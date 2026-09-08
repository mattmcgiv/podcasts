use super::{normalize_rate, sanitize_error, Error};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const HELPER_WAIT: Duration = Duration::from_millis(2500);
const HELPER_KILL_WAIT: Duration = Duration::from_millis(500);

#[cfg(target_os = "macos")]
const HELPER_BIN: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/pods-speaker-helper"));

#[derive(Clone, Debug, Default)]
pub struct TransportSnapshot {
    pub position: f64,
    pub duration: f64,
    pub rate: f64,
    pub paused: bool,
    pub ended: bool,
    pub error: Option<String>,
}

pub trait SpeakerTransport: Send + Sync {
    fn available(&self) -> bool;
    fn name(&self) -> &'static str;
    fn alive(&self) -> bool {
        true
    }
    fn load(&self, path: &Path, position: f64, rate: f64, mute: bool) -> Result<TransportSnapshot, Error>;
    fn play(&self) -> Result<TransportSnapshot, Error>;
    fn pause(&self) -> Result<TransportSnapshot, Error>;
    fn seek(&self, seconds: f64) -> Result<TransportSnapshot, Error>;
    fn set_rate(&self, rate: f64) -> Result<TransportSnapshot, Error>;
    fn stop(&self) -> Result<TransportSnapshot, Error>;
    fn snapshot(&self) -> TransportSnapshot;
    fn child_pid(&self) -> Option<i32> {
        None
    }
}

pub struct UnavailableTransport;

impl SpeakerTransport for UnavailableTransport {
    fn available(&self) -> bool {
        false
    }
    fn name(&self) -> &'static str {
        "Mac"
    }
    fn load(&self, _path: &Path, _position: f64, _rate: f64, _mute: bool) -> Result<TransportSnapshot, Error> {
        Err(unavailable())
    }
    fn play(&self) -> Result<TransportSnapshot, Error> {
        Err(unavailable())
    }
    fn pause(&self) -> Result<TransportSnapshot, Error> {
        Err(unavailable())
    }
    fn seek(&self, _seconds: f64) -> Result<TransportSnapshot, Error> {
        Err(unavailable())
    }
    fn set_rate(&self, _rate: f64) -> Result<TransportSnapshot, Error> {
        Err(unavailable())
    }
    fn stop(&self) -> Result<TransportSnapshot, Error> {
        Ok(TransportSnapshot {
            paused: true,
            rate: 1.0,
            ..TransportSnapshot::default()
        })
    }
    fn snapshot(&self) -> TransportSnapshot {
        TransportSnapshot {
            paused: true,
            rate: 1.0,
            ..TransportSnapshot::default()
        }
    }
}

fn unavailable() -> Error {
    Error::Invalid("Mac speaker is not available on this computer.".into())
}

pub struct LoadHold {
    entered: Mutex<bool>,
    entered_cvar: Condvar,
    go: Mutex<bool>,
    go_cvar: Condvar,
}

impl LoadHold {
    fn new() -> Self {
        Self {
            entered: Mutex::new(false),
            entered_cvar: Condvar::new(),
            go: Mutex::new(false),
            go_cvar: Condvar::new(),
        }
    }

    pub fn wait_entered(&self) {
        let mut entered = self.entered.lock().unwrap();
        while !*entered {
            entered = self.entered_cvar.wait(entered).unwrap();
        }
    }

    pub fn release(&self) {
        *self.go.lock().unwrap() = true;
        self.go_cvar.notify_all();
    }

    fn park(&self) {
        {
            let mut entered = self.entered.lock().unwrap();
            *entered = true;
            self.entered_cvar.notify_all();
        }
        let mut go = self.go.lock().unwrap();
        while !*go {
            go = self.go_cvar.wait(go).unwrap();
        }
    }
}

struct MemoryInner {
    available: bool,
    alive: bool,
    snapshot: TransportSnapshot,
    stopped: bool,
    loads: u64,
    last_path: Option<PathBuf>,
    load_hold: Option<Arc<LoadHold>>,
    fail_next_load: bool,
}

/// Injectable in-memory transport. Position changes only from load/seek, never a timer.
pub struct MemoryTransport {
    inner: Mutex<MemoryInner>,
}

impl MemoryTransport {
    pub fn new(available: bool) -> Self {
        Self {
            inner: Mutex::new(MemoryInner {
                available,
                alive: true,
                snapshot: TransportSnapshot {
                    paused: true,
                    rate: 1.0,
                    ..TransportSnapshot::default()
                },
                stopped: false,
                loads: 0,
                last_path: None,
                load_hold: None,
                fail_next_load: false,
            }),
        }
    }

    pub fn set_available(&self, available: bool) {
        self.inner.lock().unwrap().available = available;
    }

    pub fn set_alive(&self, alive: bool) {
        self.inner.lock().unwrap().alive = alive;
    }

    pub fn set_duration(&self, duration: f64) {
        self.inner.lock().unwrap().snapshot.duration = duration;
    }

    pub fn set_ended(&self) {
        let mut inner = self.inner.lock().unwrap();
        inner.snapshot.ended = true;
        inner.snapshot.paused = true;
        if inner.snapshot.duration > 0.0 {
            inner.snapshot.position = inner.snapshot.duration;
        }
    }

    pub fn set_error(&self, message: &str) {
        self.inner.lock().unwrap().snapshot.error = Some(sanitize_error(message));
    }

    pub fn load_count(&self) -> u64 {
        self.inner.lock().unwrap().loads
    }

    pub fn last_path(&self) -> Option<PathBuf> {
        self.inner.lock().unwrap().last_path.clone()
    }

    pub fn stopped(&self) -> bool {
        self.inner.lock().unwrap().stopped
    }

    pub fn fail_next_load(&self) {
        self.inner.lock().unwrap().fail_next_load = true;
    }

    pub fn arm_load_hold(&self) -> Arc<LoadHold> {
        let hold = Arc::new(LoadHold::new());
        self.inner.lock().unwrap().load_hold = Some(hold.clone());
        hold
    }
}

impl Default for MemoryTransport {
    fn default() -> Self {
        Self::new(true)
    }
}

impl SpeakerTransport for MemoryTransport {
    fn available(&self) -> bool {
        self.inner.lock().unwrap().available
    }
    fn name(&self) -> &'static str {
        "Mac"
    }
    fn alive(&self) -> bool {
        self.inner.lock().unwrap().alive
    }
    fn load(&self, path: &Path, position: f64, rate: f64, _mute: bool) -> Result<TransportSnapshot, Error> {
        let hold = {
            let mut inner = self.inner.lock().unwrap();
            if !inner.available {
                return Err(unavailable());
            }
            if !inner.alive {
                return Err(Error::Invalid("Mac speaker disconnected.".into()));
            }
            inner.load_hold.take()
        };
        if let Some(hold) = hold {
            hold.park();
        }
        let mut inner = self.inner.lock().unwrap();
        inner.loads += 1;
        inner.last_path = Some(path.to_path_buf());
        inner.stopped = false;
        inner.snapshot.position = position.max(0.0);
        inner.snapshot.rate = normalize_rate(rate);
        inner.snapshot.paused = true;
        inner.snapshot.ended = false;
        inner.snapshot.error = None;
        if inner.snapshot.duration <= 0.0 {
            inner.snapshot.duration = 15.0;
        }
        if inner.fail_next_load {
            inner.fail_next_load = false;
            inner.snapshot.paused = false;
            return Err(Error::Invalid("Mac could not play this episode.".into()));
        }
        Ok(inner.snapshot.clone())
    }
    fn play(&self) -> Result<TransportSnapshot, Error> {
        let mut inner = self.inner.lock().unwrap();
        if !inner.alive {
            return Err(Error::Invalid("Mac speaker disconnected.".into()));
        }
        inner.snapshot.paused = false;
        inner.snapshot.ended = false;
        Ok(inner.snapshot.clone())
    }
    fn pause(&self) -> Result<TransportSnapshot, Error> {
        let mut inner = self.inner.lock().unwrap();
        inner.snapshot.paused = true;
        Ok(inner.snapshot.clone())
    }
    fn seek(&self, seconds: f64) -> Result<TransportSnapshot, Error> {
        let mut inner = self.inner.lock().unwrap();
        inner.snapshot.position = seconds.max(0.0);
        inner.snapshot.ended = false;
        Ok(inner.snapshot.clone())
    }
    fn set_rate(&self, rate: f64) -> Result<TransportSnapshot, Error> {
        let mut inner = self.inner.lock().unwrap();
        inner.snapshot.rate = normalize_rate(rate);
        Ok(inner.snapshot.clone())
    }
    fn stop(&self) -> Result<TransportSnapshot, Error> {
        let mut inner = self.inner.lock().unwrap();
        inner.stopped = true;
        inner.snapshot.paused = true;
        inner.snapshot.ended = false;
        inner.snapshot.error = None;
        Ok(inner.snapshot.clone())
    }
    fn snapshot(&self) -> TransportSnapshot {
        self.inner.lock().unwrap().snapshot.clone()
    }
}

struct HelperProcess {
    child: Child,
    stdin: std::process::ChildStdin,
}

struct HelperShared {
    snapshot: TransportSnapshot,
    last_ack_id: u64,
    failed_id: u64,
    load_generation: u64,
    eof: bool,
    incarnation: u64,
}

pub struct HelperTransport {
    helper_path: PathBuf,
    ready: AtomicBool,
    next_id: AtomicU64,
    next_generation: AtomicU64,
    shared: Arc<(Mutex<HelperShared>, Condvar)>,
    process: Mutex<Option<HelperProcess>>,
}

impl HelperTransport {
    pub fn new() -> Result<Self, Error> {
        Ok(Self {
            helper_path: extract_helper()?,
            ready: AtomicBool::new(true),
            next_id: AtomicU64::new(1),
            next_generation: AtomicU64::new(1),
            shared: Arc::new((
                Mutex::new(HelperShared {
                    snapshot: TransportSnapshot {
                        paused: true,
                        rate: 1.0,
                        ..TransportSnapshot::default()
                    },
                    last_ack_id: 0,
                    failed_id: 0,
                    load_generation: 0,
                    eof: false,
                    incarnation: 0,
                }),
                Condvar::new(),
            )),
            process: Mutex::new(None),
        })
    }

    fn process_alive(&self) -> bool {
        let mut process = self.process.lock().unwrap();
        match process.as_mut() {
            Some(proc) => {
                if proc.child.try_wait().ok().flatten().is_some() {
                    *process = None;
                    let (lock, cvar) = &*self.shared;
                    let mut shared = lock.lock().unwrap();
                    shared.eof = true;
                    cvar.notify_all();
                    false
                } else {
                    !self.shared.0.lock().unwrap().eof
                }
            }
            None => false,
        }
    }

    fn require_alive(&self) -> Result<(), Error> {
        if self.process_alive() {
            Ok(())
        } else {
            Err(Error::Invalid("Mac speaker disconnected.".into()))
        }
    }

    fn spawn_for_load(&self) -> Result<(), Error> {
        if self.process_alive() {
            return Ok(());
        }
        self.reap();
        let mut command = Command::new(&self.helper_path);
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            command.process_group(0);
        }
        let mut child = command
            .spawn()
            .map_err(|_| Error::Invalid("Mac speaker failed to start.".into()))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| Error::Invalid("Mac speaker failed to start.".into()))?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| Error::Invalid("Mac speaker failed to start.".into()))?;
        let incarnation = {
            let (lock, cvar) = &*self.shared;
            let mut shared = lock.lock().unwrap();
            shared.incarnation = shared.incarnation.saturating_add(1);
            shared.eof = false;
            shared.last_ack_id = 0;
            shared.failed_id = 0;
            shared.snapshot.error = None;
            cvar.notify_all();
            shared.incarnation
        };
        let shared = self.shared.clone();
        thread::spawn(move || {
            let reader = BufReader::new(stdout);
            for line in reader.lines().map_while(Result::ok) {
                if let Ok(value) = serde_json::from_str::<Value>(&line) {
                    apply_helper_event(&shared, incarnation, &value);
                }
            }
            let (lock, cvar) = &*shared;
            let mut state = lock.lock().unwrap();
            if state.incarnation != incarnation {
                return;
            }
            state.eof = true;
            if state.snapshot.error.is_none() {
                state.snapshot.error = Some("Mac speaker disconnected.".into());
            }
            cvar.notify_all();
        });
        *self.process.lock().unwrap() = Some(HelperProcess { child, stdin });
        Ok(())
    }

    fn send_and_wait(&self, mut payload: Value) -> Result<TransportSnapshot, Error> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        payload["id"] = json!(id);
        {
            let mut process = self.process.lock().unwrap();
            let proc = process
                .as_mut()
                .ok_or_else(|| Error::Invalid("Mac speaker disconnected.".into()))?;
            let mut line = serde_json::to_vec(&payload)
                .map_err(|_| Error::Invalid("Mac speaker command failed.".into()))?;
            line.push(b'\n');
            proc.stdin
                .write_all(&line)
                .map_err(|_| Error::Invalid("Mac speaker disconnected.".into()))?;
            proc.stdin
                .flush()
                .map_err(|_| Error::Invalid("Mac speaker disconnected.".into()))?;
        }
        self.wait_ack(id)
    }

    fn wait_ack(&self, id: u64) -> Result<TransportSnapshot, Error> {
        let (lock, cvar) = &*self.shared;
        let start = Instant::now();
        let mut shared = lock.lock().unwrap();
        loop {
            if shared.failed_id == id {
                return Err(Error::Invalid(
                    shared
                        .snapshot
                        .error
                        .clone()
                        .unwrap_or_else(|| "Mac could not play this episode.".into()),
                ));
            }
            if shared.last_ack_id == id {
                return Ok(shared.snapshot.clone());
            }
            if shared.eof {
                return Err(Error::Invalid("Mac speaker disconnected.".into()));
            }
            let remaining = HELPER_WAIT.saturating_sub(start.elapsed());
            if remaining.is_zero() {
                return Err(Error::Invalid("Mac speaker timed out.".into()));
            }
            let (next, result) = cvar.wait_timeout(shared, remaining).unwrap();
            shared = next;
            if result.timed_out() && shared.last_ack_id != id && shared.failed_id != id {
                return Err(Error::Invalid("Mac speaker timed out.".into()));
            }
        }
    }

    fn reap(&self) {
        let mut process = self.process.lock().unwrap();
        if let Some(mut proc) = process.take() {
            kill_process(&mut proc);
        }
    }
}

fn apply_helper_event(shared: &(Mutex<HelperShared>, Condvar), incarnation: u64, value: &Value) {
    let (lock, cvar) = shared;
    let mut state = lock.lock().unwrap();
    if state.incarnation != incarnation {
        return;
    }
    let generation = value.get("generation").and_then(Value::as_u64).unwrap_or(0);
    if generation > 0 && state.load_generation > 0 && generation < state.load_generation {
        return;
    }
    if generation > 0 {
        state.load_generation = generation;
    }
    if let Some(position) = value.get("position").and_then(Value::as_f64) {
        if position.is_finite() && position >= 0.0 {
            state.snapshot.position = position;
        }
    }
    if let Some(duration) = value.get("duration").and_then(Value::as_f64) {
        if duration.is_finite() && duration > 0.0 {
            state.snapshot.duration = duration;
        }
    }
    if let Some(rate) = value.get("rate").and_then(Value::as_f64) {
        if rate.is_finite() && rate > 0.0 {
            state.snapshot.rate = rate;
        }
    }
    if let Some(paused) = value.get("paused").and_then(Value::as_bool) {
        state.snapshot.paused = paused;
    }
    if let Some(ended) = value.get("ended").and_then(Value::as_bool) {
        state.snapshot.ended = ended;
        if ended {
            state.snapshot.paused = true;
        }
    }
    let kind = value.get("type").and_then(Value::as_str).unwrap_or("");
    if let Some(error) = value.get("error").and_then(Value::as_str) {
        state.snapshot.error = Some(sanitize_error(error));
    } else if kind != "error" {
        state.snapshot.error = None;
    }
    if let Some(id) = value.get("id").and_then(Value::as_u64) {
        if kind == "ack" {
            state.last_ack_id = id;
            cvar.notify_all();
        } else if kind == "error" {
            state.failed_id = id;
            cvar.notify_all();
        } else if kind == "ended" {
            cvar.notify_all();
        }
    }
}

fn kill_process(proc: &mut HelperProcess) {
    let pid = proc.child.id() as i32;
    let _ = writeln!(proc.stdin, "{{\"cmd\":\"quit\",\"id\":0}}");
    let start = Instant::now();
    while start.elapsed() < HELPER_KILL_WAIT {
        if proc.child.try_wait().ok().flatten().is_some() {
            return;
        }
        thread::sleep(Duration::from_millis(50));
    }
    #[cfg(unix)]
    unsafe {
        libc::kill(-pid, libc::SIGTERM);
        thread::sleep(Duration::from_millis(50));
        libc::kill(-pid, libc::SIGKILL);
        let _ = proc.child.wait();
    }
    #[cfg(not(unix))]
    {
        let _ = proc.child.kill();
        let _ = proc.child.wait();
    }
}

impl SpeakerTransport for HelperTransport {
    fn available(&self) -> bool {
        self.ready.load(Ordering::SeqCst)
    }
    fn name(&self) -> &'static str {
        "Mac"
    }
    fn alive(&self) -> bool {
        self.process_alive()
    }
    fn load(&self, path: &Path, position: f64, rate: f64, mute: bool) -> Result<TransportSnapshot, Error> {
        if !path.is_absolute() {
            return Err(Error::Invalid("Mac could not play this episode.".into()));
        }
        self.spawn_for_load()?;
        let generation = self.next_generation.fetch_add(1, Ordering::SeqCst);
        {
            let mut shared = self.shared.0.lock().unwrap();
            shared.load_generation = generation;
            shared.snapshot.ended = false;
            shared.snapshot.error = None;
            shared.snapshot.duration = 0.0;
            shared.snapshot.position = position.max(0.0);
            shared.snapshot.rate = normalize_rate(rate);
            shared.snapshot.paused = true;
        }
        self.send_and_wait(json!({
            "cmd": "load",
            "generation": generation,
            "path": path.to_string_lossy(),
            "position": position,
            "rate": normalize_rate(rate),
            "mute": mute,
        }))
    }
    fn play(&self) -> Result<TransportSnapshot, Error> {
        self.require_alive()?;
        self.send_and_wait(json!({"cmd": "play"}))
    }
    fn pause(&self) -> Result<TransportSnapshot, Error> {
        self.require_alive()?;
        self.send_and_wait(json!({"cmd": "pause"}))
    }
    fn seek(&self, seconds: f64) -> Result<TransportSnapshot, Error> {
        self.require_alive()?;
        self.send_and_wait(json!({"cmd": "seek", "seconds": seconds}))
    }
    fn set_rate(&self, rate: f64) -> Result<TransportSnapshot, Error> {
        self.require_alive()?;
        self.send_and_wait(json!({"cmd": "rate", "rate": normalize_rate(rate)}))
    }
    fn stop(&self) -> Result<TransportSnapshot, Error> {
        let last = self.shared.0.lock().unwrap().snapshot.clone();
        let mut snap = if self.process_alive() {
            self.send_and_wait(json!({"cmd": "stop"}))
                .unwrap_or_else(|_| last.clone())
        } else {
            last.clone()
        };
        if snap.position <= 0.0 && last.position > 0.0 {
            snap.position = last.position;
        }
        snap.paused = true;
        snap.ended = false;
        self.reap();
        let mut shared = self.shared.0.lock().unwrap();
        shared.snapshot = snap.clone();
        shared.eof = true;
        Ok(snap)
    }
    fn snapshot(&self) -> TransportSnapshot {
        self.shared.0.lock().unwrap().snapshot.clone()
    }
    fn child_pid(&self) -> Option<i32> {
        self.process
            .lock()
            .unwrap()
            .as_ref()
            .map(|p| p.child.id() as i32)
    }
}

impl Drop for HelperTransport {
    fn drop(&mut self) {
        let _ = SpeakerTransport::stop(self);
    }
}

fn hash_bytes(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn hash_file(path: &Path) -> Result<String, Error> {
    let bytes =
        std::fs::read(path).map_err(|_| Error::Invalid("Mac speaker failed to start.".into()))?;
    Ok(hash_bytes(&bytes))
}

fn extract_helper() -> Result<PathBuf, Error> {
    #[cfg(not(target_os = "macos"))]
    {
        Err(unavailable())
    }
    #[cfg(target_os = "macos")]
    {
        if HELPER_BIN.is_empty() {
            return Err(unavailable());
        }
        let hash = hash_bytes(HELPER_BIN);
        let dir = std::env::temp_dir().join("pods-speaker-helper-cache");
        std::fs::create_dir_all(&dir)
            .map_err(|_| Error::Invalid("Mac speaker failed to start.".into()))?;
        let dest = dir.join(&hash);
        if dest.is_file() && hash_file(&dest)? == hash {
            return Ok(dest);
        }
        let part = dir.join(format!(
            "{hash}.{}.part",
            uuid::Uuid::new_v4().simple()
        ));
        std::fs::write(&part, HELPER_BIN)
            .map_err(|_| Error::Invalid("Mac speaker failed to start.".into()))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&part, std::fs::Permissions::from_mode(0o700))
                .map_err(|_| Error::Invalid("Mac speaker failed to start.".into()))?;
        }
        if hash_file(&part)? != hash {
            let _ = std::fs::remove_file(&part);
            return Err(Error::Invalid("Mac speaker failed to start.".into()));
        }
        match std::fs::rename(&part, &dest) {
            Ok(()) => Ok(dest),
            Err(_) => {
                let _ = std::fs::remove_file(&part);
                if dest.is_file() && hash_file(&dest)? == hash {
                    Ok(dest)
                } else {
                    Err(Error::Invalid("Mac speaker failed to start.".into()))
                }
            }
        }
    }
}

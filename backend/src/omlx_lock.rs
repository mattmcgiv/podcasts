//! Mac-wide cooperative oMLX inference lock.
//!
//! This is an advisory `flock(2)` on `~/.omlx/locks/mac-inference.lock`. It is
//! not a daemon. Kernel close of the lock fd releases ownership on process
//! death, panic, and Drop. Sleep/wake keeps a live holder.
//!
//! oMLX `max_concurrent_requests=1` is per model engine and still queues. This
//! lock is the Mac-wide cooperative mutex for complete inference work.
//!
//! After `flock` succeeds, Pods makes an authenticated GET `/api/status`. If
//! `active_requests` or `waiting_requests` is nonzero, Pods releases and
//! reports `omlx_busy`. An uncooperative caller can still race after that
//! check and POST to `:8000` without this file lock.
//!
//! Classification and show notes start the managed oMLX server when loopback
//! port 8000 is down, load Pods' model, then unload it on Drop. If the server
//! is idle with no models left, or Pods started it, Drop also runs `omlx stop`.
//! Whisper still only unloads Pods' model and leaves the server running.
//!
//! Nested acquire of the same lock path in-process returns busy. Chat POST
//! functions take `&InferencePermit` so they cannot start without a holder.
//!
//! `PODS_OMLX_LOCK=0` disables only this cooperative lock. That override is
//! unsafe for normal use. Locking is otherwise enabled and fail closed.
//!
//! libc is a direct dependency so this crate can call `flock(2)`. The version
//! is the one already locked in `Cargo.lock` (0.2.189). No new crate.

use crate::error::Error;
use serde_json::{json, Value};
use std::{
    collections::HashSet,
    fs::{self, File, OpenOptions},
    io,
    ops::Deref,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{Mutex, OnceLock},
    thread,
    time::{Duration, Instant},
};

#[cfg(unix)]
use std::os::unix::io::AsRawFd;

pub const OMLX_BUSY: &str = "omlx_busy";
pub const LOCK_FILE_NAME: &str = "mac-inference.lock";
pub const METADATA_FILE_NAME: &str = "mac-inference.json";
pub const OWNER_PODS: &str = "pods";
pub const PURPOSE_CLASSIFICATION: &str = "classification";
pub const PURPOSE_SHOW_NOTES: &str = "show_notes";
pub const PURPOSE_WHISPER: &str = "speech_to_text";
pub const PURPOSE_CODE_FIX: &str = "code_fix";
pub const DEFAULT_CHAT_URL: &str = "http://127.0.0.1:8000/v1/chat/completions";
const OMLX_APP_CLI: &str = "/Applications/oMLX.app/Contents/MacOS/omlx-cli";
const OMLX_START_WAIT: Duration = Duration::from_secs(180);
const OMLX_START_POLL: Duration = Duration::from_millis(200);
const OMLX_STOP_TIMEOUT_SECS: &str = "60";
const OMLX_CLI_PATH: &str = "/opt/homebrew/bin:/usr/local/bin:";

const BUSY_RETRY_MIN_SECS: i64 = 30;
const BUSY_RETRY_SPAN: u64 = 31;
const METADATA_FIELDS: [&str; 5] = ["pid", "owner", "purpose", "model", "started_at"];

static HELD_PATHS: OnceLock<Mutex<HashSet<PathBuf>>> = OnceLock::new();

fn held_paths() -> std::sync::MutexGuard<'static, HashSet<PathBuf>> {
    HELD_PATHS
        .get_or_init(|| Mutex::new(HashSet::new()))
        .lock()
        .unwrap_or_else(|e| e.into_inner())
}

#[derive(Clone, Debug)]
pub struct LockPaths {
    pub lock: PathBuf,
    pub metadata: PathBuf,
}

impl LockPaths {
    pub fn in_dir(dir: &Path) -> Self {
        Self {
            lock: dir.join(LOCK_FILE_NAME),
            metadata: dir.join(METADATA_FILE_NAME),
        }
    }

    pub fn configured() -> Result<Self, LockError> {
        Ok(Self::in_dir(&configured_lock_dir()?))
    }

    pub fn canonical() -> Result<Self, LockError> {
        Ok(Self::in_dir(&canonical_lock_dir()?))
    }
}

#[derive(Clone, Debug)]
pub struct LockClaim {
    pub owner: String,
    pub purpose: String,
    pub model: String,
}

impl LockClaim {
    pub fn new(
        owner: impl Into<String>,
        purpose: impl Into<String>,
        model: impl Into<String>,
    ) -> Result<Self, LockError> {
        let claim = Self {
            owner: owner.into(),
            purpose: purpose.into(),
            model: model.into(),
        };
        claim.validate()?;
        Ok(claim)
    }

    fn validate(&self) -> Result<(), LockError> {
        for (field, value) in [
            ("owner", self.owner.as_str()),
            ("purpose", self.purpose.as_str()),
            ("model", self.model.as_str()),
        ] {
            validate_metadata_token(field, value)?;
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Occupancy {
    pub active_requests: u64,
    pub waiting_requests: u64,
}

impl Occupancy {
    pub fn idle() -> Self {
        Self {
            active_requests: 0,
            waiting_requests: 0,
        }
    }

    pub fn is_busy(self) -> bool {
        self.active_requests != 0 || self.waiting_requests != 0
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LockError {
    Busy,
    Failed(&'static str),
}

impl LockError {
    pub fn is_busy(&self) -> bool {
        matches!(self, Self::Busy)
    }
}

impl std::fmt::Display for LockError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(OMLX_BUSY)
    }
}

impl From<LockError> for Error {
    fn from(_: LockError) -> Self {
        Error::Upstream(OMLX_BUSY.into())
    }
}

/// Capability token for oMLX chat POST. Not `Clone`: nested holders cannot share it.
#[derive(Debug)]
#[must_use]
pub struct InferencePermit {
    file: Option<File>,
    metadata: Option<PathBuf>,
    held: Option<PathBuf>,
    disabled: bool,
    purpose: String,
}

impl InferencePermit {
    pub fn is_disabled(&self) -> bool {
        self.disabled
    }

    pub fn purpose(&self) -> &str {
        &self.purpose
    }
}

impl Drop for InferencePermit {
    fn drop(&mut self) {
        if let Some(path) = self.metadata.take() {
            remove_owned_metadata(&path);
        }
        if let Some(file) = self.file.take() {
            #[cfg(unix)]
            unsafe {
                libc::flock(file.as_raw_fd(), libc::LOCK_UN);
            }
        }
        if let Some(path) = self.held.take() {
            release_held_path(&path);
        }
    }
}

/// Chat-session permit: start oMLX if it is down, load the model, then unload
/// and stop the managed server on Drop when nothing else remains loaded.
///
/// The inner flock stays held through unload/stop. A disabled advisory lock is
/// not enough authority to start, load, or stop shared state.
#[derive(Debug)]
#[must_use]
pub struct ChatPermit {
    model: String,
    started_server: bool,
    permit: Option<InferencePermit>,
}

impl Deref for ChatPermit {
    type Target = InferencePermit;

    fn deref(&self) -> &Self::Target {
        self.permit.as_ref().expect("chat permit")
    }
}

impl Drop for ChatPermit {
    fn drop(&mut self) {
        if let Some(permit) = self.permit.as_ref() {
            let _ = release_after_chat(permit, &self.model, self.started_server);
        }
        self.permit.take();
    }
}

/// 30–60 seconds, deterministic from `episode_id`.
pub fn busy_retry_delay_secs(episode_id: i64) -> i64 {
    BUSY_RETRY_MIN_SECS + (mix_u64(episode_id as u64) % BUSY_RETRY_SPAN) as i64
}

pub fn is_busy_error(error: &Error) -> bool {
    error.to_string() == OMLX_BUSY
}

pub fn lock_enabled() -> bool {
    #[cfg(test)]
    if let Some(enabled) = test_state().lock_enabled {
        return enabled;
    }
    match std::env::var("PODS_OMLX_LOCK") {
        Ok(value) if value == "0" => false,
        _ => true,
    }
}

pub fn acquire_pods(purpose: &str, model: &str) -> Result<InferencePermit, Error> {
    let paths = LockPaths::configured()?;
    let claim = LockClaim::new(OWNER_PODS, purpose, model)?;
    try_acquire(&paths, &claim, probe_occupancy).map_err(Error::from)
}

/// Acquire the cooperative lock for classification, show notes, or a code fix,
/// start oMLX if the loopback server is down, and load `model` if needed.
pub fn acquire_chat(purpose: &str, model: &str) -> Result<ChatPermit, Error> {
    if purpose != PURPOSE_CLASSIFICATION
        && purpose != PURPOSE_SHOW_NOTES
        && purpose != PURPOSE_CODE_FIX
    {
        return Err(LockError::Busy.into());
    }
    let paths = LockPaths::configured()?;
    let claim = LockClaim::new(OWNER_PODS, purpose, model)?;
    let permit = try_acquire(&paths, &claim, probe_occupancy_allow_stopped).map_err(Error::from)?;
    if permit.is_disabled() {
        return Err(LockError::Busy.into());
    }
    match prepare_chat(&permit, model) {
        Ok(started_server) => Ok(ChatPermit {
            model: model.to_string(),
            started_server,
            permit: Some(permit),
        }),
        Err(error) => Err(error),
    }
}

/// Keep cooperating inference clients out until the Whisper child exits.
/// Only unload Pods' model; the shared oMLX server remains running.
pub fn prepare_whisper(model: &str) -> Result<InferencePermit, Error> {
    let paths = LockPaths::configured()?;
    let claim = LockClaim::new(OWNER_PODS, PURPOSE_WHISPER, model)?;
    // Claim the file lock before probing. A stopped server is safe for
    // Whisper, but classification's acquire deliberately requires a server.
    let permit = try_acquire(&paths, &claim, || Ok(Occupancy::idle()))?;
    // A disabled advisory lock is insufficient authority to unload shared state.
    if permit.is_disabled() {
        return Err(LockError::Busy.into());
    }
    let Some(status) = read_omlx_status_or_stopped()? else {
        return Ok(permit);
    };
    if model_loaded_idle_from_status(model, &status)? {
        model_transition(&permit, model, "unload")?;
        if model_loaded_idle(model)? {
            return Err(LockError::Busy.into());
        }
    }
    Ok(permit)
}

pub fn load_for_classification(permit: &InferencePermit, model: &str) -> Result<(), Error> {
    if permit.purpose() != PURPOSE_CLASSIFICATION {
        return Err(LockError::Busy.into());
    }
    model_transition(permit, model, "load")
}

fn probe_occupancy_allow_stopped() -> Result<Occupancy, LockError> {
    #[cfg(test)]
    if let Some(occupancy) = test_state().occupancy {
        return Ok(occupancy);
    }
    match read_omlx_status_or_stopped()? {
        None => Ok(Occupancy::idle()),
        Some(status) => occupancy_from_status(&status),
    }
}

fn prepare_chat(permit: &InferencePermit, model: &str) -> Result<bool, Error> {
    let (status, started) = match read_omlx_status_or_stopped()? {
        Some(status) => (status, false),
        None => {
            start_omlx()?;
            match wait_for_omlx_status() {
                Ok(status) => (status, true),
                Err(error) => {
                    let _ = stop_omlx();
                    return Err(error);
                }
            }
        }
    };
    let prepared = (|| {
        if occupancy_from_status(&status)?.is_busy() || status["models_loading"].as_u64() != Some(0)
        {
            return Err(LockError::Busy.into());
        }
        if !model_in_status(model, &status)? {
            model_transition(permit, model, "load")?;
        }
        Ok(started)
    })();
    if prepared.is_err() && started {
        let _ = stop_omlx();
    }
    prepared
}

fn release_after_chat(
    permit: &InferencePermit,
    model: &str,
    started_server: bool,
) -> Result<(), Error> {
    let Some(mut status) = read_omlx_status_or_stopped()? else {
        return Ok(());
    };
    if model_loaded_idle_from_status(model, &status)? {
        model_transition(permit, model, "unload")?;
        status = read_omlx_status_or_stopped()?.ok_or(LockError::Busy)?;
        if model_loaded_idle_from_status(model, &status)? {
            return Err(LockError::Busy.into());
        }
    }
    if started_server || server_idle_empty(&status) {
        stop_omlx()?;
    }
    Ok(())
}

fn server_idle_empty(status: &Value) -> bool {
    occupancy_from_status(status).map(|occupancy| !occupancy.is_busy()) == Ok(true)
        && status["models_loading"].as_u64() == Some(0)
        && status["loaded_models"]
            .as_array()
            .is_some_and(|models| models.is_empty())
}

fn model_in_status(model: &str, status: &Value) -> Result<bool, Error> {
    let models = status["loaded_models"].as_array().ok_or(LockError::Busy)?;
    if models.iter().any(|value| !value.is_string()) {
        return Err(LockError::Busy.into());
    }
    Ok(models.iter().any(|value| value.as_str() == Some(model)))
}

fn wait_for_omlx_status() -> Result<Value, Error> {
    let deadline = Instant::now() + start_wait();
    loop {
        match read_omlx_status_or_stopped() {
            Ok(Some(status)) => return Ok(status),
            Ok(None) | Err(_) => {
                if Instant::now() >= deadline {
                    return Err(LockError::Busy.into());
                }
                thread::sleep(poll_interval());
            }
        }
    }
}

fn start_wait() -> Duration {
    #[cfg(test)]
    if let Some(wait) = test_state().start_wait {
        return wait;
    }
    OMLX_START_WAIT
}

fn poll_interval() -> Duration {
    #[cfg(test)]
    if test_state().start_wait.is_some() {
        return Duration::from_millis(20);
    }
    OMLX_START_POLL
}

fn start_omlx() -> Result<(), LockError> {
    let cli = configured_omlx_cli().ok_or(LockError::Busy)?;
    run_omlx_cli(&cli, &["start", "--no-wait"])
}

fn stop_omlx() -> Result<(), LockError> {
    let Some(cli) = configured_omlx_cli() else {
        return Ok(());
    };
    run_omlx_cli(&cli, &["stop", "--timeout", OMLX_STOP_TIMEOUT_SECS])
}

fn run_omlx_cli(cli: &Path, args: &[&str]) -> Result<(), LockError> {
    let output = Command::new(cli)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .env("PATH", omlx_cli_path())
        .output()
        .map_err(|_| LockError::Busy)?;
    if output.status.success() {
        Ok(())
    } else {
        Err(LockError::Busy)
    }
}

fn omlx_cli_path() -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    format!("{OMLX_CLI_PATH}{home}/.local/bin:{home}/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin")
}

fn configured_omlx_cli() -> Option<PathBuf> {
    #[cfg(test)]
    if let Some(cli) = test_state().omlx_cli {
        return cli;
    }
    for candidate in [
        Some(PathBuf::from(OMLX_APP_CLI)),
        std::env::var_os("HOME").map(|home| Path::new(&home).join(".omlx/bin/omlx")),
    ]
    .into_iter()
    .flatten()
    {
        if is_executable(&candidate) {
            return Some(candidate);
        }
    }
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join("omlx");
        if is_executable(&candidate) && omlx_cli_is_managed(&candidate) {
            return Some(candidate);
        }
    }
    None
}

fn omlx_cli_is_managed(path: &Path) -> bool {
    let resolved = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    let text = resolved.to_string_lossy();
    text.contains("/oMLX.app/Contents/MacOS/") || text.ends_with("/.omlx/bin/omlx")
}

fn is_executable(path: &Path) -> bool {
    if !path.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::metadata(path)
            .map(|meta| meta.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        false
    }
}

fn model_loaded_idle(model: &str) -> Result<bool, Error> {
    let status = read_omlx_status()?;
    model_loaded_idle_from_status(model, &status)
}

fn model_loaded_idle_from_status(model: &str, status: &Value) -> Result<bool, Error> {
    if occupancy_from_status(status)?.is_busy() || status["models_loading"].as_u64() != Some(0) {
        return Err(LockError::Busy.into());
    }
    model_in_status(model, status)
}

fn model_transition(_permit: &InferencePermit, model: &str, action: &str) -> Result<(), Error> {
    validate_metadata_token("model", model)?;
    let endpoint = url::Url::parse(&configured_chat_url()?)
        .map_err(|_| LockError::Busy)?
        .join(&format!("/v1/models/{model}/{action}"))
        .map_err(|_| LockError::Busy)?;
    let key = configured_api_key()?;
    let response = ureq::post(endpoint.as_str())
        .set("Authorization", &format!("Bearer {key}"))
        .timeout(Duration::from_secs(180))
        .call()
        .map_err(|_| LockError::Busy)?;
    let status: Value = serde_json::from_str(&response.into_string().map_err(|_| LockError::Busy)?)
        .map_err(|_| LockError::Busy)?;
    if status["status"] != "ok" || status["model_id"] != model {
        return Err(LockError::Busy.into());
    }
    Ok(())
}

pub fn try_acquire(
    paths: &LockPaths,
    claim: &LockClaim,
    occupancy: impl FnOnce() -> Result<Occupancy, LockError>,
) -> Result<InferencePermit, LockError> {
    claim.validate()?;
    if !lock_enabled() {
        let held = insert_held_path(&paths.lock)?;
        return Ok(InferencePermit {
            file: None,
            metadata: None,
            held: Some(held),
            disabled: true,
            purpose: claim.purpose.clone(),
        });
    }
    if let Some(parent) = paths.lock.parent() {
        fs::create_dir_all(parent).map_err(|_| LockError::Busy)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(parent, fs::Permissions::from_mode(0o755));
        }
    }
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .open(&paths.lock)
        .map_err(|_| LockError::Busy)?;
    let held_key = canonicalize_or(&paths.lock);
    let held = insert_held_path(&held_key)?;
    if let Err(error) = flock_exclusive_nonblocking(&file) {
        release_held_path(&held);
        return Err(error);
    }
    match occupancy() {
        Ok(status) if !status.is_busy() => {}
        Ok(_) | Err(_) => {
            #[cfg(unix)]
            unsafe {
                libc::flock(file.as_raw_fd(), libc::LOCK_UN);
            }
            release_held_path(&held);
            return Err(LockError::Busy);
        }
    }
    if let Err(error) = write_metadata(&paths.metadata, claim) {
        #[cfg(unix)]
        unsafe {
            libc::flock(file.as_raw_fd(), libc::LOCK_UN);
        }
        release_held_path(&held);
        return Err(error);
    }
    Ok(InferencePermit {
        file: Some(file),
        metadata: Some(paths.metadata.clone()),
        held: Some(held),
        disabled: false,
        purpose: claim.purpose.clone(),
    })
}

/// Inspect availability without keeping the lock or writing metadata.
///
/// Same-process `flock(2)` is not exclusive against the holder. This check
/// consults in-process ownership first so it cannot unlock a live permit.
pub fn lock_available(paths: &LockPaths) -> bool {
    if !lock_enabled() {
        return true;
    }
    if path_held_in_process(&paths.lock) {
        return false;
    }
    let Ok(file) = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .open(&paths.lock)
    else {
        return false;
    };
    match flock_exclusive_nonblocking(&file) {
        Ok(()) => {
            #[cfg(unix)]
            unsafe {
                libc::flock(file.as_raw_fd(), libc::LOCK_UN);
            }
            true
        }
        Err(_) => false,
    }
}

pub fn configured_chat_url() -> Result<String, Error> {
    #[cfg(test)]
    if let Some(url) = test_state().omlx_url.clone() {
        return enforce_loopback(&url).map(|u| u.to_string());
    }
    let raw = std::env::var("PODS_OMLX_URL").unwrap_or_else(|_| DEFAULT_CHAT_URL.into());
    enforce_loopback(&raw).map(|url| url.to_string())
}

pub fn configured_status_url() -> Result<String, Error> {
    let chat = configured_chat_url()?;
    let parsed = url::Url::parse(&chat).map_err(|_| Error::Upstream(OMLX_BUSY.into()))?;
    parsed
        .join("/api/status")
        .map(|url| url.to_string())
        .map_err(|_| Error::Upstream(OMLX_BUSY.into()))
}

pub fn configured_api_key() -> Result<String, Error> {
    #[cfg(test)]
    if let Some(key) = test_state().omlx_key.clone() {
        if key.is_empty() {
            return Err(Error::Upstream(
                "local model credentials unavailable".into(),
            ));
        }
        return Ok(key);
    }
    if let Ok(key) = std::env::var("PODS_OMLX_KEY") {
        if !key.is_empty() {
            return Ok(key);
        }
    }
    let path = std::env::var("HOME")
        .ok()
        .map(|home| Path::new(&home).join(".pi/agent/models.json"))
        .ok_or_else(|| Error::Upstream("local model credentials unavailable".into()))?;
    let value: Value = serde_json::from_slice(
        &fs::read(path)
            .map_err(|_| Error::Upstream("local model credentials unavailable".into()))?,
    )
    .map_err(|_| Error::Upstream("local model credentials unavailable".into()))?;
    value
        .pointer("/providers/omlx/apiKey")
        .and_then(Value::as_str)
        .filter(|key| !key.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| Error::Upstream("local model credentials unavailable".into()))
}

pub fn enforce_loopback(raw: &str) -> Result<url::Url, Error> {
    let parsed = url::Url::parse(raw)
        .map_err(|_| Error::Upstream("oMLX must be loopback; cloud fallback is disabled".into()))?;
    if !matches!(parsed.host_str(), Some("127.0.0.1" | "localhost" | "[::1]")) {
        return Err(Error::Upstream(
            "oMLX must be loopback; cloud fallback is disabled".into(),
        ));
    }
    Ok(parsed)
}

fn probe_occupancy() -> Result<Occupancy, LockError> {
    #[cfg(test)]
    if let Some(occupancy) = test_state().occupancy {
        return Ok(occupancy);
    }
    read_omlx_occupancy()
}

fn read_omlx_occupancy() -> Result<Occupancy, LockError> {
    occupancy_from_status(&read_omlx_status()?)
}

fn read_omlx_status() -> Result<Value, LockError> {
    read_omlx_status_or_stopped()?.ok_or(LockError::Busy)
}

fn read_omlx_status_or_stopped() -> Result<Option<Value>, LockError> {
    let url = configured_status_url().map_err(|_| LockError::Busy)?;
    let key = configured_api_key().map_err(|_| LockError::Busy)?;
    let response = match ureq::get(&url)
        .set("Authorization", &format!("Bearer {key}"))
        .timeout(Duration::from_secs(5))
        .call()
    {
        Ok(response) => response,
        Err(error) => {
            // Only a refused connection establishes that no listener is
            // available. Timeouts, HTTP failures and bad JSON fail closed.
            let mut source: Option<&(dyn std::error::Error + 'static)> = Some(&error);
            while let Some(cause) = source {
                if cause
                    .downcast_ref::<io::Error>()
                    .is_some_and(|e| e.kind() == io::ErrorKind::ConnectionRefused)
                {
                    return Ok(None);
                }
                source = cause.source();
            }
            return Err(LockError::Busy);
        }
    };
    let raw: Value = serde_json::from_str(&response.into_string().map_err(|_| LockError::Busy)?)
        .map_err(|_| LockError::Busy)?;
    Ok(Some(raw))
}

pub fn occupancy_from_status(raw: &Value) -> Result<Occupancy, LockError> {
    let active = json_u64(&raw["active_requests"]).ok_or(LockError::Busy)?;
    let waiting = json_u64(&raw["waiting_requests"]).ok_or(LockError::Busy)?;
    Ok(Occupancy {
        active_requests: active,
        waiting_requests: waiting,
    })
}

fn json_u64(value: &Value) -> Option<u64> {
    value
        .as_u64()
        .or_else(|| value.as_i64().and_then(|n| u64::try_from(n).ok()))
}

fn configured_lock_dir() -> Result<PathBuf, LockError> {
    #[cfg(test)]
    if let Some(dir) = test_state().lock_dir.clone() {
        return Ok(dir);
    }
    if let Ok(dir) = std::env::var("PODS_OMLX_LOCK_DIR") {
        if !dir.is_empty() {
            return Ok(PathBuf::from(dir));
        }
    }
    canonical_lock_dir()
}

fn canonical_lock_dir() -> Result<PathBuf, LockError> {
    let home = std::env::var_os("HOME").ok_or(LockError::Busy)?;
    Ok(PathBuf::from(home).join(".omlx/locks"))
}

fn validate_metadata_token(field: &str, value: &str) -> Result<(), LockError> {
    let _ = field;
    if value.is_empty() || value.len() > 120 {
        return Err(LockError::Failed("invalid lock metadata"));
    }
    let lower = value.to_ascii_lowercase();
    if lower.contains("http")
        || lower.contains("prompt")
        || lower.contains("transcript")
        || lower.contains("bearer")
        || lower.starts_with("sk-")
        || value.contains('\n')
        || value.contains('/')
        || value.contains('\\')
        || value.contains(' ')
        || value.contains(':')
    {
        return Err(LockError::Failed("invalid lock metadata"));
    }
    if !value
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
    {
        return Err(LockError::Failed("invalid lock metadata"));
    }
    Ok(())
}

fn metadata_pid(path: &Path) -> Option<u32> {
    let value: Value = serde_json::from_slice(&fs::read(path).ok()?).ok()?;
    value["pid"]
        .as_u64()
        .and_then(|n| u32::try_from(n).ok())
        .or_else(|| value["pid"].as_i64().and_then(|n| u32::try_from(n).ok()))
}

fn remove_owned_metadata(path: &Path) {
    if metadata_pid(path) == Some(std::process::id()) {
        let _ = fs::remove_file(path);
    }
}

fn write_metadata(path: &Path, claim: &LockClaim) -> Result<(), LockError> {
    claim.validate()?;
    let body = json!({
        "pid": std::process::id(),
        "owner": claim.owner,
        "purpose": claim.purpose,
        "model": claim.model,
        "started_at": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
    });
    let object = body.as_object().ok_or(LockError::Busy)?;
    if object.len() != METADATA_FIELDS.len()
        || METADATA_FIELDS
            .iter()
            .any(|field| !object.contains_key(*field))
    {
        return Err(LockError::Busy);
    }
    let encoded = serde_json::to_vec_pretty(&body).map_err(|_| LockError::Busy)?;
    let temp = path.with_extension("json.tmp");
    fs::write(&temp, encoded).map_err(|_| LockError::Busy)?;
    fs::rename(&temp, path).map_err(|_| LockError::Busy)?;
    Ok(())
}

fn flock_exclusive_nonblocking(file: &File) -> Result<(), LockError> {
    #[cfg(unix)]
    {
        let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if rc == 0 {
            return Ok(());
        }
        let err = io::Error::last_os_error();
        if err.kind() == io::ErrorKind::WouldBlock
            || err.raw_os_error() == Some(libc::EAGAIN)
            || err.raw_os_error() == Some(libc::EWOULDBLOCK)
        {
            return Err(LockError::Busy);
        }
        Err(LockError::Busy)
    }
    #[cfg(not(unix))]
    {
        let _ = file;
        Err(LockError::Busy)
    }
}

fn canonicalize_or(path: &Path) -> PathBuf {
    fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

fn path_held_in_process(path: &Path) -> bool {
    let key = canonicalize_or(path);
    let held = held_paths();
    held.contains(&key) || held.contains(&path.to_path_buf())
}

fn insert_held_path(path: &Path) -> Result<PathBuf, LockError> {
    let key = path.to_path_buf();
    let mut held = held_paths();
    if !held.insert(key.clone()) {
        return Err(LockError::Busy);
    }
    Ok(key)
}

fn release_held_path(path: &Path) {
    held_paths().remove(path);
}

fn mix_u64(mut z: u64) -> u64 {
    z = z.wrapping_add(0x9E3779B97F4A7C15);
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
    z ^ (z >> 31)
}

#[cfg(test)]
#[derive(Clone, Default)]
struct TestState {
    lock_dir: Option<PathBuf>,
    lock_enabled: Option<bool>,
    occupancy: Option<Occupancy>,
    omlx_url: Option<String>,
    omlx_key: Option<String>,
    omlx_cli: Option<Option<PathBuf>>,
    start_wait: Option<Duration>,
}

#[cfg(test)]
std::thread_local! {
    static TEST_STATE: std::cell::RefCell<TestState> = const { std::cell::RefCell::new(TestState {
        lock_dir: None,
        lock_enabled: None,
        occupancy: None,
        omlx_url: None,
        omlx_key: None,
        omlx_cli: None,
        start_wait: None,
    }) };
}

#[cfg(test)]
fn test_state() -> TestState {
    TEST_STATE.with(|state| state.borrow().clone())
}

#[cfg(test)]
pub fn with_test_lock_env<R>(
    dir: &Path,
    occupancy: Occupancy,
    enabled: bool,
    f: impl FnOnce() -> R,
) -> R {
    struct Reset;
    impl Drop for Reset {
        fn drop(&mut self) {
            TEST_STATE.with(|state| *state.borrow_mut() = TestState::default());
        }
    }
    let _reset = Reset;
    TEST_STATE.with(|state| {
        *state.borrow_mut() = TestState {
            lock_dir: Some(dir.to_path_buf()),
            lock_enabled: Some(enabled),
            occupancy: Some(occupancy),
            omlx_url: None,
            omlx_key: None,
            omlx_cli: Some(None),
            start_wait: Some(Duration::from_millis(80)),
        };
    });
    f()
}

#[cfg(test)]
pub fn set_test_omlx_endpoint(url: impl Into<String>, key: impl Into<String>) {
    TEST_STATE.with(|state| {
        let mut env = state.borrow_mut();
        env.omlx_url = Some(url.into());
        env.omlx_key = Some(key.into());
    });
}

#[cfg(test)]
pub fn set_test_occupancy(occupancy: Option<Occupancy>) {
    TEST_STATE.with(|state| state.borrow_mut().occupancy = occupancy);
}

#[cfg(test)]
pub fn set_test_omlx_cli(cli: Option<PathBuf>) {
    TEST_STATE.with(|state| state.borrow_mut().omlx_cli = Some(cli));
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::{Read, Write},
        net::TcpListener,
        process::{Command, Stdio},
        sync::{
            atomic::{AtomicUsize, Ordering},
            Arc,
        },
        thread,
        time::{Duration, Instant},
    };

    fn claim() -> LockClaim {
        LockClaim::new("pods", "classification", "Qwen3.8-27B-4bit").unwrap()
    }

    // Each response is paired with its expected request, including a second
    // status read after unload: an HTTP success alone does not prove release.
    fn lifecycle_server(replies: Vec<(&'static str, Value)>) -> (String, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let address = listener.local_addr().unwrap();
        let worker = thread::spawn(move || {
            for (expected, body) in replies {
                let deadline = Instant::now() + Duration::from_secs(5);
                let mut stream = loop {
                    if let Ok((stream, _)) = listener.accept() {
                        break stream;
                    }
                    assert!(Instant::now() < deadline, "missing {expected}");
                    thread::sleep(Duration::from_millis(5));
                };
                stream
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .unwrap();
                let mut buffer = [0; 4096];
                let n = stream.read(&mut buffer).unwrap();
                let request = String::from_utf8_lossy(&buffer[..n]);
                assert!(request.starts_with(expected), "{request}");
                assert!(request.contains("Authorization: Bearer test-key"));
                let payload = body.to_string();
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{payload}",
                    payload.len()
                )
                .unwrap();
            }
        });
        (format!("http://{address}/v1/chat/completions"), worker)
    }

    fn lifecycle_status(loaded: bool) -> Value {
        json!({"active_requests":0,"waiting_requests":0,"models_loading":0,
            "loaded_models": if loaded { vec!["model", "other"] } else { vec!["other"] }})
    }

    fn idle_models(models: &[&str]) -> Value {
        json!({"active_requests":0,"waiting_requests":0,"models_loading":0,"loaded_models":models})
    }

    #[test]
    fn whisper_unloads_holds_lock_then_classification_loads() {
        let dir = tempfile::tempdir().unwrap();
        let (url, server) = lifecycle_server(vec![
            ("GET /api/status ", lifecycle_status(true)),
            (
                "POST /v1/models/model/unload ",
                json!({"status":"ok","model_id":"model"}),
            ),
            ("GET /api/status ", lifecycle_status(false)),
            (
                "POST /v1/models/model/load ",
                json!({"status":"ok","model_id":"model"}),
            ),
        ]);
        with_test_lock_env(dir.path(), Occupancy::idle(), true, || {
            set_test_omlx_endpoint(url, "test-key");
            let paths = LockPaths::in_dir(dir.path());
            {
                let whisper = prepare_whisper("model").unwrap();
                assert_eq!(whisper.purpose(), PURPOSE_WHISPER);
                assert!(!lock_available(&paths));
                assert!(acquire_pods(PURPOSE_CLASSIFICATION, "model").is_err());
                // A bounded child represents Whisper; no model can be loaded
                // by a cooperating caller until it has exited and we drop.
                assert!(Command::new("/usr/bin/true").status().unwrap().success());
            }
            assert!(lock_available(&paths));
            let classification = acquire_pods(PURPOSE_CLASSIFICATION, "model").unwrap();
            load_for_classification(&classification, "model").unwrap();
            drop(classification);
            assert!(lock_available(&paths));
        });
        server.join().unwrap();
    }

    #[test]
    fn whisper_transition_failure_releases_permit() {
        for response in [
            json!({"status":"error"}),
            json!({"status":"ok","model_id":"model"}),
        ] {
            let dir = tempfile::tempdir().unwrap();
            let mut replies = vec![
                ("GET /api/status ", lifecycle_status(true)),
                ("POST /v1/models/model/unload ", response.clone()),
            ];
            if response["status"] == "ok" {
                replies.push(("GET /api/status ", lifecycle_status(true)));
            }
            let (url, server) = lifecycle_server(replies);
            with_test_lock_env(dir.path(), Occupancy::idle(), true, || {
                set_test_omlx_endpoint(url, "test-key");
                assert!(is_busy_error(&prepare_whisper("model").unwrap_err()));
                assert!(lock_available(&LockPaths::in_dir(dir.path())));
                assert!(!LockPaths::in_dir(dir.path()).metadata.exists());
            });
            server.join().unwrap();
        }
    }

    #[test]
    fn whisper_busy_loading_unknown_and_disabled_never_unload() {
        for status in [
            json!({"active_requests":1,"waiting_requests":0,"models_loading":0,"loaded_models":["model"]}),
            json!({"active_requests":0,"waiting_requests":1,"models_loading":0,"loaded_models":["model"]}),
            json!({"active_requests":0,"waiting_requests":0,"models_loading":1,"loaded_models":["model"]}),
            json!({"active_requests":0,"waiting_requests":0}),
        ] {
            let dir = tempfile::tempdir().unwrap();
            let (url, server) = lifecycle_server(vec![("GET /api/status ", status)]);
            with_test_lock_env(dir.path(), Occupancy::idle(), true, || {
                set_test_omlx_endpoint(url, "test-key");
                assert!(prepare_whisper("model").is_err());
                assert!(lock_available(&LockPaths::in_dir(dir.path())));
            });
            server.join().unwrap();
        }
        let dir = tempfile::tempdir().unwrap();
        with_test_lock_env(dir.path(), Occupancy::idle(), false, || {
            assert!(prepare_whisper("model").is_err());
        });
    }

    #[test]
    fn already_unloaded_whisper_failure_releases_without_reloading() {
        let dir = tempfile::tempdir().unwrap();
        let (url, server) = lifecycle_server(vec![("GET /api/status ", lifecycle_status(false))]);
        with_test_lock_env(dir.path(), Occupancy::idle(), true, || {
            set_test_omlx_endpoint(url, "test-key");
            let result = (|| -> Result<(), Error> {
                let _permit = prepare_whisper("model")?;
                Err(Error::Upstream("Whisper failed".into()))
            })();
            assert!(result.is_err());
            assert!(lock_available(&LockPaths::in_dir(dir.path())));
        });
        server.join().unwrap();
    }

    fn logging_cli(dir: &Path) -> PathBuf {
        let path = dir.join("omlx-cli");
        let log = dir.join("omlx-cli.log");
        fs::write(
            &path,
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"{}\"\nexit 0\n",
                log.display()
            ),
        )
        .unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
        }
        path
    }

    fn cli_log(dir: &Path) -> String {
        fs::read_to_string(dir.join("omlx-cli.log")).unwrap_or_default()
    }

    #[test]
    fn chat_loads_unloads_and_stops_when_idle() {
        let dir = tempfile::tempdir().unwrap();
        let cli = logging_cli(dir.path());
        let (url, server) = lifecycle_server(vec![
            ("GET /api/status ", idle_models(&[])),
            (
                "POST /v1/models/model/load ",
                json!({"status":"ok","model_id":"model"}),
            ),
            ("GET /api/status ", idle_models(&["model"])),
            (
                "POST /v1/models/model/unload ",
                json!({"status":"ok","model_id":"model"}),
            ),
            ("GET /api/status ", idle_models(&[])),
        ]);
        with_test_lock_env(dir.path(), Occupancy::idle(), true, || {
            set_test_omlx_endpoint(url, "test-key");
            set_test_omlx_cli(Some(cli.clone()));
            let permit = acquire_chat(PURPOSE_CLASSIFICATION, "model").unwrap();
            assert_eq!(permit.purpose(), PURPOSE_CLASSIFICATION);
            drop(permit);
            assert!(lock_available(&LockPaths::in_dir(dir.path())));
        });
        server.join().unwrap();
        assert_eq!(cli_log(dir.path()).trim(), "stop --timeout 60");
    }

    #[test]
    fn chat_keeps_server_when_other_models_remain() {
        let dir = tempfile::tempdir().unwrap();
        let cli = logging_cli(dir.path());
        let (url, server) = lifecycle_server(vec![
            ("GET /api/status ", lifecycle_status(true)),
            ("GET /api/status ", lifecycle_status(true)),
            (
                "POST /v1/models/model/unload ",
                json!({"status":"ok","model_id":"model"}),
            ),
            ("GET /api/status ", idle_models(&["other"])),
        ]);
        with_test_lock_env(dir.path(), Occupancy::idle(), true, || {
            set_test_omlx_endpoint(url, "test-key");
            set_test_omlx_cli(Some(cli.clone()));
            drop(acquire_chat(PURPOSE_SHOW_NOTES, "model").unwrap());
            assert!(lock_available(&LockPaths::in_dir(dir.path())));
        });
        server.join().unwrap();
        assert!(cli_log(dir.path()).is_empty());
    }

    #[test]
    fn chat_permits_code_fix_purpose() {
        let dir = tempfile::tempdir().unwrap();
        let (url, server) = lifecycle_server(vec![
            ("GET /api/status ", idle_models(&["model"])),
            ("GET /api/status ", idle_models(&["model"])),
            (
                "POST /v1/models/model/unload ",
                json!({"status":"ok","model_id":"model"}),
            ),
            ("GET /api/status ", idle_models(&[])),
        ]);
        with_test_lock_env(dir.path(), Occupancy::idle(), true, || {
            set_test_omlx_endpoint(url, "test-key");
            let permit = acquire_chat(PURPOSE_CODE_FIX, "model").unwrap();
            assert_eq!(permit.purpose(), PURPOSE_CODE_FIX);
            drop(permit);
            assert!(lock_available(&LockPaths::in_dir(dir.path())));
        });
        server.join().unwrap();
    }

    #[test]
    fn chat_starts_when_stopped_and_stops_if_never_up() {
        let dir = tempfile::tempdir().unwrap();
        let cli = logging_cli(dir.path());
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!(
            "http://{}/v1/chat/completions",
            listener.local_addr().unwrap()
        );
        drop(listener);
        with_test_lock_env(dir.path(), Occupancy::idle(), true, || {
            set_test_omlx_endpoint(url, "test-key");
            set_test_omlx_cli(Some(cli.clone()));
            assert!(is_busy_error(
                &acquire_chat(PURPOSE_CLASSIFICATION, "model").unwrap_err()
            ));
            assert!(lock_available(&LockPaths::in_dir(dir.path())));
        });
        let log = cli_log(dir.path());
        assert!(log.contains("start --no-wait"), "{log}");
        assert!(log.contains("stop --timeout 60"), "{log}");
    }

    #[test]
    fn running_chat_does_not_start_cli() {
        let dir = tempfile::tempdir().unwrap();
        let cli = logging_cli(dir.path());
        let (url, server) = lifecycle_server(vec![
            ("GET /api/status ", idle_models(&[])),
            (
                "POST /v1/models/model/load ",
                json!({"status":"ok","model_id":"model"}),
            ),
            ("GET /api/status ", idle_models(&["model"])),
            (
                "POST /v1/models/model/unload ",
                json!({"status":"ok","model_id":"model"}),
            ),
            ("GET /api/status ", idle_models(&[])),
        ]);
        with_test_lock_env(dir.path(), Occupancy::idle(), true, || {
            set_test_omlx_endpoint(url, "test-key");
            set_test_omlx_cli(Some(cli.clone()));
            drop(acquire_chat(PURPOSE_CLASSIFICATION, "model").unwrap());
        });
        server.join().unwrap();
        assert_eq!(cli_log(dir.path()).trim(), "stop --timeout 60");
        assert!(!cli_log(dir.path()).contains("start"));
    }

    #[test]
    fn disabled_lock_never_starts_or_stops_omlx() {
        let dir = tempfile::tempdir().unwrap();
        let cli = logging_cli(dir.path());
        with_test_lock_env(dir.path(), Occupancy::idle(), false, || {
            set_test_omlx_cli(Some(cli.clone()));
            assert!(is_busy_error(
                &acquire_chat(PURPOSE_CLASSIFICATION, "model").unwrap_err()
            ));
        });
        assert!(cli_log(dir.path()).is_empty());
    }

    #[test]
    fn whisper_does_not_stop_omlx() {
        let dir = tempfile::tempdir().unwrap();
        let cli = logging_cli(dir.path());
        let (url, server) = lifecycle_server(vec![
            ("GET /api/status ", lifecycle_status(true)),
            (
                "POST /v1/models/model/unload ",
                json!({"status":"ok","model_id":"model"}),
            ),
            ("GET /api/status ", lifecycle_status(false)),
        ]);
        with_test_lock_env(dir.path(), Occupancy::idle(), true, || {
            set_test_omlx_endpoint(url, "test-key");
            set_test_omlx_cli(Some(cli.clone()));
            drop(prepare_whisper("model").unwrap());
        });
        server.join().unwrap();
        assert!(cli_log(dir.path()).is_empty());
    }

    #[test]
    fn unavailable_server_and_failed_load_release_on_return() {
        let dir = tempfile::tempdir().unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!(
            "http://{}/v1/chat/completions",
            listener.local_addr().unwrap()
        );
        drop(listener);
        with_test_lock_env(dir.path(), Occupancy::idle(), true, || {
            set_test_omlx_endpoint(url, "test-key");
            let permit = prepare_whisper("model").unwrap();
            assert!(!lock_available(&LockPaths::in_dir(dir.path())));
            assert!(acquire_pods(PURPOSE_CLASSIFICATION, "model").is_err());
            drop(permit);
            assert!(lock_available(&LockPaths::in_dir(dir.path())));
        });
        let (url, server) = lifecycle_server(vec![(
            "POST /v1/models/model/load ",
            json!({"status":"error"}),
        )]);
        with_test_lock_env(dir.path(), Occupancy::idle(), true, || {
            set_test_omlx_endpoint(url, "test-key");
            let result = (|| -> Result<(), Error> {
                let permit = acquire_pods(PURPOSE_CLASSIFICATION, "model")?;
                load_for_classification(&permit, "model")
            })();
            assert!(result.is_err());
            assert!(lock_available(&LockPaths::in_dir(dir.path())));
        });
        server.join().unwrap();
    }

    fn notes_claim() -> LockClaim {
        LockClaim::new("pods", "show_notes", "Qwen3.8-27B-4bit").unwrap()
    }

    fn idle_occupancy() -> Result<Occupancy, LockError> {
        Ok(Occupancy::idle())
    }

    fn acquire_idle(paths: &LockPaths, claim: &LockClaim) -> Result<InferencePermit, LockError> {
        try_acquire(paths, claim, idle_occupancy)
    }

    #[test]
    fn mutual_exclusion_second_acquire_is_busy() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LockPaths::in_dir(dir.path());
        let first = acquire_idle(&paths, &claim()).unwrap();
        assert!(try_acquire(&paths, &claim(), idle_occupancy)
            .unwrap_err()
            .is_busy());
        drop(first);
        assert!(acquire_idle(&paths, &claim()).is_ok());
    }

    #[test]
    fn second_thread_sees_busy() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LockPaths::in_dir(dir.path());
        let first = acquire_idle(&paths, &claim()).unwrap();
        let paths2 = paths.clone();
        let busy = thread::spawn(move || try_acquire(&paths2, &claim(), idle_occupancy))
            .join()
            .unwrap()
            .unwrap_err();
        assert!(busy.is_busy());
        drop(first);
    }

    #[test]
    fn second_process_lockf_is_busy() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LockPaths::in_dir(dir.path());
        fs::create_dir_all(dir.path()).unwrap();
        File::create(&paths.lock).unwrap();
        let mut child = Command::new("/usr/bin/lockf")
            .args(["-k", "-s", "-t", "0"])
            .arg(&paths.lock)
            .args(["/bin/sleep", "20"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline && lock_available(&paths) {
            thread::sleep(Duration::from_millis(10));
        }
        assert!(!lock_available(&paths));
        assert!(acquire_idle(&paths, &claim()).unwrap_err().is_busy());
        let _ = child.kill();
        let _ = child.wait();
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline && !lock_available(&paths) {
            thread::sleep(Duration::from_millis(10));
        }
        assert!(acquire_idle(&paths, &claim()).is_ok());
    }

    #[test]
    fn drop_releases_lock() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LockPaths::in_dir(dir.path());
        {
            let _permit = acquire_idle(&paths, &claim()).unwrap();
            assert!(!lock_available(&paths));
        }
        assert!(lock_available(&paths));
        assert!(!paths.metadata.is_file());
        assert!(paths.lock.is_file());
    }

    #[test]
    fn lock_available_does_not_write_metadata() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LockPaths::in_dir(dir.path());
        assert!(lock_available(&paths));
        assert!(!paths.metadata.is_file());
        assert!(paths.lock.is_file());
    }

    #[test]
    fn drop_leaves_metadata_owned_by_another_pid() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LockPaths::in_dir(dir.path());
        let permit = acquire_idle(&paths, &claim()).unwrap();
        fs::write(
            &paths.metadata,
            r#"{"pid":1,"owner":"pi","purpose":"chat","model":"unspecified","started_at":"2026-01-01T00:00:00Z"}"#,
        )
        .unwrap();
        drop(permit);
        assert_eq!(metadata_pid(&paths.metadata), Some(1));
        assert!(lock_available(&paths));
    }

    #[test]
    fn error_path_releases_lock() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LockPaths::in_dir(dir.path());
        let result: Result<(), Error> = (|| {
            let _permit = acquire_idle(&paths, &claim())?;
            Err(Error::Upstream("boom".into()))
        })();
        assert!(result.is_err());
        assert!(lock_available(&paths));
    }

    #[test]
    fn panic_unwind_releases_lock() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LockPaths::in_dir(dir.path());
        let caught = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _permit = acquire_idle(&paths, &claim()).unwrap();
            panic!("omlx lock panic fixture");
        }));
        assert!(caught.is_err());
        assert!(lock_available(&paths));
        assert!(acquire_idle(&paths, &claim()).is_ok());
    }

    #[test]
    fn metadata_lifecycle_and_redaction() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LockPaths::in_dir(dir.path());
        let permit = acquire_idle(&paths, &claim()).unwrap();
        let raw = fs::read_to_string(&paths.metadata).unwrap();
        let value: Value = serde_json::from_str(&raw).unwrap();
        let object = value.as_object().unwrap();
        assert_eq!(object.len(), 5);
        for field in METADATA_FIELDS {
            assert!(object.contains_key(field));
        }
        assert_eq!(value["owner"], "pods");
        assert_eq!(value["purpose"], "classification");
        assert_eq!(value["pid"], std::process::id());
        assert!(!raw.contains("http"));
        assert!(!raw.contains("sk-"));
        assert!(!raw.contains("prompt"));
        assert!(!raw.contains("transcript"));
        assert!(!raw.contains("Bearer"));
        drop(permit);
        assert!(!paths.metadata.is_file());
        assert!(paths.lock.is_file());
    }

    #[test]
    fn metadata_rejects_payload_shaped_fields() {
        assert!(LockClaim::new("pods", "classification", "http://127.0.0.1/secret").is_err());
        assert!(LockClaim::new("pods", "say this prompt", "model").is_err());
        assert!(LockClaim::new("pods", "classification", "sk-secret-key-value").is_err());
        assert!(LockClaim::new("pods", "classification", "a".repeat(121)).is_err());
    }

    #[test]
    fn override_skips_cooperative_lock() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LockPaths::in_dir(dir.path());
        File::create(&paths.lock).unwrap();
        let mut child = Command::new("/usr/bin/lockf")
            .args(["-k", "-s", "-t", "0"])
            .arg(&paths.lock)
            .args(["/bin/sleep", "20"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline && lock_available(&paths) {
            thread::sleep(Duration::from_millis(10));
        }
        with_test_lock_env(dir.path(), Occupancy::idle(), false, || {
            let permit = acquire_pods("classification", "Qwen3.8-27B-4bit").unwrap();
            assert!(permit.is_disabled());
            assert!(!paths.metadata.is_file());
        });
        let _ = child.kill();
        let _ = child.wait();
    }

    #[test]
    fn occupied_status_releases_and_reports_busy() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LockPaths::in_dir(dir.path());
        let busy = Occupancy {
            active_requests: 1,
            waiting_requests: 0,
        };
        assert!(try_acquire(&paths, &claim(), || Ok(busy))
            .unwrap_err()
            .is_busy());
        assert!(lock_available(&paths));
        assert!(!paths.metadata.is_file());
        let waiting = Occupancy {
            active_requests: 0,
            waiting_requests: 2,
        };
        assert!(try_acquire(&paths, &claim(), || Ok(waiting))
            .unwrap_err()
            .is_busy());
        assert!(acquire_idle(&paths, &claim()).is_ok());
    }

    #[test]
    fn occupancy_http_busy_does_not_keep_lock() {
        let dir = tempfile::tempdir().unwrap();
        let (url, posts, server) =
            spawn_status_server(json!({"active_requests":1,"waiting_requests":0}));
        with_test_lock_env(dir.path(), Occupancy::idle(), true, || {
            set_test_omlx_endpoint(&url, "test-key");
            TEST_STATE.with(|state| state.borrow_mut().occupancy = None);
            let paths = LockPaths::in_dir(dir.path());
            assert!(try_acquire(&paths, &claim(), read_omlx_occupancy)
                .unwrap_err()
                .is_busy());
            assert_eq!(posts.load(Ordering::SeqCst), 0);
            assert!(lock_available(&paths));
        });
        let _ = server.join();
    }

    #[test]
    fn inspect_availability_does_not_steal_lock() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LockPaths::in_dir(dir.path());
        let permit = acquire_idle(&paths, &claim()).unwrap();
        assert!(!lock_available(&paths));
        assert!(paths.metadata.is_file());
        assert!(!lock_available(&paths));
        drop(permit);
        assert!(lock_available(&paths));
    }

    #[test]
    fn classification_and_show_notes_share_the_same_lock_separately() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LockPaths::in_dir(dir.path());
        {
            let permit = acquire_idle(&paths, &claim()).unwrap();
            assert_eq!(permit.purpose(), "classification");
            assert!(try_acquire(&paths, &notes_claim(), idle_occupancy)
                .unwrap_err()
                .is_busy());
        }
        let notes = acquire_idle(&paths, &notes_claim()).unwrap();
        assert_eq!(notes.purpose(), "show_notes");
        let meta: Value = serde_json::from_slice(&fs::read(&paths.metadata).unwrap()).unwrap();
        assert_eq!(meta["purpose"], "show_notes");
    }

    #[test]
    fn busy_retry_is_bounded_and_deterministic() {
        for id in [0_i64, 1, 7, 42, 20720, i64::MIN, i64::MAX] {
            let delay = busy_retry_delay_secs(id);
            assert!((30..=60).contains(&delay), "id={id} delay={delay}");
            assert_eq!(delay, busy_retry_delay_secs(id));
        }
        let spread: std::collections::HashSet<_> = (0..200).map(busy_retry_delay_secs).collect();
        assert!(spread.len() > 1);
    }

    #[test]
    fn occupancy_parser_reads_status_counts() {
        assert!(
            occupancy_from_status(&json!({"active_requests":0,"waiting_requests":0}))
                .unwrap()
                .is_busy()
                == false
        );
        assert!(
            occupancy_from_status(&json!({"active_requests":1,"waiting_requests":0}))
                .unwrap()
                .is_busy()
        );
        assert!(
            occupancy_from_status(&json!({"active_requests":0,"waiting_requests":1}))
                .unwrap()
                .is_busy()
        );
        assert!(occupancy_from_status(&json!({"status":"ok"})).is_err());
    }

    #[test]
    fn loopback_enforcement_rejects_remote_hosts() {
        assert!(enforce_loopback("http://example.com/v1/chat/completions").is_err());
        assert!(enforce_loopback("http://127.0.0.1:8000/v1/chat/completions").is_ok());
        assert!(enforce_loopback("http://localhost:8000/v1/chat/completions").is_ok());
    }

    fn spawn_status_server(body: Value) -> (String, Arc<AtomicUsize>, thread::JoinHandle<()>) {
        let posts = Arc::new(AtomicUsize::new(0));
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let address = listener.local_addr().unwrap();
        let posts_clone = posts.clone();
        let server = thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(5);
            while Instant::now() < deadline {
                let Ok((mut stream, _)) = listener.accept() else {
                    thread::sleep(Duration::from_millis(5));
                    continue;
                };
                stream.set_nonblocking(false).unwrap();
                let mut buffer = [0; 4096];
                let n = stream.read(&mut buffer).unwrap_or(0);
                let request = String::from_utf8_lossy(&buffer[..n]);
                if request.starts_with("POST") {
                    posts_clone.fetch_add(1, Ordering::SeqCst);
                }
                let payload = body.to_string();
                let _ = write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{payload}",
                    payload.len()
                );
                break;
            }
        });
        (
            format!("http://127.0.0.1:{}/v1/chat/completions", address.port()),
            posts,
            server,
        )
    }
}

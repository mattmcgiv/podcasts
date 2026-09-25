//! User-typed feature requests and bug reports, dispatched to `pi` on the Mac.
//!
//! The browser queues reports through `/api/sync/actions` (entity `feedback`,
//! field is the report id). This worker claims one queued report per step,
//! holds the cooperative oMLX lock for the code-fix model, and runs
//! `pi --provider omlx --model <model> --print` in the repo checkout so the
//! report becomes a local code fix. Dispatch stays disabled until
//! `PODS_FEEDBACK_REPO` names the checkout directory.
use crate::{Backend, Error};
use rusqlite::{params, OptionalExtension};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

pub const PI_PROVIDER: &str = "omlx";
pub const MAX_ATTEMPTS: i64 = 3;
const DEFAULT_TIMEOUT_SECS: u64 = 1800;
const FAILURE_BACKOFF_BASE_SECS: i64 = 300;
const FAILURE_BACKOFF_MAX_SECS: i64 = 7200;
const PREEMPT_RETRY_SECS: i64 = 60;
const LAUNCH_RETRY_SECS: i64 = 60;

pub fn model() -> String {
    std::env::var("PODS_FEEDBACK_MODEL")
        .ok()
        .filter(|model| !model.is_empty())
        .unwrap_or_else(|| crate::local_worker::MODEL.to_string())
}

fn pi_bin() -> String {
    std::env::var("PODS_FEEDBACK_PI")
        .ok()
        .filter(|bin| !bin.is_empty())
        .unwrap_or_else(|| "pi".to_string())
}

fn repo_dir() -> Option<PathBuf> {
    let dir = std::env::var_os("PODS_FEEDBACK_REPO").map(PathBuf::from)?;
    if dir.is_dir() { Some(dir) } else { None }
}

fn timeout_secs() -> u64 {
    std::env::var("PODS_FEEDBACK_TIMEOUT_SECS")
        .ok()
        .and_then(|raw| raw.parse::<u64>().ok())
        .filter(|secs| *secs > 0)
        .unwrap_or(DEFAULT_TIMEOUT_SECS)
}

/// 30–60 seconds, deterministic from the report id. Mirrors the oMLX busy range.
fn retry_delay_secs(id: &str) -> i64 {
    30 + (id.bytes().fold(0u64, |sum, byte| sum.wrapping_add(byte as u64)) % 31) as i64
}

struct Report {
    id: String,
    kind: String,
    body: String,
    attempts: i64,
}

enum PiOutcome {
    Ok(Duration),
    Exit(Option<i32>, Duration),
    Timeout(Duration),
    SpawnFailed(String),
    Preempted,
}

/// Claim and dispatch the oldest queued report. Gate failures defer the report
/// without consuming an attempt and return `Ok(false)` so episode work proceeds.
pub fn step(backend: &Backend) -> Result<bool, Error> {
    let Some(repo) = repo_dir() else {
        return Ok(false);
    };
    let timeout = timeout_secs();
    let now = crate::db::now_unix();
    // A restart mid-run leaves `running` rows behind; the timeout reclaims them.
    backend.db.execute(
        "UPDATE browser_feedback SET status='queued', next_at=0, started_at=0 WHERE status='running' AND started_at<?",
        [now - timeout as i64],
    )?;
    let report: Option<Report> = {
        let conn = backend.db.lock()?;
        conn.query_row(
            "SELECT id, kind, body, attempts FROM browser_feedback WHERE status='queued' AND next_at<=? ORDER BY created_at LIMIT 1",
            [now],
            |row| {
                Ok(Report {
                    id: row.get(0)?,
                    kind: row.get(1)?,
                    body: row.get(2)?,
                    attempts: row.get(3)?,
                })
            },
        )
        .optional()?
    };
    let Some(report) = report else {
        return Ok(false);
    };
    if crate::power_gate::require_external_power().is_err()
        || crate::memory_gate::require_inference(crate::memory_gate::InferenceKind::Omlx).is_err()
    {
        return defer(backend, &report.id);
    }
    let model = model();
    let _permit = match crate::omlx_lock::acquire_chat(crate::omlx_lock::PURPOSE_CODE_FIX, &model) {
        Ok(permit) => permit,
        Err(_) => return defer(backend, &report.id),
    };
    let claimed = backend.db.execute(
        "UPDATE browser_feedback SET status='running', started_at=?, attempts=attempts+1 WHERE id=? AND status='queued'",
        params![crate::db::now_unix(), report.id],
    )?;
    if claimed != 1 {
        return Ok(false);
    }
    let attempts = report.attempts + 1;
    let prompt = dispatch_prompt(&repo, &report.kind, &report.body);
    match run_pi(&pi_bin(), &model, &repo, &prompt, Duration::from_secs(timeout)) {
        PiOutcome::Ok(elapsed) => {
            finish(
                backend,
                &report.id,
                "done",
                &format!("pi exit 0 in {}s", elapsed.as_secs()),
                0,
            )?;
        }
        PiOutcome::Exit(code, elapsed) => {
            if code == Some(127) {
                requeue_without_attempt(
                    backend,
                    &report.id,
                    &format!(
                        "pi exit 127 after {}s (launch failed; retrying)",
                        elapsed.as_secs()
                    ),
                )?;
            } else {
                fail_or_retry(
                    backend,
                    &report.id,
                    attempts,
                    &format!(
                        "pi exit {} after {}s",
                        code.unwrap_or(-1),
                        elapsed.as_secs()
                    ),
                )?;
            }
        }
        PiOutcome::Timeout(limit) => {
            fail_or_retry(
                backend,
                &report.id,
                attempts,
                &format!("pi timeout after {}s", limit.as_secs()),
            )?;
        }
        PiOutcome::SpawnFailed(detail) => {
            requeue_without_attempt(backend, &report.id, &format!("pi spawn failed: {detail}"))?;
        }
        PiOutcome::Preempted => {
            backend.db.execute(
                "UPDATE browser_feedback SET status='queued', next_at=?, started_at=0, attempts=attempts-1 WHERE id=?",
                params![crate::db::now_unix() + PREEMPT_RETRY_SECS, report.id],
            )?;
        }
    }
    Ok(true)
}

fn defer(backend: &Backend, id: &str) -> Result<bool, Error> {
    backend.db.execute(
        "UPDATE browser_feedback SET next_at=? WHERE id=? AND status='queued'",
        params![crate::db::now_unix() + retry_delay_secs(id), id],
    )?;
    Ok(false)
}

fn finish(backend: &Backend, id: &str, status: &str, result: &str, next_at: i64) -> Result<(), Error> {
    backend.db.execute(
        "UPDATE browser_feedback SET status=?, result=?, next_at=?, started_at=0 WHERE id=?",
        params![status, result, next_at, id],
    )?;
    Ok(())
}

fn fail_or_retry(backend: &Backend, id: &str, attempts: i64, result: &str) -> Result<(), Error> {
    if attempts >= MAX_ATTEMPTS {
        finish(backend, id, "failed", result, 0)?;
    } else {
        let backoff = FAILURE_BACKOFF_BASE_SECS
            .saturating_mul(1 << attempts.min(4))
            .min(FAILURE_BACKOFF_MAX_SECS);
        finish(
            backend,
            id,
            "queued",
            result,
            crate::db::now_unix() + backoff,
        )?;
    }
    Ok(())
}

/// Requeue a report whose pi launch never ran without consuming an attempt.
/// A missing binary or interpreter is environmental: the report waits for the
/// host to be repaired instead of failing after three launch attempts.
fn requeue_without_attempt(backend: &Backend, id: &str, result: &str) -> Result<(), Error> {
    backend.db.execute(
        "UPDATE browser_feedback SET status='queued', result=?, next_at=?, started_at=0, attempts=attempts-1 WHERE id=?",
        params![result, crate::db::now_unix() + LAUNCH_RETRY_SECS, id],
    )?;
    Ok(())
}

fn dispatch_prompt(repo: &Path, kind: &str, body: &str) -> String {
    let label = if kind == "bug" { "bug report" } else { "feature request" };
    format!(
        "You maintain the Pods codebase checked out at {}. The owner filed this {label} from the app:\n\n---\n{body}\n---\n\nImplement the fix in the working tree. Follow AGENTS.md and the repo's existing patterns. Run the relevant tests. Do not commit, push, or change branches; leave the fix uncommitted for review and end with a short summary of what changed.",
        repo.display()
    )
}

#[cfg(unix)]
fn run_pi(pi: &str, model: &str, repo: &Path, prompt: &str, timeout: Duration) -> PiOutcome {
    use std::os::unix::process::CommandExt;
    let mut child = match Command::new(pi)
        .arg("--provider")
        .arg(PI_PROVIDER)
        .arg("--model")
        .arg(model)
        .arg("--print")
        .arg("--")
        .arg(prompt)
        .current_dir(repo)
        .process_group(0)
        .spawn()
    {
        Ok(child) => child,
        Err(error) => return PiOutcome::SpawnFailed(error.to_string()),
    };
    let start = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => return PiOutcome::Ok(start.elapsed()),
            Ok(Some(status)) => return PiOutcome::Exit(status.code(), start.elapsed()),
            Ok(None) => {}
            Err(error) => return PiOutcome::SpawnFailed(error.to_string()),
        }
        if start.elapsed() >= timeout {
            preempt_process_group(&mut child);
            return PiOutcome::Timeout(timeout);
        }
        if crate::power_gate::require_external_power().is_err() {
            preempt_process_group(&mut child);
            return PiOutcome::Preempted;
        }
        std::thread::sleep(Duration::from_secs(1));
    }
}

#[cfg(not(unix))]
fn run_pi(pi: &str, model: &str, repo: &Path, prompt: &str, _timeout: Duration) -> PiOutcome {
    let start = Instant::now();
    match Command::new(pi)
        .arg("--provider")
        .arg(PI_PROVIDER)
        .arg("--model")
        .arg(model)
        .arg("--print")
        .arg("--")
        .arg(prompt)
        .current_dir(repo)
        .status()
    {
        Ok(status) if status.success() => PiOutcome::Ok(start.elapsed()),
        Ok(status) => PiOutcome::Exit(status.code(), start.elapsed()),
        Err(error) => PiOutcome::SpawnFailed(error.to_string()),
    }
}

#[cfg(unix)]
fn preempt_process_group(child: &mut std::process::Child) {
    let pid = child.id() as libc::pid_t;
    unsafe {
        libc::killpg(pid, libc::SIGTERM);
    }
    let deadline = Instant::now() + Duration::from_secs(15);
    while Instant::now() < deadline {
        if child.try_wait().ok().flatten().is_some() {
            return;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    unsafe {
        libc::killpg(pid, libc::SIGKILL);
    }
    let _ = child.wait();
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Database, DisabledDirectory, MockFeedFetcher};
    use serde_json::json;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;

    // Process-global env is shared by parallel tests; the guard serializes mutation.
    static ENV_SERIAL: std::sync::Mutex<()> = std::sync::Mutex::new(());

    struct EnvGuard {
        previous: Vec<(&'static str, Option<String>)>,
        _serial: std::sync::MutexGuard<'static, ()>,
    }

    impl EnvGuard {
        fn apply(values: Vec<(&'static str, Option<String>)>) -> Self {
            let serial = ENV_SERIAL.lock().unwrap_or_else(|poison| poison.into_inner());
            let previous = values
                .iter()
                .map(|(key, _)| (*key, std::env::var(key).ok()))
                .collect();
            for (key, value) in &values {
                match value {
                    Some(value) => std::env::set_var(key, value),
                    None => std::env::remove_var(key),
                }
            }
            Self {
                previous,
                _serial: serial,
            }
        }
    }

    impl Drop for EnvGuard {
        fn drop(&mut self) {
            for (key, value) in &self.previous {
                match value {
                    Some(value) => std::env::set_var(key, value),
                    None => std::env::remove_var(key),
                }
            }
        }
    }

    fn fixture() -> (Backend, tempfile::TempDir) {
        let temp = tempfile::tempdir().unwrap();
        let db = Database::open_in_memory().unwrap();
        let mut backend = Backend::with_data_root(
            db,
            Arc::new(MockFeedFetcher::default()),
            Arc::new(DisabledDirectory),
            Some(temp.path().to_owned()),
        );
        backend.local = true;
        (backend, temp)
    }

    fn queue_report(backend: &Backend, id: &str, kind: &str, body: &str) {
        backend
            .db
            .execute(
                "INSERT INTO browser_feedback(id,kind,body,device,client_id,created_at) VALUES(?,?,?,?,?,?)",
                params![id, kind, body, "iPhone", "client", crate::db::now_unix()],
            )
            .unwrap();
    }

    fn report_status(backend: &Backend, id: &str) -> (String, i64, i64, Option<String>) {
        backend
            .db
            .lock()
            .unwrap()
            .query_row(
                "SELECT status, attempts, next_at, result FROM browser_feedback WHERE id=?",
                [id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .unwrap()
    }

    fn stub_pi(dir: &Path, script: &str) -> PathBuf {
        let path = dir.join("pi-stub");
        std::fs::write(&path, format!("#!/bin/sh\n{script}\n")).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        path
    }

    struct MockOmlx {
        url: String,
        stop: Arc<AtomicBool>,
        handle: Option<std::thread::JoinHandle<()>>,
    }

    impl Drop for MockOmlx {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::SeqCst);
            if let Some(handle) = self.handle.take() {
                let _ = handle.join();
            }
        }
    }

    fn start_mock_omlx(model: &str) -> MockOmlx {
        let status = json!({
            "active_requests": 0,
            "waiting_requests": 0,
            "models_loading": 0,
            "loaded_models": [model],
        })
        .to_string();
        let stop = Arc::new(AtomicBool::new(false));
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let address = listener.local_addr().unwrap();
        let stop_clone = stop.clone();
        let handle = std::thread::spawn(move || {
            while !stop_clone.load(Ordering::SeqCst) {
                let Ok((mut stream, _)) = listener.accept() else {
                    std::thread::sleep(Duration::from_millis(5));
                    continue;
                };
                stream.set_nonblocking(false).unwrap();
                stream.set_read_timeout(Some(Duration::from_secs(2))).ok();
                let mut buffer = Vec::new();
                let mut chunk = [0; 4096];
                loop {
                    match stream.read(&mut chunk) {
                        Ok(0) => break,
                        Ok(n) => {
                            buffer.extend_from_slice(&chunk[..n]);
                            if buffer.windows(4).any(|w| w == b"\r\n\r\n") {
                                break;
                            }
                        }
                        Err(_) => break,
                    }
                }
                let header = String::from_utf8_lossy(&buffer).into_owned();
                let content_len = header
                    .lines()
                    .filter_map(|line| line.split_once(':'))
                    .filter(|(name, _)| name.eq_ignore_ascii_case("content-length"))
                    .filter_map(|(_, value)| value.trim().parse::<usize>().ok())
                    .next()
                    .unwrap_or(0);
                let header_end = buffer
                    .windows(4)
                    .position(|w| w == b"\r\n\r\n")
                    .map(|i| i + 4)
                    .unwrap_or(buffer.len());
                while buffer.len() < header_end + content_len {
                    match stream.read(&mut chunk) {
                        Ok(0) => break,
                        Ok(n) => buffer.extend_from_slice(&chunk[..n]),
                        Err(_) => break,
                    }
                }
                let request_line = header.lines().next().unwrap_or("").to_string();
                let payload = if request_line.starts_with("POST /v1/models/") {
                    let id = request_line
                        .split_whitespace()
                        .nth(1)
                        .unwrap_or("")
                        .split('/')
                        .nth(3)
                        .unwrap_or("");
                    json!({"status":"ok","model_id":id}).to_string()
                } else {
                    status.clone()
                };
                let _ = write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{payload}",
                    payload.len()
                );
            }
        });
        MockOmlx {
            url: format!(
                "http://127.0.0.1:{}/v1/chat/completions",
                address.port()
            ),
            stop,
            handle: Some(handle),
        }
    }

    fn open_gates<R>(work: impl FnOnce() -> R) -> R {
        let mut memory = crate::memory_gate::TestMemory::default();
        memory.snapshot.available_bytes = 64 * 1024 * 1024 * 1024;
        crate::memory_gate::with_test_memory(memory, || {
            crate::power_gate::with_test_power_status(
                crate::power_gate::PowerStatus::External,
                work,
            )
        })
    }

    fn with_lock<R>(work: impl FnOnce() -> R) -> R {
        let dir = tempfile::tempdir().unwrap();
        let mock = start_mock_omlx(&model());
        crate::omlx_lock::with_test_lock_env(
            dir.path(),
            crate::omlx_lock::Occupancy::idle(),
            true,
            || {
                crate::omlx_lock::set_test_omlx_endpoint(&mock.url, "test-key");
                work()
            },
        )
    }

    #[test]
    fn step_without_repo_is_noop() {
        let _env = EnvGuard::apply(vec![("PODS_FEEDBACK_REPO", None)]);
        let (backend, _temp) = fixture();
        assert_eq!(step(&backend).unwrap(), false);
    }

    #[test]
    fn env_guard_survives_poisoned_serial() {
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _guard = ENV_SERIAL.lock().unwrap();
            panic!("poison the env serial for coverage");
        }));
        let _env = EnvGuard::apply(vec![]);
    }

    #[test]
    fn mock_omlx_consumes_request_body() {
        use std::io::{Read, Write};
        let mock = start_mock_omlx("test-model");
        let port: u16 = mock
            .url
            .rsplit(':')
            .next()
            .unwrap()
            .split('/')
            .next()
            .unwrap()
            .parse()
            .unwrap();
        let mut stream = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
        stream
            .write_all(b"POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello")
            .unwrap();
        let mut response = Vec::new();
        stream.read_to_end(&mut response).unwrap();
        assert!(response.starts_with(b"HTTP/1.1 200 OK"));
    }

    #[test]
    fn step_without_reports_is_noop() {
        let (backend, temp) = fixture();
        let _env = EnvGuard::apply(vec![(
            "PODS_FEEDBACK_REPO",
            Some(temp.path().to_string_lossy().into_owned()),
        )]);
        assert_eq!(open_gates(|| step(&backend).unwrap()), false);
    }

    #[test]
    fn missing_repo_disables_dispatch() {
        let _env = EnvGuard::apply(vec![(
            "PODS_FEEDBACK_REPO",
            Some("/nonexistent-pods-feedback-repo".to_string()),
        )]);
        let (backend, _temp) = fixture();
        assert_eq!(step(&backend).unwrap(), false);
    }

    #[test]
    fn env_defaults_match_local_model() {
        let _env = EnvGuard::apply(vec![
            ("PODS_FEEDBACK_MODEL", None),
            ("PODS_FEEDBACK_PI", None),
            ("PODS_FEEDBACK_TIMEOUT_SECS", None),
        ]);
        assert_eq!(model(), crate::local_worker::MODEL);
        assert_eq!(pi_bin(), "pi");
        assert_eq!(timeout_secs(), 1800);
    }

    #[test]
    fn prompt_names_report_and_forbids_history_writes() {
        let prompt = dispatch_prompt(Path::new("/repo"), "bug", "it broke");
        assert!(prompt.contains("bug report"), "{prompt}");
        assert!(prompt.contains("it broke"), "{prompt}");
        assert!(prompt.contains("/repo"), "{prompt}");
        assert!(prompt.contains("Do not commit"), "{prompt}");
    }

    #[test]
    fn retry_delay_is_bounded_and_deterministic() {
        for id in ["a", "report-1", "xyz"] {
            let delay = retry_delay_secs(id);
            assert!((30..=60).contains(&delay), "{id}");
            assert_eq!(delay, retry_delay_secs(id));
        }
    }

    #[test]
    fn successful_run_marks_report_done_and_invokes_pi_with_omlx_model() {
        let (backend, temp) = fixture();
        queue_report(&backend, "r1", "bug", "crash on launch");
        let args_log = temp.path().join("args.log");
        let pi = stub_pi(
            temp.path(),
            &format!("echo \"$*\" >> '{}'\nexit 0", args_log.display()),
        );
        let _env = EnvGuard::apply(vec![
            (
                "PODS_FEEDBACK_REPO",
                Some(temp.path().to_string_lossy().into_owned()),
            ),
            ("PODS_FEEDBACK_PI", Some(pi.to_string_lossy().into_owned())),
        ]);
        let dispatched = open_gates(|| with_lock(|| step(&backend).unwrap()));
        assert!(dispatched);
        let (status, attempts, _, result) = report_status(&backend, "r1");
        assert_eq!(status, "done");
        assert_eq!(attempts, 1);
        assert!(result.unwrap().contains("pi exit 0"));
        let args = std::fs::read_to_string(&args_log).unwrap();
        assert!(args.contains("--provider omlx"), "{args}");
        assert!(args.contains(&format!("--model {}", model())), "{args}");
        assert!(args.contains("--print"), "{args}");
        assert!(args.contains("crash on launch"), "{args}");
    }

    #[test]
    fn failing_run_retries_then_marks_failed() {
        let (backend, temp) = fixture();
        queue_report(&backend, "r1", "feature", "dark mode");
        let pi = stub_pi(temp.path(), "exit 1");
        let _env = EnvGuard::apply(vec![
            (
                "PODS_FEEDBACK_REPO",
                Some(temp.path().to_string_lossy().into_owned()),
            ),
            ("PODS_FEEDBACK_PI", Some(pi.to_string_lossy().into_owned())),
        ]);
        open_gates(|| {
            with_lock(|| {
                assert!(step(&backend).unwrap());
                let (status, attempts, next_at, result) = report_status(&backend, "r1");
                assert_eq!(status, "queued");
                assert_eq!(attempts, 1);
                assert!(next_at > crate::db::now_unix());
                assert!(result.unwrap().contains("pi exit 1"));
                backend
                    .db
                    .execute("UPDATE browser_feedback SET next_at=0 WHERE id='r1'", [])
                    .unwrap();
                assert!(step(&backend).unwrap());
                let (status, attempts, _, _) = report_status(&backend, "r1");
                assert_eq!(status, "queued");
                assert_eq!(attempts, 2);
                backend
                    .db
                    .execute("UPDATE browser_feedback SET next_at=0 WHERE id='r1'", [])
                    .unwrap();
                assert!(step(&backend).unwrap());
                let (status, attempts, _, _) = report_status(&backend, "r1");
                assert_eq!(status, "failed");
                assert_eq!(attempts, 3);
            })
        });
    }

    #[test]
    fn exit_127_requeues_without_consuming_an_attempt() {
        let (backend, temp) = fixture();
        queue_report(&backend, "r1", "feature", "dark mode");
        let pi = stub_pi(temp.path(), "exit 127");
        let _env = EnvGuard::apply(vec![
            (
                "PODS_FEEDBACK_REPO",
                Some(temp.path().to_string_lossy().into_owned()),
            ),
            ("PODS_FEEDBACK_PI", Some(pi.to_string_lossy().into_owned())),
        ]);
        open_gates(|| {
            with_lock(|| {
                assert!(step(&backend).unwrap());
                let (status, attempts, next_at, result) = report_status(&backend, "r1");
                assert_eq!(status, "queued");
                assert_eq!(attempts, 0);
                assert!(next_at > crate::db::now_unix());
                assert!(result.unwrap().contains("pi exit 127"));
                // A permanently broken launcher must not fail the report:
                // repeated 127s still leave it queued with zero attempts.
                for _ in 0..3 {
                    backend
                        .db
                        .execute("UPDATE browser_feedback SET next_at=0 WHERE id='r1'", [])
                        .unwrap();
                    assert!(step(&backend).unwrap());
                }
                let (status, attempts, _, _) = report_status(&backend, "r1");
                assert_eq!(status, "queued");
                assert_eq!(attempts, 0);
            })
        });
    }

    #[test]
    fn spawn_failure_requeues_without_consuming_an_attempt() {
        let (backend, temp) = fixture();
        queue_report(&backend, "r1", "bug", "crash on launch");
        let _env = EnvGuard::apply(vec![
            (
                "PODS_FEEDBACK_REPO",
                Some(temp.path().to_string_lossy().into_owned()),
            ),
            (
                "PODS_FEEDBACK_PI",
                Some(
                    temp.path()
                        .join("missing-pi")
                        .to_string_lossy()
                        .into_owned(),
                ),
            ),
        ]);
        let dispatched = open_gates(|| with_lock(|| step(&backend).unwrap()));
        assert!(dispatched);
        let (status, attempts, next_at, result) = report_status(&backend, "r1");
        assert_eq!(status, "queued");
        assert_eq!(attempts, 0);
        assert!(next_at > crate::db::now_unix());
        assert!(result.unwrap().contains("pi spawn failed"));
    }

    #[test]
    fn busy_lock_defers_without_consuming_an_attempt() {
        let (backend, temp) = fixture();
        queue_report(&backend, "r1", "bug", "stuck sync");
        let pi = stub_pi(temp.path(), "exit 0");
        let dir = tempfile::tempdir().unwrap();
        let _env = EnvGuard::apply(vec![
            (
                "PODS_FEEDBACK_REPO",
                Some(temp.path().to_string_lossy().into_owned()),
            ),
            ("PODS_FEEDBACK_PI", Some(pi.to_string_lossy().into_owned())),
        ]);
        let dispatched = open_gates(|| {
            crate::omlx_lock::with_test_lock_env(
                dir.path(),
                crate::omlx_lock::Occupancy::idle(),
                false,
                || step(&backend).unwrap(),
            )
        });
        assert!(!dispatched);
        let (status, attempts, next_at, _) = report_status(&backend, "r1");
        assert_eq!(status, "queued");
        assert_eq!(attempts, 0);
        assert!(next_at > crate::db::now_unix());
    }

    #[test]
    fn battery_power_defers_without_dispatch() {
        let (backend, temp) = fixture();
        queue_report(&backend, "r1", "bug", "no power");
        let _env = EnvGuard::apply(vec![(
            "PODS_FEEDBACK_REPO",
            Some(temp.path().to_string_lossy().into_owned()),
        )]);
        let mut memory = crate::memory_gate::TestMemory::default();
        memory.snapshot.available_bytes = 64 * 1024 * 1024 * 1024;
        let dispatched = crate::memory_gate::with_test_memory(memory, || {
            crate::power_gate::with_test_power_status(
                crate::power_gate::PowerStatus::Battery,
                || step(&backend).unwrap(),
            )
        });
        assert!(!dispatched);
        let (status, attempts, next_at, _) = report_status(&backend, "r1");
        assert_eq!(status, "queued");
        assert_eq!(attempts, 0);
        assert!(next_at > crate::db::now_unix());
    }

    #[test]
    fn timed_out_run_requeues_with_backoff() {
        let (backend, temp) = fixture();
        queue_report(&backend, "r1", "feature", "slow model");
        let pi = stub_pi(temp.path(), "sleep 30");
        let _env = EnvGuard::apply(vec![
            (
                "PODS_FEEDBACK_REPO",
                Some(temp.path().to_string_lossy().into_owned()),
            ),
            ("PODS_FEEDBACK_PI", Some(pi.to_string_lossy().into_owned())),
            ("PODS_FEEDBACK_TIMEOUT_SECS", Some("2".to_string())),
        ]);
        let dispatched = open_gates(|| with_lock(|| step(&backend).unwrap()));
        assert!(dispatched);
        let (status, attempts, next_at, result) = report_status(&backend, "r1");
        assert_eq!(status, "queued");
        assert_eq!(attempts, 1);
        assert!(next_at > crate::db::now_unix());
        assert!(result.unwrap().contains("timeout"));
    }

    #[test]
    fn stale_running_report_is_reclaimed() {
        let (backend, temp) = fixture();
        backend
            .db
            .execute(
                "INSERT INTO browser_feedback(id,kind,body,device,client_id,created_at,status,attempts,started_at) VALUES('r1','bug','orphaned', 'iPhone','client',?, 'running',1,?)",
                params![crate::db::now_unix(), crate::db::now_unix() - 10_000],
            )
            .unwrap();
        let pi = stub_pi(temp.path(), "exit 0");
        let _env = EnvGuard::apply(vec![
            (
                "PODS_FEEDBACK_REPO",
                Some(temp.path().to_string_lossy().into_owned()),
            ),
            ("PODS_FEEDBACK_PI", Some(pi.to_string_lossy().into_owned())),
            ("PODS_FEEDBACK_TIMEOUT_SECS", None),
        ]);
        let dispatched = open_gates(|| with_lock(|| step(&backend).unwrap()));
        assert!(dispatched);
        let (status, attempts, _, _) = report_status(&backend, "r1");
        assert_eq!(status, "done");
        assert_eq!(attempts, 2);
    }
}

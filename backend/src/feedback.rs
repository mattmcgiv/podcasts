//! User-typed feature requests and bug reports, dispatched to `pi` on the Mac.
//!
//! The browser queues reports through `/api/sync/actions` (entity `feedback`,
//! field is the report id). This worker claims one queued report per step,
//! holds the cooperative oMLX lock for the code-fix model, and runs
//! `pi --provider omlx --model <model> --print` in the repo checkout so the
//! report becomes a local code fix. Dispatch stays disabled until
//! `PODS_FEEDBACK_REPO` names the checkout directory.
//!
//! A clean pi exit is not trusted on its own: `verify` checks the worktree
//! diff is non-empty, touches no protected build/gate path, and passes the
//! area test suites (cargo for `backend/`, the client gate in an ephemeral
//! container for `client/`). Verified reports become `ready` for the host
//! land-and-ship timer; anything else becomes `needs-review` with the reason.
//! Old `done` rows are verified the same way as backfill, so no finished
//! report waits silently.
//!
//! Every wait and outcome lands in `browser_feedback.result`: gate deferrals
//! name the gate, preempts name the power loss, and each run appends its pi
//! transcript at `feedback/<id>.pi.log` in the artifact store. Each report gets
//! an isolated git worktree (`feedback-worktrees/<id>` under the data root)
//! on its own `feedback/<id>` branch, reused across attempts so a retry
//! continues earlier work. pi never touches the owner's checkout and never
//! commits; the backend never removes worktrees itself, so unreviewed work
//! is never destroyed.
use crate::{Backend, Error};
use rusqlite::{params, OptionalExtension};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub const PI_PROVIDER: &str = "omlx";
pub const MAX_ATTEMPTS: i64 = 3;
const DEFAULT_TIMEOUT_SECS: u64 = 1800;
const DEFAULT_VERIFY_TIMEOUT_SECS: u64 = 600;
const FAILURE_BACKOFF_BASE_SECS: i64 = 300;
const FAILURE_BACKOFF_MAX_SECS: i64 = 7200;
const PREEMPT_RETRY_SECS: i64 = 60;
const LAUNCH_RETRY_SECS: i64 = 60;
const MAX_REASON_CHARS: usize = 200;
const MAX_VERIFY_TAIL_CHARS: usize = 1200;

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

fn verify_timeout_secs() -> u64 {
    std::env::var("PODS_FEEDBACK_VERIFY_TIMEOUT_SECS")
        .ok()
        .and_then(|raw| raw.parse::<u64>().ok())
        .filter(|secs| *secs > 0)
        .unwrap_or(DEFAULT_VERIFY_TIMEOUT_SECS)
}

fn cargo_bin() -> String {
    std::env::var("PODS_FEEDBACK_CARGO")
        .ok()
        .filter(|bin| !bin.is_empty())
        .unwrap_or_else(|| "cargo".to_string())
}

fn container_bin() -> String {
    std::env::var("PODS_FEEDBACK_CONTAINER")
        .ok()
        .filter(|bin| !bin.is_empty())
        .unwrap_or_else(|| "container".to_string())
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
/// With nothing queued, one finished-but-unverified `done` report is verified
/// as backfill; verification needs only the worktree, not the repo checkout.
pub fn step(backend: &Backend) -> Result<bool, Error> {
    let timeout = timeout_secs();
    let now = crate::db::now_unix();
    // A restart mid-run leaves `running` rows behind; the timeout reclaims them.
    // This is pure bookkeeping, so it runs even while dispatch is disabled.
    backend.db.execute(
        "UPDATE browser_feedback SET status='queued', next_at=0, started_at=0, result='reclaimed after restart' WHERE status='running' AND started_at<?",
        [now - timeout as i64],
    )?;
    let Some(repo) = repo_dir() else {
        return verify_backfill(backend);
    };
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
        return verify_backfill(backend);
    };
    if let Err(error) = crate::power_gate::require_external_power() {
        return defer(backend, &report.id, &format!("waiting on power ({error})"));
    }
    if let Err(error) = crate::memory_gate::require_inference(crate::memory_gate::InferenceKind::Omlx) {
        return defer(backend, &report.id, &format!("waiting on memory ({error})"));
    }
    let model = model();
    let _permit = match crate::omlx_lock::acquire_chat(crate::omlx_lock::PURPOSE_CODE_FIX, &model) {
        Ok(permit) => permit,
        Err(error) => return defer(backend, &report.id, &format!("waiting on omlx ({error})")),
    };
    let claimed = backend.db.execute(
        "UPDATE browser_feedback SET status='running', started_at=?, attempts=attempts+1 WHERE id=? AND status='queued'",
        params![crate::db::now_unix(), report.id],
    )?;
    if claimed != 1 {
        return Ok(false);
    }
    let attempts = report.attempts + 1;
    let (worktree, branch) = match ensure_worktree(&repo, backend, &report.id) {
        Ok(pair) => pair,
        Err(error) => {
            requeue_without_attempt(backend, &report.id, &format!("worktree setup failed: {error}"))?;
            return Ok(true);
        }
    };
    let log = open_pi_log(backend, &report.id);
    let prompt = dispatch_prompt(&worktree, &branch, &report.kind, &report.body);
    let outcome = run_pi(
        &pi_bin(),
        &model,
        &worktree,
        &prompt,
        Duration::from_secs(timeout),
        log.as_ref().map(|(_, path)| path.as_path()),
    );
    let note = format!("{}{}", log_summary(&log), worktree_note(&worktree, &branch));
    match outcome {
        PiOutcome::Ok(elapsed) => {
            let prefix = format!("pi exit 0 in {}s", elapsed.as_secs());
            match verify(&worktree, &report.id) {
                Ok(summary) => finish(
                    backend,
                    &report.id,
                    "ready",
                    &format!("{prefix}; verified: {summary}{note}"),
                    0,
                )?,
                Err(reason) => finish(
                    backend,
                    &report.id,
                    "needs-review",
                    &format!("{prefix} but {reason}{note}"),
                    0,
                )?,
            }
        }
        PiOutcome::Exit(code, elapsed) => {
            if code == Some(127) {
                requeue_without_attempt(
                    backend,
                    &report.id,
                    &format!(
                        "pi exit 127 after {}s (launch failed; retrying){note}",
                        elapsed.as_secs()
                    ),
                )?;
            } else {
                fail_or_retry(
                    backend,
                    &report.id,
                    attempts,
                    &format!(
                        "pi exit {} after {}s{note}",
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
                &format!("pi timeout after {}s{note}", limit.as_secs()),
            )?;
        }
        PiOutcome::SpawnFailed(detail) => {
            requeue_without_attempt(backend, &report.id, &format!("pi spawn failed: {detail}"))?;
        }
        PiOutcome::Preempted => {
            note_preempted(backend, &report.id, &note)?;
        }
    }
    Ok(true)
}

/// Verify one finished-but-unverified report left over from before the
/// verify stage existed. New runs verify inline; this drains the backlog.
fn verify_backfill(backend: &Backend) -> Result<bool, Error> {
    let id: Option<String> = backend
        .db
        .lock()?
        .query_row(
            "SELECT id FROM browser_feedback WHERE status='done' ORDER BY created_at LIMIT 1",
            [],
            |row| row.get(0),
        )
        .optional()?;
    let Some(id) = id else {
        return Ok(false);
    };
    let worktree = worktrees_root(backend).join(&id);
    let note = worktree_note(&worktree, &worktree_branch(&id));
    match verify(&worktree, &id) {
        Ok(summary) => finish(
            backend,
            &id,
            "ready",
            &format!("backfill verified: {summary}{note}"),
            0,
        )?,
        Err(reason) => finish(
            backend,
            &id,
            "needs-review",
            &format!("backfill {reason}{note}"),
            0,
        )?,
    }
    Ok(true)
}

/// Check a finished run before it becomes landable: the diff must be
/// non-empty, avoid protected build/gate paths, and pass the area suites.
/// `Ok` carries a short summary for the result column; `Err` carries the
/// reason the report needs a human. Both keep the worktree intact.
fn verify(worktree: &Path, id: &str) -> Result<String, String> {
    if !worktree.join(".git").exists() {
        return Err("the worktree is missing".to_string());
    }
    let files = changed_files(worktree)?;
    if files.is_empty() {
        return Err("no file changed".to_string());
    }
    if let Some(hit) = files.iter().find(|file| verify_protected_path(file)) {
        return Err(format!("protected path changed: {hit}"));
    }
    let timeout = Duration::from_secs(verify_timeout_secs());
    let mut ran = Vec::new();
    if files.iter().any(|file| file.starts_with("backend/")) {
        let manifest = worktree.join("backend/Cargo.toml").to_string_lossy().into_owned();
        let secs = run_verify_cmd(
            &cargo_bin(),
            &["test", "--manifest-path", &manifest, "--features", "passkey"],
            worktree,
            timeout,
            id,
            "cargo test",
        )?;
        ran.push(format!("cargo test {secs}s"));
    }
    if files.iter().any(|file| file.starts_with("client/")) {
        let mount = format!("{}:/work/client", worktree.join("client").display());
        let secs = run_verify_cmd(
            &container_bin(),
            &[
                "run", "--rm", "--dns", "1.1.1.1", "--cpus", "6", "--memory", "8g",
                "-v", &mount, "--tmpfs", "/work/client/node_modules", "pods-dev-img",
                "sh", "-c", "cd /work/client && npm ci --no-audit --no-fund && npm run check",
            ],
            worktree,
            timeout,
            id,
            "client gate",
        )?;
        ran.push(format!("client gate {secs}s"));
    }
    let suites = if ran.is_empty() {
        "no code touched".to_string()
    } else {
        ran.join(", ")
    };
    Ok(format!("{} file(s); {suites}", files.len()))
}

/// Uncommitted changes plus any branch delta: pi is told not to commit, but
/// a committed change still ships, so it must be verified too.
fn changed_files(worktree: &Path) -> Result<Vec<String>, String> {
    let mut files = std::collections::BTreeSet::new();
    let status = git(worktree, &["status", "--porcelain=v1", "-uall"])?;
    for line in status.lines() {
        let path = line.get(3..).unwrap_or("").trim();
        // Renames print `old -> new`; the new name is what ships.
        let path = path.rsplit(" -> ").next().unwrap_or("").trim().trim_matches('"');
        if !path.is_empty() {
            files.insert(path.to_string());
        }
    }
    if let Ok(delta) = git(worktree, &["diff", "--name-only", "main...HEAD"]) {
        for line in delta.lines() {
            let path = line.trim();
            if !path.is_empty() {
                files.insert(path.to_string());
            }
        }
    }
    Ok(files.into_iter().collect())
}

/// Build configuration and the merge gate itself. Mirrors the dispatch
/// prompt; the prompt tells pi, this enforces. A fix that legitimately needs
/// one of these paths goes through a human.
fn verify_protected_path(path: &str) -> bool {
    path.starts_with("dev/")
        || path.starts_with("infra/")
        || path.starts_with(".github/")
        || path.starts_with("client/scripts/")
        || path == "client/package.json"
        || path == "client/package-lock.json"
        || path == "client/vite.config.ts"
        || path.starts_with("backend/Cargo.")
}

/// Run one verify command with a timeout. Stdout and stderr share a capture
/// file so the failure reason can quote the tail.
fn run_verify_cmd(
    bin: &str,
    args: &[&str],
    cwd: &Path,
    timeout: Duration,
    id: &str,
    label: &str,
) -> Result<u64, String> {
    let capture =
        std::env::temp_dir().join(format!("pods-verify-{}-{id}-{label}.log", std::process::id()));
    let (log_out, log_err) = log_stdio_pair(Some(&capture));
    let mut cmd = Command::new(bin);
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        cmd.process_group(0);
    }
    let mut child = cmd
        .args(args)
        .current_dir(cwd)
        .stdout(log_out)
        .stderr(log_err)
        .spawn()
        .map_err(|error| format!("{label} not launchable: {error}"))?;
    let start = Instant::now();
    let status = loop {
        match child
            .try_wait()
            .map_err(|error| format!("{label} wait failed: {error}"))?
        {
            Some(status) => break status,
            None => {}
        }
        if start.elapsed() >= timeout {
            kill_verify_child(&mut child);
            let _ = std::fs::remove_file(&capture);
            return Err(format!("{label} timeout after {}s", timeout.as_secs()));
        }
        std::thread::sleep(Duration::from_secs(1));
    };
    let secs = start.elapsed().as_secs();
    let tail = read_tail(&capture, MAX_VERIFY_TAIL_CHARS);
    let _ = std::fs::remove_file(&capture);
    if status.success() {
        Ok(secs)
    } else {
        Err(format!(
            "{label} exit {} after {secs}s: {tail}",
            status.code().unwrap_or(-1)
        ))
    }
}

fn read_tail(path: &Path, max_chars: usize) -> String {
    let text = std::fs::read_to_string(path).unwrap_or_default();
    let trimmed = text.trim();
    if trimmed.chars().count() <= max_chars {
        return trimmed.to_string();
    }
    trimmed.chars().rev().take(max_chars).collect::<String>().chars().rev().collect()
}

#[cfg(unix)]
fn kill_verify_child(child: &mut std::process::Child) {
    preempt_process_group(child);
}

#[cfg(not(unix))]
fn kill_verify_child(child: &mut std::process::Child) {
    let _ = child.kill();
    let _ = child.wait();
}

fn defer(backend: &Backend, id: &str, reason: &str) -> Result<bool, Error> {
    let reason: String = reason.chars().take(MAX_REASON_CHARS).collect();
    backend.db.execute(
        "UPDATE browser_feedback SET next_at=?, result=? WHERE id=? AND status='queued'",
        params![crate::db::now_unix() + retry_delay_secs(id), reason, id],
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

fn note_preempted(backend: &Backend, id: &str, log_note: &str) -> Result<(), Error> {
    backend.db.execute(
        "UPDATE browser_feedback SET status='queued', result=?, next_at=?, started_at=0, attempts=attempts-1 WHERE id=?",
        params![
            format!("preempted: power lost during run; tree kept, attempt not consumed{log_note}"),
            crate::db::now_unix() + PREEMPT_RETRY_SECS,
            id
        ],
    )?;
    Ok(())
}

fn pi_log_relative(id: &str) -> String {
    format!("feedback/{id}.pi.log")
}

/// Reserve the per-report pi transcript. `None` dispatches without a log
/// rather than failing the report.
fn open_pi_log(backend: &Backend, id: &str) -> Option<(String, PathBuf)> {
    let relative = pi_log_relative(id);
    backend
        .artifacts
        .prepare_dest(&relative)
        .ok()
        .map(|path| (relative, path))
}

/// Open the transcript once and share it: cloned handles share one file
/// offset, so stdout and stderr interleave instead of overwriting each other
/// no matter which stream writes first.
fn log_stdio_pair(path: Option<&Path>) -> (Stdio, Stdio) {
    let pair = path
        .and_then(|path| {
            std::fs::OpenOptions::new()
                .create(true)
                .truncate(true)
                .write(true)
                .open(path)
                .ok()
        })
        .and_then(|file| file.try_clone().ok().map(|clone| (file, clone)));
    match pair {
        Some((out, err)) => (Stdio::from(out), Stdio::from(err)),
        None => (Stdio::inherit(), Stdio::inherit()),
    }
}

fn log_summary(log: &Option<(String, PathBuf)>) -> String {
    match log {
        Some((relative, path)) => {
            let bytes = std::fs::metadata(path).map(|meta| meta.len()).unwrap_or(0);
            format!("; log {relative} ({bytes} bytes)")
        }
        None => "; log unavailable".to_string(),
    }
}

fn worktrees_root(backend: &Backend) -> PathBuf {
    backend.data_root.join("feedback-worktrees")
}

fn worktree_branch(id: &str) -> String {
    format!("feedback/{id}")
}

/// Report ids arrive from the browser: keep them inside the worktrees directory.
fn valid_worktree_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 128 && !id.contains('/') && !id.contains("..") && !id.starts_with('.')
}

fn git(repo: &Path, args: &[&str]) -> Result<String, String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(args)
        .output()
        .map_err(|error| format!("git not launchable: {error}"))?;
    if output.status.success() {
        return Ok(String::from_utf8_lossy(&output.stdout).into_owned());
    }
    let detail = String::from_utf8_lossy(&output.stderr).trim().to_string();
    Err(if detail.is_empty() {
        format!("git {} failed", args.join(" "))
    } else {
        format!(
            "git {} failed: {}",
            args.join(" "),
            detail.chars().take(300).collect::<String>()
        )
    })
}

/// Isolated checkout for one report, reused across attempts so retries
/// continue earlier work. The branch preserves the lineage for review.
fn ensure_worktree(repo: &Path, backend: &Backend, id: &str) -> Result<(PathBuf, String), String> {
    if !valid_worktree_id(id) {
        return Err(format!("invalid report id {id:?}"));
    }
    let dir = worktrees_root(backend).join(id);
    let branch = worktree_branch(id);
    if dir.join(".git").exists() {
        return Ok((dir, branch));
    }
    if dir.exists() {
        return Err(format!("worktree path blocked: {}", dir.display()));
    }
    if let Some(parent) = dir.parent() {
        std::fs::create_dir_all(parent).map_err(|error| format!("worktree root not writable: {error}"))?;
    }
    // Fresh branch first; an existing branch (worktree removed by hand) is reused instead.
    let dir_arg = dir.to_string_lossy().into_owned();
    match git(repo, &["worktree", "add", "-b", &branch, &dir_arg, "HEAD"]) {
        Ok(_) => Ok((dir, branch)),
        Err(first) => git(repo, &["worktree", "add", &dir_arg, &branch])
            .map(|_| (dir, branch))
            .map_err(|second| format!("{first}; then {second}")),
    }
}

fn worktree_note(dir: &Path, branch: &str) -> String {
    format!("; worktree {} ({branch})", dir.display())
}

fn dispatch_prompt(worktree: &Path, branch: &str, kind: &str, body: &str) -> String {
    let label = if kind == "bug" { "bug report" } else { "feature request" };
    format!(
        "You maintain the Pods codebase checked out at {} on branch {branch}. The owner filed this {label} from the app:\n\n---\n{body}\n---\n\nImplement the fix in this worktree. Follow AGENTS.md and the repo's existing patterns. Start with `git status --short` and `git diff --stat`: a previous attempt may have left committed or uncommitted progress here — continue it instead of redoing it. Keep the diff minimal and scoped to this request; do not change the merge gate or build configuration (anything under dev/ or infra/, client/package.json, client/package-lock.json, client/vite.config.ts, client/scripts/, backend/Cargo.toml, backend/Cargo.lock) and do not add new check scripts — the verifier rejects those paths and your run will need a human. Verify backend changes with `cargo test` from this worktree. The client test container mounts the main checkout rather than this worktree, so never run dev/check.sh or npm here — client changes are verified after you finish, and your closing summary must say that. Do not commit, push, or change branches; leave the fix uncommitted for review and end with a short summary of what changed.",
        worktree.display()
    )
}

#[cfg(unix)]
fn run_pi(
    pi: &str,
    model: &str,
    repo: &Path,
    prompt: &str,
    timeout: Duration,
    log: Option<&Path>,
) -> PiOutcome {
    use std::os::unix::process::CommandExt;
    let (log_out, log_err) = log_stdio_pair(log);
    let mut child = match Command::new(pi)
        .arg("--provider")
        .arg(PI_PROVIDER)
        .arg("--model")
        .arg(model)
        .arg("--print")
        .arg("--")
        .arg(prompt)
        .current_dir(repo)
        .stdout(log_out)
        .stderr(log_err)
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
fn run_pi(
    pi: &str,
    model: &str,
    repo: &Path,
    prompt: &str,
    _timeout: Duration,
    log: Option<&Path>,
) -> PiOutcome {
    let start = Instant::now();
    let (log_out, log_err) = log_stdio_pair(log);
    match Command::new(pi)
        .arg("--provider")
        .arg(PI_PROVIDER)
        .arg("--model")
        .arg(model)
        .arg("--print")
        .arg("--")
        .arg(prompt)
        .current_dir(repo)
        .stdout(log_out)
        .stderr(log_err)
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
        stub_bin(dir, "pi-stub", script)
    }

    fn stub_bin(dir: &Path, name: &str, script: &str) -> PathBuf {
        let path = dir.join(name);
        std::fs::write(&path, format!("#!/bin/sh\n{script}\n")).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        path
    }

    /// Minimal git checkout for worktree tests. Requires the git binary:
    /// backend tests run on the Mac host. Identity and signing come from
    /// `-c` flags so no global gitconfig is touched or needed.
    fn git_repo(path: &Path) {
        let run = |args: &[&str]| {
            let status = Command::new("git")
                .arg("-C")
                .arg(path)
                .args(args)
                .status()
                .expect("git binary");
            assert!(status.success(), "{args:?}");
        };
        run(&["init", "-b", "main"]);
        run(&[
            "-c",
            "user.email=t@t",
            "-c",
            "user.name=t",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "--allow-empty",
            "-m",
            "base",
        ]);
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
        let prompt = dispatch_prompt(Path::new("/wt"), "feedback/r1", "bug", "it broke");
        assert!(prompt.contains("bug report"), "{prompt}");
        assert!(prompt.contains("it broke"), "{prompt}");
        assert!(prompt.contains("/wt"), "{prompt}");
        assert!(prompt.contains("feedback/r1"), "{prompt}");
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
    fn successful_run_without_changes_needs_review_and_invokes_pi_with_omlx_model() {
        let (backend, temp) = fixture();
        queue_report(&backend, "r1", "bug", "crash on launch");
        git_repo(temp.path());
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
        assert_eq!(status, "needs-review");
        assert_eq!(attempts, 1);
        let result = result.unwrap();
        assert!(result.contains("pi exit 0"), "{result}");
        assert!(result.contains("no file changed"), "{result}");
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
        git_repo(temp.path());
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
        git_repo(temp.path());
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
        git_repo(temp.path());
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
        git_repo(temp.path());
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
        git_repo(temp.path());
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
        assert_eq!(status, "needs-review");
        assert_eq!(attempts, 2);
    }

    #[test]
    fn defer_records_power_wait_reason() {
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
        let (status, attempts, next_at, result) = report_status(&backend, "r1");
        assert_eq!(status, "queued");
        assert_eq!(attempts, 0);
        assert!(next_at > crate::db::now_unix());
        let result = result.unwrap();
        assert!(result.contains("waiting on power"), "{result}");
        assert!(result.contains("power_unplugged"), "{result}");
    }

    #[test]
    fn defer_records_memory_wait_reason() {
        let (backend, temp) = fixture();
        queue_report(&backend, "r1", "bug", "no memory");
        let _env = EnvGuard::apply(vec![(
            "PODS_FEEDBACK_REPO",
            Some(temp.path().to_string_lossy().into_owned()),
        )]);
        let mut memory = crate::memory_gate::TestMemory::default();
        memory.snapshot.available_bytes = 0;
        let dispatched = crate::memory_gate::with_test_memory(memory, || {
            crate::power_gate::with_test_power_status(
                crate::power_gate::PowerStatus::External,
                || step(&backend).unwrap(),
            )
        });
        assert!(!dispatched);
        let (_, _, _, result) = report_status(&backend, "r1");
        let result = result.unwrap();
        assert!(result.contains("waiting on memory"), "{result}");
        assert!(result.contains("memory_busy"), "{result}");
    }

    #[test]
    fn defer_records_omlx_wait_reason() {
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
        let (_, _, _, result) = report_status(&backend, "r1");
        assert!(result.unwrap().contains("waiting on omlx"));
    }

    #[test]
    fn pi_output_streams_to_per_report_log() {
        let (backend, temp) = fixture();
        queue_report(&backend, "r1", "feature", "dark mode");
        git_repo(temp.path());
        let pi = stub_pi(temp.path(), "echo err-line >&2; echo out-line; exit 0");
        let _env = EnvGuard::apply(vec![
            (
                "PODS_FEEDBACK_REPO",
                Some(temp.path().to_string_lossy().into_owned()),
            ),
            ("PODS_FEEDBACK_PI", Some(pi.to_string_lossy().into_owned())),
        ]);
        let dispatched = open_gates(|| with_lock(|| step(&backend).unwrap()));
        assert!(dispatched);
        let text = std::fs::read_to_string(backend.artifacts.url("feedback/r1.pi.log")).unwrap();
        assert!(text.contains("out-line"), "{text}");
        assert!(text.contains("err-line"), "{text}");
        let (status, _, _, result) = report_status(&backend, "r1");
        assert_eq!(status, "needs-review");
        let result = result.unwrap();
        assert!(result.contains("pi exit 0"), "{result}");
        assert!(result.contains("feedback/r1.pi.log"), "{result}");
    }

    #[test]
    fn invalid_report_id_requeues_without_dispatch() {
        let (backend, temp) = fixture();
        queue_report(&backend, "r../1", "feature", "dark mode");
        let _env = EnvGuard::apply(vec![(
            "PODS_FEEDBACK_REPO",
            Some(temp.path().to_string_lossy().into_owned()),
        )]);
        let dispatched = open_gates(|| with_lock(|| step(&backend).unwrap()));
        assert!(dispatched);
        let (status, attempts, next_at, result) = report_status(&backend, "r../1");
        assert_eq!(status, "queued");
        assert_eq!(attempts, 0);
        assert!(next_at > crate::db::now_unix());
        let result = result.unwrap();
        assert!(result.contains("worktree setup failed"), "{result}");
        assert!(result.contains("invalid report id"), "{result}");
    }

    #[test]
    fn log_summary_names_missing_log() {
        assert_eq!(log_summary(&None), "; log unavailable");
    }

    #[test]
    fn preempt_note_frees_the_attempt_and_names_power() {
        let (backend, _temp) = fixture();
        let now = crate::db::now_unix();
        backend
            .db
            .execute(
                "INSERT INTO browser_feedback(id,kind,body,device,client_id,created_at,status,attempts,started_at) VALUES('r1','bug','x','iPhone','client',?,'running',1,?)",
                params![now, now],
            )
            .unwrap();
        note_preempted(&backend, "r1", "; log feedback/r1.pi.log (10 bytes)").unwrap();
        let (status, attempts, next_at, result) = report_status(&backend, "r1");
        assert_eq!(status, "queued");
        assert_eq!(attempts, 0);
        assert!(next_at > crate::db::now_unix());
        let result = result.unwrap();
        assert!(result.contains("preempted"), "{result}");
        assert!(result.contains("feedback/r1.pi.log"), "{result}");
    }

    #[test]
    fn prompt_continues_prior_work_and_protects_the_gate() {
        let prompt = dispatch_prompt(Path::new("/wt"), "feedback/r1", "feature", "faster play");
        assert!(prompt.contains("feature request"), "{prompt}");
        assert!(prompt.contains("git status"), "{prompt}");
        assert!(prompt.contains("continue"), "{prompt}");
        assert!(prompt.contains("dev/check.sh"), "{prompt}");
        assert!(prompt.contains("never run dev/check.sh"), "{prompt}");
        assert!(prompt.contains("verifier rejects"), "{prompt}");
        assert!(prompt.contains("verified after you finish"), "{prompt}");
        assert!(prompt.contains("Do not commit"), "{prompt}");
    }

    fn git_branches(repo: &Path, pattern: &str) -> String {
        let output = Command::new("git")
            .arg("-C")
            .arg(repo)
            .args(["branch", "--list", pattern])
            .output()
            .expect("git binary");
        assert!(output.status.success());
        String::from_utf8_lossy(&output.stdout).into_owned()
    }

    #[test]
    fn dispatch_creates_isolated_worktree_and_runs_pi_inside() {
        let (backend, temp) = fixture();
        queue_report(&backend, "r1", "feature", "dark mode");
        git_repo(temp.path());
        let cwd_log = temp.path().join("cwd.log");
        let pi = stub_pi(temp.path(), &format!("pwd > '{}'; exit 0", cwd_log.display()));
        let _env = EnvGuard::apply(vec![
            (
                "PODS_FEEDBACK_REPO",
                Some(temp.path().to_string_lossy().into_owned()),
            ),
            ("PODS_FEEDBACK_PI", Some(pi.to_string_lossy().into_owned())),
        ]);
        let dispatched = open_gates(|| with_lock(|| step(&backend).unwrap()));
        assert!(dispatched);
        let tree = temp.path().join("feedback-worktrees").join("r1");
        assert!(tree.join(".git").exists(), "{}", tree.display());
        let cwd = std::fs::read_to_string(&cwd_log).unwrap();
        assert!(
            cwd.trim().ends_with("feedback-worktrees/r1"),
            "{cwd}"
        );
        assert!(git_branches(temp.path(), "feedback/r1").contains("feedback/r1"));
        let (status, _, _, result) = report_status(&backend, "r1");
        assert_eq!(status, "needs-review");
        let result = result.unwrap();
        assert!(result.contains("worktree"), "{result}");
        assert!(result.contains("feedback/r1"), "{result}");
    }

    #[test]
    fn retry_reuses_report_worktree_and_branch() {
        let (backend, temp) = fixture();
        queue_report(&backend, "r1", "feature", "dark mode");
        git_repo(temp.path());
        let pi = stub_pi(
            temp.path(),
            "if [ -f ran-once ]; then exit 0; else touch ran-once; exit 1; fi",
        );
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
                let (status, attempts, _, _) = report_status(&backend, "r1");
                assert_eq!(status, "queued");
                assert_eq!(attempts, 1);
                let tree = temp.path().join("feedback-worktrees").join("r1");
                assert!(tree.join("ran-once").is_file());
                backend
                    .db
                    .execute("UPDATE browser_feedback SET next_at=0 WHERE id='r1'", [])
                    .unwrap();
                assert!(step(&backend).unwrap());
                let (status, attempts, _, result) = report_status(&backend, "r1");
                assert_eq!(status, "ready");
                assert_eq!(attempts, 2);
                let result = result.unwrap();
                assert!(result.contains("1 file(s)"), "{result}");
                assert!(tree.join("ran-once").is_file());
            })
        });
        let branches = git_branches(temp.path(), "feedback/*");
        assert_eq!(branches.lines().count(), 1, "{branches}");
        assert!(branches.contains("feedback/r1"), "{branches}");
    }

    #[test]
    fn non_git_repo_requeues_without_dispatch() {
        let (backend, temp) = fixture();
        queue_report(&backend, "r1", "feature", "dark mode");
        let pi = stub_pi(temp.path(), "exit 0");
        let _env = EnvGuard::apply(vec![
            (
                "PODS_FEEDBACK_REPO",
                Some(temp.path().to_string_lossy().into_owned()),
            ),
            ("PODS_FEEDBACK_PI", Some(pi.to_string_lossy().into_owned())),
        ]);
        let dispatched = open_gates(|| with_lock(|| step(&backend).unwrap()));
        assert!(dispatched);
        let (status, attempts, next_at, result) = report_status(&backend, "r1");
        assert_eq!(status, "queued");
        assert_eq!(attempts, 0);
        assert!(next_at > crate::db::now_unix());
        let result = result.unwrap();
        assert!(result.contains("worktree setup failed"), "{result}");
        assert!(result.contains("not a git repository"), "{result}");
    }

    #[test]
    fn verify_protected_paths_cover_build_config() {
        for path in [
            "dev/check.sh",
            "dev/Dockerfile",
            "infra/deploy.sh",
            ".github/workflows/ci.yml",
            "client/scripts/check-coverage.mjs",
            "client/package.json",
            "client/package-lock.json",
            "client/vite.config.ts",
            "backend/Cargo.toml",
            "backend/Cargo.lock",
        ] {
            assert!(verify_protected_path(path), "{path}");
        }
        for path in [
            "client/src/player.tsx",
            "backend/src/feedback.rs",
            "docs/mac-backend.md",
            "AGENTS.md",
        ] {
            assert!(!verify_protected_path(path), "{path}");
        }
    }

    #[test]
    fn verify_marks_ready_when_client_gate_passes() {
        let (backend, temp) = fixture();
        queue_report(&backend, "r1", "feature", "dark mode");
        git_repo(temp.path());
        let args_log = temp.path().join("container-args.log");
        let pi = stub_pi(temp.path(), "mkdir -p client && echo x > client/note.txt && exit 0");
        let gate = stub_bin(
            temp.path(),
            "container-stub",
            &format!("echo \"$*\" >> '{}'\nexit 0", args_log.display()),
        );
        let _env = EnvGuard::apply(vec![
            (
                "PODS_FEEDBACK_REPO",
                Some(temp.path().to_string_lossy().into_owned()),
            ),
            ("PODS_FEEDBACK_PI", Some(pi.to_string_lossy().into_owned())),
            ("PODS_FEEDBACK_CONTAINER", Some(gate.to_string_lossy().into_owned())),
            // No backend/ file changed, so cargo must not run at all.
            ("PODS_FEEDBACK_CARGO", Some("/nonexistent-pods-cargo".to_string())),
        ]);
        let dispatched = open_gates(|| with_lock(|| step(&backend).unwrap()));
        assert!(dispatched);
        let (status, _, _, result) = report_status(&backend, "r1");
        assert_eq!(status, "ready");
        let result = result.unwrap();
        assert!(result.contains("verified: 1 file(s); client gate"), "{result}");
        let args = std::fs::read_to_string(&args_log).unwrap();
        assert!(args.contains("pods-dev-img"), "{args}");
        assert!(args.contains("npm run check"), "{args}");
        assert!(args.contains("/work/client/node_modules"), "{args}");
        // Only the client/ subtree is mounted into the container, never .git.
        assert!(!args.contains(":/work/.git"), "{args}");
    }

    #[test]
    fn verify_rejects_protected_path() {
        let (backend, temp) = fixture();
        queue_report(&backend, "r1", "feature", "dark mode");
        git_repo(temp.path());
        let pi = stub_pi(temp.path(), "mkdir -p client && echo x > client/package.json && exit 0");
        let _env = EnvGuard::apply(vec![
            (
                "PODS_FEEDBACK_REPO",
                Some(temp.path().to_string_lossy().into_owned()),
            ),
            ("PODS_FEEDBACK_PI", Some(pi.to_string_lossy().into_owned())),
            ("PODS_FEEDBACK_CARGO", Some("/nonexistent-pods-cargo".to_string())),
            ("PODS_FEEDBACK_CONTAINER", Some("/nonexistent-pods-container".to_string())),
        ]);
        let dispatched = open_gates(|| with_lock(|| step(&backend).unwrap()));
        assert!(dispatched);
        let (status, _, _, result) = report_status(&backend, "r1");
        assert_eq!(status, "needs-review");
        let result = result.unwrap();
        assert!(result.contains("protected path changed: client/package.json"), "{result}");
    }

    #[test]
    fn verify_backend_failure_needs_review_with_tail() {
        let (backend, temp) = fixture();
        queue_report(&backend, "r1", "bug", "crash on launch");
        git_repo(temp.path());
        let pi = stub_pi(temp.path(), "mkdir -p backend && echo x > backend/fix.rs && exit 0");
        let cargo = stub_bin(temp.path(), "cargo-stub", "echo boom >&2; exit 1");
        let _env = EnvGuard::apply(vec![
            (
                "PODS_FEEDBACK_REPO",
                Some(temp.path().to_string_lossy().into_owned()),
            ),
            ("PODS_FEEDBACK_PI", Some(pi.to_string_lossy().into_owned())),
            ("PODS_FEEDBACK_CARGO", Some(cargo.to_string_lossy().into_owned())),
            ("PODS_FEEDBACK_CONTAINER", Some("/nonexistent-pods-container".to_string())),
        ]);
        let dispatched = open_gates(|| with_lock(|| step(&backend).unwrap()));
        assert!(dispatched);
        let (status, _, _, result) = report_status(&backend, "r1");
        assert_eq!(status, "needs-review");
        let result = result.unwrap();
        assert!(result.contains("cargo test exit 1"), "{result}");
        assert!(result.contains("boom"), "{result}");
    }

    #[test]
    fn backfill_verifies_old_done_row_without_repo() {
        let (backend, temp) = fixture();
        git_repo(temp.path());
        let tree = temp.path().join("feedback-worktrees").join("r1");
        let dir_arg = tree.to_string_lossy().into_owned();
        let added = Command::new("git")
            .arg("-C")
            .arg(temp.path())
            .args(["worktree", "add", "-b", "feedback/r1", &dir_arg, "HEAD"])
            .status()
            .expect("git binary");
        assert!(added.success());
        std::fs::create_dir_all(tree.join("client")).unwrap();
        std::fs::write(tree.join("client/note.txt"), "x").unwrap();
        backend
            .db
            .execute(
                "INSERT INTO browser_feedback(id,kind,body,device,client_id,created_at,status,attempts) VALUES('r1','feature','dark mode','iPhone','client',?, 'done',1)",
                params![crate::db::now_unix()],
            )
            .unwrap();
        let gate = stub_bin(temp.path(), "container-stub", "exit 0");
        let _env = EnvGuard::apply(vec![
            ("PODS_FEEDBACK_REPO", None),
            ("PODS_FEEDBACK_CONTAINER", Some(gate.to_string_lossy().into_owned())),
            ("PODS_FEEDBACK_CARGO", Some("/nonexistent-pods-cargo".to_string())),
        ]);
        assert!(step(&backend).unwrap());
        let (status, _, _, result) = report_status(&backend, "r1");
        assert_eq!(status, "ready");
        let result = result.unwrap();
        assert!(result.contains("backfill verified"), "{result}");
    }

    #[test]
    fn backfill_missing_worktree_needs_review() {
        let (backend, _temp) = fixture();
        backend
            .db
            .execute(
                "INSERT INTO browser_feedback(id,kind,body,device,client_id,created_at,status,attempts) VALUES('r1','feature','dark mode','iPhone','client',?, 'done',1)",
                params![crate::db::now_unix()],
            )
            .unwrap();
        let _env = EnvGuard::apply(vec![("PODS_FEEDBACK_REPO", None)]);
        assert!(step(&backend).unwrap());
        let (status, _, _, result) = report_status(&backend, "r1");
        assert_eq!(status, "needs-review");
        let result = result.unwrap();
        assert!(result.contains("worktree is missing"), "{result}");
    }
}

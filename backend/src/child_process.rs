//! Bounded subprocess output, deadlines, and process-group cleanup.
use crate::Error;
#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::{
    io::Read,
    process::{Command, Output, Stdio},
    time::{Duration, Instant},
};
static ACTIVE: [std::sync::atomic::AtomicI32; 16] =
    [const { std::sync::atomic::AtomicI32::new(0) }; 16];

pub fn shutdown() {
    #[cfg(unix)]
    {
        for slot in &ACTIVE {
            let pid = slot.swap(0, std::sync::atomic::Ordering::SeqCst);
            if pid > 1 {
                unsafe {
                    libc::killpg(pid, libc::SIGKILL);
                }
            }
        }
    }
}
struct ChildGuard(std::process::Child);
impl Drop for ChildGuard {
    fn drop(&mut self) {
        if !matches!(self.0.try_wait(), Ok(Some(_))) {
            #[cfg(unix)]
            unsafe {
                libc::killpg(self.0.id() as i32, libc::SIGKILL);
            }
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
        for slot in &ACTIVE {
            let _ = slot.compare_exchange(
                self.0.id() as i32,
                0,
                std::sync::atomic::Ordering::SeqCst,
                std::sync::atomic::Ordering::SeqCst,
            );
        }
    }
}
fn collect(mut input: impl Read, cap: usize) -> Vec<u8> {
    let mut kept = Vec::new();
    let mut buf = [0; 8192];
    while let Ok(n) = input.read(&mut buf) {
        if n == 0 {
            break;
        }
        let available = cap.saturating_sub(kept.len());
        kept.extend_from_slice(&buf[..n.min(available)]);
    }
    kept
}
pub fn output(command: &mut Command, deadline: Duration) -> Result<Output, Error> {
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(unix)]
    command.process_group(0);
    let mut child = ChildGuard(
        command
            .spawn()
            .map_err(|_| Error::Upstream("tool failed to start".into()))?,
    );
    if !ACTIVE.iter().any(|slot| {
        slot.compare_exchange(
            0,
            child.0.id() as i32,
            std::sync::atomic::Ordering::SeqCst,
            std::sync::atomic::Ordering::SeqCst,
        )
        .is_ok()
    }) {
        return Err(Error::Upstream("tool capacity exceeded".into()));
    }
    let stdout = child.0.stdout.take().unwrap();
    let stderr = child.0.stderr.take().unwrap();
    let started = Instant::now();
    std::thread::scope(|scope| {
        let out = scope.spawn(|| collect(stdout, 8 * 1024 * 1024));
        let err = scope.spawn(|| collect(stderr, 64 * 1024));
        let result = loop {
            match child.0.try_wait() {
                Ok(Some(status)) => break Ok(status),
                Ok(None) if started.elapsed() < deadline => {
                    std::thread::sleep(Duration::from_millis(50))
                }
                Ok(None) => break Err(Error::Upstream("tool timeout".into())),
                Err(_) => break Err(Error::Upstream("tool wait failed".into())),
            }
        };
        // Close inherited pipes in descendants even if the direct child exited.
        #[cfg(unix)]
        unsafe {
            libc::killpg(child.0.id() as i32, libc::SIGKILL);
        }
        if result.is_err() {
            let _ = child.0.kill();
            let _ = child.0.wait();
        }
        let stdout = out.join().unwrap_or_default();
        let stderr = err.join().unwrap_or_default();
        Ok(Output {
            status: result?,
            stdout,
            stderr,
        })
    })
}
pub fn checked(command: &mut Command, seconds: u64, label: &str) -> Result<Output, Error> {
    let result = output(command, Duration::from_secs(seconds))?;
    if !result.status.success() {
        let raw = String::from_utf8_lossy(&result.stderr);
        // Classification occurs in memory; only allow-listed details leave this boundary.
        return Err(Error::Upstream(format!(
            "{label} exit={} {} code={}",
            result.status.code().unwrap_or(-1),
            crate::reliability::safe_detail(&raw),
            crate::reliability::error_code(&raw)
        )));
    }
    Ok(result)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn deadline_kills_and_reaps_process_group() {
        let started = Instant::now();
        let result = output(
            Command::new("/bin/sh").args(["-c", "sleep 30 & wait"]),
            Duration::from_millis(100),
        );
        assert!(result.unwrap_err().to_string().contains("timeout"));
        assert!(started.elapsed() < Duration::from_secs(3));
    }
    #[test]
    fn diagnostics_do_not_leak_stderr() {
        let error = checked(
            Command::new("/bin/sh").args([
                "-c",
                "echo 'HTTP 403 https://secret.example/?token=hidden' >&2; exit 7",
            ]),
            2,
            "download",
        )
        .unwrap_err()
        .to_string();
        assert!(error.contains("403"));
        assert!(error.contains("exit=7"));
        assert!(!error.contains("hidden"));
    }
}

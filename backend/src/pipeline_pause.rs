//! User-controlled pause of local inference work.
//!
//! The Mac menu-bar companion writes `pipeline-pause.json` in the Pods state
//! directory when Matt turns pause on. While that file holds a live pause,
//! local Whisper, classification, and show-notes acquisition refuse to start.
//! Downloads, HTTP, sync, speaker, and rendering are not paused.
//!
//! The pause is bounded: `pause_until` is `paused_at + PAUSE_LIMIT_SECS`. Both
//! the menu app and this gate treat an expired pause as off, so a forgotten
//! toggle cannot stop the pipeline for more than four hours.
//!
//! No new crates. Serde is already a dependency.

use crate::error::Error;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub const PIPELINE_PAUSED: &str = "pipeline_paused";
/// The maximum length of a single pause: four hours.
pub const PAUSE_LIMIT_SECS: i64 = 4 * 60 * 60;
/// How long a paused job waits before the worker re-checks the toggle.
pub const RETRY_SECS: i64 = 60;
pub const FILE_NAME: &str = "pipeline-pause.json";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PauseState {
    pub paused_at: i64,
    pub pause_until: i64,
}

impl PauseState {
    pub fn new(paused_at: i64) -> Self {
        Self {
            paused_at,
            pause_until: paused_at.saturating_add(PAUSE_LIMIT_SECS),
        }
    }

    pub fn active(self, now: i64) -> bool {
        now < self.pause_until
    }

    pub fn remaining(self, now: i64) -> i64 {
        (self.pause_until - now).max(0)
    }
}

/// Strictly parse the on-disk pause. A pause that ends before it starts is
/// corrupt and treated as off rather than as an unbounded pause.
pub fn parse_state(raw: &str) -> Option<PauseState> {
    let state: PauseState = serde_json::from_str(raw).ok()?;
    if state.pause_until <= state.paused_at {
        return None;
    }
    Some(state)
}

pub fn state_path() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os("PODS_STATE_DIR") {
        if !dir.is_empty() {
            return Some(PathBuf::from(dir).join(FILE_NAME));
        }
    }
    let home = std::env::var_os("HOME")?;
    Some(PathBuf::from(home).join(".local/share/pods").join(FILE_NAME))
}

pub fn read_state(path: &Path) -> Option<PauseState> {
    parse_state(&std::fs::read_to_string(path).ok()?)
}

pub fn is_paused_at(path: &Path, now: i64) -> bool {
    read_state(path).is_some_and(|state| state.active(now))
}

/// True while the menu-bar pause is live. Expired or missing state is off.
pub fn is_paused(now: i64) -> bool {
    #[cfg(test)]
    if let Some(paused) = TEST_PAUSED.with(|cell| cell.get()) {
        return paused;
    }
    state_path().is_some_and(|path| is_paused_at(&path, now))
}

pub fn require_not_paused() -> Result<(), Error> {
    if is_paused(crate::db::now_unix()) {
        return Err(Error::Upstream(PIPELINE_PAUSED.into()));
    }
    Ok(())
}

pub fn is_paused_error(error: &Error) -> bool {
    error.to_string() == PIPELINE_PAUSED
}

#[cfg(test)]
thread_local! {
    static TEST_PAUSED: std::cell::Cell<Option<bool>> = const { std::cell::Cell::new(None) };
}

#[cfg(test)]
pub fn with_test_paused<T>(paused: Option<bool>, work: impl FnOnce() -> T) -> T {
    TEST_PAUSED.with(|cell| {
        let previous = cell.replace(paused);
        struct Restore(Option<bool>);
        impl Drop for Restore {
            fn drop(&mut self) {
                TEST_PAUSED.with(|cell| cell.set(self.0));
            }
        }
        let _restore = Restore(previous);
        work()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_round_trips_and_marks_active_until_the_deadline() {
        let state = PauseState::new(1_000);
        assert_eq!(state.pause_until, 1_000 + PAUSE_LIMIT_SECS);
        assert_eq!(PAUSE_LIMIT_SECS, 14_400);
        assert!(state.active(1_000));
        assert!(state.active(state.pause_until - 1));
        assert!(!state.active(state.pause_until));
        assert_eq!(state.remaining(1_000), PAUSE_LIMIT_SECS);
        assert_eq!(state.remaining(state.pause_until + 500), 0);
        let encoded = serde_json::to_string(&state).unwrap();
        assert_eq!(parse_state(&encoded), Some(state));
        assert!(encoded.contains("\"paused_at\""));
        assert!(encoded.contains("\"pause_until\""));
    }

    #[test]
    fn parse_rejects_corrupt_or_inverted_state() {
        assert!(parse_state("").is_none());
        assert!(parse_state("not json").is_none());
        assert!(parse_state(r#"{"paused_at":10}"#).is_none());
        assert!(parse_state(r#"{"paused_at":10,"pause_until":10}"#).is_none());
        assert!(parse_state(r#"{"paused_at":10,"pause_until":9}"#).is_none());
        assert_eq!(
            parse_state(r#"{"paused_at":10,"pause_until":20}"#),
            Some(PauseState {
                paused_at: 10,
                pause_until: 20
            })
        );
    }

    #[test]
    fn is_paused_at_reads_the_file_and_expires() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(FILE_NAME);
        assert!(!is_paused_at(&path, 1_000));
        let state = PauseState::new(1_000);
        std::fs::write(&path, serde_json::to_vec(&state).unwrap()).unwrap();
        assert!(is_paused_at(&path, 1_000));
        assert!(is_paused_at(&path, state.pause_until - 1));
        assert!(!is_paused_at(&path, state.pause_until));
        std::fs::write(&path, b"garbage").unwrap();
        assert!(!is_paused_at(&path, 1_000));
    }

    #[test]
    fn require_not_paused_reports_a_distinct_error() {
        with_test_paused(Some(true), || {
            let error = require_not_paused().unwrap_err();
            assert_eq!(error.to_string(), PIPELINE_PAUSED);
            assert!(is_paused_error(&error));
        });
        with_test_paused(Some(false), || {
            require_not_paused().unwrap();
            assert!(!is_paused_error(&Error::Upstream("other".into())));
        });
    }
}

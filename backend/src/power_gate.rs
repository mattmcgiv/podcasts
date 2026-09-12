//! External-power gate for Mac inference.
//!
//! Pods starts local Whisper and oMLX requests only while macOS reports an
//! external power source. A missing or unparseable power sample fails closed:
//! it is safer to wait than to drain the MacBook unexpectedly.

use crate::error::Error;

pub const POWER_UNPLUGGED: &str = "power_unplugged";
pub const POWER_STATUS_UNAVAILABLE: &str = "power_status_unavailable";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PowerStatus {
    External,
    Battery,
    Unavailable,
}

pub fn require_external_power() -> Result<(), Error> {
    match power_status() {
        PowerStatus::External => Ok(()),
        PowerStatus::Battery => Err(Error::Upstream(POWER_UNPLUGGED.into())),
        PowerStatus::Unavailable => Err(Error::Upstream(POWER_STATUS_UNAVAILABLE.into())),
    }
}

pub fn is_power_error(error: &Error) -> bool {
    matches!(
        error.to_string().as_str(),
        POWER_UNPLUGGED | POWER_STATUS_UNAVAILABLE
    )
}

fn power_status() -> PowerStatus {
    #[cfg(test)]
    {
        if let Some(status) = TEST_POWER_STATUS.with(|cell| cell.get()) {
            return status;
        }
        return PowerStatus::External;
    }
    #[cfg(all(not(test), target_os = "macos"))]
    {
        live_power_status()
    }
    #[cfg(all(not(test), not(target_os = "macos")))]
    {
        // Pods' local inference runner is macOS-only. Keep non-Mac builds
        // usable for development rather than pretending they have a battery.
        PowerStatus::External
    }
}

#[cfg(all(not(test), target_os = "macos"))]
fn live_power_status() -> PowerStatus {
    let output = match std::process::Command::new("/usr/bin/pmset")
        .args(["-g", "batt"])
        .output()
    {
        Ok(output) if output.status.success() => output,
        _ => return PowerStatus::Unavailable,
    };
    parse_pmset_power(&String::from_utf8_lossy(&output.stdout))
}

#[cfg(any(test, target_os = "macos"))]
fn parse_pmset_power(output: &str) -> PowerStatus {
    let Some(source) = output
        .lines()
        .find_map(|line| line.trim().strip_prefix("Now drawing from '"))
        .and_then(|line| line.split_once('\'').map(|(source, _)| source))
    else {
        return PowerStatus::Unavailable;
    };
    match source {
        "AC Power" | "UPS Power" => PowerStatus::External,
        "Battery Power" => PowerStatus::Battery,
        _ => PowerStatus::Unavailable,
    }
}

#[cfg(test)]
thread_local! {
    static TEST_POWER_STATUS: std::cell::Cell<Option<PowerStatus>> = const { std::cell::Cell::new(None) };
}

#[cfg(test)]
pub fn with_test_power_status<T>(status: PowerStatus, work: impl FnOnce() -> T) -> T {
    TEST_POWER_STATUS.with(|cell| {
        let previous = cell.replace(Some(status));
        struct Restore(Option<PowerStatus>);
        impl Drop for Restore {
            fn drop(&mut self) {
                TEST_POWER_STATUS.with(|cell| cell.set(self.0));
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
    fn parses_pmset_sources_and_fails_closed_for_unknown_output() {
        assert_eq!(
            parse_pmset_power("Now drawing from 'AC Power'\n"),
            PowerStatus::External
        );
        assert_eq!(
            parse_pmset_power("Now drawing from 'UPS Power'\n"),
            PowerStatus::External
        );
        assert_eq!(
            parse_pmset_power("Now drawing from 'Battery Power'\n"),
            PowerStatus::Battery
        );
        assert_eq!(
            parse_pmset_power("pmset unavailable"),
            PowerStatus::Unavailable
        );
    }

    #[test]
    fn inference_requires_external_power() {
        with_test_power_status(PowerStatus::External, || require_external_power().unwrap());
        with_test_power_status(PowerStatus::Battery, || {
            let error = require_external_power().unwrap_err();
            assert_eq!(error.to_string(), POWER_UNPLUGGED);
            assert!(is_power_error(&error));
        });
        with_test_power_status(PowerStatus::Unavailable, || {
            let error = require_external_power().unwrap_err();
            assert_eq!(error.to_string(), POWER_STATUS_UNAVAILABLE);
            assert!(is_power_error(&error));
        });
    }
}

use crate::models::RefreshStatus;

pub const AUTOMATIC_INTERVAL: i64 = 12 * 60 * 60;
pub const RETRY_INTERVAL: i64 = 2 * 60 * 60;

pub fn is_foreground_refresh_due(status: &RefreshStatus, now: i64) -> bool {
    if status.last_errors > 0 {
        if let Some(last_attempt) = status.last_attempt_at {
            return now >= last_attempt + RETRY_INTERVAL;
        }
    }
    match status.last_success_at {
        None => true,
        Some(last_success) => now >= last_success + AUTOMATIC_INTERVAL,
    }
}

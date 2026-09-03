use pods_backend::backend::Backend;
use pods_backend::db::Database;
use pods_backend::feeds::MockFeedFetcher;
use pods_backend::models::RefreshStatus;
use pods_backend::refresh;
use pods_backend::server;
use pods_backend::DisabledDirectory;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::sync::Arc;
use std::time::Duration;

fn get_recent(addr: &str) -> (u16, String) {
    let mut stream = TcpStream::connect(addr).expect("connect");
    stream
        .write_all(b"GET /api/recent HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
        .unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
    let mut buf = String::new();
    stream.read_to_string(&mut buf).unwrap();
    let status = buf
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let body = buf.split("\r\n\r\n").nth(1).unwrap_or("").to_string();
    (status, body)
}

#[test]
fn test_local_server_serves_http() {
    let db = Database::open_in_memory().unwrap();
    let backend = Arc::new(Backend::new(
        db,
        Arc::new(MockFeedFetcher::default()),
        Arc::new(DisabledDirectory),
    ));
    let listener = server::serve(backend, "127.0.0.1:0").expect("listen");
    let addr = listener.local_addr().unwrap().to_string();
    let (status, body) = get_recent(&addr);
    assert_eq!(status, 200);
    let value: serde_json::Value = serde_json::from_str(&body).expect("json");
    assert!(value.get("items").and_then(|v| v.as_array()).is_some());
    assert!(value.get("next_offset").is_some());
}

#[test]
fn test_refresh_policy_requests_at_most_one_automatic_pass_every_twelve_hours() {
    let status = RefreshStatus {
        last_attempt_at: Some(1_000_000),
        last_success_at: Some(1_000_000),
        last_source: Some("foreground".into()),
        last_refreshed: 1,
        last_errors: 0,
        is_refreshing: None,
    };
    assert!(!refresh::is_foreground_refresh_due(&status, 1_000_000 + 11 * 3600));
    assert!(refresh::is_foreground_refresh_due(&status, 1_000_000 + 12 * 3600));
}

#[test]
fn test_refresh_policy_backs_off_for_two_hours_after_an_automatic_failure() {
    let status = RefreshStatus {
        last_attempt_at: Some(1_000),
        last_success_at: None,
        last_source: Some("foreground".into()),
        last_refreshed: 0,
        last_errors: 1,
        is_refreshing: None,
    };
    assert!(!refresh::is_foreground_refresh_due(&status, 1_000 + 100));
    assert!(refresh::is_foreground_refresh_due(&status, 1_000 + 2 * 3600));
}

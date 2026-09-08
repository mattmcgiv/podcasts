//! Loopback HTTP tests for authenticated Mac speaker control.
use pods_backend::browser::Manifest;
use pods_backend::http::HttpRequest;
use pods_backend::speaker::MemoryTransport;
use pods_backend::{server, Backend, Database, DisabledDirectory, MockFeedFetcher};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::io::{Read, Write};
use std::net::TcpStream;
use std::sync::Arc;
use std::time::Duration;

fn fixture() -> (Backend, tempfile::TempDir, Manifest, Arc<MemoryTransport>) {
    let temp = tempfile::tempdir().unwrap();
    let db = Database::open_in_memory().unwrap();
    db.execute(
        "INSERT INTO podcasts(id,feed_url,title,created_at) VALUES(1,'https://example.org/feed','Example',0)",
        [],
    )
    .unwrap();
    for id in [1, 2] {
        db.execute(
            "INSERT INTO episodes(id,podcast_id,guid,title,audio_url,published_at) VALUES(?,1,?,'Episode','https://example.org/original.mp3',?)",
            rusqlite::params![id, id.to_string(), id],
        )
        .unwrap();
    }
    let mut backend = Backend::with_data_root(
        db,
        Arc::new(MockFeedFetcher::default()),
        Arc::new(DisabledDirectory),
        Some(temp.path().to_owned()),
    );
    backend.local = true;
    let bytes = b"abcdefgh";
    let hash = hex::encode(Sha256::digest(bytes));
    backend
        .artifacts
        .install(&format!("published/{hash}.m4a"), bytes)
        .unwrap();
    let manifest = Manifest {
        version: 1,
        episode_id: 1,
        hash: hash.clone(),
        source_hash: "source".into(),
        bytes: 8,
        duration: 15.0,
        chunk_size: 1024 * 1024,
        chunks: vec![hash],
        timeline: vec![pods_backend::browser::Interval {
            original_start: 0.0,
            original_end: 15.0,
            processed_start: 0.0,
        }],
        model: "local".into(),
        pipeline_version: "v1".into(),
    };
    backend
        .db
        .execute(
            "INSERT INTO browser_publications VALUES(?,?,'[]',0)",
            rusqlite::params![1, json!(manifest).to_string()],
        )
        .unwrap();
    let memory = Arc::new(MemoryTransport::default());
    memory.set_duration(15.0);
    backend.set_speaker_transport(memory.clone());
    (backend, temp, manifest, memory)
}

fn cookie_pair(set_cookie: &str) -> String {
    set_cookie.split(';').next().unwrap().trim().to_string()
}

fn enroll_scripted_session(backend: &mut Backend) -> String {
    let local = backend.local;
    backend.local = false;
    let reset = backend.handle(
        HttpRequest::new("POST", "/api/internal/passkey-reset")
            .with_header("x-pods-reset-key", "test-reset-secret"),
    );
    assert_eq!(reset.status_code, 200);
    let body: Value = serde_json::from_slice(&reset.body).unwrap();
    let token = body["enroll_url"]
        .as_str()
        .unwrap()
        .split("#enroll=")
        .nth(1)
        .unwrap();
    let options = backend.handle(
        HttpRequest::new("POST", "/api/auth/register/options").with_json(&json!({ "token": token })),
    );
    assert_eq!(options.status_code, 200);
    let options_body: Value = serde_json::from_slice(&options.body).unwrap();
    let registered = backend.handle(HttpRequest::new("POST", "/api/auth/register").with_json(
        &json!({
            "state_id": options_body["state_id"],
            "credential": { "id": "cred-1" }
        }),
    ));
    assert_eq!(registered.status_code, 201);
    backend.local = local;
    cookie_pair(registered.headers.get("set-cookie").unwrap())
}

fn tcp_exchange(addr: &str, raw: &str) -> Vec<u8> {
    let mut stream = TcpStream::connect(addr).expect("connect");
    stream.write_all(raw.as_bytes()).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    let mut buf = Vec::new();
    stream.read_to_end(&mut buf).unwrap();
    buf
}

fn tcp_status_line(raw: &[u8]) -> &str {
    std::str::from_utf8(raw)
        .unwrap()
        .split("\r\n")
        .next()
        .unwrap()
}

fn tcp_body(raw: &[u8]) -> &str {
    let text = std::str::from_utf8(raw).unwrap();
    text.split("\r\n\r\n").nth(1).unwrap_or("")
}

fn post_json(method: &str, path: &str, cookie: &str, origin: &str, body: &str) -> String {
    format!(
        "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: {origin}\r\nCookie: {cookie}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )
}

#[test]
fn speaker_requires_session_and_trusted_origin() {
    let (mut backend, _temp, _, _) = fixture();
    backend
        .auth
        .enable_passkey("test-reset-secret", "https://pods.mcgiv.dev");
    let cookie = enroll_scripted_session(&mut backend);
    let listener = server::serve(Arc::new(backend), "127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap().to_string();

    let missing = tcp_exchange(
        &addr,
        "GET /api/speaker/status HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
    );
    assert_eq!(tcp_status_line(&missing), "HTTP/1.1 401 Unauthorized");

    let evil = tcp_exchange(
        &addr,
        &format!(
            "GET /api/speaker/status HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: https://evil.example\r\nCookie: {cookie}\r\nConnection: close\r\n\r\n"
        ),
    );
    assert_eq!(tcp_status_line(&evil), "HTTP/1.1 403 Forbidden");

    let ok = tcp_exchange(
        &addr,
        &format!(
            "GET /api/speaker/status HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: https://pods.mcgiv.dev\r\nCookie: {cookie}\r\nConnection: close\r\n\r\n"
        ),
    );
    assert_eq!(tcp_status_line(&ok), "HTTP/1.1 200 OK");
    let body: Value = serde_json::from_str(tcp_body(&ok)).unwrap();
    assert_eq!(body["available"], true);
    assert_eq!(body["connected"], false);
    let dump = tcp_body(&ok);
    assert!(!dump.contains("/Users/"));
    assert!(!dump.contains("published/"));
    assert!(!dump.contains(cookie.split('=').nth(1).unwrap_or("pods_session")));
}

#[test]
fn speaker_options_matches_browser_cors_contract() {
    let (backend, _temp, _, _) = fixture();
    let rejected = backend.handle(
        HttpRequest::new("OPTIONS", "/api/speaker/status")
            .with_header("origin", "https://evil.example"),
    );
    assert_eq!(rejected.status_code, 403);
    let accepted = backend.handle(
        HttpRequest::new("OPTIONS", "/api/speaker/load")
            .with_header("origin", "https://pods.mcgiv.dev"),
    );
    assert_eq!(accepted.status_code, 204);
    assert_eq!(accepted.headers["access-control-allow-origin"], "https://pods.mcgiv.dev");
    assert_eq!(accepted.headers["access-control-allow-credentials"], "true");
}

#[test]
fn speaker_http_load_is_processed_media_only_and_controls_identity() {
    let (mut backend, _temp, manifest, memory) = fixture();
    backend
        .auth
        .enable_passkey("test-reset-secret", "https://pods.mcgiv.dev");
    let cookie = enroll_scripted_session(&mut backend);
    let listener = server::serve(Arc::new(backend), "127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap().to_string();
    let origin = "https://pods.mcgiv.dev";

    let remote = tcp_exchange(
        &addr,
        &post_json(
            "POST",
            "/api/speaker/load",
            &cookie,
            origin,
            &json!({
                "episode_id": 1,
                "session_id": "sess-a",
                "generation": 0,
                "artifact_hash": manifest.hash,
                "url": "https://cdn.example/ep.mp3"
            })
            .to_string(),
        ),
    );
    assert_eq!(tcp_status_line(&remote), "HTTP/1.1 422 Unprocessable Entity");
    assert!(memory.last_path().is_none());

    let unpublished = tcp_exchange(
        &addr,
        &post_json(
            "POST",
            "/api/speaker/load",
            &cookie,
            origin,
            &json!({
                "episode_id": 2,
                "session_id": "sess-a",
                "generation": 0,
                "artifact_hash": manifest.hash
            })
            .to_string(),
        ),
    );
    assert_eq!(tcp_status_line(&unpublished), "HTTP/1.1 404 Not Found");

    let mismatch = tcp_exchange(
        &addr,
        &post_json(
            "POST",
            "/api/speaker/load",
            &cookie,
            origin,
            &json!({
                "episode_id": 1,
                "session_id": "sess-a",
                "generation": 0,
                "artifact_hash": "ab".repeat(32)
            })
            .to_string(),
        ),
    );
    assert_eq!(tcp_status_line(&mismatch), "HTTP/1.1 409 Conflict");
    assert!(tcp_body(&mismatch).contains("Synchronize"));

    let loaded = tcp_exchange(
        &addr,
        &post_json(
            "POST",
            "/api/speaker/load",
            &cookie,
            origin,
            &json!({
                "episode_id": 1,
                "session_id": "sess-a",
                "generation": 0,
                "artifact_hash": manifest.hash,
                "position": 2.5,
                "rate": 1.5,
                "playing": true
            })
            .to_string(),
        ),
    );
    assert_eq!(tcp_status_line(&loaded), "HTTP/1.1 200 OK");
    let body: Value = serde_json::from_str(tcp_body(&loaded)).unwrap();
    assert_eq!(body["episode_id"], 1);
    assert_eq!(body["connected"], true);
    assert_eq!(body["paused"], false);
    assert_eq!(body["session_id"], "sess-a");
    let generation = body["generation"].as_u64().unwrap();
    let path = memory.last_path().unwrap();
    assert!(path.ends_with(format!("{}.m4a", manifest.hash)));
    assert!(path.to_string_lossy().contains("published"));
    assert!(!tcp_body(&loaded).contains("published/"));
    assert!(!tcp_body(&loaded).contains("/Users/"));
    assert_eq!(body["artifact_hash"], manifest.hash);

    let stale = tcp_exchange(
        &addr,
        &post_json(
            "POST",
            "/api/speaker/pause",
            &cookie,
            origin,
            &json!({"session_id": "sess-a", "generation": 0}).to_string(),
        ),
    );
    assert_eq!(tcp_status_line(&stale), "HTTP/1.1 409 Conflict");

    let other = tcp_exchange(
        &addr,
        &post_json(
            "POST",
            "/api/speaker/pause",
            &cookie,
            origin,
            &json!({"session_id": "sess-other", "generation": generation}).to_string(),
        ),
    );
    assert_eq!(tcp_status_line(&other), "HTTP/1.1 409 Conflict");

    let pause = tcp_exchange(
        &addr,
        &post_json(
            "POST",
            "/api/speaker/pause",
            &cookie,
            origin,
            &json!({"session_id": "sess-a", "generation": generation}).to_string(),
        ),
    );
    assert_eq!(tcp_status_line(&pause), "HTTP/1.1 200 OK");
    assert_eq!(serde_json::from_str::<Value>(tcp_body(&pause)).unwrap()["paused"], true);

    let seek = tcp_exchange(
        &addr,
        &post_json(
            "POST",
            "/api/speaker/seek",
            &cookie,
            origin,
            &json!({"session_id": "sess-a", "generation": generation, "seconds": 6.0}).to_string(),
        ),
    );
    assert_eq!(
        serde_json::from_str::<Value>(tcp_body(&seek)).unwrap()["position"],
        6.0
    );

    let takeover = tcp_exchange(
        &addr,
        &post_json(
            "POST",
            "/api/speaker/load",
            &cookie,
            origin,
            &json!({
                "episode_id": 1,
                "session_id": "sess-b",
                "generation": generation,
                "artifact_hash": manifest.hash,
                "position": 1.0
            })
            .to_string(),
        ),
    );
    assert_eq!(tcp_status_line(&takeover), "HTTP/1.1 200 OK");
    let takeover_body: Value = serde_json::from_str(tcp_body(&takeover)).unwrap();
    assert_eq!(takeover_body["session_id"], "sess-b");
    let play_old = tcp_exchange(
        &addr,
        &post_json(
            "POST",
            "/api/speaker/play",
            &cookie,
            origin,
            &json!({"session_id": "sess-a", "generation": generation}).to_string(),
        ),
    );
    assert_eq!(tcp_status_line(&play_old), "HTTP/1.1 409 Conflict");

    let disconnect = tcp_exchange(
        &addr,
        &post_json(
            "POST",
            "/api/speaker/disconnect",
            &cookie,
            origin,
            &json!({
                "session_id": "sess-b",
                "generation": takeover_body["generation"]
            })
            .to_string(),
        ),
    );
    assert_eq!(tcp_status_line(&disconnect), "HTTP/1.1 200 OK");
    assert_eq!(
        serde_json::from_str::<Value>(tcp_body(&disconnect)).unwrap()["connected"],
        false
    );
    assert!(memory.stopped());
}

#[test]
fn speaker_errors_do_not_include_filesystem_paths() {
    let (backend, _temp, manifest, _) = fixture();
    backend.set_speaker_transport(Arc::new(pods_backend::speaker::UnavailableTransport));
    let load = backend.handle(
        HttpRequest::new("POST", "/api/speaker/load").with_json(&json!({
            "episode_id": 1,
            "session_id": "sess-a",
            "generation": 0,
            "artifact_hash": manifest.hash
        })),
    );
    assert_eq!(load.status_code, 422);
    let body = String::from_utf8_lossy(&load.body);
    assert!(!body.contains("/Users/"));
    assert!(!body.contains("/private/"));
    assert!(!body.contains(".m4a"));
    assert!(body.contains("Mac speaker is not available on this computer."));
}

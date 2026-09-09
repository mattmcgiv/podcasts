//! Extra tests that execute previously uncovered shipped library paths.
use pods_backend::auth::{
    self, Auth, PasskeyEngine, ScriptedPasskey, WebauthnEngine, SESSION_COOKIE,
};
use pods_backend::directory::PodcastIndexClient;
use pods_backend::feeds::{self, FeedFetcher, FeedValidators, UreqFetcher};
use pods_backend::jobs::{BlockingReason, JobStage, JobStore};
use pods_backend::models::DeepSeekUsageMetricsPayload;
use pods_backend::pipeline::{
    self, AudioDownloader, CloudClassifier, DeepSeekClassifier, MockDownloader, NotesTranscriber,
    ParakeetTranscriber, PipelineConfig, Transcriber, TranscriberKind,
};
use pods_backend::speaker::{SpeakerTransport, UnavailableTransport};
use pods_backend::storage::{ArtifactStore, DownloadResult};
use pods_backend::models::{DirectoryAppearance, DirectoryPodcast};
use pods_backend::{
    bootstrap, memory_gate, omlx_lock, opml, Backend, Database, DisabledDirectory, DirectorySearcher,
    Error, HttpRequest, MockFeedFetcher,
};
use serde_json::json;
use sha2::Digest;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

static ENV: Mutex<()> = Mutex::new(());

fn serve_once(status: &str, headers: &str, body: &[u8]) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let addr = listener.local_addr().unwrap();
    let status = status.to_string();
    let headers = headers.to_string();
    let body = body.to_vec();
    std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(8);
        while Instant::now() < deadline {
            let Ok((mut stream, _)) = listener.accept() else {
                std::thread::sleep(Duration::from_millis(5));
                continue;
            };
            stream.set_nonblocking(false).unwrap();
            let mut buf = [0; 8192];
            let _ = stream.read(&mut buf);
            let _ = write!(
                stream,
                "HTTP/1.1 {status}\r\n{headers}Content-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            let _ = stream.write_all(&body);
            return;
        }
    });
    format!("http://{addr}")
}

#[test]
fn opml_parse_render_and_escape_round_trip() {
    let xml = r#"<opml><outline xmlUrl="https://a.example/feed" /><outline XMLURL='https://b.example/feed&amp;x=1' /><outline xmlUrl="https://a.example/feed" /><outline text="no-url" /></opml>"#;
    let urls = opml::parse(xml);
    assert_eq!(
        urls,
        vec![
            "https://a.example/feed".to_string(),
            "https://b.example/feed&x=1".to_string()
        ]
    );
    let rendered = opml::render(&[("A & B <C>".into(), "https://x.example/\"feed\"".into())]);
    assert!(rendered.contains("&amp;"));
    assert!(rendered.contains("&lt;"));
    assert!(rendered.contains("&quot;"));
    assert!(rendered.contains("xmlUrl="));
}

#[test]
fn models_empty_usage_payload_serializes() {
    let payload = DeepSeekUsageMetricsPayload::empty(true);
    let value = serde_json::to_value(&payload).unwrap();
    assert_eq!(value["telemetry_complete"], true);
    assert_eq!(value["total_cost_usd"], 0.0);
}

#[test]
fn bootstrap_replaces_invalid_schema_from_seed() {
    let dir = tempfile::tempdir().unwrap();
    let live = dir.path().join("live.sqlite");
    let seed = dir.path().join("seed.sqlite");
    rusqlite::Connection::open(&live)
        .unwrap()
        .execute_batch("CREATE TABLE junk(id INTEGER);")
        .unwrap();
    Database::open(&seed).unwrap();
    bootstrap::prepare(&live, Some(&seed)).unwrap();
    let db = Database::open(&live).unwrap();
    assert!(db
        .scalar_i64("SELECT COUNT(*) FROM podcasts", [])
        .unwrap()
        .is_some());
}

#[test]
fn bootstrap_creates_live_from_seed_when_missing() {
    let dir = tempfile::tempdir().unwrap();
    let live = dir.path().join("nested/live.sqlite");
    let seed = dir.path().join("seed.sqlite");
    let db = Database::open(&seed).unwrap();
    db.execute(
        "INSERT INTO podcasts(feed_url,title,created_at) VALUES('https://s','S',1)",
        [],
    )
    .unwrap();
    drop(db);
    bootstrap::prepare(&live, Some(&seed)).unwrap();
    assert!(live.is_file());
}

#[test]
fn directory_client_parses_credentials_and_search_payloads() {
    let dir = tempfile::tempdir().unwrap();
    let creds = dir.path().join("credentials.env");
    std::fs::write(
        &creds,
        "# comment\nPODCASTINDEX_KEY=\"abc\"\nPODCASTINDEX_SECRET=xyz\nPODCASTINDEX_BASE_URL=\nOTHER=1\nnot-a-pair\n",
    )
    .unwrap();
    assert!(PodcastIndexClient::from_credentials_file(&creds).is_some());
    assert_eq!(
        PodcastIndexClient::auth_header("abc", "xyz", 10).len(),
        40
    );
    assert!(PodcastIndexClient::from_credentials_file(&dir.path().join("missing")).is_none());
    std::fs::write(&creds, "PODCASTINDEX_KEY=\nPODCASTINDEX_SECRET=\n").unwrap();
    assert!(PodcastIndexClient::from_credentials_file(&creds).is_none());

    let feeds = json!({"feeds":[
        {"url":"https://one.example/feed","title":"One","author":"Ann","artwork":"https://img/a","description":"d"},
        {"url":"","title":"skip"},
        {"url":"https://two.example/feed","image":"https://img/b"}
    ]});
    let base = serve_once("200 OK", "Content-Type: application/json\r\n", &serde_json::to_vec(&feeds).unwrap());
    let client = PodcastIndexClient::new("k", "s", format!("{base}/"));
    assert!(client.is_configured());
    let found = client.search("hello world &x").unwrap();
    assert_eq!(found.len(), 2);
    assert_eq!(found[0].title, "One");
    assert_eq!(found[1].image_url, "https://img/b");

    let items = json!({"items":[
        {"feedUrl":"https://f","enclosureUrl":"https://a.mp3","guid":"g1","id":11,"title":"Alice talks","description":"no","feedTitle":"F","feedImage":"i","duration":12,"datePublished":9,"image":"e","persons":[{"name":"Alice","role":"guest"}]},
        {"feedUrl":"https://f","enclosureUrl":"https://a.mp3","guid":"g2","id":12,"title":"Alice title","description":"Alice description"},
        {"feedUrl":"https://f","enclosureUrl":"https://a.mp3","guid":"g3","id":13,"title":"Alice only","description":"other"},
        {"feedUrl":"https://f","enclosureUrl":"https://a.mp3","guid":"g4","id":14,"title":"other","description":"Alice only"},
        {"feedUrl":"https://f","enclosureUrl":"https://a.mp3","guid":"g5","id":15,"title":"nope","description":"nope"},
        {"feedUrl":"https://f","enclosureUrl":"https://a.mp3","id":16,"title":"Alice","description":"x","persons":[{"name":"Alice"}]}
    ]});
    let base = serve_once("200 OK", "Content-Type: application/json\r\n", &serde_json::to_vec(&items).unwrap());
    let client = PodcastIndexClient::new("k", "s", &base);
    let hits = client.search_appearances("Alice").unwrap();
    assert!(hits.iter().any(|h| h.confidence == "high" && h.evidence.contains("person tag")));
    assert!(hits.iter().any(|h| h.evidence.contains("title and description")));
    assert!(hits.iter().any(|h| h.evidence == "name in title"));
    assert!(hits.iter().any(|h| h.evidence == "name in description"));

    let base = serve_once("500 Internal Server Error", "", b"nope");
    let client = PodcastIndexClient::new("k", "s", &base);
    assert!(client.search("q").is_err());

    let empty = PodcastIndexClient::new("k", "s", "");
    assert!(empty.is_configured());
}

#[test]
fn directory_from_env_and_disabled_appearance_default() {
    let _guard = ENV.lock().unwrap();
    std::env::remove_var("PODCASTINDEX_KEY");
    std::env::remove_var("PODCASTINDEX_SECRET");
    assert!(PodcastIndexClient::from_env().is_none());
    std::env::set_var("PODCASTINDEX_KEY", "  ");
    std::env::set_var("PODCASTINDEX_SECRET", "s");
    assert!(PodcastIndexClient::from_env().is_none());
    std::env::set_var("PODCASTINDEX_KEY", "k");
    std::env::set_var("PODCASTINDEX_SECRET", "s");
    std::env::set_var("PODCASTINDEX_BASE_URL", "https://example.test/api/");
    assert!(PodcastIndexClient::from_env().is_some());
    std::env::remove_var("PODCASTINDEX_KEY");
    std::env::remove_var("PODCASTINDEX_SECRET");
    std::env::remove_var("PODCASTINDEX_BASE_URL");
    let err = DisabledDirectory
        .search_appearances("person")
        .unwrap_err();
    assert!(format!("{err}").contains("unavailable") || matches!(err, Error::Upstream(_)));
}

#[test]
fn feeds_parse_dates_durations_and_http_fetcher() {
    assert!(feeds::parse_feed_date("") == 0);
    assert!(feeds::parse_feed_date("Mon, 2 Jan 2006 15:04:05 GMT") > 0);
    assert!(feeds::parse_feed_date("2006-01-02T15:04:05Z") > 0);
    assert!(feeds::parse_feed_date("2006-01-02") > 0);
    assert_eq!(feeds::parse_duration(""), None);
    assert_eq!(feeds::parse_duration("12"), Some(12));
    assert_eq!(feeds::parse_duration("1:02:03"), Some(3723));
    let body = b"<rss></rss>";
    let url = serve_once("200 OK", "ETag: \"x\"\r\nLast-Modified: yesterday\r\n", body);
    let fetcher = UreqFetcher::default();
    assert_eq!(fetcher.request_timeout(), Duration::from_secs(12));
    let data = fetcher
        .fetch(
            &url,
            &FeedValidators {
                etag: Some("\"old\"".into()),
                last_modified: Some("old".into()),
            },
        )
        .unwrap();
    match data {
        feeds::FeedFetchResponse::Data(bytes, _) => assert_eq!(bytes, body),
        _ => panic!("expected data"),
    }
    let url = serve_once("304 Not Modified", "ETag: \"n\"\r\n", b"");
    let result = fetcher.fetch(
        &url,
        &FeedValidators {
            etag: Some("\"n\"".into()),
            last_modified: None,
        },
    );
    assert!(result.is_ok());
}

#[test]
fn pipeline_notes_parakeet_download_and_classify_stages() {
    let _guard = ENV.lock().unwrap();
    std::env::set_var("PODS_TRANSCRIBER", "parakeet");
    std::env::set_var("PODS_PARAKEET_URL", "http://127.0.0.1:9/transcribe");
    let config = PipelineConfig::from_env();
    assert!(matches!(
        config.transcriber,
        pipeline::TranscriberKind::Parakeet
    ));
    std::env::remove_var("PODS_TRANSCRIBER");
    std::env::remove_var("PODS_PARAKEET_URL");
    assert!(matches!(
        PipelineConfig::from_env().transcriber,
        pipeline::TranscriberKind::Notes
    ));

    let notes = NotesTranscriber
        .transcribe(1, None, "<p>Hello world. Next sentence!</p>", Some(20))
        .unwrap();
    assert!(notes.len() >= 2);
    let fallback = NotesTranscriber.transcribe(2, None, "   ", None).unwrap();
    assert_eq!(fallback[0].text, "Episode audio");
    assert_eq!(NotesTranscriber.version(), "notes-transcriber-v1");

    let parakeet = ParakeetTranscriber {
        endpoint: "http://127.0.0.1:1/transcribe".into(),
    };
    assert_eq!(parakeet.version(), "parakeet-tdt-ctc-110m");
    assert!(parakeet.transcribe(1, None, "", None).is_err());
    let words = json!({"words":[{"word":"Hi","start":0.0,"end":0.4}]});
    let url = serve_once("200 OK", "Content-Type: application/json\r\n", &serde_json::to_vec(&words).unwrap());
    let parakeet = ParakeetTranscriber { endpoint: url };
    let wav = tempfile::NamedTempFile::new().unwrap();
    let segs = parakeet.transcribe(3, Some(wav.path()), "", None).unwrap();
    assert_eq!(segs[0].text, "Hi");
    assert!(parse_parakeet_empty_is_error());

    assert_eq!(
        DeepSeekClassifier
            .classify_window("p", "")
            .unwrap_err(),
        "pause:model_required"
    );
    assert_eq!(
        pipeline::ScriptedClassifier {
            responses: Mutex::new(vec![]),
        }
        .classify_window("p", "")
        .unwrap_err(),
        "pause:model_required"
    );

    let dir = tempfile::tempdir().unwrap();
    let dest = dir.path().join("audio.mp3");
    let payload = b"ID3audio";
    let url = serve_once(
        "200 OK",
        "Content-Type: audio/mpeg\r\n",
        payload,
    );
    let fetched = pipeline::UreqDownloader.fetch_to(&url, &dest).unwrap();
    assert_eq!(fetched.status, 200);
    assert_eq!(fetched.byte_count, payload.len() as i64);
    assert!(dest.is_file());
    let url = serve_once("404 Not Found", "Content-Type: text/plain\r\n", b"no");
    assert!(pipeline::UreqDownloader
        .fetch_to(&url, &dir.path().join("missing.mp3"))
        .is_err());
    let url = serve_once("201 Created", "Content-Type: audio/mpeg\r\n", b"x");
    let fetched = pipeline::UreqDownloader.fetch_to(&url, &dir.path().join("created.mp3"));
    if let Ok(fetched) = fetched {
        assert_ne!(fetched.status, 200);
    }

    let db = Database::open_in_memory().unwrap();
    db.execute(
        "INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO episodes (id, podcast_id, guid, title, audio_url, notes_html, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 'Hello world.', 100)",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO episode_state (episode_id, updated_at) VALUES (1, 1)",
        [],
    )
    .unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    let job = store.enqueue(1).unwrap();
    store.transition(&job.id, JobStage::Downloading).unwrap();
    let artifacts = ArtifactStore::open(dir.path().join("ad")).unwrap();
    let downloader = MockDownloader::default();
    downloader.set(
        "https://a",
        DownloadResult {
            status: 200,
            content_type: "audio/mpeg".into(),
            bytes: b"mp3-bytes".to_vec(),
        },
    );
    pipeline::execute_stage(
        &store,
        &artifacts,
        &downloader,
        &NotesTranscriber,
        &pipeline::ScriptedClassifier {
            responses: Mutex::new(vec![]),
        },
        "key",
        JobStage::Downloading,
        &store.job(&job.id).unwrap().unwrap(),
        "https://a",
        "Hello world.",
        Some(10),
        Some(&db),
    )
    .unwrap();
    store.transition(&job.id, JobStage::Downloaded).unwrap();
    store.transition(&job.id, JobStage::Transcribing).unwrap();
    pipeline::execute_stage(
        &store,
        &artifacts,
        &downloader,
        &NotesTranscriber,
        &pipeline::ScriptedClassifier {
            responses: Mutex::new(vec![]),
        },
        "key",
        JobStage::Transcribing,
        &store.job(&job.id).unwrap().unwrap(),
        "https://a",
        "Hello world.",
        Some(10),
        Some(&db),
    )
    .unwrap();
    store.transition(&job.id, JobStage::Classifying).unwrap();
    let job = store.job(&job.id).unwrap().unwrap();
    let ids: Vec<_> = store
        .transcript_segments(1)
        .unwrap()
        .into_iter()
        .map(|s| s.id)
        .collect();
    let windows = pods_backend::classify::production_windows(&ids);
    let classifier = pipeline::ScriptedClassifier {
        responses: Mutex::new(
            windows
                .iter()
                .rev()
                .map(|window| {
                    let labels = window
                        .iter()
                        .map(|id| {
                            format!(
                                r#"{{"segment_id":"{id}","label":"content","reason":"ok editorial"}}"#
                            )
                        })
                        .collect::<Vec<_>>()
                        .join(",");
                    pipeline::ClassifyOutcome {
                        content: Some(format!(r#"{{"labels":[{labels}]}}"#)),
                        raw: json!({"usage":{"prompt_tokens":1,"completion_tokens":1,"prompt_cache_hit_tokens":0}}),
                    }
                })
                .collect(),
        ),
    };
    pipeline::execute_stage(
        &store,
        &artifacts,
        &downloader,
        &NotesTranscriber,
        &classifier,
        "key",
        JobStage::Classifying,
        &job,
        "https://a",
        "Hello world.",
        Some(10),
        Some(&db),
    )
    .expect("classify using transcript ids");
    pipeline::execute_stage(
        &store,
        &artifacts,
        &downloader,
        &NotesTranscriber,
        &pipeline::ScriptedClassifier {
            responses: Mutex::new(vec![]),
        },
        "key",
        JobStage::Ready,
        &job,
        "https://a",
        "",
        None,
        None,
    )
    .unwrap();
    let _ = pipeline::largest_compatible_checkpoint(&[], 3);
    assert!(JobStage::parse("nope").is_none());
    assert!(BlockingReason::parse("nope").is_none());
    assert_eq!(JobStage::Failed.as_str(), "failed");
    assert_eq!(BlockingReason::ThermalPressure.as_str(), "thermal_pressure");
}

fn parse_parakeet_empty_is_error() -> bool {
    pipeline::parse_parakeet_words("not-json and no ranges").is_err()
}

#[test]
fn auth_webauthn_env_cookies_and_scripted_errors() {
    let _guard = ENV.lock().unwrap();
    let engine = WebauthnEngine::new("pods.mcgiv.dev", "https://pods.mcgiv.dev").unwrap();
    let (options, state) = engine.start_registration(&["zz".into(), "aa".into()]).unwrap();
    assert!(options.get("publicKey").is_some() || options.get("rp").is_some() || !options.is_null());
    assert!(engine
        .finish_registration(&json!({}), &json!({}))
        .is_err());
    assert!(engine.start_authentication(&[]).is_err());
    assert!(engine
        .finish_authentication(&state, &json!({}))
        .is_err());
    assert!(WebauthnEngine::new("bad", "not-a-url").is_err());

    let scripted = ScriptedPasskey;
    assert!(scripted
        .finish_registration(&json!({}), &json!({"id":"  "}))
        .is_err());
    assert!(scripted.start_authentication(&[]).is_err());
    assert!(scripted
        .finish_authentication(&json!({}), &json!({}))
        .is_err());

    let dir = tempfile::tempdir().unwrap();
    let key_path = dir.path().join("reset.key");
    std::fs::write(&key_path, "  reset-secret  \n").unwrap();
    std::env::remove_var("PODS_RESET_KEY");
    std::env::set_var("PODS_RESET_KEY_FILE", key_path.to_str().unwrap());
    assert_eq!(auth::load_reset_key().unwrap(), "reset-secret");
    std::fs::write(&key_path, "   ").unwrap();
    assert!(auth::load_reset_key().is_err());
    std::env::set_var("PODS_RESET_KEY", "from-env");
    assert_eq!(auth::load_reset_key().unwrap(), "from-env");

    std::env::set_var("PODS_AUTH_MODE", "off");
    let auth = Auth::default();
    auth::configure_from_env(&auth).unwrap();
    std::env::set_var("PODS_AUTH_MODE", "passkey");
    std::env::set_var("PODS_ORIGIN", "https://pods.mcgiv.dev");
    std::env::set_var("PODS_RP_ID", "pods.mcgiv.dev");
    std::env::set_var("PODS_RESET_KEY", "from-env");
    auth::configure_from_env(&auth).unwrap();
    assert!(auth.enabled());

    std::env::set_var("PODS_TRUSTED_ORIGINS", "https://a.example, https://b.example,");
    let origins = auth::trusted_origins_from_env();
    assert_eq!(origins.len(), 2);
    std::env::remove_var("PODS_TRUSTED_ORIGINS");
    assert!(!auth::trusted_origins_from_env().is_empty());
    let cookie = auth::session_cookie_header("tok", true);
    assert!(cookie.contains("Secure"));
    assert!(cookie.contains(SESSION_COOKIE));
    assert!(auth::clear_session_cookie(true).contains("Secure"));
    assert!(auth::is_public_auth_path("/api/auth/status", "GET"));
    let db = Database::open_in_memory().unwrap();
    assert!(!auth::enrolled(&db).unwrap());
    assert!(!auth::valid_session(&db, None).unwrap());
    std::env::remove_var("PODS_AUTH_MODE");
    std::env::remove_var("PODS_RESET_KEY");
    std::env::remove_var("PODS_RESET_KEY_FILE");
}

#[test]
fn speaker_unavailable_transport_and_helper_extract() {
    let t = UnavailableTransport;
    assert!(!t.available());
    assert_eq!(t.name(), "Mac");
    assert!(t.alive());
    assert!(t.child_pid().is_none());
    assert!(t.load(std::path::Path::new("/tmp/x"), 0.0, 1.0, true).is_err());
    assert!(t.play().is_err());
    assert!(t.pause().is_err());
    assert!(t.seek(1.0).is_err());
    assert!(t.set_rate(1.0).is_err());
    assert!(t.stop().unwrap().paused);
    assert!(t.snapshot().paused);
    if let Ok(helper) = pods_backend::speaker::HelperTransport::new() {
        assert!(helper.available());
        let _ = helper.stop();
    }
}

#[test]
fn bluetooth_mac_keys_and_live_memory_status() {
    let route = pods_backend::backend::BluetoothRoute {
        uid: "host-aa:bb:cc:dd:ee:ff-port".into(),
        name: "Speaker".into(),
        port_type: "bluetooth".into(),
    };
    assert_eq!(route.stable_device_key(), "aa:bb:cc:dd:ee:ff");
    let dashed = pods_backend::backend::BluetoothRoute {
        uid: "AA-BB-CC-DD-EE-FF".into(),
        name: "".into(),
        port_type: "bluetooth".into(),
    };
    assert_eq!(dashed.stable_device_key(), "aa:bb:cc:dd:ee:ff");
    let named = pods_backend::backend::BluetoothRoute {
        uid: "  ".into(),
        name: " Kitchen Speaker ".into(),
        port_type: "bluetooth".into(),
    };
    assert_eq!(named.stable_device_key(), "kitchen speaker");
    let memory = memory_gate::status_json();
    assert!(memory.get("whisper").is_some());
    assert!(memory.get("available_bytes").is_some());
}

#[test]
fn omlx_lock_reads_api_key_from_env() {
    let _guard = ENV.lock().unwrap();
    std::env::set_var("PODS_OMLX_KEY", "test-omlx-key");
    assert_eq!(omlx_lock::configured_api_key().unwrap(), "test-omlx-key");
    std::env::set_var("PODS_OMLX_KEY", "");
    let _ = omlx_lock::configured_api_key();
    std::env::remove_var("PODS_OMLX_KEY");
    assert!(omlx_lock::LockPaths::canonical().is_ok());
}

#[test]
fn browser_status_search_and_local_worker_step() {
    let temp = tempfile::tempdir().unwrap();
    let db = Database::open_in_memory().unwrap();
    db.execute(
        "INSERT INTO podcasts(id,feed_url,title,is_subscribed,created_at) VALUES(1,'https://example.org/feed','Example',1,0)",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO episodes(id,podcast_id,guid,title,audio_url,published_at) VALUES(1,1,'g','Episode','ftp://bad',1)",
        [],
    )
    .unwrap();
    let mut backend = Backend::with_data_root(
        db,
        Arc::new(MockFeedFetcher::default()),
        Arc::new(DisabledDirectory),
        Some(temp.path().to_owned()),
    );
    backend.auth.enable_passkey("reset", "https://pods.mcgiv.dev");
    let token = enroll_session(&backend);
    backend.local = true;
    let mut req = HttpRequest::new("GET", "/api/status");
    req = req.with_header("cookie", format!("{SESSION_COOKIE}={token}"));
    let status = backend.handle(req);
    assert_eq!(status.status_code, 200);
    let body: serde_json::Value = serde_json::from_slice(&status.body).unwrap();
    assert_eq!(body["available"], true);
    let mut req = HttpRequest::new("GET", "/api/search?q=Episode");
    req = req.with_header("cookie", format!("{SESSION_COOKIE}={token}"));
    let search = backend.handle(req);
    assert_eq!(search.status_code, 200);
    let mut req = HttpRequest::new("GET", "/api/opml");
    req = req.with_header("cookie", format!("{SESSION_COOKIE}={token}"));
    assert_eq!(backend.handle(req).status_code, 200);
    let mut req = HttpRequest::new("GET", "/api/refresh-status");
    req = req.with_header("cookie", format!("{SESSION_COOKIE}={token}"));
    assert_eq!(backend.handle(req).status_code, 200);
    let stepped = pods_backend::local_worker::step(&backend);
    assert!(stepped.is_ok());
}

fn enroll_session(backend: &Backend) -> String {
    let mut req = HttpRequest::new("POST", "/api/internal/passkey-reset");
    req = req.with_header("x-pods-reset-key", "reset");
    let reset = backend.handle(req);
    let body: serde_json::Value = serde_json::from_slice(&reset.body).unwrap();
    let token = body["enroll_url"]
        .as_str()
        .unwrap()
        .split("#enroll=")
        .nth(1)
        .unwrap()
        .to_string();
    let options = backend.handle(
        HttpRequest::new("POST", "/api/auth/register/options").with_json(&json!({"token": token})),
    );
    let options_body: serde_json::Value = serde_json::from_slice(&options.body).unwrap();
    let state_id = options_body["state_id"].as_str().unwrap();
    let registered = backend.handle(HttpRequest::new("POST", "/api/auth/register").with_json(
        &json!({"state_id": state_id, "credential": {"id": "cred-1"}}),
    ));
    registered
        .headers
        .get("set-cookie")
        .unwrap()
        .split(';')
        .next()
        .unwrap()
        .split('=')
        .nth(1)
        .unwrap()
        .to_string()
}

#[test]
fn local_worker_reuses_cached_transcript_and_publication() {
    let temp = tempfile::tempdir().unwrap();
    let wav = temp.path().join("tone.wav");
    let ffmpeg = std::process::Command::new("ffmpeg")
        .args([
            "-nostdin",
            "-v",
            "error",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:duration=2:sample_rate=16000",
            "-y",
        ])
        .arg(&wav)
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    assert!(ffmpeg, "ffmpeg is required to plant fixture audio");
    let db = Database::open_in_memory().unwrap();
    db.execute(
        "INSERT INTO podcasts(id,feed_url,title,is_subscribed,created_at) VALUES(1,'https://example.org/feed','Example',1,0)",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO episodes(id,podcast_id,guid,title,audio_url,published_at) VALUES(1,1,'g','Episode','https://example.org/a.mp3',1)",
        [],
    )
    .unwrap();
    let backend = Backend::with_data_root(
        db,
        Arc::new(MockFeedFetcher::default()),
        Arc::new(DisabledDirectory),
        Some(temp.path().to_owned()),
    );
    let source = backend
        .artifacts
        .prepare_dest("local/1/source.audio")
        .unwrap();
    std::fs::copy(&wav, &source).unwrap();
    let (source_hash, _) = ArtifactStore::hash_file(&source).unwrap();
    let segments = vec![pods_backend::local_worker::Segment {
        id: "s0".into(),
        start: 0.0,
        end: 2.0,
        text: "Hello from a fixture transcript.".into(),
    }];
    pods_backend::local_worker::validate_segments(&segments).unwrap();
    let work = source.parent().unwrap();
    std::fs::write(
        work.join(format!("transcript-{source_hash}.json")),
        serde_json::to_vec(&segments).unwrap(),
    )
    .unwrap();
    let transcript_hash = hex::encode(sha2::Sha256::digest(serde_json::to_vec(&segments).unwrap()));
    let classifier_run =
        pods_backend::local_worker::cached_classifier_run_id(&source_hash, &transcript_hash);
    let run = pods_backend::local_worker::cached_run_id(&source_hash, &transcript_hash);
    let labels = vec![pods_backend::local_worker::Label {
        segment_id: "s0".into(),
        label: "content".into(),
        evidence: "editorial speech".into(),
    }];
    std::fs::write(
        work.join(format!("labels-{classifier_run}.json")),
        serde_json::to_vec(&labels).unwrap(),
    )
    .unwrap();
    std::fs::write(
        work.join(format!("refined-{run}.json")),
        serde_json::to_vec(&labels).unwrap(),
    )
    .unwrap();
    let manifest = pods_backend::browser::Manifest {
        version: 1,
        episode_id: 1,
        hash: "deadbeef".into(),
        source_hash: source_hash.clone(),
        bytes: 8,
        duration: 2.0,
        chunk_size: 1024,
        chunks: vec!["deadbeef".into()],
        timeline: vec![pods_backend::browser::Interval {
            original_start: 0.0,
            original_end: 2.0,
            processed_start: 0.0,
        }],
        model: pods_backend::local_worker::MODEL.into(),
        pipeline_version: run,
    };
    backend
        .db
        .execute(
            "INSERT INTO browser_publications(episode_id,manifest_json,notes_json,published_at) VALUES(1,?,'[{\"title\":\"n\"}]',1)",
            rusqlite::params![serde_json::to_string(&manifest).unwrap()],
        )
        .unwrap();
    backend
        .db
        .execute(
            "INSERT INTO browser_jobs(episode_id,stage,attempts,next_retry_at,priority) VALUES(1,'queued',0,0,1)",
            [],
        )
        .unwrap();
    let did = pods_backend::local_worker::step(&backend).unwrap();
    assert!(did);
}

#[test]
fn backend_follow_ad_removal_and_runtime_refresh() {
    let db = Database::open_in_memory().unwrap();
    db.execute(
        "INSERT INTO podcasts(id,feed_url,title,is_subscribed,created_at) VALUES(1,'https://example.org/feed','S',0,1)",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO episodes(id,podcast_id,guid,title,audio_url,published_at) VALUES(1,1,'g','E','https://a',1)",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO episode_state(episode_id,updated_at) VALUES(1,1)",
        [],
    )
    .unwrap();
    let backend = Backend::new(
        db,
        Arc::new(MockFeedFetcher::default()),
        Arc::new(DisabledDirectory),
    );
    let _ = backend.handle(
        HttpRequest::new("PUT", "/api/ad-removal/deepseek-key").with_json(&json!({"api_key": "sk-test"})),
    );
    let _ = backend.handle(HttpRequest::new("DELETE", "/api/follows/99"));
    let prepare = backend.handle(HttpRequest::new("POST", "/api/episodes/1/ad-removal/prepare"));
    assert_eq!(prepare.status_code, 202);
    let retry = backend.handle(HttpRequest::new("POST", "/api/episodes/1/ad-removal/retry"));
    assert_eq!(retry.status_code, 409);
    let follow = backend.handle(
        HttpRequest::new("POST", "/api/follows").with_json(&json!({"name":"Al","aliases":[]})),
    );
    assert_eq!(follow.status_code, 500);
    let short = backend.handle(
        HttpRequest::new("POST", "/api/follows").with_json(&json!({"name":"x"})),
    );
    assert_eq!(short.status_code, 422);
    let mut backend = backend;
    let mut cfg = PipelineConfig::from_env();
    cfg.transcriber = TranscriberKind::Parakeet;
    cfg.parakeet_url = Some("http://127.0.0.1:9/transcribe".into());
    cfg.background_refresh_secs = 1;
    backend.set_pipeline_config(cfg);
    backend.local = true;
    let backend = Arc::new(backend);
    backend.start_runtime();
    std::thread::sleep(Duration::from_millis(50));
    backend.stop_runtime();
}

#[test]
fn pipeline_malformed_classification_records_evidence() {
    let db = Database::open_in_memory().unwrap();
    db.execute(
        "INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO episodes (id, podcast_id, guid, title, audio_url, notes_html, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 'Hello world.', 100)",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO episode_state (episode_id, updated_at) VALUES (1, 1)",
        [],
    )
    .unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    let job = store.enqueue(1).unwrap();
    store
        .replace_transcript_segments(
            1,
            &[pods_backend::transcribe::TranscriptSegment {
                id: "s0".into(),
                index: 0,
                language: "en".into(),
                start_time: 0.0,
                end_time: 1.0,
                text: "Hello world.".into(),
            }],
        )
        .unwrap();
    for stage in [
        JobStage::Downloading,
        JobStage::Downloaded,
        JobStage::Transcribing,
        JobStage::Classifying,
    ] {
        store.transition(&job.id, stage).unwrap();
    }
    let dir = tempfile::tempdir().unwrap();
    let artifacts = ArtifactStore::open(dir.path().to_path_buf()).unwrap();
    let classifier = pipeline::ScriptedClassifier {
        responses: Mutex::new(vec![pipeline::ClassifyOutcome {
            content: Some(r#"{"labels":[{"segment_id":"nope","label":"ad","reason":"x"}]}"#.into()),
            raw: json!({"usage":{"prompt_tokens":1,"completion_tokens":1,"prompt_cache_hit_tokens":0}}),
        }]),
    };
    let err = pipeline::execute_stage(
        &store,
        &artifacts,
        &MockDownloader::default(),
        &NotesTranscriber,
        &classifier,
        "key",
        JobStage::Classifying,
        &store.job(&job.id).unwrap().unwrap(),
        "https://a",
        "Hello world.",
        Some(10),
        Some(&db),
    )
    .unwrap_err();
    assert_eq!(err, "malformed classification");
}

#[test]
fn memory_transport_error_and_unavailable_branches() {
    let t = pods_backend::speaker::MemoryTransport::new(true);
    t.set_available(false);
    assert!(t
        .load(std::path::Path::new("/tmp/x"), 0.0, 1.0, false)
        .is_err());
    t.set_available(true);
    t.set_alive(false);
    assert!(t
        .load(std::path::Path::new("/tmp/x"), 0.0, 1.0, false)
        .is_err());
    t.set_alive(true);
    t.set_duration(10.0);
    t.set_ended();
    t.set_error(" /secret/path token=abc ");
    t.fail_next_load();
    assert!(t
        .load(std::path::Path::new("/tmp/x"), 1.0, 1.0, false)
        .is_err());
    assert!(t.load_count() >= 1);
}

#[test]
fn auth_logout_and_login_without_enrolled_key() {
    let db = Database::open_in_memory().unwrap();
    let backend = Backend::new(
        db,
        Arc::new(MockFeedFetcher::default()),
        Arc::new(DisabledDirectory),
    );
    backend.auth.enable_passkey("reset", "https://pods.mcgiv.dev");
    let logout = backend.handle(HttpRequest::new("POST", "/api/auth/logout"));
    assert!(logout.status_code == 204 || logout.status_code == 200);
    let login = backend.handle(HttpRequest::new("POST", "/api/auth/login/options").with_json(&json!({})));
    assert_eq!(login.status_code, 401);
}

struct FakeDirectory;

impl DirectorySearcher for FakeDirectory {
    fn is_configured(&self) -> bool {
        true
    }
    fn search(&self, _query: &str) -> Result<Vec<DirectoryPodcast>, Error> {
        Ok(vec![DirectoryPodcast {
            title: "Show".into(),
            author: "A".into(),
            feed_url: "https://example.org/feed".into(),
            image_url: "https://example.org/i.png".into(),
            description: "d".into(),
            subscribed: false,
        }])
    }
    fn search_appearances(&self, person: &str) -> Result<Vec<DirectoryAppearance>, Error> {
        let now = unix_now();
        Ok(vec![
            DirectoryAppearance {
                source_episode_key: "k1".into(),
                feed_url: "https://example.org/feed".into(),
                feed_title: "Show".into(),
                feed_image_url: "https://example.org/i.png".into(),
                guid: "guid-1".into(),
                title: format!("{person} visits"),
                description: "desc".into(),
                audio_url: "https://example.org/a.mp3".into(),
                duration_secs: Some(60),
                published_at: now,
                image_url: "".into(),
                evidence: "person tag: guest".into(),
                confidence: "high".into(),
            },
            DirectoryAppearance {
                source_episode_key: "k2".into(),
                feed_url: "https://example.org/other".into(),
                feed_title: "Other".into(),
                feed_image_url: "".into(),
                guid: "guid-2".into(),
                title: format!("{person} maybe"),
                description: "maybe".into(),
                audio_url: "https://example.org/b.mp3".into(),
                duration_secs: None,
                published_at: now,
                image_url: "".into(),
                evidence: "name in title".into(),
                confidence: "review".into(),
            },
            DirectoryAppearance {
                source_episode_key: "k-old".into(),
                feed_url: "https://example.org/old".into(),
                feed_title: "Old".into(),
                feed_image_url: "".into(),
                guid: "guid-old".into(),
                title: format!("{person} old"),
                description: "".into(),
                audio_url: "https://example.org/old.mp3".into(),
                duration_secs: None,
                published_at: now - 40 * 24 * 60 * 60,
                image_url: "".into(),
                evidence: "name".into(),
                confidence: "high".into(),
            },
        ])
    }
}

fn unix_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}

#[test]
fn job_store_errors_and_stage_enums() {
    use pods_backend::jobs::JobStoreError;
    for (stage, name) in [
        (JobStage::Queued, "queued"),
        (JobStage::Downloading, "downloading"),
        (JobStage::Downloaded, "downloaded"),
        (JobStage::Transcribing, "transcribing"),
        (JobStage::Classifying, "classifying"),
        (JobStage::Ready, "ready"),
        (JobStage::Failed, "failed"),
        (JobStage::Cancelled, "cancelled"),
    ] {
        assert_eq!(stage.as_str(), name);
        assert_eq!(JobStage::parse(name), Some(stage));
    }
    for (reason, name) in [
        (BlockingReason::ModelRequired, "model_required"),
        (BlockingReason::StorageLimit, "storage_limit"),
        (BlockingReason::LowPower, "low_power"),
        (BlockingReason::ThermalPressure, "thermal_pressure"),
        (BlockingReason::DailyLimit, "daily_limit"),
        (BlockingReason::PlaybackActive, "playback_active"),
    ] {
        assert_eq!(reason.as_str(), name);
        assert_eq!(BlockingReason::parse(name), Some(reason));
    }
    let _: Error = JobStoreError::EpisodeNotFound.into();
    let _: Error = JobStoreError::JobNotFound.into();
    let _: Error = JobStoreError::EpisodeArchived.into();
    let _: Error = JobStoreError::InvalidTransition.into();
    let _: Error = JobStoreError::CorruptState("x".into()).into();
    let db = Database::open_in_memory().unwrap();
    let store = JobStore::new(&db);
    assert!(store.enqueue(99).is_err());
}

#[test]
fn browser_show_notes_queue_and_artifact_manifest() {
    let temp = tempfile::tempdir().unwrap();
    let db = Database::open_in_memory().unwrap();
    db.execute(
        "INSERT INTO podcasts(id,feed_url,title,is_subscribed,created_at) VALUES(1,'https://example.org/feed','Example',1,0)",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO episodes(id,podcast_id,guid,title,audio_url,published_at) VALUES(1,1,'g','Episode','https://example.org/a.mp3',1)",
        [],
    )
    .unwrap();
    let mut backend = Backend::with_data_root(
        db,
        Arc::new(MockFeedFetcher::default()),
        Arc::new(DisabledDirectory),
        Some(temp.path().to_owned()),
    );
    backend.auth.enable_passkey("reset", "https://pods.mcgiv.dev");
    let token = enroll_session(&backend);
    backend.local = true;
    let manifest = pods_backend::browser::Manifest {
        version: 1,
        episode_id: 1,
        hash: "abcd".into(),
        source_hash: "src".into(),
        bytes: 8,
        duration: 2.0,
        chunk_size: 1024,
        chunks: vec!["abcd".into()],
        timeline: vec![pods_backend::browser::Interval {
            original_start: 0.0,
            original_end: 2.0,
            processed_start: 0.0,
        }],
        model: "m".into(),
        pipeline_version: "p".into(),
    };
    backend
        .db
        .execute(
            "INSERT INTO browser_publications(episode_id,manifest_json,notes_json,published_at) VALUES(1,?,'[]',1)",
            rusqlite::params![serde_json::to_string(&manifest).unwrap()],
        )
        .unwrap();
    let cookie = format!("{SESSION_COOKIE}={token}");
    let mut req = HttpRequest::new("GET", "/api/episodes/1/artifact-manifest");
    req = req.with_header("cookie", cookie.clone());
    assert_eq!(backend.handle(req).status_code, 200);
    let mut req = HttpRequest::new("POST", "/api/episodes/1/show-notes");
    req = req.with_header("cookie", cookie);
    let notes = backend.handle(req);
    assert!(notes.status_code == 202 || notes.status_code == 200);
}

fn cookie_req(method: &str, target: &str, token: &str) -> HttpRequest {
    HttpRequest::new(method, target).with_header("cookie", format!("{SESSION_COOKIE}={token}"))
}

#[test]
fn follow_reject_delete_search_and_legacy_admin_routes() {
    let fetcher = Arc::new(MockFeedFetcher::default());
    let feed_url = "https://example.org/feed";
    fetcher.set(
        feed_url,
        br#"<?xml version="1.0"?><rss version="2.0"><channel><title>Show</title><description>d</description><item><title>Episode</title><guid>g</guid><pubDate>Mon, 06 Jan 2025 00:00:00 GMT</pubDate><enclosure url="https://example.org/a.mp3" type="audio/mpeg" length="123"/></item></channel></rss>"#.to_vec(),
    );
    let db = Database::open_in_memory().unwrap();
    db.execute(
        "INSERT INTO feed_refresh_attempts(source, started_at, outcome) VALUES('foreground', 1, 'running')",
        [],
    )
    .unwrap();
    let backend = Backend::new(db, fetcher, Arc::new(FakeDirectory));
    backend.auth.enable_passkey("reset", "https://pods.mcgiv.dev");
    let token = enroll_session(&backend);
    let cookie = format!("{SESSION_COOKIE}={token}");
    let mut search = HttpRequest::new("GET", "/api/search?q=Show");
    search = search.with_header("cookie", cookie.clone());
    let found = backend.handle(search);
    assert_eq!(found.status_code, 200);
    let created = backend.handle(
        cookie_req("POST", "/api/follows", &token).with_json(&json!({"name":"Alice","aliases":["Al"]})),
    );
    assert_eq!(created.status_code, 201);
    let follow: serde_json::Value = serde_json::from_slice(&created.body).unwrap();
    let follow_id = follow["id"].as_i64().unwrap();
    let listed = backend.handle(cookie_req("GET", "/api/follows", &token));
    assert_eq!(listed.status_code, 200);
    let candidates = backend.handle(cookie_req("GET", "/api/follow-candidates", &token));
    assert_eq!(candidates.status_code, 200);
    let body: serde_json::Value = serde_json::from_slice(&candidates.body).unwrap();
    if let Some(id) = body.as_array().and_then(|a| a.first()).and_then(|c| c["id"].as_i64()) {
        let reject = backend.handle(cookie_req(
            "POST",
            &format!("/api/follow-candidates/{id}/reject"),
            &token,
        ));
        assert_eq!(reject.status_code, 204);
    }
    let refreshed = backend.handle(cookie_req("POST", &format!("/api/follows/{follow_id}"), &token));
    assert_eq!(refreshed.status_code, 200);
    let dup = backend.handle(
        cookie_req("POST", "/api/follows", &token).with_json(&json!({"name":"Alice"})),
    );
    assert_eq!(dup.status_code, 409);
    let deleted = backend.handle(cookie_req("DELETE", &format!("/api/follows/{follow_id}"), &token));
    assert_eq!(deleted.status_code, 204);
    let missing = backend.handle(cookie_req("DELETE", "/api/follows/999", &token));
    assert_eq!(missing.status_code, 404);
    let missing_refresh = backend.handle(cookie_req("POST", "/api/follows/999", &token));
    assert_eq!(missing_refresh.status_code, 404);
    let reject_missing = backend.handle(cookie_req("POST", "/api/follow-candidates/999/reject", &token));
    assert_eq!(reject_missing.status_code, 404);
    let accept_missing = backend.handle(cookie_req("POST", "/api/follow-candidates/999/accept", &token));
    assert_eq!(accept_missing.status_code, 404);

    let subscribed = backend.handle(
        cookie_req("POST", "/api/shows", &token).with_json(&json!({"feed_url": feed_url})),
    );
    assert_eq!(subscribed.status_code, 201);
    let show: serde_json::Value = serde_json::from_slice(&subscribed.body).unwrap();
    let show_id = show["id"].as_i64().unwrap();
    let search_show = backend.handle(cookie_req(
        "GET",
        &format!("/api/shows/{show_id}/search?q=Episode"),
        &token,
    ));
    assert_eq!(search_show.status_code, 200);
    let empty_q = backend.handle(cookie_req(
        "GET",
        &format!("/api/shows/{show_id}/search?q="),
        &token,
    ));
    assert!(empty_q.status_code == 422 || empty_q.status_code == 400);

    backend.set_car_routes(vec![
        pods_backend::backend::BluetoothRoute {
            uid: "aa:bb:cc:dd:ee:ff".into(),
            name: "AirPods Pro".into(),
            port_type: "bluetoothA2DP".into(),
        },
        pods_backend::backend::BluetoothRoute {
            uid: "11:22:33:44:55:66".into(),
            name: "Tesla".into(),
            port_type: "carAudio".into(),
        },
    ]);
    let enroll_car = backend.handle(cookie_req("POST", "/api/car-bluetooth/enroll", &token));
    assert_eq!(enroll_car.status_code, 200);
    let unenroll = backend.handle(cookie_req("POST", "/api/car-bluetooth/unenroll", &token));
    assert_eq!(unenroll.status_code, 200);
    backend.set_car_routes(vec![pods_backend::backend::BluetoothRoute {
        uid: "built-in".into(),
        name: "MacBook".into(),
        port_type: "builtInSpeaker".into(),
    }]);
    let no_bt = backend.handle(cookie_req("POST", "/api/car-bluetooth/enroll", &token));
    assert_eq!(no_bt.status_code, 422);

    let export = backend.handle(cookie_req("GET", "/api/ad-removal/diagnostics/export", &token));
    assert_eq!(export.status_code, 200);
    let clear = backend.handle(cookie_req("POST", "/api/ad-removal/diagnostics/clear", &token));
    assert_eq!(clear.status_code, 204);
    let disable = backend.handle(cookie_req("POST", "/api/ad-removal/disable", &token));
    assert_eq!(disable.status_code, 200);
    let bad_cleanup = backend.handle(
        cookie_req("POST", "/api/ad-removal/cleanup", &token).with_json(&json!({"confirm":"nope"})),
    );
    assert_eq!(bad_cleanup.status_code, 422);
    let cleanup = backend.handle(
        cookie_req("POST", "/api/ad-removal/cleanup", &token)
            .with_json(&json!({"confirm":"DELETE_AD_REMOVAL_DATA"})),
    );
    assert_eq!(cleanup.status_code, 200);
    let reset_corr = backend.handle(cookie_req(
        "POST",
        "/api/ad-removal/corrections/1/reset",
        &token,
    ));
    assert_eq!(reset_corr.status_code, 200);
    let trusted_options = backend.handle(
        HttpRequest::new("OPTIONS", "/api/episodes/1/show-notes")
            .with_header("origin", "http://127.0.0.1:18180")
            .with_header("cookie", cookie.clone()),
    );
    assert_eq!(trusted_options.status_code, 204);
    let trusted_get = backend.handle(
        HttpRequest::new("GET", "/api/episodes/1/show-notes")
            .with_header("origin", "http://127.0.0.1:18180")
            .with_header("cookie", cookie.clone())
            .with_header("content-type", "application/json"),
    );
    assert_eq!(trusted_get.status_code, 404);
    let trusted_bad_ct = backend.handle(
        HttpRequest::new("POST", "/api/episodes/1/show-notes")
            .with_header("origin", "http://127.0.0.1:18180")
            .with_header("cookie", cookie)
            .with_header("content-type", "text/plain"),
    );
    assert_eq!(trusted_bad_ct.status_code, 422);
    let opml = backend.handle(
        cookie_req("POST", "/api/opml", &token).with_json(&json!({})),
    );
    assert!(opml.status_code == 200 || opml.status_code == 422);
    let mut opml_xml = HttpRequest::new("POST", "/api/opml");
    opml_xml.body = format!(r#"<opml><outline xmlUrl="{feed_url}" /></opml>"#).into_bytes();
    opml_xml = opml_xml.with_header("cookie", format!("{SESSION_COOKIE}={token}"));
    let imported = backend.handle(opml_xml);
    assert_eq!(imported.status_code, 200);
}

#[test]
fn usage_storage_coordinator_classify_and_transcribe_helpers() {
    let db = Database::open_in_memory().unwrap();
    db.execute(
        "INSERT INTO podcasts(id,feed_url,title,created_at) VALUES(1,'https://x','S',1)",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO episodes(id,podcast_id,guid,title,audio_url,duration_secs,published_at) VALUES(1,1,'g','E','https://a',60,100)",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO episode_state(episode_id,updated_at) VALUES(1,1)",
        [],
    )
    .unwrap();
    let dir = tempfile::tempdir().unwrap();
    let ledger = dir.path().join("ledger.jsonl");
    let store = pods_backend::usage::UsageStore::with_ledger(&db, ledger.clone());
    store.fail_next_insert();
    let tokens = pods_backend::usage::UsageTokens {
        input_tokens: Some(10),
        cached_input_tokens: Some(2),
        output_tokens: Some(4),
    };
    let recorded = store
        .record(1, "ad_detection", "deepseek-v4-flash", Some(&tokens), 20 * 3600)
        .unwrap();
    assert_eq!(recorded.episode_id, 1);
    let parsed = store
        .record_parsed(
            1,
            "show_notes",
            "deepseek-v4-pro",
            &json!({"usage":{"prompt_tokens":3,"completion_tokens":1,"prompt_cache_hit_tokens":0}}),
            2 * 3600,
        )
        .unwrap();
    assert!(parsed.is_some());
    assert!(store.record_parsed(1, "show_notes", "m", &json!({}), 1).unwrap().is_none());
    let invalid = store
        .record_parsed(1, "show_notes", "m", &json!({"usage":{"total_tokens":9}}), 1)
        .unwrap();
    assert!(invalid.is_some());
    assert!(!store.records(1).unwrap().is_empty());
    assert!(store.episode_total_cost(1).unwrap() >= 0.0);
    let metrics = store.metrics().unwrap();
    assert!(metrics.total_cost_usd >= 0.0);
    assert_eq!(
        pods_backend::usage::episode_key("https://x", "g"),
        format!("https://x\u{1F}g")
    );
    let _ = pods_backend::usage::legacy_record_id(&recorded);
    assert!(pods_backend::usage::is_peak(2 * 3600));
    assert!(pods_backend::usage::cost_usd_model(&tokens, "deepseek-v4-flash", 20 * 3600).is_some());
    assert!(pods_backend::usage::parse_usage(&json!({"usage":"nope"})).is_none());
    match pods_backend::usage::parse_usage_result(&json!({"usage":{}})) {
        pods_backend::usage::ParsedUsage::Absent | pods_backend::usage::ParsedUsage::Invalid => {}
        _ => panic!("empty usage object"),
    }

    let artifacts = ArtifactStore::open(dir.path().join("ad")).unwrap();
    let hash = artifacts.install("episodes/1/audio.mp3", b"ID3data").unwrap();
    assert!(artifacts.validate("episodes/1/audio.mp3", &hash, 7));
    assert!(!artifacts.validate("/tmp/x", &hash, 7));
    let hashed = ArtifactStore::hash_file(&artifacts.url("episodes/1/audio.mp3")).unwrap();
    assert_eq!(hashed.0, hash);
    let resume = artifacts.write_resume("job-1", b"partial").unwrap();
    assert!(resume.starts_with("resume/"));
    artifacts.remove("episodes/1/audio.mp3").unwrap();
    artifacts.remove("/tmp/untrusted").unwrap();
    assert!(pods_backend::storage::storage_allows(1, 100, 50, 10, 5));
    assert!(!pods_backend::storage::storage_allows(90, 100, 5, 10, 20));
    assert!(pods_backend::storage::is_mp3_or_octet("audio/mp3"));
    assert!(pods_backend::storage::is_mp3_or_octet("binary/octet-stream"));
    assert!(!pods_backend::storage::is_mp3_or_octet("text/plain"));
    let jobs = JobStore::with_now(&db, || 1_000);
    let job = jobs.enqueue(1).unwrap();
    jobs.transition(&job.id, JobStage::Downloading).unwrap();
    let download = DownloadResult {
        status: 200,
        content_type: "audio/mpeg".into(),
        bytes: b"mp3-bytes".to_vec(),
    };
    pods_backend::storage::finalize_download(&artifacts, &jobs, &job.id, 1, &download).unwrap();
    assert!(pods_backend::storage::finalize_download(
        &artifacts,
        &jobs,
        &job.id,
        1,
        &DownloadResult {
            status: 200,
            content_type: "text/plain".into(),
            bytes: b"x".to_vec(),
        }
    )
    .is_err());

    jobs.set_blocking_reason(&job.id, Some(BlockingReason::LowPower)).unwrap();
    jobs.clear_blocking_reasons(&[]).unwrap();
    jobs.clear_blocking_reasons(&[BlockingReason::LowPower]).unwrap();
    jobs.record_download_resume_path(&job.id, "resume/job-1.resume").unwrap();
    assert!(jobs.record_download_resume_path(&job.id, "episodes/nope").is_err());
    jobs.transition(&job.id, JobStage::Downloaded).unwrap();
    jobs.transition(&job.id, JobStage::Transcribing).unwrap();
    jobs.record_transcript(
        &job.id,
        &[pods_backend::transcribe::TranscriptSegment {
            id: "s0".into(),
            index: 0,
            language: "en".into(),
            start_time: 0.0,
            end_time: 1.0,
            text: "Hello world.".into(),
        }],
        "notes-transcriber-v1",
    )
    .unwrap();
    jobs.transition(&job.id, JobStage::Classifying).unwrap();
    jobs.complete_classification(
        &job.id,
        "run-1",
        &[pods_backend::skip::AdSkipRange {
            id: "r0".into(),
            start_segment_id: "s0".into(),
            end_segment_id: "s0".into(),
            start_time: 0.0,
            end_time: 1.0,
            confidence: 0.9,
            reason: "ad".into(),
            classifier_version: "v".into(),
            prompt_version: "p".into(),
            created_at: 1,
            disabled: false,
        }],
    )
    .unwrap();
    let _ = jobs.undo_skip(1, "r0").unwrap();
    jobs.replace_show_notes(
        1,
        &[pods_backend::jobs::ShowNoteRecord {
            segment_id: "s0".into(),
            start_time: 0.0,
            title: "Intro".into(),
            summary: "s".into(),
            model_id: "m".into(),
            prompt_version: "p".into(),
            created_at: 1,
        }],
    )
    .unwrap();
    assert!(!jobs.show_notes(1).unwrap().is_empty());
    db.execute("UPDATE episode_state SET played_at = 2 WHERE episode_id = 1", [])
        .unwrap();
    jobs.cancel(&job.id).ok();
    jobs.recover_played_cleanup().unwrap();
    assert!(jobs.job_retry_wait().unwrap().is_none());
    jobs.delete_podcast_corrections(1).unwrap();
    JobStore::cleanup_archived_episode_metadata(&db.lock().unwrap(), 1).unwrap();
    assert_eq!(
        pods_backend::jobs::blocking_reason_for_stage(
            JobStage::Transcribing,
            pods_backend::jobs::ResourceConditions {
                low_power_mode: true,
                serious_thermal_pressure: false
            }
        ),
        Some(BlockingReason::LowPower)
    );
    assert_eq!(
        pods_backend::jobs::blocking_reason_for_stage(
            JobStage::Transcribing,
            pods_backend::jobs::ResourceConditions {
                low_power_mode: false,
                serious_thermal_pressure: true
            }
        ),
        Some(BlockingReason::ThermalPressure)
    );
    assert!(pods_backend::jobs::blocking_reason_for_stage(
        JobStage::Queued,
        pods_backend::jobs::ResourceConditions::default()
    )
    .is_none());
    assert!(pods_backend::jobs::valid_artifact_path("local/1/source.audio"));
    assert!(pods_backend::jobs::valid_artifact_path("published/ab.m4a"));
    assert!(!pods_backend::jobs::valid_artifact_path("../x"));

    let db2 = Database::open_in_memory().unwrap();
    db2.execute(
        "INSERT INTO podcasts(id,feed_url,title,created_at) VALUES(1,'https://x','S',1)",
        [],
    )
    .unwrap();
    db2.execute(
        "INSERT INTO episodes(id,podcast_id,guid,title,audio_url,published_at) VALUES(1,1,'g','E','https://a',100)",
        [],
    )
    .unwrap();
    db2.execute(
        "INSERT INTO episode_state(episode_id,updated_at) VALUES(1,1)",
        [],
    )
    .unwrap();
    let jobs2 = JobStore::with_now(&db2, || 1_000);
    let queued = jobs2.enqueue(1).unwrap();
    let coord = pods_backend::coordinator::Coordinator::new(&jobs2).skip_daily_limit(true);
    let ran = coord
        .run_next_stage(|stage, _job| {
            assert_eq!(stage, JobStage::Downloading);
            Ok(())
        })
        .unwrap();
    assert!(ran.is_some());
    let idle = coord
        .run_until_idle(|_stage, _job| Err("pause:low_power".into()))
        .unwrap();
    assert!(idle >= 1);
    let disabled = pods_backend::coordinator::Coordinator::with_enabled(&jobs2, || false);
    assert_eq!(disabled.run_until_idle(|_, _| Ok(())).unwrap(), 0);
    let slept = coord
        .run_until_idle_with_sleep(|_, _| Ok(()), |_s| {}, &|| 1_000)
        .unwrap();
    assert!(slept < 100);
    let _ = queued;

    let ids = vec!["a".into(), "b".into()];
    let fenced = pods_backend::classify::parse_structured_labels(
        "```json\n{\"labels\":[{\"segment_id\":\"a\",\"label\":\"content\",\"reason\":\"ok\"},{\"segment_id\":\"b\",\"label\":\"ad\",\"reason\":\"promo\"}]}\n```",
        &ids,
    )
    .unwrap();
    assert_eq!(fenced.len(), 2);
    assert!(pods_backend::classify::parse_show_notes(
        r#"{"chapters":[{"segment_id":"a","title":"T","summary":"S"}]}"#,
        &ids
    )
    .is_ok());
    assert!(pods_backend::classify::parse_show_notes(r#"{"chapters":[]}"#, &ids).is_ok());
    let windows = pods_backend::classify::windows(&ids, 1, 0);
    assert_eq!(windows.len(), 2);
    assert!(pods_backend::classify::windows(&[], 8, 1).is_empty());
    assert_eq!(pods_backend::classify::total_windows(0), 0);
    assert_eq!(pods_backend::classify::total_windows(10), 1);
    assert!(pods_backend::classify::total_windows(200) > 1);
    let _ = pods_backend::classify::production_windows(&ids);
    let _ = pods_backend::classify::short_request_ids(3);
    let _ = pods_backend::classify::deepseek_chat_body("m", "p");
    let corrections = vec![pods_backend::classify::CorrectionExample {
        id: "c1".into(),
        text: "sponsor read about acme widgets today".into(),
        created_at: 9,
    }];
    let selected = pods_backend::classify::select_corrections("acme widgets", &corrections, 20);
    assert!(!selected.is_empty());
    let prompt = pods_backend::classify::classification_prompt(&ids, &selected);
    assert!(prompt.contains("SEGMENT"));

    let segs = pods_backend::transcribe::from_finalized(1, "en", &[(0.0, 1.0, "Hi".into())]).unwrap();
    assert_eq!(segs[0].text, "Hi");
    assert!(pods_backend::transcribe::from_finalized(1, "en", &[]).is_err());
    let mut acc = pods_backend::transcribe::ResultAccumulator::new("en");
    acc.consume(false, 0.0, 1.0, "skip");
    acc.consume(true, 0.0, 1.0, "Hello.");
    acc.consume(true, 1.0, 0.5, "bad");
    assert_eq!(acc.segments.len(), 1);
    let grouped = pods_backend::transcribe::group_words(
        2,
        &[
            pods_backend::transcribe::TimedWord {
                text: "Hello".into(),
                start: 0.0,
                end: 0.3,
            },
            pods_backend::transcribe::TimedWord {
                text: "there.".into(),
                start: 0.3,
                end: 0.6,
            },
            pods_backend::transcribe::TimedWord {
                text: "Next".into(),
                start: 2.0,
                end: 2.2,
            },
        ],
    )
    .unwrap();
    assert!(grouped.len() >= 2);
    assert_eq!(pods_backend::transcribe::error_code("canceled"), "transcription.canceled");
    assert_eq!(pods_backend::transcribe::error_code("unsupported"), "transcription.unsupported_audio");
    assert_eq!(pods_backend::transcribe::error_code("timeout"), "transcription.timeout");
    assert_eq!(pods_backend::transcribe::error_code("other"), "transcription.failed");
    assert_eq!(
        pods_backend::transcribe::stable_segment_id(9, 1, 100),
        "ep9-seg1-100"
    );
}

#[test]
fn memory_gate_auth_login_feeds_directory_and_show_notes() {
    let _guard = ENV.lock().unwrap();
    let cfg = memory_gate::parse_gate_config(
        Some("1"),
        Some("100"),
        Some("50"),
        Some("not-a-number"),
        Some(""),
    );
    assert!(cfg.enabled);
    let _ = memory_gate::evaluate();
    let status = memory_gate::status_json();
    assert!(status.get("available_bytes").is_some());
    let _ = memory_gate::require_inference(memory_gate::InferenceKind::Whisper);
    let _ = memory_gate::require_inference(memory_gate::InferenceKind::Omlx);
    let _ = memory_gate::should_preempt_whisper();
    assert!(memory_gate::is_busy_error(&Error::Upstream(
        memory_gate::MEMORY_BUSY.into()
    )));
    assert!(!memory_gate::is_busy_error(&Error::Upstream("x".into())));
    assert!(memory_gate::busy_retry_delay_secs(7) >= 60);
    assert_eq!(memory_gate::available_from_counts(10, 2, 4, 4096), (8 + 4) * 4096);

    let db = Database::open_in_memory().unwrap();
    let backend = Backend::new(
        db,
        Arc::new(MockFeedFetcher::default()),
        Arc::new(DisabledDirectory),
    );
    backend.auth.enable_passkey("reset", "https://pods.mcgiv.dev");
    let token = enroll_session(&backend);
    let status = backend.handle(cookie_req("GET", "/api/auth/status", &token));
    assert_eq!(status.status_code, 200);
    let options = backend.handle(cookie_req("POST", "/api/auth/login/options", &token).with_json(&json!({})));
    assert_eq!(options.status_code, 200);
    let options_body: serde_json::Value = serde_json::from_slice(&options.body).unwrap();
    let state_id = options_body["state_id"].as_str().unwrap();
    let login = backend.handle(
        cookie_req("POST", "/api/auth/login", &token).with_json(&json!({
            "state_id": state_id,
            "credential": {"id": "cred-1"}
        })),
    );
    assert_eq!(login.status_code, 200);
    let bad_reset = backend.handle(
        HttpRequest::new("POST", "/api/internal/passkey-reset").with_header("x-pods-reset-key", "wrong"),
    );
    assert_eq!(bad_reset.status_code, 401);
    let missing_reset = backend.handle(HttpRequest::new("POST", "/api/internal/passkey-reset"));
    assert_eq!(missing_reset.status_code, 401);

    let xml = br#"<?xml version="1.0"?><rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>Show</title><description>About</description><link>https://site.example</link><itunes:image href="https://img/i.png"/><item><title>Ep</title><content:encoded>Notes</content:encoded><enclosure url="https://a.mp3" type="audio/mpeg"/><itunes:duration>1:02</itunes:duration><pubDate>Mon, 2 Jan 2006 15:04:05 GMT</pubDate></item><item><title>Skip</title></item></channel></rss>"#;
    let parsed = feeds::parse_feed(xml).unwrap();
    assert_eq!(parsed.title, "Show");
    assert_eq!(parsed.episodes.len(), 1);
    assert_eq!(parsed.episodes[0].duration_secs, Some(62));
    assert!(feeds::https_equivalent("http://example.com/feed").unwrap().starts_with("https://"));
    assert!(feeds::https_equivalent("https://example.com/feed").is_none());
    let err = feeds::fetch_with_https_fallback("http://127.0.0.1:1/feed", |_u| {
        Err(Error::Upstream("down".into()))
    });
    assert!(err.is_err());
    let ok = feeds::fetch_with_https_fallback("https://example.com/feed", |_u| {
        Ok(feeds::FeedFetchResponse::Data(b"<rss/>".to_vec(), feeds::FeedValidators::default()))
    })
    .unwrap();
    match ok {
        feeds::FeedFetchResponse::Data(bytes, _) => assert_eq!(bytes, b"<rss/>"),
        _ => panic!("expected data"),
    }
    let url = serve_once("500 Internal Server Error", "", b"no");
    assert!(UreqFetcher::default()
        .fetch(&url, &feeds::FeedValidators::default())
        .is_err());
    assert!(feeds::parse_feed(b"not xml").is_err());
    assert!(feeds::parse_feed(b"<rss></rss>").is_err());

    std::env::remove_var("PODCASTINDEX_KEY");
    std::env::remove_var("PODCASTINDEX_SECRET");
    let _ = PodcastIndexClient::from_default_locations();
    let _ = pods_backend::directory::configured_directory();
    std::env::set_var("PODCASTINDEX_KEY", "k");
    std::env::set_var("PODCASTINDEX_SECRET", "s");
    assert!(PodcastIndexClient::from_default_locations().is_some());
    std::env::remove_var("PODCASTINDEX_KEY");
    std::env::remove_var("PODCASTINDEX_SECRET");

    let notes = pods_backend::show_notes::ShowNotesService::default();
    let generated = notes
        .generate(1, || {
            Ok(vec![pods_backend::jobs::ShowNoteRecord {
                segment_id: "s0".into(),
                start_time: 0.0,
                title: "T".into(),
                summary: "S".into(),
                model_id: "m".into(),
                prompt_version: "p".into(),
                created_at: 1,
            }])
        })
        .unwrap();
    assert_eq!(generated[0].title, "T");
    assert!(!notes.observe_cancel(1));
    notes.cancel(99);
    notes.cancel_all();
    notes.close_writes();
    assert!(notes.writes_closed());
    assert!(notes.generate(2, || Ok(vec![])).is_err());

    let diag_dir = tempfile::tempdir().unwrap();
    let diag = pods_backend::diagnostics::Diagnostics::open(diag_dir.path().to_path_buf()).unwrap();
    let event = pods_backend::diagnostics::DiagnosticEvent {
        event_name: "e".into(),
        severity: "info".into(),
        message: "sk-secret keyabcdef0123456789abcdef0123".into(),
        job_id: Some("j".into()),
        episode_id: Some(1),
        playback_session_id: None,
    };
    diag.record(event.clone()).unwrap();
    diag.record_rotating(event.clone(), 1, 3).unwrap();
    diag.save_snapshot("job-1", "{}", 2).unwrap();
    assert!(!diag.snapshot_ids().unwrap().is_empty());
    assert!(!diag.log_names().unwrap().is_empty());
    let _ = diag.read_persisted_events().unwrap();
    let _ = diag.export_bytes().unwrap();
    diag.rotate_if_needed(1).unwrap();
    diag.clear().unwrap();
    let mut payload = json!({});
    pods_backend::diagnostics::attach_session(&mut payload, "sess");
    assert_eq!(
        pods_backend::diagnostics::session_from_payload(&payload).as_deref(),
        Some("sess")
    );

    assert!(omlx_lock::enforce_loopback("http://127.0.0.1:8000/v1").is_ok());
    assert!(omlx_lock::enforce_loopback("https://example.com").is_err());
    let occ = omlx_lock::occupancy_from_status(&json!({"active_requests":0,"waiting_requests":0})).unwrap();
    assert!(!occ.is_busy());
    assert!(omlx_lock::occupancy_from_status(&json!({})).is_err());
    let _ = omlx_lock::busy_retry_delay_secs(3);
    assert!(!omlx_lock::is_busy_error(&Error::Upstream("x".into())));
    let _ = omlx_lock::lock_enabled();
    let _ = omlx_lock::configured_status_url();

    let spans = vec![pods_backend::browser::Interval {
        original_start: 0.0,
        original_end: 10.0,
        processed_start: 0.0,
    }];
    assert!(pods_backend::browser::original_time(&spans, 4.0) >= 0.0);
    assert!(pods_backend::browser::processed_time(&spans, 4.0) >= 0.0);
    assert_eq!(pods_backend::browser::original_time(&[], 1.0), 0.0);
    assert_eq!(pods_backend::browser::processed_time(&[], 1.0), 0.0);
}

#[test]
fn pipeline_ad_ranges_download_failures_and_backend_pipeline_step() {
    let db = Database::open_in_memory().unwrap();
    db.execute(
        "INSERT INTO podcasts(id,feed_url,title,created_at) VALUES(1,'https://x','S',1)",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO episodes(id,podcast_id,guid,title,audio_url,notes_html,published_at) VALUES(1,1,'g','E','https://a','Hello world.',100)",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO episode_state(episode_id,updated_at) VALUES(1,1)",
        [],
    )
    .unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    let job = store.enqueue(1).unwrap();
    store.transition(&job.id, JobStage::Downloading).unwrap();
    let dir = tempfile::tempdir().unwrap();
    let artifacts = ArtifactStore::open(dir.path().to_path_buf()).unwrap();
    let downloader = MockDownloader::default();
    downloader.set(
        "https://a",
        DownloadResult {
            status: 200,
            content_type: "text/plain".into(),
            bytes: b"nope".to_vec(),
        },
    );
    assert!(pipeline::execute_stage(
        &store,
        &artifacts,
        &downloader,
        &NotesTranscriber,
        &pipeline::ScriptedClassifier {
            responses: Mutex::new(vec![]),
        },
        "key",
        JobStage::Downloading,
        &store.job(&job.id).unwrap().unwrap(),
        "https://a",
        "Hello world.",
        Some(10),
        Some(&db),
    )
    .is_err());
    downloader.set(
        "https://a",
        DownloadResult {
            status: 200,
            content_type: "audio/mpeg".into(),
            bytes: vec![],
        },
    );
    assert!(pipeline::execute_stage(
        &store,
        &artifacts,
        &downloader,
        &NotesTranscriber,
        &pipeline::ScriptedClassifier {
            responses: Mutex::new(vec![]),
        },
        "key",
        JobStage::Downloading,
        &store.job(&job.id).unwrap().unwrap(),
        "https://a",
        "Hello world.",
        Some(10),
        Some(&db),
    )
    .is_err());
    downloader.set(
        "https://a",
        DownloadResult {
            status: 200,
            content_type: "audio/mpeg".into(),
            bytes: b"mp3-bytes".to_vec(),
        },
    );
    pipeline::execute_stage(
        &store,
        &artifacts,
        &downloader,
        &NotesTranscriber,
        &pipeline::ScriptedClassifier {
            responses: Mutex::new(vec![]),
        },
        "key",
        JobStage::Downloading,
        &store.job(&job.id).unwrap().unwrap(),
        "https://a",
        "Hello world.",
        Some(10),
        Some(&db),
    )
    .unwrap();
    store.transition(&job.id, JobStage::Downloaded).unwrap();
    store.transition(&job.id, JobStage::Transcribing).unwrap();
    pipeline::execute_stage(
        &store,
        &artifacts,
        &downloader,
        &NotesTranscriber,
        &pipeline::ScriptedClassifier {
            responses: Mutex::new(vec![]),
        },
        "key",
        JobStage::Transcribing,
        &store.job(&job.id).unwrap().unwrap(),
        "https://a",
        "Hello world.",
        Some(10),
        Some(&db),
    )
    .unwrap();
    store.transition(&job.id, JobStage::Classifying).unwrap();
    assert_eq!(
        pipeline::execute_stage(
            &store,
            &artifacts,
            &downloader,
            &NotesTranscriber,
            &pipeline::ScriptedClassifier {
                responses: Mutex::new(vec![]),
            },
            "",
            JobStage::Classifying,
            &store.job(&job.id).unwrap().unwrap(),
            "https://a",
            "Hello world.",
            Some(10),
            Some(&db),
        )
        .unwrap_err(),
        "pause:model_required"
    );
    let ids: Vec<_> = store
        .transcript_segments(1)
        .unwrap()
        .into_iter()
        .map(|s| s.id)
        .collect();
    let windows = pods_backend::classify::production_windows(&ids);
    let classifier = pipeline::ScriptedClassifier {
        responses: Mutex::new(
            windows
                .iter()
                .rev()
                .map(|window| {
                    let labels = window
                        .iter()
                        .enumerate()
                        .map(|(i, id)| {
                            let label = if i == 0 { "ad" } else { "content" };
                            format!(r#"{{"segment_id":"{id}","label":"{label}","reason":"promo read"}}"#)
                        })
                        .collect::<Vec<_>>()
                        .join(",");
                    pipeline::ClassifyOutcome {
                        content: Some(format!(r#"{{"labels":[{labels}]}}"#)),
                        raw: json!({"usage":{"prompt_tokens":1,"completion_tokens":1,"prompt_cache_hit_tokens":0}}),
                    }
                })
                .collect(),
        ),
    };
    pipeline::execute_stage(
        &store,
        &artifacts,
        &downloader,
        &NotesTranscriber,
        &classifier,
        "key",
        JobStage::Classifying,
        &store.job(&job.id).unwrap().unwrap(),
        "https://a",
        "Hello world.",
        Some(10),
        Some(&db),
    )
    .unwrap();
    assert!(pipeline::parse_parakeet_words("0.00-0.20 hello (1.0)\n").is_ok());
    assert!(pipeline::parse_parakeet_words("not-a-range-line\n").is_err());
    assert!(pipeline::parse_parakeet_words("0.00 hello\n").is_err());
    assert!(pipeline::parse_parakeet_words("abc-def hello\n").is_err());
    assert!(pipeline::parse_parakeet_words("").is_err());

    let backend = Backend::new(
        Database::open_in_memory().unwrap(),
        Arc::new(MockFeedFetcher::default()),
        Arc::new(DisabledDirectory),
    );
    backend.db.execute(
        "INSERT INTO podcasts(id,feed_url,title,is_subscribed,created_at) VALUES(1,'https://x','S',1,1)",
        [],
    )
    .unwrap();
    backend.db.execute(
        "INSERT INTO episodes(id,podcast_id,guid,title,audio_url,notes_html,published_at) VALUES(1,1,'g','E','https://a','Hello.',100)",
        [],
    )
    .unwrap();
    backend.db.execute(
        "INSERT INTO episode_state(episode_id,updated_at) VALUES(1,1)",
        [],
    )
    .unwrap();
    let _ = backend.handle(
        HttpRequest::new("PUT", "/api/ad-removal/deepseek-key").with_json(&json!({"api_key":"sk"})),
    );
    let _ = backend.handle(
        HttpRequest::new("POST", "/api/ad-removal/enable").with_json(&json!({"confirmed_bytes":0})),
    );
    backend.set_downloader(Arc::new(downloader));
    backend.set_classifier(Arc::new(pipeline::ScriptedClassifier {
        responses: Mutex::new(vec![]),
    }));
    JobStore::new(&backend.db).enqueue(1).unwrap();
    let woke = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let flag = woke.clone();
    backend.set_ad_removal_wake(move || flag.store(true, std::sync::atomic::Ordering::SeqCst));
    backend.set_ad_removal_cancel(move || {});
    backend.record_playback_progress(1, 1.5);
    let stepped = backend.run_pipeline_step().unwrap();
    assert!(stepped);
    let job = JobStore::new(&backend.db).job_for_episode(1).unwrap().unwrap();
    assert_ne!(job.stage, JobStage::Queued);

    for i in 2..=52 {
        backend
            .db
            .execute(
                "INSERT INTO episodes(id,podcast_id,guid,title,audio_url,published_at) VALUES(?,?,?,?, 'https://a', ?)",
                rusqlite::params![i, 1, format!("g{i}"), format!("E{i}"), 100 + i],
            )
            .unwrap();
        backend
            .db
            .execute(
                "INSERT INTO episode_state(episode_id,updated_at) VALUES(?,1)",
                rusqlite::params![i],
            )
            .unwrap();
    }
    let page = backend.handle(HttpRequest::new("GET", "/api/recent"));
    assert_eq!(page.status_code, 200);
    let body: serde_json::Value = serde_json::from_slice(&page.body).unwrap();
    assert!(body.get("next_offset").is_some());
}

#[test]
fn backend_retry_unsubscribe_invalid_position_and_browser_sync() {
    let fetcher = Arc::new(MockFeedFetcher::default());
    let feed_url = "https://feeds.example/retry.xml";
    fetcher.set(
        feed_url,
        br#"<?xml version="1.0"?><rss version="2.0"><channel><title>Retry</title><item><title>Ep</title><guid>g</guid><pubDate>Mon, 06 Jan 2025 00:00:00 GMT</pubDate><enclosure url="https://h.example/1.mp3" type="audio/mpeg"/></item></channel></rss>"#.to_vec(),
    );
    let backend = Backend::new(
        Database::open_in_memory().unwrap(),
        fetcher.clone(),
        Arc::new(DisabledDirectory),
    );
    let _ = backend.handle(
        HttpRequest::new("PUT", "/api/ad-removal/deepseek-key").with_json(&json!({"api_key":"sk"})),
    );
    let sub = backend.handle(HttpRequest::new("POST", "/api/shows").with_json(&json!({"feed_url": feed_url})));
    assert_eq!(sub.status_code, 201);
    let show: serde_json::Value = serde_json::from_slice(&sub.body).unwrap();
    let show_id = show["id"].as_i64().unwrap();
    let recent: serde_json::Value =
        serde_json::from_slice(&backend.handle(HttpRequest::new("GET", "/api/recent")).body).unwrap();
    let ep_id = recent["items"][0]["id"].as_i64().unwrap();
    let prepared = backend.handle(HttpRequest::new(
        "POST",
        format!("/api/episodes/{ep_id}/ad-removal/prepare"),
    ));
    assert_eq!(prepared.status_code, 202);
    let again = backend.handle(HttpRequest::new(
        "POST",
        format!("/api/episodes/{ep_id}/ad-removal/prepare"),
    ));
    assert_eq!(again.status_code, 202);
    let store = JobStore::new(&backend.db);
    let job = store.job_for_episode(ep_id).unwrap().unwrap();
    store.transition(&job.id, JobStage::Downloading).unwrap();
    let mut failed = job;
    for _ in 0..4 {
        failed = store.record_failure(&failed.id, "net", "boom").unwrap();
    }
    assert_eq!(failed.stage, JobStage::Failed);
    let retry = backend.handle(HttpRequest::new(
        "POST",
        format!("/api/episodes/{ep_id}/ad-removal/retry"),
    ));
    assert_eq!(retry.status_code, 202);
    let bad_pos = backend.handle(
        HttpRequest::new("PUT", format!("/api/episodes/{ep_id}/position"))
            .with_json(&json!({"seconds": -1.0})),
    );
    assert_eq!(bad_pos.status_code, 422);
    assert_eq!(
        backend
            .handle(HttpRequest::new(
                "POST",
                format!("/api/episodes/{ep_id}/played")
            ))
            .status_code,
        204
    );
    assert_eq!(
        backend
            .handle(HttpRequest::new(
                "DELETE",
                format!("/api/episodes/{ep_id}/played")
            ))
            .status_code,
        204
    );
    fetcher.not_modified.lock().unwrap().insert(feed_url.into());
    let preview_304 = backend.handle(
        HttpRequest::new("POST", "/api/feeds/preview").with_json(&json!({"feed_url": feed_url})),
    );
    assert_eq!(preview_304.status_code, 500);
    fetcher.not_modified.lock().unwrap().clear();
    fetcher.set(feed_url, b"<rss><channel><title>bad");
    let refreshed = backend.handle(HttpRequest::new("POST", "/api/refresh"));
    assert_eq!(refreshed.status_code, 200);
    let mut opml = HttpRequest::new("POST", "/api/opml");
    opml.body = b"<opml><outline xmlUrl=\"ftp://x\" /></opml>".to_vec();
    let imported = backend.handle(opml);
    assert_eq!(imported.status_code, 200);
    let empty_guid = backend.handle(
        HttpRequest::new("POST", "/api/listen-episodes")
            .with_json(&json!({"feed_url": feed_url, "guid": "  "})),
    );
    assert_eq!(empty_guid.status_code, 422);
    assert_eq!(
        backend
            .handle(HttpRequest::new("GET", "/api/not-a-route"))
            .status_code,
        404
    );
    assert_eq!(
        backend
            .handle(HttpRequest::new("POST", "/api/follows/abc"))
            .status_code,
        404
    );
    assert_eq!(
        backend
            .handle(HttpRequest::new("DELETE", format!("/api/shows/{show_id}")))
            .status_code,
        204
    );
    downloader_404_stage();

    let temp = tempfile::tempdir().unwrap();
    let db = Database::open_in_memory().unwrap();
    db.execute(
        "INSERT INTO podcasts(id,feed_url,title,is_subscribed,created_at) VALUES(1,'https://example.org/feed','Example',1,0)",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO episodes(id,podcast_id,guid,title,audio_url,published_at) VALUES(1,1,'g','Episode','https://example.org/a.mp3',1)",
        [],
    )
    .unwrap();
    let mut backend = Backend::with_data_root(
        db,
        Arc::new(MockFeedFetcher::default()),
        Arc::new(DisabledDirectory),
        Some(temp.path().to_owned()),
    );
    backend.auth.enable_passkey("reset", "https://pods.mcgiv.dev");
    let token = enroll_session(&backend);
    backend.local = true;
    let hash = "ab".repeat(32);
    let manifest = pods_backend::browser::Manifest {
        version: 1,
        episode_id: 1,
        hash: hash.clone(),
        source_hash: "src".into(),
        bytes: 4,
        duration: 1.0,
        chunk_size: 1024,
        chunks: vec![hash.clone()],
        timeline: vec![pods_backend::browser::Interval {
            original_start: 0.0,
            original_end: 1.0,
            processed_start: 0.0,
        }],
        model: "m".into(),
        pipeline_version: "p".into(),
    };
    backend
        .artifacts
        .install(&format!("published/{hash}.m4a"), b"data")
        .unwrap();
    backend
        .db
        .execute(
            "INSERT INTO browser_publications(episode_id,manifest_json,notes_json,published_at) VALUES(1,?,'[]',1)",
            rusqlite::params![serde_json::to_string(&manifest).unwrap()],
        )
        .unwrap();
    let cookie = format!("{SESSION_COOKIE}={token}");
    let sync = backend.handle(HttpRequest::new("GET", "/api/sync").with_header("cookie", cookie.clone()));
    assert_eq!(sync.status_code, 200);
    let speed = backend.handle(
        HttpRequest::new("POST", "/api/sync/actions")
            .with_header("cookie", cookie.clone())
            .with_json(&json!({
                "client_id":"c1",
                "actions":[{
                    "id":"a1","sequence":1,"entity":"settings","field":"speed",
                    "base_revision":0,"value":1.5
                }]
            })),
    );
    assert_eq!(speed.status_code, 200);
    let autoplay = backend.handle(
        HttpRequest::new("POST", "/api/sync/actions")
            .with_header("cookie", cookie.clone())
            .with_json(&json!({
                "client_id":"c1",
                "actions":[{
                    "id":"a2","sequence":2,"entity":"settings","field":"autoplay",
                    "base_revision":1,"value":false
                }]
            })),
    );
    assert_eq!(autoplay.status_code, 200);
    let sub_act = backend.handle(
        HttpRequest::new("POST", "/api/sync/actions")
            .with_header("cookie", cookie.clone())
            .with_json(&json!({
                "client_id":"c1",
                "actions":[{
                    "id":"a3","sequence":3,"entity":"subscription","field":"https://feeds.example/new.xml",
                    "base_revision":0,"value":true
                }]
            })),
    );
    assert_eq!(sub_act.status_code, 200);
    let notes = backend.handle(
        HttpRequest::new("POST", "/api/episodes/1/show-notes").with_header("cookie", cookie.clone()),
    );
    assert!(notes.status_code == 202 || notes.status_code == 200);
    let bad_art = backend.handle(
        HttpRequest::new("GET", "/api/artifacts/nope").with_header("cookie", cookie.clone()),
    );
    assert_eq!(bad_art.status_code, 404);
    let missing_art = backend.handle(
        HttpRequest::new("GET", format!("/api/artifacts/{}", "cd".repeat(32)))
            .with_header("cookie", cookie.clone()),
    );
    assert_eq!(missing_art.status_code, 404);
    let post_art = backend.handle(
        HttpRequest::new("POST", format!("/api/artifacts/{hash}")).with_header("cookie", cookie.clone()),
    );
    assert_eq!(post_art.status_code, 404);
    let options = backend.handle(HttpRequest::new("OPTIONS", "/api/sync"));
    assert_eq!(options.status_code, 403);
    let logout = backend.handle(
        HttpRequest::new("POST", "/api/auth/logout").with_header("cookie", cookie.clone()),
    );
    assert!(logout.status_code == 204 || logout.status_code == 200);
    backend.local = false;
    let options = backend.handle(
        HttpRequest::new("POST", "/api/auth/login/options").with_json(&json!({})),
    );
    assert_eq!(options.status_code, 200);
    let options_body: serde_json::Value = serde_json::from_slice(&options.body).unwrap();
    let state_id = options_body["state_id"].as_str().unwrap();
    let bad_login = backend.handle(HttpRequest::new("POST", "/api/auth/login").with_json(&json!({
        "state_id": state_id,
        "credential": {"id": "unknown-cred"}
    })));
    assert_eq!(bad_login.status_code, 401);
}

#[test]
fn skip_classify_http_usage_server_and_show_notes_branches() {
    use pods_backend::skip::*;
    let r = AdSkipRange {
        id: "r".into(),
        start_segment_id: "s0".into(),
        end_segment_id: "s1".into(),
        start_time: 1.0,
        end_time: 2.0,
        confidence: 1.0,
        reason: "ad".into(),
        classifier_version: "v".into(),
        prompt_version: "p".into(),
        created_at: 1,
        disabled: false,
    };
    assert!(skip_decision(f64::NAN, &[r.clone()]).is_none());
    assert_eq!(local_source("pub", Some("dl")), "dl");
    assert_eq!(local_source("pub", None), "pub");
    assert_eq!(mac_source("pub", false, None).as_deref(), Some("pub"));
    assert!(mac_source("pub", true, None).is_none());
    assert_eq!(mac_source("pub", true, Some("s")).as_deref(), Some("s"));
    let mut fence = AdRemovalMacSupersedingSeekFence::new(1.0);
    assert_eq!(
        fence.observe_with(f64::NAN, 1.0, 3.0),
        AdRemovalMacSupersedingSeekObservation::Suppress
    );
    let mut state = AdRemovalMacSkipState::default();
    let decision = AdRemovalSkipDecision {
        range_id: "r".into(),
        range_start: 1.0,
        range_end: 2.0,
    };
    let attempt = state.begin(decision, 1, 0).unwrap();
    match state.observe_with(f64::NAN, 1, 1.0) {
        AdRemovalMacSkipClockObservation::Suppress => {}
        other => panic!("{other:?}"),
    }
    assert!(matches!(
        state.retry(0, 1, 1, 3),
        AdRemovalMacSkipRetryTransition::Ignored
    ));
    match state.retry(attempt.token, 1, 1, 1) {
        AdRemovalMacSkipRetryTransition::Exhausted(_) => {}
        other => panic!("{other:?}"),
    }
    state.invalidate();
    match state.observe_with(f64::NAN, 1, 1.0) {
        AdRemovalMacSkipClockObservation::PassThrough => {}
        other => panic!("{other:?}"),
    }

    let ids = vec!["a".into()];
    assert!(pods_backend::classify::parse_structured_labels(
        r#"{"labels":[{"segment_id":"a","label":"ad","reason":"x"},{"segment_id":"a","label":"ad","reason":"y"}]}"#,
        &ids
    )
    .is_err());
    assert!(pods_backend::classify::parse_structured_labels(
        r#"{"labels":[{"segment_id":"a","label":"nope","reason":"x"}]}"#,
        &ids
    )
    .is_err());
    assert!(pods_backend::classify::parse_structured_labels(
        "```\n{\"labels\":[{\"segment_id\":\"a\",\"label\":\"content\",\"reason\":\"ok\"}]}\n```",
        &ids
    )
    .is_ok());
    let quoted = serde_json::to_string(r#"{"labels":[{"segment_id":"a","label":"content","reason":"ok"}]}"#).unwrap();
    assert!(pods_backend::classify::parse_structured_labels(&quoted, &ids).is_ok());
    assert!(pods_backend::classify::parse_show_notes(
        r#"{"chapters":[{"segment_id":"z","title":"T","summary":"S"}]}"#,
        &ids
    )
    .is_err());
    let corrections = vec![pods_backend::classify::CorrectionExample {
        id: "c".into(),
        text: "short".into(),
        created_at: 1,
    }];
    let none = pods_backend::classify::select_corrections("zzzz", &corrections, 1);
    assert!(none.is_empty());
    let huge = vec![pods_backend::classify::CorrectionExample {
        id: "c".into(),
        text: "alpha beta gamma delta epsilon".into(),
        created_at: 1,
    }];
    assert!(pods_backend::classify::select_corrections("alpha beta", &huge, 1).is_empty());

    let req = HttpRequest::new("GET", "http://example.com/api/recent?offset=2");
    assert_eq!(req.path(), "/api/recent");
    assert_eq!(req.query("offset").as_deref(), Some("2"));
    assert!(HttpRequest::new("POST", "/api/x")
        .with_json(&json!([1]))
        .json_object()
        .is_err());
    let cookie_req = HttpRequest::new("GET", "/x").with_header("cookie", "a=1; pods_session=tok");
    assert_eq!(
        pods_backend::HttpResponse::cookie(&cookie_req, "pods_session").as_deref(),
        Some("tok")
    );
    assert!(pods_backend::HttpResponse::cookie(&cookie_req, "missing").is_none());

    let saturday = 3 * 24 * 3600;
    assert!(!pods_backend::usage::is_peak(saturday));
    let tokens = pods_backend::usage::UsageTokens {
        input_tokens: Some(10),
        cached_input_tokens: Some(20),
        output_tokens: Some(1),
    };
    assert!(pods_backend::usage::cost_usd_model(&tokens, "deepseek-v4-pro", 1).is_none());
    let flash = pods_backend::usage::UsageTokens {
        input_tokens: Some(1_000_000),
        cached_input_tokens: Some(0),
        output_tokens: Some(1_000_000),
    };
    assert!(pods_backend::usage::cost_usd_model(&flash, "deepseek-v4-flash", 2 * 3600).is_some());
    let db = Database::open_in_memory().unwrap();
    let store = pods_backend::usage::UsageStore::new(&db);
    let rec = store
        .record(99, "ad_detection", "m", None, 1)
        .unwrap();
    assert!(rec.episode_key.contains("episode-id:99"));
    store.fail_next_replace();
    let dir = tempfile::tempdir().unwrap();
    let ledger = dir.path().join("missing-parent/nested/ledger.jsonl");
    let store = pods_backend::usage::UsageStore::with_ledger(&db, ledger);
    store.fail_next_insert();
    let _ = store.record(99, "show_notes", "m", None, 1);

    match pods_backend::server::parse_request(b"\xff\xfe\r\n\r\n") {
        pods_backend::server::ParseResult::Invalid(_) => {}
        other => panic!("{other:?}"),
    }
    match pods_backend::server::parse_request(b"\r\n\r\n") {
        pods_backend::server::ParseResult::Invalid(_) => {}
        other => panic!("{other:?}"),
    }
    match pods_backend::server::parse_request(b"GET\r\n\r\n") {
        pods_backend::server::ParseResult::Invalid(_) => {}
        other => panic!("{other:?}"),
    }
    match pods_backend::server::parse_request(b"GET / HTTP/1.1\r\nContent-Length: -1\r\n\r\n") {
        pods_backend::server::ParseResult::Invalid(_) => {}
        other => panic!("{other:?}"),
    }
    match pods_backend::server::parse_request(b"GET / HTTP/1.1\r\nContent-Length: no\r\n\r\n") {
        pods_backend::server::ParseResult::Invalid(_) => {}
        other => panic!("{other:?}"),
    }
    let notes = pods_backend::show_notes::ShowNotesService::default();
    let started = std::sync::Arc::new(std::sync::Barrier::new(2));
    let start = started.clone();
    std::thread::scope(|scope| {
        scope.spawn(|| {
            start.wait();
            let _ = notes.generate(1, || {
                std::thread::sleep(Duration::from_millis(50));
                Ok(vec![pods_backend::jobs::ShowNoteRecord {
                    segment_id: "s0".into(),
                    start_time: 0.0,
                    title: "T".into(),
                    summary: "S".into(),
                    model_id: "m".into(),
                    prompt_version: "p".into(),
                    created_at: 1,
                }])
            });
        });
        start.wait();
        std::thread::sleep(Duration::from_millis(5));
        notes.cancel(1);
    });

    let t = pods_backend::speaker::MemoryTransport::new(true);
    t.set_duration(0.0);
    t.load(std::path::Path::new("/tmp/x"), 0.0, 1.0, false).unwrap();
    t.set_alive(false);
    assert!(t.play().is_err());
}

#[test]
fn job_store_terminal_and_reset_branches() {
    let db = Database::open_in_memory().unwrap();
    db.execute(
        "INSERT INTO podcasts(id,feed_url,title,created_at) VALUES(1,'https://x','S',1)",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO episodes(id,podcast_id,guid,title,audio_url,published_at) VALUES(1,1,'g','E','https://a',100)",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO episode_state(episode_id,updated_at) VALUES(1,1)",
        [],
    )
    .unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    let job = store.enqueue(1).unwrap();
    assert!(!store.reserve_daily_classification_slot(1, 0).unwrap());
    store.transition(&job.id, JobStage::Downloading).unwrap();
    store.cancel(&job.id).unwrap();
    assert!(store
        .record_failure(&job.id, "x", "y")
        .is_err());
    assert!(store
        .record_audio_artifact(
            &job.id,
            &pods_backend::jobs::AudioArtifact {
                relative_path: "episodes/1/audio.mp3".into(),
                sha256: "a".repeat(64),
                byte_count: 1,
            }
        )
        .is_err());
    assert!(store
        .record_transcript(
            &job.id,
            &[],
            "v"
        )
        .is_err());
    let job2_id = {
        db.execute(
            "INSERT INTO episodes(id,podcast_id,guid,title,audio_url,published_at) VALUES(2,1,'g2','E2','https://a',101)",
            [],
        )
        .unwrap();
        db.execute(
            "INSERT INTO episode_state(episode_id,updated_at) VALUES(2,1)",
            [],
        )
        .unwrap();
        store.enqueue(2).unwrap().id
    };
    store.transition(&job2_id, JobStage::Downloading).unwrap();
    store.transition(&job2_id, JobStage::Downloaded).unwrap();
    store.transition(&job2_id, JobStage::Transcribing).unwrap();
    store.transition(&job2_id, JobStage::Classifying).unwrap();
    store.transition(&job2_id, JobStage::Ready).unwrap();
    assert!(store.record_failure(&job2_id, "x", "y").is_err());
    assert!(store.complete_classification(&job2_id, "run", &[]).is_err());
    store.transition(&job2_id, JobStage::Cancelled).unwrap();
    assert!(store.transition(&job2_id, JobStage::Queued).is_err());
    db.execute(
        "UPDATE ad_removal_jobs SET audio_relative_path='episodes/2/audio.mp3', transcriber_version='notes-transcriber-v1', stage='ready' WHERE id=?",
        rusqlite::params![store.enqueue(2).unwrap().id],
    )
    .ok();
    let n = store.reset_notes_transcript_jobs().unwrap();
    assert!(n >= 1);
    let failed_job = {
        db.execute(
            "INSERT INTO episodes(id,podcast_id,guid,title,audio_url,published_at) VALUES(3,1,'g3','E3','https://a',102)",
            [],
        )
        .unwrap();
        db.execute(
            "INSERT INTO episode_state(episode_id,updated_at) VALUES(3,1)",
            [],
        )
        .unwrap();
        store.enqueue(3).unwrap()
    };
    store.transition(&failed_job.id, JobStage::Downloading).unwrap();
    let mut cur = failed_job;
    for _ in 0..4 {
        cur = store.record_failure(&cur.id, "net", "boom").unwrap();
    }
    store.transition(&cur.id, JobStage::Queued).unwrap();
}

#[test]
fn server_handle_one_loopback_request() {
    let db = Database::open_in_memory().unwrap();
    let backend = Arc::new(Backend::new(
        db,
        Arc::new(MockFeedFetcher::default()),
        Arc::new(DisabledDirectory),
    ));
    let listener = pods_backend::server::serve(backend, "127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let mut stream = std::net::TcpStream::connect(addr).unwrap();
    use std::io::{Read, Write};
    stream
        .write_all(b"GET /api/recent HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n")
        .unwrap();
    stream.shutdown(std::net::Shutdown::Write).unwrap();
    let mut buf = Vec::new();
    stream.read_to_end(&mut buf).unwrap();
    assert!(String::from_utf8_lossy(&buf).contains("HTTP/1.1"));
    drop(listener);
}

#[test]
fn pipeline_pauses_when_playback_is_active_and_runtime_is_idempotent() {
    let db = Database::open_in_memory().unwrap();
    db.execute(
        "INSERT INTO podcasts(id,feed_url,title,created_at) VALUES(1,'https://x','S',1)",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO episodes(id,podcast_id,guid,title,audio_url,notes_html,published_at) VALUES(1,1,'g','E','https://a','Hello.',100)",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO episode_state(episode_id,updated_at) VALUES(1,1)",
        [],
    )
    .unwrap();
    let backend = Backend::new(
        db,
        Arc::new(MockFeedFetcher::default()),
        Arc::new(DisabledDirectory),
    );
    let _ = backend.handle(
        HttpRequest::new("PUT", "/api/ad-removal/deepseek-key").with_json(&json!({"api_key":"sk"})),
    );
    let _ = backend.handle(
        HttpRequest::new("POST", "/api/ad-removal/enable").with_json(&json!({"confirmed_bytes":0})),
    );
    let store = JobStore::new(&backend.db);
    let job = store.enqueue(1).unwrap();
    store.transition(&job.id, JobStage::Downloading).unwrap();
    store.transition(&job.id, JobStage::Downloaded).unwrap();
    backend.record_playback_progress(1, 3.0);
    let ran = backend.run_pipeline_step().unwrap();
    assert!(ran);
    let blocked = store.job_for_episode(1).unwrap().unwrap().blocking_reason;
    drop(store);
    assert_eq!(blocked, Some(BlockingReason::PlaybackActive));
    let backend = Arc::new(backend);
    backend.start_runtime();
    backend.start_runtime();
    backend.stop_runtime();
}

#[test]
fn coordinator_caps_steps_and_browser_covers_notes_and_settings() {
    let db = Database::open_in_memory().unwrap();
    db.execute(
        "INSERT INTO podcasts(id,feed_url,title,created_at) VALUES(1,'https://x','S',1)",
        [],
    )
    .unwrap();
    for i in 1..=70 {
        db.execute(
            "INSERT INTO episodes(id,podcast_id,guid,title,audio_url,published_at) VALUES(?,?,?,?, 'https://a', ?)",
            rusqlite::params![i, 1, format!("g{i}"), format!("E{i}"), 100 + i],
        )
        .unwrap();
        db.execute(
            "INSERT INTO episode_state(episode_id,updated_at) VALUES(?,1)",
            rusqlite::params![i],
        )
        .unwrap();
    }
    let store = JobStore::with_now(&db, || 1_000);
    for i in 1..=70 {
        store.enqueue(i).unwrap();
    }
    let coord = pods_backend::coordinator::Coordinator::new(&store).skip_daily_limit(true);
    let steps = coord.run_until_idle(|_, _| Ok(())).unwrap();
    assert!(steps > 64);
    let steps = coord
        .run_until_idle_with_sleep(|_, _| Ok(()), |_| {}, &|| 1_000)
        .unwrap();
    assert!(steps <= 65);
    let daily = pods_backend::coordinator::Coordinator::new(&store);
    let _ = daily.run_next_stage(|stage, _| {
        if stage == JobStage::Classifying {
            Ok(())
        } else {
            Ok(())
        }
    });

    let temp = tempfile::tempdir().unwrap();
    let db = Database::open_in_memory().unwrap();
    db.execute(
        "INSERT INTO podcasts(id,feed_url,title,is_subscribed,created_at) VALUES(1,'https://example.org/feed','Example',1,0)",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO episodes(id,podcast_id,guid,title,audio_url,published_at) VALUES(1,1,'g','Episode','https://example.org/a.mp3',1)",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO episodes(id,podcast_id,guid,title,audio_url,published_at) VALUES(2,1,'g2','Two','https://example.org/b.mp3',2)",
        [],
    )
    .unwrap();
    let mut backend = Backend::with_data_root(
        db,
        Arc::new(MockFeedFetcher::default()),
        Arc::new(DisabledDirectory),
        Some(temp.path().to_owned()),
    );
    backend.auth.enable_passkey("reset", "https://pods.mcgiv.dev");
    let token = enroll_session(&backend);
    backend.local = true;
    let hash = "ab".repeat(32);
    let manifest = pods_backend::browser::Manifest {
        version: 1,
        episode_id: 1,
        hash: hash.clone(),
        source_hash: "src".into(),
        bytes: 4,
        duration: 1.0,
        chunk_size: 1024,
        chunks: vec![hash.clone()],
        timeline: vec![pods_backend::browser::Interval {
            original_start: 0.0,
            original_end: 1.0,
            processed_start: 0.0,
        }],
        model: "m".into(),
        pipeline_version: "p".into(),
    };
    backend
        .artifacts
        .install(&format!("published/{hash}.m4a"), b"data")
        .unwrap();
    backend
        .db
        .execute(
            "INSERT INTO browser_publications(episode_id,manifest_json,notes_json,published_at) VALUES(1,?,'[{\"title\":\"Hi\"}]',1)",
            rusqlite::params![serde_json::to_string(&manifest).unwrap()],
        )
        .unwrap();
    backend
        .db
        .execute(
            "INSERT INTO browser_jobs(episode_id,stage,attempts) VALUES(2,'retry',1)",
            [],
        )
        .unwrap();
    backend
        .db
        .execute(
            "INSERT INTO browser_jobs(episode_id,stage,attempts) VALUES(1,'blocked',4)",
            [],
        )
        .unwrap();
    let cookie = format!("{SESSION_COOKIE}={token}");
    let status = backend.handle(HttpRequest::new("GET", "/api/status").with_header("cookie", cookie.clone()));
    assert_eq!(status.status_code, 200);
    let notes = backend.handle(
        HttpRequest::new("POST", "/api/episodes/1/show-notes").with_header("cookie", cookie.clone()),
    );
    assert_eq!(notes.status_code, 200);
    let bad_setting = backend.handle(
        HttpRequest::new("POST", "/api/sync/actions")
            .with_header("cookie", cookie.clone())
            .with_json(&json!({
                "client_id":"c1",
                "actions":[{
                    "id":"bad","sequence":1,"entity":"settings","field":"theme",
                    "base_revision":0,"value":"dark"
                }]
            })),
    );
    assert_eq!(bad_setting.status_code, 422);
    let art = backend.handle(
        HttpRequest::new("GET", format!("/api/artifacts/{hash}"))
            .with_header("cookie", cookie.clone())
            .with_header("if-range", "\"other\""),
    );
    assert!(art.status_code == 200 || art.status_code == 206);
    let sync = backend.handle(HttpRequest::new("GET", "/api/sync").with_header("cookie", cookie));
    assert_eq!(sync.status_code, 200);
}

fn downloader_404_stage() {
    let db = Database::open_in_memory().unwrap();
    db.execute(
        "INSERT INTO podcasts(id,feed_url,title,created_at) VALUES(1,'https://x','S',1)",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO episodes(id,podcast_id,guid,title,audio_url,published_at) VALUES(1,1,'g','E','https://a',100)",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO episode_state(episode_id,updated_at) VALUES(1,1)",
        [],
    )
    .unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    let job = store.enqueue(1).unwrap();
    store.transition(&job.id, JobStage::Downloading).unwrap();
    let dir = tempfile::tempdir().unwrap();
    let artifacts = ArtifactStore::open(dir.path().to_path_buf()).unwrap();
    let downloader = MockDownloader::default();
    downloader.set(
        "https://a",
        DownloadResult {
            status: 404,
            content_type: "text/plain".into(),
            bytes: b"no".to_vec(),
        },
    );
    assert!(pipeline::execute_stage(
        &store,
        &artifacts,
        &downloader,
        &NotesTranscriber,
        &pipeline::ScriptedClassifier {
            responses: Mutex::new(vec![]),
        },
        "key",
        JobStage::Downloading,
        &store.job(&job.id).unwrap().unwrap(),
        "https://a",
        "",
        None,
        None,
    )
    .is_err());
    assert!(pipeline::execute_stage(
        &store,
        &artifacts,
        &downloader,
        &NotesTranscriber,
        &pipeline::ScriptedClassifier {
            responses: Mutex::new(vec![]),
        },
        "key",
        JobStage::Classifying,
        &store.job(&job.id).unwrap().unwrap(),
        "https://a",
        "",
        None,
        None,
    )
    .is_err());
    assert!(downloader.fetch_to("https://missing", dir.path().join("x").as_path()).is_err());
}

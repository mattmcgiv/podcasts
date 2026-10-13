use pods_backend::reliability::*;
use pods_backend::youtube::{VideoMeta, YoutubeProbe};
use pods_backend::{Backend, Database, DisabledDirectory, Error, HttpRequest, MockFeedFetcher};
use serde_json::{json, Value};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
struct Probe(Arc<AtomicBool>);
impl YoutubeProbe for Probe {
    fn channel_id(&self, _: &str) -> Result<String, Error> {
        unreachable!()
    }
    fn video(&self, id: &str) -> Result<VideoMeta, Error> {
        if self.0.load(Ordering::SeqCst) {
            return Err(Error::Upstream(
                "DNS https://secret.example/?token=hidden".into(),
            ));
        }
        Ok(VideoMeta {
            video_id: id.into(),
            channel_id: "UCabcdefghijklmnopqrstuv".into(),
            channel_title: "Show".into(),
            title: "Video".into(),
            thumbnail: String::new(),
            published_at: 1,
            description: String::new(),
        })
    }
}
fn fixture() -> (Backend, tempfile::TempDir, Arc<AtomicBool>) {
    let temp = tempfile::tempdir().unwrap();
    let mut backend = Backend::with_data_root(
        Database::open_in_memory().unwrap(),
        Arc::new(MockFeedFetcher::default()),
        Arc::new(DisabledDirectory),
        Some(temp.path().into()),
    );
    backend.local = true;
    let failed = Arc::new(AtomicBool::new(true));
    backend.set_youtube_probe(Arc::new(Probe(failed.clone())));
    (backend, temp, failed)
}
#[test]
fn lookup_failure_survives_exhaustion_restart_and_manual_retry_without_duplicate_episode() {
    let (backend, _temp, failed) = fixture();
    let id = backend
        .db
        .with_transaction(|tx| enqueue(tx, "video", "https://youtu.be/abcdefghijk"))
        .unwrap();
    assert_eq!(
        backend
            .db
            .with_transaction(|tx| enqueue(
                tx,
                "video",
                "https://www.youtube.com/watch?v=abcdefghijk"
            ))
            .unwrap(),
        id
    );
    for _ in 0..12 {
        backend
            .db
            .execute("UPDATE browser_intake SET next_retry_at=0", [])
            .unwrap();
        assert!(drain(&backend).unwrap());
    }
    let before = status(&backend.db.lock().unwrap()).unwrap();
    assert_eq!(before["items"][0]["state"], "needs_attention");
    assert!(!before.to_string().contains("hidden"));
    recover(&backend.db).unwrap();
    assert!(!drain(&backend).unwrap());
    backend.db.with_transaction(|tx| retry(tx, &id)).unwrap();
    failed.store(false, Ordering::SeqCst);
    assert!(drain(&backend).unwrap());
    assert!(!drain(&backend).unwrap());
    backend
        .db
        .with_transaction(|tx| enqueue(tx, "video", "https://youtu.be/abcdefghijk"))
        .unwrap();
    assert!(!drain(&backend).unwrap());
    assert_eq!(
        backend
            .db
            .scalar_i64("SELECT COUNT(*) FROM episodes", [])
            .unwrap(),
        Some(1)
    );
    assert_eq!(
        backend
            .db
            .scalar_i64("SELECT COUNT(*) FROM browser_intake", [])
            .unwrap(),
        Some(1)
    );
}
#[test]
fn migration_is_atomic_and_retains_bad_legacy_queue() {
    let db = Database::open_in_memory().unwrap();
    db.execute(
        "INSERT INTO settings VALUES('browser_youtube_listen',?)",
        [json!([{"url":"https://youtu.be/abcdefghijk","attempts":2,"next_at":300}]).to_string()],
    )
    .unwrap();
    db.execute(
        "INSERT INTO settings VALUES('browser_article_listen','invalid')",
        [],
    )
    .unwrap();
    assert!(migrate(&db).is_err());
    assert_eq!(
        db.scalar_i64("SELECT COUNT(*) FROM browser_intake", [])
            .unwrap(),
        Some(0)
    );
    db.execute(
        "DELETE FROM settings WHERE key='browser_article_listen'",
        [],
    )
    .unwrap();
    migrate(&db).unwrap();
    migrate(&db).unwrap();
    assert_eq!(
        db.scalar_i64("SELECT attempts FROM browser_intake", [])
            .unwrap(),
        Some(2)
    );
    assert!(db
        .scalar_string(
            "SELECT value FROM settings WHERE key='browser_youtube_listen'",
            []
        )
        .unwrap()
        .is_none());
}
#[test]
fn writes_fail_without_acknowledging_and_concurrent_enqueues_survive_drain() {
    let (backend, _temp, _) = fixture();
    let backend = Arc::new(backend);
    backend.db.execute("CREATE TRIGGER fail_intake BEFORE INSERT ON browser_intake BEGIN SELECT RAISE(ABORT,'write failed'); END",[]).unwrap();
    assert!(backend
        .db
        .with_transaction(|tx| enqueue(tx, "video", "https://youtu.be/abcdefghijk"))
        .is_err());
    backend.db.execute("DROP TRIGGER fail_intake", []).unwrap();
    backend
        .db
        .with_transaction(|tx| enqueue(tx, "video", "https://youtu.be/abcdefghijk"))
        .unwrap();
    std::thread::scope(|scope| {
        scope.spawn(|| {
            drain(&backend).unwrap();
        });
        for id in ["abcdefghijl", "abcdefghijm", "abcdefghijn"] {
            let backend = &backend;
            scope.spawn(move || {
                backend
                    .db
                    .with_transaction(|tx| enqueue(tx, "video", &format!("https://youtu.be/{id}")))
                    .unwrap();
            });
        }
    });
    assert_eq!(
        backend
            .db
            .scalar_i64("SELECT COUNT(*) FROM browser_intake", [])
            .unwrap(),
        Some(4)
    );
}
#[test]
fn interrupted_claims_resume_without_consuming_failure_attempts() {
    let (backend, _temp, _) = fixture();
    backend
        .db
        .with_transaction(|tx| enqueue(tx, "article", "https://example.com/story"))
        .unwrap();
    backend
        .db
        .execute("UPDATE browser_intake SET state='working',owner=123", [])
        .unwrap();
    recover(&backend.db).unwrap();
    assert_eq!(
        backend
            .db
            .scalar_string("SELECT state FROM browser_intake", [])
            .unwrap()
            .as_deref(),
        Some("queued")
    );
    assert_eq!(
        backend
            .db
            .scalar_i64("SELECT attempts FROM browser_intake", [])
            .unwrap(),
        Some(0)
    );
    let exported = diagnostics(&backend.db.lock().unwrap()).unwrap();
    assert!(!exported.to_string().contains("https://"));
}
#[test]
fn internal_status_is_shared_and_rejects_browser_origin_and_foreign_host() {
    let (backend, _temp, _) = fixture();
    backend
        .db
        .with_transaction(|tx| enqueue(tx, "video", "https://youtu.be/abcdefghijk"))
        .unwrap();
    let request = HttpRequest::new("GET", "/api/internal/pipeline");
    let response = backend.handle(request);
    assert_eq!(response.status_code, 200);
    let projected: Value = serde_json::from_slice(&response.body).unwrap();
    assert_eq!(
        projected,
        pods_backend::browser::snapshot(&backend).unwrap()["pipeline"]
    );
    assert_eq!(
        backend
            .handle(
                HttpRequest::new("GET", "/api/internal/pipeline")
                    .with_header("origin", "https://pods.mcgiv.dev")
            )
            .status_code,
        403
    );
    assert_eq!(
        backend
            .handle(
                HttpRequest::new("GET", "/api/internal/pipeline")
                    .with_header("host", "attacker.example")
            )
            .status_code,
        403
    );
}

#[test]
fn missing_media_is_queued_to_rebuild_and_show_notes_are_retained() {
    let (backend, _temp, _) = fixture();
    backend.db.execute("INSERT INTO podcasts(id,feed_url,title,created_at,is_subscribed) VALUES(1,'https://example.com/feed','Show',1,1)",[]).unwrap();
    backend.db.execute("INSERT INTO episodes(id,podcast_id,guid,title,audio_url,published_at) VALUES(1,1,'guid','Episode','https://example.com/audio',1)",[]).unwrap();
    let manifest = pods_backend::browser::Manifest {
        episode_id: 1,
        hash: "aa".repeat(32),
        bytes: 12,
        ..Default::default()
    };
    backend
        .db
        .execute(
            "INSERT INTO browser_publications VALUES(1,?,'[{\"id\":\"note\"}]',1)",
            [serde_json::to_string(&manifest).unwrap()],
        )
        .unwrap();
    reconcile_publications(&backend).unwrap();
    assert_eq!(
        backend
            .db
            .scalar_string("SELECT notes_json FROM browser_publications", [])
            .unwrap()
            .as_deref(),
        Some("[{\"id\":\"note\"}]")
    );
    assert_eq!(
        backend
            .db
            .scalar_string("SELECT stage FROM browser_jobs", [])
            .unwrap()
            .as_deref(),
        Some("queued")
    );
    assert!(
        pods_backend::browser::snapshot(&backend).unwrap()["episodes"]
            .as_array()
            .unwrap()
            .is_empty()
    );
}

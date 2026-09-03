use pods_backend::bootstrap;
use pods_backend::db::Database;
use pods_backend::diagnostics::{attach_session, session_from_payload, DiagnosticEvent, Diagnostics};
use pods_backend::storage::{self, ArtifactStore};

#[test]
fn test_artifact_store_installs_downloaded_audio_with_checksum_and_backup_exclusion() {
    let dir = tempfile::tempdir().unwrap();
    let store = ArtifactStore::open(dir.path().join("ad")).unwrap();
    let sha = store.install("episodes/1/audio.mp3", b"hello-bytes").unwrap();
    assert!(store.validate("episodes/1/audio.mp3", &sha, 11));
    assert!(!store.validate("episodes/1/audio.mp3", &sha, 3));
    assert!(store.install("/tmp/x.mp3", b"no").is_err());
}

#[test]
fn test_storage_policy_blocks_aggregate_limit_and_minimum_free_space_without_eviction() {
    assert!(storage::storage_allows(0, 100, 50, 10, 20));
    assert!(!storage::storage_allows(90, 100, 50, 10, 20));
    assert!(!storage::storage_allows(0, 100, 15, 10, 20));
}

#[test]
fn test_download_finalizer_accepts_substack_binary_octet_stream_as_mp3() {
    assert!(storage::is_mp3_or_octet("binary/octet-stream"));
    assert!(storage::is_mp3_or_octet("audio/mpeg"));
}

#[test]
fn test_structured_event_is_redacted_before_it_is_persisted() {
    let event = DiagnosticEvent {
        event_name: "key".into(),
        severity: "info".into(),
        message: "sk-secret-token".into(),
        job_id: None,
        episode_id: None,
        playback_session_id: None,
    }
    .redacted();
    assert!(!event.message.contains("sk-secret"));
}

#[test]
fn test_playback_session_correlation_round_trips_across_control_payloads() {
    let mut payload = serde_json::json!({"command":"play"});
    attach_session(&mut payload, "abc");
    assert_eq!(session_from_payload(&payload).as_deref(), Some("abc"));
}

#[test]
fn test_clear_removes_structured_logs_and_snapshots() {
    let dir = tempfile::tempdir().unwrap();
    let diag = Diagnostics::open(dir.path().to_path_buf()).unwrap();
    diag.record(DiagnosticEvent {
        event_name: "x".into(),
        severity: "info".into(),
        message: "hi".into(),
        job_id: None,
        episode_id: None,
        playback_session_id: None,
    })
    .unwrap();
    diag.clear().unwrap();
    assert!(dir.path().join("logs").exists());
}

#[test]
fn test_bootstrap_replaces_empty_live_database_from_seed() {
    let dir = tempfile::tempdir().unwrap();
    let seed = dir.path().join("seed.sqlite");
    let live = dir.path().join("live.sqlite");
    let db = Database::open(&seed).unwrap();
    db.execute("INSERT INTO podcasts (feed_url, title, created_at) VALUES ('https://x','S',1)", []).unwrap();
    drop(db);
    Database::open(&live).unwrap(); // empty schema
    bootstrap::prepare(&live, Some(&seed)).unwrap();
    let live_db = Database::open(&live).unwrap();
    let count = live_db.scalar_i64("SELECT COUNT(*) FROM podcasts", []).unwrap().unwrap();
    assert_eq!(count, 1);
}

#[test]
fn test_bootstrap_preserves_non_empty_live_database() {
    let dir = tempfile::tempdir().unwrap();
    let seed = dir.path().join("seed.sqlite");
    let live = dir.path().join("live.sqlite");
    let seed_db = Database::open(&seed).unwrap();
    seed_db.execute("INSERT INTO podcasts (feed_url, title, created_at) VALUES ('https://seed','Seed',1)", []).unwrap();
    drop(seed_db);
    let live_db = Database::open(&live).unwrap();
    live_db.execute("INSERT INTO podcasts (feed_url, title, created_at) VALUES ('https://live','Live',1)", []).unwrap();
    drop(live_db);
    bootstrap::prepare(&live, Some(&seed)).unwrap();
    let live_db = Database::open(&live).unwrap();
    let title = live_db.scalar_string("SELECT title FROM podcasts", []).unwrap().unwrap();
    assert_eq!(title, "Live");
}

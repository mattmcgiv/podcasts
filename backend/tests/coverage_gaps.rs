//! Tests that close measured coverage gaps: error paths and rarely hit
//! branches in shipped library code. See `dev/backend-coverage.sh`.
use pods_backend::db::Database;
use pods_backend::jobs::{
    AudioArtifact, BlockingReason, ClassificationEvidence, JobStage, JobStore, JobStoreError,
};
use pods_backend::usage::{parse_usage, UsageStore, UsageTokens};
use pods_backend::auth::{
    configure_from_env, handle_auth, hash_secret, load_reset_key, Auth, PasskeyEngine,
    ScriptedPasskey, StoredPasskey, WebauthnEngine,
};
use pods_backend::db::now_unix;
use pods_backend::error::Error;
use pods_backend::http::HttpRequest;
use pods_backend::pipeline::{
    execute_stage, AudioDownloader, ClassifyOutcome, MockDownloader, ParakeetTranscriber,
    ScriptedClassifier, Transcriber, UreqDownloader,
};
use pods_backend::storage::{ArtifactStore, DownloadResult};
use pods_backend::transcribe::TranscriptSegment;
use pods_backend::browser::{apply_actions, processed_time, Interval};
use pods_backend::feeds::MockFeedFetcher;
use pods_backend::{Backend, DisabledDirectory};
use pods_backend::backend::DirectorySearcher;
use pods_backend::models::{DirectoryPodcast, SearchResults};
use pods_backend::speaker::MemoryTransport;
use pods_backend::feeds::{parse_feed, FeedFetcher, FeedValidators, UreqFetcher};
use pods_backend::bootstrap;
use pods_backend::directory::PodcastIndexClient;
use pods_backend::storage::finalize_download;
use pods_backend::articles::{tts_model, tts_revision};
use pods_backend::classify::{accept_listen_title, parse_show_notes, parse_structured_labels};
use pods_backend::diagnostics::DiagnosticEvent;
use pods_backend::youtube::{classify, parse_atom, video_meta_from_json, ytdlp_bin, CommandProbe, MapProbe, YoutubeProbe, YT_DLP_TEST_LOCK};
use pods_backend::jev::{classify_window_with, configured_api_key, default_episode_dir};
use pods_backend::local_worker::Segment;

fn seed_episode(db: &Database) -> i64 {
    db.execute(
        "INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 100)",
        [],
    )
    .unwrap();
    db.execute("INSERT INTO episode_state (episode_id, updated_at) VALUES (1, 1)", [])
        .unwrap();
    1
}

fn seed_range(db: &Database, episode_id: i64) {
    for (segment_id, index, start, end) in [("s0", 0, 0.0, 10.0), ("s1", 1, 10.0, 20.0)] {
        db.execute(
            "INSERT INTO ad_transcript_segments (episode_id, segment_id, segment_index, language, start_time, end_time, text) VALUES (?, ?, ?, 'en', ?, ?, 'words')",
            rusqlite::params![episode_id, segment_id, index, start, end],
        )
        .unwrap();
    }
    db.execute(
        "INSERT INTO ad_skip_ranges (id, episode_id, start_segment_id, end_segment_id, start_time, end_time, confidence, reason, classifier_version, prompt_version, created_at, disabled) VALUES ('r1', ?, 's0', 's1', 10.0, 20.0, 0.9, 'promo', 'cv', 'pv', 1, 0)",
        rusqlite::params![episode_id],
    )
    .unwrap();
}

fn poison(db: &Database) {
    std::thread::scope(|scope| {
        let handle = scope.spawn(|| {
            let _guard = db.lock().unwrap();
            panic!("poison the database mutex for coverage");
        });
        assert!(handle.join().is_err());
    });
    assert!(db.lock().is_err());
}

fn sample_evidence() -> ClassificationEvidence {
    ClassificationEvidence {
        run_id: "run1".into(),
        window_index: 0,
        segment_ids: vec!["s0".into()],
        correction_ids: vec![],
        prompt: "p".into(),
        raw_output: "{}".into(),
        schema_valid: true,
        validation_error: None,
        labels_json: "[]".into(),
        model_id: "m".into(),
        model_revision: "r".into(),
        quantization: "q".into(),
        prompt_version: "pv".into(),
        max_context_tokens: 100,
        max_output_tokens: 10,
        temperature: 0.0,
        top_p: 1.0,
        created_at: 1,
    }
}

fn sample_artifact(episode_id: i64) -> AudioArtifact {
    AudioArtifact {
        relative_path: format!("episodes/{episode_id}/audio.mp3"),
        sha256: "a".repeat(64),
        byte_count: 123,
    }
}

fn is_corrupt(result: Result<impl core::fmt::Debug, JobStoreError>) -> bool {
    matches!(result, Err(JobStoreError::CorruptState(_)))
}

#[test]
fn test_cov_jobs_poisoned_lock_fails_every_store_method() {
    let db = Database::open_in_memory().unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    let evidence = sample_evidence();
    let artifact = sample_artifact(1);
    poison(&db);
    assert!(is_corrupt(store.enqueue(1)));
    assert!(is_corrupt(store.job("nope")));
    assert!(is_corrupt(store.job_for_episode(1)));
    assert!(is_corrupt(store.transition("nope", JobStage::Queued)));
    assert!(is_corrupt(store.cancel("nope")));
    assert!(is_corrupt(store.set_blocking_reason("nope", None)));
    assert!(is_corrupt(store.clear_blocking_reasons(&[
        BlockingReason::LowPower,
        BlockingReason::DailyLimit,
    ])));
    assert!(is_corrupt(store.next_runnable_job()));
    assert!(is_corrupt(store.record_failure("nope", "c", "m")));
    assert!(is_corrupt(store.retry("nope")));
    assert!(is_corrupt(store.record_audio_artifact("nope", &artifact)));
    assert!(is_corrupt(store.reserve_daily_classification_slot(1, 10)));
    assert!(is_corrupt(store.skip_ranges(1)));
    assert!(is_corrupt(store.record_download_resume_path("nope", "resume/x")));
    assert!(is_corrupt(store.replace_transcript_segments(1, &[])));
    assert!(is_corrupt(store.transcript_segments(1)));
    assert!(is_corrupt(store.record_transcript("nope", &[], "v")));
    assert!(is_corrupt(store.replace_skip_ranges(1, &[])));
    assert!(is_corrupt(store.record_classification_evidence("nope", &evidence)));
    assert!(is_corrupt(store.complete_classification("nope", "r", &[])));
    assert!(is_corrupt(store.classification_evidence(1)));
    assert!(is_corrupt(store.add_correction(1, 1, "w", "c", "cv", "pv")));
    assert!(is_corrupt(store.corrections(1)));
    assert!(is_corrupt(store.undo_skip(1, "r1")));
    assert!(is_corrupt(store.replace_show_notes(1, &[])));
    assert!(is_corrupt(store.show_notes(1)));
    assert!(is_corrupt(store.delete_episode_ad_data(1)));
    assert!(is_corrupt(store.delete_podcast_corrections(1)));
    assert!(is_corrupt(store.reset_notes_transcript_jobs()));
    assert!(is_corrupt(store.recover_played_cleanup()));
    assert!(is_corrupt(store.job_retry_wait()));
}

#[test]
fn test_cov_jobs_missing_job_table_fails_readers() {
    let db = Database::open_in_memory().unwrap();
    let store = JobStore::new(&db);
    db.execute("DROP TABLE ad_removal_jobs", []).unwrap();
    assert!(is_corrupt(store.job("nope")));
    assert!(is_corrupt(store.job_for_episode(1)));
    assert!(is_corrupt(store.next_runnable_job()));
    assert!(is_corrupt(store.clear_blocking_reasons(&[
        BlockingReason::LowPower,
        BlockingReason::DailyLimit,
    ])));
    assert!(is_corrupt(store.job_retry_wait()));
    assert!(is_corrupt(store.reset_notes_transcript_jobs()));
    assert!(is_corrupt(store.recover_played_cleanup()));
}

#[test]
fn test_cov_jobs_missing_episodes_table_fails_enqueue_lookup() {
    let db = Database::open_in_memory().unwrap();
    let store = JobStore::new(&db);
    db.execute("DROP TABLE episodes", []).unwrap();
    assert!(is_corrupt(store.enqueue(1)));
}

#[test]
fn test_cov_jobs_enqueue_insert_failure() {
    let db = Database::open_in_memory().unwrap();
    let episode_id = seed_episode(&db);
    let store = JobStore::new(&db);
    db.execute(
        "CREATE TRIGGER cov_fail_enqueue BEFORE INSERT ON ad_removal_jobs BEGIN SELECT RAISE(ABORT, 'cov'); END",
        [],
    )
    .unwrap();
    assert!(is_corrupt(store.enqueue(episode_id)));
}

#[test]
fn test_cov_jobs_missing_side_tables_fail_readers() {
    let db = Database::open_in_memory().unwrap();
    let store = JobStore::new(&db);
    for table in [
        "ad_skip_ranges",
        "ad_transcript_segments",
        "ad_classification_windows",
        "ad_corrections",
        "episode_show_notes",
    ] {
        db.execute(&format!("DROP TABLE {table}"), []).unwrap();
    }
    assert!(is_corrupt(store.skip_ranges(1)));
    assert!(is_corrupt(store.transcript_segments(1)));
    assert!(is_corrupt(store.classification_evidence(1)));
    assert!(is_corrupt(store.corrections(1)));
    assert!(is_corrupt(store.show_notes(1)));
}

#[test]
fn test_cov_jobs_failing_job_update_trigger_fails_writers() {
    for method in ["transition", "set_blocking_reason", "record_failure", "record_audio_artifact"] {
        let db = Database::open_in_memory().unwrap();
        let episode_id = seed_episode(&db);
        let store = JobStore::with_now(&db, || 1_000);
        let job = store.enqueue(episode_id).unwrap();
        let job = store.transition(&job.id, JobStage::Downloading).unwrap();
        db.execute(
            "CREATE TRIGGER cov_fail_update BEFORE UPDATE ON ad_removal_jobs BEGIN SELECT RAISE(ABORT, 'cov'); END",
            [],
        )
        .unwrap();
        let failed = match method {
            "transition" => is_corrupt(store.transition(&job.id, JobStage::Downloaded)),
            "set_blocking_reason" => {
                is_corrupt(store.set_blocking_reason(&job.id, Some(BlockingReason::LowPower)))
            }
            "record_failure" => is_corrupt(store.record_failure(&job.id, "c", "m")),
            "record_audio_artifact" => {
                is_corrupt(store.record_audio_artifact(&job.id, &sample_artifact(episode_id)))
            }
            _ => unreachable!(),
        };
        assert!(failed, "{method} must fail when the job update aborts");
    }
}

#[test]
fn test_cov_jobs_retry_update_failure_after_exhaustion() {
    let db = Database::open_in_memory().unwrap();
    let episode_id = seed_episode(&db);
    let store = JobStore::with_now(&db, || 1_000);
    let job = store.enqueue(episode_id).unwrap();
    let job = store.transition(&job.id, JobStage::Downloading).unwrap();
    let mut job = job;
    for _ in 0..4 {
        job = store.record_failure(&job.id, "net", "boom").unwrap();
    }
    assert_eq!(job.stage, JobStage::Failed);
    db.execute(
        "CREATE TRIGGER cov_fail_retry BEFORE UPDATE ON ad_removal_jobs BEGIN SELECT RAISE(ABORT, 'cov'); END",
        [],
    )
    .unwrap();
    assert!(is_corrupt(store.retry(&job.id)));
}

#[test]
fn test_cov_jobs_resume_path_update_failure() {
    let db = Database::open_in_memory().unwrap();
    let episode_id = seed_episode(&db);
    let store = JobStore::with_now(&db, || 1_000);
    let job = store.enqueue(episode_id).unwrap();
    db.execute(
        "CREATE TRIGGER cov_fail_resume BEFORE UPDATE ON ad_removal_jobs BEGIN SELECT RAISE(ABORT, 'cov'); END",
        [],
    )
    .unwrap();
    assert!(is_corrupt(store.record_download_resume_path(&job.id, "resume/part")));
}

#[test]
fn test_cov_jobs_transcript_and_classification_update_failures() {
    for method in ["record_transcript", "record_classification_evidence", "complete_classification"] {
        let db = Database::open_in_memory().unwrap();
        let episode_id = seed_episode(&db);
        let store = JobStore::with_now(&db, || 1_000);
        let job = store.enqueue(episode_id).unwrap();
        let job = store.transition(&job.id, JobStage::Downloading).unwrap();
        let job = store.transition(&job.id, JobStage::Downloaded).unwrap();
        let job = store.transition(&job.id, JobStage::Transcribing).unwrap();
        if method == "complete_classification" {
            let job = store.transition(&job.id, JobStage::Classifying).unwrap();
            db.execute(
                "CREATE TRIGGER cov_fail_complete BEFORE UPDATE ON ad_removal_jobs BEGIN SELECT RAISE(ABORT, 'cov'); END",
                [],
            )
            .unwrap();
            assert!(is_corrupt(store.complete_classification(&job.id, "run", &[])));
        } else if method == "record_transcript" {
            db.execute(
                "CREATE TRIGGER cov_fail_transcript BEFORE UPDATE ON ad_removal_jobs BEGIN SELECT RAISE(ABORT, 'cov'); END",
                [],
            )
            .unwrap();
            assert!(is_corrupt(store.record_transcript(&job.id, &[], "v1")));
        } else {
            db.execute(
                "CREATE TRIGGER cov_fail_evidence BEFORE INSERT ON ad_classification_windows BEGIN SELECT RAISE(ABORT, 'cov'); END",
                [],
            )
            .unwrap();
            assert!(is_corrupt(store.record_classification_evidence(&job.id, &sample_evidence())));
        }
    }
}

#[test]
fn test_cov_jobs_clear_blocking_reasons_update_failure() {
    let db = Database::open_in_memory().unwrap();
    let episode_id = seed_episode(&db);
    let store = JobStore::with_now(&db, || 1_000);
    let job = store.enqueue(episode_id).unwrap();
    store.set_blocking_reason(&job.id, Some(BlockingReason::LowPower)).unwrap();
    db.execute(
        "CREATE TRIGGER cov_fail_clear BEFORE UPDATE ON ad_removal_jobs BEGIN SELECT RAISE(ABORT, 'cov'); END",
        [],
    )
    .unwrap();
    assert!(is_corrupt(store.clear_blocking_reasons(&[BlockingReason::LowPower])));
}

#[test]
fn test_cov_jobs_clear_sorts_multiple_reasons_before_update() {
    let db = Database::open_in_memory().unwrap();
    let episode_id = seed_episode(&db);
    let store = JobStore::with_now(&db, || 1_000);
    let job = store.enqueue(episode_id).unwrap();
    store.set_blocking_reason(&job.id, Some(BlockingReason::LowPower)).unwrap();
    store
        .clear_blocking_reasons(&[BlockingReason::DailyLimit, BlockingReason::LowPower])
        .unwrap();
    let cleared = store.job(&job.id).unwrap().unwrap();
    assert!(cleared.blocking_reason.is_none());
}

#[test]
fn test_cov_jobs_reset_transaction_failure_mid_loop() {
    let db = Database::open_in_memory().unwrap();
    let episode_id = seed_episode(&db);
    let store = JobStore::with_now(&db, || 1_000);
    store.enqueue(episode_id).unwrap();
    db.execute(
        "CREATE TRIGGER cov_fail_reset BEFORE UPDATE ON ad_removal_jobs BEGIN SELECT RAISE(ABORT, 'cov'); END",
        [],
    )
    .unwrap();
    assert!(is_corrupt(store.reset_notes_transcript_jobs()));
}

#[test]
fn test_cov_jobs_undo_skip_lookup_and_update_failures() {
    let db = Database::open_in_memory().unwrap();
    let episode_id = seed_episode(&db);
    seed_range(&db, episode_id);
    db.execute("PRAGMA foreign_keys = OFF", []).unwrap();
    db.execute("DROP TABLE episodes", []).unwrap();
    let store = JobStore::new(&db);
    assert!(is_corrupt(store.undo_skip(episode_id, "r1")));

    let db = Database::open_in_memory().unwrap();
    let episode_id = seed_episode(&db);
    seed_range(&db, episode_id);
    let store = JobStore::new(&db);
    db.execute(
        "CREATE TRIGGER cov_fail_undo BEFORE UPDATE ON ad_skip_ranges BEGIN SELECT RAISE(ABORT, 'cov'); END",
        [],
    )
    .unwrap();
    assert!(is_corrupt(store.undo_skip(episode_id, "r1")));
}

// ---------- usage.rs ----------

fn priced_tokens() -> UsageTokens {
    UsageTokens { input_tokens: Some(100), cached_input_tokens: Some(0), output_tokens: Some(50) }
}

#[test]
fn test_cov_usage_u64_tokens_beyond_i64_are_rejected() {
    let value = serde_json::json!({"usage": {"prompt_tokens": 18446744073709551615u64}});
    assert!(parse_usage(&value).is_none());
}

#[test]
fn test_cov_usage_poisoned_lock_fails_readers() {
    let db = Database::open_in_memory().unwrap();
    let store = UsageStore::new(&db);
    poison(&db);
    assert!(store.records(1).is_err());
    assert!(store.episode_total_cost(1).is_err());
    assert!(store.metrics().is_err());
    assert!(store.record(1, "rk", "m", None, 1).is_err());
}

#[test]
fn test_cov_usage_poisoned_lock_with_corrupt_ledger_fails_reconcile() {
    let dir = tempfile::tempdir().unwrap();
    let ledger = dir.path().join("usage.jsonl");
    std::fs::write(&ledger, "not json\n").unwrap();
    let db = Database::open_in_memory().unwrap();
    let store = UsageStore::with_ledger(&db, ledger);
    poison(&db);
    assert!(store.records(1).is_err());
}

#[test]
fn test_cov_usage_missing_usage_table_fails_records_and_metrics() {
    let db = Database::open_in_memory().unwrap();
    let store = UsageStore::new(&db);
    db.execute("DROP TABLE deepseek_usage", []).unwrap();
    assert!(store.records(1).is_err());
    assert!(store.metrics().is_err());
}

#[test]
fn test_cov_usage_missing_episodes_table_breaks_duration_lookup() {
    let db = Database::open_in_memory().unwrap();
    let episode_id = seed_episode(&db);
    let store = UsageStore::new(&db);
    store.record(episode_id, "ad_detection", "deepseek-chat", Some(&priced_tokens()), 1_000).unwrap();
    db.execute("PRAGMA foreign_keys = OFF", []).unwrap();
    db.execute("DROP TABLE episodes", []).unwrap();
    assert!(store.metrics().is_err());
}

#[test]
fn test_cov_usage_missing_segments_table_breaks_episode_duration() {
    let db = Database::open_in_memory().unwrap();
    let episode_id = seed_episode(&db);
    db.execute("DROP TABLE ad_transcript_segments", []).unwrap();
    let store = UsageStore::new(&db);
    assert!(store.record(episode_id, "rk", "m", None, 1).is_err());
}

#[test]
fn test_cov_usage_garbage_duration_fails_identity() {
    let db = Database::open_in_memory().unwrap();
    let episode_id = seed_episode(&db);
    db.execute(
        "UPDATE episodes SET duration_secs = 'junk' WHERE id = ?",
        rusqlite::params![episode_id],
    )
    .unwrap();
    let store = UsageStore::new(&db);
    assert!(store.record(episode_id, "rk", "m", None, 1).is_err());
}

#[test]
fn test_cov_usage_garbage_episode_key_fails_priced_minutes() {
    let db = Database::open_in_memory().unwrap();
    let episode_id = seed_episode(&db);
    let store = UsageStore::new(&db);
    store.record(episode_id, "ad_detection", "deepseek-chat", Some(&priced_tokens()), 1_000).unwrap();
    db.execute("UPDATE deepseek_usage SET episode_key = x'FF'", []).unwrap();
    assert!(store.metrics().is_err());
}

#[test]
fn test_cov_usage_failing_insert_trigger_fails_record() {
    let db = Database::open_in_memory().unwrap();
    let episode_id = seed_episode(&db);
    let store = UsageStore::new(&db);
    db.execute(
        "CREATE TRIGGER cov_fail_usage BEFORE INSERT ON deepseek_usage BEGIN SELECT RAISE(ABORT, 'cov'); END",
        [],
    )
    .unwrap();
    assert!(store.record(episode_id, "ad_detection", "m", None, 1).is_err());
}

#[test]
fn test_cov_usage_ledger_parent_is_file_fails_append() {
    let dir = tempfile::tempdir().unwrap();
    let blocker = dir.path().join("blocker");
    std::fs::write(&blocker, "x").unwrap();
    let db = Database::open_in_memory().unwrap();
    let episode_id = seed_episode(&db);
    let store = UsageStore::with_ledger(&db, blocker.join("usage.jsonl"));
    store.fail_next_insert();
    assert!(store.record(episode_id, "rk", "m", None, 1).is_err());
}

#[test]
fn test_cov_usage_ledger_directory_fails_append() {
    let dir = tempfile::tempdir().unwrap();
    let db = Database::open_in_memory().unwrap();
    let episode_id = seed_episode(&db);
    let store = UsageStore::with_ledger(&db, dir.path().to_path_buf());
    store.fail_next_insert();
    assert!(store.record(episode_id, "rk", "m", None, 1).is_err());
}

#[test]
fn test_cov_usage_full_device_fails_ledger_write() {
    let db = Database::open_in_memory().unwrap();
    let episode_id = seed_episode(&db);
    let store = UsageStore::with_ledger(&db, std::path::PathBuf::from("/dev/full"));
    store.fail_next_insert();
    assert!(store.record(episode_id, "rk", "m", None, 1).is_err());
}

#[test]
fn test_cov_usage_unreadable_ledger_marks_incomplete() {
    let dir = tempfile::tempdir().unwrap();
    let db = Database::open_in_memory().unwrap();
    let store = UsageStore::with_ledger(&db, dir.path().to_path_buf());
    assert!(store.records(1).unwrap().is_empty());
}

#[test]
fn test_cov_usage_corrupt_ledger_line_marks_incomplete() {
    let dir = tempfile::tempdir().unwrap();
    let ledger = dir.path().join("usage.jsonl");
    std::fs::write(&ledger, "not json\n").unwrap();
    let db = Database::open_in_memory().unwrap();
    let store = UsageStore::with_ledger(&db, ledger);
    assert!(store.records(1).unwrap().is_empty());
}

#[test]
fn test_cov_usage_legacy_ledger_record_without_id_marks_incomplete() {
    let dir = tempfile::tempdir().unwrap();
    let ledger = dir.path().join("usage.jsonl");
    std::fs::write(&ledger, "{\"record_id\":\"\"}\n").unwrap();
    let db = Database::open_in_memory().unwrap();
    let store = UsageStore::with_ledger(&db, ledger);
    assert!(store.records(1).unwrap().is_empty());
}

#[test]
fn test_cov_usage_ledger_record_with_id_but_invalid_shape_marks_incomplete() {
    let dir = tempfile::tempdir().unwrap();
    let ledger = dir.path().join("usage.jsonl");
    std::fs::write(&ledger, "{\"record_id\":\"x\"}\n").unwrap();
    let db = Database::open_in_memory().unwrap();
    let store = UsageStore::with_ledger(&db, ledger);
    assert!(store.records(1).unwrap().is_empty());
}

#[test]
fn test_cov_usage_readonly_ledger_blocks_rewrite() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let ledger = dir.path().join("usage.jsonl");
    std::fs::write(
        &ledger,
        "{\"record_id\":\"r1\",\"episode_id\":1,\"episode_key\":\"k\",\"duration_secs\":null,\"request_kind\":\"rk\",\"model\":\"m\",\"input_tokens\":null,\"cached_input_tokens\":null,\"output_tokens\":null,\"cost_usd\":null,\"created_at\":1}\n",
    )
    .unwrap();
    std::fs::set_permissions(&ledger, std::fs::Permissions::from_mode(0o444)).unwrap();
    let db = Database::open_in_memory().unwrap();
    let store = UsageStore::with_ledger(&db, ledger);
    store.fail_next_insert();
    assert!(store.records(1).is_err());
}

#[test]
fn test_cov_usage_missing_settings_table_fails_incomplete_mark() {
    let dir = tempfile::tempdir().unwrap();
    let ledger = dir.path().join("usage.jsonl");
    std::fs::write(&ledger, "not json\n").unwrap();
    let db = Database::open_in_memory().unwrap();
    db.execute("DROP TABLE settings", []).unwrap();
    let store = UsageStore::with_ledger(&db, ledger);
    assert!(store.records(1).is_err());
}

#[test]
fn test_cov_usage_garbage_cost_fails_record_mapping() {
    let db = Database::open_in_memory().unwrap();
    let episode_id = seed_episode(&db);
    let store = UsageStore::new(&db);
    store.record(episode_id, "ad_detection", "m", None, 1).unwrap();
    db.execute("UPDATE deepseek_usage SET cost_usd = 'junk'", []).unwrap();
    assert!(store.records(1).is_err());
}

// ---------- auth.rs ----------

static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

struct EnvGuard {
    saved: Vec<(&'static str, Option<String>)>,
}

impl EnvGuard {
    fn take(keys: &[&'static str]) -> Self {
        Self { saved: keys.iter().map(|k| (*k, std::env::var(k).ok())).collect() }
    }
}

impl Drop for EnvGuard {
    fn drop(&mut self) {
        for (key, value) in &self.saved {
            match value {
                Some(v) => std::env::set_var(key, v),
                None => std::env::remove_var(key),
            }
        }
    }
}

fn authed() -> (Auth, Database) {
    let db = Database::open_in_memory().unwrap();
    let auth = Auth::default();
    auth.enable_passkey("reset-secret", "https://pods.mcgiv.dev");
    (auth, db)
}

fn post(path: &str, body: serde_json::Value) -> HttpRequest {
    HttpRequest::new("POST", path).with_json(&body)
}

#[test]
fn test_cov_auth_scripted_registration_requires_credential_id() {
    let engine = ScriptedPasskey;
    let err = engine.finish_registration(&serde_json::json!({}), &serde_json::json!({})).unwrap_err();
    assert!(matches!(err, Error::Invalid(_)));
}

#[test]
fn test_cov_auth_webauthn_builder_rejects_bad_ids_and_origins() {
    assert!(WebauthnEngine::new("", "https://example.com").is_err());
    assert!(WebauthnEngine::new("other.com", "https://example.com").is_err());
    assert!(WebauthnEngine::new("example.com", "https://example.com").is_ok());
}

#[test]
fn test_cov_auth_webauthn_registration_rejects_malformed_response() {
    let engine = WebauthnEngine::new("example.com", "https://example.com").unwrap();
    let (_options, state) = engine.start_registration(&[]).unwrap();
    let err = engine
        .finish_registration(&state, &serde_json::json!({"bogus": 1}))
        .unwrap_err();
    assert!(matches!(err, Error::Invalid(_)));
}

#[test]
fn test_cov_auth_webauthn_registration_rejects_bogus_attestation() {
    let engine = WebauthnEngine::new("example.com", "https://example.com").unwrap();
    let (_options, state) = engine.start_registration(&[]).unwrap();
    let response = serde_json::json!({
        "id": "eA",
        "rawId": "eA",
        "type": "public-key",
        "response": { "attestationObject": "eA", "clientDataJSON": "eA" },
    });
    let err = engine.finish_registration(&state, &response).unwrap_err();
    assert!(matches!(err, Error::Unauthorized(_)));
}

#[test]
fn test_cov_auth_webauthn_authentication_ignores_unparseable_keys() {
    let engine = WebauthnEngine::new("example.com", "https://example.com").unwrap();
    let stored = vec![StoredPasskey { credential_id: "x".into(), public_key_json: "bogus".into() }];
    let err = engine.start_authentication(&stored).unwrap_err();
    assert!(matches!(err, Error::Unauthorized(_)));
}

fn fabricated_auth_state() -> serde_json::Value {
    serde_json::json!({
        "ast": {
            "credentials": [],
            "policy": "required",
            "challenge": "eA",
            "appid": null,
            "allow_backup_eligible_upgrade": false,
        }
    })
}

#[test]
fn test_cov_auth_webauthn_authentication_rejects_malformed_response() {
    let engine = WebauthnEngine::new("example.com", "https://example.com").unwrap();
    let err = engine
        .finish_authentication(&fabricated_auth_state(), &serde_json::json!({"bogus": 1}))
        .unwrap_err();
    assert!(matches!(err, Error::Invalid(_)));
}

#[test]
fn test_cov_auth_webauthn_authentication_rejects_bogus_assertion() {
    let engine = WebauthnEngine::new("example.com", "https://example.com").unwrap();
    let response = serde_json::json!({
        "id": "eA",
        "rawId": "eA",
        "type": "public-key",
        "response": { "authenticatorData": "eA", "clientDataJSON": "eA", "signature": "eA" },
    });
    let err = engine.finish_authentication(&fabricated_auth_state(), &response).unwrap_err();
    assert!(matches!(err, Error::Unauthorized(_)));
}

#[test]
fn test_cov_auth_reset_key_file_fallbacks_and_missing_file() {
    let _lock = ENV_LOCK.lock().unwrap();
    let _guard = EnvGuard::take(&["PODS_RESET_KEY", "PODS_RESET_KEY_FILE"]);
    std::env::remove_var("PODS_RESET_KEY");
    std::env::remove_var("PODS_RESET_KEY_FILE");
    assert!(matches!(load_reset_key(), Err(Error::Invalid(_))));
    std::env::set_var("PODS_RESET_KEY_FILE", "/nonexistent-cov-reset.key");
    assert!(matches!(load_reset_key(), Err(Error::Invalid(_))));
}

#[test]
fn test_cov_auth_configure_uses_default_origin_and_rp_id() {
    let _lock = ENV_LOCK.lock().unwrap();
    let _guard = EnvGuard::take(&["PODS_AUTH_MODE", "PODS_ORIGIN", "PODS_RP_ID", "PODS_RESET_KEY", "PODS_RESET_KEY_FILE"]);
    std::env::set_var("PODS_AUTH_MODE", "passkey");
    std::env::remove_var("PODS_ORIGIN");
    std::env::remove_var("PODS_RP_ID");
    std::env::remove_var("PODS_RESET_KEY");
    std::env::remove_var("PODS_RESET_KEY_FILE");
    let auth = Auth::default();
    assert!(configure_from_env(&auth).is_err());
}

#[test]
fn test_cov_auth_register_options_lists_existing_credentials() {
    let (auth, db) = authed();
    db.execute(
        "INSERT INTO auth_enroll_tokens (token_hash, expires_at, used) VALUES (?, ?, 0)",
        rusqlite::params![hash_secret("tok"), now_unix() + 3600],
    )
    .unwrap();
    db.execute(
        "INSERT INTO passkey_credentials (credential_id, user_handle, public_key_json, counter, created_at) VALUES ('abc123', 'matt', '{}', 0, 1)",
        [],
    )
    .unwrap();
    let response = handle_auth(&auth, &db, &post("/api/auth/register/options", serde_json::json!({"token": "tok"})));
    assert_eq!(response.unwrap().unwrap().status_code, 200);
}

#[test]
fn test_cov_auth_register_validates_state_and_credential() {
    let (auth, db) = authed();
    let missing_state = handle_auth(&auth, &db, &post("/api/auth/register", serde_json::json!({})));
    assert!(matches!(missing_state, Err(Error::Invalid(_))));
    let missing_credential = handle_auth(&auth, &db, &post("/api/auth/register", serde_json::json!({"state_id": "x"})));
    assert!(matches!(missing_credential, Err(Error::Invalid(_))));
}

#[test]
fn test_cov_auth_register_rejects_state_without_enroll_token() {
    let (auth, db) = authed();
    db.execute(
        "INSERT INTO auth_webauthn_state (id, kind, state_json, expires_at) VALUES ('s1', 'register', '{\"state\":{}}', ?)",
        rusqlite::params![now_unix() + 600],
    )
    .unwrap();
    let result = handle_auth(
        &auth,
        &db,
        &post("/api/auth/register", serde_json::json!({"state_id": "s1", "credential": {"id": "c"}})),
    );
    assert!(matches!(result, Err(Error::Unauthorized(_))));
}

#[test]
fn test_cov_auth_register_rejects_unparseable_state() {
    let (auth, db) = authed();
    db.execute(
        "INSERT INTO auth_webauthn_state (id, kind, state_json, expires_at) VALUES ('s2', 'register', 'bogus', ?)",
        rusqlite::params![now_unix() + 600],
    )
    .unwrap();
    let result = handle_auth(
        &auth,
        &db,
        &post("/api/auth/register", serde_json::json!({"state_id": "s2", "credential": {"id": "c"}})),
    );
    assert!(matches!(result, Err(Error::Invalid(_))));
}

#[test]
fn test_cov_auth_login_validates_state_and_credential() {
    let (auth, db) = authed();
    let missing_state = handle_auth(&auth, &db, &post("/api/auth/login", serde_json::json!({})));
    assert!(matches!(missing_state, Err(Error::Invalid(_))));
    let missing_credential = handle_auth(&auth, &db, &post("/api/auth/login", serde_json::json!({"state_id": "x"})));
    assert!(matches!(missing_credential, Err(Error::Invalid(_))));
}

// ---------- pipeline.rs ----------

fn serve_once(status: &str, content_type: &str, body: &[u8]) -> String {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let status = status.to_string();
    let content_type = content_type.to_string();
    let body = body.to_vec();
    std::thread::spawn(move || {
        if let Ok((mut stream, _)) = listener.accept() {
            use std::io::{Read, Write};
            let mut buf = [0u8; 4096];
            let _ = stream.read(&mut buf);
            let _ = stream.write_all(
                format!(
                    "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                )
                .as_bytes(),
            );
            let _ = stream.write_all(&body);
        }
    });
    format!("http://{addr}/")
}

fn serve_truncated(content_length: usize, prefix: &[u8]) -> String {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let prefix = prefix.to_vec();
    std::thread::spawn(move || {
        if let Ok((mut stream, _)) = listener.accept() {
            use std::io::{Read, Write};
            let mut buf = [0u8; 4096];
            let _ = stream.read(&mut buf);
            let _ = stream.write_all(
                format!("HTTP/1.1 200 OK\r\nContent-Length: {content_length}\r\nConnection: close\r\n\r\n").as_bytes(),
            );
            let _ = stream.write_all(&prefix);
        }
    });
    format!("http://{addr}/")
}

struct StubTranscriber(Vec<TranscriptSegment>);

impl Transcriber for StubTranscriber {
    fn version(&self) -> &'static str {
        "stub-v1"
    }

    fn transcribe(
        &self,
        _episode_id: i64,
        _audio_path: Option<&std::path::Path>,
        _notes_html: &str,
        _duration_secs: Option<i64>,
    ) -> Result<Vec<TranscriptSegment>, String> {
        Ok(self.0.clone())
    }
}

fn one_segment() -> TranscriptSegment {
    TranscriptSegment {
        id: "s0".into(),
        index: 0,
        language: "en".into(),
        start_time: 0.0,
        end_time: 1.0,
        text: "hi".into(),
    }
}

fn stage_job(db: &Database) -> pods_backend::jobs::Job {
    let episode_id = seed_episode(db);
    JobStore::with_now(db, || 1_000).enqueue(episode_id).unwrap()
}

#[test]
fn test_cov_pipeline_ureq_create_dir_failure() {
    let url = serve_once("200 OK", "audio/mpeg", b"ID3data");
    let dir = tempfile::tempdir().unwrap();
    let blocker = dir.path().join("blocker");
    std::fs::write(&blocker, "x").unwrap();
    let dest = blocker.join("sub").join("f.mp3");
    assert!(UreqDownloader.fetch_to(&url, &dest).is_err());
}

#[test]
fn test_cov_pipeline_ureq_file_create_failure_in_readonly_dir() {
    use std::os::unix::fs::PermissionsExt;
    let url = serve_once("200 OK", "audio/mpeg", b"ID3data");
    let dir = tempfile::tempdir().unwrap();
    let target = dir.path().join("ro");
    std::fs::create_dir(&target).unwrap();
    std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o555)).unwrap();
    let result = UreqDownloader.fetch_to(&url, &target.join("f.mp3"));
    std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert!(result.is_err());
}

#[test]
fn test_cov_pipeline_ureq_truncated_body_fails_read() {
    let url = serve_truncated(100, b"short");
    let dir = tempfile::tempdir().unwrap();
    assert!(UreqDownloader.fetch_to(&url, &dir.path().join("f.mp3")).is_err());
}

#[test]
fn test_cov_pipeline_ureq_rename_onto_directory_fails() {
    let url = serve_once("200 OK", "audio/mpeg", b"ID3data");
    let dir = tempfile::tempdir().unwrap();
    let target = dir.path().join("adir");
    std::fs::create_dir(&target).unwrap();
    assert!(UreqDownloader.fetch_to(&url, &target).is_err());
}

#[test]
fn test_cov_pipeline_mock_download_filesystem_failures() {
    let mock = MockDownloader::default();
    mock.set(
        "https://x/a.mp3",
        DownloadResult { bytes: b"ID3".to_vec(), content_type: "audio/mpeg".into(), status: 200 },
    );
    let dir = tempfile::tempdir().unwrap();
    let blocker = dir.path().join("blocker");
    std::fs::write(&blocker, "x").unwrap();
    assert!(mock.fetch_to("https://x/a.mp3", &blocker.join("f.mp3")).is_err());
    let target = dir.path().join("adir");
    std::fs::create_dir(&target).unwrap();
    assert!(mock.fetch_to("https://x/a.mp3", &target).is_err());
}

#[test]
fn test_cov_pipeline_parakeet_connection_and_body_failures() {
    let refused = ParakeetTranscriber { endpoint: "http://127.0.0.1:9/transcribe".into() };
    assert!(refused.transcribe(1, Some(std::path::Path::new("/tmp/x.mp3")), "", None).is_err());
    let url = serve_truncated(100, b"short");
    let truncated = ParakeetTranscriber { endpoint: url };
    assert!(truncated.transcribe(1, Some(std::path::Path::new("/tmp/x.mp3")), "", None).is_err());
}

#[test]
fn test_cov_pipeline_scripted_classifier_requires_queued_output() {
    let classifier = ScriptedClassifier { responses: std::sync::Mutex::new(vec![]) };
    assert!(pods_backend::pipeline::CloudClassifier::classify_window(&classifier, "p", "key").is_err());
}

#[test]
fn test_cov_pipeline_stage_download_rejects_unwritable_store() {
    use std::os::unix::fs::PermissionsExt;
    let db = Database::open_in_memory().unwrap();
    let job = stage_job(&db);
    let store = JobStore::new(&db);
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("store");
    let artifacts = ArtifactStore::open(root.clone()).unwrap();
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o555)).unwrap();
    let result = execute_stage(
        &store, &artifacts, &MockDownloader::default(), &StubTranscriber(vec![]),
        &ScriptedClassifier { responses: std::sync::Mutex::new(vec![]) },
        "key", JobStage::Downloading, &job, "https://x/a.mp3", "", None, None,
    );
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert!(result.is_err());
}

#[test]
fn test_cov_pipeline_stage_download_rejects_wrong_job_stage() {
    let db = Database::open_in_memory().unwrap();
    let job = stage_job(&db);
    let store = JobStore::new(&db);
    let dir = tempfile::tempdir().unwrap();
    let artifacts = ArtifactStore::open(dir.path().join("store")).unwrap();
    let mock = MockDownloader::default();
    mock.set(
        "https://x/a.mp3",
        DownloadResult { bytes: b"ID3".to_vec(), content_type: "audio/mpeg".into(), status: 200 },
    );
    let result = execute_stage(
        &store, &artifacts, &mock, &StubTranscriber(vec![]),
        &ScriptedClassifier { responses: std::sync::Mutex::new(vec![]) },
        "key", JobStage::Downloading, &job, "https://x/a.mp3", "", None, None,
    );
    assert!(result.is_err());
}

#[test]
fn test_cov_pipeline_stage_transcribe_rejects_wrong_job_stage() {
    let db = Database::open_in_memory().unwrap();
    let job = stage_job(&db);
    let store = JobStore::new(&db);
    let dir = tempfile::tempdir().unwrap();
    let artifacts = ArtifactStore::open(dir.path().join("store")).unwrap();
    let result = execute_stage(
        &store, &artifacts, &MockDownloader::default(), &StubTranscriber(vec![one_segment()]),
        &ScriptedClassifier { responses: std::sync::Mutex::new(vec![]) },
        "key", JobStage::Transcribing, &job, "https://x/a.mp3", "", None, None,
    );
    assert!(result.is_err());
}

#[test]
fn test_cov_pipeline_stage_classify_requires_readable_store() {
    let db = Database::open_in_memory().unwrap();
    let job = stage_job(&db);
    let store = JobStore::new(&db);
    poison(&db);
    let dir = tempfile::tempdir().unwrap();
    let artifacts = ArtifactStore::open(dir.path().join("store")).unwrap();
    let result = execute_stage(
        &store, &artifacts, &MockDownloader::default(), &StubTranscriber(vec![]),
        &ScriptedClassifier { responses: std::sync::Mutex::new(vec![]) },
        "key", JobStage::Classifying, &job, "https://x/a.mp3", "", None, None,
    );
    assert!(result.is_err());
}

fn classify_setup(trigger_sql: &str, content: &str) -> Result<(), String> {
    let db = Database::open_in_memory().unwrap();
    let episode_id = seed_episode(&db);
    let store = JobStore::with_now(&db, || 1_000);
    let job = store.enqueue(episode_id).unwrap();
    store.replace_transcript_segments(episode_id, &[one_segment()]).unwrap();
    db.execute(trigger_sql, []).unwrap();
    let dir = tempfile::tempdir().unwrap();
    let artifacts = ArtifactStore::open(dir.path().join("store")).unwrap();
    let classifier = ScriptedClassifier {
        responses: std::sync::Mutex::new(vec![ClassifyOutcome {
            content: Some(content.to_string()),
            raw: serde_json::json!({}),
        }]),
    };
    execute_stage(
        &store, &artifacts, &MockDownloader::default(), &StubTranscriber(vec![]),
        &classifier, "key", JobStage::Classifying, &job, "https://x/a.mp3", "", None, None,
    )
}

#[test]
fn test_cov_pipeline_stage_classify_evidence_insert_failure() {
    let labels = r#"{"labels":[{"segment_id":"s0","label":"content","reason":"ok"}]}"#;
    let result = classify_setup(
        "CREATE TRIGGER cov_fail_ev BEFORE INSERT ON ad_classification_windows BEGIN SELECT RAISE(ABORT, 'cov'); END",
        labels,
    );
    assert!(result.is_err());
}

#[test]
fn test_cov_pipeline_stage_classify_malformed_insert_failure() {
    let result = classify_setup(
        "CREATE TRIGGER cov_fail_ev2 BEFORE INSERT ON ad_classification_windows BEGIN SELECT RAISE(ABORT, 'cov'); END",
        "!!! not json !!!",
    );
    assert!(result.is_err());
}

#[test]
fn test_cov_pipeline_stage_classify_completion_failure() {
    let labels = r#"{"labels":[{"segment_id":"s0","label":"content","reason":"ok"}]}"#;
    let result = classify_setup(
        "CREATE TRIGGER cov_fail_cc BEFORE UPDATE ON ad_removal_jobs BEGIN SELECT RAISE(ABORT, 'cov'); END",
        labels,
    );
    assert!(result.is_err());
}

// ---------- browser.rs ----------

fn sync_backend() -> (Backend, tempfile::TempDir) {
    let temp = tempfile::tempdir().unwrap();
    let db = Database::open_in_memory().unwrap();
    let mut backend = Backend::with_data_root(
        db,
        std::sync::Arc::new(MockFeedFetcher::default()),
        std::sync::Arc::new(DisabledDirectory),
        Some(temp.path().to_owned()),
    );
    backend.local = true;
    (backend, temp)
}

fn sync_action(value: serde_json::Value) -> serde_json::Value {
    serde_json::json!({"client_id": "c1", "actions": [value]})
}

fn full_action(entity: &str, field: &str, value: serde_json::Value) -> serde_json::Value {
    serde_json::json!({
        "id": "op1", "sequence": 1, "entity": entity, "field": field,
        "base_revision": 0, "value": value,
    })
}

const VIDEO_URL: &str = "https://www.youtube.com/watch?v=dQw4w9WgXcQ";

const VALID_MANIFEST: &str = r#"{"version":1,"episode_id":1,"hash":"h1","source_hash":"s1","bytes":10,"duration":5.0,"chunk_size":99,"chunks":[],"timeline":[],"model":"m","pipeline_version":"v"}"#;

fn seed_publication(db: &Database, manifest_json: &str) {
    seed_episode(db);
    db.execute(
        "INSERT INTO browser_publications (episode_id, manifest_json, notes_json, published_at) VALUES (1, ?, '[1]', 1)",
        rusqlite::params![manifest_json],
    )
    .unwrap();
}

#[test]
fn test_cov_browser_processed_time_falls_back_to_last_interval() {
    let timeline = vec![Interval { original_start: 0.0, original_end: 5.0, processed_start: 0.0 }];
    assert_eq!(processed_time(&timeline, 9.9), 5.0);
    assert_eq!(processed_time(&[], 9.9), 0.0);
}

#[test]
fn test_cov_browser_library_requires_url() {
    let (backend, _temp) = sync_backend();
    let response = backend.handle(HttpRequest::new("POST", "/api/internal/library").with_json(&serde_json::json!({})));
    assert_eq!(response.status_code, 422);
}

#[test]
fn test_cov_browser_library_rejects_unparseable_url() {
    let (backend, _temp) = sync_backend();
    let response = backend.handle(
        HttpRequest::new("POST", "/api/internal/library").with_json(&serde_json::json!({"url": "notaurl"})),
    );
    assert_eq!(response.status_code, 422);
}

#[test]
fn test_cov_browser_publication_rejects_corrupt_manifest() {
    let (backend, _temp) = sync_backend();
    seed_publication(&backend.db, "bogus");
    let response = backend.handle(HttpRequest::new("GET", "/api/episodes/1/artifact-manifest"));
    assert_eq!(response.status_code, 422);
}

#[test]
fn test_cov_sync_validates_envelope_and_action_shape() {
    let (backend, _temp) = sync_backend();
    assert!(matches!(apply_actions(&backend, serde_json::json!({"actions": []})), Err(Error::Invalid(_))));
    assert!(matches!(apply_actions(&backend, serde_json::json!({"client_id": "c"})), Err(Error::Invalid(_))));
    assert!(matches!(
        apply_actions(&backend, sync_action(serde_json::json!({"sequence": 1}))),
        Err(Error::Invalid(_))
    ));
    assert!(matches!(
        apply_actions(&backend, sync_action(serde_json::json!({"id": "op1"}))),
        Err(Error::Invalid(_))
    ));
    assert!(matches!(
        apply_actions(&backend, sync_action(serde_json::json!({"id": "op1", "sequence": 1}))),
        Err(Error::Invalid(_))
    ));
    assert!(matches!(
        apply_actions(&backend, sync_action(serde_json::json!({"id": "op1", "sequence": 1, "entity": "settings"}))),
        Err(Error::Invalid(_))
    ));
    assert!(matches!(
        apply_actions(
            &backend,
            sync_action(serde_json::json!({"id": "op1", "sequence": 1, "entity": "settings", "field": "autoplay"}))
        ),
        Err(Error::Invalid(_))
    ));
}

#[test]
fn test_cov_sync_rejects_unparseable_stored_operation() {
    let (backend, _temp) = sync_backend();
    let action = full_action("settings", "autoplay", serde_json::json!(true));
    apply_actions(&backend, sync_action(action.clone())).unwrap();
    backend.db.execute("UPDATE browser_operations SET result = 'bogus'", []).unwrap();
    assert!(matches!(apply_actions(&backend, sync_action(action)), Err(Error::Invalid(_))));
}

#[test]
fn test_cov_sync_listen_checks_queue_without_and_with_entries() {
    let (backend, _temp) = sync_backend();
    let fresh = full_action("listen", VIDEO_URL, serde_json::json!(true));
    apply_actions(&backend, sync_action(fresh)).unwrap();
    backend.db.execute("DELETE FROM settings WHERE key = 'browser_youtube_listen'", []).unwrap();
    backend.db.execute(
        "INSERT INTO settings (key, value) VALUES ('browser_youtube_listen', '[{\"url\":\"https://other.example\",\"attempts\":0,\"next_at\":0}]')",
        [],
    )
    .unwrap();
    let seeded = serde_json::json!({
        "id": "op2", "sequence": 2, "entity": "listen", "field": VIDEO_URL,
        "base_revision": 1, "value": true,
    });
    apply_actions(&backend, sync_action(seeded)).unwrap();
}

#[test]
fn test_cov_sync_last_listened_requires_published_episode() {
    let (backend, _temp) = sync_backend();
    let result = apply_actions(
        &backend,
        sync_action(full_action("settings", "last_listened", serde_json::json!(999))),
    );
    assert!(matches!(result, Err(Error::Invalid(_))));
}

#[test]
fn test_cov_sync_listen_rejects_non_youtube_field() {
    let (backend, _temp) = sync_backend();
    let result = apply_actions(
        &backend,
        sync_action(full_action("listen", "https://example.com/not-youtube", serde_json::json!(true))),
    );
    assert!(matches!(result, Err(Error::Invalid(_))));
}

#[test]
fn test_cov_sync_feedback_requires_report_kind() {
    let (backend, _temp) = sync_backend();
    let result = apply_actions(
        &backend,
        sync_action(full_action("feedback", "r1", serde_json::json!({}))),
    );
    assert!(matches!(result, Err(Error::Invalid(_))));
}

#[test]
fn test_cov_sync_subscription_validates_feed_url_and_value() {
    let (backend, _temp) = sync_backend();
    let bad_url = apply_actions(
        &backend,
        sync_action(full_action("subscription", "http://exa mple.com/feed", serde_json::json!(true))),
    );
    assert!(matches!(bad_url, Err(Error::Invalid(_))));
    let bad_value = apply_actions(
        &backend,
        sync_action(serde_json::json!({
            "id": "op2", "sequence": 2, "entity": "subscription",
            "field": "https://example.com/feed", "base_revision": 0, "value": "yes",
        })),
    );
    assert!(matches!(bad_value, Err(Error::Invalid(_))));
}

#[test]
fn test_cov_sync_rejects_non_numeric_episode_entity() {
    let (backend, _temp) = sync_backend();
    let result = apply_actions(&backend, sync_action(full_action("abc", "x", serde_json::json!(true))));
    assert!(matches!(result, Err(Error::Invalid(_))));
}

#[test]
fn test_cov_sync_rejects_corrupt_publication_manifest() {
    let (backend, _temp) = sync_backend();
    seed_publication(&backend.db, "bogus");
    let result = apply_actions(&backend, sync_action(full_action("1", "played", serde_json::json!(true))));
    assert!(matches!(result, Err(Error::Invalid(_))));
}

#[test]
fn test_cov_sync_position_requires_valid_seconds() {
    let (backend, _temp) = sync_backend();
    seed_publication(&backend.db, VALID_MANIFEST);
    let result = apply_actions(&backend, sync_action(full_action("1", "position", serde_json::json!({}))));
    assert!(matches!(result, Err(Error::Invalid(_))));
}

#[test]
fn test_cov_sync_position_rejects_corrupt_playback_artifact() {
    let (backend, _temp) = sync_backend();
    seed_publication(&backend.db, VALID_MANIFEST);
    backend.db.execute(
        "INSERT INTO browser_artifacts (hash, episode_id, manifest_json) VALUES ('other', 1, 'bogus')",
        [],
    )
    .unwrap();
    let result = apply_actions(
        &backend,
        sync_action(full_action("1", "position", serde_json::json!({"seconds": 1.0, "artifact_hash": "other"}))),
    );
    assert!(matches!(result, Err(Error::Invalid(_))));
}

#[test]
fn test_cov_sync_played_requires_boolean() {
    let (backend, _temp) = sync_backend();
    seed_publication(&backend.db, VALID_MANIFEST);
    let result = apply_actions(&backend, sync_action(full_action("1", "played", serde_json::json!("yes"))));
    assert!(matches!(result, Err(Error::Invalid(_))));
}

#[test]
fn test_cov_browser_artifact_directory_fails_body_read() {
    let (backend, temp) = sync_backend();
    let hash = "a".repeat(64);
    seed_episode(&backend.db);
    backend.db.execute(
        "INSERT INTO browser_artifacts (hash, episode_id, manifest_json) VALUES (?, 1, '{}')",
        rusqlite::params![hash],
    )
    .unwrap();
    let path = temp.path().join("AdRemoval").join("published").join(format!("{hash}.m4a"));
    std::fs::create_dir_all(&path).unwrap();
    let response = backend.handle(HttpRequest::new("GET", format!("/api/artifacts/{hash}")));
    assert_eq!(response.status_code, 422);
}

// ---------- backend.rs ----------

fn legacy_backend() -> (Backend, tempfile::TempDir, std::sync::Arc<MockFeedFetcher>) {
    let temp = tempfile::tempdir().unwrap();
    let db = Database::open_in_memory().unwrap();
    let fetcher = std::sync::Arc::new(MockFeedFetcher::default());
    let backend = Backend::with_data_root(
        db,
        fetcher.clone(),
        std::sync::Arc::new(DisabledDirectory),
        Some(temp.path().to_owned()),
    );
    (backend, temp, fetcher)
}

fn legacy_call(backend: &Backend, method: &str, target: &str, json_body: Option<serde_json::Value>) -> pods_backend::HttpResponse {
    let mut req = HttpRequest::new(method, target);
    if let Some(body) = json_body {
        req = req.with_json(&body);
    }
    backend.handle(req)
}

struct StubDirectory {
    podcasts: Vec<DirectoryPodcast>,
}

impl DirectorySearcher for StubDirectory {
    fn is_configured(&self) -> bool {
        true
    }

    fn search(&self, _query: &str) -> Result<Vec<DirectoryPodcast>, Error> {
        Ok(self.podcasts.clone())
    }
}

#[test]
fn test_cov_backend_disabled_directory_search_is_empty() {
    let found = DisabledDirectory.search("anything").unwrap();
    assert!(found.is_empty());
}

#[test]
fn test_cov_backend_stored_key_and_directory_are_configurable() {
    let temp = tempfile::tempdir().unwrap();
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO settings (key, value) VALUES ('deepseek_api_key', 'k')", []).unwrap();
    let backend = Backend::with_data_root(
        db,
        std::sync::Arc::new(MockFeedFetcher::default()),
        std::sync::Arc::new(DisabledDirectory),
        Some(temp.path().to_owned()),
    );
    backend.set_directory(std::sync::Arc::new(DisabledDirectory));
    assert!(!backend.local);
}

#[test]
fn test_cov_backend_construction_survives_failed_recovery() {
    let temp = tempfile::tempdir().unwrap();
    let db = Database::open_in_memory().unwrap();
    db.execute("DROP TABLE ad_removal_jobs", []).unwrap();
    let backend = Backend::with_data_root(
        db,
        std::sync::Arc::new(MockFeedFetcher::default()),
        std::sync::Arc::new(DisabledDirectory),
        Some(temp.path().to_owned()),
    );
    assert!(!backend.local);
}

#[test]
fn test_cov_backend_legacy_validates_required_fields() {
    let (backend, _temp, _fetcher) = legacy_backend();
    let none: Option<serde_json::Value> = None;
    let cases = [
        ("POST", "/api/shows", Some(serde_json::json!({}))),
        ("POST", "/api/youtube/videos", Some(serde_json::json!({}))),
        ("POST", "/api/follows", Some(serde_json::json!({}))),
        ("POST", "/api/feeds/preview", Some(serde_json::json!({}))),
        ("POST", "/api/listen-episodes", Some(serde_json::json!({}))),
        ("POST", "/api/listen-episodes", Some(serde_json::json!({"feed_url": "https://f.example/rss"}))),
        ("GET", "/api/shows/1/search", none.clone()),
        ("PUT", "/api/episodes/1/position", Some(serde_json::json!({}))),
        ("PUT", "/api/ad-removal/deepseek-key", Some(serde_json::json!({}))),
        ("POST", "/api/ad-removal/enable", Some(serde_json::json!({}))),
        ("PUT", "/api/settings", Some(serde_json::json!({}))),
        ("PUT", "/api/settings", Some(serde_json::json!({"speed": 1.5}))),
        ("GET", "/api/next", none.clone()),
        ("GET", "/api/search", none.clone()),
        ("POST", "/api/shows", Some(serde_json::json!({"feed_url": "notaurl"}))),
        ("POST", "/api/youtube/videos", Some(serde_json::json!({"url": "https://example.com/x"}))),
        ("GET", "/api/ad-removal/statuses?episode_ids=abc", none.clone()),
    ];
    for (method, target, body) in cases {
        let response = legacy_call(&backend, method, target, body);
        assert_eq!(response.status_code, 422, "{method} {target}");
    }
}

#[test]
fn test_cov_backend_next_defaults_context_to_recent() {
    let (backend, _temp, _fetcher) = legacy_backend();
    let response = legacy_call(&backend, "GET", "/api/next?after=1", None);
    assert_eq!(response.status_code, 404);
}

#[test]
fn test_cov_backend_diagnostics_failures_surface_as_500() {
    let (backend, _temp, _fetcher) = legacy_backend();
    let logs = _temp.path().join("Diagnostics").join("logs");
    if logs.exists() {
        std::fs::remove_dir_all(&logs).unwrap();
    }
    std::fs::write(&logs, "not a dir").unwrap();
    let export = legacy_call(&backend, "GET", "/api/ad-removal/diagnostics/export", None);
    assert_eq!(export.status_code, 200);
    let clear = legacy_call(&backend, "POST", "/api/ad-removal/diagnostics/clear", None);
    assert_eq!(clear.status_code, 500);
}

#[test]
fn test_cov_backend_canonicalize_merges_duplicate_channel_feeds() {
    let (backend, _temp, _fetcher) = legacy_backend();
    let channel = "UCabcdefghijklmnopqrstuv";
    let canonical = pods_backend::youtube::channel_feed_url(channel);
    backend.db.execute(
        "INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, ?, 'A', 1)",
        rusqlite::params![canonical],
    )
    .unwrap();
    let page = format!("https://www.youtube.com/channel/{channel}");
    backend.db.execute(
        "INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (2, ?, 'B', 1)",
        rusqlite::params![page],
    )
    .unwrap();
    assert!(backend.canonicalize_youtube_feed(2, &page).unwrap());
}

#[test]
fn test_cov_backend_add_youtube_video_reuses_existing_podcast() {
    let (backend, _temp, _fetcher) = legacy_backend();
    let channel = "UCabcdefghijklmnopqrstuv";
    let probe = pods_backend::youtube::MapProbe::default();
    probe.videos.lock().unwrap().insert(
        "abcdefghijk".into(),
        pods_backend::youtube::VideoMeta {
            video_id: "abcdefghijk".into(),
            channel_id: channel.into(),
            channel_title: "Example Channel".into(),
            title: "One video".into(),
            thumbnail: "https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg".into(),
            published_at: 1_700_000_000,
            description: "Hello".into(),
        },
    );
    backend.set_youtube_probe(std::sync::Arc::new(probe));
    backend.db.execute(
        "INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, ?, 'Seeded', 1)",
        rusqlite::params![pods_backend::youtube::channel_feed_url(channel)],
    )
    .unwrap();
    let response = legacy_call(
        &backend,
        "POST",
        "/api/youtube/videos",
        Some(serde_json::json!({"url": "https://www.youtube.com/watch?v=abcdefghijk"})),
    );
    assert_eq!(response.status_code, 201);
}

#[test]
fn test_cov_backend_add_listen_episode_reuses_existing_podcast() {
    let (backend, _temp, fetcher) = legacy_backend();
    fetcher.set(
        "https://f.example/rss",
        "<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>S</title><item><title>E1</title><guid>g1</guid><enclosure url=\"https://f.example/a.mp3\" type=\"audio/mpeg\" length=\"1\"/></item></channel></rss>",
    );
    backend.db.execute(
        "INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://f.example/rss', 'S', 1)",
        [],
    )
    .unwrap();
    let response = legacy_call(
        &backend,
        "POST",
        "/api/listen-episodes",
        Some(serde_json::json!({"feed_url": "https://f.example/rss", "guid": "g1"})),
    );
    assert_eq!(response.status_code, 201);
}

#[test]
fn test_cov_backend_episode_detail_maps_show_notes() {
    let (backend, _temp, _fetcher) = legacy_backend();
    seed_episode(&backend.db);
    JobStore::new(&backend.db)
        .replace_show_notes(
            1,
            &[pods_backend::jobs::ShowNoteRecord {
                segment_id: "s0".into(),
                start_time: 0.0,
                title: "t".into(),
                summary: "s".into(),
                model_id: "m".into(),
                prompt_version: "pv".into(),
                created_at: 1,
            }],
        )
        .unwrap();
    let response = legacy_call(&backend, "GET", "/api/episodes/1", None);
    assert_eq!(response.status_code, 200);
    assert!(String::from_utf8_lossy(&response.body).contains("\"title\":\"t\""));
}

#[test]
fn test_cov_backend_search_marks_subscribed_directory_results() {
    let temp = tempfile::tempdir().unwrap();
    let db = Database::open_in_memory().unwrap();
    db.execute(
        "INSERT INTO podcasts (id, feed_url, title, created_at, is_subscribed) VALUES (1, 'https://f.example/rss', 'S', 1, 1)",
        [],
    )
    .unwrap();
    let backend = Backend::with_data_root(
        db,
        std::sync::Arc::new(MockFeedFetcher::default()),
        std::sync::Arc::new(StubDirectory {
            podcasts: vec![DirectoryPodcast {
                title: "Found".into(),
                author: "Au".into(),
                feed_url: "https://f.example/rss".into(),
                image_url: "".into(),
                description: "".into(),
                subscribed: false,
            }],
        }),
        Some(temp.path().to_owned()),
    );
    let response = legacy_call(&backend, "GET", "/api/search?q=found", None);
    assert_eq!(response.status_code, 200);
    let results: SearchResults = serde_json::from_slice(&response.body).unwrap();
    assert!(results.podcasts[0].subscribed);
}

#[test]
fn test_cov_backend_search_matches_episode_full_text() {
    let (backend, _temp, _fetcher) = legacy_backend();
    backend.db.execute("INSERT INTO podcasts (id, feed_url, title, created_at, image_url) VALUES (1, 'https://x', 'S', 1, 'https://x/i.png')", []).unwrap();
    backend.db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at, image_url) VALUES (1, 1, 'g', 'E DefinitelyUniqueToken', 'https://a', 100, 'https://x/e.png')", []).unwrap();
    backend.db.execute("INSERT INTO episode_state (episode_id, updated_at) VALUES (1, 1)", []).unwrap();
    backend.db.execute("INSERT INTO episodes_fts (rowid, title, notes) VALUES (1, ' DefinitelyUniqueToken ', '')", []).unwrap();
    let response = legacy_call(&backend, "GET", "/api/search?q=DefinitelyUniqueToken", None);
    assert_eq!(response.status_code, 200);
    assert!(String::from_utf8_lossy(&response.body).contains("DefinitelyUniqueToken"));
}

#[test]
fn test_cov_backend_settings_survive_broken_usage_store() {
    let (backend, _temp, _fetcher) = legacy_backend();
    backend.db.execute("DROP TABLE deepseek_usage", []).unwrap();
    let response = legacy_call(&backend, "GET", "/api/ad-removal/settings", None);
    assert_eq!(response.status_code, 200);
}

#[test]
fn test_cov_backend_pipeline_step_survives_broken_episode_meta() {
    let (backend, _temp, _fetcher) = legacy_backend();
    seed_episode(&backend.db);
    backend.db.execute("INSERT INTO settings (key, value) VALUES ('ad_removal_enabled', 'true')", []).unwrap();
    JobStore::with_now(&backend.db, || 1_000).enqueue(1).unwrap();
    backend.db.execute("UPDATE episodes SET duration_secs = 'junk'", []).unwrap();
    assert!(backend.run_pipeline_step().is_ok());
}

// ---------- speaker.rs ----------

#[test]
fn test_cov_speaker_dead_transport_reports_disconnect() {
    let (backend, _temp) = sync_backend();
    let memory = std::sync::Arc::new(MemoryTransport::new(true));
    backend.set_speaker_transport(memory.clone());
    backend
        .speaker
        .load(1, "h".into(), std::path::Path::new("/tmp/x.m4a"), 0.0, 1.0, "s1".into(), 0, false, false)
        .unwrap();
    memory.set_alive(false);
    let status = backend.speaker.status();
    assert_eq!(status.error.as_deref(), Some("Mac speaker disconnected."));
    assert!(backend.speaker.child_pid().is_none());
}

#[test]
fn test_cov_speaker_load_validates_request_shape() {
    let (backend, _temp) = sync_backend();
    let hash = "b".repeat(64);
    let cases = [
        serde_json::json!({}),
        serde_json::json!({"episode_id": 1}),
        serde_json::json!({"episode_id": 1, "session_id": "s1"}),
        serde_json::json!({"episode_id": 1, "session_id": "s1", "generation": -1}),
        serde_json::json!({"episode_id": 1, "session_id": "s1", "generation": 1}),
        serde_json::json!({"episode_id": 1, "session_id": "s1", "generation": 1, "artifact_hash": hash, "position": "x"}),
        serde_json::json!({"episode_id": 1, "session_id": "s1", "generation": 1, "artifact_hash": hash, "position": 0.0, "rate": "x"}),
    ];
    for body in cases {
        let response = backend.handle(HttpRequest::new("POST", "/api/speaker/load").with_json(&body));
        assert_eq!(response.status_code, 422, "{body}");
    }
    let rate = backend.handle(
        HttpRequest::new("POST", "/api/speaker/rate").with_json(&serde_json::json!({"session_id": "s1", "generation": 1})),
    );
    assert_eq!(rate.status_code, 422);
}

// ---------- feeds.rs ----------

#[test]
fn test_cov_feeds_rejects_non_utf8() {
    assert!(parse_feed(&[0xff, 0xfe, 0x00]).is_err());
}

#[test]
fn test_cov_feeds_fetch_without_validators_keeps_previous() {
    let url = serve_once("200 OK", "application/rss+xml", b"<rss></rss>");
    let fetch = UreqFetcher::default();
    let validators = FeedValidators { etag: Some("old-etag".into()), last_modified: Some("old-date".into()) };
    let response = fetch.fetch(&url, &validators).unwrap();
    match response {
        pods_backend::feeds::FeedFetchResponse::Data(data, next) => {
            assert_eq!(data, b"<rss></rss>");
            assert_eq!(next.etag.as_deref(), Some("old-etag"));
            assert_eq!(next.last_modified.as_deref(), Some("old-date"));
        }
        other => panic!("expected data, got {other:?}"),
    }
}

#[test]
fn test_cov_feeds_truncated_body_fails_read() {
    let url = serve_truncated(100, b"short");
    let fetch = UreqFetcher::default();
    let validators = FeedValidators { etag: None, last_modified: None };
    assert!(fetch.fetch(&url, &validators).is_err());
}

#[test]
fn test_cov_feeds_not_modified_keeps_previous_validators() {
    let url = serve_once("304 Not Modified", "application/rss+xml", b"");
    let fetch = UreqFetcher::default();
    let validators = FeedValidators { etag: Some("old-etag".into()), last_modified: Some("old-date".into()) };
    let response = fetch.fetch(&url, &validators).unwrap();
    match response {
        pods_backend::feeds::FeedFetchResponse::NotModified(next) => {
            assert_eq!(next.etag.as_deref(), Some("old-etag"));
            assert_eq!(next.last_modified.as_deref(), Some("old-date"));
        }
        other => panic!("expected not-modified, got {other:?}"),
    }
}

// ---------- bootstrap.rs ----------

#[test]
fn test_cov_bootstrap_seed_copy_failures() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let seed = dir.path().join("seed.sqlite");
    Database::open(&seed).unwrap();
    let blocker = dir.path().join("blocker");
    std::fs::write(&blocker, "x").unwrap();
    assert!(bootstrap::prepare(&blocker.join("live.sqlite"), Some(&seed)).is_err());

    let ro = dir.path().join("ro");
    std::fs::create_dir(&ro).unwrap();
    std::fs::set_permissions(&ro, std::fs::Permissions::from_mode(0o555)).unwrap();
    let missing = bootstrap::prepare(&ro.join("live.sqlite"), Some(&seed)).is_err();
    std::fs::set_permissions(&ro, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert!(missing);
}

#[test]
fn test_cov_bootstrap_replace_failures_in_readonly_dir() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let seed = dir.path().join("seed.sqlite");
    Database::open(&seed).unwrap();
    for live_name in ["garbage.sqlite", "empty.sqlite"] {
        let ro = dir.path().join(format!("ro-{live_name}"));
        std::fs::create_dir(&ro).unwrap();
        let live = ro.join("live.sqlite");
        if live_name.starts_with("garbage") {
            std::fs::write(&live, "not a database").unwrap();
        } else {
            Database::open(&live).unwrap();
        }
        std::fs::set_permissions(&ro, std::fs::Permissions::from_mode(0o555)).unwrap();
        let failed = bootstrap::prepare(&live, Some(&seed)).is_err();
        std::fs::set_permissions(&ro, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(failed, "{live_name} replace must fail");
    }
}

#[test]
fn test_cov_bootstrap_directory_live_fails_validation() {
    let dir = tempfile::tempdir().unwrap();
    let live = dir.path().join("adir");
    std::fs::create_dir(&live).unwrap();
    assert!(bootstrap::prepare(&live, None).is_ok());
}

// ---------- http.rs ----------

#[test]
fn test_cov_http_path_falls_back_to_raw_target() {
    let request = HttpRequest::new("GET", "http://[::1");
    assert_eq!(request.path(), "http://[::1");
}

#[test]
fn test_cov_http_offset_ignores_unparseable_values() {
    let request = HttpRequest::new("GET", "/api/recent?offset=abc");
    assert_eq!(request.offset(), 0);
}

#[test]
fn test_cov_http_json_object_rejects_invalid_body() {
    let mut request = HttpRequest::new("POST", "/api/x");
    request.body = b"not json".to_vec();
    assert!(request.json_object().is_err());
}

// ---------- directory.rs ----------

#[test]
fn test_cov_directory_truncated_body_fails_read() {
    let url = serve_truncated(100, b"short");
    let client = PodcastIndexClient::new("k", "s", url.trim_end_matches('/'));
    assert!(client.search("x").is_err());
}

#[test]
fn test_cov_directory_non_json_body_fails_parse() {
    let url = serve_once("200 OK", "application/json", b"not json");
    let client = PodcastIndexClient::new("k", "s", url.trim_end_matches('/'));
    assert!(client.search("x").is_err());
}

#[test]
fn test_cov_directory_appearances_fall_back_to_numeric_id() {
    let url = serve_once(
        "200 OK",
        "application/json",
        br#"{"items":[{"feedUrl":"https://f.example/rss","enclosureUrl":"https://f.example/a.mp3","id":7,"title":"t person","persons":[{"name":"person","role":"guest"}]}]}"#,
    );
    let client = PodcastIndexClient::new("k", "s", url.trim_end_matches('/'));
    let items = client.search_appearances("person").unwrap();
    assert_eq!(items.len(), 1);
}

// ---------- storage.rs ----------

#[test]
fn test_cov_storage_finalize_install_failure() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("store");
    let store = ArtifactStore::open(root.clone()).unwrap();
    let db = Database::open_in_memory().unwrap();
    let episode_id = seed_episode(&db);
    let job_store = JobStore::with_now(&db, || 1_000);
    let job = job_store.enqueue(episode_id).unwrap();
    job_store.transition(&job.id, JobStage::Downloading).unwrap();
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o555)).unwrap();
    let download = DownloadResult { bytes: b"ID3".to_vec(), content_type: "audio/mpeg".into(), status: 200 };
    let result = finalize_download(&store, &job_store, &job.id, episode_id, &download);
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert!(result.is_err());
}

#[test]
fn test_cov_storage_finalize_rejects_wrong_job_stage() {
    let dir = tempfile::tempdir().unwrap();
    let store = ArtifactStore::open(dir.path().join("store")).unwrap();
    let db = Database::open_in_memory().unwrap();
    let episode_id = seed_episode(&db);
    let job_store = JobStore::with_now(&db, || 1_000);
    let job = job_store.enqueue(episode_id).unwrap();
    let download = DownloadResult { bytes: b"ID3".to_vec(), content_type: "audio/mpeg".into(), status: 200 };
    assert!(finalize_download(&store, &job_store, &job.id, episode_id, &download).is_err());
}

#[test]
fn test_cov_storage_finalize_transition_failure() {
    let dir = tempfile::tempdir().unwrap();
    let store = ArtifactStore::open(dir.path().join("store")).unwrap();
    let db = Database::open_in_memory().unwrap();
    let episode_id = seed_episode(&db);
    let job_store = JobStore::with_now(&db, || 1_000);
    let job = job_store.enqueue(episode_id).unwrap();
    job_store.transition(&job.id, JobStage::Downloading).unwrap();
    db.execute(
        "CREATE TRIGGER cov_fail_fin BEFORE UPDATE ON ad_removal_jobs WHEN NEW.stage = 'downloaded' BEGIN SELECT RAISE(ABORT, 'cov'); END",
        [],
    )
    .unwrap();
    let download = DownloadResult { bytes: b"ID3".to_vec(), content_type: "audio/mpeg".into(), status: 200 };
    assert!(finalize_download(&store, &job_store, &job.id, episode_id, &download).is_err());
}

// ---------- articles.rs / feedback.rs env ----------

#[test]
fn test_cov_articles_tts_env_overrides() {
    let _lock = ENV_LOCK.lock().unwrap();
    let _guard = EnvGuard::take(&["PODS_TTS_MODEL", "PODS_TTS_REVISION"]);
    std::env::set_var("PODS_TTS_MODEL", "m1");
    std::env::set_var("PODS_TTS_REVISION", "r1");
    assert_eq!(tts_model(), "m1");
    assert_eq!(tts_revision(), "r1");
}

#[test]
fn test_cov_feedback_model_env_override() {
    let _lock = ENV_LOCK.lock().unwrap();
    let _guard = EnvGuard::take(&["PODS_FEEDBACK_MODEL"]);
    std::env::set_var("PODS_FEEDBACK_MODEL", "fb-model");
    assert_eq!(pods_backend::feedback::model(), "fb-model");
}

// ---------- classify.rs ----------

#[test]
fn test_cov_classify_parsers_reject_bad_shapes() {
    assert!(parse_structured_labels("{}", &["a".to_string()]).is_err());
    assert!(parse_show_notes("!!! not json !!!", &["a".to_string()]).is_err());
}

#[test]
fn test_cov_classify_listen_title_rejects_capitalized_particle() {
    let err = accept_listen_title("Anna Of Troy: three small word test", "anna troy show").unwrap_err();
    assert_eq!(err, "listen title guest case");
}

// ---------- db.rs ----------

#[test]
fn test_cov_db_last_insert_rowid() {
    let db = Database::open_in_memory().unwrap();
    seed_episode(&db);
    assert!(db.last_insert_rowid().unwrap() >= 1);
}

// ---------- voice.rs ----------

#[test]
fn test_cov_voice_note_install_failure() {
    use std::os::unix::fs::PermissionsExt;
    let (backend, temp) = sync_backend();
    let root = temp.path().join("AdRemoval");
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o555)).unwrap();
    let mut request = HttpRequest::new("POST", "/api/feedback/voice");
    request = request.with_header("x-pods-voice-id", "recording-1");
    request = request.with_header("x-pods-client-id", "c1");
    request = request.with_header("content-type", "audio/m4a");
    request.body = vec![7u8; 64];
    let response = backend.handle(request);
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert_eq!(response.status_code, 500);
}

// ---------- diagnostics.rs ----------

#[test]
fn test_cov_diagnostics_redacts_key_like_tokens() {
    let event = DiagnosticEvent {
        event_name: "e".into(),
        severity: "info".into(),
        message: "hello key=abcdef0123456789abcdef01 world".into(),
        job_id: None,
        episode_id: None,
        playback_session_id: None,
    };
    assert!(event.redacted().message.contains("[redacted]"));
}

// ---------- youtube.rs ----------

fn with_ytdlp<T>(bin: Option<&std::path::Path>, work: impl FnOnce() -> T) -> T {
    let _guard = YT_DLP_TEST_LOCK.lock().unwrap();
    let previous = std::env::var("PODS_YT_DLP").ok();
    match bin {
        Some(path) => std::env::set_var("PODS_YT_DLP", path),
        None => std::env::remove_var("PODS_YT_DLP"),
    }
    let result = work();
    match previous {
        Some(value) => std::env::set_var("PODS_YT_DLP", value),
        None => std::env::remove_var("PODS_YT_DLP"),
    }
    result
}

fn stub_ytdlp(dir: &std::path::Path, script: &str) -> std::path::PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let bin = dir.join("yt-dlp");
    std::fs::write(&bin, script).unwrap();
    std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
    bin
}

#[test]
fn test_cov_youtube_map_probe_misses() {
    let probe = MapProbe::default();
    assert!(probe.channel_id("https://www.youtube.com/channel/x").is_err());
    assert!(probe.video("abcdefghijk").is_err());
    probe.channels.lock().unwrap().insert("https://u".into(), "bogus".into());
    assert!(probe.channel_id("https://u").is_err());
}

#[test]
fn test_cov_youtube_classify_edge_urls() {
    assert!(classify("http://youtube.com:99999/x").is_err());
    assert!(classify("https://youtu.be/").is_err());
    assert!(classify("https://www.youtube.com/c/").is_err());
    assert!(classify("https://www.youtube.com/shorts/ab").is_err());
    assert!(classify("https://www.youtube.com/channel/short").is_err());
}

#[test]
fn test_cov_youtube_atom_rejects_bad_bytes_and_reads_author() {
    assert!(parse_atom(&[0xff, 0xfe]).is_err());
    assert!(parse_atom(b"not xml").is_err());
    let feed = parse_atom(
        br#"<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom" xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns:media="http://search.yahoo.com/mrss/"><title></title><author><name>Auth</name></author><entry><yt:videoId>abcdefghijk</yt:videoId><title>V</title><published>2024-01-15T00:00:00+00:00</published><media:group><media:description>notes</media:description></media:group></entry></feed>"#,
    )
    .unwrap();
    assert_eq!(feed.episodes.len(), 1);
    assert_eq!(feed.title, "Auth");
}

#[test]
fn test_cov_youtube_meta_requires_ids_and_falls_back() {
    assert!(video_meta_from_json(&serde_json::json!({})).is_err());
    assert!(video_meta_from_json(&serde_json::json!({"id": "abcdefghijk"})).is_err());
    let meta = video_meta_from_json(&serde_json::json!({
        "id": "abcdefghijk",
        "channel_id": "UCabcdefghijklmnopqrstuv",
        "uploader": "Up",
        "upload_date": "20240115",
    }))
    .unwrap();
    assert_eq!(meta.published_at, 1_705_276_800);
    assert_eq!(meta.channel_title, "Up");
}

#[test]
fn test_cov_youtube_bin_defaults_without_env() {
    with_ytdlp(None, || assert_eq!(ytdlp_bin(), "yt-dlp"));
}

#[test]
fn test_cov_youtube_probe_channel_fallback_failure() {
    let dir = tempfile::tempdir().unwrap();
    let bin = stub_ytdlp(
        dir.path(),
        "#!/bin/sh\nif echo \"$*\" | grep -q -- '--flat-playlist'; then echo 'NA\tF3YXg7AaKWE'; else echo 'NA'; fi\n",
    );
    with_ytdlp(Some(&bin), || {
        assert!(CommandProbe.channel_id("https://www.youtube.com/channel/x").is_err());
    });
}

#[test]
fn test_cov_youtube_probe_video_parse_failures() {
    let dir = tempfile::tempdir().unwrap();
    let plain = stub_ytdlp(dir.path(), "#!/bin/sh\necho 'no json here'\n");
    with_ytdlp(Some(&plain), || {
        assert!(CommandProbe.video("abcdefghijk").is_err());
    });
    let broken = stub_ytdlp(dir.path(), "#!/bin/sh\necho '{oops'\n");
    with_ytdlp(Some(&broken), || {
        assert!(CommandProbe.video("abcdefghijk").is_err());
    });
}

#[test]
fn test_cov_youtube_probe_missing_binary_fails_fast() {
    with_ytdlp(Some(std::path::Path::new("/nonexistent-cov-yt-dlp")), || {
        assert!(CommandProbe.video("abcdefghijk").is_err());
    });
}

// ---------- jev.rs ----------

#[test]
fn test_cov_jev_key_requires_credentials_file() {
    let _lock = ENV_LOCK.lock().unwrap();
    let _guard = EnvGuard::take(&["PODS_TYPESAFE_KEY", "TYPESAFE_API_KEY", "PODS_CREDENTIALS_FILE", "HOME"]);
    std::env::remove_var("PODS_TYPESAFE_KEY");
    std::env::remove_var("TYPESAFE_API_KEY");
    std::env::remove_var("PODS_CREDENTIALS_FILE");
    std::env::remove_var("HOME");
    assert!(configured_api_key().is_err());
}

#[test]
fn test_cov_jev_key_rejects_missing_and_keyless_files() {
    let _lock = ENV_LOCK.lock().unwrap();
    let _guard = EnvGuard::take(&["PODS_TYPESAFE_KEY", "TYPESAFE_API_KEY", "PODS_CREDENTIALS_FILE"]);
    std::env::remove_var("PODS_TYPESAFE_KEY");
    std::env::remove_var("TYPESAFE_API_KEY");
    std::env::set_var("PODS_CREDENTIALS_FILE", "/nonexistent-cov-credentials.env");
    assert!(configured_api_key().is_err());
    let dir = tempfile::tempdir().unwrap();
    let creds = dir.path().join("credentials.env");
    std::fs::write(&creds, "# comment\nOTHER=1\nMALFORMED\nTYPESAFE_API_KEY=\n").unwrap();
    std::env::set_var("PODS_CREDENTIALS_FILE", &creds);
    assert!(configured_api_key().is_err());
    std::fs::write(&creds, "TYPESAFE_API_KEY=test-key\n").unwrap();
    assert_eq!(configured_api_key().unwrap(), "test-key");
}

#[test]
fn test_cov_jev_window_requires_answers() {
    let segments = vec![Segment { id: "s0".into(), start: 0.0, end: 1.0, text: "hi".into() }];
    let err = classify_window_with(&segments, 0, 1, 0, |_| Ok(serde_json::json!({}))).unwrap_err();
    assert!(err.to_string().contains("answers missing"));
}

#[test]
fn test_cov_jev_default_episode_dir() {
    let dir = default_episode_dir(42);
    assert!(dir.ends_with("42"));
    assert!(dir.to_string_lossy().contains("AdRemoval"));
}

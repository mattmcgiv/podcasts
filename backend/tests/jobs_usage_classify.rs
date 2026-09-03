use pods_backend::classify::{parse_show_notes, parse_structured_labels, windows, SHOW_NOTES_CHAPTER_BASELINE};
use pods_backend::db::Database;
use pods_backend::jobs::{AudioArtifact, JobStage, JobStore};
use pods_backend::transcribe;
use pods_backend::usage::{cost_usd, parse_usage, UsageTokens};

fn seed_episode(db: &Database) -> i64 {
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 100)", []).unwrap();
    db.execute("INSERT INTO episode_state (episode_id, updated_at) VALUES (1, 1)", []).unwrap();
    1
}

#[test]
fn test_enqueue_and_stage_transitions_are_durable_idempotent_and_validated() {
    let db = Database::open_in_memory().unwrap();
    let episode_id = seed_episode(&db);
    let store = JobStore::with_now(&db, || 1_000);
    let queued = store.enqueue(episode_id).unwrap();
    assert_eq!(queued.stage, JobStage::Queued);
    assert_eq!(queued.enrolled_at, 1_000);
    let downloading = store.transition(&queued.id, JobStage::Downloading).unwrap();
    assert_eq!(downloading.stage, JobStage::Downloading);
    let idempotent = store.transition(&queued.id, JobStage::Downloading).unwrap();
    assert_eq!(idempotent.id, downloading.id);
    assert!(store.transition(&queued.id, JobStage::Ready).is_err());
}

#[test]
fn test_daily_classification_budget_caps_distinct_episodes_at_twenty() {
    let db = Database::open_in_memory().unwrap();
    let first = seed_episode(&db);
    for i in 2..=21 {
        db.execute(
            "INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (?, 1, ?, 'E', 'https://a', ?)",
            rusqlite::params![i, format!("g{i}"), i],
        ).unwrap();
    }
    let now = std::sync::Arc::new(std::sync::atomic::AtomicI64::new(1_752_500_000));
    let clock = now.clone();
    let store = JobStore::with_now(&db, move || clock.load(std::sync::atomic::Ordering::SeqCst));
    assert!(store.reserve_daily_classification_slot(first, 20).unwrap());
    assert!(store.reserve_daily_classification_slot(first, 20).unwrap());
    for i in 2..=20 {
        assert!(store.reserve_daily_classification_slot(i, 20).unwrap());
    }
    assert!(!store.reserve_daily_classification_slot(21, 20).unwrap());
    now.store(1_752_500_000 + 86_400, std::sync::atomic::Ordering::SeqCst);
    assert!(store.reserve_daily_classification_slot(21, 20).unwrap());
}

#[test]
fn test_runnable_selection_is_oldest_unplayed_first_and_honors_blocking_reasons() {
    let db = Database::open_in_memory().unwrap();
    let newer = seed_episode(&db);
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (2, 1, 'older', 'O', 'https://a', 50)", []).unwrap();
    db.execute("INSERT INTO episode_state (episode_id, updated_at) VALUES (2, 1)", []).unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    let newer_job = store.enqueue(newer).unwrap();
    let older_job = store.enqueue(2).unwrap();
    assert_eq!(store.next_runnable_job().unwrap().unwrap().id, older_job.id);
    let _ = store.set_blocking_reason(&older_job.id, Some(pods_backend::jobs::BlockingReason::LowPower)).unwrap();
    assert_eq!(store.next_runnable_job().unwrap().unwrap().id, newer_job.id);
    store.clear_blocking_reasons(&[pods_backend::jobs::BlockingReason::LowPower]).unwrap();
    assert_eq!(store.next_runnable_job().unwrap().unwrap().id, older_job.id);
}

#[test]
fn test_archived_episode_cannot_be_enqueued() {
    let db = Database::open_in_memory().unwrap();
    let id = seed_episode(&db);
    db.execute("UPDATE episode_state SET archived_at = 1000 WHERE episode_id = ?", [id]).unwrap();
    assert!(JobStore::new(&db).enqueue(id).is_err());
}

#[test]
fn test_audio_artifact_metadata_is_durable_and_rejects_unaudited_paths() {
    let db = Database::open_in_memory().unwrap();
    let id = seed_episode(&db);
    let store = JobStore::with_now(&db, || 1_000);
    let queued = store.enqueue(id).unwrap();
    let _ = store.transition(&queued.id, JobStage::Downloading).unwrap();
    let artifact = AudioArtifact {
        relative_path: format!("episodes/{id}/audio.mp3"),
        sha256: "a".repeat(64),
        byte_count: 12345,
    };
    let recorded = store.record_audio_artifact(&queued.id, &artifact).unwrap();
    assert_eq!(recorded.audio_artifact.unwrap().byte_count, 12345);
    assert!(store.record_audio_artifact(&queued.id, &AudioArtifact { relative_path: "/tmp/untrusted.mp3".into(), sha256: artifact.sha256, byte_count: artifact.byte_count }).is_err());
}

#[test]
fn test_failures_retry_four_times_with_stable_metadata_and_resume_failed_stage() {
    let db = Database::open_in_memory().unwrap();
    let id = seed_episode(&db);
    let store = JobStore::with_now(&db, || 1_000);
    let queued = store.enqueue(id).unwrap();
    let downloading = store.transition(&queued.id, JobStage::Downloading).unwrap();
    let mut job = downloading;
    for _ in 0..3 {
        job = store.record_failure(&job.id, "net", "boom").unwrap();
        assert_eq!(job.stage, JobStage::Downloading);
        assert!(job.retry_eligible);
    }
    job = store.record_failure(&job.id, "net", "boom").unwrap();
    assert_eq!(job.stage, JobStage::Failed);
    assert!(!job.retry_eligible);
    let resumed = store.retry(&job.id).unwrap();
    assert_eq!(resumed.stage, JobStage::Downloading);
}

#[test]
fn test_parse_usage_reads_deepseek_token_fields() {
    let value = serde_json::json!({"usage":{"prompt_tokens":10,"completion_tokens":4,"prompt_cache_hit_tokens":2}});
    let tokens = parse_usage(&value).unwrap();
    assert_eq!(tokens.input_tokens, Some(10));
    assert_eq!(tokens.output_tokens, Some(4));
    assert_eq!(tokens.cached_input_tokens, Some(2));
}

#[test]
fn test_cost_uses_published_peak_and_off_peak_rates() {
    let tokens = UsageTokens { input_tokens: Some(1_000_000), cached_input_tokens: Some(0), output_tokens: Some(1_000_000) };
    let peak = 2 * 3600; // 02:00 UTC Thursday 1970 is peak
    let off = 20 * 3600; // 20:00 UTC off-peak
    let peak_cost = cost_usd(&tokens, peak).unwrap();
    let off_cost = cost_usd(&tokens, off).unwrap();
    assert!((peak_cost - (1.32 + 3.96)).abs() < 0.0001);
    assert!((off_cost - (0.66 + 1.98)).abs() < 0.0001);
}

#[test]
fn test_structured_output_parser_accepts_only_complete_known_segment_labels() {
    let ids = vec!["a".into(), "b".into()];
    let raw = r#"{"labels":[{"segment_id":"a","label":"content","reason":"ok"},{"segment_id":"b","label":"ad","reason":"promo"}]}"#;
    let labels = parse_structured_labels(raw, &ids).unwrap();
    assert_eq!(labels.len(), 2);
    assert!(parse_structured_labels(r#"{"labels":[{"segment_id":"z","label":"ad","reason":"x"}]}"#, &ids).is_err());
}

#[test]
fn test_structured_output_parser_enforces_documented_reason_character_limit() {
    let ids = vec!["a".into()];
    let reason = "x".repeat(161);
    let raw = format!(r#"{{"labels":[{{"segment_id":"a","label":"content","reason":"{reason}"}}]}}"#);
    assert!(parse_structured_labels(&raw, &ids).is_err());
}

#[test]
fn test_structured_output_parser_accepts_one_outer_json_fence_or_json_string_wrapper() {
    let ids = vec!["a".into()];
    let fenced = "```json\n{\"labels\":[{\"segment_id\":\"a\",\"label\":\"content\",\"reason\":\"ok\"}]}\n```";
    assert_eq!(parse_structured_labels(fenced, &ids).unwrap().len(), 1);
}

#[test]
fn test_show_notes_parser_accepts_the_configured_chapter_baseline() {
    assert_eq!(SHOW_NOTES_CHAPTER_BASELINE, 12);
    let ids: Vec<String> = (0..12).map(|i| format!("s{i}")).collect();
    let chapters: Vec<_> = ids.iter().map(|id| serde_json::json!({"segment_id": id, "title": "t", "summary": "s"})).collect();
    let raw = serde_json::json!({"chapters": chapters}).to_string();
    assert_eq!(parse_show_notes(&raw, &ids).unwrap().len(), 12);
}

#[test]
fn test_show_notes_parser_rejects_more_chapters_than_the_baseline() {
    let ids: Vec<String> = (0..13).map(|i| format!("s{i}")).collect();
    let chapters: Vec<_> = ids.iter().map(|id| serde_json::json!({"segment_id": id, "title": "t", "summary": "s"})).collect();
    let raw = serde_json::json!({"chapters": chapters}).to_string();
    assert!(parse_show_notes(&raw, &ids).is_err());
}

#[test]
fn test_window_builder_bounds_input_and_overlaps_transcript_segments() {
    let ids: Vec<String> = (0..5).map(|i| format!("{i}")).collect();
    let w = windows(&ids, 3, 1);
    assert_eq!(w.first().unwrap().len(), 3);
    assert!(w.len() >= 2);
}

#[test]
fn test_segment_factory_produces_stable_original_timeline_identifiers() {
    let segs = transcribe::from_finalized(9, "en", &[(0.0, 1.0, "hi".into()), (1.0, 2.5, "there".into())]).unwrap();
    assert_eq!(segs[0].id, transcribe::stable_segment_id(9, 0, 0));
    assert_eq!(segs[1].index, 1);
}

#[test]
fn test_transcription_errors_expose_stable_specific_nserror_codes() {
    assert_eq!(transcribe::error_code("canceled"), "transcription.canceled");
    assert_eq!(transcribe::error_code("unsupported"), "transcription.unsupported_audio");
}

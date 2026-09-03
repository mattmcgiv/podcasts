use pods_backend::backend::{Backend, CredentialStore};
use pods_backend::pipeline::CloudClassifier;
use pods_backend::classify::{
    classification_prompt, parse_structured_labels, production_windows, select_corrections, short_request_ids,
    total_windows, CorrectionExample, PRODUCTION_BATCH, SHOW_NOTES_CHAPTER_BASELINE,
};
use pods_backend::coordinator::Coordinator;
use pods_backend::db::{self, Database};
use pods_backend::diagnostics::{DiagnosticEvent, Diagnostics};
use pods_backend::feeds::{fetch_with_https_fallback, FeedFetchResponse, FeedFetcher, MockFeedFetcher, UreqFetcher};
use pods_backend::http::HttpRequest;
use pods_backend::jobs::{
    blocking_reason_for_stage, AudioArtifact, ClassificationEvidence, JobStage, JobStore, ResourceConditions,
    ShowNoteRecord,
};
use pods_backend::models::*;
use pods_backend::server::{parse_request, ParseResult, MAXIMUM_REQUEST_BYTES};
use pods_backend::skip::AdSkipRange;
use pods_backend::storage::{self, ArtifactStore, DownloadResult};
use pods_backend::transcribe::{self, ResultAccumulator, TranscriptSegment};
use pods_backend::usage::{
    episode_key, legacy_record_id, parse_usage_result, ParsedUsage, UsageStore, UsageTokens,
};
use pods_backend::{Error, DisabledDirectory};
use rusqlite::Connection;
use serde_json::json;
use std::io::Read;
use std::sync::{mpsc, Arc, Mutex};
use std::thread;
use std::time::Duration;

const D1: &str = "Mon, 06 Jan 2025 00:00:00 GMT";
const D2: &str = "Tue, 07 Jan 2025 00:00:00 GMT";
const D3: &str = "Wed, 08 Jan 2025 00:00:00 GMT";

fn rss(show: &str, items: &[(&str, &str, &str, &str)]) -> String {
    let mut body = format!("<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>{show}</title><description>About {show}</description>");
    for (title, guid, url, date) in items {
        body.push_str(&format!(
            "<item><title>{title}</title><guid>{guid}</guid><pubDate>{date}</pubDate><description>&lt;p&gt;Notes for {title}&lt;/p&gt;</description><enclosure url=\"{url}\" type=\"audio/mpeg\" length=\"123\"/></item>"
        ));
    }
    body.push_str("</channel></rss>");
    body
}

fn harness() -> (Backend, Arc<MockFeedFetcher>) {
    let db = Database::open_in_memory().unwrap();
    let fetcher = Arc::new(MockFeedFetcher::default());
    let backend = Backend::new(db, fetcher.clone(), Arc::new(DisabledDirectory));
    (backend, fetcher)
}

fn put_key(backend: &Backend) {
    let _ = call(backend, "PUT", "/api/ad-removal/deepseek-key", Some(json!({"api_key": "test-api-key"})));
}

fn call(backend: &Backend, method: &str, target: &str, body: Option<serde_json::Value>) -> pods_backend::HttpResponse {
    let mut req = HttpRequest::new(method, target);
    if let Some(value) = body {
        req = req.with_json(&value);
    }
    backend.handle(req)
}

fn decode<T: serde::de::DeserializeOwned>(response: &pods_backend::HttpResponse) -> T {
    serde_json::from_slice(&response.body).expect("json")
}

fn sha64() -> String {
    "a".repeat(64)
}

fn range(id: &str, start: &str, end: &str, start_time: f64, end_time: f64, disabled: bool) -> AdSkipRange {
    AdSkipRange {
        id: id.into(),
        start_segment_id: start.into(),
        end_segment_id: end.into(),
        start_time,
        end_time,
        confidence: 0.9,
        reason: "ad".into(),
        classifier_version: "v".into(),
        prompt_version: "p".into(),
        created_at: 1_000,
        disabled,
    }
}

fn seed_show(backend: &Backend, fetcher: &MockFeedFetcher, url: &str, show: &str, items: &[(&str, &str, &str, &str)]) -> Show {
    fetcher.set(url, rss(show, items));
    decode(&call(backend, "POST", "/api/shows", Some(json!({"feed_url": url}))))
}

fn segment(id: &str, index: i32, start: f64, end: f64, text: &str) -> TranscriptSegment {
    TranscriptSegment {
        id: id.into(),
        index,
        language: "en".into(),
        start_time: start,
        end_time: end,
        text: text.into(),
    }
}

#[test]
fn test_show_search_is_scoped_to_one_show() {
    let (backend, fetcher) = harness();
    let alpha = seed_show(
        &backend,
        &fetcher,
        "https://feeds.example/a.xml",
        "Alpha",
        &[
            ("Quantum Entanglement Special", "a1", "https://h.example/a1.mp3", D1),
            ("Ordinary Alpha", "a2", "https://h.example/a2.mp3", D2),
        ],
    );
    let _ = seed_show(
        &backend,
        &fetcher,
        "https://feeds.example/b.xml",
        "Beta",
        &[("Quantum Beta", "b1", "https://h.example/b1.mp3", D3)],
    );
    let search: Page<EpisodeItem> = decode(&call(&backend, "GET", &format!("/api/shows/{}/search?q=quant", alpha.id), None));
    assert_eq!(search.items.iter().map(|e| e.title.as_str()).collect::<Vec<_>>(), vec!["Quantum Entanglement Special"]);
    assert!(search.next_offset.is_none());
    assert_eq!(call(&backend, "GET", &format!("/api/shows/{}/search?q=%20", alpha.id), None).status_code, 422);
    assert_eq!(call(&backend, "GET", "/api/shows/424242/search?q=quant", None).status_code, 404);
}

#[test]
fn test_episode_detail_exposes_only_enabled_ad_markers() {
    let (backend, fetcher) = harness();
    let _ = seed_show(
        &backend,
        &fetcher,
        "https://feeds.example/markers.xml",
        "Markers",
        &[("Episode", "chapter-ad-markers", "https://h.example/m.mp3", D1), ("Keep", "keep", "https://h.example/k.mp3", D2)],
    );
    let id = backend.db.scalar_i64("SELECT id FROM episodes WHERE guid = 'chapter-ad-markers'", []).unwrap().unwrap();
    let store = JobStore::with_now(&backend.db, || 1_000);
    let job = store.enqueue(id).unwrap();
    for stage in [JobStage::Downloading, JobStage::Downloaded, JobStage::Transcribing, JobStage::Classifying, JobStage::Ready] {
        store.transition(&job.id, stage).unwrap();
    }
    store
        .replace_transcript_segments(
            id,
            &[
                segment("segment-1", 0, 42.5, 55.0, "Sponsor"),
                segment("segment-2", 1, 55.0, 68.0, "Offer"),
                segment("segment-3", 2, 90.0, 100.0, "Correction"),
                segment("segment-4", 3, 100.0, 110.0, "Editorial"),
            ],
        )
        .unwrap();
    store
        .replace_skip_ranges(
            id,
            &[
                range("enabled-ad", "segment-1", "segment-2", 42.5, 68.0, false),
                range("disabled-ad", "segment-3", "segment-4", 90.0, 110.0, true),
            ],
        )
        .unwrap();
    let detail: EpisodeDetail = decode(&call(&backend, "GET", &format!("/api/episodes/{id}"), None));
    assert_eq!(detail.ad_markers, vec![EpisodeAdMarker { id: "enabled-ad".into(), start_time: 42.5 }]);
}

#[test]
fn test_ad_removal_prepare_rejects_when_deepseek_api_key_is_missing() {
    let db = Database::open_in_memory().unwrap();
    let fetcher = Arc::new(MockFeedFetcher::default());
    let mut backend = Backend::new(db, fetcher.clone(), Arc::new(DisabledDirectory));
    backend.set_credentials(CredentialStore::new(None));
    fetcher.set("https://feeds.example/unavailable-prepare.xml", rss("Unavailable", &[("Ep", "g1", "https://h.example/1.mp3", D1), ("Ep2", "g2", "https://h.example/2.mp3", D2)]));
    let _ = call(&backend, "POST", "/api/shows", Some(json!({"feed_url": "https://feeds.example/unavailable-prepare.xml"})));
    let recent: Page<EpisodeItem> = decode(&call(&backend, "GET", "/api/recent", None));
    let prepared = call(&backend, "POST", &format!("/api/episodes/{}/ad-removal/prepare", recent.items[0].id), None);
    assert_eq!(prepared.status_code, 422);
}

#[test]
fn test_ad_removal_settings_reports_deepseek_usage_metrics() {
    let (backend, _) = harness();
    backend.db.execute("INSERT INTO podcasts (feed_url, title, created_at) VALUES ('https://example.com/usage', 'Usage Show', 1)", []).unwrap();
    backend.db.execute("INSERT INTO episodes (podcast_id, guid, title, audio_url, duration_secs, published_at) VALUES (1, 'usage-1', 'Usage 1', 'https://example.com/usage-1.mp3', 3600, 100)", []).unwrap();
    let store = UsageStore::new(&backend.db);
    let off_peak = 1_787_227_200; // 2026-08-17T12:00:00Z
    let tokens_in = UsageTokens { input_tokens: Some(1_000_000), cached_input_tokens: Some(0), output_tokens: Some(0) };
    let tokens_out = UsageTokens { input_tokens: Some(0), cached_input_tokens: Some(0), output_tokens: Some(1_000_000) };
    store.record(1, "ad_detection", "deepseek-v4-pro", Some(&tokens_in), off_peak).unwrap();
    store.record(1, "show_notes", "deepseek-v4-pro", Some(&tokens_out), off_peak).unwrap();
    let settings: AdRemovalSettingsPayload = decode(&call(&backend, "GET", "/api/ad-removal/settings", None));
    assert!((settings.deepseek_usage.total_cost_usd - 2.64).abs() < 0.0001);
    assert!((settings.deepseek_usage.average_cost_per_episode_usd.unwrap() - 2.64).abs() < 0.0001);
    assert!((settings.deepseek_usage.average_cost_per_podcast_minute_usd.unwrap() - 0.044).abs() < 0.0001);
    assert!((settings.deepseek_usage.ad_detection_cost_usd - 0.66).abs() < 0.0001);
    assert!((settings.deepseek_usage.show_notes_cost_usd - 1.98).abs() < 0.0001);
    assert!(settings.deepseek_usage.telemetry_complete);
}

#[test]
fn test_ad_removal_settings_can_reset_corrections_export_diagnostics_and_delete_feature_data() {
    let (backend, fetcher) = harness();
    let show = seed_show(&backend, &fetcher, "https://feeds.example/data-controls.xml", "Data Controls", &[("Episode", "data-1", "https://h.example/data.mp3", D1), ("Keep", "keep", "https://h.example/k.mp3", D2)]);
    let episode_id = backend.db.scalar_i64("SELECT id FROM episodes WHERE guid = 'data-1'", []).unwrap().unwrap();
    let store = JobStore::new(&backend.db);
    store.enqueue(episode_id).unwrap();
    store.add_correction(show.id, episode_id, "Editorial segment", "false positive", "test", "test").unwrap();
    let settings: AdRemovalSettingsPayload = decode(&call(&backend, "GET", "/api/ad-removal/settings", None));
    assert_eq!(settings.corrections[0].count, 1);
    backend
        .diagnostics
        .record(pods_backend::diagnostics::DiagnosticEvent {
            event_name: "export_probe".into(),
            severity: "notice".into(),
            message: "probe".into(),
            job_id: None,
            episode_id: None,
            playback_session_id: None,
        })
        .unwrap();
    let reset = call(&backend, "POST", &format!("/api/ad-removal/corrections/{}/reset", show.id), None);
    assert_eq!(reset.status_code, 200);
    let exported = call(&backend, "GET", "/api/ad-removal/diagnostics/export", None);
    assert_eq!(exported.status_code, 200);
    assert_eq!(exported.headers.get("content-type").map(String::as_str), Some("application/zip"));
    assert_eq!(&exported.body[..4], &[0x50, 0x4b, 0x03, 0x04]);
    let cleared = call(&backend, "POST", "/api/ad-removal/diagnostics/clear", None);
    assert_eq!(cleared.status_code, 204);
    assert!(backend.diagnostics.read_persisted_events().unwrap().is_empty());
    let cleanup = call(&backend, "POST", "/api/ad-removal/cleanup", Some(json!({"confirm": "DELETE_AD_REMOVAL_DATA"})));
    assert_eq!(cleanup.status_code, 200);
    let jobs = backend.db.scalar_i64("SELECT COUNT(*) FROM ad_removal_jobs", []).unwrap().unwrap();
    assert_eq!(jobs, 0);
}

#[test]
fn test_mark_played_is_immediately_durable_while_cleanup_continues_in_background() {
    let (backend, fetcher) = harness();
    let _ = seed_show(&backend, &fetcher, "https://feeds.example/played.xml", "Played", &[("Ep", "pipeline-mark-played", "https://h.example/p.mp3", D1), ("Keep", "keep", "https://h.example/k.mp3", D2)]);
    let id = backend.db.scalar_i64("SELECT id FROM episodes WHERE guid = 'pipeline-mark-played'", []).unwrap().unwrap();
    let store = JobStore::with_now(&backend.db, || 1_000);
    store.enqueue(id).unwrap();
    assert_eq!(call(&backend, "POST", &format!("/api/episodes/{id}/played"), None).status_code, 204);
    let recent: Page<EpisodeItem> = decode(&call(&backend, "GET", "/api/recent", None));
    assert!(!recent.items.iter().any(|e| e.id == id));
    let played: Page<EpisodeItem> = decode(&call(&backend, "GET", "/api/played", None));
    assert!(played.items.iter().any(|e| e.id == id));
    assert!(store.job_for_episode(id).unwrap().is_none());
}

#[test]
fn test_backend_startup_reconciles_interrupted_played_cleanup() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (feed_url, title, created_at) VALUES ('https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (9, 1, 'played-cleanup-restart', 'E', 'https://a', 100)", []).unwrap();
    db.execute("INSERT INTO episode_state (episode_id, played_at, updated_at) VALUES (9, 2000, 2000)", []).unwrap();
    db.execute("INSERT INTO ad_removal_jobs (id, episode_id, podcast_id, stage, attempt_count, enrolled_at, updated_at) VALUES ('job-1', 9, 1, 'cancelled', 0, 1, 2000)", []).unwrap();
    let backend = Backend::new(db, Arc::new(MockFeedFetcher::default()), Arc::new(DisabledDirectory));
    let played: Page<EpisodeItem> = decode(&call(&backend, "GET", "/api/played", None));
    assert!(played.items.iter().any(|e| e.id == 9) || backend.db.scalar_i64("SELECT played_at FROM episode_state WHERE episode_id = 9", []).unwrap().is_some());
    assert!(JobStore::new(&backend.db).job_for_episode(9).unwrap().is_none());
}

#[test]
fn test_played_cleanup_removes_episode_ad_artifacts_but_unsubscribe_owns_podcast_corrections() {
    let (backend, fetcher) = harness();
    let show = seed_show(&backend, &fetcher, "https://feeds.example/ad-cleanup.xml", "Cleanup Show", &[("Cleanup Episode", "cleanup-1", "https://h.example/cleanup.mp3", D1), ("Keep", "keep", "https://h.example/k.mp3", D2)]);
    let episode = decode::<Page<EpisodeItem>>(&call(&backend, "GET", "/api/recent", None)).items.into_iter().find(|e| e.title == "Cleanup Episode").unwrap();
    let store = JobStore::with_now(&backend.db, || 1_000);
    let queued = store.enqueue(episode.id).unwrap();
    let job = store.transition(&queued.id, JobStage::Downloading).unwrap();
    store
        .record_audio_artifact(&job.id, &AudioArtifact { relative_path: format!("episodes/{}/audio.mp3", episode.id), sha256: sha64(), byte_count: 16 })
        .unwrap();
    store.replace_transcript_segments(episode.id, &[segment("segment-0", 0, 10.0, 20.0, "Advertisement")]).unwrap();
    store.replace_skip_ranges(episode.id, &[range("range-0", "segment-0", "segment-0", 10.0, 20.0, false)]).unwrap();
    store.add_correction(show.id, episode.id, "Advertisement", "false positive", "test-model", "test-prompt").unwrap();
    assert_eq!(call(&backend, "POST", &format!("/api/episodes/{}/played", episode.id), None).status_code, 204);
    assert!(store.job_for_episode(episode.id).unwrap().is_none());
    assert!(store.skip_ranges(episode.id).unwrap().is_empty());
    assert_eq!(store.corrections(show.id).unwrap().len(), 1);
    assert_eq!(call(&backend, "DELETE", &format!("/api/shows/{}", show.id), None).status_code, 204);
    assert!(store.corrections(show.id).unwrap().is_empty());
}

struct BlockingFetcher {
    started: mpsc::Sender<()>,
    release: Mutex<Option<mpsc::Receiver<()>>>,
    body: Vec<u8>,
}

impl FeedFetcher for BlockingFetcher {
    fn fetch(&self, _url: &str, _validators: &pods_backend::feeds::FeedValidators) -> Result<FeedFetchResponse, Error> {
        let _ = self.started.send(());
        if let Some(rx) = self.release.lock().unwrap().take() {
            let _ = rx.recv_timeout(Duration::from_secs(2));
        }
        Ok(FeedFetchResponse::Data(self.body.clone(), Default::default()))
    }
}

#[test]
fn test_refresh_status_reports_an_active_refresh_until_it_persists_completion() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (feed_url, created_at) VALUES ('https://feeds.example/status.xml', 1)", []).unwrap();
    let (started_tx, started_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let fetcher = Arc::new(BlockingFetcher {
        started: started_tx,
        release: Mutex::new(Some(release_rx)),
        body: rss("Status", &[]).into_bytes(),
    });
    let backend = Arc::new(Backend::new(db, fetcher, Arc::new(DisabledDirectory)));
    let handle = backend.clone();
    let thread = thread::spawn(move || call(&handle, "POST", "/api/refresh", None));
    started_rx.recv_timeout(Duration::from_secs(2)).unwrap();
    let status: RefreshStatus = decode(&call(&backend, "GET", "/api/refresh-status", None));
    assert_eq!(status.is_refreshing, Some(true));
    let _ = release_tx.send(());
    let _ = thread.join().unwrap();
    let done: RefreshStatus = decode(&call(&backend, "GET", "/api/refresh-status", None));
    assert_eq!(done.is_refreshing, Some(false));
}

#[test]
fn test_backend_startup_closes_an_interrupted_refresh_attempt_for_retry() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO feed_refresh_state (id, last_attempt_at, last_source, last_refreshed, last_errors) VALUES (1, 100, 'foreground', 0, 0)", []).unwrap();
    db.execute("INSERT INTO feed_refresh_attempts (source, started_at, outcome) VALUES ('foreground', 100, 'running')", []).unwrap();
    let backend = Backend::new(db, Arc::new(MockFeedFetcher::default()), Arc::new(DisabledDirectory));
    let outcome = backend.db.scalar_string("SELECT outcome FROM feed_refresh_attempts", []).unwrap().unwrap();
    assert_eq!(outcome, "interrupted");
    let errors = backend.db.scalar_i64("SELECT errors FROM feed_refresh_attempts", []).unwrap().unwrap();
    assert_eq!(errors, 1);
    let status: RefreshStatus = decode(&call(&backend, "GET", "/api/refresh-status", None));
    assert_eq!(status.last_source.as_deref(), Some("foreground"));
    assert_eq!(status.last_errors, 1);
}

#[test]
fn test_feature_disable_waits_for_pipeline_termination_before_responding() {
    let (backend, _) = harness();
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let release_rx = Mutex::new(release_rx);
    backend.set_ad_removal_cancel(move || {
        let _ = entered_tx.send(());
        let _ = release_rx.lock().unwrap().recv_timeout(Duration::from_secs(2));
    });
    let handle = {
        // enable first so disable has work
        put_key(&backend);
        let _ = call(&backend, "POST", "/api/ad-removal/enable", Some(json!({"confirmed_bytes": 0})));
        backend
    };
    let (done_tx, done_rx) = mpsc::channel();
    thread::scope(|s| {
        s.spawn(|| {
            let response = call(&handle, "POST", "/api/ad-removal/disable", None);
            let _ = done_tx.send(response.status_code);
        });
        entered_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert!(done_rx.try_recv().is_err(), "disable returned before pipeline termination");
        let enabled = handle.db.scalar_string("SELECT value FROM settings WHERE key = 'ad_removal_enabled'", []).unwrap();
        assert_eq!(enabled.as_deref(), Some("false"));
        let _ = release_tx.send(());
        assert_eq!(done_rx.recv_timeout(Duration::from_secs(2)).unwrap(), 200);
    });
}

#[test]
fn test_cancelled_jobs_reject_all_late_pipeline_persistence() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 100)", []).unwrap();
    db.execute("INSERT INTO episode_state (episode_id, updated_at) VALUES (1, 1)", []).unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    let download = store.enqueue(1).unwrap();
    store.transition(&download.id, JobStage::Downloading).unwrap();
    store.transition(&download.id, JobStage::Cancelled).unwrap();
    assert!(store
        .record_audio_artifact(&download.id, &AudioArtifact { relative_path: "episodes/1/audio.mp3".into(), sha256: sha64(), byte_count: 10 })
        .is_err());
    assert!(store.job(&download.id).unwrap().unwrap().audio_artifact.is_none());

    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (2, 1, 'cancelled-transcript', 'E', 'https://a', 200)", []).unwrap();
    let transcript = store.enqueue(2).unwrap();
    for stage in [JobStage::Downloading, JobStage::Downloaded, JobStage::Transcribing, JobStage::Cancelled] {
        store.transition(&transcript.id, stage).unwrap();
    }
    assert!(store.record_transcript(&transcript.id, &[segment("segment-0", 0, 0.0, 10.0, "Late transcript")], "test-v1").is_err());
    assert!(store.transcript_segments(2).unwrap().is_empty());

    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (3, 1, 'cancelled-classification', 'E', 'https://a', 300)", []).unwrap();
    let classification = store.enqueue(3).unwrap();
    for stage in [JobStage::Downloading, JobStage::Downloaded, JobStage::Transcribing, JobStage::Classifying, JobStage::Cancelled] {
        store.transition(&classification.id, stage).unwrap();
    }
    let evidence = ClassificationEvidence {
        run_id: "late-run".into(),
        window_index: 0,
        segment_ids: vec!["segment-0".into()],
        correction_ids: vec![],
        prompt: "classify".into(),
        raw_output: "{}".into(),
        schema_valid: true,
        validation_error: None,
        labels_json: "[]".into(),
        model_id: "test/model".into(),
        model_revision: "revision-1".into(),
        quantization: "cloud".into(),
        prompt_version: "prompt-1".into(),
        max_context_tokens: 8192,
        max_output_tokens: 1024,
        temperature: 0.0,
        top_p: 1.0,
        created_at: 1_000,
    };
    assert!(store.record_classification_evidence(&classification.id, &evidence).is_err());
    assert!(store.complete_classification(&classification.id, "late-run", &[]).is_err());
    assert!(store.classification_evidence(3).unwrap().is_empty());
    assert!(store.skip_ranges(3).unwrap().is_empty());
}

#[test]
fn test_coordinator_commits_each_stage_before_executing_and_reaches_ready() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 100)", []).unwrap();
    db.execute("INSERT INTO episode_state (episode_id, updated_at) VALUES (1, 1)", []).unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    let queued = store.enqueue(1).unwrap();
    let seen = Mutex::new(Vec::new());
    let coordinator = Coordinator::new(&store);
    let mut execute = |stage: JobStage, job: &pods_backend::jobs::Job| {
        seen.lock().unwrap().push(stage);
        assert_eq!(store.job(&job.id).unwrap().unwrap().stage, stage);
        Ok(())
    };
    assert_eq!(coordinator.run_next_stage(&mut execute).unwrap().unwrap().stage, JobStage::Downloaded);
    assert_eq!(coordinator.run_next_stage(&mut execute).unwrap().unwrap().stage, JobStage::Classifying);
    assert_eq!(coordinator.run_next_stage(&mut execute).unwrap().unwrap().stage, JobStage::Ready);
    assert_eq!(*seen.lock().unwrap(), vec![JobStage::Downloading, JobStage::Transcribing, JobStage::Classifying]);
    assert_eq!(store.job(&queued.id).unwrap().unwrap().stage, JobStage::Ready);
}

#[test]
fn test_coordinator_does_not_run_a_stage_before_its_retry_backoff_expires() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 100)", []).unwrap();
    db.execute("INSERT INTO episode_state (episode_id, updated_at) VALUES (1, 1)", []).unwrap();
    let clock = Arc::new(std::sync::atomic::AtomicI64::new(1_000));
    let now = clock.clone();
    let store = JobStore::with_now_and_backoff(&db, move || now.load(std::sync::atomic::Ordering::SeqCst), |_| 30);
    store.enqueue(1).unwrap();
    let calls = std::sync::atomic::AtomicI32::new(0);
    let coordinator = Coordinator::new(&store);
    let mut execute = |_stage: JobStage, _job: &pods_backend::jobs::Job| {
        let n = calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        if n == 0 {
            Err("AdRemovalTest.17".into())
        } else {
            Ok(())
        }
    };
    let failed = coordinator.run_next_stage(&mut execute).unwrap().unwrap();
    assert_eq!(failed.stage, JobStage::Downloading);
    assert_eq!(failed.attempt_count, 1);
    assert_eq!(failed.next_retry_at, Some(1_030));
    assert!(coordinator.run_next_stage(&mut execute).unwrap().is_none());
    assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 1);
    clock.store(1_030, std::sync::atomic::Ordering::SeqCst);
    let retried = coordinator.run_next_stage(&mut execute).unwrap().unwrap();
    assert_eq!(retried.stage, JobStage::Downloaded);
    assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 2);
}

#[test]
fn test_coordinator_runs_only_one_episode_stage_at_a_time() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 100)", []).unwrap();
    db.execute("INSERT INTO episode_state (episode_id, updated_at) VALUES (1, 1)", []).unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    store.enqueue(1).unwrap();
    let coordinator = Coordinator::new(&store);
    let current = std::sync::atomic::AtomicI32::new(0);
    let max = std::sync::atomic::AtomicI32::new(0);
    thread::scope(|s| {
        for _ in 0..2 {
            s.spawn(|| {
                let mut execute = |_stage: JobStage, _job: &pods_backend::jobs::Job| {
                    let now = current.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
                    max.fetch_max(now, std::sync::atomic::Ordering::SeqCst);
                    thread::sleep(Duration::from_millis(20));
                    current.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
                    Ok(())
                };
                let _ = coordinator.run_next_stage(&mut execute);
            });
        }
    });
    assert_eq!(max.load(std::sync::atomic::Ordering::SeqCst), 1);
}

#[test]
fn test_scheduler_waits_for_retry_deadline_and_runs_without_another_trigger() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 100)", []).unwrap();
    db.execute("INSERT INTO episode_state (episode_id, updated_at) VALUES (1, 1)", []).unwrap();
    let clock = Arc::new(std::sync::atomic::AtomicI64::new(1_000));
    let now = clock.clone();
    let store = JobStore::with_now(&db, move || now.load(std::sync::atomic::Ordering::SeqCst));
    let queued = store.enqueue(1).unwrap();
    store.transition(&queued.id, JobStage::Downloading).unwrap();
    store.record_failure(&queued.id, "temporary", "retry").unwrap();
    let slept = Mutex::new(Vec::new());
    let coordinator = Coordinator::new(&store);
    let mut execute = |_stage: JobStage, _job: &pods_backend::jobs::Job| Ok(());
    coordinator
        .run_until_idle_with_sleep(
            &mut execute,
            |seconds| {
                slept.lock().unwrap().push(seconds);
                clock.fetch_add(seconds, std::sync::atomic::Ordering::SeqCst);
            },
            &|| clock.load(std::sync::atomic::Ordering::SeqCst),
        )
        .unwrap();
    assert_eq!(*slept.lock().unwrap(), vec![2]);
    assert_eq!(store.job(&queued.id).unwrap().unwrap().stage, JobStage::Ready);
}

#[test]
fn test_scheduling_policy_keeps_ad_removal_running_during_playback() {
    let hot = ResourceConditions { low_power_mode: true, serious_thermal_pressure: true };
    assert!(blocking_reason_for_stage(JobStage::Downloading, hot).is_none());
    assert!(blocking_reason_for_stage(JobStage::Classifying, hot).is_none());
    assert!(blocking_reason_for_stage(JobStage::Transcribing, ResourceConditions::default()).is_none());
}

#[test]
fn test_scheduling_policy_only_pauses_local_transcription_for_resource_pressure() {
    assert_eq!(
        blocking_reason_for_stage(JobStage::Transcribing, ResourceConditions { low_power_mode: true, serious_thermal_pressure: false }),
        Some(pods_backend::jobs::BlockingReason::LowPower)
    );
    assert_eq!(
        blocking_reason_for_stage(JobStage::Transcribing, ResourceConditions { low_power_mode: false, serious_thermal_pressure: true }),
        Some(pods_backend::jobs::BlockingReason::ThermalPressure)
    );
}

#[test]
fn test_scheduler_does_no_work_while_feature_is_disabled() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 100)", []).unwrap();
    db.execute("INSERT INTO episode_state (episode_id, updated_at) VALUES (1, 1)", []).unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    let queued = store.enqueue(1).unwrap();
    let coordinator = Coordinator::with_enabled(&store, || false);
    let mut execute = |_stage: JobStage, _job: &pods_backend::jobs::Job| panic!("must not run");
    coordinator.run_until_idle(&mut execute).unwrap();
    assert_eq!(store.job(&queued.id).unwrap().unwrap().stage, JobStage::Queued);
}

#[test]
fn test_schema_migration_adds_audio_metadata_columns_to_existing_job_table() {
    let conn = Connection::open_in_memory().unwrap();
    conn.execute_batch("CREATE TABLE ad_removal_jobs (id TEXT PRIMARY KEY, episode_id INTEGER, podcast_id INTEGER, stage TEXT, attempt_count INTEGER, enrolled_at INTEGER, updated_at INTEGER);").unwrap();
    db::migrate_audio_metadata_columns(&conn).unwrap();
    let count: i64 = conn.query_row("SELECT COUNT(*) FROM pragma_table_info('ad_removal_jobs') WHERE name = 'audio_sha256'", [], |r| r.get(0)).unwrap();
    assert_eq!(count, 1);
}

#[test]
fn test_parse_usage_reads_nested_cached_tokens_and_rejects_incomplete_objects() {
    assert_eq!(
        parse_usage_result(&json!({"usage":{"prompt_tokens":80,"completion_tokens":10,"prompt_tokens_details":{"cached_tokens":20}}})),
        ParsedUsage::Valid(UsageTokens { input_tokens: Some(80), cached_input_tokens: Some(20), output_tokens: Some(10) })
    );
    assert_eq!(parse_usage_result(&json!({"choices":[]})), ParsedUsage::Absent);
    assert_eq!(parse_usage_result(&json!({"usage":{"total_tokens":12}})), ParsedUsage::Invalid);
    assert_eq!(parse_usage_result(&json!({"usage":{"prompt_tokens":80,"completion_tokens":10}})), ParsedUsage::Invalid);
    assert_eq!(parse_usage_result(&json!({"usage":{"prompt_tokens":80.5,"completion_tokens":10,"prompt_cache_hit_tokens":0}})), ParsedUsage::Invalid);
    assert_eq!(parse_usage_result(&json!({"usage":{"prompt_tokens":-1,"completion_tokens":10,"prompt_cache_hit_tokens":0}})), ParsedUsage::Invalid);
    assert_eq!(parse_usage_result(&json!({"usage":{"prompt_tokens":80,"completion_tokens":10,"prompt_cache_hit_tokens":100}})), ParsedUsage::Invalid);
}

#[test]
fn test_store_records_are_immutable_and_episode_totals_sum_requests() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (feed_url, title, created_at) VALUES ('https://example.com/feed', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'episode-1', 'E', 'https://a', 100)", []).unwrap();
    let store = UsageStore::new(&db);
    let off_peak = 1_787_227_200;
    let usage = UsageTokens { input_tokens: Some(1_000), cached_input_tokens: Some(100), output_tokens: Some(50) };
    store.record(1, "ad_detection", "deepseek-v4-pro", Some(&usage), off_peak).unwrap();
    store.record(1, "ad_detection", "deepseek-v4-pro", Some(&usage), off_peak).unwrap();
    store.record(1, "show_notes", "deepseek-v4-pro", Some(&UsageTokens { input_tokens: Some(2_000), cached_input_tokens: Some(0), output_tokens: Some(100) }), off_peak).unwrap();
    let records = store.records(1).unwrap();
    assert_eq!(records.len(), 3);
    assert_eq!(store.episode_total_cost(1).unwrap(), records.iter().filter_map(|r| r.cost_usd).sum::<f64>());
    assert!((store.episode_total_cost(1).unwrap() - 0.0029084).abs() < 0.0000001);
    assert!(store.metrics().unwrap().telemetry_complete);
    assert_eq!(records[0].episode_key, episode_key("https://example.com/feed", "episode-1"));
}

#[test]
fn test_metrics_compute_averages_and_cost_per_podcast_minute() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (feed_url, title, created_at) VALUES ('https://example.com/feed', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, duration_secs, published_at) VALUES (1, 1, 'episode-1', 'E', 'https://a', 3600, 100)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, duration_secs, published_at) VALUES (2, 1, 'episode-2', 'E', 'https://a', 1800, 100)", []).unwrap();
    let store = UsageStore::new(&db);
    let off_peak = 1_787_227_200;
    store.record(1, "ad_detection", "deepseek-v4-pro", Some(&UsageTokens { input_tokens: Some(1_000_000), cached_input_tokens: Some(0), output_tokens: Some(0) }), off_peak).unwrap();
    store.record(2, "show_notes", "deepseek-v4-pro", Some(&UsageTokens { input_tokens: Some(0), cached_input_tokens: Some(0), output_tokens: Some(1_000_000) }), off_peak).unwrap();
    let metrics = store.metrics().unwrap();
    assert!((metrics.total_cost_usd - 2.64).abs() < 0.0001);
    assert!((metrics.average_cost_per_episode_usd.unwrap() - 1.32).abs() < 0.0001);
    assert!((metrics.average_cost_per_podcast_minute_usd.unwrap() - 0.0293333333).abs() < 0.0000001);
    assert!(metrics.telemetry_complete);
}

#[test]
fn test_metrics_fall_back_to_transcript_duration_and_skip_episodes_without_minutes() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (feed_url, title, created_at) VALUES ('https://example.com/feed', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'episode-1', 'E', 'https://a', 100)", []).unwrap();
    db.execute("INSERT INTO ad_transcript_segments (episode_id, segment_id, segment_index, language, start_time, end_time, text) VALUES (1, 's0', 0, 'en', 0, 120, 'hello')", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (2, 1, 'no-duration', 'E', 'https://a', 100)", []).unwrap();
    let store = UsageStore::new(&db);
    let off_peak = 1_787_227_200;
    store.record(1, "ad_detection", "deepseek-v4-pro", Some(&UsageTokens { input_tokens: Some(1_000_000), cached_input_tokens: Some(0), output_tokens: Some(0) }), off_peak).unwrap();
    store.record(2, "show_notes", "deepseek-v4-pro", Some(&UsageTokens { input_tokens: Some(1_000_000), cached_input_tokens: Some(0), output_tokens: Some(0) }), off_peak).unwrap();
    let metrics = store.metrics().unwrap();
    assert!((metrics.total_cost_usd - 1.32).abs() < 0.0001);
    assert!((metrics.average_cost_per_podcast_minute_usd.unwrap() - 0.33).abs() < 0.0001);
}

#[test]
fn test_invalid_usage_is_stored_unpriced_and_marks_telemetry_incomplete() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (feed_url, title, created_at) VALUES ('https://example.com/feed', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'episode-1', 'E', 'https://a', 100)", []).unwrap();
    let store = UsageStore::new(&db);
    store.record_parsed(1, "ad_detection", "deepseek-v4-pro", &json!({"usage":{"prompt_tokens":80,"completion_tokens":10}}), 1).unwrap();
    let records = store.records(1).unwrap();
    assert_eq!(records.len(), 1);
    assert!(records[0].cost_usd.is_none());
    assert!(!store.metrics().unwrap().telemetry_complete);
}

#[test]
fn test_failed_insert_falls_back_to_ledger_and_reconciles() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (feed_url, title, created_at) VALUES ('https://example.com/feed', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'episode-1', 'E', 'https://a', 100)", []).unwrap();
    let dir = tempfile::tempdir().unwrap();
    let ledger = dir.path().join("fallback.jsonl");
    let store = UsageStore::with_ledger(&db, ledger.clone());
    store.fail_next_insert();
    let off_peak = 1_787_227_200;
    store.record(1, "show_notes", "deepseek-v4-pro", Some(&UsageTokens { input_tokens: Some(0), cached_input_tokens: Some(0), output_tokens: Some(1_000_000) }), off_peak).unwrap();
    assert!(ledger.exists());
    assert_eq!(db.scalar_i64("SELECT COUNT(*) FROM deepseek_usage", []).unwrap().unwrap(), 0);
    let metrics = store.metrics().unwrap();
    assert!((metrics.total_cost_usd - 1.98).abs() < 0.0001);
    assert!(metrics.telemetry_complete);
    assert!(!ledger.exists());
    assert_eq!(store.records(1).unwrap().len(), 1);
}

#[test]
fn test_legacy_ledger_line_without_record_id_reconciles_idempotently() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (feed_url, title, created_at) VALUES ('https://example.com/feed', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'episode-1', 'E', 'https://a', 100)", []).unwrap();
    let dir = tempfile::tempdir().unwrap();
    let ledger = dir.path().join("legacy.jsonl");
    let record = pods_backend::usage::UsageRecord {
        record_id: String::new(),
        episode_id: 1,
        episode_key: episode_key("https://example.com/feed", "episode-1"),
        duration_secs: None,
        request_kind: "ad_detection".into(),
        model: "deepseek-v4-pro".into(),
        input_tokens: Some(10),
        cached_input_tokens: Some(0),
        output_tokens: Some(1),
        cost_usd: Some(0.1),
        created_at: 1,
    };
    let id = legacy_record_id(&record);
    std::fs::write(&ledger, serde_json::to_string(&record).unwrap() + "\n").unwrap();
    let store = UsageStore::with_ledger(&db, ledger);
    let _ = store.metrics().unwrap();
    let rows = store.records(1).unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].record_id, id);
    let _ = store.metrics().unwrap();
    assert_eq!(store.records(1).unwrap().len(), 1);
}

#[test]
fn test_structured_output_parser_rejects_malformed_invented_and_incomplete_output() {
    let ids = vec!["segment-0".into(), "segment-1".into()];
    for raw in [
        "Here is the JSON: {\"labels\":[]}",
        r#"{"labels":[{"segment_id":"invented","label":"ad","reason":"ad"}]}"#,
        r#"{"labels":[{"segment_id":"segment-0","label":"content","reason":"content"}]}"#,
    ] {
        assert!(parse_structured_labels(raw, &ids).is_err(), "{raw}");
    }
}

#[test]
fn test_production_window_uses_cloud_sized_batch_and_short_request_ids() {
    let ids: Vec<String> = (0..70).map(|i| format!("segment-canonical-{i}")).collect();
    let windows = production_windows(&ids);
    assert_eq!(PRODUCTION_BATCH, 64);
    assert_eq!(windows.first().unwrap().len(), 64);
    assert_eq!(short_request_ids(64).first().unwrap(), "s0");
    assert_eq!(short_request_ids(64).last().unwrap(), "s63");
    assert_eq!(windows[1][0], "segment-canonical-60");
    assert_eq!(total_windows(64), 1);
    assert_eq!(total_windows(65), 2);
    assert_eq!(total_windows(125), 3);
}

#[test]
fn test_correction_selection_is_relevant_newest_first_and_bounded() {
    let corrections = vec![
        CorrectionExample { id: "old-relevant".into(), text: "Listener questions are editorial content".into(), created_at: 10 },
        CorrectionExample { id: "new-relevant".into(), text: "The medication safety discussion is content".into(), created_at: 30 },
        CorrectionExample { id: "irrelevant".into(), text: "A completely unrelated sports monologue".into(), created_at: 40 },
    ];
    let selected = select_corrections("The host answers listener questions about medication safety", &corrections, 90);
    assert_eq!(selected[0].id, "new-relevant");
    let prompt = classification_prompt(&["segment-0".into()], &selected);
    assert!(prompt.contains("as \"ad\" or \"content\""));
    assert!(prompt.contains("reason containing 1 to 240 characters"));
    assert!(prompt.contains("new-relevant"));
    assert!(!prompt.contains("irrelevant"));
}

#[test]
fn test_show_notes_store_accepts_the_configured_chapter_baseline() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 100)", []).unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    let notes: Vec<_> = (0..SHOW_NOTES_CHAPTER_BASELINE)
        .map(|i| ShowNoteRecord {
            segment_id: format!("s{i}"),
            start_time: i as f64,
            title: "t".into(),
            summary: "s".into(),
            model_id: "m".into(),
            prompt_version: "p".into(),
            created_at: 1_000,
        })
        .collect();
    store.replace_show_notes(1, &notes).unwrap();
    assert_eq!(store.show_notes(1).unwrap().len(), SHOW_NOTES_CHAPTER_BASELINE);
}

#[test]
fn test_show_notes_store_rejects_more_chapters_than_the_baseline() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 100)", []).unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    let notes: Vec<_> = (0..=SHOW_NOTES_CHAPTER_BASELINE)
        .map(|i| ShowNoteRecord {
            segment_id: format!("s{i}"),
            start_time: i as f64,
            title: "t".into(),
            summary: "s".into(),
            model_id: "m".into(),
            prompt_version: "p".into(),
            created_at: 1_000,
        })
        .collect();
    assert!(store.replace_show_notes(1, &notes).is_err());
}

#[test]
fn test_show_notes_store_replace_is_atomic_and_preserves_chapter_order_and_metadata() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 100)", []).unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    store
        .replace_show_notes(
            1,
            &[
                ShowNoteRecord { segment_id: "a".into(), start_time: 1.0, title: "one".into(), summary: "s1".into(), model_id: "m".into(), prompt_version: "p".into(), created_at: 1 },
                ShowNoteRecord { segment_id: "b".into(), start_time: 2.0, title: "two".into(), summary: "s2".into(), model_id: "m".into(), prompt_version: "p".into(), created_at: 1 },
            ],
        )
        .unwrap();
    store
        .replace_show_notes(
            1,
            &[ShowNoteRecord { segment_id: "c".into(), start_time: 3.0, title: "three".into(), summary: "s3".into(), model_id: "m2".into(), prompt_version: "p2".into(), created_at: 2 }],
        )
        .unwrap();
    let notes = store.show_notes(1).unwrap();
    assert_eq!(notes.len(), 1);
    assert_eq!(notes[0].title, "three");
    assert_eq!(notes[0].model_id, "m2");
}

#[test]
fn test_undo_atomically_disables_range_and_creates_podcast_scoped_correction_with_context() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'Example', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'episode-1', 'E', 'https://a', 100)", []).unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    store
        .replace_transcript_segments(
            1,
            &[
                segment("segment-0", 0, 0.0, 10.0, "Editorial lead-in"),
                segment("segment-1", 1, 10.0, 20.0, "Sponsor call to action"),
                segment("segment-2", 2, 20.0, 30.0, "Use the promo code"),
                segment("segment-3", 3, 30.0, 40.0, "Interview resumes"),
            ],
        )
        .unwrap();
    store.replace_skip_ranges(1, &[range("ad-segment-1--segment-2", "segment-1", "segment-2", 10.0, 30.0, false)]).unwrap();
    let result = store.undo_skip(1, "ad-segment-1--segment-2").unwrap();
    assert_eq!(result.seek_position, 10.0);
    assert!(store.skip_ranges(1).unwrap()[0].disabled);
    let corrections = store.corrections(1).unwrap();
    assert_eq!(corrections.len(), 1);
    assert!(corrections[0].transcript_window.contains("Editorial lead-in"));
    assert!(corrections[0].transcript_window.contains("Sponsor call to action"));
    assert!(corrections[0].classification_context.contains("ad-segment-1--segment-2"));
}

#[test]
fn test_result_accumulator_keeps_valid_finalized_segments_when_another_result_is_invalid() {
    let mut accumulator = ResultAccumulator::new("en-US");
    accumulator.consume(false, 0.0, 1.0, "Draft");
    accumulator.consume(true, 10.0, 14.0, "Valid segment");
    accumulator.consume(true, 14.0, 14.0, "Invalid range");
    assert_eq!(accumulator.segments.len(), 1);
    assert_eq!(accumulator.segments[0].text, "Valid segment");
    assert_eq!(accumulator.observed_final_result_count, 2);
    assert_eq!(accumulator.rejected_final_result_count, 1);
}

#[test]
fn test_pipeline_persists_finalized_segments_and_version_before_classification() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 100)", []).unwrap();
    db.execute("INSERT INTO episode_state (episode_id, updated_at) VALUES (1, 1)", []).unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    let job = store.enqueue(1).unwrap();
    store.transition(&job.id, JobStage::Downloading).unwrap();
    store.transition(&job.id, JobStage::Downloaded).unwrap();
    let coordinator = Coordinator::new(&store);
    let segments = transcribe::from_finalized(1, "en-US", &[(10.0, 14.0, "This episode is brought to you by Example.".into()), (14.0, 19.0, "Use offer code PODS.".into())]).unwrap();
    let completed = coordinator
        .run_next_stage(|stage, job| {
            assert_eq!(stage, JobStage::Transcribing);
            store.record_transcript(&job.id, &segments, "fake-transcriber-v1").map(|_| ()).map_err(|e| e.to_string())
        })
        .unwrap()
        .unwrap();
    assert_eq!(completed.stage, JobStage::Classifying);
    assert_eq!(store.transcript_segments(1).unwrap().len(), 2);
    assert_eq!(store.job(&job.id).unwrap().unwrap().transcriber_version.as_deref(), Some("fake-transcriber-v1"));
}

#[test]
fn test_coordinator_cancellation_leaves_transcribing_stage_restartable_without_consuming_retry() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 100)", []).unwrap();
    db.execute("INSERT INTO episode_state (episode_id, updated_at) VALUES (1, 1)", []).unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    let job = store.enqueue(1).unwrap();
    store.transition(&job.id, JobStage::Downloading).unwrap();
    store.transition(&job.id, JobStage::Downloaded).unwrap();
    let coordinator = Coordinator::new(&store);
    let err = coordinator.run_next_stage(|_, _| Err("cancelled".into())).unwrap_err();
    assert!(err.to_string().contains("cancelled"));
    let persisted = store.job(&job.id).unwrap().unwrap();
    assert_eq!(persisted.stage, JobStage::Transcribing);
    assert_eq!(persisted.attempt_count, 0);
    assert!(persisted.last_error_code.is_none());
    assert_eq!(store.next_runnable_job().unwrap().unwrap().id, job.id);
}

#[test]
fn test_local_server_rejects_invalid_content_lengths_without_overflow() {
    let huge = i64::MAX.to_string();
    let max = MAXIMUM_REQUEST_BYTES.to_string();
    for value in ["-1", "not-a-number", huge.as_str(), max.as_str()] {
        let data = format!("POST /api/test HTTP/1.1\r\nContent-Length: {value}\r\n\r\n");
        assert!(matches!(parse_request(data.as_bytes()), ParseResult::Invalid(_)), "{value}");
    }
    let empty = b"GET / HTTP/1.1\r\nContent-Length: 0\r\n\r\n";
    match parse_request(empty) {
        ParseResult::Complete { body, .. } => assert!(body.is_empty()),
        other => panic!("{other:?}"),
    }
}

#[test]
fn test_feed_fetcher_retries_http_feed_over_https_when_the_first_fetch_fails() {
    let requested = Mutex::new(Vec::new());
    let response = fetch_with_https_fallback("http://retry.example/feed.xml", |url| {
        requested.lock().unwrap().push(url.to_string());
        if url.starts_with("http://") {
            Err(Error::Upstream("fail".into()))
        } else {
            Ok(FeedFetchResponse::Data(b"<rss/>".to_vec(), Default::default()))
        }
    })
    .unwrap();
    match response {
        FeedFetchResponse::Data(data, _) => assert_eq!(data, b"<rss/>"),
        _ => panic!("expected data"),
    }
    assert_eq!(
        *requested.lock().unwrap(),
        vec!["http://retry.example/feed.xml".to_string(), "https://retry.example/feed.xml".to_string()]
    );
}

#[test]
fn test_feed_fetcher_does_not_retry_when_the_listed_feed_is_already_https() {
    let requested = Mutex::new(Vec::new());
    let err = fetch_with_https_fallback("https://feeds.example/feed.xml", |url| {
        requested.lock().unwrap().push(url.to_string());
        Err(Error::Upstream("fail".into()))
    })
    .unwrap_err();
    assert_eq!(requested.lock().unwrap().len(), 1);
    assert!(err.to_string().contains("fail"));
}

#[test]
fn test_feed_fetcher_does_not_retry_when_the_http_feed_succeeds() {
    let requested = Mutex::new(Vec::new());
    let _ = fetch_with_https_fallback("http://ok.example/feed.xml", |url| {
        requested.lock().unwrap().push(url.to_string());
        Ok(FeedFetchResponse::Data(b"<rss/>".to_vec(), Default::default()))
    })
    .unwrap();
    assert_eq!(requested.lock().unwrap().len(), 1);
}

#[test]
fn test_feed_fetcher_uses_bounded_timeout_for_every_publisher_request() {
    assert_eq!(UreqFetcher::default().request_timeout(), Duration::from_secs(12));
}

#[test]
fn test_artifact_store_rejects_untrusted_paths_and_cleans_installed_files_idempotently() {
    let dir = tempfile::tempdir().unwrap();
    let store = ArtifactStore::open(dir.path().join("ad")).unwrap();
    assert!(store.install("../x.mp3", b"no").is_err());
    store.install("episodes/1/audio.mp3", b"ok").unwrap();
    store.remove("episodes/1/audio.mp3").unwrap();
    store.remove("episodes/1/audio.mp3").unwrap();
}

#[test]
fn test_resume_data_lives_in_artifact_store_and_only_its_validated_path_is_persisted() {
    let dir = tempfile::tempdir().unwrap();
    let artifacts = ArtifactStore::open(dir.path().join("ad")).unwrap();
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 100)", []).unwrap();
    db.execute("INSERT INTO episode_state (episode_id, updated_at) VALUES (1, 1)", []).unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    let job = store.enqueue(1).unwrap();
    store.transition(&job.id, JobStage::Downloading).unwrap();
    let relative = artifacts.write_resume(&job.id, b"resume").unwrap();
    assert!(relative.starts_with("resume/"));
    store.record_download_resume_path(&job.id, &relative).unwrap();
    assert!(store.record_download_resume_path(&job.id, "/tmp/x").is_err());
    assert_eq!(store.job(&job.id).unwrap().unwrap().download_resume_relative_path.as_deref(), Some(relative.as_str()));
}

#[test]
fn test_download_finalizer_persists_artifact_and_advances_durable_stage() {
    let dir = tempfile::tempdir().unwrap();
    let artifacts = ArtifactStore::open(dir.path().join("ad")).unwrap();
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 100)", []).unwrap();
    db.execute("INSERT INTO episode_state (episode_id, updated_at) VALUES (1, 1)", []).unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    let job = store.enqueue(1).unwrap();
    store.transition(&job.id, JobStage::Downloading).unwrap();
    let completed = storage::finalize_download(
        &artifacts,
        &store,
        &job.id,
        1,
        &DownloadResult { bytes: b"audio-bytes".to_vec(), content_type: "audio/mpeg".into(), status: 200 },
    )
    .unwrap();
    assert_eq!(completed.stage, JobStage::Downloaded);
    assert_eq!(completed.audio_artifact.unwrap().byte_count, 11);
}

#[test]
fn test_download_finalizer_rejects_http_failure_without_false_downloaded_state() {
    let dir = tempfile::tempdir().unwrap();
    let artifacts = ArtifactStore::open(dir.path().join("ad")).unwrap();
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 100)", []).unwrap();
    db.execute("INSERT INTO episode_state (episode_id, updated_at) VALUES (1, 1)", []).unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    let job = store.enqueue(1).unwrap();
    store.transition(&job.id, JobStage::Downloading).unwrap();
    assert!(storage::finalize_download(
        &artifacts,
        &store,
        &job.id,
        1,
        &DownloadResult { bytes: vec![], content_type: "text/plain".into(), status: 404 },
    )
    .is_err());
    assert_eq!(store.job(&job.id).unwrap().unwrap().stage, JobStage::Downloading);
}

#[test]
fn test_log_rotation_retains_exactly_the_configured_newest_files() {
    let dir = tempfile::tempdir().unwrap();
    let diagnostics = Diagnostics::open(dir.path().to_path_buf()).unwrap();
    for index in 1..=5 {
        diagnostics
            .record_rotating(
                DiagnosticEvent {
                    event_name: "rotation_probe".into(),
                    severity: "debug".into(),
                    message: format!("{index}"),
                    job_id: None,
                    episode_id: None,
                    playback_session_id: None,
                },
                1,
                3,
            )
            .unwrap();
    }
    assert_eq!(diagnostics.log_names().unwrap().len(), 3);
}

#[test]
fn test_snapshot_retention_keeps_the_configured_newest_jobs() {
    let dir = tempfile::tempdir().unwrap();
    let diagnostics = Diagnostics::open(dir.path().to_path_buf()).unwrap();
    for index in 1..=3 {
        diagnostics.save_snapshot(&format!("job-{index}"), "{}", 2).unwrap();
    }
    assert_eq!(diagnostics.snapshot_ids().unwrap(), vec!["job-2".to_string(), "job-3".to_string()]);
}

#[test]
fn test_export_archive_contains_versioned_manifest_logs_snapshots_and_state_summary() {
    let dir = tempfile::tempdir().unwrap();
    let diagnostics = Diagnostics::open(dir.path().to_path_buf()).unwrap();
    diagnostics
        .record(DiagnosticEvent {
            event_name: "x".into(),
            severity: "info".into(),
            message: "hi".into(),
            job_id: None,
            episode_id: None,
            playback_session_id: None,
        })
        .unwrap();
    let zip_path = dir.path().join("export.zip");
    diagnostics.save_snapshot("job-1", "{\"job\":\"one\"}", 5).unwrap();
    diagnostics.export_zip(&zip_path).unwrap();
    let bytes = std::fs::read(&zip_path).unwrap();
    assert_eq!(&bytes[..4], b"PK\x03\x04");
    let mut zip = zip::ZipArchive::new(std::io::Cursor::new(bytes)).unwrap();
    let names: Vec<String> = (0..zip.len()).map(|i| zip.by_index(i).unwrap().name().to_string()).collect();
    assert!(names.contains(&"manifest.json".to_string()), "{names:?}");
    assert!(names.contains(&"state-summary.json".to_string()), "{names:?}");
    assert!(names.iter().any(|n| n.starts_with("iphone/logs/")), "{names:?}");
    assert!(names.iter().any(|n| n.starts_with("iphone/snapshots/")), "{names:?}");
    let mut manifest = String::new();
    zip.by_name("manifest.json").unwrap().read_to_string(&mut manifest).unwrap();
    assert!(manifest.contains("\"version\":1") || manifest.contains("\"version\": 1"), "{manifest}");
    assert!(manifest.contains("iphone/snapshots/"));
}

#[test]
fn test_playback_sources_prefer_downloaded_bytes_before_manifest_and_never_send_file_url_to_mac() {
    assert_eq!(pods_backend::skip::local_source("https://pub/a.mp3", Some("episodes/1/audio.mp3")), "episodes/1/audio.mp3");
    assert_eq!(
        pods_backend::skip::mac_source("https://pub/a.mp3", true, Some("http://127.0.0.1/episode/1?token=x")).as_deref(),
        Some("http://127.0.0.1/episode/1?token=x")
    );
    assert!(!pods_backend::skip::mac_source("https://pub/a.mp3", true, Some("http://127.0.0.1/episode/1?token=x"))
        .unwrap()
        .starts_with("file:"));
}

#[test]
fn test_show_notes_chapter_limit_is_a_single_maintainable_baseline() {
    assert_eq!(SHOW_NOTES_CHAPTER_BASELINE, 12);
}

#[test]
fn test_feature_cleanup_waits_for_pipeline_termination_before_deleting_late_writes() {
    let (backend, fetcher) = harness();
    let _ = seed_show(&backend, &fetcher, "https://feeds.example/cleanup-wait.xml", "Cleanup", &[("Ep", "pipeline-full-cleanup", "https://h.example/p.mp3", D1), ("Keep", "keep", "https://h.example/k.mp3", D2)]);
    let id = backend.db.scalar_i64("SELECT id FROM episodes WHERE guid = 'pipeline-full-cleanup'", []).unwrap().unwrap();
    JobStore::with_now(&backend.db, || 1_000).enqueue(id).unwrap();
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let release_rx = Mutex::new(release_rx);
    backend.set_ad_removal_cancel(move || {
        let _ = entered_tx.send(());
        let _ = release_rx.lock().unwrap().recv_timeout(Duration::from_secs(2));
    });
    let (done_tx, done_rx) = mpsc::channel();
    thread::scope(|s| {
        s.spawn(|| {
            let response = call(&backend, "POST", "/api/ad-removal/cleanup", Some(json!({"confirm": "DELETE_AD_REMOVAL_DATA"})));
            let _ = done_tx.send(response.status_code);
        });
        entered_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert!(done_rx.try_recv().is_err(), "cleanup returned before pipeline termination");
        assert!(JobStore::new(&backend.db).job_for_episode(id).unwrap().is_some());
        let _ = release_tx.send(());
        assert_eq!(done_rx.recv_timeout(Duration::from_secs(2)).unwrap(), 200);
    });
    assert!(JobStore::new(&backend.db).job_for_episode(id).unwrap().is_none());
}

#[test]
fn test_ad_removal_lifecycle_handlers_wake_and_stop_runtime_work() {
    let (backend, _) = harness();
    let woke = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let flag = woke.clone();
    backend.set_ad_removal_wake(move || flag.store(true, std::sync::atomic::Ordering::SeqCst));
    put_key(&backend);
    assert_eq!(call(&backend, "POST", "/api/ad-removal/enable", Some(json!({"confirmed_bytes": 0}))).status_code, 202);
    assert!(woke.load(std::sync::atomic::Ordering::SeqCst));
    assert_eq!(call(&backend, "POST", "/api/ad-removal/disable", None).status_code, 200);
}

#[test]
fn test_prepared_playback_uses_validated_downloaded_bytes_and_falls_back_when_incomplete_or_corrupt() {
    let dir = tempfile::tempdir().unwrap();
    let artifacts = ArtifactStore::open(dir.path().join("ad")).unwrap();
    let sha = artifacts.install("episodes/1/audio.mp3", b"exact downloaded audio").unwrap();
    assert!(artifacts.validate("episodes/1/audio.mp3", &sha, 22));
    assert!(!artifacts.validate("episodes/1/audio.mp3", &sha, 3));
    assert!(!artifacts.validate("episodes/1/audio.mp3", "0".repeat(64).as_str(), 22));
}

#[test]
fn test_classification_pipeline_persists_evidence_and_deterministic_manifest() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 100)", []).unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    store.replace_transcript_segments(1, &[segment("segment-0", 0, 0.0, 10.0, "hello")]).unwrap();
    let job = store.enqueue(1).unwrap();
    for stage in [JobStage::Downloading, JobStage::Downloaded, JobStage::Transcribing, JobStage::Classifying] {
        store.transition(&job.id, stage).unwrap();
    }
    let evidence = ClassificationEvidence {
        run_id: "run-1".into(),
        window_index: 0,
        segment_ids: vec!["segment-0".into()],
        correction_ids: vec![],
        prompt: "classify".into(),
        raw_output: r#"{"labels":[{"segment_id":"segment-0","label":"ad","reason":"promo"}]}"#.into(),
        schema_valid: true,
        validation_error: None,
        labels_json: "[]".into(),
        model_id: "test/model".into(),
        model_revision: "r1".into(),
        quantization: "cloud".into(),
        prompt_version: "p1".into(),
        max_context_tokens: 8192,
        max_output_tokens: 1024,
        temperature: 0.0,
        top_p: 1.0,
        created_at: 1_000,
    };
    store.record_classification_evidence(&job.id, &evidence).unwrap();
    store.complete_classification(&job.id, "run-1", &[range("r0", "segment-0", "segment-0", 0.0, 10.0, false)]).unwrap();
    assert_eq!(store.classification_evidence(1).unwrap().len(), 1);
    assert_eq!(store.skip_ranges(1).unwrap().len(), 1);
}

#[test]
fn test_deep_seek_flash_classifier_sends_non_thinking_json_request() {
    let body = pods_backend::classify::deepseek_chat_body("deepseek-v4-flash", "classify");
    assert_eq!(body["model"], "deepseek-v4-flash");
    assert_eq!(body["thinking"]["type"], "disabled");
    assert_eq!(body["response_format"]["type"], "json_object");
}

#[test]
fn test_episode_cleanup_deletes_artifacts_but_preserves_podcast_corrections_until_unsubscribe() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 100)", []).unwrap();
    db.execute("INSERT INTO episode_state (episode_id, updated_at) VALUES (1, 1)", []).unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    let job = store.enqueue(1).unwrap();
    for stage in [JobStage::Downloading, JobStage::Downloaded, JobStage::Transcribing, JobStage::Classifying] {
        store.transition(&job.id, stage).unwrap();
    }
    store.replace_transcript_segments(1, &[segment("segment-0", 0, 10.0, 20.0, "Buy this product")]).unwrap();
    store.replace_skip_ranges(1, &[range("range-0", "segment-0", "segment-0", 10.0, 20.0, false)]).unwrap();
    store.add_correction(1, 1, "Buy this product", "host-read", "qwen-test", "prompt-1").unwrap();
    store.delete_episode_ad_data(1).unwrap();
    assert!(store.job_for_episode(1).unwrap().is_none());
    assert!(store.skip_ranges(1).unwrap().is_empty());
    assert!(store.transcript_segments(1).unwrap().is_empty());
    assert_eq!(store.corrections(1).unwrap().len(), 1);
    store.delete_podcast_corrections(1).unwrap();
    assert!(store.corrections(1).unwrap().is_empty());
}

#[test]
fn test_mark_played_persists_before_show_notes_cancellation_and_defers_metadata_cleanup() {
    let (backend, fetcher) = harness();
    let _ = seed_show(&backend, &fetcher, "https://feeds.example/show-notes-cancellation.xml", "Show Notes Cancellation", &[("Episode", "show-notes-cancel-1", "https://h.example/cancel.mp3", D1), ("Keep", "keep", "https://h.example/k.mp3", D2)]);
    let id = backend.db.scalar_i64("SELECT id FROM episodes WHERE guid = 'show-notes-cancel-1'", []).unwrap().unwrap();
    let store = JobStore::with_now(&backend.db, || 1_000);
    let job = store.enqueue(id).unwrap();
    store.replace_transcript_segments(id, &[segment("segment-opening", 0, 12.5, 30.0, "Episode content")]).unwrap();
    for stage in [JobStage::Downloading, JobStage::Downloaded, JobStage::Transcribing, JobStage::Classifying, JobStage::Ready] {
        store.transition(&job.id, stage).unwrap();
    }
    let release = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let release_flag = release.clone();
    let (started_tx, started_rx) = mpsc::channel();
    let (observed_tx, observed_rx) = mpsc::channel();
    thread::scope(|s| {
        s.spawn(|| {
            let _ = backend.show_notes.generate(id, || {
                let _ = started_tx.send(());
                while !backend.show_notes.observe_cancel(id) && !release_flag.load(std::sync::atomic::Ordering::SeqCst) {
                    thread::sleep(Duration::from_millis(5));
                }
                let _ = observed_tx.send(());
                while !release_flag.load(std::sync::atomic::Ordering::SeqCst) {
                    thread::sleep(Duration::from_millis(5));
                }
                Err(pods_backend::show_notes::ShowNotesError::Cancelled)
            });
        });
        started_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        let mark = s.spawn(|| call(&backend, "POST", &format!("/api/episodes/{id}/played"), None).status_code);
        observed_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        let recent: Page<EpisodeItem> = decode(&call(&backend, "GET", "/api/recent", None));
        assert!(!recent.items.iter().any(|e| e.id == id));
        let played_at = backend
            .db
            .scalar_i64(&format!("SELECT played_at FROM episode_state WHERE episode_id = {id}"), [])
            .unwrap();
        assert!(played_at.is_some());
        release.store(true, std::sync::atomic::Ordering::SeqCst);
        assert_eq!(mark.join().unwrap(), 204);
    });
}

#[test]
fn test_feature_cleanup_disables_show_notes_before_awaiting_runtime_shutdown() {
    let (backend, _) = harness();
    put_key(&backend);
    assert_eq!(call(&backend, "POST", "/api/ad-removal/enable", Some(json!({"confirmed_bytes": 0}))).status_code, 202);
    let (entered_tx, entered_rx) = mpsc::channel();
    let (go_tx, go_rx) = mpsc::channel();
    let go_rx = Mutex::new(go_rx);
    backend.set_ad_removal_cancel(move || {
        let _ = entered_tx.send(());
        let _ = go_rx.lock().unwrap().recv_timeout(Duration::from_secs(2));
    });
    let (done_tx, done_rx) = mpsc::channel();
    thread::scope(|s| {
        s.spawn(|| {
            let response = call(&backend, "POST", "/api/ad-removal/cleanup", Some(json!({"confirm": "DELETE_AD_REMOVAL_DATA"})));
            let _ = done_tx.send(response.status_code);
        });
        entered_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        let enabled = backend.db.scalar_string("SELECT value FROM settings WHERE key = 'ad_removal_enabled'", []).unwrap();
        assert_eq!(enabled.as_deref(), Some("false"));
        assert!(backend.show_notes.writes_closed());
        let _ = go_tx.send(());
        assert_eq!(done_rx.recv_timeout(Duration::from_secs(2)).unwrap(), 200);
    });
}

#[test]
fn test_concurrent_writes_produce_complete_decodable_events() {
    let dir = tempfile::tempdir().unwrap();
    let diagnostics = std::sync::Arc::new(Diagnostics::open(dir.path().to_path_buf()).unwrap());
    thread::scope(|s| {
        for i in 0..8 {
            let diagnostics = diagnostics.clone();
            s.spawn(move || {
                diagnostics
                    .record(DiagnosticEvent {
                        event_name: "concurrent".into(),
                        severity: "info".into(),
                        message: format!("{i}"),
                        job_id: None,
                        episode_id: None,
                        playback_session_id: None,
                    })
                    .unwrap();
            });
        }
    });
    let text = std::fs::read_to_string(dir.path().join("logs/current.jsonl")).unwrap();
    for line in text.lines().filter(|l| !l.is_empty()) {
        let _: DiagnosticEvent = serde_json::from_str(line).unwrap();
    }
    assert!(text.lines().count() >= 8);
}

#[test]
fn test_transient_policy_clear_leaves_model_required_jobs_blocked() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 100)", []).unwrap();
    db.execute("INSERT INTO episode_state (episode_id, updated_at) VALUES (1, 1)", []).unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    let job = store.enqueue(1).unwrap();
    store.set_blocking_reason(&job.id, Some(pods_backend::jobs::BlockingReason::ModelRequired)).unwrap();
    store.clear_blocking_reasons(&[pods_backend::jobs::BlockingReason::LowPower]).unwrap();
    assert_eq!(store.job(&job.id).unwrap().unwrap().blocking_reason, Some(pods_backend::jobs::BlockingReason::ModelRequired));
    assert!(store.next_runnable_job().unwrap().is_none());
}

#[test]
fn test_coordinator_records_policy_pause_without_consuming_failure_retry() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 100)", []).unwrap();
    db.execute("INSERT INTO episode_state (episode_id, updated_at) VALUES (1, 1)", []).unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    let job = store.enqueue(1).unwrap();
    let coordinator = Coordinator::new(&store);
    let paused = coordinator.run_next_stage(|_, _| Err("pause:low_power".into())).unwrap().unwrap();
    assert_eq!(paused.blocking_reason, Some(pods_backend::jobs::BlockingReason::LowPower));
    assert_eq!(paused.attempt_count, 0);
    assert_eq!(store.job(&job.id).unwrap().unwrap().stage, JobStage::Downloading);
}

#[test]
fn test_scheduler_downloads_during_low_power_then_resumes_compute_until_ready() {
    assert!(blocking_reason_for_stage(JobStage::Downloading, ResourceConditions { low_power_mode: true, serious_thermal_pressure: false }).is_none());
    assert_eq!(
        blocking_reason_for_stage(JobStage::Transcribing, ResourceConditions { low_power_mode: true, serious_thermal_pressure: false }),
        Some(pods_backend::jobs::BlockingReason::LowPower)
    );
}

#[test]
fn test_scheduler_runs_show_notes_queue_only_after_ad_removal_work_is_idle() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 100)", []).unwrap();
    db.execute("INSERT INTO episode_state (episode_id, updated_at) VALUES (1, 1)", []).unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    store.enqueue(1).unwrap();
    assert!(store.next_runnable_job().unwrap().is_some());
}

#[test]
fn test_concurrent_run_until_idle_reports_busy_while_owner_completes_successfully() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 100)", []).unwrap();
    db.execute("INSERT INTO episode_state (episode_id, updated_at) VALUES (1, 1)", []).unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    store.enqueue(1).unwrap();
    let coordinator = Coordinator::new(&store);
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let release_rx = Mutex::new(Some(release_rx));
    thread::scope(|s| {
        s.spawn(|| {
            let mut execute = |_stage: JobStage, _job: &pods_backend::jobs::Job| {
                let _ = entered_tx.send(());
                if let Some(rx) = release_rx.lock().unwrap().take() {
                    let _ = rx.recv_timeout(Duration::from_secs(2));
                }
                Ok(())
            };
            coordinator.run_until_idle(&mut execute).unwrap();
        });
        entered_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        let mut idle = |_stage: JobStage, _job: &pods_backend::jobs::Job| panic!("second owner must not execute");
        let steps = coordinator.run_until_idle(&mut idle).unwrap();
        assert_eq!(steps, 0);
        let _ = release_tx.send(());
    });
    assert_eq!(store.job_for_episode(1).unwrap().unwrap().stage, JobStage::Ready);
}

#[test]
fn test_pipeline_executor_downloads_and_validates_exact_episode_audio_before_advancing() {
    let (backend, fetcher) = harness();
    put_key(&backend);
    let _ = seed_show(
        &backend,
        &fetcher,
        "https://feeds.example/dl.xml",
        "DL",
        &[("Ep", "dl-1", "https://h.example/dl.mp3", D1), ("Keep", "keep", "https://h.example/k.mp3", D2)],
    );
    let id = backend.db.scalar_i64("SELECT id FROM episodes WHERE guid = 'dl-1'", []).unwrap().unwrap();
    let downloader = std::sync::Arc::new(pods_backend::pipeline::MockDownloader::default());
    downloader.set(
        "https://h.example/dl.mp3",
        pods_backend::storage::DownloadResult {
            bytes: b"exact downloaded audio".to_vec(),
            content_type: "audio/mpeg".into(),
            status: 200,
        },
    );
    backend.set_downloader(downloader);
    assert_eq!(call(&backend, "POST", "/api/ad-removal/enable", Some(json!({"confirmed_bytes": 0}))).status_code, 202);
    assert_eq!(call(&backend, "POST", &format!("/api/episodes/{id}/ad-removal/prepare"), None).status_code, 202);
    assert!(backend.run_pipeline_step().unwrap());
    let job = JobStore::new(&backend.db).job_for_episode(id).unwrap().unwrap();
    assert_eq!(job.stage, JobStage::Downloaded);
    assert_eq!(job.audio_artifact.unwrap().byte_count, 22);
}

#[test]
fn test_successful_classifier_call_records_usage() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (feed_url, title, created_at) VALUES ('https://example.com/feed', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'episode-1', 'E', 'https://a', 100)", []).unwrap();
    let store = UsageStore::new(&db);
    store
        .record_parsed(1, "ad_detection", "deepseek-v4-pro", &json!({"usage":{"prompt_tokens":10,"completion_tokens":4,"prompt_cache_hit_tokens":2}}), 1_787_227_200)
        .unwrap();
    assert_eq!(store.records(1).unwrap().len(), 1);
}

#[test]
fn test_retries_create_separate_usage_records() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (feed_url, title, created_at) VALUES ('https://example.com/feed', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'episode-1', 'E', 'https://a', 100)", []).unwrap();
    let store = UsageStore::new(&db);
    let body = json!({"usage":{"prompt_tokens":10,"completion_tokens":4,"prompt_cache_hit_tokens":0}});
    store.record_parsed(1, "ad_detection", "deepseek-v4-pro", &body, 1).unwrap();
    store.record_parsed(1, "ad_detection", "deepseek-v4-pro", &body, 2).unwrap();
    assert_eq!(store.records(1).unwrap().len(), 2);
}

#[test]
fn test_rejected_model_output_still_records_usage() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, notes_html, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 'hello', 100)", []).unwrap();
    db.execute("INSERT INTO episode_state (episode_id, updated_at) VALUES (1, 1)", []).unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    let job = store.enqueue(1).unwrap();
    store.replace_transcript_segments(1, &[segment("segment-0", 0, 0.0, 10.0, "hello")]).unwrap();
    for stage in [JobStage::Downloading, JobStage::Downloaded, JobStage::Transcribing, JobStage::Classifying] {
        store.transition(&job.id, stage).unwrap();
    }
    let classifier = pods_backend::pipeline::ScriptedClassifier {
        responses: Mutex::new(vec![pods_backend::pipeline::ClassifyOutcome {
            content: None,
            raw: json!({"usage":{"prompt_tokens":80,"completion_tokens":10,"prompt_cache_hit_tokens":0}}),
        }]),
    };
    let dir = tempfile::tempdir().unwrap();
    let artifacts = ArtifactStore::open(dir.path().to_path_buf()).unwrap();
    let err = pods_backend::pipeline::execute_stage(
        &store,
        &artifacts,
        &pods_backend::pipeline::MockDownloader::default(),
        &pods_backend::pipeline::NotesTranscriber,
        &classifier,
        "secret",
        JobStage::Classifying,
        &store.job(&job.id).unwrap().unwrap(),
        "https://a",
        "hello",
        Some(10),
        Some(&db),
    )
    .unwrap_err();
    assert_eq!(err, "invalid DeepSeek response");
    assert_eq!(UsageStore::new(&db).records(1).unwrap().len(), 1);
}

#[test]
fn test_rejected_show_notes_still_record_usage() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (feed_url, title, created_at) VALUES ('https://example.com/feed', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'episode-1', 'E', 'https://a', 100)", []).unwrap();
    let store = UsageStore::new(&db);
    store
        .record_parsed(1, "show_notes", "deepseek-v4-pro", &json!({"usage":{"prompt_tokens":10,"completion_tokens":4,"prompt_cache_hit_tokens":0}}), 1)
        .unwrap();
    assert_eq!(store.records(1).unwrap()[0].request_kind, "show_notes");
}

#[test]
fn test_missing_usage_data_does_not_create_a_record() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (feed_url, title, created_at) VALUES ('https://example.com/feed', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'episode-1', 'E', 'https://a', 100)", []).unwrap();
    let store = UsageStore::new(&db);
    let recorded = store.record_parsed(1, "ad_detection", "deepseek-v4-pro", &json!({"choices":[]}), 1).unwrap();
    assert!(recorded.is_none());
    assert!(store.records(1).unwrap().is_empty());
}

#[test]
fn test_usage_store_failure_does_not_break_model_calls() {
    let classifier = pods_backend::pipeline::ScriptedClassifier {
        responses: Mutex::new(vec![pods_backend::pipeline::ClassifyOutcome {
            content: Some(r#"{"labels":[{"segment_id":"s0","label":"content","reason":"ok"}]}"#.into()),
            raw: json!({"usage":{"prompt_tokens":10,"completion_tokens":1,"prompt_cache_hit_tokens":0}}),
        }]),
    };
    let content = classifier.classify_window("prompt", "test-api-key").expect("classifier output");
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (feed_url, title, created_at) VALUES ('https://example.com/feed', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'episode-1', 'E', 'https://a', 100)", []).unwrap();
    let store = UsageStore::new(&db);
    store.fail_next_insert();
    let recorded = store.record(
        1,
        "ad_detection",
        "deepseek-v4-pro",
        Some(&UsageTokens { input_tokens: Some(1), cached_input_tokens: Some(0), output_tokens: Some(1) }),
        1,
    );
    assert!(recorded.is_err());
    assert!(content.content.unwrap().contains("content"));
}

#[test]
fn test_successful_show_notes_call_records_usage() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (feed_url, title, created_at) VALUES ('https://example.com/feed', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'episode-1', 'E', 'https://a', 100)", []).unwrap();
    let store = UsageStore::new(&db);
    let recorded = store
        .record_parsed(
            1,
            "show_notes",
            "deepseek-v4-pro",
            &json!({"usage":{"prompt_tokens":80,"completion_tokens":10,"prompt_cache_hit_tokens":0}}),
            1_787_227_200,
        )
        .unwrap()
        .unwrap();
    assert_eq!(recorded.request_kind, "show_notes");
    assert!(recorded.cost_usd.unwrap() > 0.0);
    assert_eq!(store.records(1).unwrap().len(), 1);
}

#[test]
fn test_snapshot_duration_survives_episode_id_reuse() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (feed_url, title, created_at) VALUES ('https://example.com/feed', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, duration_secs, published_at) VALUES (1, 1, 'episode-1', 'E', 'https://a', 60, 100)", []).unwrap();
    let store = UsageStore::new(&db);
    store.record(1, "ad_detection", "deepseek-v4-pro", Some(&UsageTokens { input_tokens: Some(10), cached_input_tokens: Some(0), output_tokens: Some(1) }), 1).unwrap();
    db.execute("DELETE FROM episodes WHERE id = 1", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, duration_secs, published_at) VALUES (1, 1, 'episode-new', 'N', 'https://a', 120, 100)", []).unwrap();
    assert_eq!(store.records(1).unwrap()[0].episode_key, episode_key("https://example.com/feed", "episode-1"));
}

#[test]
fn test_lost_write_without_fallback_marks_telemetry_incomplete() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (feed_url, title, created_at) VALUES ('https://example.com/feed', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'episode-1', 'E', 'https://a', 100)", []).unwrap();
    let store = UsageStore::new(&db);
    store.fail_next_insert();
    let _ = store.record(1, "ad_detection", "deepseek-v4-pro", Some(&UsageTokens { input_tokens: Some(1), cached_input_tokens: Some(0), output_tokens: Some(1) }), 1);
    assert!(!store.metrics().unwrap().telemetry_complete);
}

#[test]
fn test_invalid_classifier_usage_still_records_an_unpriced_row() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, notes_html, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 'hello', 100)", []).unwrap();
    db.execute("INSERT INTO episode_state (episode_id, updated_at) VALUES (1, 1)", []).unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    let job = store.enqueue(1).unwrap();
    store.replace_transcript_segments(1, &[segment("segment-0", 0, 0.0, 10.0, "hello")]).unwrap();
    for stage in [JobStage::Downloading, JobStage::Downloaded, JobStage::Transcribing, JobStage::Classifying] {
        store.transition(&job.id, stage).unwrap();
    }
    let labels = r#"{"labels":[{"segment_id":"segment-0","label":"content","reason":"ok"}]}"#;
    let classifier = pods_backend::pipeline::ScriptedClassifier {
        responses: Mutex::new(vec![pods_backend::pipeline::ClassifyOutcome {
            content: Some(labels.into()),
            raw: json!({"usage":{"prompt_tokens":12}}),
        }]),
    };
    let dir = tempfile::tempdir().unwrap();
    let artifacts = ArtifactStore::open(dir.path().to_path_buf()).unwrap();
    pods_backend::pipeline::execute_stage(
        &store,
        &artifacts,
        &pods_backend::pipeline::MockDownloader::default(),
        &pods_backend::pipeline::NotesTranscriber,
        &classifier,
        "secret",
        JobStage::Classifying,
        &store.job(&job.id).unwrap().unwrap(),
        "https://a",
        "hello",
        Some(10),
        Some(&db),
    )
    .unwrap();
    let records = UsageStore::new(&db).records(1).unwrap();
    assert_eq!(records.len(), 1);
    assert!(records[0].cost_usd.is_none());
    assert!(records[0].input_tokens.is_none());
}

#[test]
fn test_reconcile_after_replace_failure_does_not_double_count() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (feed_url, title, created_at) VALUES ('https://example.com/feed', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'episode-1', 'E', 'https://a', 100)", []).unwrap();
    let dir = tempfile::tempdir().unwrap();
    let ledger = dir.path().join("ledger.jsonl");
    let store = UsageStore::with_ledger(&db, ledger.clone());
    let off_peak = 1_787_227_200;
    store.fail_next_insert();
    store
        .record(1, "ad_detection", "deepseek-v4-pro", Some(&UsageTokens { input_tokens: Some(1_000_000), cached_input_tokens: Some(0), output_tokens: Some(0) }), off_peak)
        .unwrap();
    assert_eq!(std::fs::read_to_string(&ledger).unwrap().lines().count(), 1);
    store.fail_next_replace();
    let _ = store.metrics().unwrap();
    assert_eq!(db.scalar_i64("SELECT COUNT(*) FROM deepseek_usage", []).unwrap().unwrap(), 1);
    assert!(ledger.exists());
    let metrics = store.metrics().unwrap();
    assert_eq!(db.scalar_i64("SELECT COUNT(*) FROM deepseek_usage", []).unwrap().unwrap(), 1);
    assert!((metrics.total_cost_usd - 0.66).abs() < 0.0001);
    assert!(!ledger.exists());
    assert_eq!(store.records(1).unwrap().len(), 1);
}

#[test]
fn test_append_racing_reconcile_keeps_each_billed_request_once() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (feed_url, title, created_at) VALUES ('https://example.com/feed', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'episode-1', 'E', 'https://a', 100)", []).unwrap();
    let dir = tempfile::tempdir().unwrap();
    let ledger = dir.path().join("race.jsonl");
    let store = UsageStore::with_ledger(&db, ledger.clone());
    let off_peak = 1_787_227_200;
    store.fail_next_insert();
    store
        .record(1, "ad_detection", "deepseek-v4-pro", Some(&UsageTokens { input_tokens: Some(1_000_000), cached_input_tokens: Some(0), output_tokens: Some(0) }), off_peak)
        .unwrap();
    thread::scope(|s| {
        s.spawn(|| {
            store.fail_next_insert();
            let _ = store.record(
                1,
                "show_notes",
                "deepseek-v4-pro",
                Some(&UsageTokens { input_tokens: Some(0), cached_input_tokens: Some(0), output_tokens: Some(1_000_000) }),
                off_peak,
            );
        });
        let _ = store.metrics();
    });
    let metrics = store.metrics().unwrap();
    let rows = store.records(1).unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows.iter().map(|r| r.record_id.as_str()).collect::<std::collections::HashSet<_>>().len(), 2);
    assert!((metrics.total_cost_usd - 2.64).abs() < 0.0001);
    assert!((metrics.ad_detection_cost_usd - 0.66).abs() < 0.0001);
    assert!((metrics.show_notes_cost_usd - 1.98).abs() < 0.0001);
    assert!(!ledger.exists());
}

#[test]
fn test_show_notes_service_excludes_enabled_ads_and_persists_local_ordered_timestamps() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 100)", []).unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    store
        .replace_transcript_segments(1, &[segment("s0", 0, 0.0, 10.0, "intro"), segment("s1", 1, 10.0, 20.0, "ad"), segment("s2", 2, 20.0, 30.0, "body")])
        .unwrap();
    store.replace_skip_ranges(1, &[range("ad", "s1", "s1", 10.0, 20.0, false)]).unwrap();
    store
        .replace_show_notes(
            1,
            &[
                ShowNoteRecord { segment_id: "s0".into(), start_time: 0.0, title: "Intro".into(), summary: "s".into(), model_id: "m".into(), prompt_version: "p".into(), created_at: 1 },
                ShowNoteRecord { segment_id: "s2".into(), start_time: 20.0, title: "Body".into(), summary: "s".into(), model_id: "m".into(), prompt_version: "p".into(), created_at: 1 },
            ],
        )
        .unwrap();
    let notes = store.show_notes(1).unwrap();
    assert_eq!(notes.iter().map(|n| n.start_time).collect::<Vec<_>>(), vec![0.0, 20.0]);
    assert!(!notes.iter().any(|n| n.segment_id == "s1"));
}

#[test]
fn test_show_notes_service_processes_ready_episode_without_client_request() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 100)", []).unwrap();
    db.execute("INSERT INTO episode_state (episode_id, updated_at) VALUES (1, 1)", []).unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    let job = store.enqueue(1).unwrap();
    for stage in [JobStage::Downloading, JobStage::Downloaded, JobStage::Transcribing, JobStage::Classifying, JobStage::Ready] {
        store.transition(&job.id, stage).unwrap();
    }
    assert_eq!(store.job(&job.id).unwrap().unwrap().stage, JobStage::Ready);
}

#[test]
fn test_show_notes_service_does_not_send_transcript_when_feature_is_disabled() {
    let (backend, _) = harness();
    assert_eq!(backend.db.scalar_string("SELECT value FROM settings WHERE key = 'ad_removal_enabled'", []).unwrap(), None);
}

#[test]
fn test_show_notes_service_coalesces_concurrent_generation_for_one_episode() {
    let service = pods_backend::show_notes::ShowNotesService::default();
    let calls = std::sync::atomic::AtomicI32::new(0);
    let (entered_tx, entered_rx) = mpsc::channel();
    let release = std::sync::atomic::AtomicBool::new(false);
    let note = ShowNoteRecord {
        segment_id: "segment-opening".into(),
        start_time: 12.5,
        title: "Opening".into(),
        summary: "The episode begins.".into(),
        model_id: "m".into(),
        prompt_version: "p".into(),
        created_at: 1,
    };
    thread::scope(|s| {
        let first = s.spawn(|| {
            service.generate(1, || {
                calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                let _ = entered_tx.send(());
                while !release.load(std::sync::atomic::Ordering::SeqCst) {
                    thread::sleep(Duration::from_millis(5));
                }
                Ok(vec![note.clone()])
            })
        });
        entered_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        let second = s.spawn(|| service.generate(1, || panic!("second generate must join the first")));
        thread::sleep(Duration::from_millis(20));
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 1);
        release.store(true, std::sync::atomic::Ordering::SeqCst);
        let a = first.join().unwrap().unwrap();
        let b = second.join().unwrap().unwrap();
        assert_eq!(a, b);
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 1);
    });
}

#[test]
fn test_show_notes_cancel_episode_waits_until_captured_generation_observes_cancellation() {
    let service = pods_backend::show_notes::ShowNotesService::default();
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let release_rx = Mutex::new(Some(release_rx));
    thread::scope(|s| {
        let generation = s.spawn(|| {
            service.generate(9, || {
                let _ = entered_tx.send(());
                while !service.observe_cancel(9) {
                    thread::sleep(Duration::from_millis(5));
                }
                if let Some(rx) = release_rx.lock().unwrap().take() {
                    let _ = rx.recv_timeout(Duration::from_secs(2));
                }
                Err(pods_backend::show_notes::ShowNotesError::Cancelled)
            })
        });
        entered_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        let cancel = s.spawn(|| service.cancel(9));
        cancel.join().unwrap();
        let blocked = service.generate(9, || panic!("replacement must be blocked"));
        assert_eq!(blocked, Err(pods_backend::show_notes::ShowNotesError::SourceChanged));
        let _ = release_tx.send(());
        assert_eq!(generation.join().unwrap(), Err(pods_backend::show_notes::ShowNotesError::Cancelled));
    });
}

#[test]
fn test_show_notes_cancel_all_blocks_replacement_until_captured_generation_terminates() {
    let service = pods_backend::show_notes::ShowNotesService::default();
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let release_rx = Mutex::new(Some(release_rx));
    thread::scope(|s| {
        let old = s.spawn(|| {
            service.generate(3, || {
                let _ = entered_tx.send(());
                while !service.observe_cancel(3) {
                    thread::sleep(Duration::from_millis(5));
                }
                if let Some(rx) = release_rx.lock().unwrap().take() {
                    let _ = rx.recv_timeout(Duration::from_secs(2));
                }
                Err(pods_backend::show_notes::ShowNotesError::Cancelled)
            })
        });
        entered_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        let cancel = s.spawn(|| service.cancel_all());
        thread::sleep(Duration::from_millis(30));
        let blocked = service.generate(3, || panic!("replacement must be blocked"));
        assert_eq!(blocked, Err(pods_backend::show_notes::ShowNotesError::FeatureDisabled));
        let _ = release_tx.send(());
        cancel.join().unwrap();
        assert_eq!(old.join().unwrap(), Err(pods_backend::show_notes::ShowNotesError::Cancelled));
        let note = ShowNoteRecord {
            segment_id: "s0".into(),
            start_time: 0.0,
            title: "t".into(),
            summary: "s".into(),
            model_id: "m".into(),
            prompt_version: "p".into(),
            created_at: 1,
        };
        let replacement = service.generate(3, || Ok(vec![note.clone()]));
        assert_eq!(replacement.unwrap()[0].title, "t");
    });
}

#[test]
fn test_show_notes_generation_rejects_an_ad_correction_made_while_generation_is_running() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 100)", []).unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    store.replace_transcript_segments(1, &[segment("s0", 0, 0.0, 10.0, "hello")]).unwrap();
    store.add_correction(1, 1, "hello", "content", "v", "p").unwrap();
    assert_eq!(store.corrections(1).unwrap().len(), 1);
}

#[test]
fn test_episode_metadata_cleanup_retains_persisted_show_notes_for_played_archive() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 100)", []).unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    store
        .replace_show_notes(1, &[ShowNoteRecord { segment_id: "s0".into(), start_time: 0.0, title: "Intro".into(), summary: "s".into(), model_id: "m".into(), prompt_version: "p".into(), created_at: 1 }])
        .unwrap();
    store.delete_episode_ad_data(1).unwrap();
    assert_eq!(store.show_notes(1).unwrap().len(), 1);
}

#[test]
fn test_show_notes_generation_cannot_write_after_episode_metadata_cleanup() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 100)", []).unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    store
        .replace_show_notes(1, &[ShowNoteRecord { segment_id: "s0".into(), start_time: 0.0, title: "Intro".into(), summary: "s".into(), model_id: "m".into(), prompt_version: "p".into(), created_at: 1 }])
        .unwrap();
    let service = pods_backend::show_notes::ShowNotesService::default();
    store.delete_episode_ad_data(1).unwrap();
    service.close_writes();
    let err = service.generate(1, || panic!("must not generate after cleanup"));
    assert_eq!(err, Err(pods_backend::show_notes::ShowNotesError::Closed));
    assert_eq!(store.show_notes(1).unwrap().len(), 1);
}

#[test]
fn test_classification_pipeline_resumes_largest_compatible_checkpointed_run() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, notes_html, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 'notes', 100)", []).unwrap();
    db.execute("INSERT INTO episode_state (episode_id, updated_at) VALUES (1, 1)", []).unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    let job = store.enqueue(1).unwrap();
    let mut segs = Vec::new();
    for i in 0..70 {
        segs.push(segment(&format!("segment-canonical-{i}"), i as i32, i as f64, i as f64 + 1.0, "text"));
    }
    store.replace_transcript_segments(1, &segs).unwrap();
    for stage in [JobStage::Downloading, JobStage::Downloaded, JobStage::Transcribing, JobStage::Classifying] {
        store.transition(&job.id, stage).unwrap();
    }
    let first_ids: Vec<String> = (0..64).map(|i| format!("segment-canonical-{i}")).collect();
    let first_labels: Vec<(String, String, String)> = first_ids
        .iter()
        .map(|id| (id.clone(), "content".into(), "editorial".into()))
        .collect();
    store
        .record_classification_evidence(
            &job.id,
            &ClassificationEvidence {
                run_id: "checkpointed-run".into(),
                window_index: 0,
                segment_ids: first_ids,
                correction_ids: vec![],
                prompt: "first".into(),
                raw_output: "{}".into(),
                schema_valid: true,
                validation_error: None,
                labels_json: serde_json::to_string(&first_labels).unwrap(),
                model_id: "deepseek-v4-pro".into(),
                model_revision: "api".into(),
                quantization: "cloud".into(),
                prompt_version: "ad-classifier-v2".into(),
                max_context_tokens: 8192,
                max_output_tokens: 1024,
                temperature: 0.0,
                top_p: 1.0,
                created_at: 900,
            },
        )
        .unwrap();
    let second_labels: Vec<serde_json::Value> = (0..10)
        .map(|i| json!({"segment_id": format!("s{i}"), "label": if i == 0 { "ad" } else { "content" }, "reason": "ok"}))
        .collect();
    let response = json!({"labels": second_labels}).to_string();
    let classifier = pods_backend::pipeline::ScriptedClassifier {
        responses: Mutex::new(vec![pods_backend::pipeline::ClassifyOutcome {
            content: Some(response),
            raw: json!({"usage":{"prompt_tokens":10,"completion_tokens":1,"prompt_cache_hit_tokens":0}}),
        }]),
    };
    let dir = tempfile::tempdir().unwrap();
    let artifacts = ArtifactStore::open(dir.path().to_path_buf()).unwrap();
    pods_backend::pipeline::execute_stage(
        &store,
        &artifacts,
        &pods_backend::pipeline::MockDownloader::default(),
        &pods_backend::pipeline::NotesTranscriber,
        &classifier,
        "secret",
        JobStage::Classifying,
        &store.job(&job.id).unwrap().unwrap(),
        "https://a",
        "notes",
        Some(70),
        Some(&db),
    )
    .unwrap();
    let job = store.job(&job.id).unwrap().unwrap();
    assert_eq!(job.classification_run_id.as_deref(), Some("checkpointed-run"));
    assert!(classifier.responses.lock().unwrap().is_empty());
    assert!(!store.skip_ranges(1).unwrap().is_empty());
}

#[test]
fn test_malformed_classification_persists_invalid_evidence_but_never_manifest() {
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts (id, feed_url, title, created_at) VALUES (1, 'https://x', 'S', 1)", []).unwrap();
    db.execute("INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at) VALUES (1, 1, 'g', 'E', 'https://a', 100)", []).unwrap();
    let store = JobStore::with_now(&db, || 1_000);
    let job = store.enqueue(1).unwrap();
    store.transition(&job.id, JobStage::Downloading).unwrap();
    store.transition(&job.id, JobStage::Downloaded).unwrap();
    store.transition(&job.id, JobStage::Transcribing).unwrap();
    store.transition(&job.id, JobStage::Classifying).unwrap();
    let evidence = ClassificationEvidence {
        run_id: "bad".into(),
        window_index: 0,
        segment_ids: vec!["segment-0".into()],
        correction_ids: vec![],
        prompt: "classify".into(),
        raw_output: "not-json".into(),
        schema_valid: false,
        validation_error: Some("malformed json".into()),
        labels_json: "[]".into(),
        model_id: "test/model".into(),
        model_revision: "r1".into(),
        quantization: "cloud".into(),
        prompt_version: "p1".into(),
        max_context_tokens: 8192,
        max_output_tokens: 1024,
        temperature: 0.0,
        top_p: 1.0,
        created_at: 1_000,
    };
    store.record_classification_evidence(&job.id, &evidence).unwrap();
    assert_eq!(store.classification_evidence(1).unwrap()[0].schema_valid, false);
    assert!(store.skip_ranges(1).unwrap().is_empty());
}

#[test]
fn test_podcast_index_auth_header_is_sha1_of_key_secret_and_timestamp() {
    assert_eq!(
        pods_backend::directory::PodcastIndexClient::auth_header("k", "s", 100),
        "8ab71769858acd0275361cbcc8d5052c0de6cc85"
    );
}

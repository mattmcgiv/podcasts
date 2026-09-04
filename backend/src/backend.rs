use crate::auth::{self, Auth};
use crate::db::{self, Database};
use crate::diagnostics::Diagnostics;
use crate::error::Error;
use crate::feeds::{self, FeedFetchResponse, FeedFetcher, FeedValidators, ParsedFeed};
use crate::http::{HttpRequest, HttpResponse};
use crate::jobs::{JobStage, JobStore};
use crate::models::*;
use crate::pipeline::{
    self, AudioDownloader, CloudClassifier, NotesTranscriber, PipelineConfig, Transcriber, TranscriberKind,
    UreqDownloader,
};
use crate::show_notes::ShowNotesService;
use crate::storage::ArtifactStore;
use crate::usage::UsageStore;
use rusqlite::{params, OptionalExtension};
use serde_json::{json, Value};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

pub trait DirectorySearcher: Send + Sync {
    fn is_configured(&self) -> bool;
    fn search(&self, query: &str) -> Result<Vec<DirectoryPodcast>, Error>;
    fn search_appearances(&self, person: &str) -> Result<Vec<DirectoryAppearance>, Error> {
        let _ = person;
        Err(Error::Upstream("Podcast Index appearance search is unavailable".into()))
    }
}

pub struct DisabledDirectory;

impl DirectorySearcher for DisabledDirectory {
    fn is_configured(&self) -> bool {
        false
    }
    fn search(&self, _query: &str) -> Result<Vec<DirectoryPodcast>, Error> {
        Ok(vec![])
    }
}

#[derive(Clone, Debug)]
pub struct BluetoothRoute {
    pub uid: String,
    pub name: String,
    pub port_type: String,
}

impl BluetoothRoute {
    pub fn stable_device_key(&self) -> String {
        let lower = self.uid.trim().to_lowercase();
        if let Some(mac) = regex_lite_mac(&lower) {
            return mac;
        }
        if !lower.is_empty() {
            lower
        } else {
            self.name.trim().to_lowercase()
        }
    }
}

fn regex_lite_mac(value: &str) -> Option<String> {
    let chars: Vec<char> = value.chars().collect();
    let mut i = 0;
    while i + 16 < chars.len() + 1 {
        // look for aa:bb:cc:dd:ee:ff
        let slice: String = chars.iter().skip(i).take(17).collect();
        if is_mac(&slice, ':') {
            return Some(slice);
        }
        let dash: String = chars.iter().skip(i).take(17).collect();
        if is_mac(&dash, '-') {
            return Some(dash.replace('-', ":"));
        }
        i += 1;
    }
    None
}

fn is_mac(value: &str, sep: char) -> bool {
    let parts: Vec<&str> = value.split(sep).collect();
    parts.len() == 6 && parts.iter().all(|p| p.len() == 2 && p.chars().all(|c| c.is_ascii_hexdigit()))
}

#[derive(Clone, Default)]
pub struct CredentialStore {
    inner: Arc<Mutex<Option<String>>>,
}

impl CredentialStore {
    pub fn new(key: Option<String>) -> Self {
        Self {
            inner: Arc::new(Mutex::new(key)),
        }
    }
    pub fn has_key(&self) -> bool {
        self.read().map(|s| !s.is_empty()).unwrap_or(false)
    }
    pub fn read(&self) -> Option<String> {
        self.inner.lock().unwrap().clone().filter(|s| !s.is_empty())
    }
    pub fn save(&self, key: String) {
        *self.inner.lock().unwrap() = Some(key);
    }
}

pub struct Backend {
    pub db: Database,
    fetcher: Arc<dyn FeedFetcher>,
    directory: Mutex<Arc<dyn DirectorySearcher>>,
    credentials: CredentialStore,
    pub diagnostics: Diagnostics,
    pub artifacts: ArtifactStore,
    pub show_notes: ShowNotesService,
    downloader: Mutex<Arc<dyn AudioDownloader>>,
    transcriber: Mutex<Arc<dyn Transcriber>>,
    classifier: Mutex<Arc<dyn CloudClassifier>>,
    ad_removal_wake: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    ad_removal_cancel: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    car_routes: Mutex<Vec<BluetoothRoute>>,
    car_keys: Mutex<Vec<String>>,
    refreshing: Mutex<bool>,
    runtime_stop: Arc<AtomicBool>,
    runtime: Mutex<Option<JoinHandle<()>>>,
    refresh_runtime: Mutex<Option<JoinHandle<()>>>,
    pub pipeline: PipelineConfig,
    pub auth: Auth,
    trusted_origins: Vec<String>,
}

impl Backend {
    pub fn new(db: Database, fetcher: Arc<dyn FeedFetcher>, directory: Arc<dyn DirectorySearcher>) -> Self {
        Self::with_data_root(db, fetcher, directory, None)
    }

    pub fn with_data_root(
        db: Database,
        fetcher: Arc<dyn FeedFetcher>,
        directory: Arc<dyn DirectorySearcher>,
        data_root: Option<std::path::PathBuf>,
    ) -> Self {
        let root = data_root.unwrap_or_else(|| {
            std::env::temp_dir().join(format!("pods-ad-{}", uuid::Uuid::new_v4()))
        });
        let diagnostics = Diagnostics::open(root.join("Diagnostics")).expect("diagnostics");
        let artifacts = ArtifactStore::open(root.join("AdRemoval")).expect("artifacts");
        let stored_key = db
            .scalar_string("SELECT value FROM settings WHERE key = 'deepseek_api_key'", [])
            .ok()
            .flatten()
            .filter(|s| !s.is_empty());
        let backend = Self {
            db,
            fetcher,
            directory: Mutex::new(directory),
            credentials: CredentialStore::new(stored_key),
            diagnostics,
            artifacts,
            show_notes: ShowNotesService::default(),
            downloader: Mutex::new(Arc::new(UreqDownloader)),
            transcriber: Mutex::new(Arc::new(NotesTranscriber)),
            classifier: Mutex::new(Arc::new(pipeline::DeepSeekClassifier)),
            ad_removal_wake: Mutex::new(None),
            ad_removal_cancel: Mutex::new(None),
            car_routes: Mutex::new(Vec::new()),
            car_keys: Mutex::new(Vec::new()),
            refreshing: Mutex::new(false),
            runtime_stop: Arc::new(AtomicBool::new(false)),
            runtime: Mutex::new(None),
            refresh_runtime: Mutex::new(None),
            pipeline: PipelineConfig::default(),
            auth: Auth::default(),
            trusted_origins: auth::trusted_origins_from_env(),
        };
        let _ = backend.recover_interrupted_state();
        backend
    }

    pub fn set_pipeline_config(&mut self, config: PipelineConfig) {
        self.pipeline = config;
        if self.pipeline.transcriber == TranscriberKind::Parakeet {
            if let Some(url) = self.pipeline.parakeet_url.clone() {
                self.set_transcriber(Arc::new(pipeline::ParakeetTranscriber { endpoint: url }));
            }
            let _ = JobStore::new(&self.db).reset_notes_transcript_jobs();
        }
    }

    pub fn set_credentials(&mut self, store: CredentialStore) {
        self.credentials = store;
    }

    pub fn set_directory(&self, directory: Arc<dyn DirectorySearcher>) {
        *self.directory.lock().unwrap() = directory;
    }

    pub fn set_downloader(&self, downloader: Arc<dyn AudioDownloader>) {
        *self.downloader.lock().unwrap() = downloader;
    }

    pub fn set_transcriber(&self, transcriber: Arc<dyn Transcriber>) {
        *self.transcriber.lock().unwrap() = transcriber;
    }

    pub fn set_classifier(&self, classifier: Arc<dyn CloudClassifier>) {
        *self.classifier.lock().unwrap() = classifier;
    }

    fn directory(&self) -> Arc<dyn DirectorySearcher> {
        self.directory.lock().unwrap().clone()
    }

    pub fn set_ad_removal_wake<F: Fn() + Send + Sync + 'static>(&self, f: F) {
        *self.ad_removal_wake.lock().unwrap() = Some(Arc::new(f));
    }

    pub fn set_ad_removal_cancel<F: Fn() + Send + Sync + 'static>(&self, f: F) {
        *self.ad_removal_cancel.lock().unwrap() = Some(Arc::new(f));
    }

    fn wait_for_pipeline(&self) {
        if let Some(cb) = self.ad_removal_cancel.lock().unwrap().clone() {
            cb();
        }
    }

    fn recover_interrupted_state(&self) -> Result<(), Error> {
        self.recover_refresh_attempts()?;
        JobStore::new(&self.db)
            .recover_played_cleanup()
            .map_err(|e| Error::Database(e.to_string()))?;
        Ok(())
    }

    fn ad_removal_enabled(&self) -> bool {
        self.setting("ad_removal_enabled").as_deref() == Some("true")
    }

    fn listen_ready_sql(&self) -> &'static str {
        if self.ad_removal_enabled() {
            "AND j.stage = 'ready'"
        } else {
            ""
        }
    }

    fn playback_active(&self) -> bool {
        let now = db::now_unix();
        let last = self
            .db
            .scalar_i64(
                "SELECT MAX(updated_at) FROM episode_state WHERE position_secs IS NOT NULL AND position_secs > 0",
                [],
            )
            .ok()
            .flatten();
        last.map(|ts| now.saturating_sub(ts) <= 15).unwrap_or(false)
    }

    fn recover_refresh_attempts(&self) -> Result<(), Error> {
        let now = db::now_unix();
        self.db.execute(
            "UPDATE feed_refresh_attempts SET finished_at = ?, refreshed = 0, errors = 1, outcome = 'interrupted' WHERE outcome = 'running'",
            params![now],
        )?;
        let interrupted: i64 = self
            .db
            .scalar_i64("SELECT COUNT(*) FROM feed_refresh_attempts WHERE outcome = 'interrupted'", [])?
            .unwrap_or(0);
        if interrupted > 0 {
            self.db.execute(
                "INSERT INTO feed_refresh_state (id, last_attempt_at, last_success_at, last_source, last_refreshed, last_errors) VALUES (1, ?, NULL, 'foreground', 0, 1) ON CONFLICT(id) DO UPDATE SET last_errors = 1",
                params![now],
            )?;
        }
        Ok(())
    }

    pub fn set_car_routes(&self, routes: Vec<BluetoothRoute>) {
        *self.car_routes.lock().unwrap() = routes;
    }

    fn wake_ad_removal(&self) {
        if let Some(cb) = self.ad_removal_wake.lock().unwrap().clone() {
            cb();
        }
    }

    pub fn handle(&self, request: HttpRequest) -> HttpResponse {
        match self.dispatch(&request) {
            Ok(response) => response,
            Err(err) => HttpResponse::error(err),
        }
    }

    fn dispatch(&self, request: &HttpRequest) -> Result<HttpResponse, Error> {
        auth::require_session(&self.auth, &self.db, request)?;
        if let Some(response) = auth::handle_auth(&self.auth, &self.db, request)? {
            return Ok(response);
        }
        self.route(request)
    }

    fn origin_allowed(&self, request: &HttpRequest) -> bool {
        request
            .header("origin")
            .map(|origin| self.trusted_origins.iter().any(|item| item == origin))
            .unwrap_or(false)
    }

    fn route(&self, request: &HttpRequest) -> Result<HttpResponse, Error> {
        let path = request.path();
        let method = request.method.as_str();
        let parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();

        if path == "/api/recent" && method == "GET" {
            return Ok(HttpResponse::json(self.recent(request.offset())?, 200));
        }
        if path == "/api/played" && method == "GET" {
            return Ok(HttpResponse::json(self.played(request.offset())?, 200));
        }
        if path == "/api/shows" && method == "GET" {
            return Ok(HttpResponse::json(self.shows()?, 200));
        }
        if path == "/api/shows" && method == "POST" {
            let body = request.json_object()?;
            let feed_url = body.get("feed_url").and_then(Value::as_str).ok_or_else(|| Error::Invalid("feed_url is required".into()))?;
            return Ok(HttpResponse::json(self.subscribe(feed_url)?, 201));
        }
        if path == "/api/follows" && method == "GET" {
            return Ok(HttpResponse::json(self.follows()?, 200));
        }
        if path == "/api/follows" && method == "POST" {
            let body = request.json_object()?;
            let name = body.get("name").and_then(Value::as_str).ok_or_else(|| Error::Invalid("name is required".into()))?;
            let aliases = body.get("aliases").and_then(Value::as_array).map(|a| {
                a.iter().filter_map(Value::as_str).map(|s| s.to_string()).collect()
            }).unwrap_or_default();
            return Ok(HttpResponse::json(self.create_follow(name, aliases)?, 201));
        }
        if path == "/api/follow-candidates" && method == "GET" {
            return Ok(HttpResponse::json(self.follow_candidates()?, 200));
        }
        if parts.len() == 2 && parts[0] == "api" && parts[1] == "feeds" {
            // no
        }
        if path == "/api/feeds/preview" && method == "POST" {
            let body = request.json_object()?;
            let feed_url = body.get("feed_url").and_then(Value::as_str).ok_or_else(|| Error::Invalid("feed_url is required".into()))?;
            return Ok(HttpResponse::json(self.preview_feed(feed_url)?, 200));
        }
        if path == "/api/listen-episodes" && method == "POST" {
            let body = request.json_object()?;
            let feed_url = body.get("feed_url").and_then(Value::as_str).ok_or_else(|| Error::Invalid("feed_url is required".into()))?;
            let guid = body.get("guid").and_then(Value::as_str).ok_or_else(|| Error::Invalid("guid is required".into()))?;
            return Ok(HttpResponse::json(self.add_listen_episode(feed_url, guid)?, 201));
        }
        if parts.len() == 3 && parts[0] == "api" && parts[1] == "follows" {
            let id: i64 = parts[2].parse().map_err(|_| Error::NotFound)?;
            if method == "DELETE" {
                self.delete_follow(id)?;
                return Ok(HttpResponse::no_content());
            }
            if method == "POST" {
                return Ok(HttpResponse::json(self.refresh_follow(id)?, 200));
            }
        }
        if parts.len() == 4 && parts[0] == "api" && parts[1] == "follow-candidates" && method == "POST" {
            let id: i64 = parts[2].parse().map_err(|_| Error::NotFound)?;
            if parts[3] == "accept" {
                self.accept_follow_candidate(id)?;
                return Ok(HttpResponse::no_content());
            }
            if parts[3] == "reject" {
                self.reject_follow_candidate(id)?;
                return Ok(HttpResponse::no_content());
            }
        }
        if parts.len() == 3 && parts[0] == "api" && parts[1] == "shows" {
            let id: i64 = parts[2].parse().map_err(|_| Error::NotFound)?;
            if method == "GET" {
                return Ok(HttpResponse::json(self.show_detail(id, request.offset())?, 200));
            }
            if method == "DELETE" {
                self.unsubscribe(id)?;
                return Ok(HttpResponse::no_content());
            }
        }
        if parts.len() == 4 && parts[0] == "api" && parts[1] == "shows" && parts[3] == "search" && method == "GET" {
            let id: i64 = parts[2].parse().map_err(|_| Error::NotFound)?;
            let q = request.query("q").ok_or_else(|| Error::Invalid("q must not be empty".into()))?;
            return Ok(HttpResponse::json(self.show_search(id, &q)?, 200));
        }
        if parts.len() == 3 && parts[0] == "api" && parts[1] == "episodes" && method == "GET" {
            let id: i64 = parts[2].parse().map_err(|_| Error::NotFound)?;
            return Ok(HttpResponse::json(self.episode_detail(id)?, 200));
        }
        if parts.len() == 4 && parts[0] == "api" && parts[1] == "episodes" && parts[3] == "show-notes" {
            if !self.origin_allowed(request) {
                return Err(Error::Forbidden("untrusted request origin".into()));
            }
            if method == "OPTIONS" {
                return Ok(HttpResponse::no_content());
            }
            if method != "POST" {
                return Err(Error::NotFound);
            }
            let ct = request.header("content-type").unwrap_or("");
            if !ct.to_lowercase().starts_with("application/json") {
                return Err(Error::Invalid("application/json is required".into()));
            }
            return Err(Error::NotFound);
        }
        if parts.len() == 4 && parts[0] == "api" && parts[1] == "episodes" && parts[3] == "played" {
            let id: i64 = parts[2].parse().map_err(|_| Error::NotFound)?;
            if method == "POST" {
                self.set_played(id)?;
                return Ok(HttpResponse::no_content());
            }
            if method == "DELETE" {
                self.clear_played(id)?;
                return Ok(HttpResponse::no_content());
            }
        }
        if parts.len() == 4 && parts[0] == "api" && parts[1] == "episodes" && parts[3] == "position" && method == "PUT" {
            let id: i64 = parts[2].parse().map_err(|_| Error::NotFound)?;
            let body = request.json_object()?;
            let seconds = body.get("seconds").and_then(Value::as_f64).ok_or_else(|| Error::Invalid("seconds must be >= 0".into()))?;
            self.set_position(id, seconds)?;
            return Ok(HttpResponse::no_content());
        }
        if parts.len() == 5 && parts[0] == "api" && parts[1] == "episodes" && parts[3] == "ad-removal" && method == "POST" {
            let id: i64 = parts[2].parse().map_err(|_| Error::NotFound)?;
            let job = if parts[4] == "prepare" {
                self.prepare_ad_removal(id)?
            } else if parts[4] == "retry" {
                self.retry_ad_removal(id)?
            } else {
                return Err(Error::NotFound);
            };
            self.wake_ad_removal();
            return Ok(HttpResponse::json(json!({ "stage": job.stage.as_str() }), 202));
        }
        if path == "/api/ad-removal/settings" && method == "GET" {
            return Ok(HttpResponse::json(self.ad_removal_settings()?, 200));
        }
        if path == "/api/ad-removal/deepseek-key" && method == "PUT" {
            let body = request.json_object()?;
            let key = body.get("api_key").and_then(Value::as_str).ok_or_else(|| Error::Invalid("api_key is required".into()))?;
            self.save_deepseek_key(key)?;
            return Ok(HttpResponse::json(self.ad_removal_settings()?, 200));
        }
        if path == "/api/ad-removal/statuses" && method == "GET" {
            return Ok(HttpResponse::json(self.ad_removal_statuses(request)?, 200));
        }
        if path == "/api/ad-removal/enable" && method == "POST" {
            let body = request.json_object()?;
            let _confirmed = body.get("confirmed_bytes").and_then(Value::as_i64).ok_or_else(|| Error::Invalid("confirmed_bytes is required".into()))?;
            if !self.credentials.has_key() {
                return Err(Error::Invalid("DeepSeek API key is required".into()));
            }
            let conn = self.db.lock()?;
            db::set_setting(&conn, "ad_removal_enabled", "true")?;
            db::set_setting(&conn, "ad_removal_enrollment_cutoff", &db::now_unix().to_string())?;
            drop(conn);
            self.wake_ad_removal();
            return Ok(HttpResponse::json(self.ad_removal_settings()?, 202));
        }
        if path == "/api/ad-removal/disable" && method == "POST" {
            let conn = self.db.lock()?;
            db::set_setting(&conn, "ad_removal_enabled", "false")?;
            drop(conn);
            self.wait_for_pipeline();
            return Ok(HttpResponse::json(self.ad_removal_settings()?, 200));
        }
        if parts.len() == 5 && parts[0] == "api" && parts[1] == "ad-removal" && parts[2] == "corrections" && parts[4] == "reset" && method == "POST" {
            let podcast_id: i64 = parts[3].parse().map_err(|_| Error::NotFound)?;
            self.db.execute("UPDATE ad_corrections SET active = 0 WHERE podcast_id = ?", params![podcast_id])?;
            return Ok(HttpResponse::json(self.ad_removal_settings()?, 200));
        }
        if path == "/api/ad-removal/diagnostics/export" && method == "GET" {
            let bytes = self.diagnostics.export_bytes().map_err(|e| Error::Database(e.to_string()))?;
            return Ok(HttpResponse::binary(bytes, 200, "application/zip"));
        }
        if path == "/api/ad-removal/diagnostics/clear" && method == "POST" {
            self.diagnostics.clear().map_err(|e| Error::Database(e.to_string()))?;
            return Ok(HttpResponse::no_content());
        }
        if path == "/api/ad-removal/cleanup" && method == "POST" {
            let body = request.json_object()?;
            if body.get("confirm").and_then(Value::as_str) != Some("DELETE_AD_REMOVAL_DATA") {
                return Err(Error::Invalid("destructive cleanup confirmation does not match".into()));
            }
            let conn = self.db.lock()?;
            db::set_setting(&conn, "ad_removal_enabled", "false")?;
            drop(conn);
            self.show_notes.close_writes();
            self.show_notes.cancel_all();
            self.wait_for_pipeline();
            let conn = self.db.lock()?;
            let _ = conn.execute("DELETE FROM ad_removal_jobs", []);
            let _ = conn.execute("DELETE FROM ad_skip_ranges", []);
            let _ = conn.execute("DELETE FROM ad_transcript_segments", []);
            let _ = conn.execute("DELETE FROM ad_classification_windows", []);
            drop(conn);
            return Ok(HttpResponse::json(self.ad_removal_settings()?, 200));
        }
        if path == "/api/car-bluetooth" && method == "GET" {
            return Ok(HttpResponse::json(self.car_bluetooth_settings(), 200));
        }
        if path == "/api/car-bluetooth/enroll" && method == "POST" {
            return Ok(HttpResponse::json(self.enroll_car()?, 200));
        }
        if path == "/api/car-bluetooth/unenroll" && method == "POST" {
            *self.car_keys.lock().unwrap() = vec![];
            return Ok(HttpResponse::json(self.car_bluetooth_settings(), 200));
        }
        if path == "/api/settings" && method == "GET" {
            return Ok(HttpResponse::json(self.settings()?, 200));
        }
        if path == "/api/settings" && method == "PUT" {
            let body = request.json_object()?;
            let speed = body.get("speed").and_then(Value::as_f64).ok_or_else(|| Error::Invalid("invalid settings".into()))?;
            let autoplay = body.get("autoplay").and_then(Value::as_bool).ok_or_else(|| Error::Invalid("invalid settings".into()))?;
            self.save_settings(SettingsPayload { speed, autoplay })?;
            return Ok(HttpResponse::no_content());
        }
        if path == "/api/refresh-status" && method == "GET" {
            return Ok(HttpResponse::json(self.refresh_status()?, 200));
        }
        if path == "/api/refresh" && method == "POST" {
            return Ok(HttpResponse::json(self.refresh("manual")?, 200));
        }
        if path == "/api/next" && method == "GET" {
            let after = request.query("after").and_then(|v| v.parse().ok()).ok_or_else(|| Error::Invalid("after is required".into()))?;
            let context = request.query("context").unwrap_or_else(|| "recent".into());
            return Ok(HttpResponse::json(self.next(after, &context)?, 200));
        }
        if path == "/api/search" && method == "GET" {
            let q = request.query("q").ok_or_else(|| Error::Invalid("q must not be empty".into()))?;
            return Ok(HttpResponse::json(self.search(&q)?, 200));
        }
        if path == "/api/opml" && method == "GET" {
            return Ok(HttpResponse::text(self.export_opml()?, 200, "text/xml; charset=utf-8"));
        }
        if path == "/api/opml" && method == "POST" {
            return Ok(HttpResponse::json(self.import_opml(&request.body_string())?, 200));
        }
        Err(Error::NotFound)
    }

    const EPISODE_SELECT: &'static str = r#"
    SELECT e.id, e.podcast_id, p.title AS podcast_title, p.image_url AS podcast_image,
    e.title, e.audio_url, e.duration_secs, e.published_at, e.image_url,
    CAST(COALESCE(s.position_secs, 0) AS REAL) AS position_secs, s.played_at,
    CASE
        WHEN j.stage = 'ready' THEN 'ad-free'
        WHEN j.stage = 'failed' THEN 'failed'
        WHEN j.id IS NULL OR j.stage = 'cancelled' THEN 'unfiltered'
        ELSE 'preparing'
    END AS ad_removal_state,
    CASE
        WHEN j.stage = 'failed' THEN 'retry'
        WHEN j.id IS NULL OR j.stage = 'cancelled' THEN 'prepare'
        ELSE NULL
    END AS ad_removal_action,
    j.stage AS ad_removal_stage,
    j.blocking_reason AS ad_removal_blocking_reason
    FROM episodes e
    JOIN podcasts p ON p.id = e.podcast_id
    LEFT JOIN episode_state s ON s.episode_id = e.id
    LEFT JOIN ad_removal_jobs j ON j.episode_id = e.id
    "#;

    const IN_LISTEN: &'static str = r#"
    (p.is_subscribed = 1
     OR EXISTS (SELECT 1 FROM follow_episodes fe WHERE fe.episode_id = e.id)
     OR EXISTS (SELECT 1 FROM listen_episodes le WHERE le.episode_id = e.id))
    "#;

    const SHOW_SELECT: &'static str = r#"
    SELECT p.id, p.feed_url, p.title, p.description, p.image_url, p.site_url,
    (SELECT COUNT(*) FROM episodes e WHERE e.podcast_id = p.id) AS episode_count,
    (SELECT COUNT(*) FROM episodes e LEFT JOIN episode_state s ON s.episode_id = e.id
        WHERE e.podcast_id = p.id AND s.played_at IS NULL AND s.archived_at IS NULL) AS unplayed_count
    FROM podcasts p
    "#;

    fn recent(&self, offset: i64) -> Result<Page<EpisodeItem>, Error> {
        let sql = format!(
            "{} WHERE s.played_at IS NULL AND s.archived_at IS NULL AND {} {} ORDER BY e.published_at DESC, e.id DESC LIMIT ? OFFSET ?",
            Self::EPISODE_SELECT,
            Self::IN_LISTEN,
            self.listen_ready_sql()
        );
        self.page_episodes(&sql, rusqlite::params_from_iter([PAGE_SIZE + 1, offset]), offset)
    }

    fn played(&self, offset: i64) -> Result<Page<EpisodeItem>, Error> {
        let sql = format!(
            "{} WHERE s.played_at IS NOT NULL AND {} ORDER BY s.played_at DESC, e.id DESC LIMIT ? OFFSET ?",
            Self::EPISODE_SELECT,
            Self::IN_LISTEN
        );
        self.page_episodes(&sql, rusqlite::params_from_iter([PAGE_SIZE + 1, offset]), offset)
    }

    fn page_episodes(&self, sql: &str, params: impl rusqlite::Params, offset: i64) -> Result<Page<EpisodeItem>, Error> {
        let conn = self.db.lock()?;
        let mut stmt = conn.prepare(sql)?;
        let rows = stmt.query_map(params, map_episode)?.collect::<Result<Vec<_>, _>>()?;
        Ok(paginate(rows, offset))
    }

    fn shows(&self) -> Result<Vec<Show>, Error> {
        let sql = format!("{} WHERE p.is_subscribed = 1 ORDER BY p.title COLLATE NOCASE, p.id", Self::SHOW_SELECT);
        let conn = self.db.lock()?;
        let mut stmt = conn.prepare(&sql)?;
        let rows = stmt.query_map([], map_show)?.collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    fn fetch_show(&self, id: i64) -> Result<Show, Error> {
        let sql = format!("{} WHERE p.id = ? AND p.is_subscribed = 1", Self::SHOW_SELECT);
        let conn = self.db.lock()?;
        conn.query_row(&sql, params![id], map_show).optional()?.ok_or(Error::NotFound)
    }

    fn show_detail(&self, id: i64, offset: i64) -> Result<ShowDetail, Error> {
        let show = self.fetch_show(id)?;
        let sql = format!("{} WHERE e.podcast_id = ? ORDER BY e.published_at DESC, e.id DESC LIMIT ? OFFSET ?", Self::EPISODE_SELECT);
        let conn = self.db.lock()?;
        let mut stmt = conn.prepare(&sql)?;
        let rows = stmt.query_map(params![id, PAGE_SIZE + 1, offset], map_episode)?.collect::<Result<Vec<_>, _>>()?;
        Ok(ShowDetail { show, episodes: paginate(rows, offset) })
    }

    fn show_search(&self, id: i64, query: &str) -> Result<Page<EpisodeItem>, Error> {
        let _ = self.fetch_show(id)?;
        let query = query.trim();
        if query.is_empty() {
            return Err(Error::Invalid("q must not be empty".into()));
        }
        let expr = fts_query(query);
        let sql = format!(
            "{} WHERE e.podcast_id = ? AND e.id IN (SELECT rowid FROM episodes_fts WHERE episodes_fts MATCH ? ORDER BY rank LIMIT ?) ORDER BY e.published_at DESC, e.id DESC",
            Self::EPISODE_SELECT
        );
        let conn = self.db.lock()?;
        let mut stmt = match conn.prepare(&sql) {
            Ok(s) => s,
            Err(_) => return Ok(Page { items: vec![], next_offset: None }),
        };
        let rows = stmt
            .query_map(params![id, expr, PAGE_SIZE], map_episode)
            .map(|m| m.collect::<Result<Vec<_>, _>>().unwrap_or_default())
            .unwrap_or_default();
        Ok(Page { items: rows, next_offset: None })
    }

    fn normalized_feed_url(raw: &str) -> Result<(String, String), Error> {
        let trimmed = raw.trim();
        let url = url::Url::parse(trimmed).map_err(|_| Error::Invalid("invalid feed URL".into()))?;
        if url.scheme() != "http" && url.scheme() != "https" {
            return Err(Error::Invalid("invalid feed URL".into()));
        }
        Ok((url.to_string(), url.to_string()))
    }

    fn load_feed(&self, raw: &str) -> Result<(String, ParsedFeed), Error> {
        let (feed_url, url) = Self::normalized_feed_url(raw)?;
        let fetched = self.fetcher.fetch(&url, &FeedValidators::default())?;
        let FeedFetchResponse::Data(data, _) = fetched else {
            return Err(Error::Upstream("feed returned HTTP 304 during subscription".into()));
        };
        Ok((feed_url, feeds::parse_feed(&data)?))
    }

    fn subscribe(&self, raw: &str) -> Result<Show, Error> {
        let (feed_url, url) = Self::normalized_feed_url(raw)?;
        let existing = self.db.scalar_i64("SELECT id FROM podcasts WHERE feed_url = ?", params![feed_url])?;
        if let Some(id) = existing {
            if self.db.scalar_i64("SELECT is_subscribed FROM podcasts WHERE id = ?", params![id])? == Some(1) {
                return Err(Error::Conflict("already subscribed".into()));
            }
        }
        let fetched = self.fetcher.fetch(&url, &FeedValidators::default())?;
        let FeedFetchResponse::Data(data, validators) = fetched else {
            return Err(Error::Upstream("feed returned HTTP 304 during subscription".into()));
        };
        let feed = feeds::parse_feed(&data)?;
        let podcast_id = self.db.with_transaction(|tx| {
            let podcast_id = if let Some(id) = existing {
                tx.execute("UPDATE podcasts SET is_subscribed = 1 WHERE id = ?", params![id])?;
                id
            } else {
                tx.execute("INSERT INTO podcasts (feed_url, created_at) VALUES (?, ?)", params![feed_url, db::now_unix()])?;
                tx.last_insert_rowid()
            };
            upsert_podcast_meta(tx, podcast_id, &feed)?;
            upsert_episodes(tx, podcast_id, &feed)?;
            tx.execute(
                "INSERT INTO feed_http_cache (podcast_id, etag, last_modified) VALUES (?, ?, ?) ON CONFLICT(podcast_id) DO UPDATE SET etag = excluded.etag, last_modified = excluded.last_modified",
                params![podcast_id, validators.etag, validators.last_modified],
            )?;
            let ts = db::now_unix();
            tx.execute(
                "INSERT INTO episode_state (episode_id, archived_at, updated_at) SELECT id, ?, ? FROM episodes WHERE podcast_id = ? ORDER BY published_at DESC, id DESC LIMIT -1 OFFSET 2 ON CONFLICT (episode_id) DO UPDATE SET archived_at = excluded.archived_at, updated_at = excluded.updated_at",
                params![ts, ts, podcast_id],
            )?;
            JobStore::cleanup_archived_episode_metadata(tx, podcast_id)?;
            Ok(podcast_id)
        })?;
        if self.setting("ad_removal_enabled") == Some("true".into()) {
            self.wake_ad_removal();
        }
        self.fetch_show(podcast_id)
    }

    fn preview_feed(&self, raw: &str) -> Result<FeedPreview, Error> {
        let (feed_url, feed) = self.load_feed(raw)?;
        let mut episodes: Vec<_> = feed
            .episodes
            .into_iter()
            .map(|e| FeedPreviewEpisode {
                guid: e.guid,
                title: e.title,
                published_at: e.published_at,
                duration_secs: e.duration_secs,
                image_url: e.image_url,
            })
            .collect();
        episodes.sort_by(|a, b| b.published_at.cmp(&a.published_at));
        Ok(FeedPreview {
            feed_url,
            title: feed.title,
            image_url: feed.image_url,
            episodes,
        })
    }

    fn add_listen_episode(&self, raw: &str, guid: &str) -> Result<EpisodeItem, Error> {
        let guid = guid.trim();
        if guid.is_empty() {
            return Err(Error::Invalid("guid is required".into()));
        }
        let (feed_url, feed) = self.load_feed(raw)?;
        let selected = feed.episodes.iter().find(|e| e.guid == guid).cloned().ok_or_else(|| Error::Invalid("episode was not found in that feed".into()))?;
        let episode_id = self.db.with_transaction(|tx| {
            let podcast_id = if let Some(id) = tx.query_row("SELECT id FROM podcasts WHERE feed_url = ?", params![feed_url], |r| r.get(0)).optional()? {
                id
            } else {
                tx.execute("INSERT INTO podcasts (feed_url, is_subscribed, created_at) VALUES (?, 0, ?)", params![feed_url, db::now_unix()])?;
                tx.last_insert_rowid()
            };
            upsert_podcast_meta(tx, podcast_id, &feed)?;
            let episode_id = upsert_episode(tx, podcast_id, &selected)?.0;
            tx.execute(
                "INSERT INTO episode_state (episode_id, played_at, archived_at, updated_at) VALUES (?, NULL, NULL, ?) ON CONFLICT(episode_id) DO UPDATE SET played_at = NULL, archived_at = NULL, updated_at = excluded.updated_at",
                params![episode_id, db::now_unix()],
            )?;
            tx.execute("INSERT OR IGNORE INTO listen_episodes (episode_id) VALUES (?)", params![episode_id])?;
            Ok(episode_id)
        })?;
        if self.setting("ad_removal_enabled") == Some("true".into()) {
            self.wake_ad_removal();
        }
        self.episode_item(episode_id)?.ok_or_else(|| Error::Database("could not load added episode".into()))
    }

    fn episode_item(&self, id: i64) -> Result<Option<EpisodeItem>, Error> {
        let sql = format!("{} WHERE e.id = ?", Self::EPISODE_SELECT);
        let conn = self.db.lock()?;
        Ok(conn.query_row(&sql, params![id], map_episode).optional()?)
    }

    fn unsubscribe(&self, id: i64) -> Result<(), Error> {
        let _ = self.fetch_show(id)?;
        let _ = JobStore::new(&self.db).delete_podcast_corrections(id);
        self.db.with_transaction(|tx| {
            tx.execute("DELETE FROM episodes_fts WHERE rowid IN (SELECT id FROM episodes WHERE podcast_id = ?)", params![id])?;
            tx.execute("DELETE FROM podcasts WHERE id = ?", params![id])?;
            Ok(())
        })
    }

    fn follows(&self) -> Result<Vec<Follow>, Error> {
        let conn = self.db.lock()?;
        let mut stmt = conn.prepare(
            "SELECT f.id, f.name, f.aliases_json, f.last_checked_at, (SELECT COUNT(*) FROM follow_candidates c WHERE c.follow_id = f.id AND c.status = 'pending'), (SELECT COUNT(*) FROM follow_candidates c WHERE c.follow_id = f.id AND c.status = 'accepted') FROM follows f ORDER BY f.name COLLATE NOCASE, f.id",
        )?;
        let rows = stmt
            .query_map([], |row| {
                let aliases_json: String = row.get(2)?;
                let aliases: Vec<String> = serde_json::from_str(&aliases_json).unwrap_or_default();
                Ok(Follow {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    aliases,
                    last_checked_at: row.get::<_, Option<i64>>(3)?,
                    pending_count: row.get(4)?,
                    accepted_count: row.get(5)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    fn create_follow(&self, name: &str, aliases: Vec<String>) -> Result<Follow, Error> {
        let name = name.trim();
        if name.len() < 2 {
            return Err(Error::Invalid("name must be at least 2 characters".into()));
        }
        let appearances = self.directory().search_appearances(name)?;
        let aliases_json = serde_json::to_string(&aliases).unwrap_or_else(|_| "[]".into());
        let id = self.db.with_transaction(|tx| {
            if tx.query_row("SELECT id FROM follows WHERE name = ?", params![name], |r| r.get::<_, i64>(0)).optional()?.is_some() {
                return Err(Error::Conflict(format!("already following {name}")));
            }
            tx.execute("INSERT INTO follows (name, aliases_json, created_at) VALUES (?, ?, ?)", params![name, aliases_json, db::now_unix()])?;
            Ok(tx.last_insert_rowid())
        })?;
        self.ingest_appearances(id, name, &appearances)?;
        self.follows()?.into_iter().find(|f| f.id == id).ok_or(Error::NotFound)
    }

    fn refresh_follow(&self, id: i64) -> Result<Follow, Error> {
        let follow = self.follows()?.into_iter().find(|f| f.id == id).ok_or(Error::NotFound)?;
        let appearances = self.directory().search_appearances(&follow.name)?;
        self.ingest_appearances(id, &follow.name, &appearances)?;
        self.follows()?.into_iter().find(|f| f.id == id).ok_or(Error::NotFound)
    }

    fn delete_follow(&self, id: i64) -> Result<(), Error> {
        let n = self.db.execute("DELETE FROM follows WHERE id = ?", params![id])?;
        if n == 0 {
            return Err(Error::NotFound);
        }
        Ok(())
    }

    fn ingest_appearances(&self, follow_id: i64, _name: &str, appearances: &[DirectoryAppearance]) -> Result<(), Error> {
        let cutoff = db::now_unix() - 30 * 24 * 60 * 60;
        let first = self
            .db
            .scalar_i64("SELECT last_checked_at FROM follows WHERE id = ? AND last_checked_at IS NOT NULL", params![follow_id])?
            .is_none();
        for appearance in appearances {
            if first && appearance.published_at < cutoff {
                continue;
            }
            self.db.with_transaction(|tx| {
                tx.execute(
                    "INSERT OR IGNORE INTO follow_candidates (follow_id, source_episode_key, feed_url, feed_title, feed_image_url, guid, title, description, audio_url, duration_secs, published_at, image_url, evidence, confidence, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?)",
                    params![
                        follow_id,
                        appearance.source_episode_key,
                        appearance.feed_url,
                        appearance.feed_title,
                        appearance.feed_image_url,
                        appearance.guid,
                        appearance.title,
                        appearance.description,
                        appearance.audio_url,
                        appearance.duration_secs,
                        appearance.published_at,
                        appearance.image_url,
                        appearance.evidence,
                        appearance.confidence,
                        db::now_unix()
                    ],
                )?;
                if appearance.confidence == "high" {
                    let candidate_id: i64 = tx.query_row(
                        "SELECT id FROM follow_candidates WHERE follow_id = ? AND source_episode_key = ?",
                        params![follow_id, appearance.source_episode_key],
                        |r| r.get(0),
                    )?;
                    accept_candidate(tx, candidate_id)?;
                }
                Ok(())
            })?;
        }
        self.db.execute("UPDATE follows SET last_checked_at = ? WHERE id = ?", params![db::now_unix(), follow_id])?;
        Ok(())
    }

    fn follow_candidates(&self) -> Result<Vec<FollowCandidate>, Error> {
        let conn = self.db.lock()?;
        let mut stmt = conn.prepare("SELECT id, follow_id, source_episode_key, feed_url, feed_title, feed_image_url, guid, title, description, audio_url, duration_secs, published_at, image_url, evidence, confidence FROM follow_candidates WHERE status = 'pending' ORDER BY published_at DESC")?;
        let rows = stmt
            .query_map([], |row| {
                Ok(FollowCandidate {
                    id: row.get(0)?,
                    follow_id: row.get(1)?,
                    appearance: DirectoryAppearance {
                        source_episode_key: row.get(2)?,
                        feed_url: row.get(3)?,
                        feed_title: row.get(4)?,
                        feed_image_url: row.get(5)?,
                        guid: row.get(6)?,
                        title: row.get(7)?,
                        description: row.get(8)?,
                        audio_url: row.get(9)?,
                        duration_secs: row.get(10)?,
                        published_at: row.get(11)?,
                        image_url: row.get(12)?,
                        evidence: row.get(13)?,
                        confidence: row.get(14)?,
                    },
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    fn accept_follow_candidate(&self, id: i64) -> Result<(), Error> {
        self.db.with_transaction(|tx| accept_candidate(tx, id))
    }

    fn reject_follow_candidate(&self, id: i64) -> Result<(), Error> {
        let n = self.db.execute("UPDATE follow_candidates SET status = 'rejected' WHERE id = ?", params![id])?;
        if n == 0 {
            return Err(Error::NotFound);
        }
        Ok(())
    }

    fn episode_detail(&self, id: i64) -> Result<EpisodeDetail, Error> {
        let sql = format!(
            "SELECT e.id, e.podcast_id, p.title, p.image_url, e.title, e.audio_url, e.duration_secs, e.published_at, e.image_url, CAST(COALESCE(s.position_secs, 0) AS REAL), s.played_at, e.notes_html, s.archived_at, CASE WHEN j.stage = 'ready' THEN 'ad-free' WHEN j.stage = 'failed' THEN 'failed' WHEN j.id IS NULL OR j.stage = 'cancelled' THEN 'unfiltered' ELSE 'preparing' END, CASE WHEN j.stage = 'failed' THEN 'retry' WHEN j.id IS NULL OR j.stage = 'cancelled' THEN 'prepare' ELSE NULL END, j.stage, j.blocking_reason FROM episodes e JOIN podcasts p ON p.id = e.podcast_id LEFT JOIN episode_state s ON s.episode_id = e.id LEFT JOIN ad_removal_jobs j ON j.episode_id = e.id WHERE e.id = ?"
        );
        let conn = self.db.lock()?;
        let mut detail: EpisodeDetail = conn.query_row(&sql, params![id], |row| {
            Ok(EpisodeDetail {
                id: row.get(0)?,
                podcast_id: row.get(1)?,
                podcast_title: row.get(2)?,
                podcast_image: row.get(3)?,
                title: row.get(4)?,
                audio_url: row.get(5)?,
                duration_secs: row.get(6)?,
                published_at: row.get(7)?,
                image_url: row.get(8)?,
                position_secs: row.get(9)?,
                played_at: row.get(10)?,
                notes_html: row.get(11)?,
                archived_at: row.get(12)?,
                ad_removal_state: row.get(13)?,
                ad_removal_action: row.get(14)?,
                ad_removal_stage: row.get(15)?,
                ad_removal_blocking_reason: row.get(16)?,
                show_notes: vec![],
                ad_markers: vec![],
            })
        }).optional()?.ok_or(Error::NotFound)?;
        drop(conn);
        let store = JobStore::new(&self.db);
        if detail.ad_removal_stage.as_deref() == Some("ready") {
            detail.ad_markers = store
                .skip_ranges(id)
                .unwrap_or_default()
                .into_iter()
                .filter(|r| !r.disabled && r.start_time.is_finite() && r.start_time >= 0.0)
                .map(|r| EpisodeAdMarker { id: r.id, start_time: r.start_time })
                .collect();
        }
        detail.show_notes = store
            .show_notes(id)
            .unwrap_or_default()
            .into_iter()
            .map(|n| EpisodeShowNote {
                id: n.segment_id,
                start_time: n.start_time,
                title: n.title,
                summary: n.summary,
            })
            .collect();
        Ok(detail)
    }

    fn set_played(&self, id: i64) -> Result<(), Error> {
        self.require_episode(id)?;
        let now = db::now_unix();
        self.db.execute(
            "INSERT INTO episode_state (episode_id, played_at, updated_at) VALUES (?, ?, ?) ON CONFLICT(episode_id) DO UPDATE SET played_at = excluded.played_at, updated_at = excluded.updated_at",
            params![id, now, now],
        )?;
        self.show_notes.cancel(id);
        let store = JobStore::new(&self.db);
        if let Some(job) = store.job_for_episode(id).ok().flatten() {
            let _ = store.cancel(&job.id);
        }
        let _ = store.delete_episode_ad_data(id);
        Ok(())
    }

    fn clear_played(&self, id: i64) -> Result<(), Error> {
        self.require_episode(id)?;
        self.db.execute(
            "UPDATE episode_state SET played_at = NULL, archived_at = NULL, updated_at = ? WHERE episode_id = ?",
            params![db::now_unix(), id],
        )?;
        Ok(())
    }

    fn set_position(&self, id: i64, seconds: f64) -> Result<(), Error> {
        if !seconds.is_finite() || seconds < 0.0 {
            return Err(Error::Invalid("seconds must be >= 0".into()));
        }
        self.require_episode(id)?;
        self.db.execute(
            "INSERT INTO episode_state (episode_id, position_secs, updated_at) VALUES (?, ?, ?) ON CONFLICT (episode_id) DO UPDATE SET position_secs = excluded.position_secs, updated_at = excluded.updated_at",
            params![id, seconds, db::now_unix()],
        )?;
        Ok(())
    }

    fn require_episode(&self, id: i64) -> Result<(), Error> {
        self.db.scalar_i64("SELECT id FROM episodes WHERE id = ?", params![id])?.ok_or(Error::NotFound).map(|_| ())
    }

    fn next(&self, after: i64, context: &str) -> Result<Option<EpisodeItem>, Error> {
        let ready = self.listen_ready_sql();
        let conn = self.db.lock()?;
        let (published_at, podcast_id): (i64, i64) = conn
            .query_row("SELECT published_at, podcast_id FROM episodes WHERE id = ?", params![after], |r| Ok((r.get(0)?, r.get(1)?)))
            .optional()?
            .ok_or(Error::NotFound)?;
        let sql = if context == "show" {
            format!("{} WHERE s.played_at IS NULL AND s.archived_at IS NULL AND e.podcast_id = ?3 AND (e.published_at > ?1 OR (e.published_at = ?1 AND e.id > ?2)) ORDER BY e.published_at ASC, e.id ASC LIMIT 1", Self::EPISODE_SELECT)
        } else {
            format!("{} WHERE s.played_at IS NULL AND s.archived_at IS NULL AND {} {} AND (e.published_at < ?1 OR (e.published_at = ?1 AND e.id < ?2)) AND ?3 = ?3 ORDER BY e.published_at DESC, e.id DESC LIMIT 1", Self::EPISODE_SELECT, Self::IN_LISTEN, ready)
        };
        let mut stmt = conn.prepare(&sql)?;
        Ok(stmt.query_row(params![published_at, after, podcast_id], map_episode).optional()?)
    }

    fn settings(&self) -> Result<SettingsPayload, Error> {
        let conn = self.db.lock()?;
        let mut stmt = conn.prepare("SELECT key, value FROM settings")?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?.collect::<Result<Vec<_>, _>>()?;
        let mut speed = 1.0;
        let mut autoplay = true;
        for (k, v) in rows {
            if k == "speed" {
                speed = v.parse().unwrap_or(1.0);
            } else if k == "autoplay" {
                autoplay = v != "false";
            }
        }
        Ok(SettingsPayload { speed, autoplay })
    }

    fn save_settings(&self, settings: SettingsPayload) -> Result<(), Error> {
        if !(0.5..=3.0).contains(&settings.speed) {
            return Err(Error::Invalid("speed must be between 0.5 and 3.0".into()));
        }
        let conn = self.db.lock()?;
        db::set_setting(&conn, "speed", &settings.speed.to_string())?;
        db::set_setting(&conn, "autoplay", if settings.autoplay { "true" } else { "false" })?;
        Ok(())
    }

    fn setting(&self, key: &str) -> Option<String> {
        self.db.scalar_string("SELECT value FROM settings WHERE key = ?", params![key]).ok().flatten()
    }

    fn refresh_status(&self) -> Result<RefreshStatus, Error> {
        let conn = self.db.lock()?;
        let mut status = conn
            .query_row(
                "SELECT last_attempt_at, last_success_at, last_source, last_refreshed, last_errors FROM feed_refresh_state WHERE id = 1",
                [],
                |row| {
                    Ok(RefreshStatus {
                        last_attempt_at: row.get(0)?,
                        last_success_at: row.get(1)?,
                        last_source: row.get(2)?,
                        last_refreshed: row.get(3).unwrap_or(0),
                        last_errors: row.get(4).unwrap_or(0),
                        is_refreshing: None,
                    })
                },
            )
            .optional()?
            .unwrap_or_default();
        status.is_refreshing = Some(*self.refreshing.lock().unwrap());
        Ok(status)
    }

    fn refresh(&self, source: &str) -> Result<RefreshResult, Error> {
        *self.refreshing.lock().unwrap() = true;
        let started = db::now_unix();
        let _ = self.db.execute(
            "INSERT INTO feed_refresh_attempts (source, started_at, outcome) VALUES (?, ?, 'running')",
            params![source, started],
        );
        let result = self.refresh_inner(source);
        *self.refreshing.lock().unwrap() = false;
        let finished = db::now_unix();
        match &result {
            Ok(done) => {
                let _ = self.db.execute(
                    "UPDATE feed_refresh_attempts SET finished_at = ?, refreshed = ?, errors = ?, outcome = 'ok' WHERE outcome = 'running'",
                    params![finished, done.refreshed, done.errors],
                );
            }
            Err(_) => {
                let _ = self.db.execute(
                    "UPDATE feed_refresh_attempts SET finished_at = ?, refreshed = 0, errors = 1, outcome = 'error' WHERE outcome = 'running'",
                    params![finished],
                );
            }
        }
        result
    }

    fn refresh_inner(&self, source: &str) -> Result<RefreshResult, Error> {
        let ids: Vec<(i64, String)> = {
            let conn = self.db.lock()?;
            let mut stmt = conn.prepare("SELECT id, feed_url FROM podcasts WHERE is_subscribed = 1")?;
            let mapped = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
            let collected = mapped.collect::<Result<Vec<_>, _>>()?;
            collected
        };
        let mut refreshed = 0i64;
        let mut errors = 0i64;
        for (id, url) in ids {
            let validators = {
                let conn = self.db.lock()?;
                conn.query_row(
                    "SELECT etag, last_modified FROM feed_http_cache WHERE podcast_id = ?",
                    params![id],
                    |r| {
                        Ok(FeedValidators {
                            etag: r.get(0)?,
                            last_modified: r.get(1)?,
                        })
                    },
                )
                .optional()?
                .unwrap_or_default()
            };
            match self.fetcher.fetch(&url, &validators) {
                Ok(FeedFetchResponse::NotModified(next)) => {
                    refreshed += 1;
                    let conn = self.db.lock()?;
                    conn.execute(
                        "INSERT INTO feed_http_cache (podcast_id, etag, last_modified) VALUES (?, ?, ?) ON CONFLICT(podcast_id) DO UPDATE SET etag = excluded.etag, last_modified = excluded.last_modified",
                        params![id, next.etag, next.last_modified],
                    )?;
                }
                Ok(FeedFetchResponse::Data(data, next)) => match feeds::parse_feed(&data) {
                    Ok(feed) => {
                        let _ = self.db.with_transaction(|tx| {
                            upsert_podcast_meta(tx, id, &feed)?;
                            upsert_episodes(tx, id, &feed)?;
                            tx.execute(
                                "INSERT INTO feed_http_cache (podcast_id, etag, last_modified) VALUES (?, ?, ?) ON CONFLICT(podcast_id) DO UPDATE SET etag = excluded.etag, last_modified = excluded.last_modified",
                                params![id, next.etag, next.last_modified],
                            )?;
                            Ok(())
                        });
                        refreshed += 1;
                    }
                    Err(_) => errors += 1,
                },
                Err(_) => errors += 1,
            }
        }
        let now = db::now_unix();
        let conn = self.db.lock()?;
        conn.execute(
            "INSERT INTO feed_refresh_state (id, last_attempt_at, last_success_at, last_source, last_refreshed, last_errors) VALUES (1, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET last_attempt_at = excluded.last_attempt_at, last_success_at = excluded.last_success_at, last_source = excluded.last_source, last_refreshed = excluded.last_refreshed, last_errors = excluded.last_errors",
            params![now, now, source, refreshed, errors],
        )?;
        conn.execute(
            "INSERT INTO feed_refresh_runs (source, started_at, finished_at, refreshed, errors) VALUES (?, ?, ?, ?, ?)",
            params![source, now, now, refreshed, errors],
        )?;
        Ok(RefreshResult { refreshed, errors })
    }

    fn search(&self, query: &str) -> Result<SearchResults, Error> {
        let directory = self.directory();
        let podcasts = if directory.is_configured() {
            let mut pods = directory.search(query)?;
            let conn = self.db.lock()?;
            for p in &mut pods {
                let sub: Option<i64> = conn
                    .query_row("SELECT is_subscribed FROM podcasts WHERE feed_url = ?", params![p.feed_url], |r| r.get(0))
                    .optional()?;
                p.subscribed = sub == Some(1);
            }
            pods
        } else {
            vec![]
        };
        let expr = fts_query(query);
        let sql = format!("{} WHERE e.id IN (SELECT rowid FROM episodes_fts WHERE episodes_fts MATCH ? ORDER BY rank LIMIT ?) ORDER BY e.published_at DESC, e.id DESC", Self::EPISODE_SELECT);
        let conn = self.db.lock()?;
        let episodes = conn
            .prepare(&sql)
            .ok()
            .and_then(|mut stmt| stmt.query_map(params![expr, PAGE_SIZE], map_episode).ok().map(|m| m.filter_map(|r| r.ok()).collect()))
            .unwrap_or_default();
        Ok(SearchResults {
            directory_configured: directory.is_configured(),
            podcasts,
            episodes,
        })
    }

    fn export_opml(&self) -> Result<String, Error> {
        let conn = self.db.lock()?;
        let mut stmt = conn.prepare("SELECT title, feed_url FROM podcasts WHERE is_subscribed = 1 ORDER BY title COLLATE NOCASE")?;
        let shows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?.collect::<Result<Vec<_>, _>>()?;
        Ok(crate::opml::render(&shows))
    }

    fn import_opml(&self, xml: &str) -> Result<OpmlImportResult, Error> {
        let urls = crate::opml::parse(xml);
        let mut imported = 0;
        let mut skipped = 0;
        let mut failed = 0;
        for url in urls {
            match self.subscribe(&url) {
                Ok(_) => imported += 1,
                Err(Error::Conflict(_)) => skipped += 1,
                Err(_) => failed += 1,
            }
        }
        Ok(OpmlImportResult { imported, skipped, failed })
    }

    fn prepare_ad_removal(&self, id: i64) -> Result<crate::jobs::Job, Error> {
        if !self.credentials.has_key() {
            return Err(Error::Invalid("DeepSeek API key is required".into()));
        }
        self.require_episode(id)?;
        let store = JobStore::new(&self.db);
        if let Some(existing) = store.job_for_episode(id).map_err(Error::from)? {
            if existing.stage == JobStage::Failed {
                return Err(Error::Conflict("failed preparation must be retried".into()));
            }
            return Ok(existing);
        }
        store.enqueue(id).map_err(Error::from)
    }

    fn retry_ad_removal(&self, id: i64) -> Result<crate::jobs::Job, Error> {
        if !self.credentials.has_key() {
            return Err(Error::Invalid("DeepSeek API key is required".into()));
        }
        self.require_episode(id)?;
        let store = JobStore::new(&self.db);
        let existing = store.job_for_episode(id).map_err(Error::from)?.ok_or(Error::NotFound)?;
        if existing.stage != JobStage::Failed {
            return Err(Error::Conflict("preparation has not failed".into()));
        }
        store.retry(&existing.id).map_err(Error::from)
    }

    fn ad_removal_settings(&self) -> Result<AdRemovalSettingsPayload, Error> {
        let enabled = self.setting("ad_removal_enabled").as_deref() == Some("true");
        let cutoff = self.setting("ad_removal_enrollment_cutoff").and_then(|v| v.parse().ok());
        let deepseek_usage = UsageStore::new(&self.db).metrics().unwrap_or_else(|_| DeepSeekUsageMetricsPayload::empty(true));
        let conn = self.db.lock()?;
        let mut stmt = conn.prepare(
            "SELECT c.podcast_id, p.title, COUNT(*) FROM ad_corrections c JOIN podcasts p ON p.id = c.podcast_id WHERE c.active = 1 GROUP BY c.podcast_id ORDER BY p.title COLLATE NOCASE",
        )?;
        let corrections = stmt
            .query_map([], |row| {
                Ok(AdRemovalCorrectionCountPayload {
                    podcast_id: row.get(0)?,
                    podcast_title: row.get(1)?,
                    count: row.get(2)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        drop(stmt);
        let counts: (i64, i64) = conn
            .query_row(
                "SELECT
                    COALESCE(SUM(CASE WHEN j.stage = 'failed' THEN 1 ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN j.stage NOT IN ('ready', 'cancelled', 'failed') THEN 1 ELSE 0 END), 0)
                 FROM ad_removal_jobs j
                 JOIN episodes e ON e.id = j.episode_id
                 LEFT JOIN episode_state s ON s.episode_id = e.id
                 WHERE s.played_at IS NULL AND s.archived_at IS NULL",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap_or((0, 0));
        drop(conn);
        Ok(AdRemovalSettingsPayload {
            enabled,
            enrollment_cutoff: cutoff,
            cloud_classifier_configured: self.credentials.has_key(),
            model_repository: "deepseek-v4-pro".into(),
            model_revision: "api".into(),
            model_total_bytes: 0,
            model_downloaded_bytes: 0,
            model_download_state: "ready".into(),
            classifier_available: self.credentials.has_key(),
            classifier_unavailable_reason: if self.credentials.has_key() { None } else { Some("api_key_required".into()) },
            episode_storage_bytes: 0,
            episode_storage_limit_bytes: 10_000_000_000,
            minimum_free_bytes: 10_000_000_000,
            device_available_bytes: 20_000_000_000,
            corrections,
            deepseek_usage,
            failed_count: counts.0,
            preparing_count: counts.1,
            listen_requires_ready: enabled,
        })
    }

    fn ad_removal_statuses(&self, request: &HttpRequest) -> Result<AdRemovalStatusesPayload, Error> {
        let raw = request.query("episode_ids").unwrap_or_default();
        if raw.trim().is_empty() {
            return Err(Error::Invalid("episode_ids is required".into()));
        }
        let mut ids = Vec::new();
        for part in raw.split(',') {
            let id: i64 = part.parse().map_err(|_| Error::Invalid("episode_ids is invalid".into()))?;
            if id <= 0 {
                return Err(Error::Invalid("episode_ids is invalid".into()));
            }
            ids.push(id);
        }
        if ids.len() > 50 {
            return Err(Error::Invalid("episode_ids exceeds limit".into()));
        }
        let mut items = Vec::new();
        for id in ids {
            if let Some(ep) = self.episode_item(id)? {
                items.push(AdRemovalStatusItem {
                    id: ep.id,
                    ad_removal_state: ep.ad_removal_state,
                    ad_removal_action: ep.ad_removal_action,
                    ad_removal_stage: ep.ad_removal_stage,
                    ad_removal_blocking_reason: ep.ad_removal_blocking_reason,
                    ad_removal_completed_windows: None,
                    ad_removal_total_windows: None,
                });
            }
        }
        Ok(AdRemovalStatusesPayload { items })
    }

    fn car_bluetooth_settings(&self) -> CarBluetoothSettingsPayload {
        let routes = self.car_routes.lock().unwrap().clone();
        let keys = self.car_keys.lock().unwrap().clone();
        snapshot_car(&routes, &keys)
    }

    fn enroll_car(&self) -> Result<CarBluetoothSettingsPayload, Error> {
        let routes = self.car_routes.lock().unwrap().clone();
        let device = enrollable(&routes).ok_or_else(|| Error::Invalid("no enrollable Bluetooth output".into()))?;
        *self.car_keys.lock().unwrap() = vec![device.stable_device_key()];
        Ok(self.car_bluetooth_settings())
    }

    pub fn record_playback_progress(&self, episode_id: i64, seconds: f64) {
        let _ = self.set_position(episode_id, seconds);
    }

    fn save_deepseek_key(&self, key: &str) -> Result<(), Error> {
        self.credentials.save(key.to_string());
        let conn = self.db.lock()?;
        db::set_setting(&conn, "deepseek_api_key", key)?;
        Ok(())
    }

    pub fn start_runtime(self: &Arc<Self>) {
        let mut slot = self.runtime.lock().unwrap();
        if slot.is_some() {
            return;
        }
        self.runtime_stop.store(false, Ordering::SeqCst);
        let backend = self.clone();
        let stop = self.runtime_stop.clone();
        *slot = Some(std::thread::spawn(move || {
            while !stop.load(Ordering::SeqCst) {
                let _ = backend.run_pipeline_step();
                std::thread::sleep(std::time::Duration::from_millis(200));
            }
        }));
        let interval = self.pipeline.background_refresh_secs;
        if interval > 0 {
            let backend = self.clone();
            let stop = self.runtime_stop.clone();
            *self.refresh_runtime.lock().unwrap() = Some(std::thread::spawn(move || {
                let mut elapsed = 0u64;
                while !stop.load(Ordering::SeqCst) {
                    std::thread::sleep(std::time::Duration::from_secs(1));
                    elapsed += 1;
                    if elapsed < interval {
                        continue;
                    }
                    elapsed = 0;
                    let _ = backend.refresh("background");
                }
            }));
        }
    }

    pub fn stop_runtime(&self) {
        self.runtime_stop.store(true, Ordering::SeqCst);
        if let Some(handle) = self.runtime.lock().unwrap().take() {
            let _ = handle.join();
        }
        if let Some(handle) = self.refresh_runtime.lock().unwrap().take() {
            let _ = handle.join();
        }
    }

    pub fn run_pipeline_step(&self) -> Result<bool, Error> {
        if self.setting("ad_removal_enabled").as_deref() != Some("true") {
            return Ok(false);
        }
        let store = JobStore::new(&self.db).with_unbounded_retry(self.pipeline.unbounded_job_retry);
        let coordinator = crate::coordinator::Coordinator::new(&store)
            .skip_daily_limit(self.pipeline.skip_daily_classification_limit);
        let downloader = self.downloader.lock().unwrap().clone();
        let transcriber = self.transcriber.lock().unwrap().clone();
        let classifier = self.classifier.lock().unwrap().clone();
        let api_key = self.credentials.read().unwrap_or_default();
        let artifacts = &self.artifacts;
        let playback_active = self.playback_active();
        let ran = coordinator.run_next_stage(|stage, job| {
            if playback_active && matches!(stage, JobStage::Transcribing | JobStage::Classifying) {
                return Err("pause:playback_active".into());
            }
            let (audio_url, notes, duration) = self
                .episode_pipeline_meta(job.episode_id)
                .unwrap_or_else(|_| (String::new(), String::new(), None));
            pipeline::execute_stage(
                &store,
                artifacts,
                downloader.as_ref(),
                transcriber.as_ref(),
                classifier.as_ref(),
                &api_key,
                stage,
                job,
                &audio_url,
                &notes,
                duration,
                Some(&self.db),
            )
        })?;
        Ok(ran.is_some())
    }

    fn episode_pipeline_meta(&self, episode_id: i64) -> Result<(String, String, Option<i64>), Error> {
        let conn = self.db.lock()?;
        Ok(conn.query_row(
            "SELECT audio_url, notes_html, duration_secs FROM episodes WHERE id = ?",
            params![episode_id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )?)
    }
}

fn paginate<T>(mut rows: Vec<T>, offset: i64) -> Page<T> {
    if rows.len() as i64 > PAGE_SIZE {
        rows.truncate(PAGE_SIZE as usize);
        Page { items: rows, next_offset: Some(offset + PAGE_SIZE) }
    } else {
        Page { items: rows, next_offset: None }
    }
}

fn map_episode(row: &rusqlite::Row<'_>) -> rusqlite::Result<EpisodeItem> {
    Ok(EpisodeItem {
        id: row.get(0)?,
        podcast_id: row.get(1)?,
        podcast_title: row.get(2)?,
        podcast_image: row.get(3)?,
        title: row.get(4)?,
        audio_url: row.get(5)?,
        duration_secs: row.get(6)?,
        published_at: row.get(7)?,
        image_url: row.get(8)?,
        position_secs: row.get(9)?,
        played_at: row.get(10)?,
        ad_removal_state: row.get(11)?,
        ad_removal_action: row.get(12)?,
        ad_removal_stage: row.get(13)?,
        ad_removal_blocking_reason: row.get(14)?,
    })
}

fn map_show(row: &rusqlite::Row<'_>) -> rusqlite::Result<Show> {
    Ok(Show {
        id: row.get(0)?,
        feed_url: row.get(1)?,
        title: row.get(2)?,
        description: row.get(3)?,
        image_url: row.get(4)?,
        site_url: row.get(5)?,
        episode_count: row.get(6)?,
        unplayed_count: row.get(7)?,
    })
}

fn fts_query(value: &str) -> String {
    let tokens: Vec<String> = value
        .split_whitespace()
        .map(|t| format!("\"{}\"", t.replace('"', "\"\"")))
        .collect();
    if tokens.is_empty() {
        return String::new();
    }
    let mut parts = tokens;
    if let Some(last) = parts.last_mut() {
        *last = format!("{last}*");
    }
    parts.join(" ")
}

fn upsert_podcast_meta(tx: &rusqlite::Transaction<'_>, podcast_id: i64, feed: &ParsedFeed) -> Result<(), Error> {
    tx.execute(
        "UPDATE podcasts SET title = ?, description = ?, image_url = ?, site_url = ?, last_fetched_at = ? WHERE id = ?",
        params![feed.title, feed.description, feed.image_url, feed.site_url, db::now_unix(), podcast_id],
    )?;
    Ok(())
}

fn upsert_episodes(tx: &rusqlite::Transaction<'_>, podcast_id: i64, feed: &ParsedFeed) -> Result<i64, Error> {
    let mut n = 0;
    for episode in &feed.episodes {
        if upsert_episode(tx, podcast_id, episode)?.1 {
            n += 1;
        }
    }
    Ok(n)
}

fn upsert_episode(tx: &rusqlite::Transaction<'_>, podcast_id: i64, episode: &crate::feeds::ParsedEpisode) -> Result<(i64, bool), Error> {
    let existing: Option<i64> = tx
        .query_row("SELECT id FROM episodes WHERE podcast_id = ? AND guid = ?", params![podcast_id, episode.guid], |r| r.get(0))
        .optional()?;
    let (episode_id, inserted) = if let Some(id) = existing {
        tx.execute(
            "UPDATE episodes SET title = ?, notes_html = ?, audio_url = ?, duration_secs = ?, published_at = ?, image_url = ? WHERE id = ?",
            params![episode.title, episode.notes_html, episode.audio_url, episode.duration_secs, episode.published_at, episode.image_url, id],
        )?;
        (id, false)
    } else {
        tx.execute(
            "INSERT INTO episodes (podcast_id, guid, title, notes_html, audio_url, duration_secs, published_at, image_url) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            params![podcast_id, episode.guid, episode.title, episode.notes_html, episode.audio_url, episode.duration_secs, episode.published_at, episode.image_url],
        )?;
        let id = tx.last_insert_rowid();
        let enabled: Option<String> = tx.query_row("SELECT value FROM settings WHERE key = 'ad_removal_enabled'", [], |r| r.get(0)).optional()?;
        if enabled.as_deref() == Some("true") {
            let store_now = db::now_unix();
            let job_id = uuid::Uuid::new_v4().to_string().to_lowercase();
            let _ = tx.execute(
                "INSERT INTO ad_removal_jobs (id, episode_id, podcast_id, stage, attempt_count, enrolled_at, updated_at) VALUES (?, ?, ?, 'queued', 0, ?, ?)",
                params![job_id, id, podcast_id, store_now, store_now],
            );
        }
        (id, true)
    };
    tx.execute("DELETE FROM episodes_fts WHERE rowid = ?", params![episode_id])?;
    tx.execute(
        "INSERT INTO episodes_fts (rowid, title, notes) VALUES (?, ?, ?)",
        params![episode_id, episode.title, strip_html(&episode.notes_html)],
    )?;
    Ok((episode_id, inserted))
}

fn strip_html(html: &str) -> String {
    let mut out = String::new();
    let mut in_tag = false;
    for c in html.chars() {
        match c {
            '<' => in_tag = true,
            '>' => {
                in_tag = false;
                out.push(' ');
            }
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn accept_candidate(tx: &rusqlite::Transaction<'_>, id: i64) -> Result<(), Error> {
    let row = tx
        .query_row(
            "SELECT follow_id, feed_url, feed_title, feed_image_url, guid, title, description, audio_url, duration_secs, published_at, image_url FROM follow_candidates WHERE id = ?",
            params![id],
            |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, String>(4)?,
                    r.get::<_, String>(5)?,
                    r.get::<_, String>(6)?,
                    r.get::<_, String>(7)?,
                    r.get::<_, Option<i64>>(8)?,
                    r.get::<_, i64>(9)?,
                    r.get::<_, String>(10)?,
                ))
            },
        )
        .optional()?
        .ok_or(Error::NotFound)?;
    let (follow_id, feed_url, feed_title, feed_image, guid, title, description, audio_url, duration, published, image) = row;
    let podcast_id = if let Some(id) = tx.query_row("SELECT id FROM podcasts WHERE feed_url = ?", params![feed_url], |r| r.get(0)).optional()? {
        id
    } else {
        tx.execute(
            "INSERT INTO podcasts (feed_url, title, description, image_url, is_subscribed, created_at) VALUES (?, ?, ?, ?, 0, ?)",
            params![feed_url, feed_title, description, feed_image, db::now_unix()],
        )?;
        tx.last_insert_rowid()
    };
    let episode = crate::feeds::ParsedEpisode {
        guid,
        title,
        notes_html: description,
        audio_url,
        duration_secs: duration,
        published_at: published,
        image_url: image,
    };
    let episode_id = upsert_episode(tx, podcast_id, &episode)?.0;
    tx.execute(
        "INSERT INTO episode_state (episode_id, played_at, archived_at, updated_at) VALUES (?, NULL, NULL, ?) ON CONFLICT(episode_id) DO UPDATE SET played_at = NULL, archived_at = NULL, updated_at = excluded.updated_at",
        params![episode_id, db::now_unix()],
    )?;
    tx.execute("INSERT OR IGNORE INTO follow_episodes (follow_id, episode_id) VALUES (?, ?)", params![follow_id, episode_id])?;
    tx.execute("UPDATE follow_candidates SET status = 'accepted' WHERE id = ?", params![id])?;
    Ok(())
}

fn enrollable(routes: &[BluetoothRoute]) -> Option<&BluetoothRoute> {
    let candidates: Vec<_> = routes
        .iter()
        .filter(|r| is_bluetooth(&r.port_type) && device_kind(r) != "headphone" && device_kind(r) != "not_bluetooth")
        .collect();
    candidates
        .iter()
        .copied()
        .find(|r| r.port_type == "bluetoothA2DP" || r.port_type == "carAudio")
        .or_else(|| candidates.first().copied())
}

fn device_kind(route: &BluetoothRoute) -> &'static str {
    let n = route.name.to_lowercase();
    if route.port_type == "headphones" {
        return "headphone";
    }
    if route.port_type == "builtInSpeaker" || route.port_type == "builtInReceiver" {
        return "not_bluetooth";
    }
    if ["airpods", "earpods", "earbuds", "headset", "headphone", "jabra", "beats"].iter().any(|t| n.contains(t)) {
        return "headphone";
    }
    if route.port_type == "carAudio" || n.contains("tesla") {
        return "car";
    }
    if is_bluetooth(&route.port_type) {
        return "other_bluetooth";
    }
    "not_bluetooth"
}

fn is_bluetooth(port: &str) -> bool {
    matches!(port, "bluetoothA2DP" | "bluetoothHFP" | "bluetoothLE" | "carAudio")
}

fn snapshot_car(routes: &[BluetoothRoute], enrolled: &[String]) -> CarBluetoothSettingsPayload {
    let device = enrollable(routes);
    let key = device.map(|d| d.stable_device_key());
    CarBluetoothSettingsPayload {
        enrolled: !enrolled.is_empty(),
        enrollable: device.is_some(),
        current_enrolled: key.as_ref().is_some_and(|k| enrolled.contains(k)),
        current_device_name: device.map(|d| d.name.clone()),
        current_device_key: key,
    }
}

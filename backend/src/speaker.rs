//! Authenticated same-Wi-Fi Mac speaker. The backend owns processed media and playback.
mod transport;

use crate::error::Error;
use crate::http::{HttpRequest, HttpResponse};
use crate::jobs::valid_artifact_path;
use crate::Backend;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

pub use transport::{HelperTransport, MemoryTransport, SpeakerTransport, UnavailableTransport};

const MIN_RATE: f64 = 0.5;
const MAX_RATE: f64 = 3.0;
const STALE_MESSAGE: &str = "Playback session is out of date.";
const RESYNC_MESSAGE: &str = "This episode was updated on the Mac. Synchronize, then play again.";

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct SpeakerStatus {
    pub available: bool,
    pub connected: bool,
    pub name: Option<String>,
    pub error: Option<String>,
    pub episode_id: Option<i64>,
    pub artifact_hash: Option<String>,
    pub position: f64,
    pub duration: f64,
    pub rate: f64,
    pub paused: bool,
    pub ended: bool,
    pub session_id: Option<String>,
    pub generation: u64,
}

impl SpeakerStatus {
    fn unavailable(reason: &str, generation: u64, session_id: Option<String>) -> Self {
        Self {
            available: false,
            connected: false,
            name: None,
            error: Some(reason.to_string()),
            episode_id: None,
            artifact_hash: None,
            position: 0.0,
            duration: 0.0,
            rate: 1.0,
            paused: true,
            ended: false,
            session_id,
            generation,
        }
    }
}

struct SpeakerInner {
    transport: Arc<dyn SpeakerTransport>,
    session_id: Option<String>,
    generation: u64,
    episode_id: Option<i64>,
    artifact_hash: Option<String>,
    connected: bool,
    last_error: Option<String>,
    rate: f64,
}

impl SpeakerInner {
    fn new(transport: Arc<dyn SpeakerTransport>) -> Self {
        Self {
            transport,
            session_id: None,
            generation: 0,
            episode_id: None,
            artifact_hash: None,
            connected: false,
            last_error: None,
            rate: 1.0,
        }
    }

    fn sync_transport(&mut self) {
        if !self.connected {
            return;
        }
        let snap = self.transport.snapshot();
        if self.transport.alive() && snap.error.is_none() {
            return;
        }
        self.connected = false;
        self.last_error = snap.error.or_else(|| Some("Mac speaker disconnected.".into()));
    }

    fn status(&self) -> SpeakerStatus {
        if !self.transport.available() && !self.connected {
            let mut status = SpeakerStatus::unavailable(
                self.last_error
                    .as_deref()
                    .unwrap_or("Mac speaker is not available on this computer."),
                self.generation,
                self.session_id.clone(),
            );
            if self.last_error.is_none() {
                status.error = Some("Mac speaker is not available on this computer.".into());
            }
            return status;
        }
        let snap = self.transport.snapshot();
        SpeakerStatus {
            available: self.transport.available(),
            connected: self.connected,
            name: Some(self.transport.name().to_string()),
            error: self.last_error.clone().or(snap.error),
            episode_id: self.episode_id,
            artifact_hash: self.artifact_hash.clone(),
            position: snap.position.max(0.0),
            duration: if snap.duration > 0.0 { snap.duration } else { 0.0 },
            rate: if snap.rate > 0.0 { snap.rate } else { self.rate },
            paused: if self.connected { snap.paused } else { true },
            ended: snap.ended,
            session_id: self.session_id.clone(),
            generation: self.generation,
        }
    }

    fn status_from(&self, snap: &transport::TransportSnapshot) -> SpeakerStatus {
        let mut status = self.status();
        status.position = snap.position.max(0.0);
        status.duration = if snap.duration > 0.0 { snap.duration } else { status.duration };
        status.rate = if snap.rate > 0.0 { snap.rate } else { self.rate };
        status.paused = snap.paused;
        status.ended = snap.ended;
        status.error = self.last_error.clone().or(snap.error.clone());
        status
    }
}

pub struct Speaker {
    inner: Mutex<SpeakerInner>,
}

impl Speaker {
    pub fn platform() -> Self {
        Self::with_transport(platform_transport())
    }

    pub fn with_transport(transport: Arc<dyn SpeakerTransport>) -> Self {
        Self {
            inner: Mutex::new(SpeakerInner::new(transport)),
        }
    }

    pub fn set_transport(&self, transport: Arc<dyn SpeakerTransport>) {
        let mut inner = self.inner.lock().unwrap();
        let _ = inner.transport.stop();
        *inner = SpeakerInner::new(transport);
    }

    pub fn status(&self) -> SpeakerStatus {
        let mut inner = self.inner.lock().unwrap();
        inner.sync_transport();
        inner.status()
    }

    fn require_current(inner: &SpeakerInner, session_id: &str, generation: u64) -> Result<(), Error> {
        if inner.session_id.as_deref() != Some(session_id) || inner.generation != generation {
            return Err(Error::Conflict(STALE_MESSAGE.into()));
        }
        if !inner.connected {
            return Err(Error::Conflict("Mac speaker is not connected.".into()));
        }
        Ok(())
    }

    pub fn load(
        &self,
        episode_id: i64,
        artifact_hash: String,
        path: &Path,
        position: f64,
        rate: f64,
        session_id: String,
        generation: u64,
        playing: bool,
        mute: bool,
    ) -> Result<SpeakerStatus, Error> {
        let mut inner = self.inner.lock().unwrap();
        if generation != inner.generation {
            return Err(Error::Conflict(STALE_MESSAGE.into()));
        }
        if !inner.transport.available() {
            return Err(Error::Invalid(
                "Mac speaker is not available on this computer.".into(),
            ));
        }
        let rate = normalize_rate(rate);
        inner.generation = inner.generation.saturating_add(1).max(1);
        inner.connected = false;
        inner.session_id = None;
        inner.episode_id = None;
        inner.artifact_hash = None;
        inner.last_error = None;
        let snap = match inner.transport.load(path, position, rate, mute) {
            Ok(_snap) if playing => match inner.transport.play() {
                Ok(playing_snap) => playing_snap,
                Err(error) => {
                    return Err(Self::fail_load(&mut inner, error));
                }
            },
            Ok(snap) => snap,
            Err(error) => return Err(Self::fail_load(&mut inner, error)),
        };
        inner.session_id = Some(session_id);
        inner.episode_id = Some(episode_id);
        inner.artifact_hash = Some(artifact_hash);
        inner.connected = true;
        inner.last_error = None;
        inner.rate = rate;
        Ok(inner.status_from(&snap))
    }

    fn fail_load(inner: &mut SpeakerInner, error: Error) -> Error {
        let _ = inner.transport.stop();
        inner.connected = false;
        inner.session_id = None;
        inner.episode_id = None;
        inner.artifact_hash = None;
        inner.last_error = Some(sanitize_error(&error.to_string()));
        error
    }

    fn mutate<F>(&self, session_id: &str, generation: u64, op: F) -> Result<SpeakerStatus, Error>
    where
        F: FnOnce(&dyn SpeakerTransport) -> Result<transport::TransportSnapshot, Error>,
    {
        let mut inner = self.inner.lock().unwrap();
        Self::require_current(&inner, session_id, generation)?;
        if !inner.transport.alive() {
            inner.connected = false;
            inner.last_error = Some("Mac speaker disconnected.".into());
            return Err(Error::Invalid("Mac speaker disconnected.".into()));
        }
        let snap = op(&*inner.transport)?;
        if snap.rate > 0.0 {
            inner.rate = snap.rate;
        }
        Ok(inner.status_from(&snap))
    }

    pub fn play(&self, session_id: &str, generation: u64) -> Result<SpeakerStatus, Error> {
        self.mutate(session_id, generation, |t| t.play())
    }

    pub fn pause(&self, session_id: &str, generation: u64) -> Result<SpeakerStatus, Error> {
        self.mutate(session_id, generation, |t| t.pause())
    }

    pub fn seek(&self, session_id: &str, generation: u64, seconds: f64) -> Result<SpeakerStatus, Error> {
        self.mutate(session_id, generation, |t| t.seek(seconds))
    }

    pub fn set_rate(&self, session_id: &str, generation: u64, rate: f64) -> Result<SpeakerStatus, Error> {
        let rate = normalize_rate(rate);
        self.mutate(session_id, generation, |t| t.set_rate(rate))
    }

    pub fn disconnect(&self, session_id: &str, generation: u64) -> Result<SpeakerStatus, Error> {
        let mut inner = self.inner.lock().unwrap();
        Self::require_current(&inner, session_id, generation)?;
        let snap = inner.transport.stop().unwrap_or_else(|_| inner.transport.snapshot());
        inner.connected = false;
        inner.episode_id = None;
        inner.artifact_hash = None;
        inner.session_id = None;
        inner.last_error = None;
        inner.generation = inner.generation.saturating_add(1);
        let mut status = inner.status_from(&snap);
        status.connected = false;
        status.paused = true;
        status.ended = false;
        status.position = snap.position.max(0.0);
        Ok(status)
    }

    pub fn child_pid(&self) -> Option<i32> {
        self.inner.lock().unwrap().transport.child_pid()
    }

    pub fn stop(&self) {
        let mut inner = self.inner.lock().unwrap();
        let _ = inner.transport.stop();
        *inner = SpeakerInner::new(inner.transport.clone());
    }
}

impl Drop for Speaker {
    fn drop(&mut self) {
        self.stop();
    }
}

fn platform_transport() -> Arc<dyn SpeakerTransport> {
    #[cfg(target_os = "macos")]
    {
        match HelperTransport::new() {
            Ok(helper) => Arc::new(helper),
            Err(_) => Arc::new(UnavailableTransport),
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        Arc::new(UnavailableTransport)
    }
}

pub fn handle(backend: &Backend, request: &HttpRequest) -> Result<HttpResponse, Error> {
    let path = request.path();
    let method = request.method.as_str();
    if path == "/api/speaker/status" && method == "GET" {
        return Ok(HttpResponse::json(backend.speaker.status(), 200));
    }
    if method != "POST" {
        return Err(Error::NotFound);
    }
    match path.as_str() {
        "/api/speaker/load" => Ok(HttpResponse::json(load(backend, request)?, 200)),
        "/api/speaker/play" => Ok(HttpResponse::json(command(backend, request, Cmd::Play)?, 200)),
        "/api/speaker/pause" => Ok(HttpResponse::json(command(backend, request, Cmd::Pause)?, 200)),
        "/api/speaker/seek" => Ok(HttpResponse::json(command(backend, request, Cmd::Seek)?, 200)),
        "/api/speaker/rate" => Ok(HttpResponse::json(command(backend, request, Cmd::Rate)?, 200)),
        "/api/speaker/disconnect" => {
            Ok(HttpResponse::json(command(backend, request, Cmd::Disconnect)?, 200))
        }
        _ => Err(Error::NotFound),
    }
}

enum Cmd {
    Play,
    Pause,
    Seek,
    Rate,
    Disconnect,
}

fn load(backend: &Backend, request: &HttpRequest) -> Result<SpeakerStatus, Error> {
    let body = request.json_object()?;
    reject_remote_media(&body)?;
    let episode_id = parse_episode_id(body.get("episode_id"))?;
    let session_id = parse_session(body.get("session_id"))?;
    let generation = parse_generation(body.get("generation"))?;
    let artifact_hash = parse_artifact_hash(body.get("artifact_hash"))?;
    let position = parse_position(body.get("position"))?;
    let rate = parse_rate(body.get("rate"))?;
    let playing = body.get("playing").and_then(Value::as_bool).unwrap_or(false);
    let path = published_media_path(backend, episode_id, &artifact_hash)?;
    let mute = std::env::var("PODS_SPEAKER_MUTE").as_deref() == Ok("1");
    backend.speaker.load(
        episode_id,
        artifact_hash,
        &path,
        position,
        rate,
        session_id,
        generation,
        playing,
        mute,
    )
}

fn command(backend: &Backend, request: &HttpRequest, cmd: Cmd) -> Result<SpeakerStatus, Error> {
    let body = request.json_object()?;
    let session_id = parse_session(body.get("session_id"))?;
    let generation = parse_generation(body.get("generation"))?;
    match cmd {
        Cmd::Play => backend.speaker.play(&session_id, generation),
        Cmd::Pause => backend.speaker.pause(&session_id, generation),
        Cmd::Seek => {
            let seconds = parse_position(body.get("seconds"))?;
            backend.speaker.seek(&session_id, generation, seconds)
        }
        Cmd::Rate => {
            let rate = body
                .get("rate")
                .ok_or_else(|| Error::Invalid("rate is required".into()))?;
            let rate = parse_rate(Some(rate))?;
            backend.speaker.set_rate(&session_id, generation, rate)
        }
        Cmd::Disconnect => backend.speaker.disconnect(&session_id, generation),
    }
}

fn reject_remote_media(body: &Value) -> Result<(), Error> {
    for key in ["url", "src", "path", "blob", "audio_url", "file"] {
        if body.get(key).is_some() {
            return Err(Error::Invalid(
                "episode_id is required; remote media URLs are not accepted".into(),
            ));
        }
    }
    Ok(())
}

fn parse_episode_id(value: Option<&Value>) -> Result<i64, Error> {
    let id = value
        .and_then(Value::as_i64)
        .ok_or_else(|| Error::Invalid("episode_id is required".into()))?;
    if id <= 0 {
        return Err(Error::Invalid("episode_id is invalid".into()));
    }
    Ok(id)
}

fn parse_session(value: Option<&Value>) -> Result<String, Error> {
    let session = value
        .and_then(Value::as_str)
        .ok_or_else(|| Error::Invalid("session_id is required".into()))?;
    if session.is_empty()
        || session.len() > 128
        || !session
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-')
    {
        return Err(Error::Invalid("session_id is invalid".into()));
    }
    Ok(session.to_string())
}

fn parse_generation(value: Option<&Value>) -> Result<u64, Error> {
    value
        .and_then(Value::as_u64)
        .or_else(|| value.and_then(Value::as_i64).filter(|v| *v >= 0).map(|v| v as u64))
        .ok_or_else(|| Error::Invalid("generation is required".into()))
}

fn parse_artifact_hash(value: Option<&Value>) -> Result<String, Error> {
    let hash = value
        .and_then(Value::as_str)
        .ok_or_else(|| Error::Invalid("artifact_hash is required".into()))?;
    if hash.len() != 64 || !hash.bytes().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()) {
        return Err(Error::Invalid("artifact_hash is invalid".into()));
    }
    Ok(hash.to_string())
}

fn parse_position(value: Option<&Value>) -> Result<f64, Error> {
    if value.is_none() {
        return Ok(0.0);
    }
    let seconds = value
        .and_then(Value::as_f64)
        .ok_or_else(|| Error::Invalid("Position must be a finite number of seconds.".into()))?;
    if !seconds.is_finite() || seconds < 0.0 {
        return Err(Error::Invalid(
            "Position must be a finite number of seconds.".into(),
        ));
    }
    Ok(seconds)
}

fn parse_rate(value: Option<&Value>) -> Result<f64, Error> {
    if value.is_none() {
        return Ok(1.0);
    }
    let rate = value
        .and_then(Value::as_f64)
        .ok_or_else(|| Error::Invalid("Playback speed must be between 0.5 and 3.".into()))?;
    if !rate.is_finite() || rate < MIN_RATE || rate > MAX_RATE {
        return Err(Error::Invalid(
            "Playback speed must be between 0.5 and 3.".into(),
        ));
    }
    Ok(rate)
}

fn normalize_rate(rate: f64) -> f64 {
    if rate.is_finite() && (MIN_RATE..=MAX_RATE).contains(&rate) {
        rate
    } else {
        1.0
    }
}

pub fn published_media_path(
    backend: &Backend,
    episode_id: i64,
    expected_hash: &str,
) -> Result<PathBuf, Error> {
    let (manifest, _) = crate::browser::publication(backend, episode_id)?;
    if manifest.hash != expected_hash {
        return Err(Error::Conflict(RESYNC_MESSAGE.into()));
    }
    if manifest.hash.len() != 64
        || !manifest
            .hash
            .bytes()
            .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
    {
        return Err(Error::NotFound);
    }
    let relative = format!("published/{}.m4a", manifest.hash);
    if !valid_artifact_path(&relative) {
        return Err(Error::NotFound);
    }
    let path = backend.artifacts.url(&relative);
    let root = backend
        .artifacts
        .url("published")
        .canonicalize()
        .map_err(|_| Error::NotFound)?;
    let path = path.canonicalize().map_err(|_| Error::NotFound)?;
    if !path.starts_with(&root) || !path.is_file() {
        return Err(Error::NotFound);
    }
    Ok(path)
}

pub(crate) fn sanitize_error(message: &str) -> String {
    let lower = message.to_ascii_lowercase();
    if lower.contains("/users/")
        || lower.contains("/private/")
        || lower.contains("/var/")
        || lower.contains("/tmp/")
        || lower.contains("/work/")
        || lower.contains("pods.sqlite")
        || lower.contains(".m4a")
        || lower.contains("cookie")
        || lower.contains("token")
        || message.contains('\\')
        || message.contains('\0')
    {
        return "Mac could not play this episode.".into();
    }
    let trimmed: String = message.chars().take(160).collect();
    if trimmed.trim().is_empty() {
        "Mac speaker failed.".into()
    } else {
        trimmed
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::browser::{Interval, Manifest};
    use crate::db::Database;
    use crate::{DisabledDirectory, MockFeedFetcher};
    use serde_json::json;
    use sha2::{Digest, Sha256};
    use std::path::Path;
    use std::sync::Arc;
    use std::thread;
    use std::time::{Duration, Instant};

    fn speaker_fixture() -> (Backend, tempfile::TempDir, Manifest, Arc<MemoryTransport>) {
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
            timeline: vec![Interval {
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

    fn post(backend: &Backend, path: &str, body: Value) -> crate::HttpResponse {
        backend.handle(HttpRequest::new("POST", path).with_json(&body))
    }

    fn status_json(response: &crate::HttpResponse) -> Value {
        serde_json::from_slice(&response.body).unwrap()
    }

    fn load_body(hash: &str, generation: u64, session: &str) -> Value {
        json!({
            "episode_id": 1,
            "session_id": session,
            "generation": generation,
            "artifact_hash": hash,
        })
    }

    #[test]
    fn sanitize_error_strips_paths_and_tokens() {
        assert_eq!(
            sanitize_error("/Users/matt/Library/audio.m4a token=secret"),
            "Mac could not play this episode."
        );
        assert_eq!(sanitize_error(STALE_MESSAGE), STALE_MESSAGE);
    }

    #[test]
    fn memory_transport_does_not_fabricate_progress() {
        let memory = MemoryTransport::default();
        memory.set_duration(20.0);
        memory
            .load(Path::new("/tmp/synthetic.m4a"), 4.0, 1.5, true)
            .unwrap();
        memory.play().unwrap();
        thread::sleep(Duration::from_millis(30));
        let snap = memory.snapshot();
        assert_eq!(snap.position, 4.0);
        assert!(!snap.paused);
        memory.seek(9.0).unwrap();
        assert_eq!(memory.snapshot().position, 9.0);
    }

    #[test]
    fn load_rejects_caller_urls_and_unpublished_episodes() {
        let (backend, _temp, manifest, memory) = speaker_fixture();
        let rejected = post(
            &backend,
            "/api/speaker/load",
            json!({
                "episode_id": 1,
                "session_id": "sess-a",
                "generation": 0,
                "artifact_hash": manifest.hash,
                "url": "https://evil.example/x.mp3"
            }),
        );
        assert_eq!(rejected.status_code, 422);
        assert!(memory.last_path().is_none());
        let missing = post(
            &backend,
            "/api/speaker/load",
            json!({
                "episode_id": 2,
                "session_id": "sess-a",
                "generation": 0,
                "artifact_hash": manifest.hash
            }),
        );
        assert_eq!(missing.status_code, 404);
        let blob = post(
            &backend,
            "/api/speaker/load",
            json!({
                "episode_id": 1,
                "session_id": "sess-a",
                "generation": 0,
                "artifact_hash": manifest.hash,
                "src": "blob:https://pods.mcgiv.dev/1"
            }),
        );
        assert_eq!(blob.status_code, 422);
    }

    #[test]
    fn load_rejects_stale_artifact_hash() {
        let (backend, _temp, _, _) = speaker_fixture();
        let old = "ab".repeat(32);
        let response = post(
            &backend,
            "/api/speaker/load",
            json!({
                "episode_id": 1,
                "session_id": "sess-a",
                "generation": 0,
                "artifact_hash": old
            }),
        );
        assert_eq!(response.status_code, 409);
        let body = status_json(&response);
        assert_eq!(body["error"], RESYNC_MESSAGE);
        assert!(!String::from_utf8_lossy(&response.body).contains("/Users/"));
    }

    #[test]
    fn load_play_pause_seek_rate_use_generation() {
        let (backend, _temp, manifest, memory) = speaker_fixture();
        let loaded = post(
            &backend,
            "/api/speaker/load",
            json!({
                "episode_id": 1,
                "session_id": "sess-a",
                "generation": 0,
                "artifact_hash": manifest.hash,
                "position": 3.0,
                "rate": 1.5,
                "playing": true
            }),
        );
        assert_eq!(loaded.status_code, 200);
        let body = status_json(&loaded);
        assert_eq!(body["episode_id"], 1);
        assert_eq!(body["connected"], true);
        assert_eq!(body["generation"], 1);
        assert_eq!(body["paused"], false);
        assert_eq!(body["artifact_hash"], manifest.hash);
        let path = memory.last_path().unwrap();
        assert!(path.ends_with(format!("{}.m4a", manifest.hash)));
        assert!(path.to_string_lossy().contains("published"));
        let generation = body["generation"].as_u64().unwrap();
        let paused = post(
            &backend,
            "/api/speaker/pause",
            json!({"session_id": "sess-a", "generation": generation}),
        );
        assert_eq!(status_json(&paused)["paused"], true);
        let seek = post(
            &backend,
            "/api/speaker/seek",
            json!({"session_id": "sess-a", "generation": generation, "seconds": 8.0}),
        );
        assert_eq!(status_json(&seek)["position"], 8.0);
        let rate = post(
            &backend,
            "/api/speaker/rate",
            json!({"session_id": "sess-a", "generation": generation, "rate": 2.0}),
        );
        assert_eq!(status_json(&rate)["rate"], 2.0);
        let stale = post(
            &backend,
            "/api/speaker/play",
            json!({"session_id": "sess-a", "generation": 0}),
        );
        assert_eq!(stale.status_code, 409);
    }

    #[test]
    fn load_requires_matching_generation_and_rejects_replay() {
        let (backend, _temp, manifest, memory) = speaker_fixture();
        let first = status_json(&post(
            &backend,
            "/api/speaker/load",
            load_body(&manifest.hash, 0, "sess-a"),
        ));
        assert_eq!(first["generation"], 1);
        let replay = post(
            &backend,
            "/api/speaker/load",
            load_body(&manifest.hash, 0, "sess-a"),
        );
        assert_eq!(replay.status_code, 409);
        assert_eq!(memory.load_count(), 1);
        let next = post(
            &backend,
            "/api/speaker/load",
            json!({
                "episode_id": 1,
                "session_id": "sess-a",
                "generation": 1,
                "artifact_hash": manifest.hash,
                "playing": true
            }),
        );
        assert_eq!(next.status_code, 200);
        assert_eq!(status_json(&next)["generation"], 2);
        assert_eq!(memory.load_count(), 2);
    }

    #[test]
    fn takeover_requires_current_generation() {
        let (backend, _temp, manifest, _) = speaker_fixture();
        let first = status_json(&post(
            &backend,
            "/api/speaker/load",
            json!({
                "episode_id": 1,
                "session_id": "sess-a",
                "generation": 0,
                "artifact_hash": manifest.hash,
                "playing": true
            }),
        ));
        let denied = post(
            &backend,
            "/api/speaker/load",
            load_body(&manifest.hash, 0, "sess-b"),
        );
        assert_eq!(denied.status_code, 409);
        let second = status_json(&post(
            &backend,
            "/api/speaker/load",
            json!({
                "episode_id": 1,
                "session_id": "sess-b",
                "generation": first["generation"],
                "artifact_hash": manifest.hash,
                "position": 5.0
            }),
        ));
        assert_eq!(second["session_id"], "sess-b");
        assert!(second["generation"].as_u64().unwrap() > first["generation"].as_u64().unwrap());
        let stale = post(
            &backend,
            "/api/speaker/pause",
            json!({
                "session_id": "sess-a",
                "generation": first["generation"]
            }),
        );
        assert_eq!(stale.status_code, 409);
        let ok = post(
            &backend,
            "/api/speaker/play",
            json!({
                "session_id": "sess-b",
                "generation": second["generation"]
            }),
        );
        assert_eq!(ok.status_code, 200);
    }

    #[test]
    fn concurrent_stale_load_cannot_reclaim_newer_playback() {
        let (backend, _temp, manifest, memory) = speaker_fixture();
        let backend = Arc::new(backend);
        let hold = memory.arm_load_hold();
        let hash = manifest.hash.clone();
        let first_backend = backend.clone();
        let first = thread::spawn(move || {
            first_backend.handle(
                HttpRequest::new("POST", "/api/speaker/load").with_json(&json!({
                    "episode_id": 1,
                    "session_id": "sess-a",
                    "generation": 0,
                    "artifact_hash": hash,
                    "playing": true
                })),
            )
        });
        hold.wait_entered();
        let stale_backend = backend.clone();
        let stale_hash = manifest.hash.clone();
        let stale = thread::spawn(move || {
            stale_backend.handle(
                HttpRequest::new("POST", "/api/speaker/load").with_json(&json!({
                    "episode_id": 1,
                    "session_id": "sess-old",
                    "generation": 0,
                    "artifact_hash": stale_hash
                })),
            )
        });
        let pause_backend = backend.clone();
        let pause = thread::spawn(move || {
            pause_backend.handle(
                HttpRequest::new("POST", "/api/speaker/pause").with_json(&json!({
                    "session_id": "sess-a",
                    "generation": 0
                })),
            )
        });
        hold.release();
        let first = first.join().unwrap();
        let stale = stale.join().unwrap();
        let pause = pause.join().unwrap();
        assert_eq!(first.status_code, 200);
        let body = status_json(&first);
        assert_eq!(body["session_id"], "sess-a");
        assert_eq!(body["paused"], false);
        assert_eq!(stale.status_code, 409);
        assert_eq!(pause.status_code, 409);
        assert_eq!(memory.load_count(), 1);
        assert!(!memory.snapshot().paused);
        assert_eq!(backend.speaker.status().session_id.as_deref(), Some("sess-a"));
    }

    #[test]
    fn disconnect_stops_transport_and_rejects_stale_commands() {
        let (backend, _temp, manifest, memory) = speaker_fixture();
        let loaded = status_json(&post(
            &backend,
            "/api/speaker/load",
            json!({
                "episode_id": 1,
                "session_id": "sess-a",
                "generation": 0,
                "artifact_hash": manifest.hash,
                "playing": true
            }),
        ));
        let disconnected = post(
            &backend,
            "/api/speaker/disconnect",
            json!({
                "session_id": "sess-a",
                "generation": loaded["generation"]
            }),
        );
        assert_eq!(disconnected.status_code, 200);
        let body = status_json(&disconnected);
        assert_eq!(body["connected"], false);
        assert!(memory.stopped());
        let play = post(
            &backend,
            "/api/speaker/play",
            json!({
                "session_id": "sess-a",
                "generation": loaded["generation"]
            }),
        );
        assert_eq!(play.status_code, 409);
        let replay = post(
            &backend,
            "/api/speaker/load",
            load_body(&manifest.hash, loaded["generation"].as_u64().unwrap(), "sess-a"),
        );
        assert_eq!(replay.status_code, 409);
        let again = post(
            &backend,
            "/api/speaker/load",
            load_body(&manifest.hash, body["generation"].as_u64().unwrap(), "sess-a"),
        );
        assert_eq!(again.status_code, 200);
    }

    #[test]
    fn unavailable_transport_reports_cleanly() {
        let (backend, _temp, manifest, _) = speaker_fixture();
        backend.set_speaker_transport(Arc::new(UnavailableTransport));
        let status = backend.handle(HttpRequest::new("GET", "/api/speaker/status"));
        assert_eq!(status.status_code, 200);
        let body = status_json(&status);
        assert_eq!(body["available"], false);
        assert_eq!(body["connected"], false);
        assert_eq!(
            body["error"],
            "Mac speaker is not available on this computer."
        );
        let load = post(
            &backend,
            "/api/speaker/load",
            load_body(&manifest.hash, 0, "sess-a"),
        );
        assert_eq!(load.status_code, 422);
        let dump = String::from_utf8_lossy(&load.body);
        assert!(!dump.contains("/Users/"));
        assert!(!dump.contains("published/"));
    }

    #[test]
    fn invalid_rate_and_position_are_rejected() {
        let (backend, _temp, manifest, _) = speaker_fixture();
        let loaded = status_json(&post(
            &backend,
            "/api/speaker/load",
            load_body(&manifest.hash, 0, "sess-a"),
        ));
        let generation = loaded["generation"].as_u64().unwrap();
        assert_eq!(
            post(
                &backend,
                "/api/speaker/rate",
                json!({"session_id": "sess-a", "generation": generation, "rate": 9.0})
            )
            .status_code,
            422
        );
        assert_eq!(
            post(
                &backend,
                "/api/speaker/seek",
                json!({"session_id": "sess-a", "generation": generation, "seconds": -1.0})
            )
            .status_code,
            422
        );
        assert_eq!(
            post(
                &backend,
                "/api/speaker/load",
                json!({"episode_id": 0, "session_id": "sess-a", "generation": 0, "artifact_hash": manifest.hash})
            )
            .status_code,
            422
        );
    }

    #[test]
    fn failed_replacement_invalidates_old_session_and_stops_audio() {
        let (backend, _temp, manifest, memory) = speaker_fixture();
        let first = status_json(&post(
            &backend,
            "/api/speaker/load",
            json!({
                "episode_id": 1,
                "session_id": "sess-a",
                "generation": 0,
                "artifact_hash": manifest.hash,
                "playing": true
            }),
        ));
        assert_eq!(first["connected"], true);
        memory.fail_next_load();
        let failed = post(
            &backend,
            "/api/speaker/load",
            json!({
                "episode_id": 1,
                "session_id": "sess-a",
                "generation": first["generation"],
                "artifact_hash": manifest.hash,
                "playing": true
            }),
        );
        assert_eq!(failed.status_code, 422);
        let pause = post(
            &backend,
            "/api/speaker/pause",
            json!({
                "session_id": "sess-a",
                "generation": first["generation"]
            }),
        );
        assert_eq!(pause.status_code, 409);
        let status = status_json(&backend.handle(HttpRequest::new("GET", "/api/speaker/status")));
        assert_eq!(status["connected"], false);
        assert_eq!(status["paused"], true);
        assert!(memory.stopped());
        assert!(memory.snapshot().paused);
    }

    #[test]
    fn status_reports_disconnected_when_transport_dies() {
        let (backend, _temp, manifest, memory) = speaker_fixture();
        post(
            &backend,
            "/api/speaker/load",
            json!({
                "episode_id": 1,
                "session_id": "sess-a",
                "generation": 0,
                "artifact_hash": manifest.hash,
                "playing": true
            }),
        );
        memory.set_alive(false);
        memory.set_error("Mac speaker disconnected.");
        let status = status_json(&backend.handle(HttpRequest::new("GET", "/api/speaker/status")));
        assert_eq!(status["connected"], false);
        assert_eq!(status["paused"], true);
        assert_eq!(status["error"], "Mac speaker disconnected.");
    }

    #[test]
    fn disconnect_returns_last_known_position() {
        let (backend, _temp, manifest, _) = speaker_fixture();
        let loaded = status_json(&post(
            &backend,
            "/api/speaker/load",
            json!({
                "episode_id": 1,
                "session_id": "sess-a",
                "generation": 0,
                "artifact_hash": manifest.hash,
                "position": 11.0,
                "playing": true
            }),
        ));
        let disconnected = status_json(&post(
            &backend,
            "/api/speaker/disconnect",
            json!({
                "session_id": "sess-a",
                "generation": loaded["generation"]
            }),
        ));
        assert_eq!(disconnected["connected"], false);
        assert_eq!(disconnected["paused"], true);
        assert_eq!(disconnected["position"], 11.0);
    }

    #[test]
    fn play_after_dead_transport_does_not_load() {
        let (backend, _temp, manifest, memory) = speaker_fixture();
        let loaded = status_json(&post(
            &backend,
            "/api/speaker/load",
            json!({
                "episode_id": 1,
                "session_id": "sess-a",
                "generation": 0,
                "artifact_hash": manifest.hash,
                "playing": true
            }),
        ));
        memory.set_alive(false);
        let play = post(
            &backend,
            "/api/speaker/play",
            json!({
                "session_id": "sess-a",
                "generation": loaded["generation"]
            }),
        );
        assert_eq!(play.status_code, 422);
        assert_eq!(memory.load_count(), 1);
    }

    #[cfg(target_os = "macos")]
    fn write_silent_wav(path: &Path, seconds: f64) {
        let sample_rate: u32 = 8000;
        let n = (seconds * sample_rate as f64) as u32;
        let data_bytes = n * 2;
        let mut buf = Vec::new();
        buf.extend(b"RIFF");
        buf.extend(&(36 + data_bytes).to_le_bytes());
        buf.extend(b"WAVE");
        buf.extend(b"fmt ");
        buf.extend(&16u32.to_le_bytes());
        buf.extend(&1u16.to_le_bytes());
        buf.extend(&1u16.to_le_bytes());
        buf.extend(&sample_rate.to_le_bytes());
        buf.extend(&(sample_rate * 2).to_le_bytes());
        buf.extend(&2u16.to_le_bytes());
        buf.extend(&16u16.to_le_bytes());
        buf.extend(b"data");
        buf.extend(&data_bytes.to_le_bytes());
        buf.extend(vec![0u8; data_bytes as usize]);
        std::fs::write(path, buf).unwrap();
    }

    #[cfg(target_os = "macos")]
    fn process_exists(pid: i32) -> bool {
        unsafe { libc::kill(pid, 0) == 0 }
    }

    #[cfg(target_os = "macos")]
    fn process_path(pid: i32) -> Option<String> {
        let mut buf = [0u8; 4096];
        let n = unsafe { libc::proc_pidpath(pid, buf.as_mut_ptr().cast(), buf.len() as u32) };
        if n <= 0 {
            return None;
        }
        std::str::from_utf8(&buf[..n as usize]).ok().map(str::to_owned)
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn helper_plays_synthetic_wav_silently_and_cleans_up() {
        let dir = tempfile::tempdir().unwrap();
        let short = dir.path().join("short.wav");
        let long = dir.path().join("long.wav");
        write_silent_wav(&short, 0.4);
        write_silent_wav(&long, 0.9);
        let helper = HelperTransport::new().expect("extract helper");
        let first = helper.load(&short, 0.0, 1.0, true).expect("load short");
        assert!(first.duration > 0.2, "first load must report real duration");
        let helper_path = process_path(helper.child_pid().expect("helper pid")).expect("helper path");
        assert!(
            helper_path.contains(".app/Contents/MacOS/"),
            "helper must run from an app bundle, got {helper_path}"
        );
        let app_name = std::path::Path::new(&helper_path)
            .parent()
            .and_then(|p| p.parent())
            .and_then(|p| p.parent())
            .and_then(|p| p.file_name())
            .and_then(|n| n.to_str())
            .unwrap_or("");
        let stem = app_name.strip_suffix(".app").unwrap_or("");
        assert_eq!(stem.len(), 64, "must reuse the canonical helper bundle, got {app_name}");
        assert!(
            stem.chars().all(|c| c.is_ascii_hexdigit()),
            "must reuse the canonical helper bundle, got {app_name}"
        );
        let reused = HelperTransport::new().expect("reuse helper cache");
        reused.load(&short, 0.0, 1.0, true).expect("load from cached bundle");
        let reused_path = process_path(reused.child_pid().expect("reused pid")).expect("reused path");
        assert_eq!(
            std::path::Path::new(&helper_path).parent().unwrap().parent().unwrap().parent().unwrap(),
            std::path::Path::new(&reused_path).parent().unwrap().parent().unwrap().parent().unwrap(),
            "second extract must reuse the signed bundle"
        );
        drop(reused);
        helper.play().expect("play");
        let start = Instant::now();
        let mut saw_end = false;
        while start.elapsed() < Duration::from_secs(4) {
            if helper.snapshot().ended {
                saw_end = true;
                break;
            }
            thread::sleep(Duration::from_millis(40));
        }
        assert!(saw_end, "helper must report ended for short synthetic audio");

        let second = helper.load(&long, 0.0, 1.0, true).expect("load long");
        assert!(
            second.duration > first.duration,
            "second load must wait for its own duration, not the cached first duration"
        );
        helper.play().expect("play long");
        let paused = helper.pause().expect("pause");
        assert!(paused.paused);
        let sought = helper.seek(0.1).expect("seek");
        assert!(sought.position >= 0.05);
        let stopped = helper.stop().expect("stop");
        assert!(
            stopped.position >= 0.05,
            "stop must keep last actual position, got {}",
            stopped.position
        );
        assert!(stopped.paused);
        let after_stop = helper.load(&long, stopped.position, 1.0, true).expect("load after stop");
        assert!(after_stop.duration > 0.2);
        helper.play().expect("play after stop");
        let rated = helper.set_rate(1.5).expect("rate");
        assert!(
            (rated.rate - 1.5).abs() < 0.01,
            "helper must ack the requested rate, got {}",
            rated.rate
        );

        let missing = dir.path().join("missing.wav");
        assert!(helper.load(&missing, 0.0, 1.0, true).is_err());

        let pid = helper.child_pid().expect("helper pid");
        unsafe {
            libc::kill(pid, libc::SIGKILL);
        }
        let start = Instant::now();
        while start.elapsed() < Duration::from_secs(2) && process_exists(pid) {
            thread::sleep(Duration::from_millis(40));
        }
        assert!(helper.play().is_err(), "play must not respawn an empty helper");
        let restarted = helper.load(&short, 0.0, 1.0, true).expect("reload same helper");
        assert!(restarted.duration > 0.2, "same helper must play after a crash");
        helper.play().expect("play after restart");

        let helper = HelperTransport::new().expect("extract helper");
        helper.load(&short, 0.0, 1.0, true).expect("reload");
        let pid = helper.child_pid().expect("helper pid");
        assert!(process_exists(pid));
        drop(helper);
        let start = Instant::now();
        while start.elapsed() < Duration::from_secs(2) && process_exists(pid) {
            thread::sleep(Duration::from_millis(50));
        }
        assert!(!process_exists(pid), "helper must not remain as an orphan");
    }
}

//! Authenticated browser publication and transactional offline synchronization.
use crate::{Backend, Error, HttpRequest, HttpResponse};
use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::io::{Read, Seek, SeekFrom};

pub const ORIGIN: &str = "https://pods.mcgiv.dev";
pub const CHUNK_SIZE: usize = 1024 * 1024;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Interval {
    pub original_start: f64,
    pub original_end: f64,
    pub processed_start: f64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Manifest {
    pub version: u32,
    pub episode_id: i64,
    pub hash: String,
    pub source_hash: String,
    pub bytes: u64,
    pub duration: f64,
    pub chunk_size: usize,
    pub chunks: Vec<String>,
    pub timeline: Vec<Interval>,
    pub model: String,
    pub pipeline_version: String,
    /// `video` publishes an MP4. Empty means the existing AAC/M4A audio file.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub media: String,
    #[serde(default, skip_serializing_if = "is_zero_u32")]
    pub width: u32,
    #[serde(default, skip_serializing_if = "is_zero_u32")]
    pub height: u32,
    /// Short Listen title. Empty keeps the feed title.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub listen_title: String,
}

fn is_zero_u32(value: &u32) -> bool {
    *value == 0
}

impl Default for Manifest {
    fn default() -> Self {
        Self {
            version: 1,
            episode_id: 0,
            hash: String::new(),
            source_hash: String::new(),
            bytes: 0,
            duration: 0.0,
            chunk_size: CHUNK_SIZE,
            chunks: Vec::new(),
            timeline: Vec::new(),
            model: String::new(),
            pipeline_version: String::new(),
            media: String::new(),
            width: 0,
            height: 0,
            listen_title: String::new(),
        }
    }
}

pub fn media_extension(manifest: &Manifest) -> &'static str {
    if manifest.media == "video" {
        "mp4"
    } else {
        "m4a"
    }
}

pub fn media_url(manifest: &Manifest) -> String {
    format!("/_media/{}.{}", manifest.hash, media_extension(manifest))
}

pub fn original_time(timeline: &[Interval], seconds: f64) -> f64 {
    for span in timeline {
        let end = span.processed_start + span.original_end - span.original_start;
        if seconds < end {
            return span.original_start + (seconds - span.processed_start).max(0.0);
        }
    }
    timeline.last().map(|s| s.original_end).unwrap_or(0.0)
}

pub fn processed_time(timeline: &[Interval], seconds: f64) -> f64 {
    for span in timeline {
        if seconds < span.original_end {
            return span.processed_start + (seconds - span.original_start).max(0.0);
        }
    }
    timeline
        .last()
        .map(|s| s.processed_start + s.original_end - s.original_start)
        .unwrap_or(0.0)
}

pub fn handle(backend: &Backend, request: &HttpRequest) -> HttpResponse {
    let origin = std::env::var("PODS_BROWSER_ORIGIN").unwrap_or_else(|_| ORIGIN.into());
    let supplied = request.header("origin");
    if supplied.is_some() && supplied != Some(origin.as_str()) {
        return HttpResponse::error(Error::Forbidden("untrusted request origin".into()));
    }
    let response = if request.method == "OPTIONS" {
        if supplied != Some(origin.as_str()) {
            HttpResponse::error(Error::Forbidden("origin required".into()))
        } else {
            HttpResponse::no_content()
                .with_header(
                    "access-control-allow-methods",
                    "GET, HEAD, POST, PUT, DELETE, OPTIONS",
                )
                .with_header(
                    "access-control-allow-headers",
                    "content-type, range, if-range, if-none-match, x-pods-client-id, x-pods-device, x-pods-voice-id",
                )
                .with_header("access-control-allow-private-network", "true")
        }
    } else {
        match route(backend, request) {
            Ok(response) => response,
            Err(error) => HttpResponse::error(error),
        }
    };
    response
        .with_header("access-control-allow-origin", origin)
        .with_header("access-control-allow-credentials", "true")
        .with_header(
            "access-control-expose-headers",
            "etag, content-range, content-length, accept-ranges",
        )
        .with_header("vary", "Origin")
        .with_header("cache-control", "no-store")
}

const LIBRARY_PASTE: &str = "Paste a podcast feed, a channel, or a video.";

fn route(backend: &Backend, request: &HttpRequest) -> Result<HttpResponse, Error> {
    if request.method == "POST" && request.path() == "/api/internal/library" {
        if request.header("origin").is_some() {
            return Err(Error::Forbidden("untrusted request origin".into()));
        }
        let url = request
            .json_object()?
            .get("url")
            .and_then(Value::as_str)
            .ok_or_else(|| Error::Invalid("url is required".into()))?
            .to_string();
        let kind = ingest_library_url(backend, &url)?;
        return Ok(HttpResponse::json(json!({ "kind": kind }), 201));
    }
    crate::auth::require_session(&backend.auth, &backend.db, request)?;
    let path = request.path();
    if path.starts_with("/api/auth/") {
        return Ok(backend.handle_legacy(request));
    }
    if request.method == "GET" && path == "/api/sync" {
        let body = snapshot(backend)?;
        record_pull_device(backend, request)?;
        return Ok(HttpResponse::json(body, 200));
    }
    if path == "/api/sync/actions" && request.method == "POST" {
        let payload = request.json_object()?;
        let result = apply_actions(backend, payload.clone())?;
        record_action_device(backend, &payload)?;
        return Ok(HttpResponse::json(result, 200));
    }
    // Spoken feedback uploads are binary. They stay off the JSON action channel.
    if path == "/api/feedback/voice" || path.starts_with("/api/feedback/voice/") {
        return crate::voice::handle(backend, request);
    }
    if path.starts_with("/api/speaker") {
        return crate::speaker::handle(backend, request);
    }
    if path == "/api/status" && request.method == "GET" {
        let conn = backend.db.lock()?;
        let pending: i64 =
            conn.query_row("SELECT COUNT(*) FROM browser_pending_jobs", [], |r| {
                r.get(0)
            })?;
        let failed: i64 = conn.query_row(
            "SELECT COUNT(*) FROM browser_pending_jobs WHERE error IS NOT NULL",
            [],
            |r| r.get(0),
        )?;
        let revision: i64 =
            conn.query_row("SELECT revision FROM browser_clock", [], |r| r.get(0))?;
        return Ok(HttpResponse::json(
            json!({"available":true,"revision":revision,"pending":pending,"failed":failed,
            "model":crate::local_worker::MODEL,"storage":crate::local_worker::storage_status(backend),
            "memory":crate::memory_gate::status_json()}),
            200,
        ));
    }
    if let Some(hash) = path.strip_prefix("/api/artifacts/") {
        return serve_artifact(backend, request, hash);
    }
    let parts: Vec<_> = path.split('/').collect();
    if parts.len() == 5 && parts[2] == "episodes" {
        let id: i64 = parts[3].parse().map_err(|_| Error::NotFound)?;
        if parts[4] == "artifact-manifest" && request.method == "GET" {
            return Ok(HttpResponse::json(publication(backend, id)?.0, 200));
        }
        if parts[4] == "show-notes" && request.method == "POST" {
            let (_, notes) = publication(backend, id)?;
            if notes.as_array().is_some_and(|a| !a.is_empty()) {
                return Ok(HttpResponse::json(notes, 200));
            }
            backend.db.execute(
                "UPDATE browser_jobs SET next_retry_at=0 WHERE episode_id=?",
                [id],
            )?;
            return Ok(HttpResponse::json(json!({"state":"queued"}), 202));
        }
    }
    // Browser reads all episode data through the publication snapshot. Never return legacy
    // original URLs, feed-preview episodes, or unprocessed job details through another route.
    let allowed = (request.method == "GET"
        && matches!(
            path.as_str(),
            "/api/settings" | "/api/refresh-status" | "/api/opml"
        ))
        || (request.method == "POST" && path == "/api/refresh");
    if allowed {
        return Ok(backend.handle_legacy(request));
    }
    if path == "/api/search" && request.method == "GET" {
        let response = backend.handle_legacy(request);
        let mut body: Value = serde_json::from_slice(&response.body).unwrap_or(json!({}));
        if body.is_object() {
            body["episodes"] = json!([]);
        }
        return Ok(HttpResponse::json(body, response.status_code));
    }
    Err(Error::NotFound)
}

/// Client-visible publications require finished show notes.
const NOTES_READY_SQL: &str = "json_array_length(b.notes_json) > 0";

pub fn publication(backend: &Backend, id: i64) -> Result<(Manifest, Value), Error> {
    publication_on(&*backend.db.lock()?, id)
}

fn publication_on(conn: &rusqlite::Connection, id: i64) -> Result<(Manifest, Value), Error> {
    let pair: Option<(String, String)> = conn.query_row(
        &format!("SELECT b.manifest_json,b.notes_json FROM browser_publications b JOIN browser_episode_catalog e ON e.id=b.episode_id
         JOIN podcasts p ON p.id=e.podcast_id LEFT JOIN episode_state s ON s.episode_id=e.id
         WHERE b.episode_id=? AND {NOTES_READY_SQL} AND (p.is_subscribed=1 OR s.played_at IS NOT NULL OR EXISTS(SELECT 1 FROM listen_episodes WHERE episode_id=e.id))"),
        [id], |r| Ok((r.get(0)?, r.get(1)?))).optional()?;
    let (manifest, notes) = pair.ok_or(Error::NotFound)?;
    Ok((
        serde_json::from_str(&manifest)
            .map_err(|_| Error::Invalid("invalid publication".into()))?,
        serde_json::from_str(&notes).map_err(|_| Error::Invalid("invalid notes".into()))?,
    ))
}

fn persisted_refresh_status(conn: &rusqlite::Connection) -> Result<Value, Error> {
    // Durable snapshots publish saved history only. Live is_refreshing is process-local
    // and becomes stale the moment the phone stores the snapshot.
    Ok(conn
        .query_row(
            "SELECT last_attempt_at, last_success_at, last_source, last_refreshed, last_errors FROM feed_refresh_state WHERE id = 1",
            [],
            |row| {
                Ok(json!({
                    "last_attempt_at": row.get::<_, Option<i64>>(0)?,
                    "last_success_at": row.get::<_, Option<i64>>(1)?,
                    "last_source": row.get::<_, Option<String>>(2)?,
                    "last_refreshed": row.get::<_, i64>(3)?,
                    "last_errors": row.get::<_, i64>(4)?,
                    "is_refreshing": false,
                }))
            },
        )
        .optional()?
        .unwrap_or_else(|| {
            json!({
                "last_attempt_at": null,
                "last_success_at": null,
                "last_source": null,
                "last_refreshed": 0,
                "last_errors": 0,
                "is_refreshing": false,
            })
        }))
}

pub fn snapshot(backend: &Backend) -> Result<Value, Error> {
    let storage = crate::local_worker::storage_status(backend);
    backend.db.with_transaction(|conn| {
    let writers = conn.prepare("SELECT entity,field,device,updated_at FROM browser_field_writers")?
        .query_map([], |r| Ok((format!("{}:{}",r.get::<_,String>(0)?,r.get::<_,String>(1)?),
            json!({"device":r.get::<_,String>(2)?,"updated_at":r.get::<_,i64>(3)?}))))?
        .collect::<Result<serde_json::Map<String, Value>,_>>()?;
    let (ids, shows, settings, versions, revision, refresh_status) = {
        let ids = conn.prepare(&format!("SELECT b.episode_id FROM browser_publications b JOIN browser_episode_catalog e ON e.id=b.episode_id
            JOIN podcasts p ON p.id=e.podcast_id LEFT JOIN episode_state s ON s.episode_id=e.id
            WHERE {NOTES_READY_SQL} AND (p.is_subscribed=1 OR s.played_at IS NOT NULL OR EXISTS(SELECT 1 FROM listen_episodes WHERE episode_id=e.id))
            ORDER BY e.published_at,e.id"))?.query_map([], |r| r.get::<_,i64>(0))?.collect::<Result<Vec<_>,_>>()?;
        // One catalog scan. Correlated COUNT(*) per show walks ~20k rows per subscribed podcast.
        let shows = conn.prepare("SELECT p.id,p.feed_url,p.title,p.description,p.image_url,p.site_url,
            COALESCE(c.episode_count,0), COALESCE(c.unplayed_count,0), COALESCE(c.ready_count,0)
            FROM podcasts p LEFT JOIN (
                SELECT e.podcast_id, COUNT(*) AS episode_count,
                    SUM(CASE WHEN s.played_at IS NULL AND s.archived_at IS NULL THEN 1 ELSE 0 END) AS unplayed_count,
                    SUM(CASE WHEN s.played_at IS NULL AND s.archived_at IS NULL AND b.episode_id IS NOT NULL AND json_array_length(b.notes_json) > 0 THEN 1 ELSE 0 END) AS ready_count
                FROM browser_episode_catalog e
                LEFT JOIN episode_state s ON s.episode_id=e.id
                LEFT JOIN browser_publications b ON b.episode_id=e.id
                GROUP BY e.podcast_id
            ) c ON c.podcast_id=p.id
            WHERE p.is_subscribed=1 ORDER BY title COLLATE NOCASE")?.query_map([], |r| Ok(json!({
                "id":r.get::<_,i64>(0)?,"feed_url":r.get::<_,String>(1)?,"title":r.get::<_,String>(2)?,
                "description":r.get::<_,String>(3)?,"image_url":r.get::<_,String>(4)?,"site_url":r.get::<_,String>(5)?,
                "episode_count":r.get::<_,i64>(6)?,"unplayed_count":r.get::<_,i64>(7)?,
                "ready_count":r.get::<_,i64>(8)?,"pending_count":r.get::<_,i64>(7)?-r.get::<_,i64>(8)?})))?.collect::<Result<Vec<_>,_>>()?;
        let settings = crate::db::setting(&conn, "browser_settings")?
            .and_then(|s| serde_json::from_str::<Value>(&s).ok())
            .unwrap_or(json!({}));
        let versions = conn
            .prepare("SELECT entity,field,revision FROM browser_field_versions")?
            .query_map([], |r| {
                Ok((
                    format!("{}:{}", r.get::<_, String>(0)?, r.get::<_, String>(1)?),
                    json!(r.get::<_, i64>(2)?),
                ))
            })?
            .collect::<Result<serde_json::Map<String, Value>, _>>()?;
        let revision: i64 =
            conn.query_row("SELECT revision FROM browser_clock", [], |r| r.get(0))?;
        let refresh_status = persisted_refresh_status(&conn)?;
        (ids, shows, settings, versions, revision, refresh_status)
    };
    let mut episodes = Vec::new();
    for id in ids {
        // A concurrent unsubscribe may remove this publication from the visible set.
        let Ok((manifest, notes)) = publication_on(conn, id) else {
            continue;
        };
        let mut detail = serde_json::to_value(Backend::episode_detail_row(conn, id)?)
            .map_err(|e| Error::Invalid(e.to_string()))?;
        detail["audio_url"] = json!(media_url(&manifest));
        detail["duration_secs"] = json!(manifest.duration);
        detail["position_secs"] = json!(processed_time(
            &manifest.timeline,
            detail["position_secs"].as_f64().unwrap_or(0.0)
        ));
        detail["ad_removal_state"] = json!("ad-free");
        detail["ad_removal_stage"] = json!("ready");
        detail["ad_removal_action"] = Value::Null;
        detail["ad_markers"] = json!([]);
        detail["show_notes"] = notes;
        if !manifest.listen_title.is_empty() {
            detail["title"] = json!(manifest.listen_title);
        }
        detail["manifest"] = serde_json::to_value(manifest).unwrap();
        episodes.push(detail);
    }
    // A complete replacement snapshot carries removals without retaining an unbounded event log.
    let pending = conn.query_row(
            "SELECT COUNT(*) FROM browser_episode_catalog e JOIN podcasts p ON p.id=e.podcast_id
            LEFT JOIN episode_state s ON s.episode_id=e.id WHERE
            (p.is_subscribed=1 OR EXISTS(SELECT 1 FROM listen_episodes WHERE episode_id=e.id))
            AND s.played_at IS NULL AND s.archived_at IS NULL
            AND NOT EXISTS(SELECT 1 FROM browser_publications b WHERE b.episode_id=e.id AND json_array_length(b.notes_json) > 0)
            AND NOT EXISTS(SELECT 1 FROM browser_jobs j WHERE j.episode_id=e.id AND j.stage='blocked')",
            [], |r| r.get::<_,i64>(0),
        )?;
    let failed = conn.query_row(
            "SELECT COUNT(*) FROM browser_pending_jobs WHERE stage='retry'",
            [], |r| r.get::<_,i64>(0),
        )?;
    let blocked = conn.query_row(
            "SELECT COUNT(*) FROM browser_pending_jobs WHERE stage='blocked'",
            [], |r| r.get::<_,i64>(0),
        )?;
    let notifications = {
        let mut stmt = conn.prepare(
            "SELECT n.id, n.episode_id, n.category, n.failed_stage, n.message, n.outcome, n.created_at,
                    COALESCE(e.title, ''), COALESCE(p.title, '')
             FROM browser_processing_notifications n
             LEFT JOIN episodes e ON e.id = n.episode_id
             LEFT JOIN podcasts p ON p.id = e.podcast_id
             JOIN browser_jobs j ON j.episode_id = n.episode_id AND j.stage IN ('retry', 'blocked')
             ORDER BY n.id DESC",
        )?;
        let notifications = stmt
            .query_map([], |row| {
                Ok(json!({
                    "id": row.get::<_, i64>(0)?,
                    "episode_id": row.get::<_, i64>(1)?,
                    "category": row.get::<_, String>(2)?,
                    "failed_stage": row.get::<_, String>(3)?,
                    "message": row.get::<_, String>(4)?,
                    "outcome": row.get::<_, String>(5)?,
                    "created_at": row.get::<_, i64>(6)?,
                    "episode_title": row.get::<_, String>(7)?,
                    "podcast_title": row.get::<_, String>(8)?,
                }))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        notifications
    };
    let feedback = {
        let mut stmt = conn.prepare(
            "SELECT id, kind, status, created_at FROM browser_feedback ORDER BY created_at DESC, id LIMIT 50",
        )?;
        let feedback = stmt
            .query_map([], |row| {
                Ok(json!({
                    "id": row.get::<_, String>(0)?,
                    "kind": row.get::<_, String>(1)?,
                    "status": row.get::<_, String>(2)?,
                    "created_at": row.get::<_, i64>(3)?,
                }))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        feedback
    };
    Ok(
        json!({"version":1,"cursor":revision,"replace":true,"episodes":episodes,"shows":shows,
        "settings":settings,"versions":versions,"writers":writers,"refresh_status":refresh_status,"notifications":notifications,
        "feedback":feedback,
        "processing":{"pending":pending,"failed":failed,"blocked":blocked,"storage":storage,
            "memory":crate::memory_gate::status_json()}}),
    )
    })
}

fn ingest_library_url(backend: &Backend, raw: &str) -> Result<&'static str, Error> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(Error::Invalid(LIBRARY_PASTE.into()));
    }
    let (kind, entity, field) = match crate::youtube::classify(trimmed) {
        Ok(Some(crate::youtube::YoutubeInput::Video { .. })) => {
            ("video", "listen", trimmed.to_string())
        }
        Ok(Some(input)) => (
            "channel",
            "subscription",
            channel_subscription_url(&input, trimmed)?,
        ),
        Ok(None) => (
            "podcast",
            "subscription",
            podcast_subscription_url(trimmed)?,
        ),
        Err(_) => return Err(Error::Invalid(LIBRARY_PASTE.into())),
    };
    queue_library_action(backend, entity, &field)?;
    Ok(kind)
}

fn channel_subscription_url(
    input: &crate::youtube::YoutubeInput,
    raw: &str,
) -> Result<String, Error> {
    match input {
        crate::youtube::YoutubeInput::ChannelLookup { url } => Ok(url.clone()),
        crate::youtube::YoutubeInput::ChannelPage { channel_id }
        | crate::youtube::YoutubeInput::ChannelFeed { channel_id } => {
            if raw.starts_with("https://") || raw.starts_with("http://") {
                Ok(raw.to_string())
            } else {
                Ok(format!("https://www.youtube.com/channel/{channel_id}"))
            }
        }
        crate::youtube::YoutubeInput::Video { .. } => Err(Error::Invalid(LIBRARY_PASTE.into())),
    }
}

fn podcast_subscription_url(raw: &str) -> Result<String, Error> {
    let url = url::Url::parse(raw).map_err(|_| Error::Invalid(LIBRARY_PASTE.into()))?;
    if !matches!(url.scheme(), "https" | "http")
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return Err(Error::Invalid(LIBRARY_PASTE.into()));
    }
    Ok(raw.to_string())
}

fn queue_library_action(backend: &Backend, entity: &str, field: &str) -> Result<(), Error> {
    let revision = backend
        .db
        .scalar_i64(
            "SELECT revision FROM browser_field_versions WHERE entity=? AND field=?",
            params![entity, field],
        )?
        .unwrap_or(0);
    let result = apply_actions(
        backend,
        json!({
            "client_id": "pipeline-menu",
            "device_name": "Pipeline",
            "actions": [{
                "id": uuid::Uuid::new_v4().to_string(),
                "sequence": 1,
                "entity": entity,
                "field": field,
                "value": true,
                "base_revision": revision
            }]
        }),
    )?;
    if result["results"][0]["status"].as_str() != Some("applied") {
        return Err(Error::Conflict(
            "That link changed while it was being added. Try again.".into(),
        ));
    }
    Ok(())
}

fn queue_browser_back_catalog_trim(
    tx: &rusqlite::Transaction,
    podcast_id: i64,
) -> Result<(), Error> {
    let mut ids: Vec<i64> = crate::db::setting(tx, "browser_trim_podcast_ids")?
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();
    if !ids.contains(&podcast_id) {
        ids.push(podcast_id);
    }
    crate::db::set_setting(
        tx,
        "browser_trim_podcast_ids",
        &serde_json::to_string(&ids).map_err(|e| Error::Invalid(e.to_string()))?,
    )
}

fn action_core(action: &Value) -> Value {
    json!({
        "id": action.get("id").cloned().unwrap_or(Value::Null),
        "sequence": action.get("sequence").cloned().unwrap_or(Value::Null),
        "entity": action.get("entity").cloned().unwrap_or(Value::Null),
        "field": action.get("field").cloned().unwrap_or(Value::Null),
        "value": action.get("value").cloned().unwrap_or(Value::Null),
        "base_revision": action.get("base_revision").cloned().unwrap_or(Value::Null),
    })
}

fn same_action(stored: &str, action: &Value) -> bool {
    serde_json::from_str::<Value>(stored)
        .is_ok_and(|original| action_core(&original) == action_core(action))
}

/// Last-sync moments per device. Recording lives in the HTTP routes so direct
/// internal `apply_actions` calls (pipeline menu) never appear as devices.
fn record_sync_device(
    backend: &Backend,
    client: &str,
    device: &str,
    with_actions: bool,
) -> Result<(), Error> {
    let now = crate::db::now_unix();
    let applied = if with_actions { now } else { 0 };
    backend.db.execute(
        "INSERT INTO browser_sync_devices(client_id,device,last_sync_at,sync_count,last_actions_at)
         VALUES(?,?,?,1,?) ON CONFLICT(client_id) DO UPDATE SET device=excluded.device,
         last_sync_at=excluded.last_sync_at,sync_count=sync_count+1,
         last_actions_at=MAX(last_actions_at,excluded.last_actions_at)",
        params![client, device, now, applied],
    )?;
    Ok(())
}

/// Snapshot pulls identify with headers. Absent or overlong identity keeps
/// working and records nothing, so old clients are unaffected.
fn record_pull_device(backend: &Backend, request: &HttpRequest) -> Result<(), Error> {
    let Some(client) = request
        .header("x-pods-client-id")
        .filter(|value| !value.is_empty() && value.len() <= 128)
    else {
        return Ok(());
    };
    let device = request
        .header("x-pods-device")
        .filter(|value| !value.is_empty() && value.len() <= 80)
        .unwrap_or("Another device");
    record_sync_device(backend, client, device, false)
}

fn record_action_device(backend: &Backend, payload: &Value) -> Result<(), Error> {
    let Some(client) = payload["client_id"]
        .as_str()
        .filter(|value| !value.is_empty() && value.len() <= 128)
    else {
        return Ok(());
    };
    let device = payload["device_name"]
        .as_str()
        .filter(|value| !value.is_empty() && value.len() <= 80)
        .unwrap_or("Another device");
    record_sync_device(backend, client, device, true)
}

pub fn apply_actions(backend: &Backend, payload: Value) -> Result<Value, Error> {
    let device = payload["device_name"]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 80)
        .unwrap_or("Another device");
    let client = payload["client_id"]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 128)
        .ok_or_else(|| Error::Invalid("client_id required".into()))?;
    let actions = payload["actions"]
        .as_array()
        .filter(|a| a.len() <= 100)
        .ok_or_else(|| Error::Invalid("at most 100 actions required".into()))?;
    backend.db.with_transaction(|tx| {
        let mut results = Vec::new();
        for action in actions {
            let id = action["id"].as_str().filter(|s| !s.is_empty() && s.len()<=128).ok_or_else(||Error::Invalid("operation id required".into()))?;
            let sequence = action["sequence"].as_i64().filter(|v|*v>0).ok_or_else(||Error::Invalid("sequence required".into()))?;
            let raw = action.to_string();
            let previous: Option<(String,String,String)> = tx.query_row("SELECT client_id,payload,result FROM browser_operations WHERE operation_id=?",
                params![id], |r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional()?;
            if let Some((owner,original,result)) = previous {
                if owner != client || !same_action(&original, action) { return Err(Error::Conflict("operation identity reused".into())); }
                results.push(serde_json::from_str::<Value>(&result).map_err(|_|Error::Invalid("invalid stored operation".into()))?);
                continue;
            }
            let entity = action["entity"].as_str().ok_or_else(||Error::Invalid("entity required".into()))?;
            let field = action["field"].as_str().ok_or_else(||Error::Invalid("field required".into()))?;
            let base = action["base_revision"].as_i64().ok_or_else(||Error::Invalid("base_revision required".into()))?;
            let revision: i64 = tx.query_row("SELECT revision FROM browser_field_versions WHERE entity=? AND field=?",params![entity,field],|r|r.get(0)).optional()?.unwrap_or(0);
            let mut stale = revision != base;
            // Equal edits are acknowledgements, not fresh writes. Watermarks commute by max.
            let mut identical = false;
            if entity == "settings" {
                let settings = crate::db::setting(tx,"browser_settings")?.and_then(|v|serde_json::from_str::<Value>(&v).ok()).unwrap_or(json!({}));
                identical = settings[field] == action["value"] && !action["value"].is_null();
                if field == "notifications_cleared_through" {
                    if let Some(value) = action["value"].as_i64().filter(|v|*v>=0) {
                        identical = value <= settings[field].as_i64().unwrap_or(0);
                        stale = false;
                    }
                }
            } else if entity == "subscription" {
                let subscribed = tx.query_row("SELECT is_subscribed FROM podcasts WHERE feed_url=?",[field],|r|r.get::<_,bool>(0)).optional()?.unwrap_or(false);
                identical = stale && action["value"].as_bool() == Some(subscribed);
            } else if entity == "listen" {
                let queued = tx.query_row("SELECT value FROM settings WHERE key=?", [crate::youtube::LISTEN_SETTING], |r| r.get::<_, String>(0)).optional()?.unwrap_or_else(|| "[]".into());
                let items: Vec<crate::youtube::PendingListen> = serde_json::from_str(&queued).unwrap_or_default();
                identical = action["value"].as_bool() == Some(true) && items.iter().any(|item| item.url == field);
            } else if entity == "feedback" {
                identical = tx.query_row("SELECT COUNT(*) FROM browser_feedback WHERE id=?", [field], |r| r.get::<_, i64>(0))? > 0;
            } else if let Ok(episode) = entity.parse::<i64>() {
                if field == "played" {
                    let played = tx.query_row("SELECT played_at IS NOT NULL FROM episode_state WHERE episode_id=?",[episode],|r|r.get::<_,bool>(0)).optional()?.unwrap_or(false);
                    identical = action["value"].as_bool() == Some(played);
                } else if field == "position" {
                    let manifest: Option<String> = tx.query_row("SELECT manifest_json FROM browser_publications WHERE episode_id=?",[episode],|r|r.get(0)).optional()?;
                    if let Some(manifest) = manifest.and_then(|raw|serde_json::from_str::<Manifest>(&raw).ok()) {
                        let seconds = tx.query_row("SELECT position_secs FROM episode_state WHERE episode_id=?",[episode],|r|r.get::<_,f64>(0)).optional()?.unwrap_or(0.0);
                        identical = action["value"]["artifact_hash"].as_str() == Some(manifest.hash.as_str())
                            && action["value"]["seconds"].as_f64().is_some_and(|s| s.is_finite() && s>=0.0 && (original_time(&manifest.timeline,s)-seconds).abs()<0.001);
                    }
                }
            }
            if identical { stale = false; }
            if !stale && !identical {
                let value = &action["value"];
                if entity == "settings" {
                    let mut settings=crate::db::setting(tx,"browser_settings")?.and_then(|s|serde_json::from_str::<Value>(&s).ok()).unwrap_or(json!({}));
                    match field {
                        "speed" if value.as_f64().is_some_and(|n|n.is_finite()&&(0.5..=3.0).contains(&n))=>settings[field]=value.clone(),
                        "autoplay" if value.is_boolean()=>settings[field]=value.clone(),
                        "theme" if matches!(value.as_str(),Some("system"|"light"|"dark"))=>settings[field]=value.clone(),
                        "last_listened" if value.as_i64().is_some_and(|id|id>0)=> {
                            let id=value.as_i64().unwrap();
                            if !tx.query_row("SELECT EXISTS(SELECT 1 FROM browser_publications WHERE episode_id=?)",[id],|r|r.get::<_,bool>(0))? { return Err(Error::Invalid("episode not published".into())); }
                            settings[field]=value.clone();
                        },
                        "notifications_cleared_through" if value.as_i64().is_some_and(|id|id>=0)=>settings[field]=json!(value.as_i64().unwrap().max(settings[field].as_i64().unwrap_or(0))),
                        _=>return Err(Error::Invalid("unsupported setting".into())),
                    }
                    crate::db::set_setting(tx,"browser_settings",&settings.to_string())?;
                } else if entity == "listen" {
                    let input = crate::youtube::classify(field)?.ok_or_else(|| Error::Invalid("paste a YouTube video URL".into()))?;
                    if !matches!(input, crate::youtube::YoutubeInput::Video { .. }) {
                        return Err(Error::Invalid("paste a YouTube video URL".into()));
                    }
                    if value.as_bool() != Some(true) {
                        return Err(Error::Invalid("listen value must be true".into()));
                    }
                    let queued = crate::db::setting(tx, crate::youtube::LISTEN_SETTING)?.unwrap_or_else(|| "[]".into());
                    let mut items: Vec<crate::youtube::PendingListen> = serde_json::from_str(&queued).unwrap_or_default();
                    if !items.iter().any(|item| item.url == field) {
                        items.push(crate::youtube::PendingListen { url: field.to_string(), attempts: 0, next_at: 0 });
                        crate::db::set_setting(tx, crate::youtube::LISTEN_SETTING, &serde_json::to_string(&items).map_err(|e| Error::Invalid(e.to_string()))?)?;
                    }
                } else if entity == "feedback" {
                    if field.is_empty() || field.len() > 128 {
                        return Err(Error::Invalid("invalid report id".into()));
                    }
                    let kind = value["kind"]
                        .as_str()
                        .ok_or_else(|| Error::Invalid("report kind required".into()))?;
                    if kind != "feature" && kind != "bug" {
                        return Err(Error::Invalid("unknown report kind".into()));
                    }
                    let body = value["body"]
                        .as_str()
                        .map(str::trim)
                        .filter(|text| !text.is_empty())
                        .ok_or_else(|| Error::Invalid("report body required".into()))?;
                    if body.len() > 4096 {
                        return Err(Error::Invalid("report too long".into()));
                    }
                    let created = value["created_at"]
                        .as_i64()
                        .filter(|at| *at > 0)
                        .unwrap_or_else(crate::db::now_unix);
                    tx.execute(
                        "INSERT OR IGNORE INTO browser_feedback(id,kind,body,device,client_id,created_at) VALUES(?,?,?,?,?,?)",
                        params![field, kind, body, device, client, created],
                    )?;
                } else if entity == "subscription" && field.starts_with("http") {
                    if matches!(crate::youtube::classify(field)?, Some(crate::youtube::YoutubeInput::Video { .. })) {
                        return Err(Error::Invalid("Paste a channel URL to subscribe. A video URL is added to Listen.".into()));
                    }
                    let url = url::Url::parse(field).map_err(|_|Error::Invalid("invalid feed URL".into()))?;
                    if !matches!(url.scheme(),"https"|"http") || url.host_str().is_none() || !url.username().is_empty() || url.password().is_some() { return Err(Error::Invalid("invalid feed URL".into())); }
                    let subscribed = value.as_bool().ok_or_else(||Error::Invalid("subscription boolean required".into()))?;
                    tx.execute("INSERT INTO podcasts(feed_url,title,created_at,is_subscribed) VALUES(?,?,?,?) ON CONFLICT(feed_url) DO UPDATE SET is_subscribed=excluded.is_subscribed",
                        params![field,url.host_str().unwrap(),crate::db::now_unix(),subscribed])?;
                    crate::db::set_setting(tx,"browser_refresh_requested","true")?;
                    if subscribed {
                        let podcast_id: i64 = tx.query_row("SELECT id FROM podcasts WHERE feed_url=?", [field], |r| r.get(0))?;
                        queue_browser_back_catalog_trim(tx, podcast_id)?;
                        crate::jobs::JobStore::archive_except_newest_two(tx, podcast_id)?;
                    }
                } else {
                    let episode: i64 = entity.parse().map_err(|_|Error::Invalid("invalid episode".into()))?;
                    if let Some(manifest_json) = tx.query_row("SELECT manifest_json FROM browser_publications WHERE episode_id=?",[episode],|r|r.get::<_,String>(0)).optional()? {
                    let manifest: Manifest = serde_json::from_str(&manifest_json).map_err(|_|Error::Invalid("invalid manifest".into()))?;
                    tx.execute("INSERT OR IGNORE INTO episode_state(episode_id,updated_at) VALUES(?,?)",params![episode,crate::db::now_unix()])?;
                    match field {
                        "position" => {
                            let seconds = value["seconds"].as_f64().filter(|s|s.is_finite()&&*s>=0.0).ok_or_else(||Error::Invalid("invalid position".into()))?;
                            // Positions carry their artifact's original timeline so reprocessing cannot reinterpret old seconds.
                            let position_manifest = if value["artifact_hash"].as_str()==Some(manifest.hash.as_str()) { Some(manifest.clone()) } else {
                                match tx.query_row("SELECT manifest_json FROM browser_artifacts WHERE episode_id=? AND hash=?",params![episode,value["artifact_hash"].as_str().unwrap_or("")],|r|r.get::<_,String>(0)).optional()? {
                                    Some(old) => {
                                        let old: Manifest = serde_json::from_str(&old).map_err(|_|Error::Invalid("invalid playback artifact".into()))?;
                                        if old.source_hash==manifest.source_hash { Some(old) } else { None }
                                    }
                                    None => None,
                                }
                            };
                            if let Some(position_manifest) = position_manifest {
                                tx.execute("UPDATE episode_state SET position_secs=?,updated_at=? WHERE episode_id=?",params![original_time(&position_manifest.timeline,seconds),crate::db::now_unix(),episode])?;
                            } else {
                                stale = true;
                            }
                        }
                        "played" => {
                            let played = value.as_bool().ok_or_else(||Error::Invalid("invalid played value".into()))?;
                            tx.execute("UPDATE episode_state SET played_at=?,updated_at=? WHERE episode_id=?",params![if played {Some(crate::db::now_unix())} else {None},crate::db::now_unix(),episode])?;
                        }
                        _ => return Err(Error::Invalid("unsupported field".into())),
                    }
                    } else {
                        stale = true;
                    }
                }
            }
            let result = if stale {
                json!({"id":id,"status":"conflict","revision":revision})
            } else if identical {
                json!({"id":id,"status":"applied","revision":revision})
            } else {
                tx.execute("UPDATE browser_clock SET revision=revision+1",[])?;
                let next: i64 = tx.query_row("SELECT revision FROM browser_clock",[],|r|r.get(0))?;
                tx.execute("INSERT INTO browser_field_versions VALUES(?,?,?) ON CONFLICT(entity,field) DO UPDATE SET revision=excluded.revision",params![entity,field,next])?;
                tx.execute("INSERT INTO browser_field_writers VALUES(?,?,?,?) ON CONFLICT(entity,field) DO UPDATE SET device=excluded.device,updated_at=excluded.updated_at",params![entity,field,device,crate::db::now_unix()])?;
                json!({"id":id,"status":"applied","revision":next})
            };
            tx.execute("INSERT INTO browser_operations VALUES(?,?,?,?,?)",params![id,client,sequence,raw,result.to_string()])?;
            results.push(result);
        }
        Ok(json!({"results":results}))
    })
}

fn serve_artifact(
    backend: &Backend,
    request: &HttpRequest,
    hash: &str,
) -> Result<HttpResponse, Error> {
    if hash.len() != 64
        || !hash
            .bytes()
            .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
    {
        return Err(Error::NotFound);
    }
    if !matches!(request.method.as_str(), "GET" | "HEAD") {
        return Err(Error::NotFound);
    }
    let exists = backend.db.scalar_i64("SELECT COUNT(*) FROM browser_publications WHERE json_extract(manifest_json,'$.hash')=?",[hash])?.unwrap_or(0)>0
        || backend.db.scalar_i64("SELECT COUNT(*) FROM browser_artifacts WHERE hash=?",[hash])?.unwrap_or(0)>0;
    if !exists {
        return Err(Error::NotFound);
    }
    let media = backend
        .db
        .scalar_string(
            "SELECT json_extract(manifest_json,'$.media') FROM browser_publications WHERE json_extract(manifest_json,'$.hash')=?
             UNION ALL SELECT json_extract(manifest_json,'$.media') FROM browser_artifacts WHERE hash=? LIMIT 1",
            [hash, hash],
        )
        .ok()
        .flatten()
        .unwrap_or_default();
    let (extension, file_name) = if media == "video" {
        ("mp4", "video.mp4")
    } else {
        ("m4a", "audio.m4a")
    };
    let path = backend
        .artifacts
        .url(&format!("published/{hash}.{extension}"));
    let mut file = std::fs::File::open(path).map_err(|_| Error::NotFound)?;
    let length = file.metadata().map_err(|_| Error::NotFound)?.len();
    let etag = format!("\"{hash}\"");
    if request.header("if-none-match") == Some(etag.as_str()) {
        let mut response = HttpResponse::no_content().with_header("etag", etag);
        response.status_code = 304;
        return Ok(response);
    }
    let authorization = crate::range::StreamAuthorization {
        episode_id: 1,
        file_path: file_name.into(),
        byte_count: length as i64,
        token: "internal".into(),
        playback_session_id: String::new(),
    };
    let mut headers = request.headers.clone();
    if request.header("if-range").is_some_and(|v| v != etag) {
        headers.remove("range");
    }
    let plan = crate::range::plan(
        &request.method,
        "/episode/1?token=internal",
        &headers,
        Some(&authorization),
    );
    let mut body = Vec::new();
    if let Some(range) = plan.body_range {
        file.seek(SeekFrom::Start(range.start as u64))
            .map_err(|e| Error::Invalid(e.to_string()))?;
        file.take((range.end - range.start) as u64)
            .read_to_end(&mut body)
            .map_err(|e| Error::Invalid(e.to_string()))?;
    }
    Ok(HttpResponse {
        status_code: plan.status_code,
        headers: plan.headers,
        body,
    }
    .with_header("etag", etag))
}

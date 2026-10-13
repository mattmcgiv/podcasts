//! Durable intake and one status projection for the Mac menu and offline browser.
use crate::{
    db::{now_unix, Database},
    Backend, Error,
};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};

pub fn canonical(kind: &str, raw: &str) -> Result<String, Error> {
    if kind == "video" {
        if let Some(crate::youtube::YoutubeInput::Video { video_id }) =
            crate::youtube::classify(raw)?
        {
            return Ok(format!("https://www.youtube.com/watch?v={video_id}"));
        }
        return Err(Error::Invalid("paste a YouTube video URL".into()));
    }
    crate::articles::validate_url(raw)
}

pub fn enqueue(conn: &Connection, kind: &str, raw: &str) -> Result<String, Error> {
    let url = canonical(kind, raw)?;
    let now = now_unix();
    conn.execute("INSERT OR IGNORE INTO browser_intake(id,kind,source,state,created_at,updated_at) VALUES(?,?,?,'queued',?,?)",
        params![uuid::Uuid::new_v4().to_string(), kind, url, now, now])?;
    Ok(conn.query_row(
        "SELECT id FROM browser_intake WHERE kind=? AND source=?",
        params![kind, url],
        |r| r.get(0),
    )?)
}

/// Legacy queues migrate and disappear in the same transaction. Invalid JSON fails closed.
pub fn migrate(db: &Database) -> Result<(), Error> {
    db.with_transaction(|tx| {
        for (kind,key) in [("video",crate::youtube::LISTEN_SETTING),("article",crate::articles::LISTEN_SETTING)] {
            if let Some(raw) = crate::db::setting(tx,key)? {
                let items: Vec<Value> = serde_json::from_str(&raw).map_err(|_|Error::Database("invalid legacy intake queue; retained for recovery".into()))?;
                for item in items {
                    let source = item["url"].as_str().ok_or_else(||Error::Database("legacy intake item has no URL".into()))?;
                    let id = enqueue(tx,kind,source)?;
                    tx.execute("UPDATE browser_intake SET attempts=MAX(attempts,?),next_retry_at=MAX(next_retry_at,?) WHERE id=?",
                        params![item["attempts"].as_i64().unwrap_or(0),item["next_at"].as_i64().unwrap_or(0),id])?;
                }
                tx.execute("DELETE FROM settings WHERE key=?",[key])?;
            }
        }
        Ok(())
    })
}

pub fn recover(db: &Database) -> Result<(), Error> {
    migrate(db)?;
    db.with_transaction(|tx| {
        tx.execute("UPDATE browser_intake SET state='queued',updated_at=?,error_code='interrupted',error='Interrupted; queued to resume.',owner=NULL WHERE state='working'",[now_unix()])?;
        tx.execute("UPDATE browser_jobs SET stage='retry',error='Interrupted; queued to resume.',error_code='interrupted',next_retry_at=0,owner=NULL WHERE owner IS NOT NULL AND stage!='ready'",[])?;
        Ok(())
    })
}

pub fn drain(backend: &Backend) -> Result<bool, Error> {
    migrate(&backend.db)?;
    let claim = backend.db.with_transaction(|tx| {
        let row: Option<(String,String,String,i64)> = tx.query_row("SELECT id,kind,source,attempts FROM browser_intake WHERE state IN ('queued','retry') AND next_retry_at<=? ORDER BY created_at,id LIMIT 1",[now_unix()],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).optional()?;
        if let Some((id,_,_,_)) = &row {
            tx.execute("UPDATE browser_intake SET state='working',updated_at=?,owner=? WHERE id=?",params![now_unix(),std::process::id(),id])?;
        }
        Ok(row)
    })?;
    let Some((id, kind, source, attempts)) = claim else {
        return Ok(false);
    };
    let result = if kind == "video" {
        backend.add_youtube_video(&source).map(|e| e.id)
    } else {
        backend.add_article(&source)
    };
    backend.db.with_transaction(|tx| {
        match result {
            Ok(episode) => {
                tx.execute("UPDATE browser_intake SET state='accepted',episode_id=?,updated_at=?,error=NULL,error_code=NULL,owner=NULL WHERE id=?",params![episode,now_unix(),id])?;
                event(tx,Some(&id),Some(episode),"intake","accepted",attempts,None)?;
            }
            Err(error) => {
                let code = error_code(&error.to_string());
                let terminal = permanent(code) || attempts+1 >= retry_limit(code);
                let state = if terminal { "blocked" } else { "retry" };
                tx.execute("UPDATE browser_intake SET state=?,attempts=attempts+1,next_retry_at=?,updated_at=?,error_code=?,error=?,owner=NULL WHERE id=?",
                    params![state,now_unix()+backoff(attempts,&id),now_unix(),code,safe_detail(&error.to_string()),id])?;
                event(tx,Some(&id),None,"intake",state,attempts+1,Some(code))?;
            }
        }
        Ok(())
    })?;
    Ok(true)
}

pub fn error_code(message: &str) -> &'static str {
    let m = message.to_lowercase();
    if m.contains("code=source_unavailable")
        || m.contains("source is unavailable")
        || m.contains("private video")
        || m.contains("video unavailable")
        || m.contains("has been removed")
    {
        "source_unavailable"
    } else if m.contains("code=dns")
        || m.contains("resolve the source host")
        || m.contains("dns")
        || m.contains("name resolution")
        || m.contains("resolve host")
    {
        "dns"
    } else if m.contains("403") {
        "source_forbidden"
    } else if m.contains("code=timeout")
        || m.contains("exceeded its deadline")
        || m.contains("timeout")
        || m.contains("timed out")
    {
        "timeout"
    } else if m.contains("code=network")
        || m.contains("429")
        || m.contains("503")
        || m.contains("502")
        || m.contains("connection")
        || m.contains("transport")
    {
        "network"
    } else if m.contains("yt-dlp") || m.contains("youtube download") {
        "youtube"
    } else if m.contains("unsupported audio") {
        "unsupported_source"
    } else if m.contains("no readable text") {
        "article_empty"
    } else if m.contains("word limit") || (m.contains("exceeds") && m.contains("words")) {
        "article_word_limit"
    } else if m.contains("synthesis failed") {
        "speech_synthesis"
    } else if m.contains("storage limit") {
        "storage_limit"
    } else if m.contains("code=processing_invalid")
        || m.contains("duration mismatch")
        || m.contains("rendering")
        || m.contains("invalid")
    {
        "processing_invalid"
    } else {
        "processing"
    }
}
pub fn permanent(code: &str) -> bool {
    code == "source_unavailable"
}
pub fn retry_limit(code: &str) -> i64 {
    if matches!(
        code,
        "dns" | "network" | "timeout" | "youtube" | "source_forbidden"
    ) {
        12
    } else {
        4
    }
}
pub fn backoff(attempts: i64, identity: &str) -> i64 {
    let jitter = identity
        .bytes()
        .fold(0u64, |a, b| a.wrapping_mul(31).wrapping_add(b as u64))
        % 61;
    (300_i64.saturating_mul(1_i64 << attempts.clamp(0, 7))).min(21600) + jitter as i64
}
/// Allow-listed explanations retain useful classification without leaking tool URLs/tokens/content.
pub fn safe_detail(message: &str) -> String {
    let code = error_code(message);
    let detail = match code {
        "unsupported_source" => "unsupported audio URL scheme.",
        "article_empty" => "Article extraction found no readable text.",
        "article_word_limit" => "The article exceeds the configured word limit.",
        "speech_synthesis" => "Local speech synthesis failed. Completed sections are retained.",
        "storage_limit" => "Processing needs more disk space.",
        "source_unavailable" => "The source is unavailable or private.",
        "dns" => "The Mac could not resolve the source host.",
        "source_forbidden" => "The source refused the download (HTTP 403).",
        "network" => "The source or network connection failed.",
        "timeout" => "The operation exceeded its deadline.",
        "youtube" => "YouTube lookup or download failed. The submitted link is retained.",
        "processing_invalid" => {
            "Processing produced an invalid artifact. Completed work is retained."
        }
        _ => "Processing failed. Completed work is retained.",
    };
    // Exit status is safe and useful; never persist the raw stderr body.
    let exit = message
        .split("exit=")
        .nth(1)
        .and_then(|s| s.split_whitespace().next())
        .filter(|s| s.chars().all(|c| c.is_ascii_digit() || c == '-'));
    match exit {
        Some(exit) => format!("{detail} Tool exit {exit}."),
        None => detail.into(),
    }
}

pub fn event(
    conn: &Connection,
    submission: Option<&str>,
    episode: Option<i64>,
    stage: &str,
    outcome: &str,
    attempt: i64,
    code: Option<&str>,
) -> Result<(), Error> {
    conn.execute("INSERT INTO browser_pipeline_events(submission_id,episode_id,stage,outcome,attempt,error_code,created_at,pipeline_version,duration_seconds) VALUES(?,?,?,?,?,?,?,?,?)",
        params![submission,episode,stage,outcome,attempt,code,now_unix(),crate::local_worker::VERSION, if outcome != "started" { episode.and_then(|id|conn.query_row("SELECT MAX(0,unixepoch()-stage_started_at) FROM browser_jobs WHERE episode_id=? AND stage_started_at>0",[id],|r|r.get::<_,i64>(0)).optional().ok().flatten()) } else { None }])?;
    Ok(())
}

pub fn retry(conn: &Connection, id: &str) -> Result<(), Error> {
    if let Some(episode) = id
        .strip_prefix("episode:")
        .and_then(|v| v.parse::<i64>().ok())
    {
        let changed = conn.execute("UPDATE browser_jobs SET stage='retry',attempts=0,next_retry_at=0,error=NULL,error_code=NULL WHERE episode_id=? AND stage IN ('blocked','retry','review') AND owner IS NULL",[episode])?;
        if changed == 0 {
            return Err(Error::Conflict(
                "This item is already working or no longer needs retry.".into(),
            ));
        }
        event(conn, None, Some(episode), "retry", "manual_retry", 0, None)?;
    } else {
        let changed = conn.execute("UPDATE browser_intake SET state='queued',attempts=0,next_retry_at=0,error=NULL,error_code=NULL,updated_at=? WHERE id=? AND state IN ('blocked','retry')",params![now_unix(),id])?;
        if changed == 0 {
            return Err(Error::Conflict(
                "This item is already working or no longer needs retry.".into(),
            ));
        }
        event(conn, Some(id), None, "intake", "manual_retry", 0, None)?;
    }
    Ok(())
}

fn label(stage: &str) -> &str {
    match stage {
        "queued" => "Queued for processing",
        "downloading" => "Downloading",
        "transcribing" => "Transcribing",
        "classifying" | "ad_boundaries" => "Finding ad breaks",
        "rendering" => "Rendering",
        "show_notes" => "Writing show notes",
        "fetching" => "Fetching article",
        "synthesizing" => "Synthesizing audio",
        "retry" => "Retry scheduled",
        "blocked" | "review" => "Needs attention",
        "ready" => "Published",
        "working" => "Looking up source",
        _ => "Processing",
    }
}

pub fn status(conn: &Connection) -> Result<Value, Error> {
    let now = now_unix();
    let mut items = Vec::new();
    let mut stmt = conn.prepare("SELECT j.episode_id,e.title,p.title,j.stage,j.error,j.attempts,j.next_retry_at,j.completed_units,j.total_units,j.updated_at,j.stage_started_at,j.owner,j.error_code,j.last_progress_at FROM browser_pending_jobs q JOIN browser_jobs j ON j.episode_id=q.episode_id JOIN episodes e ON e.id=j.episode_id JOIN podcasts p ON p.id=e.podcast_id ORDER BY j.priority DESC,e.published_at,e.id")?;
    for row in stmt.query_map([], |r| {
        Ok((
            r.get::<_, i64>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
            r.get::<_, String>(3)?,
            r.get::<_, Option<String>>(4)?,
            r.get::<_, i64>(5)?,
            r.get::<_, i64>(6)?,
            r.get::<_, Option<i64>>(7)?,
            r.get::<_, Option<i64>>(8)?,
            r.get::<_, i64>(9)?,
            r.get::<_, i64>(10)?,
            r.get::<_, Option<i64>>(11)?,
            r.get::<_, Option<String>>(12)?,
            r.get::<_, i64>(13)?,
        ))
    })? {
        let (
            episode,
            title,
            podcast,
            stage,
            error,
            attempts,
            next,
            done,
            total,
            updated,
            started,
            owner,
            code,
            last_progress,
        ) = row?;
        let wait = error.as_deref().filter(|e| {
            matches!(
                *e,
                "memory_busy"
                    | "omlx_busy"
                    | "power_unplugged"
                    | "power_status_unavailable"
                    | "pipeline_paused"
                    | "storage_limit"
            )
        });
        let state = if matches!(stage.as_str(), "blocked" | "review") {
            "needs_attention"
        } else if wait.is_some() {
            "waiting"
        } else if stage == "retry" {
            "retry_scheduled"
        } else if owner.is_some() {
            "working"
        } else {
            "queued"
        };
        let reason = match wait {
            Some("memory_busy") => Some("Waiting for memory".into()),
            Some("omlx_busy") => Some("Waiting for local AI".into()),
            Some("power_unplugged" | "power_status_unavailable") => {
                Some("Waiting for external power".into())
            }
            Some("pipeline_paused") => Some("Pipeline paused".into()),
            Some("storage_limit") => Some("Waiting for disk space".into()),
            _ => error.as_deref().map(safe_detail),
        };
        items.push(json!({"id":format!("episode:{episode}"),"episodeId":episode,"title":title,"podcastTitle":podcast,"stage":stage,"state":state,"statusLabel":label(&stage),"message":reason,"lastErrorMessage":wait.or(error.as_deref()).map(|e|if wait.is_some(){e.to_string()}else{safe_detail(e)}),"blockingReason":null,"completedUnits":done,"totalUnits":total,"attempts":attempts,"nextRetryAt":if state=="retry_scheduled" {Some(next)}else{None},"updatedAt":updated,"stageStartedAt":started,"lastProgressAt":last_progress,"stalled":owner.is_some()&&updated>0&&now-updated>300,"errorCode":code,"canRetry":matches!(state,"needs_attention"|"retry_scheduled")}));
    }
    let mut stmt = conn.prepare("SELECT id,kind,state,attempts,next_retry_at,updated_at,error,error_code,source FROM browser_intake WHERE episode_id IS NULL AND state!='cancelled' ORDER BY created_at,id")?;
    for row in stmt.query_map([], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
            r.get::<_, i64>(3)?,
            r.get::<_, i64>(4)?,
            r.get::<_, i64>(5)?,
            r.get::<_, Option<String>>(6)?,
            r.get::<_, Option<String>>(7)?,
            r.get::<_, String>(8)?,
        ))
    })? {
        let (id, kind, stage, attempts, next, updated, error, code, source) = row?;
        let title = if kind == "video" {
            match crate::youtube::classify(&source)? {
                Some(crate::youtube::YoutubeInput::Video { video_id }) => {
                    format!("YouTube video {video_id}")
                }
                _ => "Submitted video".into(),
            }
        } else {
            format!(
                "Article from {}",
                url::Url::parse(&source)
                    .ok()
                    .and_then(|u| u.host_str().map(str::to_string))
                    .unwrap_or_else(|| "saved source".into())
            )
        };
        let state = match stage.as_str() {
            "blocked" => "needs_attention",
            "retry" => "retry_scheduled",
            "working" => "working",
            _ => "queued",
        };
        items.push(json!({"id":id,"episodeId":0,"title":title,"podcastTitle":"Listen","stage":stage,"state":state,"statusLabel":label(&stage),"message":error,"lastErrorMessage":error,"blockingReason":null,"completedUnits":null,"totalUnits":null,"attempts":attempts,"nextRetryAt":if state=="retry_scheduled"{Some(next)}else{None},"updatedAt":updated,"canRetry":matches!(state,"needs_attention"|"retry_scheduled"),"errorCode":code}));
    }
    let mut recent = conn.prepare("SELECT i.id,i.kind,i.episode_id,e.title,EXISTS(SELECT 1 FROM browser_publications b WHERE b.episode_id=i.episode_id AND json_array_length(b.notes_json)>0 AND NOT EXISTS(SELECT 1 FROM browser_missing_artifacts m WHERE m.episode_id=b.episode_id)),i.updated_at FROM browser_intake i LEFT JOIN episodes e ON e.id=i.episode_id WHERE i.episode_id IS NOT NULL ORDER BY i.created_at DESC LIMIT 30")?;
    let recent = recent.query_map([],|r|Ok(json!({"id":r.get::<_,String>(0)?,"kind":r.get::<_,String>(1)?,"episodeId":r.get::<_,i64>(2)?,"title":r.get::<_,String>(3)?,"published":r.get::<_,bool>(4)?,"updatedAt":r.get::<_,i64>(5)?})))?.collect::<Result<Vec<_>,_>>()?;
    Ok(
        json!({"observedAt":now,"items":items,"recent":recent,"workerError":crate::db::setting(conn,"pipeline_worker_error")?}),
    )
}

pub fn diagnostics(conn: &Connection) -> Result<Value, Error> {
    let mut stmt = conn.prepare("SELECT submission_id,episode_id,stage,outcome,attempt,error_code,created_at,pipeline_version,duration_seconds FROM browser_pipeline_events ORDER BY id DESC LIMIT 200")?;
    let events = stmt.query_map([],|r|Ok(json!({"submission":r.get::<_,Option<String>>(0)?,"episode":r.get::<_,Option<i64>>(1)?,"stage":r.get::<_,String>(2)?,"outcome":r.get::<_,String>(3)?,"attempt":r.get::<_,i64>(4)?,"errorCode":r.get::<_,Option<String>>(5)?,"at":r.get::<_,i64>(6)?,"pipelineVersion":r.get::<_,String>(7)?,"durationSeconds":r.get::<_,Option<i64>>(8)?})))?.collect::<Result<Vec<_>,_>>()?;
    let counts = |sql: &str| -> Result<i64, Error> { Ok(conn.query_row(sql, [], |r| r.get(0))?) };
    let mut causes = conn.prepare("SELECT error_code,COUNT(DISTINCT COALESCE(submission_id,'episode:'||episode_id)) FROM browser_pipeline_events WHERE error_code IS NOT NULL GROUP BY error_code ORDER BY 2 DESC")?;
    let causes = causes
        .query_map([], |r| {
            Ok(json!({"code":r.get::<_,String>(0)?,"affected":r.get::<_,i64>(1)?}))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let mut latency=conn.prepare("SELECT stage,COUNT(*),AVG(duration_seconds),MAX(duration_seconds) FROM browser_pipeline_events WHERE duration_seconds IS NOT NULL GROUP BY stage")?;
    let latency=latency.query_map([],|r|Ok(json!({"stage":r.get::<_,String>(0)?,"count":r.get::<_,i64>(1)?,"meanSeconds":r.get::<_,f64>(2)?,"maxSeconds":r.get::<_,i64>(3)?})))?.collect::<Result<Vec<_>,_>>()?;
    Ok(
        json!({"version":1,"backendVersion":env!("CARGO_PKG_VERSION"),"buildRevision":option_env!("PODS_BUILD_REVISION").unwrap_or("development"),"pipelineVersion":crate::local_worker::VERSION,"status":status(conn)?,"events":events,"metrics":{"acceptedSubmissions":counts("SELECT COUNT(*) FROM browser_intake")?,"publishedSubmissions":counts("SELECT COUNT(*) FROM browser_intake i JOIN browser_publications b ON b.episode_id=i.episode_id WHERE json_array_length(b.notes_json)>0")?,"firstAttemptAccepted":counts("SELECT COUNT(*) FROM browser_intake WHERE state='accepted' AND attempts=0")?,"terminalIntakeFailures":counts("SELECT COUNT(*) FROM browser_intake WHERE state='blocked'")?,"retryRecoveries":counts("SELECT COUNT(*) FROM browser_pipeline_events WHERE outcome='ready' AND attempt>0")?,"oldestQueuedAt":conn.query_row("SELECT MIN(created_at) FROM browser_intake WHERE state IN ('queued','retry')",[],|r|r.get::<_,Option<i64>>(0))?,"causes":causes,"stageLatency":latency}}),
    )
}

/// Startup reconciliation retains notes and queues only missing/truncated media.
pub fn reconcile_publications(backend: &Backend) -> Result<(), Error> {
    let manifests = {
        let conn = backend.db.lock()?;
        let mut stmt = conn.prepare("SELECT episode_id,manifest_json FROM browser_publications")?;
        let rows = stmt
            .query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };
    for (id, raw) in manifests {
        let manifest: crate::browser::Manifest = serde_json::from_str(&raw)
            .map_err(|_| Error::Database("invalid saved publication".into()))?;
        let valid_hash =
            manifest.hash.len() == 64 && manifest.hash.bytes().all(|c| c.is_ascii_hexdigit());
        let path = backend.artifacts.url(&format!(
            "published/{}.{}",
            manifest.hash,
            crate::browser::media_extension(&manifest)
        ));
        let available = valid_hash
            && std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.len() == manifest.bytes);
        if !available {
            backend.db.with_transaction(|tx| {
                tx.execute("INSERT OR IGNORE INTO browser_missing_artifacts VALUES(?,?)",params![id,now_unix()])?;
                tx.execute("INSERT INTO browser_jobs(episode_id,stage,error,error_code) VALUES(?,'queued','Published media missing; queued to rebuild.','artifact_missing') ON CONFLICT(episode_id) DO UPDATE SET stage='queued',next_retry_at=0,owner=NULL,error=excluded.error,error_code=excluded.error_code",[id])?;
                event(tx,None,Some(id),"publication","artifact_missing",0,Some("artifact_missing"))?;
                Ok(())
            })?;
        }
    }
    Ok(())
}

/// Tool versions are public operational metadata. Cache once per process, outside the DB lock.
pub fn tool_versions() -> Value {
    static VERSIONS: std::sync::OnceLock<Value> = std::sync::OnceLock::new();
    VERSIONS.get_or_init(|| {
        let version = |bin: &str,flag:&str| -> Option<String> {
            crate::child_process::checked(std::process::Command::new(bin).arg(flag),2,"version probe").ok()
                .map(|o|String::from_utf8_lossy(&o.stdout).lines().next().unwrap_or("").chars().take(120).collect())
        };
        json!({"ytDlp":version(&crate::youtube::ytdlp_bin(),"--version"),"ffmpeg":version("ffmpeg","-version")})
    }).clone()
}

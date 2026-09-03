use crate::db::Database;
use crate::error::Error;
use crate::skip::AdSkipRange;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JobStage {
    Queued,
    Downloading,
    Downloaded,
    Transcribing,
    Classifying,
    Ready,
    Failed,
    Cancelled,
}

impl JobStage {
    pub fn as_str(self) -> &'static str {
        match self {
            JobStage::Queued => "queued",
            JobStage::Downloading => "downloading",
            JobStage::Downloaded => "downloaded",
            JobStage::Transcribing => "transcribing",
            JobStage::Classifying => "classifying",
            JobStage::Ready => "ready",
            JobStage::Failed => "failed",
            JobStage::Cancelled => "cancelled",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "queued" => JobStage::Queued,
            "downloading" => JobStage::Downloading,
            "downloaded" => JobStage::Downloaded,
            "transcribing" => JobStage::Transcribing,
            "classifying" => JobStage::Classifying,
            "ready" => JobStage::Ready,
            "failed" => JobStage::Failed,
            "cancelled" => JobStage::Cancelled,
            _ => return None,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum BlockingReason {
    ModelRequired,
    StorageLimit,
    LowPower,
    ThermalPressure,
    DailyLimit,
    PlaybackActive,
}

impl BlockingReason {
    pub fn as_str(self) -> &'static str {
        match self {
            BlockingReason::ModelRequired => "model_required",
            BlockingReason::StorageLimit => "storage_limit",
            BlockingReason::LowPower => "low_power",
            BlockingReason::ThermalPressure => "thermal_pressure",
            BlockingReason::DailyLimit => "daily_limit",
            BlockingReason::PlaybackActive => "playback_active",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "model_required" => BlockingReason::ModelRequired,
            "storage_limit" => BlockingReason::StorageLimit,
            "low_power" => BlockingReason::LowPower,
            "thermal_pressure" => BlockingReason::ThermalPressure,
            "daily_limit" => BlockingReason::DailyLimit,
            "playback_active" => BlockingReason::PlaybackActive,
            _ => return None,
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AudioArtifact {
    pub relative_path: String,
    pub sha256: String,
    pub byte_count: i64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Job {
    pub id: String,
    pub episode_id: i64,
    pub podcast_id: i64,
    pub stage: JobStage,
    pub blocking_reason: Option<BlockingReason>,
    pub attempt_count: i32,
    pub enrolled_at: i64,
    pub updated_at: i64,
    pub failed_stage: Option<JobStage>,
    pub last_error_code: Option<String>,
    pub last_error_message: Option<String>,
    pub retry_eligible: bool,
    pub next_retry_at: Option<i64>,
    pub audio_artifact: Option<AudioArtifact>,
    pub downloaded_at: Option<i64>,
    pub download_resume_relative_path: Option<String>,
    pub transcriber_version: Option<String>,
    pub transcribed_at: Option<i64>,
    pub classification_run_id: Option<String>,
    pub classifier_version: Option<String>,
    pub prompt_version: Option<String>,
    pub classifier_quantization: Option<String>,
    pub classified_at: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum JobStoreError {
    #[error("episode not found")]
    EpisodeNotFound,
    #[error("episode archived")]
    EpisodeArchived,
    #[error("job not found")]
    JobNotFound,
    #[error("{0}")]
    CorruptState(String),
    #[error("invalid transition")]
    InvalidTransition,
}

impl From<JobStoreError> for Error {
    fn from(value: JobStoreError) -> Self {
        match value {
            JobStoreError::EpisodeNotFound | JobStoreError::JobNotFound => Error::NotFound,
            JobStoreError::EpisodeArchived | JobStoreError::InvalidTransition | JobStoreError::CorruptState(_) => {
                Error::Conflict(value.to_string())
            }
        }
    }
}

pub struct JobStore<'a> {
    db: &'a Database,
    now: Box<dyn Fn() -> i64 + Send + Sync + 'a>,
}

impl<'a> JobStore<'a> {
    pub fn new(db: &'a Database) -> Self {
        Self {
            db,
            now: Box::new(crate::db::now_unix),
        }
    }

    pub fn with_now<F>(db: &'a Database, now: F) -> Self
    where
        F: Fn() -> i64 + Send + Sync + 'a,
    {
        Self {
            db,
            now: Box::new(now),
        }
    }

    fn now(&self) -> i64 {
        (self.now)()
    }

    pub fn enqueue(&self, episode_id: i64) -> Result<Job, JobStoreError> {
        let conn = self.db.lock().map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        let podcast_id: i64 = conn
            .query_row("SELECT podcast_id FROM episodes WHERE id = ?", params![episode_id], |row| row.get(0))
            .optional()
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?
            .ok_or(JobStoreError::EpisodeNotFound)?;
        let archived: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM episode_state WHERE episode_id = ? AND archived_at IS NOT NULL",
                params![episode_id],
                |row| row.get(0),
            )
            .unwrap_or(0);
        if archived > 0 {
            return Err(JobStoreError::EpisodeArchived);
        }
        drop(conn);
        if let Some(existing) = self.job_for_episode(episode_id)? {
            return Ok(existing);
        }
        let timestamp = self.now();
        let id = Uuid::new_v4().to_string().to_lowercase();
        self.db
            .execute(
                "INSERT INTO ad_removal_jobs (id, episode_id, podcast_id, stage, attempt_count, enrolled_at, updated_at) VALUES (?, ?, ?, ?, 0, ?, ?)",
                params![id, episode_id, podcast_id, JobStage::Queued.as_str(), timestamp, timestamp],
            )
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        self.required_job(&id)
    }

    pub fn job(&self, id: &str) -> Result<Option<Job>, JobStoreError> {
        self.query_job("SELECT id, episode_id, podcast_id, stage, blocking_reason, attempt_count, enrolled_at, updated_at, failed_stage, last_error_code, last_error_message, retry_eligible, next_retry_at, audio_relative_path, audio_sha256, audio_byte_count, downloaded_at, download_resume_relative_path, transcriber_version, transcribed_at, classification_run_id, classifier_version, prompt_version, classifier_quantization, classified_at FROM ad_removal_jobs WHERE id = ?", rusqlite::params_from_iter([id.to_string()]))
    }

    pub fn job_for_episode(&self, episode_id: i64) -> Result<Option<Job>, JobStoreError> {
        let conn = self.db.lock().map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        let mut stmt = conn
            .prepare("SELECT id, episode_id, podcast_id, stage, blocking_reason, attempt_count, enrolled_at, updated_at, failed_stage, last_error_code, last_error_message, retry_eligible, next_retry_at, audio_relative_path, audio_sha256, audio_byte_count, downloaded_at, download_resume_relative_path, transcriber_version, transcribed_at, classification_run_id, classifier_version, prompt_version, classifier_quantization, classified_at FROM ad_removal_jobs WHERE episode_id = ?")
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        stmt.query_row(rusqlite::params![episode_id], map_job)
            .optional()
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))
    }

    fn query_job(&self, sql: &str, params: impl rusqlite::Params) -> Result<Option<Job>, JobStoreError> {
        let conn = self.db.lock().map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        let mut stmt = conn.prepare(sql).map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        let job = stmt
            .query_row(params, map_job)
            .optional()
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        Ok(job)
    }

    fn required_job(&self, id: &str) -> Result<Job, JobStoreError> {
        self.job(id)?.ok_or(JobStoreError::JobNotFound)
    }

    pub fn transition(&self, job_id: &str, next: JobStage) -> Result<Job, JobStoreError> {
        let current = self.required_job(job_id)?;
        if current.stage == next {
            return Ok(current);
        }
        if !allowed(current.stage, next) {
            return Err(JobStoreError::InvalidTransition);
        }
        let ts = self.now();
        self.db
            .execute(
                "UPDATE ad_removal_jobs SET stage = ?, blocking_reason = NULL, attempt_count = 0, failed_stage = NULL, last_error_code = NULL, last_error_message = NULL, retry_eligible = 1, next_retry_at = NULL, updated_at = ? WHERE id = ?",
                params![next.as_str(), ts, job_id],
            )
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        self.required_job(job_id)
    }

    pub fn set_blocking_reason(&self, job_id: &str, reason: Option<BlockingReason>) -> Result<Job, JobStoreError> {
        let _ = self.required_job(job_id)?;
        let ts = self.now();
        self.db
            .execute(
                "UPDATE ad_removal_jobs SET blocking_reason = ?, updated_at = ? WHERE id = ?",
                params![reason.map(|r| r.as_str()), ts, job_id],
            )
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        self.required_job(job_id)
    }

    pub fn clear_blocking_reasons(&self, reasons: &[BlockingReason]) -> Result<(), JobStoreError> {
        if reasons.is_empty() {
            return Ok(());
        }
        let placeholders = reasons.iter().map(|_| "?").collect::<Vec<_>>().join(", ");
        let mut values: Vec<String> = vec![self.now().to_string()];
        let mut ordered = reasons.to_vec();
        ordered.sort_by_key(|r| r.as_str());
        values.extend(ordered.iter().map(|r| r.as_str().to_string()));
        let sql = format!(
            "UPDATE ad_removal_jobs SET blocking_reason = NULL, updated_at = ? WHERE blocking_reason IN ({placeholders})"
        );
        let conn = self.db.lock().map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        let mut stmt = conn.prepare(&sql).map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        stmt.execute(rusqlite::params_from_iter(values.iter()))
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        Ok(())
    }

    pub fn next_runnable_job(&self) -> Result<Option<Job>, JobStoreError> {
        let now = self.now();
        let conn = self.db.lock().map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        let mut stmt = conn
            .prepare("SELECT j.id, j.episode_id, j.podcast_id, j.stage, j.blocking_reason, j.attempt_count, j.enrolled_at, j.updated_at, j.failed_stage, j.last_error_code, j.last_error_message, j.retry_eligible, j.next_retry_at, j.audio_relative_path, j.audio_sha256, j.audio_byte_count, j.downloaded_at, j.download_resume_relative_path, j.transcriber_version, j.transcribed_at, j.classification_run_id, j.classifier_version, j.prompt_version, j.classifier_quantization, j.classified_at FROM ad_removal_jobs j JOIN episodes e ON e.id = j.episode_id LEFT JOIN episode_state s ON s.episode_id = e.id WHERE j.blocking_reason IS NULL AND j.stage IN ('queued','downloading','downloaded','transcribing','classifying') AND (j.next_retry_at IS NULL OR j.next_retry_at <= ?) AND s.played_at IS NULL AND s.archived_at IS NULL ORDER BY e.published_at ASC, e.id ASC LIMIT 1")
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        stmt.query_row(rusqlite::params![now], map_job)
            .optional()
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))
    }

    pub fn record_failure(&self, job_id: &str, error_code: &str, message: &str) -> Result<Job, JobStoreError> {
        let current = self.required_job(job_id)?;
        if matches!(current.stage, JobStage::Failed | JobStage::Cancelled | JobStage::Ready) {
            return Err(JobStoreError::InvalidTransition);
        }
        let attempt = current.attempt_count + 1;
        let exhausted = attempt >= 4;
        let timestamp = self.now();
        let backoff = [2, 5, 15][(attempt as usize - 1).min(2)];
        let next_retry = if exhausted { None } else { Some(timestamp + backoff) };
        let stage = if exhausted { JobStage::Failed } else { current.stage };
        self.db
            .execute(
                "UPDATE ad_removal_jobs SET stage = ?, failed_stage = ?, attempt_count = ?, last_error_code = ?, last_error_message = ?, retry_eligible = ?, next_retry_at = ?, blocking_reason = NULL, updated_at = ? WHERE id = ?",
                params![
                    stage.as_str(),
                    current.stage.as_str(),
                    attempt,
                    error_code,
                    message,
                    if exhausted { 0 } else { 1 },
                    next_retry,
                    timestamp,
                    job_id
                ],
            )
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        self.required_job(job_id)
    }

    pub fn retry(&self, job_id: &str) -> Result<Job, JobStoreError> {
        let current = self.required_job(job_id)?;
        let resume = current.failed_stage.filter(|_| current.stage == JobStage::Failed).ok_or(JobStoreError::InvalidTransition)?;
        let ts = self.now();
        self.db
            .execute(
                "UPDATE ad_removal_jobs SET stage = ?, failed_stage = NULL, attempt_count = 0, last_error_code = NULL, last_error_message = NULL, retry_eligible = 1, next_retry_at = NULL, blocking_reason = NULL, updated_at = ? WHERE id = ?",
                params![resume.as_str(), ts, job_id],
            )
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        self.required_job(job_id)
    }

    pub fn record_audio_artifact(&self, job_id: &str, artifact: &AudioArtifact) -> Result<Job, JobStoreError> {
        if !valid_artifact_path(&artifact.relative_path)
            || artifact.byte_count < 0
            || artifact.sha256.len() != 64
            || !artifact.sha256.chars().all(|c| matches!(c, '0'..='9' | 'a'..='f'))
        {
            return Err(JobStoreError::CorruptState("invalid audio artifact metadata".into()));
        }
        let job = self.required_job(job_id)?;
        if job.stage == JobStage::Cancelled {
            return Err(JobStoreError::CorruptState("cancelled".into()));
        }
        if job.stage != JobStage::Downloading {
            return Err(JobStoreError::InvalidTransition);
        }
        let ts = self.now();
        self.db
            .execute(
                "UPDATE ad_removal_jobs SET audio_relative_path = ?, audio_sha256 = ?, audio_byte_count = ?, downloaded_at = ?, updated_at = ? WHERE id = ?",
                params![artifact.relative_path, artifact.sha256, artifact.byte_count, ts, ts, job_id],
            )
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        self.required_job(job_id)
    }

    pub fn reserve_daily_classification_slot(&self, episode_id: i64, limit: i64) -> Result<bool, JobStoreError> {
        if limit <= 0 {
            return Ok(false);
        }
        let now = self.now();
        let day_start = local_day_start(now);
        self.db
            .with_transaction(|tx| {
                let exists: Option<i64> = tx
                    .query_row(
                        "SELECT 1 FROM ad_removal_daily_usage WHERE day_start = ? AND episode_id = ?",
                        params![day_start, episode_id],
                        |row| row.get(0),
                    )
                    .optional()?;
                if exists.is_some() {
                    return Ok(true);
                }
                let used: i64 = tx.query_row(
                    "SELECT COUNT(*) FROM ad_removal_daily_usage WHERE day_start = ?",
                    params![day_start],
                    |row| row.get(0),
                )?;
                if used >= limit {
                    return Ok(false);
                }
                tx.execute(
                    "INSERT INTO ad_removal_daily_usage (day_start, episode_id, reserved_at) VALUES (?, ?, ?)",
                    params![day_start, episode_id, now],
                )?;
                Ok(true)
            })
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))
    }

    pub fn skip_ranges(&self, episode_id: i64) -> Result<Vec<AdSkipRange>, JobStoreError> {
        let conn = self.db.lock().map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        let mut stmt = conn
            .prepare("SELECT id, start_segment_id, end_segment_id, start_time, end_time, confidence, reason, classifier_version, prompt_version, created_at, disabled FROM ad_skip_ranges WHERE episode_id = ? ORDER BY start_time")
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        let rows = stmt
            .query_map(params![episode_id], |row| {
                Ok(AdSkipRange {
                    id: row.get(0)?,
                    start_segment_id: row.get(1)?,
                    end_segment_id: row.get(2)?,
                    start_time: row.get(3)?,
                    end_time: row.get(4)?,
                    confidence: row.get(5)?,
                    reason: row.get(6)?,
                    classifier_version: row.get(7)?,
                    prompt_version: row.get(8)?,
                    created_at: row.get(9)?,
                    disabled: row.get::<_, i64>(10)? != 0,
                })
            })
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))
    }

    pub fn cleanup_archived_episode_metadata(conn: &Connection, podcast_id: i64) -> Result<(), rusqlite::Error> {
        conn.execute(
            "DELETE FROM ad_removal_jobs WHERE episode_id IN (SELECT episode_id FROM episode_state WHERE archived_at IS NOT NULL) AND podcast_id = ?",
            params![podcast_id],
        )?;
        Ok(())
    }
}

fn map_job(row: &rusqlite::Row<'_>) -> rusqlite::Result<Job> {
    let stage: String = row.get(3)?;
    let blocking: Option<String> = row.get(4)?;
    let failed: Option<String> = row.get(8)?;
    let rel: Option<String> = row.get(13)?;
    let sha: Option<String> = row.get(14)?;
    let bytes: Option<i64> = row.get(15)?;
    let artifact = match (rel, sha, bytes) {
        (Some(relative_path), Some(sha256), Some(byte_count)) => Some(AudioArtifact {
            relative_path,
            sha256,
            byte_count,
        }),
        _ => None,
    };
    Ok(Job {
        id: row.get(0)?,
        episode_id: row.get(1)?,
        podcast_id: row.get(2)?,
        stage: JobStage::parse(&stage).unwrap_or(JobStage::Queued),
        blocking_reason: blocking.as_deref().and_then(BlockingReason::parse),
        attempt_count: row.get::<_, i64>(5)? as i32,
        enrolled_at: row.get(6)?,
        updated_at: row.get(7)?,
        failed_stage: failed.as_deref().and_then(JobStage::parse),
        last_error_code: row.get(9)?,
        last_error_message: row.get(10)?,
        retry_eligible: row.get::<_, i64>(11)? != 0,
        next_retry_at: row.get(12)?,
        audio_artifact: artifact,
        downloaded_at: row.get(16)?,
        download_resume_relative_path: row.get(17)?,
        transcriber_version: row.get(18)?,
        transcribed_at: row.get(19)?,
        classification_run_id: row.get(20)?,
        classifier_version: row.get(21)?,
        prompt_version: row.get(22)?,
        classifier_quantization: row.get(23)?,
        classified_at: row.get(24)?,
    })
}

fn allowed(from: JobStage, to: JobStage) -> bool {
    match from {
        JobStage::Queued => matches!(to, JobStage::Downloading | JobStage::Cancelled),
        JobStage::Downloading => matches!(to, JobStage::Downloaded | JobStage::Failed | JobStage::Cancelled),
        JobStage::Downloaded => matches!(to, JobStage::Transcribing | JobStage::Failed | JobStage::Cancelled),
        JobStage::Transcribing => matches!(to, JobStage::Classifying | JobStage::Failed | JobStage::Cancelled),
        JobStage::Classifying => matches!(to, JobStage::Ready | JobStage::Failed | JobStage::Cancelled),
        JobStage::Ready => matches!(to, JobStage::Cancelled),
        JobStage::Failed => !matches!(to, JobStage::Ready),
        JobStage::Cancelled => false,
    }
}

pub fn valid_artifact_path(path: &str) -> bool {
    !path.is_empty()
        && !path.starts_with('/')
        && !path.contains("..")
        && (path.starts_with("episodes/") || path.starts_with("resume/"))
}

fn local_day_start(now: i64) -> i64 {
    use chrono::{Local, TimeZone};
    let dt = Local.timestamp_opt(now, 0).single().unwrap_or_else(Local::now);
    dt.date_naive()
        .and_hms_opt(0, 0, 0)
        .and_then(|naive| naive.and_local_timezone(Local).single())
        .map(|d| d.timestamp())
        .unwrap_or(now)
}

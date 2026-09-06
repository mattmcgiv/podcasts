use crate::db::Database;
use crate::error::Error;
use crate::skip::AdSkipRange;
use crate::transcribe::TranscriptSegment;
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
    retry_backoff: Box<dyn Fn(i32) -> i64 + Send + Sync + 'a>,
    unbounded_retry: bool,
}

impl<'a> JobStore<'a> {
    pub fn new(db: &'a Database) -> Self {
        Self {
            db,
            now: Box::new(crate::db::now_unix),
            retry_backoff: Box::new(default_backoff),
            unbounded_retry: false,
        }
    }

    pub fn with_now<F>(db: &'a Database, now: F) -> Self
    where
        F: Fn() -> i64 + Send + Sync + 'a,
    {
        Self {
            db,
            now: Box::new(now),
            retry_backoff: Box::new(default_backoff),
            unbounded_retry: false,
        }
    }

    pub fn with_now_and_backoff<F, B>(db: &'a Database, now: F, backoff: B) -> Self
    where
        F: Fn() -> i64 + Send + Sync + 'a,
        B: Fn(i32) -> i64 + Send + Sync + 'a,
    {
        Self {
            db,
            now: Box::new(now),
            retry_backoff: Box::new(backoff),
            unbounded_retry: false,
        }
    }

    pub fn with_unbounded_retry(mut self, unbounded: bool) -> Self {
        self.unbounded_retry = unbounded;
        self
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
        let exhausted = !self.unbounded_retry && attempt >= 4;
        let timestamp = self.now();
        let backoff = if self.unbounded_retry {
            unbounded_backoff(attempt)
        } else {
            (self.retry_backoff)(attempt)
        };
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

    pub fn cancel(&self, job_id: &str) -> Result<Job, JobStoreError> {
        self.transition(job_id, JobStage::Cancelled)
    }

    pub fn record_download_resume_path(&self, job_id: &str, relative_path: &str) -> Result<Job, JobStoreError> {
        if !valid_artifact_path(relative_path) || !relative_path.starts_with("resume/") {
            return Err(JobStoreError::CorruptState("invalid resume path".into()));
        }
        let job = self.required_job(job_id)?;
        self.reject_cancelled(&job)?;
        let ts = self.now();
        self.db
            .execute(
                "UPDATE ad_removal_jobs SET download_resume_relative_path = ?, updated_at = ? WHERE id = ?",
                params![relative_path, ts, job_id],
            )
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        self.required_job(job_id)
    }

    pub fn replace_transcript_segments(
        &self,
        episode_id: i64,
        segments: &[TranscriptSegment],
    ) -> Result<(), JobStoreError> {
        self.db
            .with_transaction(|tx| {
                tx.execute("DELETE FROM ad_transcript_segments WHERE episode_id = ?", params![episode_id])?;
                for segment in segments {
                    tx.execute(
                        "INSERT INTO ad_transcript_segments (episode_id, segment_id, segment_index, language, start_time, end_time, text) VALUES (?, ?, ?, ?, ?, ?, ?)",
                        params![
                            episode_id,
                            segment.id,
                            segment.index,
                            segment.language,
                            segment.start_time,
                            segment.end_time,
                            segment.text
                        ],
                    )?;
                }
                Ok(())
            })
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))
    }

    pub fn transcript_segments(&self, episode_id: i64) -> Result<Vec<TranscriptSegment>, JobStoreError> {
        let conn = self.db.lock().map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        let mut stmt = conn
            .prepare("SELECT segment_id, segment_index, language, start_time, end_time, text FROM ad_transcript_segments WHERE episode_id = ? ORDER BY segment_index")
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        let rows = stmt
            .query_map(params![episode_id], |row| {
                Ok(TranscriptSegment {
                    id: row.get(0)?,
                    index: row.get(1)?,
                    language: row.get(2)?,
                    start_time: row.get(3)?,
                    end_time: row.get(4)?,
                    text: row.get(5)?,
                })
            })
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))
    }

    pub fn record_transcript(
        &self,
        job_id: &str,
        segments: &[TranscriptSegment],
        transcriber_version: &str,
    ) -> Result<Job, JobStoreError> {
        let job = self.required_job(job_id)?;
        self.reject_cancelled(&job)?;
        if job.stage != JobStage::Transcribing {
            return Err(JobStoreError::InvalidTransition);
        }
        self.replace_transcript_segments(job.episode_id, segments)?;
        let ts = self.now();
        self.db
            .execute(
                "UPDATE ad_removal_jobs SET transcriber_version = ?, transcribed_at = ?, updated_at = ? WHERE id = ?",
                params![transcriber_version, ts, ts, job_id],
            )
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        self.required_job(job_id)
    }

    pub fn replace_skip_ranges(&self, episode_id: i64, ranges: &[AdSkipRange]) -> Result<(), JobStoreError> {
        self.db
            .with_transaction(|tx| {
                tx.execute("DELETE FROM ad_skip_ranges WHERE episode_id = ?", params![episode_id])?;
                for range in ranges {
                    tx.execute(
                        "INSERT INTO ad_skip_ranges (id, episode_id, start_segment_id, end_segment_id, start_time, end_time, confidence, reason, classifier_version, prompt_version, created_at, disabled) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                        params![
                            range.id,
                            episode_id,
                            range.start_segment_id,
                            range.end_segment_id,
                            range.start_time,
                            range.end_time,
                            range.confidence,
                            range.reason,
                            range.classifier_version,
                            range.prompt_version,
                            range.created_at,
                            if range.disabled { 1 } else { 0 }
                        ],
                    )?;
                }
                Ok(())
            })
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))
    }

    pub fn record_classification_evidence(
        &self,
        job_id: &str,
        evidence: &ClassificationEvidence,
    ) -> Result<(), JobStoreError> {
        let job = self.required_job(job_id)?;
        self.reject_cancelled(&job)?;
        self.db
            .execute(
                "INSERT INTO ad_classification_windows (run_id, episode_id, window_index, segment_ids_json, correction_ids_json, prompt, raw_output, schema_valid, validation_error, labels_json, model_id, model_revision, quantization, prompt_version, max_context_tokens, max_output_tokens, temperature, top_p, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                params![
                    evidence.run_id,
                    job.episode_id,
                    evidence.window_index,
                    serde_json::to_string(&evidence.segment_ids).unwrap_or_else(|_| "[]".into()),
                    serde_json::to_string(&evidence.correction_ids).unwrap_or_else(|_| "[]".into()),
                    evidence.prompt,
                    evidence.raw_output,
                    if evidence.schema_valid { 1 } else { 0 },
                    evidence.validation_error,
                    evidence.labels_json,
                    evidence.model_id,
                    evidence.model_revision,
                    evidence.quantization,
                    evidence.prompt_version,
                    evidence.max_context_tokens,
                    evidence.max_output_tokens,
                    evidence.temperature,
                    evidence.top_p,
                    evidence.created_at
                ],
            )
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        Ok(())
    }

    pub fn complete_classification(
        &self,
        job_id: &str,
        run_id: &str,
        ranges: &[AdSkipRange],
    ) -> Result<Job, JobStoreError> {
        let job = self.required_job(job_id)?;
        self.reject_cancelled(&job)?;
        if job.stage != JobStage::Classifying {
            return Err(JobStoreError::InvalidTransition);
        }
        self.replace_skip_ranges(job.episode_id, ranges)?;
        let ts = self.now();
        self.db
            .execute(
                "UPDATE ad_removal_jobs SET classification_run_id = ?, classified_at = ?, updated_at = ? WHERE id = ?",
                params![run_id, ts, ts, job_id],
            )
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        self.required_job(job_id)
    }

    pub fn classification_evidence(&self, episode_id: i64) -> Result<Vec<ClassificationEvidence>, JobStoreError> {
        let conn = self.db.lock().map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        let mut stmt = conn
            .prepare("SELECT run_id, window_index, segment_ids_json, correction_ids_json, prompt, raw_output, schema_valid, validation_error, labels_json, model_id, model_revision, quantization, prompt_version, max_context_tokens, max_output_tokens, temperature, top_p, created_at FROM ad_classification_windows WHERE episode_id = ? ORDER BY window_index")
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        let rows = stmt
            .query_map(params![episode_id], |row| {
                Ok(ClassificationEvidence {
                    run_id: row.get(0)?,
                    window_index: row.get(1)?,
                    segment_ids: serde_json::from_str(&row.get::<_, String>(2)?).unwrap_or_default(),
                    correction_ids: serde_json::from_str(&row.get::<_, String>(3)?).unwrap_or_default(),
                    prompt: row.get(4)?,
                    raw_output: row.get(5)?,
                    schema_valid: row.get::<_, i64>(6)? != 0,
                    validation_error: row.get(7)?,
                    labels_json: row.get(8)?,
                    model_id: row.get(9)?,
                    model_revision: row.get(10)?,
                    quantization: row.get(11)?,
                    prompt_version: row.get(12)?,
                    max_context_tokens: row.get(13)?,
                    max_output_tokens: row.get(14)?,
                    temperature: row.get(15)?,
                    top_p: row.get(16)?,
                    created_at: row.get(17)?,
                })
            })
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))
    }

    pub fn add_correction(
        &self,
        podcast_id: i64,
        source_episode_id: i64,
        transcript_window: &str,
        classification_context: &str,
        classifier_version: &str,
        prompt_version: &str,
    ) -> Result<AdCorrection, JobStoreError> {
        let id = Uuid::new_v4().to_string().to_lowercase();
        let ts = self.now();
        self.db
            .execute(
                "INSERT INTO ad_corrections (id, podcast_id, source_episode_id, transcript_window, classification_context, classifier_version, prompt_version, created_at, active) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)",
                params![
                    id,
                    podcast_id,
                    source_episode_id,
                    transcript_window,
                    classification_context,
                    classifier_version,
                    prompt_version,
                    ts
                ],
            )
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        Ok(AdCorrection {
            id,
            podcast_id,
            source_episode_id,
            transcript_window: transcript_window.to_string(),
            classification_context: classification_context.to_string(),
            classifier_version: classifier_version.to_string(),
            prompt_version: prompt_version.to_string(),
            created_at: ts,
            active: true,
        })
    }

    pub fn corrections(&self, podcast_id: i64) -> Result<Vec<AdCorrection>, JobStoreError> {
        let conn = self.db.lock().map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        let mut stmt = conn
            .prepare("SELECT id, podcast_id, source_episode_id, transcript_window, classification_context, classifier_version, prompt_version, created_at, active FROM ad_corrections WHERE podcast_id = ? AND active = 1 ORDER BY created_at DESC")
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        let rows = stmt
            .query_map(params![podcast_id], |row| {
                Ok(AdCorrection {
                    id: row.get(0)?,
                    podcast_id: row.get(1)?,
                    source_episode_id: row.get(2)?,
                    transcript_window: row.get(3)?,
                    classification_context: row.get(4)?,
                    classifier_version: row.get(5)?,
                    prompt_version: row.get(6)?,
                    created_at: row.get(7)?,
                    active: row.get::<_, i64>(8)? != 0,
                })
            })
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))
    }

    pub fn undo_skip(&self, episode_id: i64, range_id: &str) -> Result<UndoSkipResult, JobStoreError> {
        let ranges = self.skip_ranges(episode_id)?;
        let range = ranges
            .iter()
            .find(|r| r.id == range_id)
            .ok_or(JobStoreError::JobNotFound)?;
        let seek = range.start_time;
        let podcast_id: i64 = self
            .db
            .scalar_i64("SELECT podcast_id FROM episodes WHERE id = ?", params![episode_id])
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?
            .ok_or(JobStoreError::EpisodeNotFound)?;
        let segments = self.transcript_segments(episode_id)?;
        let window = surrounding_transcript(&segments, range);
        self.db
            .execute(
                "UPDATE ad_skip_ranges SET disabled = 1 WHERE id = ?",
                params![range_id],
            )
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        let correction = self.add_correction(
            podcast_id,
            episode_id,
            &window,
            range_id,
            &range.classifier_version,
            &range.prompt_version,
        )?;
        Ok(UndoSkipResult {
            seek_position: seek,
            disabled_range_id: range_id.to_string(),
            correction,
        })
    }

    pub fn replace_show_notes(&self, episode_id: i64, notes: &[ShowNoteRecord]) -> Result<(), JobStoreError> {
        if notes.len() > crate::classify::SHOW_NOTES_CHAPTER_BASELINE {
            return Err(JobStoreError::CorruptState("too many chapters".into()));
        }
        self.db
            .with_transaction(|tx| {
                tx.execute("DELETE FROM episode_show_notes WHERE episode_id = ?", params![episode_id])?;
                for (index, note) in notes.iter().enumerate() {
                    tx.execute(
                        "INSERT INTO episode_show_notes (episode_id, chapter_index, segment_id, start_time, title, summary, model_id, prompt_version, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                        params![
                            episode_id,
                            index as i64,
                            note.segment_id,
                            note.start_time,
                            note.title,
                            note.summary,
                            note.model_id,
                            note.prompt_version,
                            note.created_at
                        ],
                    )?;
                }
                Ok(())
            })
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))
    }

    pub fn show_notes(&self, episode_id: i64) -> Result<Vec<ShowNoteRecord>, JobStoreError> {
        let conn = self.db.lock().map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        let mut stmt = conn
            .prepare("SELECT segment_id, start_time, title, summary, model_id, prompt_version, created_at FROM episode_show_notes WHERE episode_id = ? ORDER BY chapter_index")
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        let rows = stmt
            .query_map(params![episode_id], |row| {
                Ok(ShowNoteRecord {
                    segment_id: row.get(0)?,
                    start_time: row.get(1)?,
                    title: row.get(2)?,
                    summary: row.get(3)?,
                    model_id: row.get(4)?,
                    prompt_version: row.get(5)?,
                    created_at: row.get(6)?,
                })
            })
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))
    }

    pub fn delete_episode_ad_data(&self, episode_id: i64) -> Result<(), JobStoreError> {
        self.db
            .with_transaction(|tx| {
                tx.execute("DELETE FROM ad_skip_ranges WHERE episode_id = ?", params![episode_id])?;
                tx.execute("DELETE FROM ad_transcript_segments WHERE episode_id = ?", params![episode_id])?;
                tx.execute("DELETE FROM ad_classification_windows WHERE episode_id = ?", params![episode_id])?;
                tx.execute("DELETE FROM ad_removal_jobs WHERE episode_id = ?", params![episode_id])?;
                Ok(())
            })
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))
    }

    pub fn delete_podcast_corrections(&self, podcast_id: i64) -> Result<(), JobStoreError> {
        self.db
            .execute("DELETE FROM ad_corrections WHERE podcast_id = ?", params![podcast_id])
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        Ok(())
    }

    pub fn reset_notes_transcript_jobs(&self) -> Result<u32, JobStoreError> {
        let rows: Vec<(String, i64, Option<String>)> = {
            let conn = self.db.lock().map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
            let mut stmt = conn
                .prepare(
                    "SELECT j.id, j.episode_id, j.audio_relative_path FROM ad_removal_jobs j
                     JOIN episodes e ON e.id = j.episode_id
                     LEFT JOIN episode_state s ON s.episode_id = e.id
                     WHERE s.played_at IS NULL AND s.archived_at IS NULL
                       AND j.stage NOT IN ('cancelled')
                       AND (j.transcriber_version IS NULL OR j.transcriber_version = 'notes-transcriber-v1')",
                )
                .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
            let mapped = stmt
                .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
                .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
            mapped
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| JobStoreError::CorruptState(e.to_string()))?
        };
        let ts = self.now();
        let mut n = 0u32;
        for (job_id, episode_id, audio_path) in rows {
            let stage = if audio_path.as_deref().is_some_and(|p| !p.is_empty()) {
                "downloaded"
            } else {
                "queued"
            };
            self.db
                .with_transaction(|tx| {
                    tx.execute("DELETE FROM ad_skip_ranges WHERE episode_id = ?", params![episode_id])?;
                    tx.execute("DELETE FROM ad_transcript_segments WHERE episode_id = ?", params![episode_id])?;
                    tx.execute("DELETE FROM ad_classification_windows WHERE episode_id = ?", params![episode_id])?;
                    tx.execute(
                        "UPDATE ad_removal_jobs SET stage = ?, transcriber_version = NULL, transcribed_at = NULL,
                         classification_run_id = NULL, classifier_version = NULL, prompt_version = NULL,
                         classifier_quantization = NULL, classified_at = NULL, failed_stage = NULL,
                         last_error_code = NULL, last_error_message = NULL, retry_eligible = 1,
                         next_retry_at = NULL, blocking_reason = NULL, attempt_count = 0, updated_at = ?
                         WHERE id = ?",
                        params![stage, ts, job_id],
                    )?;
                    Ok(())
                })
                .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
            n += 1;
        }
        Ok(n)
    }

    pub fn recover_played_cleanup(&self) -> Result<(), JobStoreError> {
        let ids: Vec<i64> = {
            let conn = self.db.lock().map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
            let mut stmt = conn
                .prepare("SELECT j.episode_id FROM ad_removal_jobs j JOIN episode_state s ON s.episode_id = j.episode_id WHERE j.stage = 'cancelled' AND s.played_at IS NOT NULL")
                .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
            let rows = stmt
                .query_map([], |r| r.get(0))
                .map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
            rows.collect::<Result<Vec<_>, _>>()
                .map_err(|e| JobStoreError::CorruptState(e.to_string()))?
        };
        for id in ids {
            self.delete_episode_ad_data(id)?;
        }
        Ok(())
    }

    fn reject_cancelled(&self, job: &Job) -> Result<(), JobStoreError> {
        if job.stage == JobStage::Cancelled {
            return Err(JobStoreError::CorruptState("cancelled".into()));
        }
        Ok(())
    }

    pub fn job_retry_wait(&self) -> Result<Option<i64>, JobStoreError> {
        let now = self.now();
        let conn = self.db.lock().map_err(|e| JobStoreError::CorruptState(e.to_string()))?;
        let next: Option<i64> = conn
            .query_row(
                "SELECT MIN(next_retry_at) FROM ad_removal_jobs WHERE next_retry_at IS NOT NULL AND next_retry_at > ?",
                params![now],
                |r| r.get(0),
            )
            .optional()
            .map_err(|e| JobStoreError::CorruptState(e.to_string()))?
            .flatten();
        Ok(next.map(|at| (at - now).max(0)))
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ClassificationEvidence {
    pub run_id: String,
    pub window_index: i64,
    pub segment_ids: Vec<String>,
    pub correction_ids: Vec<String>,
    pub prompt: String,
    pub raw_output: String,
    pub schema_valid: bool,
    pub validation_error: Option<String>,
    pub labels_json: String,
    pub model_id: String,
    pub model_revision: String,
    pub quantization: String,
    pub prompt_version: String,
    pub max_context_tokens: i64,
    pub max_output_tokens: i64,
    pub temperature: f64,
    pub top_p: f64,
    pub created_at: i64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct AdCorrection {
    pub id: String,
    pub podcast_id: i64,
    pub source_episode_id: i64,
    pub transcript_window: String,
    pub classification_context: String,
    pub classifier_version: String,
    pub prompt_version: String,
    pub created_at: i64,
    pub active: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct UndoSkipResult {
    pub seek_position: f64,
    pub disabled_range_id: String,
    pub correction: AdCorrection,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ShowNoteRecord {
    pub segment_id: String,
    pub start_time: f64,
    pub title: String,
    pub summary: String,
    pub model_id: String,
    pub prompt_version: String,
    pub created_at: i64,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct ResourceConditions {
    pub low_power_mode: bool,
    pub serious_thermal_pressure: bool,
}

pub fn blocking_reason_for_stage(stage: JobStage, conditions: ResourceConditions) -> Option<BlockingReason> {
    if stage != JobStage::Transcribing {
        return None;
    }
    if conditions.low_power_mode {
        return Some(BlockingReason::LowPower);
    }
    if conditions.serious_thermal_pressure {
        return Some(BlockingReason::ThermalPressure);
    }
    None
}

fn surrounding_transcript(segments: &[TranscriptSegment], range: &AdSkipRange) -> String {
    let mut before = None;
    let mut inside = Vec::new();
    let mut after = None;
    for segment in segments {
        if segment.end_time <= range.start_time {
            before = Some(segment.text.clone());
        } else if segment.start_time >= range.end_time {
            if after.is_none() {
                after = Some(segment.text.clone());
            }
        } else {
            inside.push(segment.text.clone());
        }
    }
    let mut parts = Vec::new();
    if let Some(text) = before {
        parts.push(text);
    }
    parts.extend(inside);
    if let Some(text) = after {
        parts.push(text);
    }
    if parts.is_empty() {
        segments.iter().map(|s| s.text.clone()).collect::<Vec<_>>().join(" ")
    } else {
        parts.join(" ")
    }
}

pub use crate::db::migrate_audio_metadata_columns;

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
        && (path.starts_with("episodes/") || path.starts_with("resume/") || path.starts_with("local/") || path.starts_with("published/"))
}

fn default_backoff(attempt: i32) -> i64 {
    [2, 5, 15][(attempt as usize - 1).min(2)]
}

fn unbounded_backoff(attempt: i32) -> i64 {
    let exp = (attempt.max(1) as u32 - 1).min(7);
    (15 * 2_i64.pow(exp)).min(1800)
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

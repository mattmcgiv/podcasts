use crate::db::Database;
use crate::models::DeepSeekUsageMetricsPayload;
use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;
use uuid::Uuid;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct UsageTokens {
    pub input_tokens: Option<i64>,
    pub cached_input_tokens: Option<i64>,
    pub output_tokens: Option<i64>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum ParsedUsage {
    Valid(UsageTokens),
    Absent,
    Invalid,
}

pub fn parse_usage(value: &serde_json::Value) -> Option<UsageTokens> {
    match parse_usage_result(value) {
        ParsedUsage::Valid(tokens) => Some(tokens),
        _ => None,
    }
}

pub fn parse_usage_result(value: &serde_json::Value) -> ParsedUsage {
    let Some(usage) = value.get("usage") else {
        return ParsedUsage::Absent;
    };
    if !usage.is_object() {
        return ParsedUsage::Invalid;
    }
    let input = int_field(usage, "prompt_tokens").or_else(|| int_field(usage, "input_tokens"));
    let output = int_field(usage, "completion_tokens").or_else(|| int_field(usage, "output_tokens"));
    let cached = int_field(usage, "prompt_cache_hit_tokens").or_else(|| {
        usage
            .pointer("/prompt_tokens_details/cached_tokens")
            .and_then(strict_i64)
    });
    match (input, output, cached) {
        (Some(input), Some(output), Some(cached)) if input >= 0 && output >= 0 && cached >= 0 && cached <= input => {
            ParsedUsage::Valid(UsageTokens {
                input_tokens: Some(input),
                cached_input_tokens: Some(cached),
                output_tokens: Some(output),
            })
        }
        (None, None, None) => {
            if usage.get("total_tokens").is_some() || usage.as_object().map(|o| !o.is_empty()).unwrap_or(false) {
                ParsedUsage::Invalid
            } else {
                ParsedUsage::Absent
            }
        }
        _ => ParsedUsage::Invalid,
    }
}

fn int_field(value: &serde_json::Value, key: &str) -> Option<i64> {
    value.get(key).and_then(strict_i64)
}

fn strict_i64(value: &serde_json::Value) -> Option<i64> {
    match value {
        serde_json::Value::Number(n) if n.is_i64() => n.as_i64(),
        serde_json::Value::Number(n) if n.is_u64() => n.as_u64().and_then(|v| i64::try_from(v).ok()),
        _ => None,
    }
}

/// Published DeepSeek chat rates on and after 16 August 2026.
/// Peak hours are 01:00-04:00 and 06:00-10:00 UTC, Monday-Friday.
pub fn is_peak(created_at_unix: i64) -> bool {
    use chrono::{Datelike, Timelike, Utc};
    let Some(dt) = chrono::DateTime::<Utc>::from_timestamp(created_at_unix, 0) else {
        return false;
    };
    let weekday = dt.weekday().number_from_monday();
    if weekday >= 6 {
        return false;
    }
    let hour = dt.hour();
    (1..4).contains(&hour) || (6..10).contains(&hour)
}

pub fn cost_usd(tokens: &UsageTokens, created_at_unix: i64) -> Option<f64> {
    cost_usd_model(tokens, "deepseek-v4-pro", created_at_unix)
}

pub fn cost_usd_model(tokens: &UsageTokens, model: &str, created_at_unix: i64) -> Option<f64> {
    let input = tokens.input_tokens?;
    let output = tokens.output_tokens?;
    let cached = tokens.cached_input_tokens.unwrap_or(0);
    if cached > input {
        return None;
    }
    let uncached = input - cached;
    let peak = is_peak(created_at_unix);
    let (miss, hit, out) = rates(model, peak);
    Some((uncached as f64) * miss / 1_000_000.0 + (cached as f64) * hit / 1_000_000.0 + (output as f64) * out / 1_000_000.0)
}

fn rates(model: &str, peak: bool) -> (f64, f64, f64) {
    match model {
        "deepseek-v4-flash" | "deepseek-v4-flash-vision-exp" => {
            if peak {
                (0.44, 0.014, 1.32)
            } else {
                (0.22, 0.007, 0.66)
            }
        }
        _ => {
            if peak {
                (1.32, 0.044, 3.96)
            } else {
                (0.66, 0.022, 1.98)
            }
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct UsageRecord {
    #[serde(default)]
    pub record_id: String,
    pub episode_id: i64,
    pub episode_key: String,
    pub duration_secs: Option<i64>,
    pub request_kind: String,
    pub model: String,
    pub input_tokens: Option<i64>,
    pub cached_input_tokens: Option<i64>,
    pub output_tokens: Option<i64>,
    pub cost_usd: Option<f64>,
    pub created_at: i64,
}

pub fn episode_key(feed_url: &str, guid: &str) -> String {
    format!("{feed_url}\u{1F}{guid}")
}

pub fn legacy_record_id(record: &UsageRecord) -> String {
    let duration = record.duration_secs.map(|v| v.to_string()).unwrap_or_default();
    let input = record.input_tokens.map(|v| v.to_string()).unwrap_or_default();
    let cached = record.cached_input_tokens.map(|v| v.to_string()).unwrap_or_default();
    let output = record.output_tokens.map(|v| v.to_string()).unwrap_or_default();
    let cost = record.cost_usd.map(|v| v.to_string()).unwrap_or_default();
    let fields = [
        record.episode_id.to_string(),
        record.episode_key.clone(),
        duration,
        record.request_kind.clone(),
        record.model.clone(),
        input,
        cached,
        output,
        cost,
        record.created_at.to_string(),
    ];
    format!("legacy-{}", fields.join("\u{1F}"))
}

pub fn insert_usage(conn: &rusqlite::Connection, record: &UsageRecord) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT INTO deepseek_usage (record_id, episode_id, episode_key, duration_secs, request_kind, model, input_tokens, cached_input_tokens, output_tokens, cost_usd, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(record_id) DO NOTHING",
        rusqlite::params![
            record.record_id,
            record.episode_id,
            record.episode_key,
            record.duration_secs,
            record.request_kind,
            record.model,
            record.input_tokens,
            record.cached_input_tokens,
            record.output_tokens,
            record.cost_usd,
            record.created_at
        ],
    )?;
    Ok(())
}

const INCOMPLETE_KEY: &str = "deepseek_usage_incomplete";

pub struct UsageStore<'a> {
    db: &'a Database,
    ledger: Option<PathBuf>,
    fail_next_insert: Mutex<bool>,
}

impl<'a> UsageStore<'a> {
    pub fn new(db: &'a Database) -> Self {
        Self {
            db,
            ledger: None,
            fail_next_insert: Mutex::new(false),
        }
    }

    pub fn with_ledger(db: &'a Database, ledger: PathBuf) -> Self {
        Self {
            db,
            ledger: Some(ledger),
            fail_next_insert: Mutex::new(false),
        }
    }

    pub fn fail_next_insert(&self) {
        *self.fail_next_insert.lock().unwrap() = true;
    }

    pub fn record(
        &self,
        episode_id: i64,
        request_kind: &str,
        model: &str,
        tokens: Option<&UsageTokens>,
        created_at: i64,
    ) -> Result<UsageRecord, String> {
        let identity = self.identity(episode_id)?;
        let priced = tokens.and_then(|t| cost_usd_model(t, model, created_at));
        let record = UsageRecord {
            record_id: Uuid::new_v4().to_string().to_lowercase(),
            episode_id,
            episode_key: identity.0,
            duration_secs: identity.1,
            request_kind: request_kind.to_string(),
            model: model.to_string(),
            input_tokens: tokens.and_then(|t| t.input_tokens),
            cached_input_tokens: tokens.and_then(|t| t.cached_input_tokens),
            output_tokens: tokens.and_then(|t| t.output_tokens),
            cost_usd: priced,
            created_at,
        };
        match self.insert(&record) {
            Ok(()) => Ok(record),
            Err(err) => {
                if let Some(path) = &self.ledger {
                    if append_ledger(path, &record).is_ok() {
                        return Ok(record);
                    }
                }
                let _ = self.mark_incomplete();
                Err(err)
            }
        }
    }

    pub fn record_parsed(
        &self,
        episode_id: i64,
        request_kind: &str,
        model: &str,
        root: &serde_json::Value,
        created_at: i64,
    ) -> Result<Option<UsageRecord>, String> {
        match parse_usage_result(root) {
            ParsedUsage::Absent => Ok(None),
            ParsedUsage::Valid(tokens) => self
                .record(episode_id, request_kind, model, Some(&tokens), created_at)
                .map(Some),
            ParsedUsage::Invalid => self
                .record(episode_id, request_kind, model, None, created_at)
                .map(Some),
        }
    }

    pub fn records(&self, episode_id: i64) -> Result<Vec<UsageRecord>, String> {
        self.reconcile()?;
        let conn = self.db.lock().map_err(|e| e.to_string())?;
        let mut stmt = conn
            .prepare("SELECT record_id, episode_id, episode_key, duration_secs, request_kind, model, input_tokens, cached_input_tokens, output_tokens, cost_usd, created_at FROM deepseek_usage WHERE episode_id = ? ORDER BY id")
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map(params![episode_id], map_record)
            .map_err(|e| e.to_string())?;
        rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
    }

    pub fn episode_total_cost(&self, episode_id: i64) -> Result<f64, String> {
        self.reconcile()?;
        let key = self.identity(episode_id)?.0;
        let conn = self.db.lock().map_err(|e| e.to_string())?;
        let total: f64 = conn
            .query_row(
                "SELECT COALESCE(SUM(cost_usd), 0) FROM deepseek_usage WHERE episode_key = ?",
                params![key],
                |r| r.get(0),
            )
            .unwrap_or(0.0);
        Ok(total)
    }

    pub fn metrics(&self) -> Result<DeepSeekUsageMetricsPayload, String> {
        self.reconcile()?;
        let leftover = self
            .ledger
            .as_ref()
            .map(|path| load_ledger(path).map(|v| v.len()).unwrap_or(1))
            .unwrap_or(0);
        let conn = self.db.lock().map_err(|e| e.to_string())?;
        let total: f64 = conn
            .query_row("SELECT COALESCE(SUM(cost_usd), 0) FROM deepseek_usage", [], |r| r.get(0))
            .unwrap_or(0.0);
        let ad: f64 = conn
            .query_row(
                "SELECT COALESCE(SUM(cost_usd), 0) FROM deepseek_usage WHERE request_kind = 'ad_detection'",
                [],
                |r| r.get(0),
            )
            .unwrap_or(0.0);
        let notes: f64 = conn
            .query_row(
                "SELECT COALESCE(SUM(cost_usd), 0) FROM deepseek_usage WHERE request_kind = 'show_notes'",
                [],
                |r| r.get(0),
            )
            .unwrap_or(0.0);
        let episode_count: i64 = conn
            .query_row("SELECT COUNT(DISTINCT episode_key) FROM deepseek_usage", [], |r| r.get(0))
            .unwrap_or(0);
        let unpriced: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM deepseek_usage WHERE cost_usd IS NULL",
                [],
                |r| r.get(0),
            )
            .unwrap_or(0);
        let flagged: Option<String> = conn
            .query_row(
                "SELECT value FROM settings WHERE key = ?",
                rusqlite::params![INCOMPLETE_KEY],
                |r| r.get(0),
            )
            .optional()
            .ok()
            .flatten();
        let (priced_cost, minutes) = self.priced_minutes(&conn)?;
        drop(conn);
        let incomplete = flagged.as_deref() == Some("true") || leftover > 0 || unpriced > 0;
        let average = if episode_count > 0 {
            Some(total / episode_count as f64)
        } else {
            None
        };
        let per_minute = if minutes > 0.0 { Some(priced_cost / minutes) } else { None };
        Ok(DeepSeekUsageMetricsPayload {
            total_cost_usd: total,
            average_cost_per_episode_usd: average,
            average_cost_per_podcast_minute_usd: per_minute,
            ad_detection_cost_usd: ad,
            show_notes_cost_usd: notes,
            telemetry_complete: !incomplete,
        })
    }

    fn priced_minutes(&self, conn: &rusqlite::Connection) -> Result<(f64, f64), String> {
        let mut stmt = conn
            .prepare(
                "SELECT episode_key, SUM(cost_usd), MAX(duration_secs) FROM deepseek_usage WHERE cost_usd IS NOT NULL GROUP BY episode_key",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, f64>(1)?, r.get::<_, Option<i64>>(2)?)))
            .map_err(|e| e.to_string())?;
        let mut seconds = 0.0;
        let mut cost = 0.0;
        for row in rows {
            let (key, episode_cost, duration) = row.map_err(|e| e.to_string())?;
            let mut dur = duration.filter(|v| *v > 0);
            if dur.is_none() {
                dur = transcript_duration(conn, &key)?;
            }
            if let Some(d) = dur {
                seconds += d as f64;
                cost += episode_cost;
            }
        }
        Ok((cost, seconds / 60.0))
    }

    fn identity(&self, episode_id: i64) -> Result<(String, Option<i64>), String> {
        let conn = self.db.lock().map_err(|e| e.to_string())?;
        let row: Option<(String, String, Option<i64>)> = conn
            .query_row(
                "SELECT p.feed_url, e.guid, e.duration_secs FROM episodes e JOIN podcasts p ON p.id = e.podcast_id WHERE e.id = ?",
                params![episode_id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()
            .map_err(|e| e.to_string())?;
        if let Some((feed, guid, duration)) = row {
            let mut duration = duration.filter(|v| *v > 0);
            if duration.is_none() {
                duration = transcript_duration_for_episode(&conn, episode_id)?;
            }
            return Ok((episode_key(&feed, &guid), duration));
        }
        Ok((format!("episode-id:{episode_id}"), None))
    }

    fn insert(&self, record: &UsageRecord) -> Result<(), String> {
        if *self.fail_next_insert.lock().unwrap() {
            *self.fail_next_insert.lock().unwrap() = false;
            return Err("deepseek usage insert failed".into());
        }
        let conn = self.db.lock().map_err(|e| e.to_string())?;
        insert_usage(&conn, record).map_err(|e| e.to_string())?;
        Ok(())
    }

    fn reconcile(&self) -> Result<(), String> {
        let Some(path) = &self.ledger else {
            return Ok(());
        };
        let pending = match load_ledger(path) {
            Ok(rows) => rows,
            Err(_) => {
                self.mark_incomplete()?;
                return Ok(());
            }
        };
        if pending.is_empty() {
            return Ok(());
        }
        let mut remaining = Vec::new();
        for record in pending {
            if self.insert(&record).is_err() {
                remaining.push(record);
            }
        }
        if remaining.is_empty() {
            let _ = fs::remove_file(path);
        } else {
            rewrite_ledger(path, &remaining)?;
        }
        Ok(())
    }

    fn mark_incomplete(&self) -> Result<(), String> {
        let conn = self.db.lock().map_err(|e| e.to_string())?;
        crate::db::set_setting(&conn, INCOMPLETE_KEY, "true").map_err(|e| e.to_string())
    }

}

fn transcript_duration(conn: &rusqlite::Connection, episode_key_value: &str) -> Result<Option<i64>, String> {
    let episode_id: Option<i64> = conn
        .query_row(
            "SELECT e.id FROM episodes e JOIN podcasts p ON p.id = e.podcast_id WHERE p.feed_url || x'1F' || e.guid = ?",
            params![episode_key_value],
            |r| r.get(0),
        )
        .optional()
        .map_err(|e| e.to_string())?;
    match episode_id {
        Some(id) => transcript_duration_for_episode(conn, id),
        None => Ok(None),
    }
}

fn transcript_duration_for_episode(conn: &rusqlite::Connection, episode_id: i64) -> Result<Option<i64>, String> {
    let end: Option<f64> = conn
        .query_row(
            "SELECT MAX(end_time) FROM ad_transcript_segments WHERE episode_id = ?",
            params![episode_id],
            |r| r.get(0),
        )
        .optional()
        .map_err(|e| e.to_string())?
        .flatten();
    Ok(end.filter(|v| *v > 0.0).map(|v| v.round() as i64))
}

fn map_record(row: &rusqlite::Row<'_>) -> rusqlite::Result<UsageRecord> {
    Ok(UsageRecord {
        record_id: row.get(0)?,
        episode_id: row.get(1)?,
        episode_key: row.get(2)?,
        duration_secs: row.get(3)?,
        request_kind: row.get(4)?,
        model: row.get(5)?,
        input_tokens: row.get(6)?,
        cached_input_tokens: row.get(7)?,
        output_tokens: row.get(8)?,
        cost_usd: row.get(9)?,
        created_at: row.get(10)?,
    })
}

fn append_ledger(path: &PathBuf, record: &UsageRecord) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|e| e.to_string())?;
    let mut line = serde_json::to_string(record).map_err(|e| e.to_string())?;
    line.push('\n');
    file.write_all(line.as_bytes()).map_err(|e| e.to_string())
}

fn load_ledger(path: &PathBuf) -> Result<Vec<UsageRecord>, String> {
    if !path.exists() {
        return Ok(vec![]);
    }
    let text = fs::read_to_string(path).map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    for line in text.lines().filter(|l| !l.trim().is_empty()) {
        let mut value: serde_json::Value = serde_json::from_str(line).map_err(|e| e.to_string())?;
        if value.get("record_id").and_then(|v| v.as_str()).unwrap_or("").is_empty() {
            let record: UsageRecord = serde_json::from_value(value.clone()).map_err(|e| e.to_string())?;
            value
                .as_object_mut()
                .unwrap()
                .insert("record_id".into(), serde_json::Value::String(legacy_record_id(&record)));
        }
        out.push(serde_json::from_value(value).map_err(|e| e.to_string())?);
    }
    Ok(out)
}

fn rewrite_ledger(path: &PathBuf, records: &[UsageRecord]) -> Result<(), String> {
    let mut text = String::new();
    for record in records {
        text.push_str(&serde_json::to_string(record).map_err(|e| e.to_string())?);
        text.push('\n');
    }
    fs::write(path, text).map_err(|e| e.to_string())
}

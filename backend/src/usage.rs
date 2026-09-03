use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, PartialEq)]
pub struct UsageTokens {
    pub input_tokens: Option<i64>,
    pub cached_input_tokens: Option<i64>,
    pub output_tokens: Option<i64>,
}

pub fn parse_usage(value: &serde_json::Value) -> Option<UsageTokens> {
    let usage = value.get("usage")?;
    let input = usage.get("prompt_tokens").or_else(|| usage.get("input_tokens")).and_then(|v| v.as_i64());
    let output = usage.get("completion_tokens").or_else(|| usage.get("output_tokens")).and_then(|v| v.as_i64());
    let cached = usage
        .get("prompt_cache_hit_tokens")
        .or_else(|| usage.pointer("/prompt_tokens_details/cached_tokens"))
        .and_then(|v| v.as_i64());
    if input.is_none() && output.is_none() && cached.is_none() {
        return None;
    }
    Some(UsageTokens {
        input_tokens: input,
        cached_input_tokens: cached,
        output_tokens: output,
    })
}

/// DeepSeek V4 published rates (USD / million tokens). Peak 00:30-16:30 UTC.
pub fn cost_usd(tokens: &UsageTokens, created_at_unix: i64) -> Option<f64> {
    let input = tokens.input_tokens?;
    let output = tokens.output_tokens?;
    let cached = tokens.cached_input_tokens.unwrap_or(0);
    let uncached = (input - cached).max(0);
    let minutes = ((created_at_unix % 86_400) + 86_400) % 86_400;
    let peak = (30 * 60..16 * 3600 + 30 * 60).contains(&minutes);
    let (in_rate, cache_rate, out_rate) = if peak {
        (0.55, 0.055, 2.19)
    } else {
        (0.135, 0.0135, 0.55)
    };
    Some((uncached as f64) / 1_000_000.0 * in_rate + (cached as f64) / 1_000_000.0 * cache_rate + (output as f64) / 1_000_000.0 * out_rate)
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct UsageRecord {
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

pub fn insert_usage(conn: &rusqlite::Connection, record: &UsageRecord) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT INTO deepseek_usage (record_id, episode_id, episode_key, duration_secs, request_kind, model, input_tokens, cached_input_tokens, output_tokens, cost_usd, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
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

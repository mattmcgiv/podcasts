use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ClassifierLabel {
    pub segment_id: String,
    pub label: String,
    pub reason: String,
}

pub fn parse_structured_labels(raw: &str, known_ids: &[String]) -> Result<Vec<ClassifierLabel>, String> {
    let text = unwrap_json_fence(raw);
    let value: Value = serde_json::from_str(&text).map_err(|_| "malformed json".to_string())?;
    let labels = value
        .get("labels")
        .and_then(Value::as_array)
        .ok_or_else(|| "missing labels".to_string())?;
    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for item in labels {
        let segment_id = item.get("segment_id").and_then(Value::as_str).ok_or("missing segment_id")?.to_string();
        if !known_ids.contains(&segment_id) {
            return Err("invented segment".into());
        }
        if !seen.insert(segment_id.clone()) {
            return Err("duplicate segment".into());
        }
        let label = item.get("label").and_then(Value::as_str).ok_or("missing label")?.to_string();
        if label != "ad" && label != "content" {
            return Err("invalid label".into());
        }
        let reason = item.get("reason").and_then(Value::as_str).unwrap_or("").to_string();
        if reason.chars().count() > 160 {
            return Err("reason too long".into());
        }
        out.push(ClassifierLabel { segment_id, label, reason });
    }
    if out.len() != known_ids.len() {
        return Err("incomplete labels".into());
    }
    Ok(out)
}

fn unwrap_json_fence(raw: &str) -> String {
    let trimmed = raw.trim();
    if let Some(rest) = trimmed.strip_prefix("```json") {
        if let Some(end) = rest.rfind("```") {
            return rest[..end].trim().to_string();
        }
    }
    if let Some(rest) = trimmed.strip_prefix("```") {
        if let Some(end) = rest.rfind("```") {
            return rest[..end].trim().to_string();
        }
    }
    if trimmed.starts_with('"') {
        if let Ok(Value::String(inner)) = serde_json::from_str::<Value>(trimmed) {
            return inner;
        }
    }
    trimmed.to_string()
}

pub const SHOW_NOTES_CHAPTER_BASELINE: usize = 12;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ShowNoteDraft {
    pub segment_id: String,
    pub title: String,
    pub summary: String,
}

pub fn parse_show_notes(raw: &str, known_ids: &[String]) -> Result<Vec<ShowNoteDraft>, String> {
    let text = unwrap_json_fence(raw);
    let value: Value = serde_json::from_str(&text).map_err(|_| "malformed json".to_string())?;
    let chapters = value.get("chapters").and_then(Value::as_array).ok_or("missing chapters")?;
    if chapters.len() > SHOW_NOTES_CHAPTER_BASELINE {
        return Err("too many chapters".into());
    }
    let mut out = Vec::new();
    for item in chapters {
        let segment_id = item.get("segment_id").and_then(Value::as_str).ok_or("missing segment_id")?.to_string();
        if !known_ids.contains(&segment_id) {
            return Err("unknown segment".into());
        }
        out.push(ShowNoteDraft {
            segment_id,
            title: item.get("title").and_then(Value::as_str).unwrap_or("").to_string(),
            summary: item.get("summary").and_then(Value::as_str).unwrap_or("").to_string(),
        });
    }
    Ok(out)
}

pub fn windows(segment_ids: &[String], batch: usize, overlap: usize) -> Vec<Vec<String>> {
    if segment_ids.is_empty() || batch == 0 {
        return vec![];
    }
    let mut out = Vec::new();
    let mut start = 0;
    while start < segment_ids.len() {
        let end = (start + batch).min(segment_ids.len());
        out.push(segment_ids[start..end].to_vec());
        if end == segment_ids.len() {
            break;
        }
        start = end.saturating_sub(overlap).max(start + 1);
    }
    out
}

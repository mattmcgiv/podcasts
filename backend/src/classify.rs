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

pub fn deepseek_chat_body(model: &str, prompt: &str) -> serde_json::Value {
    serde_json::json!({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "thinking": {"type": "disabled"},
        "response_format": {"type": "json_object"}
    })
}

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

const GUEST_PARTICLES: &[&str] = &["and", "of", "the", "de", "van", "da", "di", "von"];

/// A Listen title is "Guest Name: three to five lowercase words", or just the
/// description when the episode has no guest. Proper names stay capitalized.
pub fn accept_listen_title(raw: &str, source: &str) -> Result<String, String> {
    let title = raw.trim();
    if title.is_empty() || title.chars().count() > 80 {
        return Err("listen title length".into());
    }
    if title.contains(['\n', '\r', '"']) || title.to_ascii_lowercase().contains("http") {
        return Err("listen title shape".into());
    }
    if title.ends_with(['.', '!', '?']) {
        return Err("listen title punctuation".into());
    }
    let (guest, description) = match title.split_once(':') {
        Some((guest, rest)) => {
            let guest = guest.trim();
            let rest = rest.trim();
            if guest.is_empty() || rest.is_empty() || rest.contains(':') {
                return Err("listen title colon".into());
            }
            (Some(guest), rest)
        }
        None => (None, title),
    };
    let desc_words: Vec<&str> = description.split_whitespace().collect();
    if !(3..=5).contains(&desc_words.len()) {
        return Err("listen title word count".into());
    }
    if let Some(guest) = guest {
        let words: Vec<&str> = guest.split_whitespace().collect();
        if words.is_empty() || words.len() > 6 {
            return Err("listen title guest".into());
        }
        for word in words {
            let bare = bare_word(word);
            if bare.is_empty() {
                return Err("listen title guest".into());
            }
            if GUEST_PARTICLES.contains(&bare.to_ascii_lowercase().as_str()) {
                if bare.chars().next().is_some_and(|c| c.is_uppercase()) {
                    return Err("listen title guest case".into());
                }
                continue;
            }
            if bare.chars().next().is_some_and(|c| c.is_lowercase()) {
                return Err("listen title guest case".into());
            }
            if !source.to_ascii_lowercase().contains(&bare.to_ascii_lowercase()) {
                return Err("listen title invented guest".into());
            }
        }
    }
    let mut after_break = true;
    for word in &desc_words {
        let bare = bare_word(word);
        if bare.is_empty() {
            continue;
        }
        let first = bare.chars().next().unwrap();
        if after_break {
            if !first.is_uppercase() {
                return Err("listen title opening case".into());
            }
        } else if first.is_uppercase() && !acronym(&bare) && !source_has_token(source, &bare) {
            return Err("listen title title case".into());
        }
        after_break = word.ends_with(';');
    }
    if !desc_words.iter().skip(1).any(|word| {
        bare_word(word).chars().next().is_some_and(|c| c.is_lowercase())
    }) {
        return Err("listen title title case".into());
    }
    Ok(title.to_string())
}

fn bare_word(word: &str) -> &str {
    word.trim_matches(|c: char| !c.is_alphanumeric() && c != '-')
}

fn acronym(word: &str) -> bool {
    let letters: Vec<char> = word.chars().filter(|c| c.is_alphabetic()).collect();
    letters.len() >= 2 && letters.iter().all(|c| c.is_uppercase())
}

fn source_has_token(source: &str, word: &str) -> bool {
    source
        .split(|c: char| !c.is_alphanumeric() && c != '-')
        .any(|token| token == word)
}

pub fn listen_title_prompt(show: &str, feed_title: &str, chapters: &str) -> String {
    format!(
        "Write a Listen title for this episode.\n\
         Host show: {show}\n\
         The host is not a guest. Do not invent a person.\n\
         Original episode title: {feed_title}\n\
         Chapters:\n{chapters}\n\
         Return JSON {{\"title\":\"...\"}}.\n\
         Shape: if a guest is named in the original title or chapters, \"Guest Name: \" plus a 3 to 5 word description. Otherwise only the 3 to 5 word description.\n\
         Example with a guest: \"John Doe: Bitcoin macro update\"\n\
         Example without a guest: \"Bitcoin macro update\"\n\
         Casing: capitalize proper names, the first word of the title, and the first word after a colon or semicolon. Every other word is lowercase. Do not use Title Case.\n\
         No episode numbers, quotes, hashtags, or trailing punctuation."
    )
}

pub const PRODUCTION_BATCH: usize = 64;
pub const PRODUCTION_OVERLAP: usize = 4;

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

pub fn production_windows(segment_ids: &[String]) -> Vec<Vec<String>> {
    windows(segment_ids, PRODUCTION_BATCH, PRODUCTION_OVERLAP)
}

pub fn short_request_ids(count: usize) -> Vec<String> {
    (0..count).map(|i| format!("s{i}")).collect()
}

pub fn total_windows(segment_count: usize) -> usize {
    if segment_count == 0 {
        return 0;
    }
    if segment_count <= PRODUCTION_BATCH {
        return 1;
    }
    let step = PRODUCTION_BATCH - PRODUCTION_OVERLAP;
    1 + (segment_count - PRODUCTION_BATCH + step - 1) / step
}

#[derive(Clone, Debug, PartialEq)]
pub struct CorrectionExample {
    pub id: String,
    pub text: String,
    pub created_at: i64,
}

pub fn select_corrections(segment_text: &str, corrections: &[CorrectionExample], token_budget: usize) -> Vec<CorrectionExample> {
    let haystack = segment_text.to_lowercase();
    let mut ranked: Vec<&CorrectionExample> = corrections
        .iter()
        .filter(|c| {
            c.text
                .split_whitespace()
                .filter(|w| w.len() > 4)
                .any(|w| haystack.contains(&w.to_lowercase()))
        })
        .collect();
    ranked.sort_by_key(|c| std::cmp::Reverse(c.created_at));
    let mut out = Vec::new();
    let mut used = 0usize;
    for item in ranked {
        let cost = item.text.split_whitespace().count();
        if used + cost > token_budget && !out.is_empty() {
            break;
        }
        if cost > token_budget && out.is_empty() {
            continue;
        }
        used += cost;
        out.push(item.clone());
    }
    out
}

pub fn classification_prompt(segment_ids: &[String], corrections: &[CorrectionExample]) -> String {
    let mut prompt = String::from("Classify each segment as \"ad\" or \"content\" with a reason containing 1 to 240 characters.\n");
    for (index, id) in segment_ids.iter().enumerate() {
        prompt.push_str(&format!("SEGMENT s{index} ({id})\n"));
    }
    for correction in corrections {
        prompt.push_str(&format!("correction {} {}\n", correction.id, correction.text));
    }
    prompt
}

#[cfg(test)]
mod listen_title_tests {
    use super::*;

    const SOURCE: &str = "John Doe on Bitcoin. Jane Roe joins. The Fed holds rates.";

    #[test]
    fn accepts_a_guest_and_a_subdued_description() {
        let title = accept_listen_title("John Doe: Bitcoin macro update", SOURCE).unwrap();
        assert_eq!(title, "John Doe: Bitcoin macro update");
        assert_eq!(
            accept_listen_title("Jane Roe: Fed holds rates", SOURCE).unwrap(),
            "Jane Roe: Fed holds rates"
        );
        assert_eq!(
            accept_listen_title("Bitcoin macro update", SOURCE).unwrap(),
            "Bitcoin macro update"
        );
    }

    #[test]
    fn rejects_title_case_invented_guests_and_the_wrong_length() {
        assert!(accept_listen_title("John Doe: Bitcoin Macro Update", SOURCE).is_err());
        assert!(accept_listen_title("John Doe: Bitcoin macro", SOURCE).is_err());
        assert!(accept_listen_title("John Doe: a very long bitcoin macro update", SOURCE).is_err());
        assert!(accept_listen_title("bitcoin macro update", SOURCE).is_err());
        assert!(accept_listen_title("Pat Smith: Bitcoin macro update", SOURCE).is_err());
        assert!(accept_listen_title("John Doe: bitcoin; fed outlook today", SOURCE).is_err());
        assert!(accept_listen_title("John Doe: Rates; Fed outlook now", SOURCE).is_ok());
    }

    #[test]
    fn prompt_states_the_casing_example() {
        let prompt = listen_title_prompt("Odd Lots", "John Doe on markets", "- intro");
        assert!(prompt.contains("John Doe: Bitcoin macro update"));
        assert!(prompt.contains("Do not use Title Case"));
        assert!(prompt.contains("semicolon"));
    }
}

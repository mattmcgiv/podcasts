#[derive(Clone, Debug, PartialEq)]
pub struct TranscriptSegment {
    pub id: String,
    pub index: i32,
    pub language: String,
    pub start_time: f64,
    pub end_time: f64,
    pub text: String,
}

pub fn stable_segment_id(episode_id: i64, index: i32, start_ms: i64) -> String {
    format!("ep{episode_id}-seg{index}-{start_ms}")
}

pub fn from_finalized(
    episode_id: i64,
    language: &str,
    pieces: &[(f64, f64, String)],
) -> Result<Vec<TranscriptSegment>, String> {
    let mut out = Vec::new();
    let mut prior_end = f64::NEG_INFINITY;
    for (index, (start, end, text)) in pieces.iter().enumerate() {
        if !start.is_finite() || !end.is_finite() || *end <= *start || *start < prior_end || text.trim().is_empty() {
            return Err("invalid transcript segment sequence".into());
        }
        let start_ms = (*start * 1000.0).round() as i64;
        out.push(TranscriptSegment {
            id: stable_segment_id(episode_id, index as i32, start_ms),
            index: index as i32,
            language: language.to_string(),
            start_time: *start,
            end_time: *end,
            text: text.clone(),
        });
        prior_end = *end;
    }
    if out.is_empty() {
        return Err("transcript has no finalized segments".into());
    }
    Ok(out)
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ResultAccumulator {
    pub language: String,
    pub segments: Vec<TranscriptSegment>,
    pub observed_final_result_count: i32,
    pub rejected_final_result_count: i32,
}

impl ResultAccumulator {
    pub fn new(language: impl Into<String>) -> Self {
        Self {
            language: language.into(),
            ..Self::default()
        }
    }

    pub fn consume(&mut self, is_final: bool, start_time: f64, end_time: f64, text: impl Into<String>) {
        if !is_final {
            return;
        }
        self.observed_final_result_count += 1;
        let text = text.into();
        if !start_time.is_finite() || !end_time.is_finite() || end_time <= start_time || text.trim().is_empty() {
            self.rejected_final_result_count += 1;
            return;
        }
        let index = self.segments.len() as i32;
        let start_ms = (start_time * 1000.0).round() as i64;
        self.segments.push(TranscriptSegment {
            id: format!("acc-{index}-{start_ms}"),
            index,
            language: self.language.clone(),
            start_time,
            end_time,
            text,
        });
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct TimedWord {
    pub text: String,
    pub start: f64,
    pub end: f64,
}

pub const MAX_SEGMENT_SECS: f64 = 12.0;
pub const GAP_SPLIT_SECS: f64 = 0.6;

pub fn group_words(episode_id: i64, words: &[TimedWord]) -> Result<Vec<TranscriptSegment>, String> {
    let mut pieces: Vec<(f64, f64, String)> = Vec::new();
    let mut cur_start: Option<f64> = None;
    let mut cur_end = 0.0;
    let mut cur_text = String::new();
    let mut last_end = f64::NEG_INFINITY;
    for word in words {
        let text = word.text.trim();
        if text.is_empty() || !word.start.is_finite() || !word.end.is_finite() || word.end <= word.start {
            continue;
        }
        let start_new = match cur_start {
            None => true,
            Some(start) => {
                let gap = word.start - last_end;
                let duration = word.end - start;
                gap > GAP_SPLIT_SECS || duration > MAX_SEGMENT_SECS || ends_sentence(&cur_text)
            }
        };
        if start_new {
            if let Some(start) = cur_start {
                if !cur_text.trim().is_empty() {
                    pieces.push((start, cur_end, cur_text.trim().to_string()));
                }
            }
            cur_start = Some(word.start);
            cur_text = text.to_string();
        } else {
            cur_text.push(' ');
            cur_text.push_str(text);
        }
        cur_end = word.end;
        last_end = word.end;
    }
    if let Some(start) = cur_start {
        if !cur_text.trim().is_empty() {
            pieces.push((start, cur_end, cur_text.trim().to_string()));
        }
    }
    from_finalized(episode_id, "en", &pieces)
}

fn ends_sentence(text: &str) -> bool {
    matches!(text.trim_end().chars().last(), Some('.' | '!' | '?'))
}

pub fn error_code(kind: &str) -> &'static str {
    match kind {
        "canceled" => "transcription.canceled",
        "unsupported" => "transcription.unsupported_audio",
        "timeout" => "transcription.timeout",
        _ => "transcription.failed",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn w(text: &str, start: f64, end: f64) -> TimedWord {
        TimedWord { text: text.into(), start, end }
    }

    #[test]
    fn group_words_splits_on_gap_punctuation_and_duration_cap() {
        let segments = group_words(
            9,
            &[
                w("Hello", 0.0, 0.4),
                w("there.", 0.4, 0.8),
                w("Next", 0.85, 1.1),
                w("clause", 1.1, 1.4),
                w("after", 2.2, 2.5),
                w("a", 2.5, 2.6),
                w("gap", 2.6, 3.0),
                w("Long", 10.0, 16.0),
                w("tail", 16.0, 23.0),
            ],
        )
        .unwrap();
        let texts: Vec<&str> = segments.iter().map(|s| s.text.as_str()).collect();
        assert_eq!(texts, vec!["Hello there.", "Next clause", "after a gap", "Long", "tail"]);
        assert_eq!(segments[0].start_time, 0.0);
        assert_eq!(segments[0].end_time, 0.8);
        assert_eq!(segments[2].start_time, 2.2);
        assert!(segments[3].end_time - segments[3].start_time <= MAX_SEGMENT_SECS + 0.001);
    }

    #[test]
    fn group_words_skips_empty_and_invalid_words() {
        let segments = group_words(1, &[w("  ", 0.0, 1.0), w("Ok", 1.0, 0.5), w("Hi", 1.0, 1.4)]).unwrap();
        assert_eq!(segments.len(), 1);
        assert_eq!(segments[0].text, "Hi");
    }
}

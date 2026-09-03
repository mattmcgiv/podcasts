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

pub fn error_code(kind: &str) -> &'static str {
    match kind {
        "canceled" => "transcription.canceled",
        "unsupported" => "transcription.unsupported_audio",
        "timeout" => "transcription.timeout",
        _ => "transcription.failed",
    }
}

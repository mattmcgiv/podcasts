use crate::classify::{self, parse_structured_labels, production_windows, short_request_ids, classification_prompt};
use crate::jobs::{Job, JobStage, JobStore};
use crate::storage::{self, ArtifactStore, DownloadResult};
use crate::transcribe::{self, TimedWord, TranscriptSegment};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{Read, Write};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum TranscriberKind {
    #[default]
    Notes,
    Parakeet,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PipelineConfig {
    pub transcriber: TranscriberKind,
    pub parakeet_url: Option<String>,
    pub skip_daily_classification_limit: bool,
    pub unbounded_job_retry: bool,
    pub background_refresh_secs: u64,
}

impl PipelineConfig {
    pub fn from_env() -> Self {
        let parakeet = std::env::var("PODS_TRANSCRIBER").ok().as_deref() == Some("parakeet");
        Self {
            transcriber: if parakeet { TranscriberKind::Parakeet } else { TranscriberKind::Notes },
            parakeet_url: std::env::var("PODS_PARAKEET_URL").ok().filter(|s| !s.is_empty()),
            skip_daily_classification_limit: parakeet,
            unbounded_job_retry: parakeet,
            background_refresh_secs: if parakeet { 30 * 60 } else { 0 },
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct FetchedAudio {
    pub content_type: String,
    pub status: u16,
    pub sha256: String,
    pub byte_count: i64,
}

pub trait AudioDownloader: Send + Sync {
    fn fetch_to(&self, url: &str, dest: &Path) -> Result<FetchedAudio, String>;
}

pub struct UreqDownloader;

impl AudioDownloader for UreqDownloader {
    fn fetch_to(&self, url: &str, dest: &Path) -> Result<FetchedAudio, String> {
        let response = ureq::get(url)
            .timeout(Duration::from_secs(30 * 60))
            .call()
            .map_err(|e| e.to_string())?;
        let status = response.status();
        let content_type = response
            .header("content-type")
            .unwrap_or("application/octet-stream")
            .to_string();
        if status != 200 {
            return Ok(FetchedAudio {
                content_type,
                status,
                sha256: String::new(),
                byte_count: 0,
            });
        }
        if let Some(parent) = dest.parent() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        let tmp = dest.with_extension("part");
        let mut hasher = Sha256::new();
        let mut total = 0i64;
        {
            let mut file = fs::File::create(&tmp).map_err(|e| e.to_string())?;
            let mut reader = response.into_reader();
            let mut buf = [0u8; 64 * 1024];
            loop {
                let n = reader.read(&mut buf).map_err(|e| e.to_string())?;
                if n == 0 {
                    break;
                }
                file.write_all(&buf[..n]).map_err(|e| e.to_string())?;
                hasher.update(&buf[..n]);
                total += n as i64;
            }
        }
        fs::rename(&tmp, dest).map_err(|e| e.to_string())?;
        Ok(FetchedAudio {
            content_type,
            status,
            sha256: hex::encode(hasher.finalize()),
            byte_count: total,
        })
    }
}

#[derive(Default)]
pub struct MockDownloader {
    pub responses: Mutex<std::collections::HashMap<String, DownloadResult>>,
}

impl MockDownloader {
    pub fn set(&self, url: &str, result: DownloadResult) {
        self.responses.lock().unwrap().insert(url.to_string(), result);
    }
}

impl AudioDownloader for MockDownloader {
    fn fetch_to(&self, url: &str, dest: &Path) -> Result<FetchedAudio, String> {
        let download = self
            .responses
            .lock()
            .unwrap()
            .get(url)
            .cloned()
            .ok_or_else(|| format!("missing mock download for {url}"))?;
        if download.status != 200 {
            return Ok(FetchedAudio {
                content_type: download.content_type,
                status: download.status,
                sha256: String::new(),
                byte_count: 0,
            });
        }
        if let Some(parent) = dest.parent() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        fs::write(dest, &download.bytes).map_err(|e| e.to_string())?;
        Ok(FetchedAudio {
            content_type: download.content_type,
            status: download.status,
            sha256: hex::encode(Sha256::digest(&download.bytes)),
            byte_count: download.bytes.len() as i64,
        })
    }
}

pub trait Transcriber: Send + Sync {
    fn version(&self) -> &'static str;
    fn transcribe(
        &self,
        episode_id: i64,
        audio_path: Option<&Path>,
        notes_html: &str,
        duration_secs: Option<i64>,
    ) -> Result<Vec<TranscriptSegment>, String>;
}

pub struct NotesTranscriber;

impl Transcriber for NotesTranscriber {
    fn version(&self) -> &'static str {
        "notes-transcriber-v1"
    }

    fn transcribe(
        &self,
        episode_id: i64,
        _audio_path: Option<&Path>,
        notes_html: &str,
        duration_secs: Option<i64>,
    ) -> Result<Vec<TranscriptSegment>, String> {
        let text = strip_html(notes_html);
        let chunks: Vec<String> = text
            .split(|c: char| c == '.' || c == '!' || c == '?' || c == '\n')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .collect();
        let chunks = if chunks.is_empty() {
            vec!["Episode audio".to_string()]
        } else {
            chunks
        };
        let total = duration_secs.unwrap_or((chunks.len() as i64) * 10).max(1) as f64;
        let slice = total / chunks.len() as f64;
        let mut pieces = Vec::new();
        for (index, chunk) in chunks.iter().enumerate() {
            let start = index as f64 * slice;
            let end = if index + 1 == chunks.len() { total } else { start + slice };
            pieces.push((start, end, chunk.clone()));
        }
        transcribe::from_finalized(episode_id, "en", &pieces)
    }
}

pub struct ParakeetTranscriber {
    pub endpoint: String,
}

impl Transcriber for ParakeetTranscriber {
    fn version(&self) -> &'static str {
        "parakeet-tdt-ctc-110m"
    }

    fn transcribe(
        &self,
        episode_id: i64,
        audio_path: Option<&Path>,
        _notes_html: &str,
        _duration_secs: Option<i64>,
    ) -> Result<Vec<TranscriptSegment>, String> {
        let path = audio_path.ok_or_else(|| "missing audio artifact".to_string())?;
        let body = serde_json::json!({
            "audio_path": path.to_string_lossy(),
            "episode_id": episode_id,
        });
        let response = ureq::post(&self.endpoint)
            .timeout(Duration::from_secs(4 * 3600))
            .set("Content-Type", "application/json")
            .send_string(&body.to_string())
            .map_err(|e| e.to_string())?;
        let status = response.status();
        let text = response.into_string().map_err(|e| e.to_string())?;
        if !(200..300).contains(&status) {
            return Err(format!("parakeet http {status}: {text}"));
        }
        let words = parse_parakeet_words(&text)?;
        transcribe::group_words(episode_id, &words)
    }
}

pub fn parse_parakeet_words(raw: &str) -> Result<Vec<TimedWord>, String> {
    if let Ok(value) = serde_json::from_str::<serde_json::Value>(raw.trim()) {
        let list = value
            .get("words")
            .or_else(|| value.get("timestamps"))
            .and_then(|v| v.as_array())
            .ok_or_else(|| "parakeet json missing words".to_string())?;
        let mut words = Vec::new();
        for item in list {
            let text = item
                .get("w")
                .or_else(|| item.get("word"))
                .or_else(|| item.get("text"))
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let start = item.get("start").and_then(|v| v.as_f64()).unwrap_or(f64::NAN);
            let end = item.get("end").and_then(|v| v.as_f64()).unwrap_or(f64::NAN);
            words.push(TimedWord { text, start, end });
        }
        return Ok(words);
    }
    let mut words = Vec::new();
    for line in raw.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let Some((range, rest)) = line.split_once(char::is_whitespace) else {
            continue;
        };
        let Some((start_raw, end_raw)) = range.split_once('-') else {
            continue;
        };
        let Ok(start) = start_raw.parse::<f64>() else { continue };
        let Ok(end) = end_raw.parse::<f64>() else { continue };
        let text = rest
            .rsplit_once('(')
            .map(|(body, _)| body)
            .unwrap_or(rest)
            .trim()
            .trim_end_matches(',')
            .to_string();
        if !text.is_empty() {
            words.push(TimedWord { text, start, end });
        }
    }
    if words.is_empty() {
        return Err("parakeet produced no words".into());
    }
    Ok(words)
}

#[derive(Clone, Debug)]
pub struct ClassifyOutcome {
    pub content: Option<String>,
    pub raw: serde_json::Value,
}

pub trait CloudClassifier: Send + Sync {
    fn classify_window(&self, prompt: &str, api_key: &str) -> Result<ClassifyOutcome, String>;
}

pub struct DeepSeekClassifier;

impl CloudClassifier for DeepSeekClassifier {
    fn classify_window(&self, prompt: &str, api_key: &str) -> Result<ClassifyOutcome, String> {
        if api_key.trim().is_empty() {
            return Err("pause:model_required".into());
        }
        let mut body = classify::deepseek_chat_body("deepseek-v4-pro", prompt);
        if let Some(obj) = body.as_object_mut() {
            obj.insert("max_tokens".into(), serde_json::json!(8192));
            obj.insert("stream".into(), serde_json::json!(false));
        }
        let response = ureq::post("https://api.deepseek.com/chat/completions")
            .set("Authorization", &format!("Bearer {api_key}"))
            .set("Content-Type", "application/json")
            .timeout(Duration::from_secs(120))
            .send_string(&body.to_string())
            .map_err(|e| e.to_string())?;
        let status = response.status();
        let text = response.into_string().map_err(|e| e.to_string())?;
        if !(200..300).contains(&status) {
            return Err(format!("http {status}"));
        }
        let raw: serde_json::Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
        let content = raw
            .pointer("/choices/0/message/content")
            .and_then(|v| v.as_str())
            .map(str::to_string);
        Ok(ClassifyOutcome { content, raw })
    }
}

pub struct ScriptedClassifier {
    pub responses: Mutex<Vec<ClassifyOutcome>>,
}

impl CloudClassifier for ScriptedClassifier {
    fn classify_window(&self, _prompt: &str, api_key: &str) -> Result<ClassifyOutcome, String> {
        if api_key.trim().is_empty() {
            return Err("pause:model_required".into());
        }
        self.responses
            .lock()
            .unwrap()
            .pop()
            .ok_or_else(|| "no scripted classifier output".into())
    }
}

pub fn execute_stage(
    store: &JobStore<'_>,
    artifacts: &ArtifactStore,
    downloader: &dyn AudioDownloader,
    transcriber: &dyn Transcriber,
    classifier: &dyn CloudClassifier,
    api_key: &str,
    stage: JobStage,
    job: &Job,
    audio_url: &str,
    notes_html: &str,
    duration_secs: Option<i64>,
    usage_db: Option<&crate::db::Database>,
) -> Result<(), String> {
    match stage {
        JobStage::Downloading => {
            let relative = format!("episodes/{}/audio.mp3", job.episode_id);
            let dest = artifacts.prepare_dest(&relative).map_err(|e| e.to_string())?;
            let download = downloader.fetch_to(audio_url, &dest)?;
            if download.status != 200 || !storage::is_mp3_or_octet(&download.content_type) || download.byte_count == 0 {
                let _ = fs::remove_file(&dest);
                return Err("download failed".into());
            }
            store
                .record_audio_artifact(
                    &job.id,
                    &crate::jobs::AudioArtifact {
                        relative_path: relative,
                        sha256: download.sha256,
                        byte_count: download.byte_count,
                    },
                )
                .map_err(|e| e.to_string())?;
            Ok(())
        }
        JobStage::Transcribing => {
            let audio_path = job
                .audio_artifact
                .as_ref()
                .map(|artifact| artifacts.url(&artifact.relative_path));
            let segments = transcriber.transcribe(
                job.episode_id,
                audio_path.as_deref(),
                notes_html,
                duration_secs,
            )?;
            store
                .record_transcript(&job.id, &segments, transcriber.version())
                .map_err(|e| e.to_string())?;
            Ok(())
        }
        JobStage::Classifying => {
            if api_key.trim().is_empty() {
                return Err("pause:model_required".into());
            }
            let segments = store.transcript_segments(job.episode_id).map_err(|e| e.to_string())?;
            if segments.is_empty() {
                return Err("missing transcript".into());
            }
            let ids: Vec<String> = segments.iter().map(|s| s.id.clone()).collect();
            let windows = production_windows(&ids);
            let existing = store.classification_evidence(job.episode_id).unwrap_or_default();
            let (run_id, resume_from) = largest_compatible_checkpoint(&existing, windows.len());
            let mut labels = Vec::new();
            for evidence in existing.iter().filter(|e| e.run_id == run_id && (e.window_index as usize) < resume_from && e.schema_valid) {
                if let Ok(saved) = serde_json::from_str::<Vec<(String, String, String)>>(&evidence.labels_json) {
                    labels.extend(saved);
                }
            }
            for (index, window) in windows.iter().enumerate().skip(resume_from) {
                let short = short_request_ids(window.len());
                let prompt = classification_prompt(window, &[]);
                let outcome = classifier.classify_window(&prompt, api_key)?;
                if let Some(db) = usage_db {
                    let _ = crate::usage::UsageStore::new(db).record_parsed(
                        job.episode_id,
                        "ad_detection",
                        "deepseek-v4-pro",
                        &outcome.raw,
                        crate::db::now_unix(),
                    );
                }
                let Some(raw) = outcome.content else {
                    return Err("invalid DeepSeek response".into());
                };
                let parsed = parse_structured_labels(&raw, &short).or_else(|_| parse_structured_labels(&raw, window));
                match parsed {
                    Ok(window_labels) => {
                        let mut saved = Vec::new();
                        for label in window_labels {
                            let canonical = if let Ok(idx) = label.segment_id.trim_start_matches('s').parse::<usize>() {
                                window.get(idx).cloned().unwrap_or(label.segment_id)
                            } else {
                                label.segment_id
                            };
                            saved.push((canonical.clone(), label.label.clone(), label.reason.clone()));
                            labels.push((canonical, label.label, label.reason));
                        }
                        store
                            .record_classification_evidence(
                                &job.id,
                                &crate::jobs::ClassificationEvidence {
                                    run_id: run_id.clone(),
                                    window_index: index as i64,
                                    segment_ids: window.clone(),
                                    correction_ids: vec![],
                                    prompt: prompt.clone(),
                                    raw_output: raw,
                                    schema_valid: true,
                                    validation_error: None,
                                    labels_json: serde_json::to_string(&saved).unwrap_or_else(|_| "[]".into()),
                                    model_id: "deepseek-v4-pro".into(),
                                    model_revision: "api".into(),
                                    quantization: "cloud".into(),
                                    prompt_version: "ad-classifier-v2".into(),
                                    max_context_tokens: 1_000_000,
                                    max_output_tokens: 8192,
                                    temperature: 0.0,
                                    top_p: 1.0,
                                    created_at: crate::db::now_unix(),
                                },
                            )
                            .map_err(|e| e.to_string())?;
                    }
                    Err(err) => {
                        store
                            .record_classification_evidence(
                                &job.id,
                                &crate::jobs::ClassificationEvidence {
                                    run_id: run_id.clone(),
                                    window_index: index as i64,
                                    segment_ids: window.clone(),
                                    correction_ids: vec![],
                                    prompt: prompt.clone(),
                                    raw_output: raw,
                                    schema_valid: false,
                                    validation_error: Some(err),
                                    labels_json: "[]".into(),
                                    model_id: "deepseek-v4-pro".into(),
                                    model_revision: "api".into(),
                                    quantization: "cloud".into(),
                                    prompt_version: "ad-classifier-v2".into(),
                                    max_context_tokens: 1_000_000,
                                    max_output_tokens: 8192,
                                    temperature: 0.0,
                                    top_p: 1.0,
                                    created_at: crate::db::now_unix(),
                                },
                            )
                            .map_err(|e| e.to_string())?;
                        return Err("malformed classification".into());
                    }
                }
            }
            let by_id: std::collections::HashMap<_, _> = segments.iter().map(|s| (s.id.clone(), s)).collect();
            let mut ranges = Vec::new();
            let mut index = 0;
            while index < labels.len() {
                if labels[index].1 != "ad" {
                    index += 1;
                    continue;
                }
                let start = index;
                let mut end = index;
                while end + 1 < labels.len() && labels[end + 1].1 == "ad" {
                    end += 1;
                }
                if let (Some(start_seg), Some(end_seg)) = (by_id.get(&labels[start].0), by_id.get(&labels[end].0)) {
                    ranges.push(crate::skip::AdSkipRange {
                        id: format!("ad-{}--{}", start_seg.id, end_seg.id),
                        start_segment_id: start_seg.id.clone(),
                        end_segment_id: end_seg.id.clone(),
                        start_time: start_seg.start_time,
                        end_time: end_seg.end_time,
                        confidence: 0.9,
                        reason: labels[start].2.clone(),
                        classifier_version: "deepseek-v4-pro".into(),
                        prompt_version: "ad-classifier-v2".into(),
                        created_at: crate::db::now_unix(),
                        disabled: false,
                    });
                }
                index = end + 1;
            }
            store.complete_classification(&job.id, &run_id, &ranges).map_err(|e| e.to_string())?;
            Ok(())
        }
        _ => Ok(()),
    }
}

pub fn largest_compatible_checkpoint(
    existing: &[crate::jobs::ClassificationEvidence],
    window_count: usize,
) -> (String, usize) {
    let mut by_run: std::collections::HashMap<String, Vec<i64>> = std::collections::HashMap::new();
    for evidence in existing {
        if evidence.schema_valid {
            by_run.entry(evidence.run_id.clone()).or_default().push(evidence.window_index);
        }
    }
    let mut best_run = uuid::Uuid::new_v4().to_string().to_lowercase();
    let mut best_len = 0usize;
    for (run_id, mut indexes) in by_run {
        indexes.sort_unstable();
        let mut prefix = 0usize;
        for expected in 0..window_count {
            if indexes.contains(&(expected as i64)) {
                prefix += 1;
            } else {
                break;
            }
        }
        if prefix > best_len {
            best_len = prefix;
            best_run = run_id;
        }
    }
    (best_run, best_len)
}

fn strip_html(html: &str) -> String {
    let mut out = String::new();
    let mut in_tag = false;
    for c in html.chars() {
        match c {
            '<' => in_tag = true,
            '>' => {
                in_tag = false;
                out.push(' ');
            }
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

pub fn spawn_runtime<F>(stop: Arc<std::sync::atomic::AtomicBool>, mut tick: F) -> std::thread::JoinHandle<()>
where
    F: FnMut() + Send + 'static,
{
    std::thread::spawn(move || {
        while !stop.load(std::sync::atomic::Ordering::SeqCst) {
            tick();
            std::thread::sleep(Duration::from_millis(200));
        }
    })
}

#[cfg(test)]
mod tests {
    use super::parse_parakeet_words;

    #[test]
    fn parse_parakeet_words_accepts_json_and_cli_lines() {
        let json = r#"{"words":[{"w":"This","start":0.08,"end":0.24},{"word":"Hello","start":0.4,"end":0.8},{"text":"there","start":0.8,"end":1.0}]}"#;
        let words = parse_parakeet_words(json).unwrap();
        assert_eq!(words.len(), 3);
        assert_eq!(words[0].text, "This");
        assert_eq!(words[1].text, "Hello");
        let lines = "0.48-0.64  Well,  (0.79)\n0.80-0.88  I  (1.00)\n";
        let words = parse_parakeet_words(lines).unwrap();
        assert_eq!(words[0].text, "Well");
        assert_eq!(words[0].start, 0.48);
        assert_eq!(words[1].text, "I");
    }
}

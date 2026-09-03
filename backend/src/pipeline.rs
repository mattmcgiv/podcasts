use crate::classify::{self, parse_structured_labels, production_windows, short_request_ids, classification_prompt};
use crate::jobs::{Job, JobStage, JobStore};
use crate::storage::{self, ArtifactStore, DownloadResult};
use crate::transcribe::{self, TranscriptSegment};
use std::io::Read;
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub trait AudioDownloader: Send + Sync {
    fn fetch(&self, url: &str) -> Result<DownloadResult, String>;
}

pub struct UreqDownloader;

impl AudioDownloader for UreqDownloader {
    fn fetch(&self, url: &str) -> Result<DownloadResult, String> {
        let response = ureq::get(url)
            .timeout(Duration::from_secs(60))
            .call()
            .map_err(|e| e.to_string())?;
        let status = response.status();
        let content_type = response
            .header("content-type")
            .unwrap_or("application/octet-stream")
            .to_string();
        let mut bytes = Vec::new();
        response
            .into_reader()
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        Ok(DownloadResult {
            bytes,
            content_type,
            status,
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
    fn fetch(&self, url: &str) -> Result<DownloadResult, String> {
        self.responses
            .lock()
            .unwrap()
            .get(url)
            .cloned()
            .ok_or_else(|| format!("missing mock download for {url}"))
    }
}

pub trait Transcriber: Send + Sync {
    fn transcribe(&self, episode_id: i64, notes_html: &str, duration_secs: Option<i64>) -> Result<Vec<TranscriptSegment>, String>;
}

pub struct NotesTranscriber;

impl Transcriber for NotesTranscriber {
    fn transcribe(&self, episode_id: i64, notes_html: &str, duration_secs: Option<i64>) -> Result<Vec<TranscriptSegment>, String> {
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

pub trait CloudClassifier: Send + Sync {
    fn classify_window(&self, prompt: &str, api_key: &str) -> Result<String, String>;
}

pub struct DeepSeekClassifier;

impl CloudClassifier for DeepSeekClassifier {
    fn classify_window(&self, prompt: &str, api_key: &str) -> Result<String, String> {
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
        let root: serde_json::Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
        root.pointer("/choices/0/message/content")
            .and_then(|v| v.as_str())
            .map(str::to_string)
            .ok_or_else(|| "invalid DeepSeek response".into())
    }
}

pub struct ScriptedClassifier {
    pub responses: Mutex<Vec<String>>,
}

impl CloudClassifier for ScriptedClassifier {
    fn classify_window(&self, _prompt: &str, api_key: &str) -> Result<String, String> {
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
) -> Result<(), String> {
    match stage {
        JobStage::Downloading => {
            let download = downloader.fetch(audio_url)?;
            if download.status != 200 || !storage::is_mp3_or_octet(&download.content_type) || download.bytes.is_empty() {
                return Err("download failed".into());
            }
            let relative = format!("episodes/{}/audio.mp3", job.episode_id);
            let sha = artifacts.install(&relative, &download.bytes).map_err(|e| e.to_string())?;
            store
                .record_audio_artifact(
                    &job.id,
                    &crate::jobs::AudioArtifact {
                        relative_path: relative,
                        sha256: sha,
                        byte_count: download.bytes.len() as i64,
                    },
                )
                .map_err(|e| e.to_string())?;
            Ok(())
        }
        JobStage::Transcribing => {
            let segments = transcriber.transcribe(job.episode_id, notes_html, duration_secs)?;
            store
                .record_transcript(&job.id, &segments, "notes-transcriber-v1")
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
            let mut labels = Vec::new();
            let run_id = uuid::Uuid::new_v4().to_string().to_lowercase();
            for (index, window) in windows.iter().enumerate() {
                let short = short_request_ids(window.len());
                let prompt = classification_prompt(window, &[]);
                let raw = classifier.classify_window(&prompt, api_key)?;
                let parsed = parse_structured_labels(&raw, &short).or_else(|_| parse_structured_labels(&raw, window));
                match parsed {
                    Ok(window_labels) => {
                        for label in window_labels {
                            let canonical = if let Ok(idx) = label.segment_id.trim_start_matches('s').parse::<usize>() {
                                window.get(idx).cloned().unwrap_or(label.segment_id)
                            } else {
                                label.segment_id
                            };
                            labels.push((canonical, label.label, label.reason));
                        }
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

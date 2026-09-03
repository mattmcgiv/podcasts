use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use uuid::Uuid;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct DiagnosticEvent {
    pub event_name: String,
    pub severity: String,
    pub message: String,
    pub job_id: Option<String>,
    pub episode_id: Option<i64>,
    pub playback_session_id: Option<String>,
}

impl DiagnosticEvent {
    pub fn redacted(mut self) -> Self {
        if self.message.contains("sk-") {
            self.message = "[redacted]".into();
        }
        self.message = self
            .message
            .split_whitespace()
            .map(|token| {
                if token.len() > 24 && token.chars().any(|c| c.is_ascii_hexdigit()) && token.contains("key") {
                    "[redacted]"
                } else {
                    token
                }
            })
            .collect::<Vec<_>>()
            .join(" ");
        self
    }
}

pub fn make_playback_session_id() -> String {
    Uuid::new_v4().to_string().to_lowercase()
}

pub fn attach_session(payload: &mut serde_json::Value, session_id: &str) {
    if let Some(obj) = payload.as_object_mut() {
        obj.insert("playbackSessionId".into(), serde_json::Value::String(session_id.into()));
    }
}

pub fn session_from_payload(payload: &serde_json::Value) -> Option<String> {
    payload.get("playbackSessionId").and_then(|v| v.as_str()).filter(|s| !s.is_empty()).map(str::to_string)
}

pub struct Diagnostics {
    root: PathBuf,
    retain: usize,
}

impl Diagnostics {
    pub fn open(root: PathBuf) -> std::io::Result<Self> {
        fs::create_dir_all(root.join("logs"))?;
        fs::create_dir_all(root.join("snapshots"))?;
        Ok(Self { root, retain: 5 })
    }

    pub fn retain_count(&self) -> usize {
        self.retain
    }

    pub fn record(&self, event: DiagnosticEvent) -> std::io::Result<()> {
        let event = event.redacted();
        let path = self.root.join("logs").join("current.jsonl");
        let mut line = serde_json::to_string(&event).unwrap_or_default();
        line.push('\n');
        fs::OpenOptions::new().create(true).append(true).open(path)?.write_all(line.as_bytes())
    }

    pub fn rotate_if_needed(&self, max_files: usize) -> std::io::Result<()> {
        let dir = self.root.join("logs");
        let mut files: Vec<_> = fs::read_dir(&dir)?
            .filter_map(|e| e.ok())
            .filter(|e| e.path().extension().and_then(|s| s.to_str()) == Some("jsonl"))
            .collect();
        files.sort_by_key(|e| e.file_name());
        while files.len() > max_files {
            let _ = fs::remove_file(files.remove(0).path());
        }
        Ok(())
    }

    pub fn record_rotating(&self, event: DiagnosticEvent, max_bytes: usize, retain: usize) -> std::io::Result<()> {
        let event = event.redacted();
        let dir = self.root.join("logs");
        fs::create_dir_all(&dir)?;
        let mut files: Vec<_> = fs::read_dir(&dir)?
            .filter_map(|e| e.ok())
            .filter(|e| e.path().extension().and_then(|s| s.to_str()) == Some("jsonl"))
            .collect();
        files.sort_by_key(|e| e.file_name());
        let current = if let Some(last) = files.last() {
            last.path()
        } else {
            dir.join("ad-removal-00.jsonl")
        };
        let size = fs::metadata(&current).map(|m| m.len()).unwrap_or(0) as usize;
        let path = if size >= max_bytes {
            let index = files.len();
            dir.join(format!("ad-removal-{index:02}.jsonl"))
        } else {
            current
        };
        let mut line = serde_json::to_string(&event).unwrap_or_default();
        line.push('\n');
        fs::OpenOptions::new().create(true).append(true).open(&path)?.write_all(line.as_bytes())?;
        self.rotate_if_needed(retain)
    }

    pub fn save_snapshot(&self, job_id: &str, body: &str, retain: usize) -> std::io::Result<()> {
        let dir = self.root.join("snapshots");
        fs::create_dir_all(&dir)?;
        fs::write(dir.join(format!("{job_id}.json")), body)?;
        let mut files: Vec<_> = fs::read_dir(&dir)?.filter_map(|e| e.ok()).collect();
        files.sort_by_key(|e| e.file_name());
        while files.len() > retain {
            let _ = fs::remove_file(files.remove(0).path());
        }
        Ok(())
    }

    pub fn snapshot_ids(&self) -> std::io::Result<Vec<String>> {
        let dir = self.root.join("snapshots");
        let mut files: Vec<_> = fs::read_dir(&dir)?.filter_map(|e| e.ok()).collect();
        files.sort_by_key(|e| e.file_name());
        Ok(files
            .into_iter()
            .filter_map(|e| e.path().file_stem().map(|s| s.to_string_lossy().into_owned()))
            .collect())
    }

    pub fn log_names(&self) -> std::io::Result<Vec<String>> {
        let dir = self.root.join("logs");
        let mut files: Vec<_> = fs::read_dir(&dir)?
            .filter_map(|e| e.ok())
            .filter(|e| e.path().extension().and_then(|s| s.to_str()) == Some("jsonl"))
            .collect();
        files.sort_by_key(|e| e.file_name());
        Ok(files
            .into_iter()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect())
    }

    pub fn clear(&self) -> std::io::Result<()> {
        for dir in ["logs", "snapshots"] {
            let path = self.root.join(dir);
            if path.exists() {
                fs::remove_dir_all(&path)?;
            }
            fs::create_dir_all(path)?;
        }
        Ok(())
    }

    pub fn export_zip(&self, dest: &Path) -> std::io::Result<()> {
        let file = fs::File::create(dest)?;
        let mut zip = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default();
        zip.start_file("manifest.json", options)?;
        std::io::Write::write_all(&mut zip, br#"{"version":1}"#)?;
        zip.start_file("state-summary.json", options)?;
        std::io::Write::write_all(&mut zip, br#"{}"#)?;
        if let Ok(logs) = self.log_names() {
            for name in logs {
                let path = self.root.join("logs").join(&name);
                if let Ok(bytes) = fs::read(&path) {
                    zip.start_file(format!("iphone/logs/{name}"), options)?;
                    std::io::Write::write_all(&mut zip, &bytes)?;
                }
            }
        }
        zip.finish()?;
        Ok(())
    }
}

use std::io::Write;

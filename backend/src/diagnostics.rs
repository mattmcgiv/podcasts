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

    pub fn record(&self, event: DiagnosticEvent) -> std::io::Result<()> {
        let event = event.redacted();
        let path = self.root.join("logs").join("current.jsonl");
        let mut line = serde_json::to_string(&event).unwrap_or_default();
        line.push('\n');
        fs::OpenOptions::new().create(true).append(true).open(path)?.write_all(line.as_bytes())
    }

    pub fn rotate_if_needed(&self, max_files: usize) -> std::io::Result<()> {
        let dir = self.root.join("logs");
        let mut files: Vec<_> = fs::read_dir(&dir)?.filter_map(|e| e.ok()).collect();
        files.sort_by_key(|e| e.file_name());
        while files.len() > max_files {
            let _ = fs::remove_file(files.remove(0).path());
        }
        Ok(())
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
        zip.finish()?;
        Ok(())
    }
}

use std::io::Write;

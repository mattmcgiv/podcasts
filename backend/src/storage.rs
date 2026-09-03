use crate::jobs::valid_artifact_path;
use sha2::{Digest, Sha256};
use std::fs;
use std::path::PathBuf;

#[derive(Clone, Debug)]
pub struct ArtifactStore {
    root: PathBuf,
}

impl ArtifactStore {
    pub fn open(root: PathBuf) -> std::io::Result<Self> {
        fs::create_dir_all(&root)?;
        Ok(Self { root })
    }

    pub fn install(&self, relative_path: &str, bytes: &[u8]) -> std::io::Result<String> {
        if !valid_artifact_path(relative_path) {
            return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "untrusted path"));
        }
        let dest = self.root.join(relative_path);
        if let Some(parent) = dest.parent() {
            fs::create_dir_all(parent)?;
        }
        let tmp = dest.with_extension("tmp");
        fs::write(&tmp, bytes)?;
        fs::rename(&tmp, &dest)?;
        Ok(hex::encode(Sha256::digest(bytes)))
    }

    pub fn validate(&self, relative_path: &str, sha256: &str, byte_count: i64) -> bool {
        if !valid_artifact_path(relative_path) {
            return false;
        }
        let dest = self.root.join(relative_path);
        let Ok(bytes) = fs::read(&dest) else { return false };
        bytes.len() as i64 == byte_count && hex::encode(Sha256::digest(&bytes)) == sha256
    }

    pub fn remove(&self, relative_path: &str) -> std::io::Result<()> {
        if !valid_artifact_path(relative_path) {
            return Ok(());
        }
        let dest = self.root.join(relative_path);
        if dest.exists() {
            fs::remove_file(dest)?;
        }
        Ok(())
    }

    pub fn url(&self, relative_path: &str) -> PathBuf {
        self.root.join(relative_path)
    }
}

pub fn storage_allows(episode_bytes: i64, limit: i64, available: i64, minimum_free: i64, incoming: i64) -> bool {
    episode_bytes + incoming <= limit && available - incoming >= minimum_free
}

pub fn is_mp3_or_octet(content_type: &str) -> bool {
    let t = content_type.to_lowercase();
    t.contains("audio/mpeg") || t.contains("audio/mp3") || t == "application/octet-stream" || t == "binary/octet-stream"
}

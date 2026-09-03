use crate::error::Error;
use rusqlite::Connection;
use std::fs;
use std::path::{Path, PathBuf};

pub fn prepare(live: &Path, seed: Option<&Path>) -> Result<PathBuf, Error> {
    if !live.exists() {
        if let Some(seed) = seed {
            if let Some(parent) = live.parent() {
                fs::create_dir_all(parent).map_err(|e| Error::Database(e.to_string()))?;
            }
            fs::copy(seed, live).map_err(|e| Error::Database(e.to_string()))?;
        }
    }
    if live.exists() {
        if validate_schema(live).is_err() {
            if let Some(seed) = seed {
                let _ = fs::remove_file(live);
                fs::copy(seed, live).map_err(|e| Error::Database(e.to_string()))?;
                validate_schema(live)?;
            }
        } else if should_replace_empty(live, seed)? {
            if let Some(seed) = seed {
                let _ = fs::remove_file(live);
                fs::copy(seed, live).map_err(|e| Error::Database(e.to_string()))?;
            }
        }
    }
    Ok(live.to_path_buf())
}

fn validate_schema(path: &Path) -> Result<(), Error> {
    let conn = Connection::open(path)?;
    for table in ["podcasts", "episodes", "episode_state", "settings", "episodes_fts"] {
        let exists: Option<String> = conn
            .query_row("SELECT name FROM sqlite_master WHERE name = ? LIMIT 1", [table], |r| r.get(0))
            .optional()
            .map_err(|e| Error::Database(e.to_string()))?;
        if exists.is_none() {
            return Err(Error::Database("schema invalid".into()));
        }
    }
    Ok(())
}

fn should_replace_empty(live: &Path, seed: Option<&Path>) -> Result<bool, Error> {
    if seed.is_none() {
        return Ok(false);
    }
    let conn = Connection::open(live)?;
    let count: i64 = conn.query_row("SELECT COUNT(*) FROM podcasts", [], |r| r.get(0))?;
    Ok(count == 0)
}

use rusqlite::OptionalExtension;

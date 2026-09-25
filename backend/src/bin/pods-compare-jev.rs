//! Compare Jev Noul labels to cached oMLX labels for one episode.
//!
//! Does not overwrite oMLX `labels-*.json`. Writes `jev-compare.json` next to
//! the transcript and prints the same JSON on stdout.
//!
//! Usage: pods-compare-jev EPISODE_ID
//!        pods-compare-jev --dir /path/to/episode

use pods_backend::jev;
use serde_json::json;
use std::path::PathBuf;
use std::process::ExitCode;

fn main() -> ExitCode {
    match run(std::env::args().skip(1).collect()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error}");
            ExitCode::FAILURE
        }
    }
}

fn run(args: Vec<String>) -> Result<(), String> {
    let work = work_dir(&args)?;
    if jev::configured_api_key().is_err() {
        return Err(
            "TypeSafe credentials unavailable. Add TYPESAFE_API_KEY to ~/.config/podcasts/credentials.env (mode 0600), or export PODS_TYPESAFE_KEY."
                .into(),
        );
    }
    let comparison = jev::compare_episode_dir(&work).map_err(|error| error.to_string())?;
    let encoded = serde_json::to_vec_pretty(&comparison).map_err(|error| error.to_string())?;
    let out = work.join("jev-compare.json");
    std::fs::write(&out, &encoded).map_err(|error| error.to_string())?;
    println!("{}", String::from_utf8_lossy(&encoded));
    eprintln!(
        "{}",
        json!({
            "wrote": out.display().to_string(),
            "jev_elapsed_ms": comparison.jev_elapsed_ms,
            "matches": comparison.matches,
            "mismatch_count": comparison.mismatch_count,
            "omlx_ad_ranges": comparison.omlx_ad_ranges,
            "jev_ad_ranges": comparison.jev_ad_ranges,
        })
    );
    Ok(())
}

fn work_dir(args: &[String]) -> Result<PathBuf, String> {
    match args {
        [] => Err("usage: pods-compare-jev EPISODE_ID | --dir PATH".into()),
        [flag, path] if flag == "--dir" => Ok(PathBuf::from(path)),
        [id] => {
            let episode: i64 = id.parse().map_err(|_| format!("invalid episode id {id}"))?;
            Ok(jev::default_episode_dir(episode))
        }
        _ => Err("usage: pods-compare-jev EPISODE_ID | --dir PATH".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    #[test]
    fn work_dir_parses_episode_id_and_dir_flag() {
        assert!(work_dir(&[]).is_err());
        assert!(work_dir(&["abc".to_string()]).is_err());
        assert!(work_dir(&["a".to_string(), "b".to_string(), "c".to_string()]).is_err());
        let dir = work_dir(&["--dir".to_string(), "/tmp/x".to_string()]).unwrap();
        assert_eq!(dir, PathBuf::from("/tmp/x"));
        let episode = work_dir(&["42".to_string()]).unwrap();
        assert!(episode.ends_with("42"));
    }

    #[test]
    fn run_rejects_empty_args() {
        assert!(run(vec![]).is_err());
    }

    #[test]
    fn run_fails_fast_without_transcript() {
        let _lock = ENV_LOCK.lock().unwrap();
        let dir = tempfile::tempdir().unwrap();
        let creds = dir.path().join("credentials.env");
        std::fs::write(&creds, "TYPESAFE_API_KEY=test-key\n").unwrap();
        let previous = std::env::var("PODS_CREDENTIALS_FILE").ok();
        let previous_key = std::env::var("PODS_TYPESAFE_KEY").ok();
        let previous_alt = std::env::var("TYPESAFE_API_KEY").ok();
        std::env::set_var("PODS_CREDENTIALS_FILE", &creds);
        std::env::remove_var("PODS_TYPESAFE_KEY");
        std::env::remove_var("TYPESAFE_API_KEY");
        let result = run(vec!["--dir".to_string(), dir.path().to_string_lossy().into_owned()]);
        match previous {
            Some(value) => std::env::set_var("PODS_CREDENTIALS_FILE", value),
            None => std::env::remove_var("PODS_CREDENTIALS_FILE"),
        }
        match previous_key {
            Some(value) => std::env::set_var("PODS_TYPESAFE_KEY", value),
            None => std::env::remove_var("PODS_TYPESAFE_KEY"),
        }
        match previous_alt {
            Some(value) => std::env::set_var("TYPESAFE_API_KEY", value),
            None => std::env::remove_var("TYPESAFE_API_KEY"),
        }
        assert!(result.is_err());
    }
}

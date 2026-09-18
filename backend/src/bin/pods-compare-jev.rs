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

//! Compare request strategies without changing live pipeline checkpoints.
//! Usage: pods-evaluate-jev TRANSCRIPT_JSON OUTPUT_JSON legacy|adaptive|whole
use pods_backend::{jev, local_worker::{validate_segments, refine_boundaries, Segment, WINDOW_CORE, WINDOW_CONTEXT}};
use serde_json::json;
use std::{fs::OpenOptions, io::Write};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    run(&std::env::args().skip(1).collect::<Vec<_>>())
}

fn run(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    if args.len()!=3 || !["legacy","adaptive","whole"].contains(&args[2].as_str()) {
        return Err("usage: pods-evaluate-jev TRANSCRIPT_JSON OUTPUT_JSON legacy|adaptive|whole".into());
    }
    let segments:Vec<Segment>=serde_json::from_slice(&std::fs::read(&args[0])?)?;
    validate_segments(&segments)?;
    let mut output=OpenOptions::new().create_new(true).write(true).open(&args[1])?;
    let ranges=match args[2].as_str() {
        "legacy" => (0..segments.len()).step_by(WINDOW_CORE).map(|s|(s,(s+WINDOW_CORE).min(segments.len()))).collect(),
        "adaptive" => jev::batch_ranges(&segments)?,
        _ => vec![(0,segments.len())],
    };
    let mut windows=Vec::new(); let mut labels=Vec::new();
    for (start,end) in ranges {
        let result=if args[2]=="legacy" {jev::classify_legacy_window(&segments,start,end)?}
            else {jev::classify_window_timed(&segments,start,end,WINDOW_CONTEXT)?};
        eprintln!("{} segments {start}..{end}: {}ms, {} input tokens", args[2],result.elapsed_ms,result.input_tokens);
        labels.extend(result.labels.iter().cloned()); windows.push(result);
    }
    let refined=refine_boundaries(&segments,&labels)?;
    let report=json!({"strategy":args[2],"model":jev::MODEL,"classifier_version":jev::CLASSIFIER_VERSION,
        "segments":segments.len(),"requests":windows.iter().map(|w|w.requests).sum::<u32>(),"elapsed_ms":windows.iter().map(|w|w.elapsed_ms).sum::<u128>(),
        "input_tokens":windows.iter().map(|w|w.input_tokens).sum::<u64>(),"windows":windows,"labels":labels,"refined":refined});
    output.write_all(&serde_json::to_vec_pretty(&report)?)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| value.to_string()).collect()
    }

    #[test]
    fn run_validates_args_and_transcript() {
        assert!(run(&args(&[])).is_err());
        assert!(run(&args(&["a", "b", "bogus"])).is_err());
        assert!(run(&args(&["/nonexistent-cov-transcript.json", "/tmp/x.json", "whole"])).is_err());
        let dir = tempfile::tempdir().unwrap();
        let transcript = dir.path().join("transcript.json");
        std::fs::write(&transcript, "not json").unwrap();
        let out = dir.path().join("out.json");
        let result = run(&args(&[
            transcript.to_str().unwrap(),
            out.to_str().unwrap(),
            "whole",
        ]));
        assert!(result.is_err());
    }
}

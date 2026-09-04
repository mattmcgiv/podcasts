use pods_backend::pipeline::parse_parakeet_words;
use pods_backend::server::{parse_request, ParseResult};
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Mutex;

fn env_or(key: &str, fallback: &str) -> String {
    std::env::var(key).ok().filter(|s| !s.is_empty()).unwrap_or_else(|| fallback.to_string())
}

fn main() {
    let _ = std::fs::write("/proc/self/oom_score_adj", "200");
    let addr = env_or("PODS_BIND", "0.0.0.0:18181");
    let listener = TcpListener::bind(&addr).expect("listen");
    eprintln!("pods-transcribe listening on {addr}");
    let lock = Mutex::new(());
    for stream in listener.incoming().flatten() {
        let _guard = lock.lock().unwrap();
        if let Err(err) = handle(stream) {
            eprintln!("pods-transcribe: {err}");
        }
    }
}

fn handle(mut stream: TcpStream) -> Result<(), String> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        let n = stream.read(&mut chunk).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&chunk[..n]);
        match parse_request(&buf) {
            ParseResult::Incomplete => continue,
            ParseResult::Invalid(err) => {
                write_http(&mut stream, 400, &json!({"error": err}))?;
                return Ok(());
            }
            ParseResult::Complete { method, target, body, .. } => {
                if method != "POST" || !target.starts_with("/transcribe") {
                    write_http(&mut stream, 404, &json!({"error": "not found"}))?;
                    return Ok(());
                }
                let payload: Value = serde_json::from_slice(&body).map_err(|e| e.to_string())?;
                let audio_path = payload
                    .get("audio_path")
                    .and_then(Value::as_str)
                    .ok_or_else(|| "audio_path is required".to_string())?;
                match transcribe(Path::new(audio_path)) {
                    Ok(words) => write_http(&mut stream, 200, &json!({ "words": words }))?,
                    Err(err) => {
                        eprintln!("pods-transcribe: {err}");
                        write_http(&mut stream, 500, &json!({ "error": err }))?;
                    }
                }
                return Ok(());
            }
        }
    }
    Ok(())
}

const CHUNK_SECS: f64 = 180.0;

fn transcribe(audio_path: &Path) -> Result<Vec<Value>, String> {
    if !audio_path.is_file() {
        return Err(format!("audio file is missing: {}", audio_path.display()));
    }
    let _ = std::fs::write("/proc/self/oom_score_adj", "800");
    let pid = std::process::id();
    let wav = PathBuf::from(format!("/tmp/pods-{pid}.wav"));
    let ffmpeg = env_or("PODS_FFMPEG", "ffmpeg");
    let status = Command::new("nice")
        .args(["-n", "19", &ffmpeg, "-y", "-i"])
        .arg(audio_path)
        .args(["-ac", "1", "-ar", "16000", "-f", "wav"])
        .arg(&wav)
        .status()
        .map_err(|e| e.to_string())?;
    if !status.success() {
        let _ = std::fs::remove_file(&wav);
        return Err("ffmpeg failed".into());
    }
    let duration = wav_duration_secs(&wav).unwrap_or(CHUNK_SECS);
    let mut words = Vec::new();
    let mut offset = 0.0;
    while offset < duration {
        let chunk = PathBuf::from(format!("/tmp/pods-{pid}-{}.wav", offset as u64));
        let status = Command::new("nice")
            .args(["-n", "19", &ffmpeg, "-y", "-ss"])
            .arg(format!("{offset:.3}"))
            .arg("-t")
            .arg(format!("{CHUNK_SECS:.3}"))
            .arg("-i")
            .arg(&wav)
            .args(["-ac", "1", "-ar", "16000", "-f", "wav"])
            .arg(&chunk)
            .status()
            .map_err(|e| e.to_string())?;
        if !status.success() {
            let _ = std::fs::remove_file(&chunk);
            let _ = std::fs::remove_file(&wav);
            return Err(format!("ffmpeg chunk at {offset:.0}s failed"));
        }
        match transcribe_wav(&chunk) {
            Ok(chunk_words) => {
                for mut word in chunk_words {
                    word.start += offset;
                    word.end += offset;
                    words.push(word);
                }
            }
            Err(err) => {
                let _ = std::fs::remove_file(&chunk);
                let _ = std::fs::remove_file(&wav);
                return Err(err);
            }
        }
        let _ = std::fs::remove_file(&chunk);
        offset += CHUNK_SECS;
    }
    let _ = std::fs::remove_file(&wav);
    if words.is_empty() {
        return Err("parakeet produced no words".into());
    }
    Ok(words
        .into_iter()
        .map(|w| json!({"word": w.text, "start": w.start, "end": w.end}))
        .collect())
}

fn wav_duration_secs(path: &Path) -> Result<f64, String> {
    let output = Command::new("ffprobe")
        .args([
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "csv=p=0",
        ])
        .arg(path)
        .output()
        .map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err("ffprobe failed".into());
    }
    String::from_utf8_lossy(&output.stdout)
        .trim()
        .parse::<f64>()
        .map_err(|_| "ffprobe duration is invalid".into())
}

fn transcribe_wav(wav: &Path) -> Result<Vec<pods_backend::transcribe::TimedWord>, String> {
    let bin = env_or("PODS_PARAKEET_BIN", "parakeet-cli");
    let model = env_or("PODS_PARAKEET_MODEL", "/models/tdt_ctc-110m-q8_0.gguf");
    let output = Command::new("nice")
        .args(["-n", "19", &bin, "transcribe", "--model"])
        .arg(&model)
        .arg("--input")
        .arg(wav)
        .args(["--timestamps", "--json", "--threads", "1"])
        .output()
        .map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).into_owned());
    }
    parse_parakeet_words(&String::from_utf8_lossy(&output.stdout))
}

fn write_http(stream: &mut TcpStream, status: u16, body: &Value) -> Result<(), String> {
    let payload = serde_json::to_vec(body).map_err(|e| e.to_string())?;
    let reason = if status == 200 { "OK" } else { "Error" };
    let header = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        payload.len()
    );
    stream.write_all(header.as_bytes()).map_err(|e| e.to_string())?;
    stream.write_all(&payload).map_err(|e| e.to_string())?;
    Ok(())
}

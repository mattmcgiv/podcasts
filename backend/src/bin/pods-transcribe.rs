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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::io::Write;
    use std::net::{TcpListener, TcpStream};
    use std::time::Duration;

    static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn exchange(payload: &[u8]) -> (u16, String) {
        exchange_fallible(payload).unwrap()
    }

    fn exchange_fallible(payload: &[u8]) -> Result<(u16, String), String> {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            handle(stream)
        });
        let mut client = TcpStream::connect_timeout(&addr, Duration::from_secs(2)).unwrap();
        client.write_all(payload).unwrap();
        client.shutdown(std::net::Shutdown::Write).unwrap();
        let mut buf = Vec::new();
        let mut c = client;
        std::io::Read::read_to_end(&mut c, &mut buf).unwrap();
        server.join().unwrap()?;
        let text = String::from_utf8_lossy(&buf);
        let status = text
            .split_whitespace()
            .nth(1)
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        Ok((status, text.into_owned()))
    }

    fn post_transcribe(body: &[u8]) -> Vec<u8> {
        let header = format!(
            "POST /transcribe HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n",
            body.len()
        );
        let mut payload = header.into_bytes();
        payload.extend_from_slice(body);
        payload
    }

    fn with_env(vars: &[(&str, Option<&str>)]) -> EnvRestore {
        let _lock = ENV_LOCK.lock().unwrap();
        let saved: Vec<(String, Option<String>)> = vars
            .iter()
            .map(|(key, _)| (key.to_string(), std::env::var(key).ok()))
            .collect();
        for (key, value) in vars {
            match value {
                Some(v) => std::env::set_var(key, v),
                None => std::env::remove_var(key),
            }
        }
        EnvRestore { saved, _lock: _lock }
    }

    struct EnvRestore {
        saved: Vec<(String, Option<String>)>,
        _lock: std::sync::MutexGuard<'static, ()>,
    }

    impl Drop for EnvRestore {
        fn drop(&mut self) {
            for (key, value) in &self.saved {
                match value {
                    Some(v) => std::env::set_var(key, v),
                    None => std::env::remove_var(key),
                }
            }
        }
    }

    #[test]
    fn env_or_uses_fallback_and_set_value() {
        assert_eq!(env_or("PODS_TRANSCRIBE_TEST_MISSING", "fb"), "fb");
        std::env::set_var("PODS_TRANSCRIBE_TEST_MISSING", "set");
        assert_eq!(env_or("PODS_TRANSCRIBE_TEST_MISSING", "fb"), "set");
        std::env::remove_var("PODS_TRANSCRIBE_TEST_MISSING");
    }

    #[test]
    fn handle_rejects_invalid_incomplete_and_wrong_route() {
        let (status, body) = exchange(b"GET /nope HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n");
        assert_eq!(status, 404);
        assert!(body.contains("not found"));
        let (status, _) = exchange(b"!!!\r\n\r\n");
        assert_eq!(status, 400);
        let body = br#"{"audio_path":"/nope.wav"}"#;
        let header = format!(
            "POST /transcribe HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n",
            body.len()
        );
        let mut payload = header.into_bytes();
        payload.extend_from_slice(body);
        let (status, text) = exchange(&payload);
        assert_eq!(status, 500);
        assert!(text.contains("missing") || text.contains("error"));
    }

    #[test]
    fn transcribe_missing_file_and_write_http() {
        let err = transcribe(Path::new("/no/such/audio.wav")).unwrap_err();
        assert!(err.contains("missing"));
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            write_http(&mut stream, 200, &json!({"ok":true})).unwrap();
        });
        let mut client = TcpStream::connect_timeout(&addr, Duration::from_secs(2)).unwrap();
        let mut buf = Vec::new();
        std::io::Read::read_to_end(&mut client, &mut buf).unwrap();
        server.join().unwrap();
        assert!(String::from_utf8_lossy(&buf).contains("200 OK"));
    }

    #[test]
    fn transcribe_runs_fake_ffmpeg_ffprobe_and_parakeet() {
        let _lock = ENV_LOCK.lock().unwrap();
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("bin");
        std::fs::create_dir(&bin).unwrap();
        let wav = dir.path().join("fixture.wav");
        std::fs::write(&wav, b"RIFF").unwrap();
        let ffmpeg = bin.join("ffmpeg");
        std::fs::write(
            &ffmpeg,
            "#!/bin/sh\nout=\"$1\"\nfor a in \"$@\"; do out=\"$a\"; done\nif [ \"$out\" = \"-\" ]; then echo out_time_us=1000000; exit 0; fi\ncp \"$PODS_FAKE_WAV\" \"$out\"\n",
        )
        .unwrap();
        let ffprobe = bin.join("ffprobe");
        std::fs::write(&ffprobe, "#!/bin/sh\necho 0.5\n").unwrap();
        let parakeet = bin.join("parakeet-cli");
        std::fs::write(
            &parakeet,
            "#!/bin/sh\necho '{\"words\":[{\"word\":\"hi\",\"start\":0.0,\"end\":0.2}]}'\n",
        )
        .unwrap();
        for p in [&ffmpeg, &ffprobe, &parakeet] {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o755)).unwrap();
            }
        }
        let prev_path = std::env::var("PATH").unwrap();
        let prev_fake = std::env::var("PODS_FAKE_WAV").ok();
        let prev_ffmpeg = std::env::var("PODS_FFMPEG").ok();
        let prev_parakeet = std::env::var("PODS_PARAKEET_BIN").ok();
        std::env::set_var("PATH", format!("{}:{}", bin.display(), prev_path));
        std::env::set_var("PODS_FAKE_WAV", wav.to_str().unwrap());
        std::env::set_var("PODS_FFMPEG", ffmpeg.to_str().unwrap());
        std::env::set_var("PODS_PARAKEET_BIN", parakeet.to_str().unwrap());
        let src = dir.path().join("src.mp3");
        std::fs::write(&src, b"data").unwrap();
        let words = transcribe(&src).unwrap();
        assert_eq!(words[0]["word"], "hi");
        assert!(wav_duration_secs(&wav).unwrap() > 0.0);
        let words = transcribe_wav(&wav).unwrap();
        assert_eq!(words[0].text, "hi");
        std::fs::write(&ffprobe, "#!/bin/sh\nexit 1\n").unwrap();
        assert!(wav_duration_secs(&wav).is_err());
        std::fs::write(&ffmpeg, "#!/bin/sh\nexit 1\n").unwrap();
        assert!(transcribe(&src).unwrap_err().contains("ffmpeg"));
        std::fs::write(
            &ffmpeg,
            "#!/bin/sh\nout=\"$1\"\nfor a in \"$@\"; do out=\"$a\"; done\ncp \"$PODS_FAKE_WAV\" \"$out\"\n",
        )
        .unwrap();
        std::fs::write(&ffprobe, "#!/bin/sh\necho 0.5\n").unwrap();
        std::fs::write(&parakeet, "#!/bin/sh\necho '{}'\n").unwrap();
        assert!(transcribe_wav(&wav).is_err());
        std::env::set_var("PATH", prev_path);
        match prev_fake {
            Some(value) => std::env::set_var("PODS_FAKE_WAV", value),
            None => std::env::remove_var("PODS_FAKE_WAV"),
        }
        match prev_ffmpeg {
            Some(value) => std::env::set_var("PODS_FFMPEG", value),
            None => std::env::remove_var("PODS_FFMPEG"),
        }
        match prev_parakeet {
            Some(value) => std::env::set_var("PODS_PARAKEET_BIN", value),
            None => std::env::remove_var("PODS_PARAKEET_BIN"),
        }
    }

    #[test]
    fn handle_rejects_malformed_transcribe_payload() {
        let bad = post_transcribe(b"not json");
        assert!(exchange_fallible(&bad).is_err());
        let missing = post_transcribe(br#"{"other": 1}"#);
        assert!(exchange_fallible(&missing).is_err());
    }

    #[test]
    fn transcribe_reports_missing_ffmpeg_binary() {
        let _env = with_env(&[("PODS_FFMPEG", Some("/nonexistent-cov-ffmpeg"))]);
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("src.mp3");
        std::fs::write(&src, b"data").unwrap();
        assert!(transcribe(&src).is_err());
    }

    #[test]
    fn transcribe_reports_vanishing_ffmpeg_binary() {
        let dir = tempfile::tempdir().unwrap();
        let stub = dir.path().join("ffmpeg");
        std::fs::write(&stub, "#!/bin/sh\nrm -f -- \"$0\"\nexit 0\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let _env = with_env(&[("PODS_FFMPEG", stub.to_str())]);
        let src = dir.path().join("src.mp3");
        std::fs::write(&src, b"data").unwrap();
        assert!(transcribe(&src).is_err());
    }

    #[test]
    fn wav_duration_reports_missing_and_garbage_ffprobe() {
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("bin");
        std::fs::create_dir(&bin).unwrap();
        let wav = dir.path().join("fixture.wav");
        std::fs::write(&wav, b"RIFF").unwrap();
        let nice = ["/usr/bin/nice", "/bin/nice"]
            .into_iter()
            .map(std::path::PathBuf::from)
            .find(|path| path.is_file())
            .unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(&nice, bin.join("nice")).unwrap();
        let _env = with_env(&[("PATH", bin.to_str())]);
        assert!(wav_duration_secs(&wav).is_err());
        let ffprobe = bin.join("ffprobe");
        std::fs::write(&ffprobe, "#!/bin/sh\necho bogus\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&ffprobe, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        assert!(wav_duration_secs(&wav).is_err());
    }

    #[test]
    fn transcribe_wav_reports_missing_parakeet_binary() {
        let _env = with_env(&[("PODS_PARAKEET_BIN", Some("/nonexistent-cov-parakeet"))]);
        let dir = tempfile::tempdir().unwrap();
        let wav = dir.path().join("fixture.wav");
        std::fs::write(&wav, b"RIFF").unwrap();
        assert!(transcribe_wav(&wav).is_err());
    }
}


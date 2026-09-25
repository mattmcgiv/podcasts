//! Spoken feedback notes. The browser stores the recording first, then uploads
//! the bytes here. Whisper large-v3 writes a transcript. The note is not a
//! report until the user confirms that text through the JSON `feedback` action.
use crate::local_worker::transcribe_audio;
use crate::{Backend, Error, HttpRequest, HttpResponse};
use rusqlite::{params, OptionalExtension};
use serde_json::json;

const MAX_BYTES: usize = 4_000_000;
const MIN_BYTES: usize = 32;
/// Matches the client composer limit so a confirmed transcript still submits.
const MAX_TRANSCRIPT_BYTES: usize = 4000;
const MAX_ATTEMPTS: i64 = 3;
const RUNNING_TIMEOUT_SECS: i64 = 900;
const FAILURE_BACKOFF_SECS: i64 = 60;

pub fn handle(backend: &Backend, request: &HttpRequest) -> Result<HttpResponse, Error> {
    let path = request.path();
    if path == "/api/feedback/voice" && request.method == "POST" {
        return accept(backend, request);
    }
    if let Some(id) = path.strip_prefix("/api/feedback/voice/") {
        if id.is_empty() || id.contains('/') {
            return Err(Error::NotFound);
        }
        return match request.method.as_str() {
            "GET" => status(backend, request, id),
            "DELETE" => remove(backend, request, id),
            _ => Err(Error::Invalid("use GET or DELETE".into())),
        };
    }
    Err(Error::NotFound)
}

/// Claim one due note and transcribe it. Gate failures wait without using an attempt.
pub fn step(backend: &Backend) -> Result<bool, Error> {
    let now = crate::db::now_unix();
    backend.db.execute(
        "UPDATE browser_voice_notes SET status='queued', next_at=0, started_at=0 WHERE status='running' AND started_at<?",
        [now - RUNNING_TIMEOUT_SECS],
    )?;
    let note: Option<(String, i64)> = {
        let conn = backend.db.lock()?;
        conn.query_row(
            "SELECT id, attempts FROM browser_voice_notes WHERE status='queued' AND next_at<=? ORDER BY created_at LIMIT 1",
            [now],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?
    };
    let Some((id, attempts)) = note else {
        return Ok(false);
    };
    let relative = audio_relative(&id);
    let path = backend.artifacts.url(&relative);
    if !path.is_file() {
        finish(
            backend,
            &id,
            "failed",
            None,
            "The recording did not arrive.",
        )?;
        return Ok(true);
    }
    if let Err(error) = crate::power_gate::require_external_power() {
        if is_deferrable(&error) {
            return defer(backend, &id);
        }
        return Err(error);
    }
    if let Err(error) =
        crate::memory_gate::require_inference(crate::memory_gate::InferenceKind::Whisper)
    {
        if is_deferrable(&error) {
            return defer(backend, &id);
        }
        return Err(error);
    }
    let claimed = backend.db.execute(
        "UPDATE browser_voice_notes SET status='running', started_at=?, attempts=attempts+1 WHERE id=? AND status='queued'",
        params![crate::db::now_unix(), id],
    )?;
    if claimed != 1 {
        return Ok(false);
    }
    match transcribe_audio(&path) {
        Ok(text) => {
            let transcript = clip_report_text(&text);
            if transcript.is_empty() {
                fail_or_retry(
                    backend,
                    &id,
                    attempts + 1,
                    "Could not hear any speech. Try again.",
                )?;
            } else {
                finish(backend, &id, "done", Some(&transcript), "")?;
                let _ = backend.artifacts.remove(&relative);
            }
        }
        Err(error) if is_deferrable(&error) => {
            backend.db.execute(
                "UPDATE browser_voice_notes SET status='queued', next_at=?, started_at=0, attempts=attempts-1 WHERE id=?",
                params![crate::db::now_unix() + retry_delay_secs(&id), id],
            )?;
            return Ok(false);
        }
        Err(error) => {
            let message = if error.to_string().contains("empty transcript")
                || error.to_string().contains("invalid transcript")
            {
                "Could not hear any speech. Try again."
            } else {
                "The Mac could not transcribe that recording."
            };
            fail_or_retry(backend, &id, attempts + 1, message)?;
        }
    }
    Ok(true)
}

fn accept(backend: &Backend, request: &HttpRequest) -> Result<HttpResponse, Error> {
    let id = voice_id(request.header("x-pods-voice-id").unwrap_or(""))?;
    let client = client_id(request)?;
    let mime = audio_mime(request.header("content-type").unwrap_or(""))
        .ok_or_else(|| Error::Invalid("unsupported recording".into()))?;
    if request.body.len() < MIN_BYTES {
        return Err(Error::Invalid("recording is empty".into()));
    }
    if request.body.len() > MAX_BYTES {
        return Err(Error::Invalid("recording is too long".into()));
    }
    if let Some(existing) = load(backend, id)? {
        if existing.0 != client {
            return Err(Error::Conflict("recording id already used".into()));
        }
        return Ok(note_response(
            &existing.1,
            id,
            existing.2.as_deref(),
            existing.3.as_deref(),
            false,
        ));
    }
    let relative = audio_relative(id);
    backend
        .artifacts
        .install(&relative, &request.body)
        .map_err(|error| Error::Upstream(error.to_string()))?;
    if let Err(error) = backend.db.execute(
        "INSERT INTO browser_voice_notes(id,client_id,mime,created_at) VALUES(?,?,?,?)",
        params![id, client, mime, crate::db::now_unix()],
    ) {
        let _ = backend.artifacts.remove(&relative);
        return Err(error);
    }
    Ok(note_response("queued", id, None, None, true))
}

fn status(backend: &Backend, request: &HttpRequest, id: &str) -> Result<HttpResponse, Error> {
    let id = voice_id(id)?;
    let client = client_id(request)?;
    let Some(existing) = load(backend, id)? else {
        return Err(Error::NotFound);
    };
    if existing.0 != client {
        return Err(Error::NotFound);
    }
    Ok(note_response(
        &existing.1,
        id,
        existing.2.as_deref(),
        existing.3.as_deref(),
        false,
    ))
}

fn remove(backend: &Backend, request: &HttpRequest, id: &str) -> Result<HttpResponse, Error> {
    let id = voice_id(id)?;
    let client = client_id(request)?;
    let deleted = backend.db.execute(
        "DELETE FROM browser_voice_notes WHERE id=? AND client_id=?",
        params![id, client],
    )?;
    if deleted != 1 {
        return Err(Error::NotFound);
    }
    let _ = backend.artifacts.remove(&audio_relative(id));
    Ok(HttpResponse::no_content())
}

fn load(
    backend: &Backend,
    id: &str,
) -> Result<Option<(String, String, Option<String>, Option<String>)>, Error> {
    let conn = backend.db.lock()?;
    Ok(conn
        .query_row(
            "SELECT client_id, status, transcript, error FROM browser_voice_notes WHERE id=?",
            [id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .optional()?)
}

fn finish(
    backend: &Backend,
    id: &str,
    status: &str,
    transcript: Option<&str>,
    error: &str,
) -> Result<(), Error> {
    backend.db.execute(
        "UPDATE browser_voice_notes SET status=?, transcript=?, error=?, next_at=0, started_at=0 WHERE id=?",
        params![status, transcript, if error.is_empty() { None::<&str> } else { Some(error) }, id],
    )?;
    Ok(())
}

fn fail_or_retry(backend: &Backend, id: &str, attempts: i64, message: &str) -> Result<(), Error> {
    if attempts >= MAX_ATTEMPTS {
        finish(backend, id, "failed", None, message)?;
        let _ = backend.artifacts.remove(&audio_relative(id));
    } else {
        backend.db.execute(
            "UPDATE browser_voice_notes SET status='queued', error=?, next_at=?, started_at=0 WHERE id=?",
            params![message, crate::db::now_unix() + FAILURE_BACKOFF_SECS * attempts, id],
        )?;
    }
    Ok(())
}

fn defer(backend: &Backend, id: &str) -> Result<bool, Error> {
    backend.db.execute(
        "UPDATE browser_voice_notes SET next_at=? WHERE id=? AND status='queued'",
        params![crate::db::now_unix() + retry_delay_secs(id), id],
    )?;
    Ok(false)
}

fn retry_delay_secs(id: &str) -> i64 {
    30 + (id
        .bytes()
        .fold(0u64, |sum, byte| sum.wrapping_add(byte as u64))
        % 31) as i64
}

fn is_deferrable(error: &Error) -> bool {
    crate::power_gate::is_power_error(error)
        || crate::memory_gate::is_busy_error(error)
        || crate::omlx_lock::is_busy_error(error)
}

fn note_response(
    status: &str,
    id: &str,
    transcript: Option<&str>,
    error: Option<&str>,
    created: bool,
) -> HttpResponse {
    let mut body = json!({"id": id, "status": status});
    if let Some(transcript) = transcript.filter(|text| !text.is_empty()) {
        body["transcript"] = json!(transcript);
    }
    if let Some(error) = error.filter(|text| !text.is_empty()) {
        body["error"] = json!(error);
    }
    let code = if created || status == "queued" || status == "running" {
        202
    } else {
        200
    };
    HttpResponse::json(body, code)
}

fn audio_relative(id: &str) -> String {
    format!("voice/{id}.audio")
}

fn voice_id(raw: &str) -> Result<&str, Error> {
    if (8..=128).contains(&raw.len())
        && raw
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
    {
        Ok(raw)
    } else {
        Err(Error::Invalid("invalid recording id".into()))
    }
}

fn client_id(request: &HttpRequest) -> Result<&str, Error> {
    request
        .header("x-pods-client-id")
        .filter(|value| !value.is_empty() && value.len() <= 128)
        .ok_or_else(|| Error::Invalid("client id required".into()))
}

fn audio_mime(header: &str) -> Option<&'static str> {
    let base = header.split(';').next()?.trim().to_ascii_lowercase();
    match base.as_str() {
        "audio/webm" => Some("audio/webm"),
        "audio/mp4" | "audio/m4a" | "audio/x-m4a" | "audio/aac" => Some("audio/mp4"),
        "audio/mpeg" | "audio/mp3" => Some("audio/mpeg"),
        "audio/wav" | "audio/wave" | "audio/x-wav" => Some("audio/wav"),
        "audio/ogg" => Some("audio/ogg"),
        _ => None,
    }
}

pub(crate) fn clip_report_text(text: &str) -> String {
    let text = text.trim();
    if text.len() <= MAX_TRANSCRIPT_BYTES {
        return text.to_string();
    }
    let mut end = MAX_TRANSCRIPT_BYTES;
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    text[..end].trim_end().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::power_gate::{with_test_power_status, PowerStatus};
    use crate::{Database, DisabledDirectory, MockFeedFetcher};
    use serde_json::{json, Value};
    use std::net::TcpListener;
    use std::sync::Arc;

    const NOTE_ID: &str = "11111111-1111-4111-8111-111111111111";

    fn fixture() -> (Backend, tempfile::TempDir) {
        let temp = tempfile::tempdir().unwrap();
        let db = Database::open_in_memory().unwrap();
        let mut backend = Backend::with_data_root(
            db,
            Arc::new(MockFeedFetcher::default()),
            Arc::new(DisabledDirectory),
            Some(temp.path().to_owned()),
        );
        backend.local = true;
        (backend, temp)
    }

    fn audio_bytes() -> Vec<u8> {
        vec![7u8; 64]
    }

    fn post(bytes: &[u8], mime: &str, id: &str, client: &str) -> HttpRequest {
        let mut request = HttpRequest::new("POST", "/api/feedback/voice")
            .with_header("content-type", mime)
            .with_header("x-pods-client-id", client)
            .with_header("x-pods-voice-id", id);
        request.body = bytes.to_vec();
        request
    }

    fn json_body(response: &HttpResponse) -> Value {
        serde_json::from_slice(&response.body).unwrap()
    }

    fn script(dir: &std::path::Path, body: &str) -> std::path::PathBuf {
        let path = dir.join("whisper.py");
        std::fs::write(&path, body).unwrap();
        path
    }

    fn with_script<T>(script_path: &std::path::Path, work: impl FnOnce() -> T) -> T {
        let _env = crate::local_worker::ENV_TEST_LOCK
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let previous = std::env::var("PODS_TRANSCRIBE_SCRIPT").ok();
        std::env::set_var("PODS_TRANSCRIBE_SCRIPT", script_path);
        let result = work();
        match previous {
            Some(value) => std::env::set_var("PODS_TRANSCRIBE_SCRIPT", value),
            None => std::env::remove_var("PODS_TRANSCRIBE_SCRIPT"),
        }
        result
    }

    fn whisper_env<T>(dir: &std::path::Path, work: impl FnOnce() -> T) -> T {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        drop(listener);
        crate::omlx_lock::with_test_lock_env(dir, crate::omlx_lock::Occupancy::idle(), true, || {
            crate::omlx_lock::set_test_omlx_endpoint(
                format!("http://{address}/v1/models"),
                "test-key",
            );
            work()
        })
    }

    #[test]
    fn script_guard_survives_poisoned_lock() {
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _guard = crate::local_worker::ENV_TEST_LOCK.lock().unwrap();
            panic!("poison the env lock for coverage");
        }));
        let dir = tempfile::tempdir().unwrap();
        let path = script(dir.path(), "ok");
        with_script(&path, || {});
    }

    #[test]
    fn clips_transcripts_on_a_char_boundary() {
        assert_eq!(clip_report_text("  hello  "), "hello");
        assert_eq!(clip_report_text(&"a".repeat(4000)).len(), 4000);
        let wide = format!("{}€", "a".repeat(3999));
        let clipped = clip_report_text(&wide);
        assert!(clipped.len() <= 4000);
        assert!(clipped.ends_with('a'));
    }

    #[test]
    fn rejects_bad_uploads_and_accepts_an_idempotent_replay() {
        let (backend, _temp) = fixture();
        let missing = backend.handle(post(&audio_bytes(), "audio/webm", NOTE_ID, ""));
        assert_eq!(missing.status_code, 422);
        let bad_id = backend.handle(post(&audio_bytes(), "audio/webm", "nope", "phone"));
        assert_eq!(json_body(&bad_id)["error"], "invalid recording id");
        let bad_mime = backend.handle(post(&audio_bytes(), "text/plain", NOTE_ID, "phone"));
        assert_eq!(json_body(&bad_mime)["error"], "unsupported recording");
        let empty = backend.handle(post(&[1, 2, 3], "audio/webm", NOTE_ID, "phone"));
        assert_eq!(json_body(&empty)["error"], "recording is empty");
        let mut huge = post(&[], "audio/mp4;codecs=mp4a", NOTE_ID, "phone");
        huge.body = vec![1u8; MAX_BYTES + 1];
        let too_long = backend.handle(huge);
        assert_eq!(json_body(&too_long)["error"], "recording is too long");

        let created = backend.handle(post(
            &audio_bytes(),
            "audio/webm;codecs=opus",
            NOTE_ID,
            "phone",
        ));
        assert_eq!(created.status_code, 202);
        assert_eq!(json_body(&created)["status"], "queued");
        assert!(backend.artifacts.url(&audio_relative(NOTE_ID)).is_file());
        let stored: String = backend
            .db
            .lock()
            .unwrap()
            .query_row(
                "SELECT mime FROM browser_voice_notes WHERE id=?",
                [NOTE_ID],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(stored, "audio/webm");

        let again = backend.handle(post(&vec![9u8; 80], "audio/webm", NOTE_ID, "phone"));
        assert_eq!(again.status_code, 202);
        assert_eq!(
            std::fs::metadata(backend.artifacts.url(&audio_relative(NOTE_ID)))
                .unwrap()
                .len(),
            64
        );
        let other = backend.handle(post(&audio_bytes(), "audio/webm", NOTE_ID, "tablet"));
        assert_eq!(other.status_code, 409);

        let denied = backend.handle(
            HttpRequest::new("GET", &format!("/api/feedback/voice/{NOTE_ID}"))
                .with_header("x-pods-client-id", "tablet"),
        );
        assert_eq!(denied.status_code, 404);
        let pending = backend.handle(
            HttpRequest::new("GET", &format!("/api/feedback/voice/{NOTE_ID}"))
                .with_header("x-pods-client-id", "phone"),
        );
        assert_eq!(json_body(&pending)["status"], "queued");
        let evil = backend.handle(
            post(
                &audio_bytes(),
                "audio/ogg",
                "22222222-2222-4222-8222-222222222222",
                "phone",
            )
            .with_header("origin", "https://evil.example"),
        );
        assert_eq!(evil.status_code, 403);
    }

    #[test]
    fn transcribes_with_whisper_and_the_confirmed_text_is_a_normal_report() {
        let (backend, temp) = fixture();
        assert_eq!(
            backend
                .handle(post(&audio_bytes(), "audio/mp4", NOTE_ID, "phone"))
                .status_code,
            202
        );
        let program = script(
            temp.path(),
            "import json,os,sys\nassert os.environ.get('PODS_TRANSCRIBE_MODE')=='dictation'\njson.dump([{\"id\":\"s0\",\"start\":0.0,\"end\":1.0,\"text\":\"Dark mode.\"},{\"id\":\"s1\",\"start\":1.0,\"end\":2.0,\"text\":\"Please.\"}], open(sys.argv[2],'w'))\n",
        );
        let ran = whisper_env(temp.path(), || {
            with_script(&program, || step(&backend).unwrap())
        });
        assert!(ran);
        let ready = backend.handle(
            HttpRequest::new("GET", &format!("/api/feedback/voice/{NOTE_ID}"))
                .with_header("x-pods-client-id", "phone"),
        );
        assert_eq!(
            ready.status_code,
            200,
            "{}",
            String::from_utf8_lossy(&ready.body)
        );
        let transcript = json_body(&ready)["transcript"]
            .as_str()
            .unwrap()
            .to_string();
        assert_eq!(transcript, "Dark mode. Please.");
        assert!(!backend.artifacts.url(&audio_relative(NOTE_ID)).is_file());

        let submitted = crate::browser::apply_actions(
            &backend,
            json!({"client_id":"phone","device_name":"iPhone","actions":[{
                "id":"op-voice","sequence":1,"entity":"feedback","field":"report-voice",
                "value":{"kind":"feature","body": transcript, "created_at": 1700000000},
                "base_revision":0
            }]}),
        )
        .unwrap();
        assert_eq!(submitted["results"][0]["status"], "applied");
        let row: (String, String, String) = backend
            .db
            .lock()
            .unwrap()
            .query_row(
                "SELECT kind, body, status FROM browser_feedback WHERE id='report-voice'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!(
            row,
            (
                "feature".into(),
                "Dark mode. Please.".into(),
                "queued".into()
            )
        );
    }

    #[test]
    fn defers_on_battery_and_retries_then_fails_closed() {
        let (backend, temp) = fixture();
        backend.handle(post(&audio_bytes(), "audio/wav", NOTE_ID, "phone"));
        let waited = with_test_power_status(PowerStatus::Battery, || step(&backend).unwrap());
        assert!(!waited);
        let (status, attempts, next_at): (String, i64, i64) = backend
            .db
            .lock()
            .unwrap()
            .query_row(
                "SELECT status, attempts, next_at FROM browser_voice_notes WHERE id=?",
                [NOTE_ID],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!((status.as_str(), attempts), ("queued", 0));
        assert!(next_at > crate::db::now_unix());

        let program = script(temp.path(), "import sys\nsys.exit(1)\n");
        whisper_env(temp.path(), || {
            with_script(&program, || {
                for _ in 0..3 {
                    backend
                        .db
                        .execute(
                            "UPDATE browser_voice_notes SET next_at=0 WHERE id=?",
                            [NOTE_ID],
                        )
                        .unwrap();
                    assert!(step(&backend).unwrap());
                }
            });
        });
        let failed = backend.handle(
            HttpRequest::new("GET", &format!("/api/feedback/voice/{NOTE_ID}"))
                .with_header("x-pods-client-id", "phone"),
        );
        assert_eq!(failed.status_code, 200);
        assert_eq!(json_body(&failed)["status"], "failed");
        assert_eq!(
            json_body(&failed)["error"],
            "The Mac could not transcribe that recording."
        );
        assert!(!backend.artifacts.url(&audio_relative(NOTE_ID)).is_file());
    }

    #[test]
    fn missing_audio_fails_and_delete_removes_the_note() {
        let (backend, _temp) = fixture();
        backend
            .db
            .execute(
                "INSERT INTO browser_voice_notes(id,client_id,mime,created_at) VALUES(?,?,?,?)",
                params![NOTE_ID, "phone", "audio/webm", 10],
            )
            .unwrap();
        assert!(step(&backend).unwrap());
        let failed = backend.handle(
            HttpRequest::new("GET", &format!("/api/feedback/voice/{NOTE_ID}"))
                .with_header("x-pods-client-id", "phone"),
        );
        assert_eq!(json_body(&failed)["error"], "The recording did not arrive.");
        let gone = backend.handle(
            HttpRequest::new("DELETE", &format!("/api/feedback/voice/{NOTE_ID}"))
                .with_header("x-pods-client-id", "phone"),
        );
        assert_eq!(gone.status_code, 204);
        let missing = backend.handle(
            HttpRequest::new("GET", &format!("/api/feedback/voice/{NOTE_ID}"))
                .with_header("x-pods-client-id", "phone"),
        );
        assert_eq!(missing.status_code, 404);
    }
}

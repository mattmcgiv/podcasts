use crate::backend::Backend;
use crate::http::HttpRequest;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::Arc;
use std::thread;

pub const MAXIMUM_REQUEST_BYTES: usize = 5_000_000;

#[derive(Debug, PartialEq)]
pub enum ParseResult {
    Incomplete,
    Invalid(String),
    Complete { method: String, target: String, headers: std::collections::HashMap<String, String>, body: Vec<u8> },
}

pub fn parse_request(data: &[u8]) -> ParseResult {
    let Some(header_end) = data.windows(4).position(|w| w == b"\r\n\r\n") else {
        return ParseResult::Incomplete;
    };
    let header_text = match std::str::from_utf8(&data[..header_end]) {
        Ok(text) => text,
        Err(_) => return ParseResult::Invalid("request headers are not UTF-8".into()),
    };
    let mut lines = header_text.split("\r\n");
    let Some(request_line) = lines.next() else {
        return ParseResult::Invalid("request line is missing".into());
    };
    let mut parts = request_line.split_whitespace();
    let Some(method) = parts.next() else {
        return ParseResult::Invalid("request line is malformed".into());
    };
    let Some(target) = parts.next() else {
        return ParseResult::Invalid("request line is malformed".into());
    };
    let mut headers = std::collections::HashMap::new();
    for line in lines {
        if let Some((k, v)) = line.split_once(':') {
            headers.insert(k.trim().to_lowercase(), v.trim().to_string());
        }
    }
    let raw_len = headers.get("content-length").cloned().unwrap_or_else(|| "0".into());
    let Ok(content_length) = raw_len.parse::<i64>() else {
        return ParseResult::Invalid("content-length is invalid".into());
    };
    if content_length < 0 || content_length as usize > MAXIMUM_REQUEST_BYTES {
        return ParseResult::Invalid("content-length is invalid".into());
    }
    let content_length = content_length as usize;
    let body_start = header_end + 4;
    if body_start > MAXIMUM_REQUEST_BYTES || content_length > MAXIMUM_REQUEST_BYTES.saturating_sub(body_start) {
        return ParseResult::Invalid("request too large".into());
    }
    let body_end = body_start + content_length;
    if data.len() < body_end {
        return ParseResult::Incomplete;
    }
    ParseResult::Complete {
        method: method.to_string(),
        target: target.to_string(),
        headers,
        body: data[body_start..body_end].to_vec(),
    }
}

pub fn serve(backend: Arc<Backend>, addr: &str) -> std::io::Result<TcpListener> {
    let listener = TcpListener::bind(addr)?;
    listener.set_nonblocking(false)?;
    let server = listener.try_clone()?;
    thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let backend = backend.clone();
            thread::spawn(move || {
                let _ = handle_conn(&backend, stream);
            });
        }
    });
    Ok(server)
}

fn handle_conn(backend: &Backend, mut stream: TcpStream) -> std::io::Result<()> {
    stream.set_read_timeout(Some(std::time::Duration::from_secs(30)))?;
    stream.set_write_timeout(Some(std::time::Duration::from_secs(60)))?;
    let mut buf = [0u8; 65536];
    let n = stream.read(&mut buf)?;
    let mut data = buf[..n].to_vec();
    loop {
        match parse_request(&data) {
            ParseResult::Incomplete => {
                let extra = stream.read(&mut buf)?;
                if extra == 0 {
                    break;
                }
                data.extend_from_slice(&buf[..extra]);
                if data.len() > MAXIMUM_REQUEST_BYTES {
                    return Ok(());
                }
            }
            ParseResult::Invalid(_) => {
                stream.write_all(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")?;
                return Ok(());
            }
            ParseResult::Complete { method, target, headers, body } => {
                let mut request = HttpRequest::new(method, target);
                request.headers = headers;
                request.body = body;
                let response = backend.handle(request);
                return write_response(stream, response);
            }
        }
    }
    Ok(())
}

fn write_response(mut stream: TcpStream, response: crate::http::HttpResponse) -> std::io::Result<()> {
    let reason = match response.status_code {
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
        206 => "Partial Content",
        304 => "Not Modified",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        416 => "Range Not Satisfiable",
        422 => "Unprocessable Entity",
        _ => "Error",
    };
    let mut out = format!("HTTP/1.1 {} {}\r\n", response.status_code, reason);
    if !response.headers.keys().any(|k| k.eq_ignore_ascii_case("content-length")) {
        out.push_str(&format!("Content-Length: {}\r\n", response.body.len()));
    }
    for (k, v) in &response.headers {
        out.push_str(&format!("{k}: {v}\r\n"));
    }
    out.push_str("Connection: close\r\n\r\n");
    stream.write_all(out.as_bytes())?;
    stream.write_all(&response.body)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::http::HttpResponse;
    use std::collections::HashMap;
    use std::io::Read;
    use std::thread;

    fn serialize_response(response: HttpResponse) -> Vec<u8> {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let worker = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            write_response(stream, response).unwrap();
        });
        let mut client = TcpStream::connect(addr).unwrap();
        client.set_read_timeout(Some(std::time::Duration::from_secs(2))).unwrap();
        let mut buf = Vec::new();
        client.read_to_end(&mut buf).unwrap();
        worker.join().unwrap();
        buf
    }

    fn status_line(raw: &[u8]) -> &str {
        let text = std::str::from_utf8(raw).unwrap();
        text.split("\r\n").next().unwrap()
    }

    fn body_after_headers(raw: &[u8]) -> &[u8] {
        let pos = raw.windows(4).position(|w| w == b"\r\n\r\n").unwrap();
        &raw[pos + 4..]
    }

    #[test]
    fn write_response_serializes_206_as_partial_content() {
        let mut headers = HashMap::new();
        headers.insert("Content-Range".into(), "bytes 2-5/8".into());
        headers.insert("Content-Length".into(), "4".into());
        headers.insert("Accept-Ranges".into(), "bytes".into());
        let raw = serialize_response(HttpResponse { status_code: 206, headers, body: b"cdef".to_vec() });
        assert_eq!(status_line(&raw), "HTTP/1.1 206 Partial Content");
        let text = std::str::from_utf8(&raw).unwrap();
        assert!(text.contains("Content-Range: bytes 2-5/8\r\n"));
        assert!(text.contains("Accept-Ranges: bytes\r\n"));
        assert_eq!(text.matches("Content-Length:").count(), 1);
        assert!(text.contains("Content-Length: 4\r\n"));
        assert_eq!(body_after_headers(&raw), b"cdef");
    }

    #[test]
    fn write_response_serializes_304_as_not_modified() {
        let mut headers = HashMap::new();
        headers.insert("etag".into(), "\"abc\"".into());
        let raw = serialize_response(HttpResponse { status_code: 304, headers, body: Vec::new() });
        assert_eq!(status_line(&raw), "HTTP/1.1 304 Not Modified");
        let text = std::str::from_utf8(&raw).unwrap();
        assert!(text.contains("etag: \"abc\"\r\n"));
        assert!(body_after_headers(&raw).is_empty());
    }

    #[test]
    fn write_response_serializes_405_as_method_not_allowed() {
        let mut headers = HashMap::new();
        headers.insert("Allow".into(), "GET, HEAD".into());
        let raw = serialize_response(HttpResponse { status_code: 405, headers, body: Vec::new() });
        assert_eq!(status_line(&raw), "HTTP/1.1 405 Method Not Allowed");
        let text = std::str::from_utf8(&raw).unwrap();
        assert!(text.contains("Allow: GET, HEAD\r\n"));
        assert!(body_after_headers(&raw).is_empty());
    }

    #[test]
    fn write_response_serializes_416_as_range_not_satisfiable() {
        let mut headers = HashMap::new();
        headers.insert("Content-Range".into(), "bytes */8".into());
        headers.insert("Content-Length".into(), "0".into());
        let raw = serialize_response(HttpResponse { status_code: 416, headers, body: Vec::new() });
        assert_eq!(status_line(&raw), "HTTP/1.1 416 Range Not Satisfiable");
        let text = std::str::from_utf8(&raw).unwrap();
        assert!(text.contains("Content-Range: bytes */8\r\n"));
        assert_eq!(text.matches("Content-Length:").count(), 1);
        assert!(text.contains("Content-Length: 0\r\n"));
        assert!(body_after_headers(&raw).is_empty());
    }

    #[test]
    fn write_response_keeps_unauthorized_reason_for_passkey_failures() {
        let raw = serialize_response(HttpResponse {
            status_code: 401,
            headers: HashMap::new(),
            body: br#"{"error":"sign in required"}"#.to_vec(),
        });
        assert_eq!(status_line(&raw), "HTTP/1.1 401 Unauthorized");
        assert_eq!(body_after_headers(&raw), br#"{"error":"sign in required"}"#);
    }
}

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
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        409 => "Conflict",
        422 => "Unprocessable Entity",
        _ => "Error",
    };
    let mut out = format!("HTTP/1.1 {} {}\r\nContent-Length: {}\r\n", response.status_code, reason, response.body.len());
    for (k, v) in &response.headers {
        out.push_str(&format!("{k}: {v}\r\n"));
    }
    out.push_str("Connection: close\r\n\r\n");
    stream.write_all(out.as_bytes())?;
    stream.write_all(&response.body)?;
    Ok(())
}

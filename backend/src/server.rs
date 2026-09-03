use crate::backend::Backend;
use crate::http::HttpRequest;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::Arc;
use std::thread;

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
    let raw = String::from_utf8_lossy(&buf[..n]).into_owned();
    let mut lines = raw.split("\r\n");
    let request_line = lines.next().unwrap_or("");
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or("GET").to_string();
    let target = parts.next().unwrap_or("/").to_string();
    let mut headers = std::collections::HashMap::new();
    let mut content_length = 0usize;
    for line in lines.by_ref() {
        if line.is_empty() {
            break;
        }
        if let Some((k, v)) = line.split_once(':') {
            let key = k.trim().to_lowercase();
            let val = v.trim().to_string();
            if key == "content-length" {
                content_length = val.parse().unwrap_or(0);
            }
            headers.insert(key, val);
        }
    }
    let header_end = raw.find("\r\n\r\n").map(|i| i + 4).unwrap_or(raw.len());
    let mut body = raw.as_bytes().get(header_end..).unwrap_or(&[]).to_vec();
    while body.len() < content_length {
        let extra = stream.read(&mut buf)?;
        if extra == 0 {
            break;
        }
        body.extend_from_slice(&buf[..extra]);
    }
    body.truncate(content_length);
    let mut request = HttpRequest::new(method, target);
    request.headers = headers;
    request.body = body;
    let response = backend.handle(request);
    let reason = match response.status_code {
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
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

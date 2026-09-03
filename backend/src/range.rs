use std::collections::HashMap;
use std::ops::Range;

#[derive(Clone, Debug, PartialEq)]
pub struct StreamAuthorization {
    pub episode_id: i64,
    pub file_path: String,
    pub byte_count: i64,
    pub token: String,
    pub playback_session_id: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct RangeResponsePlan {
    pub status_code: u16,
    pub reason: String,
    pub headers: HashMap<String, String>,
    pub body_range: Option<Range<i64>>,
}

pub fn plan(
    method: &str,
    target: &str,
    headers: &HashMap<String, String>,
    authorization: Option<&StreamAuthorization>,
) -> RangeResponsePlan {
    let Some(authorization) = authorization else {
        return response(401, "Unauthorized", HashMap::new(), None);
    };
    let url = format!("http://pods.invalid{target}");
    let parsed = url::Url::parse(&url).ok();
    let token = parsed.as_ref().and_then(|u| {
        u.query_pairs()
            .find(|(k, _)| k == "token")
            .map(|(_, v)| v.into_owned())
    });
    if token.as_deref() != Some(authorization.token.as_str()) {
        return response(401, "Unauthorized", HashMap::new(), None);
    }
    let path = parsed.as_ref().map(|u| u.path().to_string()).unwrap_or_default();
    if path != format!("/episode/{}", authorization.episode_id) {
        return response(404, "Not Found", HashMap::new(), None);
    }
    let method = method.to_uppercase();
    if method != "GET" && method != "HEAD" {
        let mut headers = HashMap::new();
        headers.insert("Allow".into(), "GET, HEAD".into());
        return response(405, "Method Not Allowed", headers, None);
    }
    let byte_count = authorization.byte_count.max(0);
    let mut out_headers = HashMap::new();
    out_headers.insert("Accept-Ranges".into(), "bytes".into());
    out_headers.insert("Cache-Control".into(), "no-store".into());
    out_headers.insert("Content-Type".into(), content_type(&authorization.file_path));
    let range_header = header(headers, "Range");
    let Some(range_header) = range_header else {
        out_headers.insert("Content-Length".into(), byte_count.to_string());
        let body = if method == "GET" && byte_count > 0 {
            Some(0..byte_count)
        } else {
            None
        };
        return RangeResponsePlan {
            status_code: 200,
            reason: "OK".into(),
            headers: out_headers,
            body_range: body,
        };
    };
    let Some(range) = parse_range(range_header, byte_count) else {
        out_headers.insert("Content-Range".into(), format!("bytes */{byte_count}"));
        out_headers.insert("Content-Length".into(), "0".into());
        return RangeResponsePlan {
            status_code: 416,
            reason: "Range Not Satisfiable".into(),
            headers: out_headers,
            body_range: None,
        };
    };
    out_headers.insert(
        "Content-Range".into(),
        format!("bytes {}-{}/{}", range.start, range.end - 1, byte_count),
    );
    out_headers.insert("Content-Length".into(), (range.end - range.start).to_string());
    RangeResponsePlan {
        status_code: 206,
        reason: "Partial Content".into(),
        headers: out_headers,
        body_range: if method == "GET" { Some(range) } else { None },
    }
}

fn parse_range(value: &str, byte_count: i64) -> Option<Range<i64>> {
    if byte_count <= 0 || !value.starts_with("bytes=") || value.contains(',') {
        return None;
    }
    let spec = &value["bytes=".len()..];
    let mut pieces = spec.splitn(2, '-');
    let start = pieces.next()?;
    let end = pieces.next()?;
    if start.is_empty() {
        let suffix: i64 = end.parse().ok()?;
        if suffix <= 0 {
            return None;
        }
        let begin = (byte_count - suffix).max(0);
        return Some(begin..byte_count);
    }
    let begin: i64 = start.parse().ok()?;
    if begin < 0 || begin >= byte_count {
        return None;
    }
    if end.is_empty() {
        return Some(begin..byte_count);
    }
    let requested_end: i64 = end.parse().ok()?;
    if requested_end < begin {
        return None;
    }
    let last = requested_end.min(byte_count - 1);
    Some(begin..(last + 1))
}

fn header<'a>(headers: &'a HashMap<String, String>, name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case(name))
        .map(|(_, v)| v.as_str())
}

fn content_type(path: &str) -> String {
    if path.ends_with(".mp3") {
        "audio/mpeg".into()
    } else if path.ends_with(".m4a") || path.ends_with(".mp4") {
        "audio/mp4".into()
    } else {
        "application/octet-stream".into()
    }
}

fn response(
    status: u16,
    reason: &str,
    headers: HashMap<String, String>,
    body_range: Option<Range<i64>>,
) -> RangeResponsePlan {
    RangeResponsePlan {
        status_code: status,
        reason: reason.into(),
        headers,
        body_range,
    }
}

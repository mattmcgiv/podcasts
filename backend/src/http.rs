use crate::error::Error;
use serde::Serialize;
use std::collections::HashMap;

#[derive(Clone, Debug)]
pub struct HttpRequest {
    pub method: String,
    pub target: String,
    pub headers: HashMap<String, String>,
    pub body: Vec<u8>,
}

impl HttpRequest {
    pub fn new(method: impl Into<String>, target: impl Into<String>) -> Self {
        Self {
            method: method.into().to_uppercase(),
            target: target.into(),
            headers: HashMap::new(),
            body: Vec::new(),
        }
    }

    pub fn with_json(mut self, value: &serde_json::Value) -> Self {
        self.body = serde_json::to_vec(value).unwrap_or_default();
        self.headers
            .insert("content-type".into(), "application/json".into());
        self
    }

    pub fn with_text(mut self, text: impl Into<String>) -> Self {
        self.body = text.into().into_bytes();
        self
    }

    pub fn with_header(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.headers.insert(key.into().to_lowercase(), value.into());
        self
    }

    pub fn path(&self) -> String {
        let url = if self.target.starts_with("http") {
            self.target.clone()
        } else {
            format!("http://localhost{}", self.target)
        };
        url::Url::parse(&url)
            .map(|u| u.path().to_string())
            .unwrap_or_else(|_| self.target.clone())
    }

    pub fn query(&self, name: &str) -> Option<String> {
        let url = if self.target.starts_with("http") {
            self.target.clone()
        } else {
            format!("http://localhost{}", self.target)
        };
        url::Url::parse(&url).ok().and_then(|u| {
            u.query_pairs()
                .find(|(k, _)| k == name)
                .map(|(_, v)| v.into_owned())
        })
    }

    pub fn offset(&self) -> i64 {
        self.query("offset")
            .and_then(|v| v.parse().ok())
            .unwrap_or(0)
            .max(0)
    }

    pub fn json_object(&self) -> Result<serde_json::Value, Error> {
        let value: serde_json::Value =
            serde_json::from_slice(&self.body).map_err(|_| Error::Invalid("expected JSON object".into()))?;
        if !value.is_object() {
            return Err(Error::Invalid("expected JSON object".into()));
        }
        Ok(value)
    }

    pub fn header(&self, name: &str) -> Option<&str> {
        let needle = name.to_lowercase();
        self.headers
            .iter()
            .find(|(k, _)| k.to_lowercase() == needle)
            .map(|(_, v)| v.as_str())
    }

    pub fn body_string(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }
}

#[derive(Clone, Debug)]
pub struct HttpResponse {
    pub status_code: u16,
    pub headers: HashMap<String, String>,
    pub body: Vec<u8>,
}

impl HttpResponse {
    pub fn json<T: Serialize>(value: T, status_code: u16) -> Self {
        let body = serde_json::to_vec(&value).unwrap_or_else(|_| b"{}".to_vec());
        let mut headers = HashMap::new();
        headers.insert(
            "content-type".into(),
            "application/json; charset=utf-8".into(),
        );
        Self {
            status_code,
            headers,
            body,
        }
    }

    pub fn text(value: impl Into<String>, status_code: u16, content_type: &str) -> Self {
        Self::binary(value.into().into_bytes(), status_code, content_type)
    }

    pub fn binary(body: Vec<u8>, status_code: u16, content_type: &str) -> Self {
        let mut headers = HashMap::new();
        headers.insert("content-type".into(), content_type.into());
        Self {
            status_code,
            headers,
            body,
        }
    }

    pub fn no_content() -> Self {
        Self {
            status_code: 204,
            headers: HashMap::new(),
            body: Vec::new(),
        }
    }

    pub fn error(error: Error) -> Self {
        Self::json(
            serde_json::json!({ "error": error.message() }),
            error.status_code(),
        )
    }
}

// Minimal URL parser without adding the `url` crate if parse fails; we added url via ureq.
// ureq re-exports? We'll add url crate explicitly if needed.

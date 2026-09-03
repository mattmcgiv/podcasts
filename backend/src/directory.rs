use crate::backend::DirectorySearcher;
use crate::error::Error;
use crate::models::{DirectoryAppearance, DirectoryPodcast};
use sha1::{Digest, Sha1};
use std::fs;
use std::path::Path;

const DEFAULT_BASE: &str = "https://api.podcastindex.org/api/1.0";

#[derive(Clone, Debug)]
pub struct PodcastIndexClient {
    key: String,
    secret: String,
    base_url: String,
}

impl PodcastIndexClient {
    pub fn new(key: impl Into<String>, secret: impl Into<String>, base_url: impl Into<String>) -> Self {
        let mut base = base_url.into();
        if base.ends_with('/') {
            base.pop();
        }
        Self {
            key: key.into(),
            secret: secret.into(),
            base_url: if base.is_empty() { DEFAULT_BASE.into() } else { base },
        }
    }

    pub fn from_env() -> Option<Self> {
        let key = std::env::var("PODCASTINDEX_KEY").ok()?;
        let secret = std::env::var("PODCASTINDEX_SECRET").ok()?;
        if key.trim().is_empty() || secret.trim().is_empty() {
            return None;
        }
        let base = std::env::var("PODCASTINDEX_BASE_URL").unwrap_or_else(|_| DEFAULT_BASE.into());
        Some(Self::new(key.trim(), secret.trim(), base.trim()))
    }

    pub fn from_credentials_file(path: &Path) -> Option<Self> {
        let text = fs::read_to_string(path).ok()?;
        let mut key = String::new();
        let mut secret = String::new();
        let mut base = DEFAULT_BASE.to_string();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((name, value)) = line.split_once('=') else { continue };
            let value = value.trim().trim_matches('"');
            match name.trim() {
                "PODCASTINDEX_KEY" => key = value.to_string(),
                "PODCASTINDEX_SECRET" => secret = value.to_string(),
                "PODCASTINDEX_BASE_URL" if !value.is_empty() => base = value.to_string(),
                _ => {}
            }
        }
        if key.is_empty() || secret.is_empty() {
            return None;
        }
        Some(Self::new(key, secret, base))
    }

    pub fn from_default_locations() -> Option<Self> {
        if let Some(client) = Self::from_env() {
            return Some(client);
        }
        if let Ok(home) = std::env::var("HOME") {
            let path = std::path::PathBuf::from(home).join(".config/podcasts/credentials.env");
            if let Some(client) = Self::from_credentials_file(&path) {
                return Some(client);
            }
        }
        None
    }

    pub fn auth_header(key: &str, secret: &str, timestamp: i64) -> String {
        let mut hasher = Sha1::new();
        hasher.update(format!("{key}{secret}{timestamp}").as_bytes());
        hex::encode(hasher.finalize())
    }

    fn get_json(&self, path: &str, query: &[(&str, &str)]) -> Result<serde_json::Value, Error> {
        let mut url = format!("{}/{path}", self.base_url.trim_end_matches('/'));
        if !query.is_empty() {
            let encoded = query
                .iter()
                .map(|(k, v)| format!("{}={}", k, urlencoding_lite(v)))
                .collect::<Vec<_>>()
                .join("&");
            url.push('?');
            url.push_str(&encoded);
        }
        let now = crate::db::now_unix();
        let response = ureq::get(&url)
            .set("X-Auth-Date", &now.to_string())
            .set("X-Auth-Key", &self.key)
            .set("Authorization", &Self::auth_header(&self.key, &self.secret, now))
            .set("User-Agent", "Pods/1.0")
            .timeout(std::time::Duration::from_secs(12))
            .call()
            .map_err(|e| Error::Upstream(e.to_string()))?;
        let status = response.status();
        if !(200..300).contains(&status) {
            return Err(Error::Upstream(format!("Podcast Index returned HTTP {status}")));
        }
        let text = response.into_string().map_err(|e| Error::Upstream(e.to_string()))?;
        serde_json::from_str(&text).map_err(|e| Error::Upstream(e.to_string()))
    }
}

impl DirectorySearcher for PodcastIndexClient {
    fn is_configured(&self) -> bool {
        true
    }

    fn search(&self, query: &str) -> Result<Vec<DirectoryPodcast>, Error> {
        let body = self.get_json("search/byterm", &[("q", query), ("max", "20")])?;
        let feeds = body.get("feeds").and_then(|v| v.as_array()).cloned().unwrap_or_default();
        Ok(feeds
            .into_iter()
            .filter_map(|feed| {
                let feed_url = non_empty(feed.get("url").and_then(|v| v.as_str()))?;
                Some(DirectoryPodcast {
                    title: feed.get("title").and_then(|v| v.as_str()).unwrap_or("").to_string(),
                    author: feed.get("author").and_then(|v| v.as_str()).unwrap_or("").to_string(),
                    feed_url,
                    image_url: non_empty(feed.get("artwork").and_then(|v| v.as_str()))
                        .or_else(|| non_empty(feed.get("image").and_then(|v| v.as_str())))
                        .unwrap_or_default(),
                    description: feed.get("description").and_then(|v| v.as_str()).unwrap_or("").to_string(),
                    subscribed: false,
                })
            })
            .collect())
    }

    fn search_appearances(&self, person: &str) -> Result<Vec<DirectoryAppearance>, Error> {
        let body = self.get_json("search/byperson", &[("q", person), ("max", "100")])?;
        let items = body.get("items").and_then(|v| v.as_array()).cloned().unwrap_or_default();
        let normalized_person = normalize(person);
        Ok(items
            .into_iter()
            .filter_map(|item| {
                let feed_url = non_empty(item.get("feedUrl").and_then(|v| v.as_str()))?;
                let audio_url = non_empty(item.get("enclosureUrl").and_then(|v| v.as_str()))?;
                let guid = non_empty(item.get("guid").and_then(|v| v.as_str()))
                    .or_else(|| item.get("id").and_then(|v| v.as_i64()).map(|id| id.to_string()))?;
                let key = item
                    .get("id")
                    .and_then(|v| v.as_i64())
                    .map(|id| id.to_string())
                    .or_else(|| non_empty(item.get("guid").and_then(|v| v.as_str())))?;
                let title = item.get("title").and_then(|v| v.as_str()).unwrap_or("").to_string();
                let description = item.get("description").and_then(|v| v.as_str()).unwrap_or("").to_string();
                let person_tag = item.get("persons").and_then(|v| v.as_array()).and_then(|people| {
                    people.iter().find(|p| normalize(p.get("name").and_then(|v| v.as_str()).unwrap_or("")) == normalized_person)
                });
                let title_has = normalize(&title).contains(&normalized_person);
                let description_has = normalize(&description).contains(&normalized_person);
                let (confidence, evidence) = if let Some(tag) = person_tag {
                    let role = tag.get("role").and_then(|v| v.as_str()).unwrap_or("");
                    let evidence = if role.is_empty() {
                        "person tag".into()
                    } else {
                        format!("person tag: {role}")
                    };
                    ("high", evidence)
                } else if title_has && description_has {
                    ("high", "name in title and description".into())
                } else if title_has {
                    ("review", "name in title".into())
                } else if description_has {
                    ("review", "name in description".into())
                } else {
                    return None;
                };
                Some(DirectoryAppearance {
                    source_episode_key: key,
                    feed_url,
                    feed_title: item.get("feedTitle").and_then(|v| v.as_str()).unwrap_or("").to_string(),
                    feed_image_url: item.get("feedImage").and_then(|v| v.as_str()).unwrap_or("").to_string(),
                    guid,
                    title,
                    description,
                    audio_url,
                    duration_secs: item.get("duration").and_then(|v| v.as_i64()),
                    published_at: item.get("datePublished").and_then(|v| v.as_i64()).unwrap_or(0),
                    image_url: item.get("image").and_then(|v| v.as_str()).unwrap_or("").to_string(),
                    evidence,
                    confidence: confidence.into(),
                })
            })
            .collect())
    }
}

pub fn configured_directory() -> std::sync::Arc<dyn DirectorySearcher> {
    if let Some(client) = PodcastIndexClient::from_default_locations() {
        std::sync::Arc::new(client)
    } else {
        std::sync::Arc::new(crate::backend::DisabledDirectory)
    }
}

fn non_empty(value: Option<&str>) -> Option<String> {
    value.map(str::trim).filter(|s| !s.is_empty()).map(str::to_string)
}

fn normalize(value: &str) -> String {
    value
        .chars()
        .map(|c| c.to_ascii_lowercase())
        .filter(|c| c.is_ascii_alphanumeric() || *c == ' ')
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn urlencoding_lite(value: &str) -> String {
    let mut out = String::new();
    for b in value.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            b' ' => out.push_str("%20"),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

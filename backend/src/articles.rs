//! Article URLs queued from the menu bar for spoken-word synthesis.
//!
//! One-off reads, like single YouTube videos: no subscription, one episode
//! per URL under a single Articles show, `article:` source URLs.
use crate::error::Error;
use serde::{Deserialize, Serialize};

pub const LISTEN_SETTING: &str = "browser_article_listen";
pub const SHOW_FEED_URL: &str = "article:articles";
pub const SHOW_TITLE: &str = "Articles";
pub const MAX_QUEUE_ATTEMPTS: u32 = 4;
/// Deferral marker while a later pipeline unit owns the stage. Never consumes
/// an attempt and never notifies; replaced by real errors once implemented.
pub const PENDING: &str = "article_pending";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PendingArticle {
    pub url: String,
    pub attempts: u32,
    #[serde(default)]
    pub next_at: i64,
}

pub fn source_url(url: &str) -> String {
    format!("article:{url}")
}

pub fn url_from_source(source: &str) -> Option<&str> {
    source.strip_prefix("article:")
}

/// Rejects empty strings, non-web schemes, and credentialed URLs.
pub fn validate_url(raw: &str) -> Result<String, Error> {
    let url = url::Url::parse(raw.trim()).map_err(|_| Error::Invalid("paste an article URL".into()))?;
    if !matches!(url.scheme(), "https" | "http")
        || url.host_str().is_none_or(|host| host.is_empty())
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return Err(Error::Invalid("paste an article URL".into()));
    }
    Ok(raw.trim().to_string())
}

/// True when fetched bytes look like an HTML document rather than a feed.
/// Feed parsing runs first; this only routes HTML the parser rejects.
pub fn looks_like_html(data: &[u8]) -> bool {
    let head = String::from_utf8_lossy(data);
    let head = head.trim_start().to_ascii_lowercase();
    head.starts_with("<!doctype html") || head.starts_with("<html")
}

/// Placeholder title until extraction resolves the real one.
pub fn placeholder_title(url: &str) -> String {
    let title = url::Url::parse(url)
        .map(|parsed| format!("{}{}", parsed.host_str().unwrap_or_default(), parsed.path()))
        .unwrap_or_else(|_| url.to_string());
    let title = title.trim_matches('/').trim();
    if title.is_empty() {
        "Untitled article".to_string()
    } else {
        title.chars().take(120).collect()
    }
}

pub fn enqueue(db: &crate::db::Database, url: &str) -> Result<(), Error> {
    let queued = db
        .scalar_string("SELECT value FROM settings WHERE key=?", [LISTEN_SETTING])?
        .unwrap_or_else(|| "[]".into());
    let mut items: Vec<PendingArticle> = serde_json::from_str(&queued).unwrap_or_default();
    if !items.iter().any(|item| item.url == url) {
        items.push(PendingArticle {
            url: url.to_string(),
            attempts: 0,
            next_at: 0,
        });
        let value = serde_json::to_string(&items).map_err(|e| Error::Invalid(e.to_string()))?;
        db.execute(
            "INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            [LISTEN_SETTING, &value],
        )?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn source_roundtrips() {
        let url = "https://example.com/story";
        assert_eq!(url_from_source(&source_url(url)), Some(url));
        assert_eq!(url_from_source("https://example.com/original.mp3"), None);
        assert_eq!(url_from_source("article:"), Some(""));
    }

    #[test]
    fn validates_article_urls() {
        assert_eq!(
            validate_url("https://example.com/story").unwrap(),
            "https://example.com/story"
        );
        for bad in [
            "",
            "not a url",
            "ftp://example.com/file",
            "https://user@example.com/",
            "https://user:pass@example.com/",
            "https://exa mple.com/",
        ] {
            assert!(validate_url(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn detects_html_documents() {
        assert!(looks_like_html(b"<!DOCTYPE html><html><body>Hi</body></html>"));
        assert!(looks_like_html(b"  \n<html lang=\"en\">Hi"));
        assert!(looks_like_html(b"<!doctype HTML><p>Hi"));
        assert!(!looks_like_html(b"<?xml version=\"1.0\"?><rss version=\"2.0\">"));
        assert!(!looks_like_html(b"{\"json\": true}"));
        assert!(!looks_like_html(b""));
    }

    #[test]
    fn placeholder_falls_back_to_host_and_path() {
        assert_eq!(
            placeholder_title("https://example.com/long-story"),
            "example.com/long-story"
        );
        assert_eq!(placeholder_title("https://example.com/"), "example.com");
        assert_eq!(placeholder_title("not a url"), "not a url");
    }

    #[test]
    fn queue_dedupes_urls() {
        let db = crate::db::Database::open_in_memory().unwrap();
        enqueue(&db, "https://example.com/a").unwrap();
        enqueue(&db, "https://example.com/a").unwrap();
        enqueue(&db, "https://example.com/b").unwrap();
        let raw = db
            .scalar_string("SELECT value FROM settings WHERE key=?", [LISTEN_SETTING])
            .unwrap()
            .unwrap();
        let items: Vec<PendingArticle> = serde_json::from_str(&raw).unwrap();
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].attempts, 0);
        assert_eq!(items[0].next_at, 0);
    }
}

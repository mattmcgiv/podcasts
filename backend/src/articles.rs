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
pub const DEFAULT_MAX_WORDS: usize = 12_000;
pub const MAX_PAGE_BYTES: usize = 10 * 1024 * 1024;
pub const DEFAULT_VOICE: &str = "af_heart";
pub const DEFAULT_TTS_MODEL: &str = "mlx-community/Kokoro-82M-bf16";
pub const DEFAULT_TTS_REVISION: &str = "a71e4d38b236d968966a2002c4c895dbd12b1c3c";
pub const TTS_PIPELINE_VERSION: &str = "pods-article-v1-kokoro-82m-bf16-aac128";

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

/// Document written by extract_article.py. Sections drive per-section synthesis;
/// each section start becomes a chapter start.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct ArticleSection {
    #[serde(default)]
    pub heading: String,
    #[serde(default)]
    pub paragraphs: Vec<String>,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub struct ArticleJson {
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub author: String,
    #[serde(default)]
    pub published: String,
    #[serde(default)]
    pub site: String,
    #[serde(default)]
    pub image_url: String,
    #[serde(default)]
    pub sections: Vec<ArticleSection>,
}

impl ArticleJson {
    pub fn word_count(&self) -> usize {
        self.sections
            .iter()
            .flat_map(|section| section.paragraphs.iter())
            .map(|paragraph| paragraph.split_whitespace().count())
            .sum()
    }

    pub fn validate(&self) -> Result<(), Error> {
        if self.sections.is_empty() || self.word_count() == 0 {
            return Err(Error::Invalid("article had no readable text".into()));
        }
        if self
            .sections
            .iter()
            .any(|section| section.paragraphs.iter().all(|p| p.trim().is_empty()))
        {
            return Err(Error::Invalid("article section had no readable text".into()));
        }
        Ok(())
    }
}

pub fn max_words() -> usize {
    std::env::var("PODS_ARTICLE_MAX_WORDS")
        .ok()
        .and_then(|value| value.parse().ok())
        .filter(|value| *value > 0)
        .unwrap_or(DEFAULT_MAX_WORDS)
}

/// Kokoro voice preset. Validated fail-fast so a bad override never burns a
/// synthesis run; the worker reads PODS_TTS_VOICE once per job.
pub fn tts_voice() -> Result<String, Error> {
    let voice = std::env::var("PODS_TTS_VOICE").unwrap_or_else(|_| DEFAULT_VOICE.into());
    if voice.is_empty()
        || voice.len() > 64
        || !voice
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
    {
        return Err(Error::Invalid("invalid TTS voice".into()));
    }
    Ok(voice)
}

pub fn tts_model() -> String {
    std::env::var("PODS_TTS_MODEL")
        .ok()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| DEFAULT_TTS_MODEL.into())
}

pub fn tts_revision() -> String {
    std::env::var("PODS_TTS_REVISION")
        .ok()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| DEFAULT_TTS_REVISION.into())
}

/// Manifest written by synthesize.py. Durations are measured, not estimated.
#[derive(Clone, Debug, Deserialize)]
pub struct SynthesizedSection {
    #[allow(dead_code)]
    pub heading: String,
    pub file: String,
    pub samples: u64,
    pub duration: f64,
}

#[derive(Clone, Debug, Deserialize)]
pub struct SynthesizeManifest {
    #[allow(dead_code)]
    pub voice: String,
    #[allow(dead_code)]
    pub model: String,
    pub sample_rate: u32,
    pub sections: Vec<SynthesizedSection>,
}

impl SynthesizeManifest {
    pub fn validate(&self, expected_sections: usize) -> Result<(), Error> {
        if self.sample_rate != 24000 {
            return Err(Error::Invalid("synthesis manifest has wrong sample rate".into()));
        }
        if self.sections.len() != expected_sections || expected_sections == 0 {
            return Err(Error::Invalid("synthesis manifest section mismatch".into()));
        }
        if self.sections.iter().any(|section| {
            section.samples == 0
                || !section.duration.is_finite()
                || section.duration <= 0.0
                || section.file.is_empty()
                || section.file.contains(['/', '\\'])
        }) {
            return Err(Error::Invalid("synthesis manifest has bad section".into()));
        }
        Ok(())
    }

    pub fn total_duration(&self) -> f64 {
        self.sections.iter().map(|section| section.duration).sum()
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
    fn validates_article_documents() {
        let blank = ArticleJson::default();
        assert!(blank.validate().is_err());
        let empty_section = ArticleJson {
            sections: vec![ArticleSection {
                heading: "H".into(),
                paragraphs: vec!["  ".into()],
            }],
            ..Default::default()
        };
        assert!(empty_section.validate().is_err());
        let good = ArticleJson {
            title: "T".into(),
            sections: vec![ArticleSection {
                heading: "H".into(),
                paragraphs: vec!["Hello world.".into()],
            }],
            ..Default::default()
        };
        assert!(good.validate().is_ok());
        assert_eq!(good.word_count(), 2);
    }

    #[test]
    fn word_cap_defaults_when_unset_or_invalid() {
        std::env::remove_var("PODS_ARTICLE_MAX_WORDS");
        assert_eq!(max_words(), DEFAULT_MAX_WORDS);
        std::env::set_var("PODS_ARTICLE_MAX_WORDS", "5000");
        assert_eq!(max_words(), 5000);
        std::env::set_var("PODS_ARTICLE_MAX_WORDS", "many");
        assert_eq!(max_words(), DEFAULT_MAX_WORDS);
        std::env::set_var("PODS_ARTICLE_MAX_WORDS", "0");
        assert_eq!(max_words(), DEFAULT_MAX_WORDS);
        std::env::remove_var("PODS_ARTICLE_MAX_WORDS");
    }

    #[test]
    fn voice_config_defaults_and_rejects_garbage() {
        std::env::remove_var("PODS_TTS_VOICE");
        assert_eq!(tts_voice().unwrap(), DEFAULT_VOICE);
        std::env::set_var("PODS_TTS_VOICE", "am_michael");
        assert_eq!(tts_voice().unwrap(), "am_michael");
        for bad in ["", "af heart", "af-heart", "../af_heart", &"a".repeat(65)] {
            std::env::set_var("PODS_TTS_VOICE", bad);
            assert!(tts_voice().is_err(), "{bad}");
        }
        std::env::remove_var("PODS_TTS_VOICE");
    }

    #[test]
    fn validates_synthesis_manifests() {
        let section = SynthesizedSection {
            heading: "H".into(),
            file: "section-000.wav".into(),
            samples: 24000,
            duration: 1.0,
        };
        let good = SynthesizeManifest {
            voice: "af_heart".into(),
            model: "m".into(),
            sample_rate: 24000,
            sections: vec![section.clone()],
        };
        assert!(good.validate(1).is_ok());
        assert_eq!(good.total_duration(), 1.0);
        assert!(good.validate(2).is_err());
        let wrong_rate = SynthesizeManifest { sample_rate: 44100, ..good.clone() };
        assert!(wrong_rate.validate(1).is_err());
        let bad_file = SynthesizeManifest {
            sections: vec![SynthesizedSection { file: "../evil.wav".into(), ..section.clone() }],
            ..good.clone()
        };
        assert!(bad_file.validate(1).is_err());
        let silent = SynthesizeManifest {
            sections: vec![SynthesizedSection { samples: 0, duration: 0.0, ..section }],
            ..good
        };
        assert!(silent.validate(1).is_err());
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

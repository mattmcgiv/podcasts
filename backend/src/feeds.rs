use crate::error::Error;
use chrono::TimeZone;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FeedValidators {
    pub etag: Option<String>,
    pub last_modified: Option<String>,
}

#[derive(Clone, Debug)]
pub enum FeedFetchResponse {
    Data(Vec<u8>, FeedValidators),
    NotModified(FeedValidators),
}

pub trait FeedFetcher: Send + Sync {
    fn fetch(&self, url: &str, validators: &FeedValidators) -> Result<FeedFetchResponse, Error>;
}

#[derive(Clone, Debug)]
pub struct ParsedEpisode {
    pub guid: String,
    pub title: String,
    pub notes_html: String,
    pub audio_url: String,
    pub duration_secs: Option<i64>,
    pub published_at: i64,
    pub image_url: String,
}

#[derive(Clone, Debug, Default)]
pub struct ParsedFeed {
    pub title: String,
    pub description: String,
    pub image_url: String,
    pub site_url: String,
    pub episodes: Vec<ParsedEpisode>,
}

pub fn parse_feed(data: &[u8]) -> Result<ParsedFeed, Error> {
    let xml = std::str::from_utf8(data).map_err(|_| Error::Upstream("feed is not UTF-8".into()))?;
    let document = roxmltree::Document::parse(xml).map_err(|_| Error::Upstream("feed contains invalid XML".into()))?;
    let channel = document.root_element().children().find(|n| n.has_tag_name("channel")).ok_or_else(|| Error::Upstream("feed has no RSS channel".into()))?;
    let text = |node: roxmltree::Node<'_, '_>, name: &str| -> String {
        node.children().find(|n| n.is_element() && n.tag_name().name() == name).map(|n| {
            n.children().filter(|c| c.is_text()).filter_map(|c| c.text()).collect::<String>().trim().to_owned()
        }).unwrap_or_default()
    };
    let image = |node: roxmltree::Node<'_, '_>| -> String {
        node.children().find(|n| n.is_element() && n.tag_name().name() == "image" && n.tag_name().namespace().is_some_and(|ns| ns.contains("itunes.com")))
            .and_then(|n| n.attribute("href")).map(str::to_owned).filter(|s| !s.trim().is_empty())
            .or_else(|| node.children().find(|n| n.has_tag_name("image")).map(|n| text(n, "url")))
            .unwrap_or_default()
    };
    let mut feed = ParsedFeed {
        title: text(channel, "title"),
        description: text(channel, "description"),
        image_url: image(channel),
        site_url: text(channel, "link"),
        episodes: Vec::new(),
    };
    for item in channel.children().filter(|n| n.has_tag_name("item")) {
        let description = text(item, "description");
        let duration = text(item, "duration");
        let date = text(item, "pubDate");
        let mut current = ParsedEpisode {
            guid: text(item, "guid"),
            title: text(item, "title"),
            notes_html: if description.is_empty() { text(item, "encoded") } else { description },
            audio_url: item.children().find(|n| n.has_tag_name("enclosure")).and_then(|n| n.attribute("url")).unwrap_or_default().to_owned(),
            duration_secs: parse_duration(&duration),
            published_at: parse_feed_date(&date),
            image_url: image(item),
        };
        if current.audio_url.is_empty() {
            continue;
        }
        if current.guid.trim().is_empty() {
            current.guid = current.audio_url.clone();
        }
        feed.episodes.push(current);
    }
    Ok(feed)
}

pub fn parse_feed_date(value: &str) -> i64 {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return 0;
    }
    let formats = [
        "%a, %d %b %Y %H:%M:%S %Z",
        "%a, %d %b %Y %H:%M:%S GMT",
        "%a, %e %b %Y %H:%M:%S %Z",
        "%a, %e %b %Y %H:%M:%S GMT",
        "%Y-%m-%dT%H:%M:%S%z",
        "%Y-%m-%dT%H:%M:%SZ",
        "%Y-%m-%d",
    ];
    for format in formats {
        if let Ok(dt) = chrono::DateTime::parse_from_str(trimmed, format) {
            return dt.timestamp();
        }
        if let Ok(naive) = chrono::NaiveDateTime::parse_from_str(trimmed, format) {
            return chrono::Utc.from_utc_datetime(&naive).timestamp();
        }
        if let Ok(date) = chrono::NaiveDate::parse_from_str(trimmed, format) {
            return date.and_hms_opt(0, 0, 0).map(|d| chrono::Utc.from_utc_datetime(&d).timestamp()).unwrap_or(0);
        }
    }
    0
}

pub fn parse_duration(value: &str) -> Option<i64> {
    let parts: Vec<&str> = value.trim().split(':').collect();
    if parts.is_empty() {
        return None;
    }
    if parts.len() == 1 {
        return parts[0].parse().ok();
    }
    let mut total = 0i64;
    for part in parts {
        total = total * 60 + part.parse::<i64>().ok()?;
    }
    Some(total)
}

pub fn https_equivalent(url: &str) -> Option<String> {
    let parsed = url::Url::parse(url).ok()?;
    if parsed.scheme() != "http" {
        return None;
    }
    let mut upgraded = parsed;
    upgraded.set_scheme("https").ok()?;
    Some(upgraded.to_string())
}

pub struct UreqFetcher {
    timeout: std::time::Duration,
}

impl Default for UreqFetcher {
    fn default() -> Self {
        Self {
            timeout: std::time::Duration::from_secs(12),
        }
    }
}

impl UreqFetcher {
    pub fn request_timeout(&self) -> std::time::Duration {
        self.timeout
    }
}

pub fn fetch_with_https_fallback<F>(url: &str, mut fetch_once: F) -> Result<FeedFetchResponse, Error>
where
    F: FnMut(&str) -> Result<FeedFetchResponse, Error>,
{
    match fetch_once(url) {
        Ok(response) => Ok(response),
        Err(err) => {
            if let Some(upgraded) = https_equivalent(url) {
                fetch_once(&upgraded)
            } else {
                Err(err)
            }
        }
    }
}

impl FeedFetcher for UreqFetcher {
    fn fetch(&self, url: &str, validators: &FeedValidators) -> Result<FeedFetchResponse, Error> {
        fetch_with_https_fallback(url, |candidate| self.fetch_once(candidate, validators))
    }
}

impl UreqFetcher {
    fn fetch_once(&self, url: &str, validators: &FeedValidators) -> Result<FeedFetchResponse, Error> {
        let mut request = ureq::get(url).timeout(self.timeout);
        if let Some(etag) = &validators.etag {
            request = request.set("If-None-Match", etag);
        }
        if let Some(last_modified) = &validators.last_modified {
            request = request.set("If-Modified-Since", last_modified);
        }
        match request.call() {
            Ok(response) => {
                let status = response.status();
                let etag = response.header("ETag").map(str::to_string).or_else(|| validators.etag.clone());
                let last_modified = response
                    .header("Last-Modified")
                    .map(str::to_string)
                    .or_else(|| validators.last_modified.clone());
                let next = FeedValidators { etag, last_modified };
                if status == 304 {
                    return Ok(FeedFetchResponse::NotModified(next));
                }
                if !(200..300).contains(&status) {
                    return Err(Error::Upstream(format!("feed returned HTTP {status}")));
                }
                let mut data = Vec::new();
                response
                    .into_reader()
                    .read_to_end(&mut data)
                    .map_err(|e| Error::Upstream(e.to_string()))?;
                Ok(FeedFetchResponse::Data(data, next))
            }
            Err(ureq::Error::Status(304, response)) => {
                let next = FeedValidators {
                    etag: response.header("ETag").map(str::to_string).or_else(|| validators.etag.clone()),
                    last_modified: response
                        .header("Last-Modified")
                        .map(str::to_string)
                        .or_else(|| validators.last_modified.clone()),
                };
                Ok(FeedFetchResponse::NotModified(next))
            }
            Err(err) => Err(Error::Upstream(err.to_string())),
        }
    }
}

#[derive(Default)]
pub struct MockFeedFetcher {
    pub responses: std::sync::Mutex<std::collections::HashMap<String, Vec<u8>>>,
    pub validators: std::sync::Mutex<std::collections::HashMap<String, FeedValidators>>,
    pub not_modified: std::sync::Mutex<std::collections::HashSet<String>>,
    pub requested: std::sync::Mutex<Vec<String>>,
}

impl MockFeedFetcher {
    pub fn set(&self, url: &str, body: impl Into<Vec<u8>>) {
        self.responses.lock().unwrap().insert(url.to_string(), body.into());
    }
}

impl FeedFetcher for MockFeedFetcher {
    fn fetch(&self, url: &str, _validators: &FeedValidators) -> Result<FeedFetchResponse, Error> {
        self.requested.lock().unwrap().push(url.to_string());
        if self.not_modified.lock().unwrap().contains(url) {
            let v = self
                .validators
                .lock()
                .unwrap()
                .get(url)
                .cloned()
                .unwrap_or_default();
            return Ok(FeedFetchResponse::NotModified(v));
        }
        let data = self
            .responses
            .lock()
            .unwrap()
            .get(url)
            .cloned()
            .ok_or_else(|| Error::Upstream("missing mock feed".into()))?;
        let v = self
            .validators
            .lock()
            .unwrap()
            .get(url)
            .cloned()
            .unwrap_or_default();
        Ok(FeedFetchResponse::Data(data, v))
    }
}

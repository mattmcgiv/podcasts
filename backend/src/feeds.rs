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
    let xml = String::from_utf8_lossy(data);
    let mut feed = ParsedFeed::default();
    if let Some(title) = tag_text(&xml, "title") {
        feed.title = title;
    }
    if let Some(desc) = tag_text(&xml, "description") {
        feed.description = desc;
    }
    let mut rest: &str = &xml;
    while let Some(start) = rest.find("<item") {
        let after = &rest[start..];
        let Some(end_rel) = after.to_lowercase().find("</item>") else { break };
        let item = &after[..end_rel + 7];
        let mut current = ParsedEpisode {
            guid: tag_text(item, "guid").unwrap_or_default(),
            title: tag_text(item, "title").unwrap_or_default(),
            notes_html: tag_text(item, "description").or_else(|| tag_text(item, "content:encoded")).unwrap_or_default(),
            audio_url: enclosure_url(item).unwrap_or_default(),
            duration_secs: tag_text(item, "itunes:duration").and_then(|d| parse_duration(&d)),
            published_at: tag_text(item, "pubDate").or_else(|| tag_text(item, "pubdate")).map(|d| parse_feed_date(&d)).unwrap_or(0),
            image_url: itunes_image(item).unwrap_or_default(),
        };
        if current.audio_url.is_empty() {
            rest = &after[end_rel + 7..];
            continue;
        }
        if current.guid.trim().is_empty() {
            current.guid = current.audio_url.clone();
        }
        feed.episodes.push(current);
        rest = &after[end_rel + 7..];
    }
    Ok(feed)
}

fn tag_text(xml: &str, tag: &str) -> Option<String> {
    let open = format!("<{tag}");
    let close = format!("</{tag}>");
    let lower = xml.to_lowercase();
    let open_l = open.to_lowercase();
    let close_l = close.to_lowercase();
    let start = lower.find(&open_l)?;
    let after = &xml[start..];
    let gt = after.find('>')?;
    let inner = &after[gt + 1..];
    let inner_l = inner.to_lowercase();
    let end = inner_l.find(&close_l)?;
    Some(decode_entities(inner[..end].trim()))
}

fn enclosure_url(item: &str) -> Option<String> {
    let lower = item.to_lowercase();
    let idx = lower.find("<enclosure")?;
    let rest = &item[idx..];
    let end = rest.find('>')?;
    let attrs = parse_attrs(&rest[10..end]);
    attrs.get("url").cloned()
}

fn itunes_image(item: &str) -> Option<String> {
    let lower = item.to_lowercase();
    let idx = lower.find("<itunes:image")?;
    let rest = &item[idx..];
    let end = rest.find('>')?;
    parse_attrs(&rest[13..end]).get("href").cloned()
}

fn parse_attrs(src: &str) -> std::collections::HashMap<String, String> {
    let mut out = std::collections::HashMap::new();
    let mut rest = src.trim().trim_end_matches('/');
    while !rest.is_empty() {
        rest = rest.trim_start();
        let eq = match rest.find('=') {
            Some(i) => i,
            None => break,
        };
        let key = rest[..eq].trim().to_lowercase();
        rest = rest[eq + 1..].trim_start();
        if rest.starts_with('"') || rest.starts_with('\'') {
            let quote = rest.chars().next().unwrap();
            rest = &rest[1..];
            if let Some(end) = rest.find(quote) {
                out.insert(key, decode_entities(&rest[..end]));
                rest = &rest[end + 1..];
            } else {
                break;
            }
        } else {
            let end = rest.find(char::is_whitespace).unwrap_or(rest.len());
            out.insert(key, decode_entities(&rest[..end]));
            rest = &rest[end..];
        }
    }
    out
}

fn decode_entities(value: &str) -> String {
    value
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&amp;", "&")
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
            timeout: std::time::Duration::from_secs(15),
        }
    }
}

impl FeedFetcher for UreqFetcher {
    fn fetch(&self, url: &str, validators: &FeedValidators) -> Result<FeedFetchResponse, Error> {
        match self.fetch_once(url, validators) {
            Ok(response) => Ok(response),
            Err(err) => {
                if let Some(upgraded) = https_equivalent(url) {
                    self.fetch_once(&upgraded, validators)
                } else {
                    Err(err)
                }
            }
        }
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

//! YouTube channel feeds and single-video Listen items.
//!
//! Platform ads are not in the downloaded file. Spoken ads are removed later
//! by the same transcript, classification, and ffmpeg cut as podcasts.
use crate::error::Error;
use crate::feeds::{ParsedEpisode, ParsedFeed};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::path::Path;
use std::process::Command;
use std::sync::Mutex;

pub const MAX_HEIGHT: u32 = 720;
pub const VIDEO_FORMAT: &str = "bv*[height<=720][vcodec^=avc1]+ba[acodec^=mp4a]/bv*[vcodec^=avc1]+ba[acodec^=mp4a]/b[ext=mp4]";
pub const LISTEN_SETTING: &str = "browser_youtube_listen";
pub const RESOLVE_AFTER_SETTING: &str = "browser_youtube_resolve_after";
pub static YT_DLP_TEST_LOCK: Mutex<()> = Mutex::new(());

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum YoutubeInput {
    ChannelFeed { channel_id: String },
    ChannelPage { channel_id: String },
    ChannelLookup { url: String },
    Video { video_id: String },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct VideoMeta {
    pub video_id: String,
    pub channel_id: String,
    pub channel_title: String,
    pub title: String,
    pub thumbnail: String,
    pub published_at: i64,
    pub description: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PendingListen {
    pub url: String,
    pub attempts: u32,
    #[serde(default)]
    pub next_at: i64,
}

pub trait YoutubeProbe: Send + Sync {
    fn channel_id(&self, page_url: &str) -> Result<String, Error>;
    fn video(&self, video_id: &str) -> Result<VideoMeta, Error>;
}

pub struct CommandProbe;

impl YoutubeProbe for CommandProbe {
    fn channel_id(&self, page_url: &str) -> Result<String, Error> {
        let output = ytdlp_output(&[
            "--flat-playlist".into(),
            "--playlist-end".into(),
            "1".into(),
            "--print".into(),
            "%(channel_id)s\t%(id)s".into(),
            "--no-warnings".into(),
            page_url.to_string(),
        ])?;
        let (channel, video_id) = flat_channel_fields(&output);
        if let Some(channel) = channel {
            return Ok(channel);
        }
        let Some(video_id) = video_id else {
            return Err(Error::Upstream("YouTube did not return a channel id".into()));
        };
        let output = ytdlp_output(&[
            "--skip-download".into(),
            "--no-warnings".into(),
            "--no-playlist".into(),
            "--print".into(),
            "channel_id".into(),
            format!("https://www.youtube.com/watch?v={video_id}"),
        ])?;
        output
            .lines()
            .map(str::trim)
            .find_map(|line| valid_channel_id(line).then(|| line.to_string()))
            .ok_or_else(|| Error::Upstream("YouTube did not return a channel id".into()))
    }

    fn video(&self, video_id: &str) -> Result<VideoMeta, Error> {
        let watch = format!("https://www.youtube.com/watch?v={video_id}");
        let output = ytdlp_output(&[
            "--skip-download".into(),
            "--no-warnings".into(),
            "--no-playlist".into(),
            "--print-json".into(),
            watch,
        ])?;
        let json_line = output
            .lines()
            .map(str::trim)
            .find(|line| line.starts_with('{'))
            .ok_or_else(|| Error::Upstream("YouTube did not return video details".into()))?;
        let value: Value = serde_json::from_str(json_line)
            .map_err(|_| Error::Upstream("YouTube video details were not JSON".into()))?;
        let meta = video_meta_from_json(&value)?;
        if meta.video_id != video_id {
            return Err(Error::Upstream("YouTube returned a different video".into()));
        }
        Ok(meta)
    }
}

#[derive(Default)]
pub struct MapProbe {
    pub channels: Mutex<HashMap<String, String>>,
    pub videos: Mutex<HashMap<String, VideoMeta>>,
}

impl YoutubeProbe for MapProbe {
    fn channel_id(&self, page_url: &str) -> Result<String, Error> {
        self.channels
            .lock()
            .expect("youtube channel map")
            .get(page_url)
            .cloned()
            .filter(|id| valid_channel_id(id))
            .ok_or_else(|| Error::Upstream("YouTube channel lookup failed".into()))
    }

    fn video(&self, video_id: &str) -> Result<VideoMeta, Error> {
        self.videos
            .lock()
            .expect("youtube video map")
            .get(video_id)
            .cloned()
            .ok_or_else(|| Error::Upstream("YouTube video lookup failed".into()))
    }
}

pub fn classify(raw: &str) -> Result<Option<YoutubeInput>, Error> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    if let Some(id) = trimmed.strip_prefix('@') {
        if valid_handle(id) && !id.contains('/') {
            return Ok(Some(YoutubeInput::ChannelLookup {
                url: format!("https://www.youtube.com/@{id}"),
            }));
        }
    }
    if valid_channel_id(trimmed) {
        return Ok(Some(YoutubeInput::ChannelPage {
            channel_id: trimmed.to_string(),
        }));
    }
    if !looks_like_youtube(trimmed) {
        return Ok(None);
    }
    let url = url::Url::parse(trimmed).map_err(|_| Error::Invalid("invalid YouTube URL".into()))?;
    if url.scheme() != "https" && url.scheme() != "http" {
        return Err(Error::Invalid("invalid YouTube URL".into()));
    }
    let host = url
        .host_str()
        .unwrap_or_default()
        .trim_start_matches("www.")
        .trim_start_matches("m.");
    if host == "youtu.be" {
        let id = single_path(url.path()).ok_or_else(|| Error::Invalid("invalid YouTube video URL".into()))?;
        return Ok(Some(YoutubeInput::Video {
            video_id: require_video_id(id)?,
        }));
    }
    if host != "youtube.com" && host != "music.youtube.com" {
        return Ok(None);
    }
    let segments = path_segments(url.path());
    if segments.first().copied() == Some("feeds") && segments.get(1).copied() == Some("videos.xml") {
        let id = query_value(&url, "channel_id").unwrap_or_default();
        return Ok(Some(YoutubeInput::ChannelFeed {
            channel_id: require_channel_id(&id)?,
        }));
    }
    if segments.first().copied() == Some("watch") || segments.is_empty() {
        if let Some(id) = query_value(&url, "v") {
            return Ok(Some(YoutubeInput::Video {
                video_id: require_video_id(&id)?,
            }));
        }
    }
    if let Some(id) = match segments.as_slice() {
        ["shorts", id] | ["embed", id] | ["live", id] | ["v", id] => Some(*id),
        _ => None,
    } {
        return Ok(Some(YoutubeInput::Video {
            video_id: require_video_id(id)?,
        }));
    }
    if let Some(handle) = segments.first().copied().filter(|segment| segment.starts_with('@')) {
        let name = handle.trim_start_matches('@');
        if !valid_handle(name) {
            return Err(Error::Invalid("invalid YouTube channel URL".into()));
        }
        return Ok(Some(YoutubeInput::ChannelLookup {
            url: format!("https://www.youtube.com/@{name}"),
        }));
    }
    if segments.first().copied() == Some("channel") {
        let id = segments.get(1).copied().unwrap_or("");
        return Ok(Some(YoutubeInput::ChannelPage {
            channel_id: require_channel_id(id)?,
        }));
    }
    if matches!(segments.first().copied(), Some("c") | Some("user")) {
        let kind = segments[0];
        let name = segments.get(1).copied().filter(|name| valid_handle(name)).ok_or_else(|| {
            Error::Invalid("invalid YouTube channel URL".into())
        })?;
        return Ok(Some(YoutubeInput::ChannelLookup {
            url: format!("https://www.youtube.com/{kind}/{name}"),
        }));
    }
    Err(Error::Invalid(
        "paste a YouTube channel URL or a single video URL".into(),
    ))
}

pub fn channel_feed_url(channel_id: &str) -> String {
    format!("https://www.youtube.com/feeds/videos.xml?channel_id={channel_id}")
}

pub fn source_url(video_id: &str) -> String {
    format!("youtube:{video_id}")
}

pub fn video_id_from_source(url: &str) -> Option<&str> {
    let id = url.strip_prefix("youtube:")?;
    valid_video_id(id).then_some(id)
}

pub fn is_youtube_feed(url: &str) -> bool {
    matches!(classify(url).ok().flatten(), Some(YoutubeInput::ChannelFeed { .. }))
}

pub fn canonical_feed_url(input: &YoutubeInput) -> Option<String> {
    match input {
        YoutubeInput::ChannelFeed { channel_id } | YoutubeInput::ChannelPage { channel_id } => {
            Some(channel_feed_url(channel_id))
        }
        YoutubeInput::ChannelLookup { .. } | YoutubeInput::Video { .. } => None,
    }
}

pub fn parse_catalog(url: &str, data: &[u8]) -> Result<ParsedFeed, Error> {
    if is_youtube_feed(url) {
        parse_atom(data)
    } else {
        crate::feeds::parse_feed(data)
    }
}

pub fn parse_atom(data: &[u8]) -> Result<ParsedFeed, Error> {
    let xml = std::str::from_utf8(data).map_err(|_| Error::Upstream("YouTube feed is not UTF-8".into()))?;
    let document = roxmltree::Document::parse(xml)
        .map_err(|_| Error::Upstream("YouTube feed contains invalid XML".into()))?;
    let feed = document.root_element();
    if feed.tag_name().name() != "feed" {
        return Err(Error::Upstream("YouTube feed has no Atom feed".into()));
    }
    let mut parsed = ParsedFeed {
        title: child_text(feed, "title"),
        description: String::new(),
        image_url: String::new(),
        site_url: link_href(feed, "alternate"),
        episodes: Vec::new(),
    };
    if parsed.title.is_empty() {
        parsed.title = child_text(child(feed, "author"), "name");
    }
    for entry in feed.children().filter(|node| node.tag_name().name() == "entry") {
        let video_id = child_text(entry, "videoId");
        if !valid_video_id(&video_id) {
            continue;
        }
        let title = child_text(entry, "title");
        if title.is_empty() {
            continue;
        }
        let published = child_text(entry, "published");
        let published_at = chrono::DateTime::parse_from_rfc3339(published.trim())
            .map(|time| time.timestamp())
            .unwrap_or(0);
        let image_url = descendant_attr(entry, "thumbnail", "url");
        let description = descendant_text(entry, "description");
        if parsed.image_url.is_empty() {
            parsed.image_url = image_url.clone();
        }
        parsed.episodes.push(ParsedEpisode {
            guid: video_id.clone(),
            title,
            notes_html: description,
            audio_url: source_url(&video_id),
            duration_secs: None,
            published_at,
            image_url,
        });
    }
    if parsed.episodes.is_empty() {
        return Err(Error::Upstream("YouTube feed has no videos".into()));
    }
    Ok(parsed)
}

pub fn video_meta_from_json(value: &Value) -> Result<VideoMeta, Error> {
    let video_id = value
        .get("id")
        .and_then(Value::as_str)
        .filter(|id| valid_video_id(id))
        .ok_or_else(|| Error::Upstream("YouTube video id missing".into()))?
        .to_string();
    let channel_id = value
        .get("channel_id")
        .and_then(Value::as_str)
        .filter(|id| valid_channel_id(id))
        .ok_or_else(|| Error::Upstream("YouTube channel id missing".into()))?
        .to_string();
    let title = value
        .get("title")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|title| !title.is_empty())
        .unwrap_or("Untitled video")
        .to_string();
    let channel_title = value
        .get("channel")
        .or_else(|| value.get("uploader"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|title| !title.is_empty())
        .unwrap_or("YouTube")
        .to_string();
    let thumbnail = value
        .get("thumbnail")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let published_at = value
        .get("timestamp")
        .and_then(Value::as_i64)
        .or_else(|| {
            value
                .get("upload_date")
                .and_then(Value::as_str)
                .and_then(upload_date_to_unix)
        })
        .unwrap_or(0);
    let description = value
        .get("description")
        .and_then(Value::as_str)
        .unwrap_or("")
        .chars()
        .take(4000)
        .collect();
    Ok(VideoMeta {
        video_id,
        channel_id,
        channel_title,
        title,
        thumbnail,
        published_at,
        description,
    })
}

pub fn download_arguments(output_mp4: &Path) -> Vec<String> {
    vec![
        "--no-playlist".into(),
        "--no-warnings".into(),
        "--no-progress".into(),
        "--retries".into(),
        "2".into(),
        "--socket-timeout".into(),
        "30".into(),
        "--match-filter".into(),
        "!is_live".into(),
        "-f".into(),
        VIDEO_FORMAT.into(),
        "--merge-output-format".into(),
        "mp4".into(),
        "-o".into(),
        output_mp4.display().to_string(),
    ]
}

pub fn ytdlp_bin() -> String {
    std::env::var("PODS_YT_DLP").unwrap_or_else(|_| "yt-dlp".into())
}

fn flat_channel_fields(output: &str) -> (Option<String>, Option<String>) {
    for line in output.lines().map(str::trim).filter(|line| !line.is_empty()) {
        let mut parts = line.split('\t');
        let channel = parts.next().unwrap_or("").trim();
        let video = parts.next().unwrap_or("").trim();
        let channel = valid_channel_id(channel).then(|| channel.to_string());
        let video = valid_video_id(video).then(|| video.to_string());
        if channel.is_some() || video.is_some() {
            return (channel, video);
        }
    }
    (None, None)
}

fn ytdlp_output(args: &[String]) -> Result<String, Error> {
    let output = Command::new(ytdlp_bin())
        .args(args)
        .output()
        .map_err(|_| Error::Upstream("yt-dlp failed to start".into()))?;
    if !output.status.success() {
        return Err(Error::Upstream("yt-dlp could not read that YouTube URL".into()));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

fn looks_like_youtube(raw: &str) -> bool {
    let lower = raw.to_ascii_lowercase();
    lower.contains("youtube.com") || lower.contains("youtu.be")
}

fn path_segments(path: &str) -> Vec<&str> {
    path.split('/').filter(|segment| !segment.is_empty()).collect()
}

fn single_path(path: &str) -> Option<&str> {
    let segments = path_segments(path);
    (segments.len() == 1).then(|| segments[0])
}

fn query_value(url: &url::Url, key: &str) -> Option<String> {
    url.query_pairs()
        .find(|(name, _)| name == key)
        .map(|(_, value)| value.into_owned())
}

fn require_video_id(id: &str) -> Result<String, Error> {
    valid_video_id(id)
        .then(|| id.to_string())
        .ok_or_else(|| Error::Invalid("invalid YouTube video URL".into()))
}

fn require_channel_id(id: &str) -> Result<String, Error> {
    valid_channel_id(id)
        .then(|| id.to_string())
        .ok_or_else(|| Error::Invalid("invalid YouTube channel URL".into()))
}

fn valid_video_id(id: &str) -> bool {
    id.len() == 11 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

fn valid_channel_id(id: &str) -> bool {
    id.len() == 24
        && id.starts_with("UC")
        && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

fn valid_handle(name: &str) -> bool {
    let chars: Vec<char> = name.chars().collect();
    (1..=60).contains(&chars.len())
        && chars
            .iter()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

fn child<'a>(node: roxmltree::Node<'a, 'a>, name: &str) -> roxmltree::Node<'a, 'a> {
    node.children()
        .find(|child| child.is_element() && child.tag_name().name() == name)
        .unwrap_or(node)
}

fn child_text(node: roxmltree::Node<'_, '_>, name: &str) -> String {
    node.children()
        .find(|child| child.is_element() && child.tag_name().name() == name)
        .map(|child| {
            child
                .children()
                .filter(|node| node.is_text())
                .filter_map(|node| node.text())
                .collect::<String>()
                .trim()
                .to_owned()
        })
        .unwrap_or_default()
}

fn descendant_text(node: roxmltree::Node<'_, '_>, name: &str) -> String {
    node.descendants()
        .find(|child| child.is_element() && child.tag_name().name() == name)
        .map(|child| {
            child
                .children()
                .filter(|node| node.is_text())
                .filter_map(|node| node.text())
                .collect::<String>()
                .trim()
                .to_owned()
        })
        .unwrap_or_default()
}

fn descendant_attr(node: roxmltree::Node<'_, '_>, name: &str, attr: &str) -> String {
    node.descendants()
        .find(|child| child.is_element() && child.tag_name().name() == name)
        .and_then(|child| child.attribute(attr))
        .unwrap_or("")
        .to_string()
}

fn link_href(node: roxmltree::Node<'_, '_>, rel: &str) -> String {
    node.children()
        .find(|child| {
            child.is_element()
                && child.tag_name().name() == "link"
                && child.attribute("rel") == Some(rel)
        })
        .and_then(|child| child.attribute("href"))
        .unwrap_or("")
        .to_string()
}

fn upload_date_to_unix(value: &str) -> Option<i64> {
    let date = chrono::NaiveDate::parse_from_str(value, "%Y%m%d").ok()?;
    Some(date.and_hms_opt(0, 0, 0)?.and_utc().timestamp())
}

#[cfg(test)]
mod tests {
    use super::*;

    const CHANNEL: &str = "UCabcdefghijklmnopqrstuv";

    #[test]
    fn classifies_channels_and_videos() {
        assert_eq!(
            classify("https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv").unwrap(),
            Some(YoutubeInput::ChannelPage {
                channel_id: CHANNEL.into()
            })
        );
        assert_eq!(
            classify("https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdefghijklmnopqrstuv").unwrap(),
            Some(YoutubeInput::ChannelFeed {
                channel_id: CHANNEL.into()
            })
        );
        assert_eq!(
            classify("@veritasium").unwrap(),
            Some(YoutubeInput::ChannelLookup {
                url: "https://www.youtube.com/@veritasium".into()
            })
        );
        assert_eq!(
            classify("https://www.youtube.com/@veritasium/videos").unwrap(),
            Some(YoutubeInput::ChannelLookup {
                url: "https://www.youtube.com/@veritasium".into()
            })
        );
        assert_eq!(
            classify("https://youtu.be/abcdefghijk").unwrap(),
            Some(YoutubeInput::Video {
                video_id: "abcdefghijk".into()
            })
        );
        assert_eq!(
            classify("https://m.youtube.com/watch?v=abcdefghijk&t=12").unwrap(),
            Some(YoutubeInput::Video {
                video_id: "abcdefghijk".into()
            })
        );
        assert_eq!(
            classify("https://www.youtube.com/shorts/abcdefghijk").unwrap(),
            Some(YoutubeInput::Video {
                video_id: "abcdefghijk".into()
            })
        );
        assert!(classify("https://example.com/feed.xml").unwrap().is_none());
        assert!(classify("https://www.youtube.com/playlist?list=PL123").is_err());
    }

    #[test]
    fn atom_feed_becomes_video_sources_without_enclosures() {
        let xml = format!(
            r#"<?xml version="1.0"?>
            <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns:media="http://search.yahoo.com/mrss/" xmlns="http://www.w3.org/2005/Atom">
              <title>Example Channel</title>
              <author><name>Example Channel</name></author>
              <link rel="alternate" href="https://www.youtube.com/channel/{CHANNEL}"/>
              <entry>
                <yt:videoId>oldvideo111</yt:videoId>
                <title>Oldest</title>
                <published>2024-01-01T00:00:00+00:00</published>
                <media:group>
                  <media:thumbnail url="https://i.ytimg.com/vi/oldvideo111/hqdefault.jpg"/>
                  <media:description>Old notes</media:description>
                </media:group>
              </entry>
              <entry>
                <yt:videoId>newvideo222</yt:videoId>
                <title>Newest</title>
                <published>2024-03-01T00:00:00+00:00</published>
                <media:group><media:description>New notes</media:description></media:group>
              </entry>
            </feed>"#
        );
        let feed = parse_atom(xml.as_bytes()).unwrap();
        assert_eq!(feed.title, "Example Channel");
        assert_eq!(feed.episodes.len(), 2);
        assert_eq!(feed.episodes[0].guid, "oldvideo111");
        assert_eq!(feed.episodes[0].audio_url, "youtube:oldvideo111");
        assert!(feed.episodes[0].published_at > 0);
        assert_eq!(feed.image_url, "https://i.ytimg.com/vi/oldvideo111/hqdefault.jpg");
    }

    #[test]
    fn video_json_reads_channel_and_timestamp() {
        let meta = video_meta_from_json(&serde_json::json!({
            "id": "abcdefghijk",
            "channel_id": CHANNEL,
            "channel": "Example",
            "title": "One video",
            "thumbnail": "https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg",
            "timestamp": 1_700_000_000,
            "description": "Hello"
        }))
        .unwrap();
        assert_eq!(meta.video_id, "abcdefghijk");
        assert_eq!(meta.channel_title, "Example");
        assert_eq!(meta.published_at, 1_700_000_000);
    }

    fn ytdlp_stub() -> &'static str {
        r#"#!/usr/bin/env python3
import re, sys
args = sys.argv[1:]
url = args[-1] if args else ""
printed = args[args.index("--print") + 1] if "--print" in args else ""

def emit(channel_id, video_id):
    if printed == "channel_id":
        print(channel_id)
    elif "%(" in printed:
        print(
            printed.replace("%(channel_id)s", channel_id)
            .replace("%(id)s", video_id)
            .replace("%(channel)s", "Channel")
            .replace("%(uploader_id)s", "NA")
        )
    else:
        print(channel_id)

if "watch?v=" in url or "--print-json" in args:
    if "abcdefghijk" in url:
        sys.exit(1)
    if "--print-json" in args:
        print('{"id":"F3YXg7AaKWE","channel_id":"UCbRP3c757lWg9M-U7TyEkXA","channel":"Theo","title":"One","thumbnail":"","timestamp":1700000000,"description":""}')
        sys.exit(0)
    if "F3YXg7AaKWE" in url:
        emit("UCbRP3c757lWg9M-U7TyEkXA", "F3YXg7AaKWE")
        sys.exit(0)
    sys.exit(1)

match = re.search(r"(UC[A-Za-z0-9_-]{22})", url)
if match:
    emit(match.group(1), "abcdefghijk")
    sys.exit(0)
if printed == "channel_id":
    print("NA")
    sys.exit(0)
if "%(" in printed:
    emit("NA", "F3YXg7AaKWE")
    sys.exit(0)
print("NA")
"#
    }

    fn with_ytdlp_stub<T>(test: impl FnOnce() -> T) -> T {
        let _guard = YT_DLP_TEST_LOCK.lock().unwrap();
        let previous = std::env::var("PODS_YT_DLP").ok();
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("yt-dlp");
        std::fs::write(&bin, ytdlp_stub()).unwrap();
        std::fs::set_permissions(&bin, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
        std::env::set_var("PODS_YT_DLP", &bin);
        let result = test();
        match previous {
            Some(value) => std::env::set_var("PODS_YT_DLP", value),
            None => std::env::remove_var("PODS_YT_DLP"),
        }
        result
    }

    #[test]
    fn channel_lookup_reads_a_channel_id_printed_by_the_flat_playlist() {
        with_ytdlp_stub(|| {
            let id = CommandProbe
                .channel_id("https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv")
                .unwrap();
            assert_eq!(id, "UCabcdefghijklmnopqrstuv");
        });
    }

    #[test]
    fn channel_lookup_follows_a_video_when_the_flat_playlist_channel_id_is_na() {
        with_ytdlp_stub(|| {
            let id = CommandProbe
                .channel_id("https://www.youtube.com/@t3dotgg")
                .unwrap();
            assert_eq!(id, "UCbRP3c757lWg9M-U7TyEkXA");
        });
    }

    #[test]
    fn download_arguments_cap_height_and_codecs() {
        let args = download_arguments(Path::new("/tmp/video.mp4"));
        let format = args[args.iter().position(|arg| arg == "-f").unwrap() + 1].as_str();
        assert!(format.contains("height<=720"));
        assert!(format.contains("vcodec^=avc1"));
        assert!(format.contains("acodec^=mp4a"));
        assert!(args.iter().any(|arg| arg == "!is_live"));
        assert!(args.iter().any(|arg| arg == "/tmp/video.mp4"));
    }
}

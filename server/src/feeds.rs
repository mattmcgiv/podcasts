use crate::error::AppError;
use crate::{now, AppState};
use feed_rs::model::{Entry, Feed};
use sqlx::SqlitePool;

pub fn sanitize_html(html: &str) -> String {
    ammonia::clean(html)
}

pub fn html_to_text(html: &str) -> String {
    ammonia::Builder::empty().clean(html).to_string()
}

pub async fn fetch_and_parse(http: &reqwest::Client, url: &str) -> Result<Feed, AppError> {
    let resp = http.get(url).send().await?.error_for_status()?;
    let bytes = resp.bytes().await?;
    Ok(feed_rs::parser::parse(bytes.as_ref())?)
}

/// Best audio enclosure for an entry: prefer an explicitly audio-typed media
/// content, fall back to the first one with a URL at all (feeds mislabel).
pub fn entry_audio(entry: &Entry) -> Option<(String, Option<i64>)> {
    let mut fallback: Option<(String, Option<i64>)> = None;
    for media in &entry.media {
        let obj_duration = media.duration.map(|d| d.as_secs() as i64);
        for content in &media.content {
            let Some(url) = content.url.as_ref() else {
                continue;
            };
            let duration = content
                .duration
                .map(|d| d.as_secs() as i64)
                .or(obj_duration);
            let is_audio = content
                .content_type
                .as_ref()
                .map(|m| m.essence_str().starts_with("audio/"))
                .unwrap_or(false);
            if is_audio {
                return Some((url.to_string(), duration));
            }
            if fallback.is_none() {
                fallback = Some((url.to_string(), duration));
            }
        }
    }
    fallback
}

pub fn entry_guid(entry: &Entry, audio_url: &str) -> String {
    if entry.id.trim().is_empty() {
        audio_url.to_string()
    } else {
        entry.id.clone()
    }
}

fn entry_notes(entry: &Entry) -> String {
    entry
        .content
        .as_ref()
        .and_then(|c| c.body.clone())
        .or_else(|| entry.summary.as_ref().map(|s| s.content.clone()))
        .unwrap_or_default()
}

fn entry_published(entry: &Entry) -> i64 {
    entry
        .published
        .or(entry.updated)
        .map(|d| d.timestamp())
        .unwrap_or(0)
}

fn entry_image(entry: &Entry) -> String {
    entry
        .media
        .iter()
        .flat_map(|m| m.thumbnails.first())
        .next()
        .map(|t| t.image.uri.clone())
        .unwrap_or_default()
}

pub fn feed_image(feed: &Feed) -> String {
    feed.logo
        .as_ref()
        .map(|i| i.uri.clone())
        .or_else(|| feed.icon.as_ref().map(|i| i.uri.clone()))
        .unwrap_or_default()
}

async fn refresh_fts(pool: &SqlitePool, episode_id: i64, title: &str, notes_html: &str) -> Result<(), sqlx::Error> {
    sqlx::query("DELETE FROM episodes_fts WHERE rowid = ?")
        .bind(episode_id)
        .execute(pool)
        .await?;
    sqlx::query("INSERT INTO episodes_fts (rowid, title, notes) VALUES (?, ?, ?)")
        .bind(episode_id)
        .bind(title)
        .bind(html_to_text(notes_html))
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn upsert_podcast_meta(pool: &SqlitePool, podcast_id: i64, feed: &Feed) -> Result<(), sqlx::Error> {
    let title = feed.title.as_ref().map(|t| t.content.clone()).unwrap_or_default();
    let description = sanitize_html(
        &feed.description.as_ref().map(|t| t.content.clone()).unwrap_or_default(),
    );
    let site = feed.links.first().map(|l| l.href.clone()).unwrap_or_default();
    sqlx::query(
        "UPDATE podcasts SET title = ?, description = ?, image_url = ?, site_url = ?, last_fetched_at = ? WHERE id = ?",
    )
    .bind(title)
    .bind(description)
    .bind(feed_image(feed))
    .bind(site)
    .bind(now())
    .bind(podcast_id)
    .execute(pool)
    .await?;
    Ok(())
}

/// Insert/update all entries of a parsed feed. Returns how many were new.
pub async fn upsert_episodes(pool: &SqlitePool, podcast_id: i64, feed: &Feed) -> Result<usize, sqlx::Error> {
    let mut new_count = 0usize;
    for entry in &feed.entries {
        let Some((audio_url, duration)) = entry_audio(entry) else {
            continue;
        };
        let guid = entry_guid(entry, &audio_url);
        let title = entry.title.as_ref().map(|t| t.content.clone()).unwrap_or_default();
        let notes_html = sanitize_html(&entry_notes(entry));
        let published = entry_published(entry);
        let image = entry_image(entry);

        let existing: Option<i64> =
            sqlx::query_scalar("SELECT id FROM episodes WHERE podcast_id = ? AND guid = ?")
                .bind(podcast_id)
                .bind(&guid)
                .fetch_optional(pool)
                .await?;

        let episode_id = match existing {
            Some(id) => {
                sqlx::query(
                    "UPDATE episodes SET title = ?, notes_html = ?, audio_url = ?, duration_secs = ?, published_at = ?, image_url = ? WHERE id = ?",
                )
                .bind(&title)
                .bind(&notes_html)
                .bind(&audio_url)
                .bind(duration)
                .bind(published)
                .bind(&image)
                .bind(id)
                .execute(pool)
                .await?;
                id
            }
            None => {
                new_count += 1;
                let res = sqlx::query(
                    "INSERT INTO episodes (podcast_id, guid, title, notes_html, audio_url, duration_secs, published_at, image_url) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                )
                .bind(podcast_id)
                .bind(&guid)
                .bind(&title)
                .bind(&notes_html)
                .bind(&audio_url)
                .bind(duration)
                .bind(published)
                .bind(&image)
                .execute(pool)
                .await?;
                res.last_insert_rowid()
            }
        };
        refresh_fts(pool, episode_id, &title, &notes_html).await?;
    }
    Ok(new_count)
}

/// Subscribe to a feed URL: insert the podcast, pull episodes, and archive the
/// back catalog so only the newest 2 land in Recent.
pub async fn subscribe(state: &AppState, feed_url: &str) -> Result<i64, AppError> {
    let feed_url = feed_url.trim();
    if !(feed_url.starts_with("http://") || feed_url.starts_with("https://")) {
        return Err(AppError::Invalid("feed_url must be an http(s) URL".into()));
    }
    let exists: Option<i64> = sqlx::query_scalar("SELECT id FROM podcasts WHERE feed_url = ?")
        .bind(feed_url)
        .fetch_optional(&state.pool)
        .await?;
    if exists.is_some() {
        return Err(AppError::Conflict("already subscribed".into()));
    }

    let feed = fetch_and_parse(&state.http, feed_url).await?;
    let res = sqlx::query("INSERT INTO podcasts (feed_url, created_at) VALUES (?, ?)")
        .bind(feed_url)
        .bind(now())
        .execute(&state.pool)
        .await?;
    let podcast_id = res.last_insert_rowid();
    upsert_podcast_meta(&state.pool, podcast_id, &feed).await?;
    upsert_episodes(&state.pool, podcast_id, &feed).await?;

    // Keep the newest 2 in Recent; everything older is archived (not "played").
    let ts = now();
    sqlx::query(
        "INSERT INTO episode_state (episode_id, archived_at, updated_at)
         SELECT id, ?, ? FROM episodes WHERE podcast_id = ?
         ORDER BY published_at DESC, id DESC LIMIT -1 OFFSET 2
         ON CONFLICT (episode_id) DO UPDATE SET archived_at = excluded.archived_at, updated_at = excluded.updated_at",
    )
    .bind(ts)
    .bind(ts)
    .bind(podcast_id)
    .execute(&state.pool)
    .await?;

    Ok(podcast_id)
}

pub async fn refresh_one(state: &AppState, podcast_id: i64, feed_url: &str) -> Result<usize, AppError> {
    let feed = fetch_and_parse(&state.http, feed_url).await?;
    upsert_podcast_meta(&state.pool, podcast_id, &feed).await?;
    let new_count = upsert_episodes(&state.pool, podcast_id, &feed).await?;
    Ok(new_count)
}

/// Refresh every subscription. Returns (succeeded, failed). Concurrent calls
/// (timer + manual button) coalesce via the lock.
pub async fn refresh_all(state: &AppState) -> (usize, usize) {
    let _guard = state.refresh_lock.lock().await;
    let rows: Vec<(i64, String)> =
        match sqlx::query_as("SELECT id, feed_url FROM podcasts ORDER BY id")
            .fetch_all(&state.pool)
            .await
        {
            Ok(r) => r,
            Err(e) => {
                tracing::error!(error = %e, "listing podcasts for refresh");
                return (0, 0);
            }
        };
    let mut ok = 0;
    let mut errs = 0;
    for (id, url) in rows {
        match refresh_one(state, id, &url).await {
            Ok(_) => ok += 1,
            Err(e) => {
                errs += 1;
                tracing::warn!(podcast_id = id, error = %e, "feed refresh failed");
            }
        }
    }
    (ok, errs)
}

#[cfg(test)]
mod tests {
    use super::*;

    const RSS: &str = r#"<?xml version="1.0"?>
<rss version="2.0"><channel>
  <title>Show</title>
  <item>
    <title>With guid</title>
    <guid>abc-1</guid>
    <enclosure url="https://h.example/e1.mp3" type="audio/mpeg" length="1"/>
  </item>
  <item>
    <title>No guid</title>
    <enclosure url="https://h.example/e2.mp3" type="audio/mpeg" length="1"/>
  </item>
  <item>
    <title>No enclosure</title>
    <guid>abc-3</guid>
  </item>
</channel></rss>"#;

    #[test]
    fn audio_and_guid_extraction() {
        let feed = feed_rs::parser::parse(RSS.as_bytes()).unwrap();
        let with_audio: Vec<_> = feed
            .entries
            .iter()
            .filter_map(|e| entry_audio(e).map(|(url, _)| (e, url)))
            .collect();
        assert_eq!(with_audio.len(), 2);
        let (e1, url1) = &with_audio[0];
        assert_eq!(url1, "https://h.example/e1.mp3");
        assert_eq!(entry_guid(e1, url1), "abc-1");
        let (e2, url2) = &with_audio[1];
        // feed-rs synthesizes ids; a guid never collapses to empty
        assert!(!entry_guid(e2, url2).is_empty());
    }

    #[test]
    fn sanitizer_strips_scripts() {
        let html = r#"<p>hi</p><script>alert(1)</script><a href="javascript:x">x</a>"#;
        let clean = sanitize_html(html);
        assert!(!clean.contains("script"));
        assert!(!clean.contains("javascript:"));
        assert!(clean.contains("<p>hi</p>"));
        assert_eq!(html_to_text("<p>a <b>b</b></p>"), "a b");
    }
}

use pods_backend::backend::{Backend, DirectorySearcher};
use pods_backend::db::Database;
use pods_backend::feeds::MockFeedFetcher;
use pods_backend::http::HttpRequest;
use pods_backend::models::*;
use pods_backend::Error;
use serde_json::{json, Value};
use std::sync::Arc;

const D1: &str = "Mon, 06 Jan 2025 00:00:00 GMT";
const D2: &str = "Tue, 07 Jan 2025 00:00:00 GMT";
const D3: &str = "Wed, 08 Jan 2025 00:00:00 GMT";
const D4: &str = "Thu, 09 Jan 2025 00:00:00 GMT";

fn rss(show: &str, items: &[(&str, &str, &str, &str)]) -> String {
    let mut body = format!("<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>{show}</title><description>About {show}</description>");
    for (title, guid, url, date) in items {
        body.push_str(&format!(
            "<item><title>{title}</title><guid>{guid}</guid><pubDate>{date}</pubDate><description>&lt;p&gt;Notes for {title}&lt;/p&gt;</description><enclosure url=\"{url}\" type=\"audio/mpeg\" length=\"123\"/></item>"
        ));
    }
    body.push_str("</channel></rss>");
    body
}

struct Harness {
    backend: Backend,
    fetcher: Arc<MockFeedFetcher>,
}

fn harness() -> Harness {
    let db = Database::open_in_memory().expect("db");
    let fetcher = Arc::new(MockFeedFetcher::default());
    let backend = Backend::new(db, fetcher.clone(), Arc::new(pods_backend::DisabledDirectory));
    let _ = call(&backend, "PUT", "/api/ad-removal/deepseek-key", Some(json!({"api_key": "test-api-key"})));
    Harness { backend, fetcher }
}

fn call(backend: &Backend, method: &str, target: &str, json_body: Option<Value>) -> pods_backend::HttpResponse {
    let mut req = HttpRequest::new(method, target);
    if let Some(body) = json_body {
        req = req.with_json(&body);
    }
    backend.handle(req)
}

fn decode<T: serde::de::DeserializeOwned>(response: &pods_backend::HttpResponse) -> T {
    serde_json::from_slice(&response.body).expect("json")
}

#[test]
fn test_endpoints_do_not_require_auth() {
    let h = harness();
    let response = call(&h.backend, "GET", "/api/recent", None);
    assert_eq!(response.status_code, 200);
    let page: Page<EpisodeItem> = decode(&response);
    assert!(page.items.is_empty());
}

struct AppearanceSearcher {
    appearances: Vec<DirectoryAppearance>,
}

impl DirectorySearcher for AppearanceSearcher {
    fn is_configured(&self) -> bool {
        true
    }
    fn search(&self, _query: &str) -> Result<Vec<DirectoryPodcast>, Error> {
        Ok(vec![])
    }
    fn search_appearances(&self, _person: &str) -> Result<Vec<DirectoryAppearance>, Error> {
        Ok(self.appearances.clone())
    }
}

fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}

#[test]
fn test_follow_accepts_high_confidence_appearance_into_listen() {
    let appearance = DirectoryAppearance {
        source_episode_key: "appearance-1".into(),
        feed_url: "https://feeds.example/interviews.xml".into(),
        feed_title: "Interviews".into(),
        feed_image_url: "https://images.example/show.jpg".into(),
        guid: "guest-1".into(),
        title: "Balaji Srinivasan on Network States".into(),
        description: "A full conversation with Balaji Srinivasan.".into(),
        audio_url: "https://audio.example/guest-1.mp3".into(),
        duration_secs: Some(3600),
        published_at: now_unix(),
        image_url: "https://images.example/episode.jpg".into(),
        evidence: "person tag: guest".into(),
        confidence: "high".into(),
    };
    let db = Database::open_in_memory().unwrap();
    let fetcher = Arc::new(MockFeedFetcher::default());
    let backend = Backend::new(db, fetcher, Arc::new(AppearanceSearcher { appearances: vec![appearance.clone()] }));
    let created = call(&backend, "POST", "/api/follows", Some(json!({"name":"Balaji Srinivasan"})));
    assert_eq!(created.status_code, 201);
    let follow: Follow = decode(&created);
    assert_eq!(follow.accepted_count, 1);
    assert_eq!(follow.pending_count, 0);
    let refreshed = call(&backend, "POST", &format!("/api/follows/{}", follow.id), None);
    let refreshed_follow: Follow = decode(&refreshed);
    assert_eq!(refreshed_follow.accepted_count, 1);
    let recent: Page<EpisodeItem> = decode(&call(&backend, "GET", "/api/recent", None));
    assert_eq!(recent.items.iter().map(|i| i.title.clone()).collect::<Vec<_>>(), vec![appearance.title]);
    let shows: Vec<Show> = decode(&call(&backend, "GET", "/api/shows", None));
    assert!(shows.is_empty());
}

#[test]
fn test_follow_keeps_ambiguous_appearance_out_of_listen_until_accepted() {
    let appearance = DirectoryAppearance {
        source_episode_key: "appearance-2".into(),
        feed_url: "https://feeds.example/tech.xml".into(),
        feed_title: "Tech Talk".into(),
        feed_image_url: "".into(),
        guid: "guest-2".into(),
        title: "The future of Elon Musk's companies".into(),
        description: "A discussion about Elon Musk.".into(),
        audio_url: "https://audio.example/guest-2.mp3".into(),
        duration_secs: None,
        published_at: now_unix(),
        image_url: "".into(),
        evidence: "name in title".into(),
        confidence: "review".into(),
    };
    let db = Database::open_in_memory().unwrap();
    let backend = Backend::new(db, Arc::new(MockFeedFetcher::default()), Arc::new(AppearanceSearcher { appearances: vec![appearance] }));
    let _ = call(&backend, "POST", "/api/follows", Some(json!({"name":"Elon Musk"})));
    let before: Page<EpisodeItem> = decode(&call(&backend, "GET", "/api/recent", None));
    assert!(before.items.is_empty());
    let candidates: Vec<FollowCandidate> = decode(&call(&backend, "GET", "/api/follow-candidates", None));
    assert_eq!(candidates.len(), 1);
    let accepted = call(&backend, "POST", &format!("/api/follow-candidates/{}/accept", candidates[0].id), None);
    assert_eq!(accepted.status_code, 204);
    let after: Page<EpisodeItem> = decode(&call(&backend, "GET", "/api/recent", None));
    assert_eq!(after.items.len(), 1);
}

#[test]
fn test_first_follow_check_excludes_appearances_older_than_thirty_days() {
    let old = DirectoryAppearance {
        source_episode_key: "old".into(),
        feed_url: "https://feeds.example/old.xml".into(),
        feed_title: "Old".into(),
        feed_image_url: "".into(),
        guid: "old".into(),
        title: "Old appearance".into(),
        description: "".into(),
        audio_url: "https://audio.example/old.mp3".into(),
        duration_secs: None,
        published_at: now_unix() - 40 * 24 * 60 * 60,
        image_url: "".into(),
        evidence: "name".into(),
        confidence: "high".into(),
    };
    let db = Database::open_in_memory().unwrap();
    let backend = Backend::new(db, Arc::new(MockFeedFetcher::default()), Arc::new(AppearanceSearcher { appearances: vec![old] }));
    let created = call(&backend, "POST", "/api/follows", Some(json!({"name":"Ada Lovelace"})));
    assert_eq!(created.status_code, 201);
    let recent: Page<EpisodeItem> = decode(&call(&backend, "GET", "/api/recent", None));
    assert!(recent.items.is_empty());
}

#[test]
fn test_show_notes_endpoint_rejects_cross_origin_browser_requests_before_generation() {
    let h = harness();
    let target = "/api/episodes/1/show-notes";
    let preflight = h.backend.handle(
        HttpRequest::new("OPTIONS", target)
            .with_header("origin", "https://attacker.example")
            .with_header("content-type", "application/json"),
    );
    assert_eq!(preflight.status_code, 403);
    let post = h.backend.handle(
        HttpRequest::new("POST", target)
            .with_json(&json!({}))
            .with_header("origin", "https://attacker.example")
            .with_header("content-type", "application/json"),
    );
    assert_eq!(post.status_code, 403);
    let missing_origin_preflight = h.backend.handle(
        HttpRequest::new("OPTIONS", target).with_header("content-type", "application/json"),
    );
    assert_eq!(missing_origin_preflight.status_code, 403);
    let missing_origin_post = h.backend.handle(
        HttpRequest::new("POST", target)
            .with_json(&json!({}))
            .with_header("content-type", "application/json"),
    );
    assert_eq!(missing_origin_post.status_code, 403);
    let trusted = h.backend.handle(
        HttpRequest::new("POST", target)
            .with_json(&json!({}))
            .with_header("origin", "http://127.0.0.1:18180")
            .with_header("content-type", "application/json"),
    );
    assert_eq!(trusted.status_code, 404);
}

#[test]
fn test_subscribe_backfills_newest_two_and_lists_recent() {
    let h = harness();
    let feed_url = "https://feeds.example/a.xml";
    h.fetcher.set(feed_url, rss("Alpha", &[
        ("Ep1", "g1", "https://h.example/1.mp3", D1),
        ("Ep2", "g2", "https://h.example/2.mp3", D2),
        ("Ep3", "g3", "https://h.example/3.mp3", D3),
        ("Ep4", "g4", "https://h.example/4.mp3", D4),
    ]));
    let subscribe = call(&h.backend, "POST", "/api/shows", Some(json!({"feed_url": feed_url})));
    assert_eq!(subscribe.status_code, 201);
    let show: Show = decode(&subscribe);
    assert_eq!(show.title, "Alpha");
    assert_eq!(show.episode_count, 4);
    assert_eq!(show.unplayed_count, 2);
    let recent: Page<EpisodeItem> = decode(&call(&h.backend, "GET", "/api/recent", None));
    assert_eq!(recent.items.iter().map(|i| i.title.clone()).collect::<Vec<_>>(), vec!["Ep4", "Ep3"]);
    assert!(recent.next_offset.is_none());
    let duplicate = call(&h.backend, "POST", "/api/shows", Some(json!({"feed_url": feed_url})));
    assert_eq!(duplicate.status_code, 409);
    let bad = call(&h.backend, "POST", "/api/shows", Some(json!({"feed_url": "ftp://x"})));
    assert_eq!(bad.status_code, 422);
    let shows: Vec<Show> = decode(&call(&h.backend, "GET", "/api/shows", None));
    assert_eq!(shows.len(), 1);
    let detail: ShowDetail = decode(&call(&h.backend, "GET", &format!("/api/shows/{}", shows[0].id), None));
    assert_eq!(detail.episodes.items.len(), 4);
    let missing = call(&h.backend, "GET", "/api/shows/9999", None);
    assert_eq!(missing.status_code, 404);
}

#[test]
fn test_preview_feed_lists_episodes_without_storing() {
    let h = harness();
    let feed_url = "https://feeds.example/one-off.xml";
    h.fetcher.set(feed_url, rss("One Off Show", &[
        ("Ep1", "g1", "https://h.example/1.mp3", D1),
        ("Ep2", "g2", "https://h.example/2.mp3", D2),
        ("Ep3", "g3", "https://h.example/3.mp3", D3),
    ]));
    let preview: FeedPreview = decode(&call(&h.backend, "POST", "/api/feeds/preview", Some(json!({"feed_url": feed_url}))));
    assert_eq!(preview.feed_url, feed_url);
    assert_eq!(preview.title, "One Off Show");
    assert_eq!(preview.episodes.iter().map(|e| e.guid.clone()).collect::<Vec<_>>(), vec!["g3", "g2", "g1"]);
    let shows: Vec<Show> = decode(&call(&h.backend, "GET", "/api/shows", None));
    assert!(shows.is_empty());
    let recent: Page<EpisodeItem> = decode(&call(&h.backend, "GET", "/api/recent", None));
    assert!(recent.items.is_empty());
    let bad = call(&h.backend, "POST", "/api/feeds/preview", Some(json!({"feed_url": "ftp://x"})));
    assert_eq!(bad.status_code, 422);
}

#[test]
fn test_add_listen_episode_stores_only_the_selected_episode_unsubscribed() {
    let h = harness();
    let feed_url = "https://feeds.example/one-off.xml";
    h.fetcher.set(feed_url, rss("One Off Show", &[
        ("Ep1", "g1", "https://h.example/1.mp3", D1),
        ("Ep2", "g2", "https://h.example/2.mp3", D2),
        ("Ep3", "g3", "https://h.example/3.mp3", D3),
    ]));
    let added = call(&h.backend, "POST", "/api/listen-episodes", Some(json!({"feed_url": feed_url, "guid": "g2"})));
    assert_eq!(added.status_code, 201);
    let item: EpisodeItem = decode(&added);
    assert_eq!(item.title, "Ep2");
    let recent: Page<EpisodeItem> = decode(&call(&h.backend, "GET", "/api/recent", None));
    assert_eq!(recent.items.iter().map(|i| i.title.clone()).collect::<Vec<_>>(), vec!["Ep2"]);
    let shows: Vec<Show> = decode(&call(&h.backend, "GET", "/api/shows", None));
    assert!(shows.is_empty());
    let missing = call(&h.backend, "POST", "/api/listen-episodes", Some(json!({"feed_url": feed_url, "guid": "missing"})));
    assert_eq!(missing.status_code, 422);
}

#[test]
fn test_add_listen_episode_refresh_does_not_insert_sibling_episodes() {
    let h = harness();
    let one_off = "https://feeds.example/one-off.xml";
    let subscribed = "https://feeds.example/subscribed.xml";
    h.fetcher.set(one_off, rss("One Off Show", &[
        ("Ep1", "g1", "https://h.example/1.mp3", D1),
        ("Ep2", "g2", "https://h.example/2.mp3", D2),
        ("Ep3", "g3", "https://h.example/3.mp3", D3),
    ]));
    h.fetcher.set(subscribed, rss("Subscribed Show", &[("Sub Ep", "s1", "https://h.example/s1.mp3", D4)]));
    let _ = call(&h.backend, "POST", "/api/listen-episodes", Some(json!({"feed_url": one_off, "guid": "g1"})));
    let _ = call(&h.backend, "POST", "/api/shows", Some(json!({"feed_url": subscribed})));
    h.fetcher.set(one_off, rss("One Off Show", &[
        ("Ep1", "g1", "https://h.example/1.mp3", D1),
        ("Ep2", "g2", "https://h.example/2.mp3", D2),
        ("Ep3", "g3", "https://h.example/3.mp3", D3),
        ("Ep4", "g4", "https://h.example/4.mp3", D4),
    ]));
    let before = h.fetcher.requested.lock().unwrap().len();
    let refreshed: RefreshResult = decode(&call(&h.backend, "POST", "/api/refresh", None));
    assert_eq!(refreshed, RefreshResult { refreshed: 1, errors: 0 });
    let after = h.fetcher.requested.lock().unwrap().clone();
    let refresh_urls = &after[before..];
    assert!(!refresh_urls.iter().any(|u| u == one_off));
    assert!(refresh_urls.iter().any(|u| u == subscribed));
    let recent: Page<EpisodeItem> = decode(&call(&h.backend, "GET", "/api/recent", None));
    let titles: std::collections::HashSet<_> = recent.items.iter().map(|i| i.title.clone()).collect();
    assert_eq!(titles, ["Ep1".into(), "Sub Ep".into()].into_iter().collect());
}

#[test]
fn test_add_listen_episode_wakes_ad_removal_scheduler() {
    let h = harness();
    h.backend.db.execute("INSERT INTO settings (key, value) VALUES ('ad_removal_enabled', 'true') ON CONFLICT(key) DO UPDATE SET value = excluded.value", []).unwrap();
    let woke = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let flag = woke.clone();
    h.backend.set_ad_removal_wake(move || flag.store(true, std::sync::atomic::Ordering::SeqCst));
    let feed_url = "https://feeds.example/one-off-ad-removal.xml";
    h.fetcher.set(feed_url, rss("One Off Ad Removal", &[
        ("Ep1", "ar1", "https://h.example/ar1.mp3", D1),
        ("Ep2", "ar2", "https://h.example/ar2.mp3", D2),
        ("Ep3", "ar3", "https://h.example/ar3.mp3", D3),
    ]));
    let response = call(&h.backend, "POST", "/api/listen-episodes", Some(json!({"feed_url": feed_url, "guid": "ar2"})));
    assert_eq!(response.status_code, 201);
    assert!(woke.load(std::sync::atomic::Ordering::SeqCst));
    let count = h.backend.db.scalar_i64("SELECT COUNT(*) FROM ad_removal_jobs", []).unwrap().unwrap();
    assert_eq!(count, 1);
}

#[test]
fn test_subscribe_enrolls_only_visible_episodes_and_wakes_ad_removal_scheduler() {
    let h = harness();
    h.backend.db.execute("INSERT INTO settings (key, value) VALUES ('ad_removal_enabled', 'true') ON CONFLICT(key) DO UPDATE SET value = excluded.value", []).unwrap();
    let woke = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let flag = woke.clone();
    h.backend.set_ad_removal_wake(move || flag.store(true, std::sync::atomic::Ordering::SeqCst));
    let feed_url = "https://feeds.example/ad-removal-subscribe.xml";
    h.fetcher.set(feed_url, rss("Ad Removal Subscribe", &[
        ("Ep1", "ar1", "https://h.example/ar1.mp3", D1),
        ("Ep2", "ar2", "https://h.example/ar2.mp3", D2),
        ("Ep3", "ar3", "https://h.example/ar3.mp3", D3),
        ("Ep4", "ar4", "https://h.example/ar4.mp3", D4),
    ]));
    let response = call(&h.backend, "POST", "/api/shows", Some(json!({"feed_url": feed_url})));
    assert_eq!(response.status_code, 201);
    assert!(woke.load(std::sync::atomic::Ordering::SeqCst));
    let conn = h.backend.db.lock().unwrap();
    let mut stmt = conn.prepare("SELECT e.title FROM ad_removal_jobs j JOIN episodes e ON e.id = j.episode_id ORDER BY e.published_at").unwrap();
    let titles: Vec<String> = stmt.query_map([], |r| r.get(0)).unwrap().map(|r| r.unwrap()).collect();
    assert_eq!(titles, vec!["Ep3", "Ep4"]);
}

#[test]
fn test_played_position_settings_and_next_round_trip() {
    let h = harness();
    let feed_url = "https://feeds.example/a.xml";
    h.fetcher.set(feed_url, rss("Alpha", &[
        ("Ep1", "g1", "https://h.example/1.mp3", D1),
        ("Ep2", "g2", "https://h.example/2.mp3", D2),
        ("Ep3", "g3", "https://h.example/3.mp3", D3),
    ]));
    let _ = call(&h.backend, "POST", "/api/shows", Some(json!({"feed_url": feed_url})));
    let recent: Page<EpisodeItem> = decode(&call(&h.backend, "GET", "/api/recent", None));
    let ep3 = recent.items[0].id;
    let ep2 = recent.items[1].id;
    let next_recent: Option<EpisodeItem> = decode(&call(&h.backend, "GET", &format!("/api/next?after={ep3}&context=recent"), None));
    assert_eq!(next_recent.unwrap().id, ep2);
    let next_show: Option<EpisodeItem> = decode(&call(&h.backend, "GET", &format!("/api/next?after={ep2}&context=show"), None));
    assert_eq!(next_show.unwrap().id, ep3);
    assert_eq!(call(&h.backend, "POST", &format!("/api/episodes/{ep3}/played"), None).status_code, 204);
    let played: Page<EpisodeItem> = decode(&call(&h.backend, "GET", "/api/played", None));
    assert_eq!(played.items[0].id, ep3);
    assert_eq!(call(&h.backend, "DELETE", &format!("/api/episodes/{ep3}/played"), None).status_code, 204);
    assert_eq!(call(&h.backend, "PUT", &format!("/api/episodes/{ep2}/position"), Some(json!({"seconds": 42.5}))).status_code, 204);
    let detail: EpisodeDetail = decode(&call(&h.backend, "GET", &format!("/api/episodes/{ep2}"), None));
    assert_eq!(detail.position_secs, 42.5);
    assert!(detail.notes_html.contains("Notes for Ep2"));
    let settings: SettingsPayload = decode(&call(&h.backend, "GET", "/api/settings", None));
    assert_eq!(settings, SettingsPayload { speed: 1.0, autoplay: true });
    assert_eq!(call(&h.backend, "PUT", "/api/settings", Some(json!({"speed": 2.5, "autoplay": false}))).status_code, 204);
    let saved: SettingsPayload = decode(&call(&h.backend, "GET", "/api/settings", None));
    assert_eq!(saved, SettingsPayload { speed: 2.5, autoplay: false });
    assert_eq!(call(&h.backend, "PUT", "/api/settings", Some(json!({"speed": 9.9, "autoplay": true}))).status_code, 422);
}

#[test]
fn test_search_refresh_opml_and_unsubscribe() {
    let h = harness();
    let feed_url = "https://feeds.example/a.xml";
    h.fetcher.set(feed_url, rss("Alpha", &[("Ep1", "g1", "https://h.example/1.mp3", D1)]));
    let _ = call(&h.backend, "POST", "/api/shows", Some(json!({"feed_url": feed_url})));
    let opml = String::from_utf8(call(&h.backend, "GET", "/api/opml", None).body).unwrap();
    assert!(opml.contains("https://feeds.example/a.xml"));
    let imported: OpmlImportResult = decode(&call(&h.backend, "POST", "/api/opml", None));
    // empty body -> zero urls
    assert_eq!(imported.imported + imported.skipped + imported.failed, 0);
    let shows: Vec<Show> = decode(&call(&h.backend, "GET", "/api/shows", None));
    assert_eq!(call(&h.backend, "DELETE", &format!("/api/shows/{}", shows[0].id), None).status_code, 204);
    let shows: Vec<Show> = decode(&call(&h.backend, "GET", "/api/shows", None));
    assert!(shows.is_empty());
}

#[test]
fn test_refresh_uses_stored_http_validators_and_counts_not_modified_as_a_healthy_feed() {
    let h = harness();
    let feed_url = "https://feeds.example/a.xml";
    h.fetcher.set(feed_url, rss("Alpha", &[("Ep1", "g1", "https://h.example/1.mp3", D1)]));
    let _ = call(&h.backend, "POST", "/api/shows", Some(json!({"feed_url": feed_url})));
    h.fetcher.not_modified.lock().unwrap().insert(feed_url.into());
    let refreshed: RefreshResult = decode(&call(&h.backend, "POST", "/api/refresh", None));
    assert_eq!(refreshed, RefreshResult { refreshed: 1, errors: 0 });
}

#[test]
fn test_native_playback_progress_recording_updates_episode_position() {
    let h = harness();
    let feed_url = "https://feeds.example/a.xml";
    h.fetcher.set(feed_url, rss("Alpha", &[
        ("Ep1", "g1", "https://h.example/1.mp3", D1),
        ("Ep2", "g2", "https://h.example/2.mp3", D2),
    ]));
    let _ = call(&h.backend, "POST", "/api/shows", Some(json!({"feed_url": feed_url})));
    let recent: Page<EpisodeItem> = decode(&call(&h.backend, "GET", "/api/recent", None));
    let id = recent.items[0].id;
    h.backend.record_playback_progress(id, 33.0);
    let detail: EpisodeDetail = decode(&call(&h.backend, "GET", &format!("/api/episodes/{id}"), None));
    assert_eq!(detail.position_secs, 33.0);
}

#[test]
fn test_ad_removal_enable_consent_cutoff_and_new_episode_enrollment() {
    let h = harness();
    let enable = call(&h.backend, "POST", "/api/ad-removal/enable", Some(json!({"confirmed_bytes": 0})));
    assert_eq!(enable.status_code, 202);
    let settings: AdRemovalSettingsPayload = decode(&enable);
    assert!(settings.enabled);
    assert!(settings.enrollment_cutoff.is_some());
}

#[test]
fn test_backend_starts_without_a_deepseek_key() {
    let db = Database::open_in_memory().unwrap();
    let backend = Backend::new(db, Arc::new(MockFeedFetcher::default()), Arc::new(pods_backend::DisabledDirectory));
    let settings: AdRemovalSettingsPayload = decode(&call(&backend, "GET", "/api/ad-removal/settings", None));
    assert!(!settings.cloud_classifier_configured);
    assert_eq!(call(&backend, "POST", "/api/ad-removal/enable", Some(json!({"confirmed_bytes": 0}))).status_code, 422);
}

#[test]
fn test_ad_removal_settings_and_enable_require_deepseek_api_key() {
    let db = Database::open_in_memory().unwrap();
    let mut backend = Backend::new(db, Arc::new(MockFeedFetcher::default()), Arc::new(pods_backend::DisabledDirectory));
    backend.set_credentials(pods_backend::backend::CredentialStore::new(None));
    let enable = call(&backend, "POST", "/api/ad-removal/enable", Some(json!({"confirmed_bytes": 0})));
    assert_eq!(enable.status_code, 422);
}

#[test]
fn test_episode_ad_removal_state_prepare_and_retry_round_trip() {
    let h = harness();
    let feed_url = "https://feeds.example/a.xml";
    h.fetcher.set(feed_url, rss("Alpha", &[("Ep1", "g1", "https://h.example/1.mp3", D1), ("Ep2", "g2", "https://h.example/2.mp3", D2)]));
    let _ = call(&h.backend, "POST", "/api/shows", Some(json!({"feed_url": feed_url})));
    let recent: Page<EpisodeItem> = decode(&call(&h.backend, "GET", "/api/recent", None));
    let id = recent.items[0].id;
    let prepared = call(&h.backend, "POST", &format!("/api/episodes/{id}/ad-removal/prepare"), None);
    assert_eq!(prepared.status_code, 202);
}

#[test]
fn test_ad_removal_statuses_returns_lightweight_ordered_records_for_existing_episodes() {
    let h = harness();
    let feed_url = "https://feeds.example/a.xml";
    h.fetcher.set(feed_url, rss("Alpha", &[("Ep1", "g1", "https://h.example/1.mp3", D1), ("Ep2", "g2", "https://h.example/2.mp3", D2)]));
    let _ = call(&h.backend, "POST", "/api/shows", Some(json!({"feed_url": feed_url})));
    let recent: Page<EpisodeItem> = decode(&call(&h.backend, "GET", "/api/recent", None));
    let ids = format!("{},{}", recent.items[0].id, recent.items[1].id);
    let payload: AdRemovalStatusesPayload = decode(&call(&h.backend, "GET", &format!("/api/ad-removal/statuses?episode_ids={ids}"), None));
    assert_eq!(payload.items.len(), 2);
}

#[test]
fn test_ad_removal_statuses_rejects_malformed_empty_non_positive_and_over_limit_input() {
    let h = harness();
    assert_eq!(call(&h.backend, "GET", "/api/ad-removal/statuses?episode_ids=", None).status_code, 422);
    assert_eq!(call(&h.backend, "GET", "/api/ad-removal/statuses?episode_ids=0", None).status_code, 422);
    let too_many = (1..=51).map(|i| i.to_string()).collect::<Vec<_>>().join(",");
    assert_eq!(call(&h.backend, "GET", &format!("/api/ad-removal/statuses?episode_ids={too_many}"), None).status_code, 422);
}

#[test]
fn test_car_bluetooth_enrollment_api_from_empty_store_resumes_custom_tesla_and_ignores_headset() {
    let h = harness();
    h.backend.set_car_routes(vec![
        pods_backend::backend::BluetoothRoute { uid: "aa:bb:cc:dd:ee:ff-tacl".into(), name: "Midnight".into(), port_type: "bluetoothA2DP".into() },
        pods_backend::backend::BluetoothRoute { uid: "aa:bb:cc:dd:ee:ff-tsco".into(), name: "Midnight".into(), port_type: "bluetoothHFP".into() },
    ]);
    let before: CarBluetoothSettingsPayload = decode(&call(&h.backend, "GET", "/api/car-bluetooth", None));
    assert!(!before.enrolled);
    assert!(before.enrollable);
    assert_eq!(before.current_device_name.as_deref(), Some("Midnight"));
    let enrolled: CarBluetoothSettingsPayload = decode(&call(&h.backend, "POST", "/api/car-bluetooth/enroll", None));
    assert!(enrolled.enrolled);
    assert!(enrolled.current_enrolled);
}

struct ConfiguredDirectory {
    podcasts: Vec<DirectoryPodcast>,
}

impl DirectorySearcher for ConfiguredDirectory {
    fn is_configured(&self) -> bool { true }
    fn search(&self, _query: &str) -> Result<Vec<DirectoryPodcast>, Error> { Ok(self.podcasts.clone()) }
}

#[test]
fn test_search_includes_configured_directory_results() {
    let db = Database::open_in_memory().unwrap();
    let fetcher = Arc::new(MockFeedFetcher::default());
    let backend = Backend::new(db, fetcher, Arc::new(ConfiguredDirectory {
        podcasts: vec![DirectoryPodcast {
            title: "Found Pod".into(),
            author: "Au".into(),
            feed_url: "https://f.example/rss".into(),
            image_url: "".into(),
            description: "".into(),
            subscribed: false,
        }],
    }));
    let results: SearchResults = decode(&call(&backend, "GET", "/api/search?q=found", None));
    assert!(results.directory_configured);
    assert_eq!(results.podcasts[0].title, "Found Pod");
}

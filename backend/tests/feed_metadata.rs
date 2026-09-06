use pods_backend::feeds::parse_feed;
use pods_backend::{Backend, Database, DisabledDirectory, HttpRequest, MockFeedFetcher};
use std::sync::Arc;

#[test]
fn rss_metadata_uses_channel_scope_and_decodes_xml_without_cdata_markup() {
    let feed = parse_feed(br#"<rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>
      <title><![CDATA[A & B <not-a-tag>]]></title><description>About &#x1F3A7; &amp; audio</description>
      <link>https://example.org/?a=1&amp;b=2</link><itunes:image href="https://example.org/show.jpg?a=1&amp;b=2"/>
      <item><title><![CDATA[Episode & one]]></title><guid>x</guid>
      <description><![CDATA[<p>Keep HTML & entities</p>]]></description>
      <enclosure url="https://example.org/audio.mp3?a=1&amp;b=2"/>
      <itunes:image href="https://example.org/episode.jpg"/><itunes:duration>01:02:03</itunes:duration></item>
    </channel></rss>"#).unwrap();
    assert_eq!(feed.title, "A & B <not-a-tag>");
    assert_eq!(feed.description, "About 🎧 & audio");
    assert_eq!(feed.site_url, "https://example.org/?a=1&b=2");
    assert_eq!(feed.image_url, "https://example.org/show.jpg?a=1&b=2");
    assert_eq!(feed.episodes[0].title, "Episode & one");
    assert_eq!(feed.episodes[0].notes_html, "<p>Keep HTML & entities</p>");
    assert_eq!(
        feed.episodes[0].image_url,
        "https://example.org/episode.jpg"
    );
    assert_eq!(feed.episodes[0].duration_secs, Some(3723));
    assert_eq!(
        feed.episodes[0].audio_url,
        "https://example.org/audio.mp3?a=1&b=2"
    );
}

#[test]
fn channel_metadata_after_items_and_rss_image_fallback_work() {
    let feed = parse_feed(
        br#"<rss><channel><item><title>Episode</title><enclosure url="https://example.org/a"/>
      <image><url>https://example.org/episode.jpg</url></image></item>
      <title>Show</title><image><url>https://example.org/show.jpg</url><title>Art</title></image>
    </channel></rss>"#,
    )
    .unwrap();
    assert_eq!(feed.title, "Show");
    assert_eq!(feed.image_url, "https://example.org/show.jpg");
    let missing = parse_feed(br#"<rss><channel><item><title>Not the show title</title><enclosure url="x"/></item></channel></rss>"#).unwrap();
    assert!(missing.title.is_empty());
    assert!(missing.image_url.is_empty());
}

#[test]
fn invalid_or_non_feed_documents_are_rejected_instead_of_erasing_metadata() {
    for xml in ["<html><title>Error</title></html>", "<rss><channel>",
        "<!DOCTYPE rss [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]><rss><channel><title>&secret;</title></channel></rss>"] {
        assert!(parse_feed(xml.as_bytes()).is_err());
    }
}

#[test]
fn refresh_preserves_known_metadata_when_fields_are_absent() {
    let fetcher = Arc::new(MockFeedFetcher::default());
    fetcher.set(
        "https://example.org/feed",
        "<rss><channel><title>Updated title</title></channel></rss>",
    );
    let backend = Backend::new(
        Database::open_in_memory().unwrap(),
        fetcher,
        Arc::new(DisabledDirectory),
    );
    backend.db.execute("INSERT INTO podcasts(id,feed_url,title,description,image_url,site_url,created_at) VALUES(1,'https://example.org/feed','Old title','Known description','https://example.org/art.jpg','https://example.org',0)", []).unwrap();
    assert_eq!(
        backend
            .handle(HttpRequest::new("POST", "/api/refresh"))
            .status_code,
        200
    );
    let response = backend.handle(HttpRequest::new("GET", "/api/shows"));
    let shows: serde_json::Value = serde_json::from_slice(&response.body).unwrap();
    assert_eq!(shows[0]["title"], "Updated title");
    assert_eq!(shows[0]["description"], "Known description");
    assert_eq!(shows[0]["image_url"], "https://example.org/art.jpg");
    assert_eq!(shows[0]["site_url"], "https://example.org");
}

#[test]
fn repaired_guid_reuses_old_episode_id_and_listening_history() {
    let fetcher = Arc::new(MockFeedFetcher::default());
    fetcher.set("https://example.org/feed", "<rss><channel><item><title>Repaired</title><guid><![CDATA[episode-key]]></guid><enclosure url='https://example.org/audio'/></item></channel></rss>");
    let backend = Backend::new(
        Database::open_in_memory().unwrap(),
        fetcher,
        Arc::new(DisabledDirectory),
    );
    backend.db.execute("INSERT INTO podcasts(id,feed_url,title,created_at) VALUES(1,'https://example.org/feed','Title',0)", []).unwrap();
    backend.db.execute("INSERT INTO episodes(id,podcast_id,guid,title,audio_url) VALUES(42,1,'<![CDATA[episode-key]]>','Old title','https://example.org/audio')", []).unwrap();
    backend.db.execute("INSERT INTO episode_state(episode_id,played_at,position_secs,updated_at) VALUES(42,123,45,123)", []).unwrap();
    assert_eq!(
        backend
            .handle(HttpRequest::new("POST", "/api/refresh"))
            .status_code,
        200
    );
    assert_eq!(
        backend
            .db
            .scalar_i64("SELECT count(*) FROM episodes", [])
            .unwrap(),
        Some(1)
    );
    assert_eq!(
        backend
            .db
            .scalar_string("SELECT guid FROM episodes WHERE id=42", [])
            .unwrap()
            .as_deref(),
        Some("episode-key")
    );
    assert_eq!(
        backend
            .db
            .scalar_i64(
                "SELECT played_at FROM episode_state WHERE episode_id=42",
                []
            )
            .unwrap(),
        Some(123)
    );
    assert_eq!(
        backend
            .db
            .scalar_i64(
                "SELECT CAST(position_secs AS INTEGER) FROM episode_state WHERE episode_id=42",
                []
            )
            .unwrap(),
        Some(45)
    );
}

#[test]
fn browser_catalog_suppresses_only_untouched_cdata_duplicates_without_deleting_data() {
    let backend = Backend::new(
        Database::open_in_memory().unwrap(),
        Arc::new(MockFeedFetcher::default()),
        Arc::new(DisabledDirectory),
    );
    backend.db.execute("INSERT INTO podcasts(id,feed_url,title,created_at) VALUES(1,'https://example.org/feed','Title',0)", []).unwrap();
    backend.db.execute("INSERT INTO episodes(id,podcast_id,guid,title,audio_url) VALUES(1,1,'key','Title','audio'),(2,1,'<![CDATA[key]]>','Duplicate','audio')", []).unwrap();
    backend
        .db
        .execute(
            "INSERT INTO episode_state(episode_id,played_at,updated_at) VALUES(1,123,123)",
            [],
        )
        .unwrap();
    backend
        .db
        .execute("INSERT INTO browser_jobs(episode_id) VALUES(2)", [])
        .unwrap();
    assert_eq!(
        backend
            .db
            .scalar_i64("SELECT count(*) FROM browser_episode_catalog", [])
            .unwrap(),
        Some(1)
    );
    assert_eq!(
        backend
            .db
            .scalar_i64("SELECT count(*) FROM browser_pending_jobs", [])
            .unwrap(),
        Some(0)
    );
    assert_eq!(
        backend
            .db
            .scalar_i64("SELECT count(*) FROM episodes", [])
            .unwrap(),
        Some(2)
    );
    // An explicit user edit on the duplicate must remain visible for reconciliation.
    backend
        .db
        .execute(
            "INSERT INTO episode_state(episode_id,position_secs,updated_at) VALUES(2,8,123)",
            [],
        )
        .unwrap();
    assert_eq!(
        backend
            .db
            .scalar_i64("SELECT count(*) FROM browser_episode_catalog", [])
            .unwrap(),
        Some(2)
    );
    assert_eq!(
        backend
            .db
            .scalar_i64("SELECT count(*) FROM browser_pending_jobs", [])
            .unwrap(),
        Some(1)
    );
}

#[test]
fn opening_existing_database_replaces_stale_browser_episode_catalog_and_keeps_rows() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("library.sqlite");
    {
        let db = Database::open(&path).unwrap();
        db.lock()
            .unwrap()
            .execute_batch(
                "DROP VIEW IF EXISTS browser_pending_jobs;
                 DROP VIEW IF EXISTS browser_episode_catalog;
                 CREATE VIEW browser_episode_catalog AS SELECT * FROM episodes;
                 CREATE VIEW browser_pending_jobs AS SELECT * FROM browser_jobs;",
            )
            .unwrap();
        db.execute("INSERT INTO podcasts(id,feed_url,title,created_at,is_subscribed) VALUES(1,'https://example.org/feed','Title',0,1)", []).unwrap();
        db.execute("INSERT INTO episodes(id,podcast_id,guid,title,audio_url) VALUES(1,1,'key','Canonical','audio'),(2,1,'<![CDATA[key]]>','Duplicate','audio'),(3,1,'other','Published','audio'),(4,1,'<![CDATA[other]]>','Touched duplicate','audio')", []).unwrap();
        db.execute("INSERT INTO episode_state(episode_id,played_at,position_secs,updated_at) VALUES(1,123,45,123)", []).unwrap();
        db.execute(
            "INSERT INTO episode_state(episode_id,position_secs,updated_at) VALUES(4,8,123)",
            [],
        )
        .unwrap();
        db.execute("INSERT INTO listen_episodes(episode_id) VALUES(3)", [])
            .unwrap();
        db.execute("INSERT INTO browser_jobs(episode_id) VALUES(2),(3)", [])
            .unwrap();
        db.execute("INSERT INTO browser_publications(episode_id,manifest_json,published_at) VALUES(3,'{}',1)", []).unwrap();
        db.execute("INSERT INTO browser_operations(operation_id,client_id,sequence,payload,result) VALUES('op1','client',1,'{}','ok')", []).unwrap();
        db.execute("UPDATE browser_clock SET revision=7 WHERE id=1", [])
            .unwrap();
        assert_eq!(
            db.scalar_i64("SELECT count(*) FROM browser_episode_catalog", [])
                .unwrap(),
            Some(4)
        );
        assert_eq!(
            db.scalar_i64("SELECT count(*) FROM browser_pending_jobs", [])
                .unwrap(),
            Some(2)
        );
    }

    let db = Database::open(&path).unwrap();
    assert_catalog_upgrade_preserved(&db);
    drop(db);
    let db = Database::open(&path).unwrap();
    assert_catalog_upgrade_preserved(&db);
}

fn assert_catalog_upgrade_preserved(db: &Database) {
    assert_eq!(
        db.scalar_string(
            "SELECT group_concat(id) FROM (SELECT id FROM browser_episode_catalog ORDER BY id)",
            [],
        )
        .unwrap()
        .as_deref(),
        Some("1,3,4")
    );
    assert_eq!(
        db.scalar_i64("SELECT count(*) FROM browser_pending_jobs", [])
            .unwrap(),
        Some(1)
    );
    assert_eq!(
        db.scalar_i64("SELECT episode_id FROM browser_pending_jobs", [])
            .unwrap(),
        Some(3)
    );
    assert_eq!(
        db.scalar_i64("SELECT count(*) FROM episodes", []).unwrap(),
        Some(4)
    );
    assert_eq!(
        db.scalar_string("SELECT guid FROM episodes WHERE id=2", [])
            .unwrap()
            .as_deref(),
        Some("<![CDATA[key]]>")
    );
    assert_eq!(
        db.scalar_i64("SELECT played_at FROM episode_state WHERE episode_id=1", [])
            .unwrap(),
        Some(123)
    );
    assert_eq!(
        db.scalar_i64(
            "SELECT CAST(position_secs AS INTEGER) FROM episode_state WHERE episode_id=4",
            [],
        )
        .unwrap(),
        Some(8)
    );
    assert_eq!(
        db.scalar_i64("SELECT count(*) FROM listen_episodes", [])
            .unwrap(),
        Some(1)
    );
    assert_eq!(
        db.scalar_i64("SELECT is_subscribed FROM podcasts WHERE id=1", [])
            .unwrap(),
        Some(1)
    );
    assert_eq!(
        db.scalar_string(
            "SELECT group_concat(episode_id) FROM (SELECT episode_id FROM browser_jobs ORDER BY episode_id)",
            [],
        )
        .unwrap()
        .as_deref(),
        Some("2,3")
    );
    assert_eq!(
        db.scalar_i64(
            "SELECT published_at FROM browser_publications WHERE episode_id=3",
            []
        )
        .unwrap(),
        Some(1)
    );
    assert_eq!(
        db.scalar_string(
            "SELECT result FROM browser_operations WHERE operation_id='op1'",
            []
        )
        .unwrap()
        .as_deref(),
        Some("ok")
    );
    assert_eq!(
        db.scalar_i64("SELECT revision FROM browser_clock WHERE id=1", [])
            .unwrap(),
        Some(7)
    );
}

#[test]
fn old_parser_cache_is_bypassed_once_then_validators_are_reused() {
    use pods_backend::feeds::{FeedFetchResponse, FeedFetcher, FeedValidators};
    use std::sync::Mutex;
    #[derive(Default)]
    struct Recorder(Mutex<Vec<FeedValidators>>);
    impl FeedFetcher for Recorder {
        fn fetch(
            &self,
            _: &str,
            validators: &FeedValidators,
        ) -> Result<FeedFetchResponse, pods_backend::error::Error> {
            self.0.lock().unwrap().push(validators.clone());
            Ok(FeedFetchResponse::Data(
                b"<rss><channel><title><![CDATA[Repaired & title]]></title></channel></rss>"
                    .to_vec(),
                FeedValidators {
                    etag: Some("new".into()),
                    last_modified: None,
                },
            ))
        }
    }
    let fetcher = Arc::new(Recorder::default());
    let backend = Backend::new(
        Database::open_in_memory().unwrap(),
        fetcher.clone(),
        Arc::new(DisabledDirectory),
    );
    backend.db.execute("INSERT INTO podcasts(id,feed_url,title,created_at) VALUES(1,'https://example.org/feed','Broken title',0)", []).unwrap();
    backend
        .db
        .execute(
            "INSERT INTO feed_http_cache(podcast_id,etag) VALUES(1,'old')",
            [],
        )
        .unwrap();
    for _ in 0..2 {
        assert_eq!(
            backend
                .handle(HttpRequest::new("POST", "/api/refresh"))
                .status_code,
            200
        );
    }
    let calls = fetcher.0.lock().unwrap();
    assert_eq!(calls[0], FeedValidators::default());
    assert_eq!(calls[1].etag.as_deref(), Some("new"));
    assert_eq!(
        backend
            .db
            .scalar_string("SELECT title FROM podcasts WHERE id=1", [])
            .unwrap()
            .as_deref(),
        Some("Repaired & title")
    );
}

#[test]
fn failed_metadata_transaction_is_reported_and_does_not_mark_parser_current() {
    let fetcher = Arc::new(MockFeedFetcher::default());
    fetcher.set(
        "https://example.org/feed",
        "<rss><channel><title>New title</title></channel></rss>",
    );
    let backend = Backend::new(
        Database::open_in_memory().unwrap(),
        fetcher,
        Arc::new(DisabledDirectory),
    );
    backend.db.execute("INSERT INTO podcasts(id,feed_url,title,created_at) VALUES(1,'https://example.org/feed','Keep title',0)", []).unwrap();
    backend.db.execute("CREATE TRIGGER reject_metadata BEFORE UPDATE ON podcasts BEGIN SELECT RAISE(ABORT,'test failure'); END", []).unwrap();
    let response = backend.handle(HttpRequest::new("POST", "/api/refresh"));
    let value: serde_json::Value = serde_json::from_slice(&response.body).unwrap();
    assert_eq!(value["errors"], 1);
    assert_eq!(value["refreshed"], 0);
    assert_eq!(
        backend
            .db
            .scalar_string("SELECT title FROM podcasts WHERE id=1", [])
            .unwrap()
            .as_deref(),
        Some("Keep title")
    );
    assert_eq!(
        backend
            .db
            .scalar_i64("SELECT COUNT(*) FROM feed_parser_state", [])
            .unwrap(),
        Some(0)
    );
}

/// Read-only acceptance against the operator's subscribed feeds. No library writes.
#[test]
#[ignore = "requires PODS_FEED_INVENTORY_DB and network access to subscribed feeds"]
fn subscribed_live_feeds_parse_with_titles_and_artwork() {
    use pods_backend::feeds::{FeedFetchResponse, FeedFetcher, FeedValidators, UreqFetcher};
    let conn = rusqlite::Connection::open_with_flags(
        std::env::var("PODS_FEED_INVENTORY_DB").unwrap(),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .unwrap();
    let mut statement = conn
        .prepare("SELECT id,feed_url FROM podcasts WHERE is_subscribed=1 ORDER BY id")
        .unwrap();
    let feeds: Vec<(i64, String)> = statement
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    assert!(!feeds.is_empty());
    let mut failures = Vec::new();
    for (id, url) in &feeds {
        let result = UreqFetcher::default()
            .fetch(url, &FeedValidators::default())
            .and_then(|response| match response {
                FeedFetchResponse::Data(data, _) => parse_feed(&data),
                _ => panic!("Unexpected unconditional 304 for feed {id}"),
            });
        match result {
            Ok(feed) => {
                println!(
                    "feed {id}: title={} artwork={} episodes={}",
                    !feed.title.is_empty(),
                    !feed.image_url.is_empty(),
                    feed.episodes.len()
                );
                if feed.title.is_empty()
                    || feed.title.contains("<![CDATA[")
                    || feed.image_url.is_empty()
                {
                    failures.push(*id);
                }
            }
            Err(_) => {
                println!("feed {id}: fetch/parse failed");
                failures.push(*id);
            }
        }
    }
    assert!(
        failures.is_empty(),
        "{} feeds checked; failures: {failures:?}",
        feeds.len()
    );
}

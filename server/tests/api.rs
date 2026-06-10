use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::Router;
use serde_json::{json, Value};
use tower::ServiceExt;
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

const TOKEN: &str = "testtoken";

async fn app_with(pi_base: String, pi_key: &str) -> (Router, tempfile::TempDir) {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("t.sqlite");
    let pool = pods_server::db::init(db_path.to_str().unwrap()).await.unwrap();
    let cfg = pods_server::Config {
        api_token: TOKEN.into(),
        pi_key: pi_key.into(),
        pi_secret: if pi_key.is_empty() { String::new() } else { "s".into() },
        pi_base,
        db_path: db_path.to_str().unwrap().into(),
        bind_addr: String::new(),
    };
    let state = pods_server::build_state(pool, cfg);
    (pods_server::api::router(state), dir)
}

async fn app() -> (Router, tempfile::TempDir) {
    app_with("http://127.0.0.1:1".into(), "").await
}

async fn call(
    app: &Router,
    method: &str,
    uri: &str,
    token: Option<&str>,
    body: Option<Value>,
) -> (StatusCode, Value) {
    let mut b = Request::builder().method(method).uri(uri);
    if let Some(t) = token {
        b = b.header("authorization", format!("Bearer {t}"));
    }
    let req = match body {
        Some(v) => b
            .header("content-type", "application/json")
            .body(Body::from(v.to_string()))
            .unwrap(),
        None => b.body(Body::empty()).unwrap(),
    };
    let res = app.clone().oneshot(req).await.unwrap();
    let status = res.status();
    let bytes = axum::body::to_bytes(res.into_body(), 10_000_000).await.unwrap();
    let json = if bytes.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&bytes)
            .unwrap_or_else(|_| Value::String(String::from_utf8_lossy(&bytes).into_owned()))
    };
    (status, json)
}

async fn get(app: &Router, uri: &str) -> (StatusCode, Value) {
    call(app, "GET", uri, Some(TOKEN), None).await
}

fn rss(show: &str, items: &[(&str, &str, &str, &str)]) -> String {
    let mut body = format!(
        "<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>{show}</title><description>About {show}</description>"
    );
    for (title, guid, url, date) in items {
        body.push_str(&format!(
            "<item><title>{title}</title><guid>{guid}</guid><pubDate>{date}</pubDate>\
             <description>&lt;p&gt;Notes for {title}&lt;/p&gt;</description>\
             <enclosure url=\"{url}\" type=\"audio/mpeg\" length=\"123\"/></item>"
        ));
    }
    body.push_str("</channel></rss>");
    body
}

async fn mount_feed(server: &MockServer, feed_path: &str, rss_body: &str) {
    Mock::given(method("GET"))
        .and(path(feed_path.to_string()))
        .respond_with(ResponseTemplate::new(200).set_body_raw(rss_body.to_owned(), "application/rss+xml"))
        .mount(server)
        .await;
}

const D1: &str = "Mon, 06 Jan 2025 00:00:00 GMT";
const D2: &str = "Tue, 07 Jan 2025 00:00:00 GMT";
const D3: &str = "Wed, 08 Jan 2025 00:00:00 GMT";
const D4: &str = "Thu, 09 Jan 2025 00:00:00 GMT";

async fn subscribe(app: &Router, feed_url: &str) -> Value {
    let (st, body) = call(app, "POST", "/api/shows", Some(TOKEN), Some(json!({ "feed_url": feed_url }))).await;
    assert_eq!(st, StatusCode::CREATED, "subscribe failed: {body}");
    body
}

#[tokio::test]
async fn auth_gate_and_login() {
    let (app, _d) = app().await;
    let (st, _) = call(&app, "GET", "/api/recent", None, None).await;
    assert_eq!(st, StatusCode::UNAUTHORIZED);
    let (st, _) = call(&app, "GET", "/api/recent", Some("wrong"), None).await;
    assert_eq!(st, StatusCode::UNAUTHORIZED);
    let (st, _) = call(&app, "POST", "/api/login", None, Some(json!({"token": "nope"}))).await;
    assert_eq!(st, StatusCode::UNAUTHORIZED);
    let (st, _) = call(&app, "POST", "/api/login", None, Some(json!({"token": TOKEN}))).await;
    assert_eq!(st, StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn subscribe_backfills_two_and_lists_recent() {
    let feeds = MockServer::start().await;
    let url = |p: &str| format!("{}{p}", feeds.uri());
    mount_feed(
        &feeds,
        "/a.xml",
        &rss(
            "Alpha",
            &[
                ("Ep1", "g1", "https://h.example/1.mp3", D1),
                ("Ep2", "g2", "https://h.example/2.mp3", D2),
                ("Ep3", "g3", "https://h.example/3.mp3", D3),
                ("Ep4", "g4", "https://h.example/4.mp3", D4),
            ],
        ),
    )
    .await;
    let (app, _d) = app().await;

    let show = subscribe(&app, &url("/a.xml")).await;
    assert_eq!(show["title"], "Alpha");
    assert_eq!(show["episode_count"], 4);
    assert_eq!(show["unplayed_count"], 2, "back catalog should be archived");

    let (st, recent) = get(&app, "/api/recent").await;
    assert_eq!(st, StatusCode::OK);
    let items = recent["items"].as_array().unwrap();
    assert_eq!(items.len(), 2);
    assert_eq!(items[0]["title"], "Ep4");
    assert_eq!(items[1]["title"], "Ep3");
    assert!(recent["next_offset"].is_null());

    // duplicate subscribe
    let (st, _) = call(&app, "POST", "/api/shows", Some(TOKEN), Some(json!({ "feed_url": url("/a.xml") }))).await;
    assert_eq!(st, StatusCode::CONFLICT);

    // bad url
    let (st, _) = call(&app, "POST", "/api/shows", Some(TOKEN), Some(json!({ "feed_url": "ftp://x" }))).await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY);

    // show list + detail
    let (_, shows) = get(&app, "/api/shows").await;
    assert_eq!(shows.as_array().unwrap().len(), 1);
    let id = shows[0]["id"].as_i64().unwrap();
    let (st, detail) = get(&app, &format!("/api/shows/{id}")).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(detail["episodes"]["items"].as_array().unwrap().len(), 4);
    let (st, _) = get(&app, "/api/shows/9999").await;
    assert_eq!(st, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn played_flow_roundtrip() {
    let feeds = MockServer::start().await;
    mount_feed(
        &feeds,
        "/a.xml",
        &rss(
            "Alpha",
            &[
                ("Ep1", "g1", "https://h.example/1.mp3", D1),
                ("Ep2", "g2", "https://h.example/2.mp3", D2),
            ],
        ),
    )
    .await;
    let (app, _d) = app().await;
    subscribe(&app, &format!("{}/a.xml", feeds.uri())).await;

    let (_, recent) = get(&app, "/api/recent").await;
    let id = recent["items"][0]["id"].as_i64().unwrap();

    let (st, _) = call(&app, "POST", &format!("/api/episodes/{id}/played"), Some(TOKEN), None).await;
    assert_eq!(st, StatusCode::NO_CONTENT);

    let (_, recent) = get(&app, "/api/recent").await;
    assert_eq!(recent["items"].as_array().unwrap().len(), 1);
    let (_, played) = get(&app, "/api/played").await;
    let played_items = played["items"].as_array().unwrap();
    assert_eq!(played_items.len(), 1);
    assert_eq!(played_items[0]["id"].as_i64().unwrap(), id);

    let (st, _) = call(&app, "DELETE", &format!("/api/episodes/{id}/played"), Some(TOKEN), None).await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    let (_, recent) = get(&app, "/api/recent").await;
    assert_eq!(recent["items"].as_array().unwrap().len(), 2);

    let (st, _) = call(&app, "POST", "/api/episodes/424242/played", Some(TOKEN), None).await;
    assert_eq!(st, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn position_and_episode_detail() {
    let feeds = MockServer::start().await;
    mount_feed(&feeds, "/a.xml", &rss("Alpha", &[("Ep1", "g1", "https://h.example/1.mp3", D1)])).await;
    let (app, _d) = app().await;
    subscribe(&app, &format!("{}/a.xml", feeds.uri())).await;
    let (_, recent) = get(&app, "/api/recent").await;
    let id = recent["items"][0]["id"].as_i64().unwrap();

    let (st, _) = call(&app, "PUT", &format!("/api/episodes/{id}/position"), Some(TOKEN), Some(json!({"seconds": 42.5}))).await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    let (st, detail) = get(&app, &format!("/api/episodes/{id}")).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(detail["position_secs"], 42.5);
    assert!(detail["notes_html"].as_str().unwrap().contains("Notes for Ep1"));
    assert_eq!(detail["podcast_title"], "Alpha");

    let (st, _) = call(&app, "PUT", &format!("/api/episodes/{id}/position"), Some(TOKEN), Some(json!({"seconds": -1}))).await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY);
    let (st, _) = get(&app, "/api/episodes/424242").await;
    assert_eq!(st, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn settings_roundtrip_and_validation() {
    let (app, _d) = app().await;
    let (st, s) = get(&app, "/api/settings").await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(s, json!({"speed": 1.0, "autoplay": true}));

    let (st, _) = call(&app, "PUT", "/api/settings", Some(TOKEN), Some(json!({"speed": 2.5, "autoplay": false}))).await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    let (_, s) = get(&app, "/api/settings").await;
    assert_eq!(s, json!({"speed": 2.5, "autoplay": false}));

    let (st, _) = call(&app, "PUT", "/api/settings", Some(TOKEN), Some(json!({"speed": 9.9, "autoplay": true}))).await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY);
}

#[tokio::test]
async fn next_episode_recent_and_show_contexts() {
    let feeds = MockServer::start().await;
    mount_feed(
        &feeds,
        "/a.xml",
        &rss(
            "Alpha",
            &[
                ("Ep1", "g1", "https://h.example/1.mp3", D1),
                ("Ep2", "g2", "https://h.example/2.mp3", D2),
                ("Ep3", "g3", "https://h.example/3.mp3", D3),
            ],
        ),
    )
    .await;
    let (app, _d) = app().await;
    subscribe(&app, &format!("{}/a.xml", feeds.uri())).await;

    // Recent holds Ep3, Ep2 (Ep1 archived). Recent-context next after Ep3 -> Ep2.
    let (_, recent) = get(&app, "/api/recent").await;
    let ep3 = recent["items"][0]["id"].as_i64().unwrap();
    let ep2 = recent["items"][1]["id"].as_i64().unwrap();

    let (st, next) = get(&app, &format!("/api/next?after={ep3}&context=recent")).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(next["id"].as_i64().unwrap(), ep2);

    // After the bottom of Recent there is nothing (Ep1 is archived).
    let (_, next) = get(&app, &format!("/api/next?after={ep2}")).await;
    assert!(next.is_null());

    // Show context binges forward chronologically: after Ep2 -> Ep3.
    let (_, next) = get(&app, &format!("/api/next?after={ep2}&context=show")).await;
    assert_eq!(next["id"].as_i64().unwrap(), ep3);

    // Played episodes are skipped: mark Ep2 played, next after Ep3 -> null.
    call(&app, "POST", &format!("/api/episodes/{ep2}/played"), Some(TOKEN), None).await;
    let (_, next) = get(&app, &format!("/api/next?after={ep3}")).await;
    assert!(next.is_null());

    let (st, _) = get(&app, "/api/next?after=424242").await;
    assert_eq!(st, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn search_local_fts_and_directory() {
    let feeds = MockServer::start().await;
    let feed_url = format!("{}/a.xml", feeds.uri());
    mount_feed(
        &feeds,
        "/a.xml",
        &rss("Alpha", &[("Quantum Entanglement Special", "g1", "https://h.example/1.mp3", D1)]),
    )
    .await;
    Mock::given(method("GET"))
        .and(path("/search/byterm"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "feeds": [
                {"title": "Alpha", "url": feed_url, "author": "A", "description": "d", "image": "i", "artwork": "art"},
                {"title": "Other", "url": "https://other.example/feed", "author": "B", "description": "d2", "image": "", "artwork": ""}
            ]
        })))
        .mount(&feeds)
        .await;

    // Directory configured
    let (app, _d) = app_with(feeds.uri(), "k").await;
    subscribe(&app, &feed_url).await;

    let (st, res) = get(&app, "/api/search?q=quantum").await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(res["directory_configured"], true);
    assert_eq!(res["episodes"][0]["title"], "Quantum Entanglement Special");
    let pods = res["podcasts"].as_array().unwrap();
    assert_eq!(pods.len(), 2);
    assert_eq!(pods[0]["subscribed"], true);
    assert_eq!(pods[1]["subscribed"], false);

    let (st, _) = get(&app, "/api/search?q=%20").await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY);

    // Directory not configured
    let (app2, _d2) = app().await;
    let (st, res) = get(&app2, "/api/search?q=anything").await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(res["directory_configured"], false);
    assert!(res["podcasts"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn opml_export_and_import() {
    let feeds = MockServer::start().await;
    let url_a = format!("{}/a.xml", feeds.uri());
    let url_b = format!("{}/b.xml", feeds.uri());
    mount_feed(&feeds, "/a.xml", &rss("Alpha", &[("Ep1", "g1", "https://h.example/1.mp3", D1)])).await;
    mount_feed(&feeds, "/b.xml", &rss("Beta", &[("Ep1", "g1", "https://h.example/b1.mp3", D2)])).await;

    let (app, _d) = app().await;
    subscribe(&app, &url_a).await;

    let (st, xml) = get(&app, "/api/opml").await;
    assert_eq!(st, StatusCode::OK);
    let xml = xml.as_str().unwrap().to_string();
    assert!(xml.contains("Alpha"));

    // Import: A (dupe) skipped, B imported, one bogus URL fails.
    let opml_doc = format!(
        r#"<opml version="2.0"><body>
            <outline type="rss" text="Alpha" xmlUrl="{url_a}"/>
            <outline type="rss" text="Beta" xmlUrl="{url_b}"/>
            <outline type="rss" text="Bogus" xmlUrl="{}/missing.xml"/>
        </body></opml>"#,
        feeds.uri()
    );
    let req = Request::builder()
        .method("POST")
        .uri("/api/opml")
        .header("authorization", format!("Bearer {TOKEN}"))
        .header("content-type", "text/xml")
        .body(Body::from(opml_doc))
        .unwrap();
    let res = app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let bytes = axum::body::to_bytes(res.into_body(), 1_000_000).await.unwrap();
    let v: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(v, json!({"imported": 1, "skipped": 1, "failed": 1}));

    let (st, _) = call(&app, "POST", "/api/opml", Some(TOKEN), Some(json!("no opml here"))).await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY);
}

#[tokio::test]
async fn refresh_picks_up_new_episodes() {
    let feeds = MockServer::start().await;
    let two = rss(
        "Alpha",
        &[
            ("Ep1", "g1", "https://h.example/1.mp3", D1),
            ("Ep2", "g2", "https://h.example/2.mp3", D2),
        ],
    );
    mount_feed(&feeds, "/a.xml", &two).await;
    let (app, _d) = app().await;
    subscribe(&app, &format!("{}/a.xml", feeds.uri())).await;

    // Feed gains an episode.
    feeds.reset().await;
    let three = rss(
        "Alpha",
        &[
            ("Ep1", "g1", "https://h.example/1.mp3", D1),
            ("Ep2", "g2", "https://h.example/2.mp3", D2),
            ("Ep3", "g3", "https://h.example/3.mp3", D3),
        ],
    );
    mount_feed(&feeds, "/a.xml", &three).await;

    let (st, res) = call(&app, "POST", "/api/refresh", Some(TOKEN), None).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(res["refreshed"], 1);

    let (_, recent) = get(&app, "/api/recent").await;
    let items = recent["items"].as_array().unwrap();
    assert_eq!(items.len(), 3, "new episode must land in Recent un-archived");
    assert_eq!(items[0]["title"], "Ep3");
}

#[tokio::test]
async fn unsubscribe_removes_everything() {
    let feeds = MockServer::start().await;
    mount_feed(&feeds, "/a.xml", &rss("Alpha", &[("Findable Episode", "g1", "https://h.example/1.mp3", D1)])).await;
    let (app, _d) = app().await;
    let show = subscribe(&app, &format!("{}/a.xml", feeds.uri())).await;
    let id = show["id"].as_i64().unwrap();

    let (st, _) = call(&app, "DELETE", &format!("/api/shows/{id}"), Some(TOKEN), None).await;
    assert_eq!(st, StatusCode::NO_CONTENT);

    let (_, recent) = get(&app, "/api/recent").await;
    assert!(recent["items"].as_array().unwrap().is_empty());
    let (_, res) = get(&app, "/api/search?q=findable").await;
    assert!(res["episodes"].as_array().unwrap().is_empty(), "fts rows must be purged");
    let (st, _) = call(&app, "DELETE", &format!("/api/shows/{id}"), Some(TOKEN), None).await;
    assert_eq!(st, StatusCode::NOT_FOUND);
}

use pods_backend::browser::{
    apply_actions, original_time, processed_time, snapshot, Interval, Manifest,
};
use pods_backend::local_worker::{
    retained_intervals, validate_labels, validate_segments, Label, Segment, MAX_FAILED_ATTEMPTS,
};
use pods_backend::{Backend, Database, DisabledDirectory, HttpRequest, MockFeedFetcher};
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::net::TcpStream;
use std::sync::Arc;
use std::time::Duration;

#[test]
fn snapshot_includes_persisted_refresh_status() {
    let (backend, _temp, _) = fixture();
    // Production passkeys must not turn saved history into a session-error body.
    backend
        .auth
        .enable_passkey("test-reset-secret", "https://pods.mcgiv.dev");
    backend.db.execute("INSERT INTO feed_refresh_state(id,last_success_at,last_attempt_at,last_source,last_refreshed,last_errors) VALUES(1,123,123,'test',32,0)", []).unwrap();
    let status = &snapshot(&backend).unwrap()["refresh_status"];
    assert_eq!(status["last_success_at"], 123);
    assert_eq!(status["last_attempt_at"], 123);
    assert_eq!(status["last_source"], "test");
    assert_eq!(status["last_refreshed"], 32);
    assert_eq!(status["last_errors"], 0);
    assert_eq!(status["is_refreshing"], false);
    assert!(status.get("error").is_none());
}

#[test]
fn snapshot_refresh_status_is_idle_before_any_refresh() {
    let (backend, _temp, _) = fixture();
    let status = &snapshot(&backend).unwrap()["refresh_status"];
    assert_eq!(status["last_success_at"], Value::Null);
    assert_eq!(status["last_attempt_at"], Value::Null);
    assert_eq!(status["last_source"], Value::Null);
    assert_eq!(status["last_refreshed"], 0);
    assert_eq!(status["last_errors"], 0);
    assert_eq!(status["is_refreshing"], false);
}

const NOTIFICATION_KEYS: [&str; 9] = [
    "id",
    "episode_id",
    "category",
    "failed_stage",
    "message",
    "outcome",
    "created_at",
    "episode_title",
    "podcast_title",
];

fn assert_notification_shape(item: &Value) {
    let obj = item.as_object().expect("notification object");
    let mut keys: Vec<_> = obj.keys().map(|k| k.as_str()).collect();
    keys.sort();
    let mut expected = NOTIFICATION_KEYS.to_vec();
    expected.sort();
    assert_eq!(keys, expected);
    for forbidden in [
        "audio_url",
        "feed_url",
        "description",
        "transcript",
        "path",
        "prompt",
        "error",
        "notes_html",
        "site_url",
        "image_url",
        "payload",
    ] {
        assert!(obj.get(forbidden).is_none(), "{forbidden}");
    }
    let dump = item.to_string();
    assert!(!dump.contains("https://"));
    assert!(!dump.contains("http://"));
    assert!(!dump.contains("original.mp3"));
    assert!(!dump.contains("/tmp/"));
    assert!(!dump.contains("feed_url"));
}

#[test]
fn snapshot_notifications_are_an_empty_array_by_default() {
    let (backend, _temp, _) = fixture();
    let value = snapshot(&backend).unwrap();
    assert_eq!(value["version"], 1);
    assert_eq!(value["notifications"], json!([]));
    assert!(value["notifications"].as_array().unwrap().is_empty());
}

#[test]
fn snapshot_notifications_are_newest_id_first_with_titles_and_four_categories() {
    let (backend, _temp, _) = fixture();
    backend
        .db
        .execute("UPDATE episodes SET title='Alpha Hour' WHERE id=1", [])
        .unwrap();
    backend
        .db
        .execute("UPDATE episodes SET title='Beta Talk' WHERE id=2", [])
        .unwrap();
    backend
        .db
        .execute(
            "INSERT INTO podcasts(id,feed_url,title,description,created_at) VALUES(2,'https://secret.example/feed.xml','Other Show','private show notes',0)",
            [],
        )
        .unwrap();
    backend
        .db
        .execute("UPDATE episodes SET podcast_id=2 WHERE id=2", [])
        .unwrap();
    let rows = [
        (
            1,
            "audio_download",
            "downloading",
            "Audio download failed.",
            "retry",
            50,
        ),
        (
            2,
            "speech_to_text",
            "transcribing",
            "Speech-to-text failed.",
            "retry",
            50,
        ),
        (
            1,
            "ad_classification",
            "classifying",
            "Ad classification failed.",
            "blocked",
            50,
        ),
        (
            2,
            "show_notes",
            "show_notes",
            "Show-note generation failed.",
            "retry",
            50,
        ),
        (
            1,
            "ad_classification",
            "ad_boundaries",
            "Ad classification failed.",
            "retry",
            50,
        ),
    ];
    for (episode_id, category, failed_stage, message, outcome, created_at) in rows {
        backend
            .db
            .execute(
                "INSERT INTO browser_processing_notifications(episode_id, category, failed_stage, message, created_at, outcome) VALUES(?,?,?,?,?,?)",
                rusqlite::params![episode_id, category, failed_stage, message, created_at, outcome],
            )
            .unwrap();
    }
    backend
        .db
        .execute(
            "INSERT INTO browser_jobs(episode_id,stage,attempts) VALUES(1,'retry',1),(2,'blocked',4)",
            [],
        )
        .unwrap();
    let value = snapshot(&backend).unwrap();
    assert_eq!(value["version"], 1);
    let notes = value["notifications"].as_array().unwrap();
    assert_eq!(notes.len(), 5);
    let ids: Vec<i64> = notes.iter().map(|n| n["id"].as_i64().unwrap()).collect();
    assert_eq!(ids, vec![5, 4, 3, 2, 1]);
    assert!(ids.windows(2).all(|pair| pair[0] > pair[1]));
    assert!(notes.iter().all(|n| n["created_at"] == 50));

    assert_eq!(notes[0]["category"], "ad_classification");
    assert_eq!(notes[0]["failed_stage"], "ad_boundaries");
    assert_eq!(notes[0]["episode_id"], 1);
    assert_eq!(notes[0]["episode_title"], "Alpha Hour");
    assert_eq!(notes[0]["podcast_title"], "Example");
    assert_eq!(notes[0]["message"], "Ad classification failed.");
    assert_eq!(notes[0]["outcome"], "retry");

    assert_eq!(notes[1]["category"], "show_notes");
    assert_eq!(notes[1]["failed_stage"], "show_notes");
    assert_eq!(notes[1]["episode_id"], 2);
    assert_eq!(notes[1]["episode_title"], "Beta Talk");
    assert_eq!(notes[1]["podcast_title"], "Other Show");
    assert_eq!(notes[1]["message"], "Show-note generation failed.");
    assert_eq!(notes[1]["outcome"], "retry");

    assert_eq!(notes[2]["category"], "ad_classification");
    assert_eq!(notes[2]["failed_stage"], "classifying");
    assert_eq!(notes[2]["outcome"], "blocked");
    assert_eq!(notes[2]["episode_title"], "Alpha Hour");

    assert_eq!(notes[3]["category"], "speech_to_text");
    assert_eq!(notes[3]["failed_stage"], "transcribing");
    assert_eq!(notes[3]["episode_title"], "Beta Talk");
    assert_eq!(notes[3]["podcast_title"], "Other Show");

    assert_eq!(notes[4]["category"], "audio_download");
    assert_eq!(notes[4]["failed_stage"], "downloading");
    assert_eq!(notes[4]["message"], "Audio download failed.");
    assert_eq!(notes[4]["episode_title"], "Alpha Hour");
    assert_eq!(notes[4]["podcast_title"], "Example");

    let categories: Vec<&str> = notes
        .iter()
        .map(|n| n["category"].as_str().unwrap())
        .collect();
    for category in [
        "audio_download",
        "speech_to_text",
        "ad_classification",
        "show_notes",
    ] {
        assert!(categories.contains(&category), "{category}");
    }
    for item in notes {
        assert_notification_shape(item);
    }
    backend
        .db
        .execute(
            "UPDATE browser_jobs SET stage='ready',error=NULL WHERE episode_id=1",
            [],
        )
        .unwrap();
    let resolved = snapshot(&backend).unwrap()["notifications"]
        .as_array()
        .unwrap()
        .clone();
    assert_eq!(resolved.len(), 2);
    assert!(resolved.iter().all(|n| n["episode_id"] == 2));

    let dump = value["notifications"].to_string();
    assert!(!dump.contains("https://secret.example/feed.xml"));
    assert!(!dump.contains("private show notes"));
    assert!(!dump.contains("original.mp3"));
    assert!(!dump.contains("error"));
}

fn fixture() -> (Backend, tempfile::TempDir, Manifest) {
    let temp = tempfile::tempdir().unwrap();
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts(id,feed_url,title,created_at) VALUES(1,'https://example.org/feed','Example',0)",[]).unwrap();
    for id in [1, 2] {
        db.execute("INSERT INTO episodes(id,podcast_id,guid,title,audio_url,published_at) VALUES(?,1,?,'Episode','https://example.org/original.mp3',?)",rusqlite::params![id,id.to_string(),id]).unwrap();
    }
    let mut backend = Backend::with_data_root(
        db,
        Arc::new(MockFeedFetcher::default()),
        Arc::new(DisabledDirectory),
        Some(temp.path().to_owned()),
    );
    backend.local = true;
    let bytes = b"abcdefgh";
    use sha2::{Digest, Sha256};
    let hash = hex::encode(Sha256::digest(bytes));
    backend
        .artifacts
        .install(&format!("published/{hash}.m4a"), bytes)
        .unwrap();
    let manifest = Manifest {
        version: 1,
        episode_id: 1,
        hash: hash.clone(),
        source_hash: "source".into(),
        bytes: 8,
        duration: 15.0,
        chunk_size: 1024 * 1024,
        chunks: vec![hash],
        timeline: vec![
            Interval {
                original_start: 0.0,
                original_end: 5.0,
                processed_start: 0.0,
            },
            Interval {
                original_start: 10.0,
                original_end: 20.0,
                processed_start: 5.0,
            },
        ],
        model: "local".into(),
        pipeline_version: "v1".into(),
        ..Default::default()
    };
    backend
        .db
        .execute(
            "INSERT INTO browser_publications VALUES(?,?,'[{\"id\":\"n0\",\"title\":\"Intro\",\"summary\":\"Start\"}]',0)",
            rusqlite::params![1, json!(manifest).to_string()],
        )
        .unwrap();
    (backend, temp, manifest)
}

fn action(id: &str, sequence: i64, field: &str, value: Value, revision: i64) -> Value {
    json!({"client_id":"phone","actions":[{"id":id,"sequence":sequence,"entity":"1","field":field,"value":value,"base_revision":revision}]})
}

#[test]
fn browser_subscribe_keeps_newest_two_episodes() {
    let (backend, _temp, _) = fixture();
    backend.db.execute("DELETE FROM browser_publications", []).unwrap();
    backend.db.execute("DELETE FROM episodes", []).unwrap();
    apply_actions(
        &backend,
        json!({"client_id":"phone","actions":[{
            "id":"sub","sequence":1,"entity":"subscription","field":"https://example.org/feed",
            "value":true,"base_revision":0
        }]}),
    )
    .unwrap();
    for id in 1..=4 {
        backend
            .db
            .execute(
                "INSERT INTO episodes(id,podcast_id,guid,title,audio_url,published_at) VALUES(?,1,?,?,?,?)",
                rusqlite::params![id, id.to_string(), format!("Ep{id}"), "invalid://not-fetched", id],
            )
            .unwrap();
    }
    pods_backend::local_worker::step(&backend).unwrap();
    let mut ids = backend
        .db
        .lock()
        .unwrap()
        .prepare("SELECT episode_id FROM browser_jobs ORDER BY episode_id")
        .unwrap()
        .query_map([], |r| r.get::<_, i64>(0))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    ids.sort();
    assert_eq!(ids, vec![3, 4]);
    assert_eq!(
        backend
            .db
            .scalar_i64("SELECT COUNT(*) FROM episode_state WHERE archived_at IS NOT NULL", [])
            .unwrap(),
        Some(2)
    );
}

#[test]
fn queued_episodes_are_not_starved_by_repeated_old_failures() {
    let (backend, _temp, _) = fixture();
    backend
        .db
        .execute("DELETE FROM browser_publications", [])
        .unwrap();
    backend
        .db
        .execute("UPDATE episodes SET audio_url='invalid://not-fetched'", [])
        .unwrap();
    backend.db.execute("INSERT INTO browser_jobs(episode_id,stage,attempts) VALUES(1,'retry',5),(2,'queued',0)", []).unwrap();
    assert!(pods_backend::local_worker::step(&backend).unwrap());
    assert_eq!(
        backend
            .db
            .scalar_i64("SELECT attempts FROM browser_jobs WHERE episode_id=1", [])
            .unwrap(),
        Some(5)
    );
    assert_eq!(
        backend
            .db
            .scalar_i64("SELECT attempts FROM browser_jobs WHERE episode_id=2", [])
            .unwrap(),
        Some(1)
    );
    let s = snapshot(&backend).unwrap();
    assert_eq!(s["episodes"].as_array().unwrap().len(), 0);
    assert_eq!(s["shows"][0]["episode_count"], 2);
    assert_eq!(s["shows"][0]["unplayed_count"], 2);
    assert_eq!(s["shows"][0]["ready_count"], 0);
    assert_eq!(s["processing"]["failed"], 2);
    assert_eq!(s["processing"]["blocked"], 0);
    assert!(s["processing"].get("review").is_none());
    assert!(!pods_backend::local_worker::step(&backend).unwrap());
    assert_eq!(
        backend
            .db
            .scalar_i64("SELECT attempts FROM browser_jobs WHERE episode_id=1", [])
            .unwrap(),
        Some(5)
    );
    assert_eq!(
        backend
            .db
            .scalar_string("SELECT stage FROM browser_jobs WHERE episode_id=1", [])
            .unwrap()
            .as_deref(),
        Some("retry")
    );
}

#[test]
fn pending_count_includes_new_episodes_before_worker_enrollment() {
    let (backend, _temp, _) = fixture();
    let value = snapshot(&backend).unwrap();
    assert_eq!(value["processing"]["pending"], 1);
    assert_eq!(value["processing"]["failed"], 0);
    assert_eq!(value["processing"]["blocked"], 0);
    assert!(value["processing"].get("review").is_none());
    backend
        .db
        .execute("UPDATE podcasts SET is_subscribed=0", [])
        .unwrap();
    assert_eq!(snapshot(&backend).unwrap()["processing"]["pending"], 0);
}

#[test]
fn worker_blocks_after_four_failed_attempts_and_skips_blocked_rows() {
    let temp = tempfile::tempdir().unwrap();
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts(id,feed_url,title,created_at) VALUES(1,'https://example.org/feed','Example',0)", []).unwrap();
    db.execute("INSERT INTO episodes(id,podcast_id,guid,title,audio_url,published_at) VALUES(1,1,'g','Episode','invalid://not-fetched',1)", []).unwrap();
    let mut backend = Backend::with_data_root(
        db,
        Arc::new(MockFeedFetcher::default()),
        Arc::new(DisabledDirectory),
        Some(temp.path().to_owned()),
    );
    backend.local = true;
    for n in 1..=MAX_FAILED_ATTEMPTS {
        assert!(pods_backend::local_worker::step(&backend).unwrap());
        let stage = backend
            .db
            .scalar_string("SELECT stage FROM browser_jobs WHERE episode_id=1", [])
            .unwrap()
            .unwrap();
        let attempts = backend
            .db
            .scalar_i64("SELECT attempts FROM browser_jobs WHERE episode_id=1", [])
            .unwrap()
            .unwrap();
        assert_eq!(attempts, n);
        if n < MAX_FAILED_ATTEMPTS {
            assert_eq!(stage, "retry");
        } else {
            assert_eq!(stage, "blocked");
        }
        backend
            .db
            .execute(
                "UPDATE browser_jobs SET next_retry_at=0 WHERE episode_id=1",
                [],
            )
            .unwrap();
    }
    assert!(!pods_backend::local_worker::step(&backend).unwrap());
    assert_eq!(
        backend
            .db
            .scalar_string("SELECT stage FROM browser_jobs WHERE episode_id=1", [])
            .unwrap()
            .as_deref(),
        Some("blocked")
    );
    let s = snapshot(&backend).unwrap();
    assert_eq!(s["processing"]["blocked"], 1);
    assert_eq!(s["processing"]["failed"], 0);
    assert_eq!(s["processing"]["pending"], 0);
    assert!(s["processing"].get("review").is_none());
}

#[test]
fn opening_existing_db_upgrades_review_rows_without_touching_publications_or_listening() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("pods.sqlite");
    let db = Database::open(&path).unwrap();
    db.execute("INSERT INTO podcasts(id,feed_url,title,created_at) VALUES(1,'https://example.org/feed','Example',0)", []).unwrap();
    for id in 1..=7 {
        db.execute(
            "INSERT INTO episodes(id,podcast_id,guid,title,audio_url,published_at) VALUES(?,1,?,'E','https://example.org/a.mp3',?)",
            rusqlite::params![id, id.to_string(), id],
        )
        .unwrap();
    }
    db.execute("INSERT INTO browser_jobs(episode_id,stage,attempts,error) VALUES(1,'review',0,'classification requires review')", []).unwrap();
    db.execute("INSERT INTO browser_jobs(episode_id,stage,attempts,error) VALUES(2,'review',3,'ad boundary requires review')", []).unwrap();
    db.execute("INSERT INTO browser_jobs(episode_id,stage,attempts,error) VALUES(3,'review',4,'classification requires review')", []).unwrap();
    db.execute(
        "INSERT INTO browser_jobs(episode_id,stage,attempts,error) VALUES(4,'queued',0,NULL)",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO browser_jobs(episode_id,stage,attempts,error) VALUES(5,'retry',4,'download failed')",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO browser_jobs(episode_id,stage,attempts,error) VALUES(6,'retry',5,'classifier timeout')",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO browser_jobs(episode_id,stage,attempts,error) VALUES(7,'retry',3,'classification requires review')",
        [],
    )
    .unwrap();
    let notes = json!([{"title":"keep"}]).to_string();
    db.execute(
        "INSERT INTO browser_publications VALUES(4,'{\"hash\":\"pub4\"}',?,123)",
        rusqlite::params![notes],
    )
    .unwrap();
    db.execute("INSERT INTO listen_episodes(episode_id) VALUES(2)", [])
        .unwrap();
    db.execute(
        "INSERT INTO episode_state(episode_id,position_secs,played_at,updated_at) VALUES(1,15.5,NULL,9)",
        [],
    )
    .unwrap();
    drop(db);

    let reopen = |path: &std::path::Path| {
        let db = Database::open(path).unwrap();
        let jobs: Vec<(i64, String, i64)> = {
            let conn = db.lock().unwrap();
            let mut stmt = conn
                .prepare("SELECT episode_id,stage,attempts FROM browser_jobs ORDER BY episode_id")
                .unwrap();
            stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
                .unwrap()
                .map(|r| r.unwrap())
                .collect()
        };
        assert_eq!(
            jobs,
            vec![
                (1, "retry".into(), 0),
                (2, "retry".into(), 3),
                (3, "blocked".into(), 4),
                (4, "queued".into(), 0),
                (5, "blocked".into(), 4),
                (6, "blocked".into(), 5),
                (7, "retry".into(), 3),
            ]
        );
        let errors: Vec<(i64, Option<String>)> = {
            let conn = db.lock().unwrap();
            let mut stmt = conn
                .prepare("SELECT episode_id,error FROM browser_jobs ORDER BY episode_id")
                .unwrap();
            stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
                .unwrap()
                .map(|r| r.unwrap())
                .collect()
        };
        assert_eq!(
            errors,
            vec![
                (1, Some("automatic processing failed validation".into())),
                (2, Some("automatic processing failed validation".into())),
                (3, Some("automatic processing failed validation".into())),
                (4, None),
                (5, Some("download failed".into())),
                (6, Some("classifier timeout".into())),
                (7, Some("automatic processing failed validation".into())),
            ]
        );
        assert_eq!(
            db.scalar_string(
                "SELECT notes_json FROM browser_publications WHERE episode_id=4",
                []
            )
            .unwrap()
            .as_deref(),
            Some(notes.as_str())
        );
        assert_eq!(
            db.scalar_i64(
                "SELECT published_at FROM browser_publications WHERE episode_id=4",
                []
            )
            .unwrap(),
            Some(123)
        );
        assert_eq!(
            db.scalar_i64(
                "SELECT episode_id FROM listen_episodes WHERE episode_id=2",
                []
            )
            .unwrap(),
            Some(2)
        );
        assert_eq!(
            db.scalar_i64(
                "SELECT CAST(position_secs * 10 AS INTEGER) FROM episode_state WHERE episode_id=1",
                []
            )
            .unwrap(),
            Some(155)
        );
        db
    };
    drop(reopen(&path));
    drop(reopen(&path));
}

#[test]
fn exhausted_retry_inserted_after_open_is_not_selected() {
    let temp = tempfile::tempdir().unwrap();
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts(id,feed_url,title,created_at) VALUES(1,'https://example.org/feed','Example',0)", []).unwrap();
    db.execute("INSERT INTO episodes(id,podcast_id,guid,title,audio_url,published_at) VALUES(1,1,'g','Episode','invalid://not-fetched',1)", []).unwrap();
    let mut backend = Backend::with_data_root(
        db,
        Arc::new(MockFeedFetcher::default()),
        Arc::new(DisabledDirectory),
        Some(temp.path().to_owned()),
    );
    backend.local = true;
    backend
        .db
        .execute(
            "INSERT INTO browser_jobs(episode_id,stage,attempts,error,next_retry_at) VALUES(1,'retry',4,'download failed',0)",
            [],
        )
        .unwrap();
    assert!(!pods_backend::local_worker::step(&backend).unwrap());
    assert_eq!(
        backend
            .db
            .execute(
                "UPDATE browser_jobs SET attempts=5,next_retry_at=0 WHERE episode_id=1",
                [],
            )
            .unwrap(),
        1
    );
    assert!(!pods_backend::local_worker::step(&backend).unwrap());
    assert_eq!(
        backend
            .db
            .scalar_string("SELECT stage FROM browser_jobs WHERE episode_id=1", [])
            .unwrap()
            .as_deref(),
        Some("retry")
    );
    assert_eq!(
        backend
            .db
            .scalar_i64("SELECT attempts FROM browser_jobs WHERE episode_id=1", [])
            .unwrap(),
        Some(5)
    );
}

#[test]
fn pending_excludes_terminal_blocked_unpublished_episodes() {
    let temp = tempfile::tempdir().unwrap();
    let db = Database::open_in_memory().unwrap();
    db.execute("INSERT INTO podcasts(id,feed_url,title,created_at) VALUES(1,'https://example.org/feed','Example',0)", []).unwrap();
    db.execute("INSERT INTO episodes(id,podcast_id,guid,title,audio_url,published_at) VALUES(1,1,'g','Episode','https://example.org/a.mp3',1)", []).unwrap();
    let mut backend = Backend::with_data_root(
        db,
        Arc::new(MockFeedFetcher::default()),
        Arc::new(DisabledDirectory),
        Some(temp.path().to_owned()),
    );
    backend.local = true;
    let before = snapshot(&backend).unwrap();
    assert_eq!(before["processing"]["pending"], 1);
    assert_eq!(before["processing"]["blocked"], 0);
    backend
        .db
        .execute(
            "INSERT INTO browser_jobs(episode_id,stage,attempts,error) VALUES(1,'blocked',4,'automatic processing failed validation')",
            [],
        )
        .unwrap();
    let after = snapshot(&backend).unwrap();
    assert_eq!(after["processing"]["blocked"], 1);
    assert_eq!(after["processing"]["pending"], 0);
    assert_eq!(after["processing"]["failed"], 0);
    assert!(after["processing"].get("review").is_none());
    assert!(after["episodes"].as_array().unwrap().is_empty());
}

#[test]
fn browser_routes_require_session_but_allow_login_bootstrap() {
    let (backend, _temp, manifest) = fixture();
    backend
        .auth
        .enable_passkey("test-reset-secret", "https://pods.mcgiv.dev");
    for path in [
        "/api/sync".to_string(),
        "/api/status".into(),
        format!("/api/artifacts/{}", manifest.hash),
        "/api/episodes/1/artifact-manifest".into(),
    ] {
        assert_eq!(
            backend.handle(HttpRequest::new("GET", &path)).status_code,
            401
        );
    }
    assert_eq!(
        backend
            .handle(
                HttpRequest::new("POST", "/api/sync/actions").with_json(&action(
                    "no-session",
                    1,
                    "played",
                    json!(true),
                    0
                ))
            )
            .status_code,
        401
    );
    assert_eq!(
        backend
            .handle(HttpRequest::new("GET", "/api/auth/status"))
            .status_code,
        200
    );
    assert_eq!(
        backend
            .handle(
                HttpRequest::new("OPTIONS", "/api/sync")
                    .with_header("origin", "https://pods.mcgiv.dev")
            )
            .status_code,
        204
    );
}

#[test]
fn old_artifact_positions_keep_their_original_timeline() {
    let (backend, _temp, old) = fixture();
    backend
        .db
        .execute(
            "INSERT INTO browser_artifacts VALUES(?,?,?)",
            rusqlite::params![old.hash, 1, json!(old).to_string()],
        )
        .unwrap();
    let mut latest = old.clone();
    latest.hash = "b".repeat(64);
    latest.timeline = vec![Interval {
        original_start: 0.0,
        original_end: 20.0,
        processed_start: 0.0,
    }];
    latest.duration = 20.0;
    backend
        .db
        .execute(
            "UPDATE browser_publications SET manifest_json=? WHERE episode_id=1",
            [json!(latest).to_string()],
        )
        .unwrap();
    apply_actions(
        &backend,
        action(
            "old-position",
            1,
            "position",
            json!({"seconds":6,"artifact_hash":old.hash}),
            0,
        ),
    )
    .unwrap();
    assert_eq!(
        snapshot(&backend).unwrap()["episodes"][0]["position_secs"],
        11.0
    );
    let response = backend.handle(HttpRequest::new(
        "GET",
        format!("/api/artifacts/{}", old.hash),
    ));
    assert_eq!(response.status_code, 200);
}

#[test]
fn snapshot_hides_publication_until_show_notes_exist() {
    let (backend, _temp, _) = fixture();
    backend
        .db
        .execute("UPDATE browser_publications SET notes_json='[]' WHERE episode_id=1", [])
        .unwrap();
    let value = snapshot(&backend).unwrap();
    assert!(value["episodes"].as_array().unwrap().is_empty());
    assert_eq!(value["shows"][0]["ready_count"], 0);
    assert_eq!(value["shows"][0]["pending_count"], 2);
}

#[test]
fn snapshot_replaces_the_feed_title_with_the_listen_title() {
    let (backend, _temp, mut manifest) = fixture();
    manifest.listen_title = "John Doe: Bitcoin macro update".into();
    backend
        .db
        .execute(
            "UPDATE browser_publications SET manifest_json=? WHERE episode_id=1",
            [json!(manifest).to_string()],
        )
        .unwrap();
    assert_eq!(
        snapshot(&backend).unwrap()["episodes"][0]["title"],
        "John Doe: Bitcoin macro update"
    );
}

#[test]
fn published_snapshot_never_exposes_original_or_unprocessed_episode() {
    let (backend, _temp, manifest) = fixture();
    let value = snapshot(&backend).unwrap();
    assert_eq!(value["episodes"].as_array().unwrap().len(), 1);
    assert_eq!(
        value["episodes"][0]["audio_url"],
        format!("/_media/{}.m4a", manifest.hash)
    );
    assert_eq!(value["episodes"][0]["ad_removal_state"], "ad-free");
    assert_eq!(value["shows"][0]["episode_count"], 2);
    assert_eq!(value["shows"][0]["unplayed_count"], 2);
    assert_eq!(value["shows"][0]["ready_count"], 1);
    assert_eq!(value["shows"][0]["pending_count"], 1);
    assert!(!value.to_string().contains("original.mp3"));
    for path in [
        "/api/episodes/2",
        "/api/recent",
        "/api/episodes/2/artifact-manifest",
        "/api/ad-removal/statuses?episode_ids=2",
        "/api/feeds/preview",
    ] {
        assert_eq!(
            backend.handle(HttpRequest::new("GET", path)).status_code,
            404,
            "{}",
            path
        );
    }
}

#[test]
fn operation_retries_are_idempotent_and_collisions_fail() {
    let (backend, _temp, manifest) = fixture();
    let payload = action("op1", 1, "played", json!(true), 0);
    let first = apply_actions(&backend, payload.clone()).unwrap();
    assert_eq!(first, apply_actions(&backend, payload).unwrap());
    let mut extra = action("op1", 1, "played", json!(true), 0);
    extra["actions"][0]["conflict"] = json!(9);
    assert_eq!(first, apply_actions(&backend, extra).unwrap());
    assert_eq!(
        backend
            .db
            .scalar_i64("SELECT COUNT(*) FROM browser_operations", [])
            .unwrap(),
        Some(1)
    );
    assert!(apply_actions(&backend, action("op1", 1, "played", json!(false), 0)).is_err());
    let duplicate_sequence = apply_actions(
        &backend,
        action(
            "another",
            1,
            "position",
            json!({"seconds":6,"artifact_hash":manifest.hash}),
            0,
        ),
    )
    .unwrap();
    assert_eq!(duplicate_sequence["results"][0]["status"], "applied");
}

#[test]
fn stale_playback_artifact_conflicts_without_blocking_later_actions() {
    let (backend, _temp, manifest) = fixture();
    let mut batch = action(
        "stale",
        1,
        "position",
        json!({"seconds":6,"artifact_hash":"c".repeat(64)}),
        0,
    );
    batch["actions"].as_array_mut().unwrap().push(
        action(
            "fresh",
            2,
            "position",
            json!({"seconds":2,"artifact_hash":manifest.hash}),
            0,
        )["actions"][0]
            .clone(),
    );
    let result = apply_actions(&backend, batch).unwrap();
    assert_eq!(result["results"][0]["status"], "conflict");
    assert_eq!(result["results"][1]["status"], "applied");
    assert_eq!(snapshot(&backend).unwrap()["episodes"][0]["position_secs"], 2.0);
}

#[test]
fn conflicting_field_does_not_overwrite_and_other_fields_are_independent() {
    let (backend, _temp, manifest) = fixture();
    apply_actions(&backend, action("played", 1, "played", json!(true), 0)).unwrap();
    let conflict =
        apply_actions(&backend, action("unplayed", 2, "played", json!(false), 0)).unwrap();
    assert_eq!(conflict["results"][0]["status"], "conflict");
    assert!(snapshot(&backend).unwrap()["episodes"][0]["played_at"].is_number());
    let position = apply_actions(
        &backend,
        action(
            "position",
            3,
            "position",
            json!({"seconds":6,"artifact_hash":manifest.hash}),
            0,
        ),
    )
    .unwrap();
    assert_eq!(position["results"][0]["status"], "applied");
    assert_eq!(
        backend
            .db
            .scalar_i64(
                "SELECT CAST(position_secs AS INTEGER) FROM episode_state WHERE episode_id=1",
                []
            )
            .unwrap(),
        Some(11)
    );
    let rev = position["results"][0]["revision"].as_i64().unwrap();
    apply_actions(
        &backend,
        action(
            "backward-seek",
            4,
            "position",
            json!({"seconds":2,"artifact_hash":manifest.hash}),
            rev,
        ),
    )
    .unwrap();
    assert_eq!(
        snapshot(&backend).unwrap()["episodes"][0]["position_secs"],
        2.0
    );
}

#[test]
fn failed_batch_rolls_back_earlier_actions() {
    let (backend, _temp, _) = fixture();
    let mut first = action("one", 1, "played", json!(true), 0);
    first["actions"]
        .as_array_mut()
        .unwrap()
        .push(action("bad", 2, "unsupported", json!(true), 0)["actions"][0].clone());
    assert!(apply_actions(&backend, first).is_err());
    assert_eq!(
        backend
            .db
            .scalar_i64("SELECT COUNT(*) FROM browser_operations", [])
            .unwrap(),
        Some(0)
    );
    assert_eq!(
        backend
            .db
            .scalar_i64("SELECT COUNT(*) FROM episode_state", [])
            .unwrap(),
        Some(0)
    );
}

#[test]
fn cors_and_authenticated_artifact_range_contract() {
    let (backend, _temp, manifest) = fixture();
    let rejected = backend.handle(
        HttpRequest::new("OPTIONS", "/api/sync").with_header("origin", "https://evil.example"),
    );
    assert_eq!(rejected.status_code, 403);
    let accepted = backend.handle(
        HttpRequest::new("OPTIONS", "/api/sync").with_header("origin", "https://pods.mcgiv.dev"),
    );
    assert_eq!(accepted.status_code, 204);
    assert_eq!(accepted.headers["access-control-allow-credentials"], "true");
    let path = format!("/api/artifacts/{}", manifest.hash);
    let range = backend.handle(HttpRequest::new("GET", &path).with_header("range", "bytes=2-5"));
    assert_eq!(range.status_code, 206);
    assert_eq!(range.body, b"cdef");
    assert_eq!(range.headers["Content-Range"], "bytes 2-5/8");
    let head = backend.handle(HttpRequest::new("HEAD", &path));
    assert!(head.body.is_empty());
    assert_eq!(head.headers["Content-Length"], "8");
    assert_eq!(
        backend
            .handle(HttpRequest::new("GET", path).with_header("range", "bytes=99-"))
            .status_code,
        416
    );
}

fn device_row(backend: &Backend, client: &str) -> Option<(String, i64, i64, i64)> {
    backend
        .db
        .lock()
        .ok()?
        .query_row(
            "SELECT device,last_sync_at,sync_count,last_actions_at FROM browser_sync_devices WHERE client_id=?",
            [client],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .ok()
}

fn device_count(backend: &Backend) -> i64 {
    backend
        .db
        .scalar_i64("SELECT COUNT(*) FROM browser_sync_devices", [])
        .unwrap()
        .unwrap()
}

#[test]
fn sync_requests_record_per_device_last_sync() {
    let (backend, _temp, _) = fixture();
    let pull = backend.handle(
        HttpRequest::new("GET", "/api/sync")
            .with_header("x-pods-client-id", "phone")
            .with_header("x-pods-device", "iPhone"),
    );
    assert_eq!(pull.status_code, 200);
    let row = device_row(&backend, "phone").expect("pull records the device");
    assert_eq!(row.0, "iPhone");
    assert!(row.1 > 0);
    assert_eq!(row.2, 1);
    assert_eq!(row.3, 0);

    // Anonymous pulls keep working and record nothing.
    let anonymous = backend.handle(HttpRequest::new("GET", "/api/sync"));
    assert_eq!(anonymous.status_code, 200);
    assert_eq!(device_count(&backend), 1);

    // Overlong identity is ignored, not stored.
    let spoofed = backend.handle(
        HttpRequest::new("GET", "/api/sync")
            .with_header("x-pods-client-id", "x".repeat(129))
            .with_header("x-pods-device", "iPhone"),
    );
    assert_eq!(spoofed.status_code, 200);
    assert_eq!(device_count(&backend), 1);

    // Action posts record the device and the applied moment.
    let posted = backend.handle(
        HttpRequest::new("POST", "/api/sync/actions").with_json(&json!({
            "client_id": "phone",
            "device_name": "iPhone",
            "actions": [],
        })),
    );
    assert_eq!(posted.status_code, 200);
    let row = device_row(&backend, "phone").expect("actions record the device");
    assert_eq!(row.2, 2);
    assert!(row.3 > 0);

    // Direct internal calls never touch the device log.
    apply_actions(
        &backend,
        json!({"client_id": "pipeline-menu", "device_name": "Pipeline", "actions": []}),
    )
    .unwrap();
    assert_eq!(device_count(&backend), 1);
}

fn tcp_get(addr: &str, path: &str, extra_headers: &str) -> Vec<u8> {
    let mut stream = TcpStream::connect(addr).expect("connect");
    let request = format!(
        "GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n{extra_headers}\r\n"
    );
    stream.write_all(request.as_bytes()).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    let mut buf = Vec::new();
    stream.read_to_end(&mut buf).unwrap();
    buf
}

fn tcp_status_line(raw: &[u8]) -> &str {
    std::str::from_utf8(raw)
        .unwrap()
        .split("\r\n")
        .next()
        .unwrap()
}

fn tcp_body(raw: &[u8]) -> &[u8] {
    let pos = raw.windows(4).position(|w| w == b"\r\n\r\n").unwrap();
    &raw[pos + 4..]
}

#[test]
fn tcp_server_serializes_artifact_206_and_304_reason_phrases() {
    let (backend, _temp, manifest) = fixture();
    let listener = pods_backend::server::serve(Arc::new(backend), "127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap().to_string();
    let path = format!("/api/artifacts/{}", manifest.hash);

    let range = tcp_get(&addr, &path, "Range: bytes=2-5\r\n");
    let range_text = std::str::from_utf8(&range).unwrap();
    assert_eq!(tcp_status_line(&range), "HTTP/1.1 206 Partial Content");
    assert!(range_text.contains("Content-Range: bytes 2-5/8"));
    assert_eq!(tcp_body(&range), b"cdef");

    let etag = format!("If-None-Match: \"{}\"\r\n", manifest.hash);
    let not_modified = tcp_get(&addr, &path, &etag);
    assert_eq!(tcp_status_line(&not_modified), "HTTP/1.1 304 Not Modified");
    assert!(tcp_body(&not_modified).is_empty());

    let unsatisfiable = tcp_get(&addr, &path, "Range: bytes=99-\r\n");
    let unsatisfiable_text = std::str::from_utf8(&unsatisfiable).unwrap();
    assert_eq!(
        tcp_status_line(&unsatisfiable),
        "HTTP/1.1 416 Range Not Satisfiable"
    );
    assert!(unsatisfiable_text.contains("Content-Range: bytes */8"));
    assert!(tcp_body(&unsatisfiable).is_empty());
}

#[test]
fn tcp_server_keeps_passkey_unauthorized_reason() {
    let (backend, _temp, manifest) = fixture();
    backend
        .auth
        .enable_passkey("test-reset-secret", "https://pods.mcgiv.dev");
    let listener = pods_backend::server::serve(Arc::new(backend), "127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap().to_string();
    let path = format!("/api/artifacts/{}", manifest.hash);
    let raw = tcp_get(&addr, &path, "Range: bytes=2-5\r\n");
    assert_eq!(tcp_status_line(&raw), "HTTP/1.1 401 Unauthorized");
}

fn cookie_pair(set_cookie: &str) -> String {
    set_cookie.split(';').next().unwrap().trim().to_string()
}

fn enroll_scripted_session(backend: &mut Backend) -> String {
    let local = backend.local;
    backend.local = false;
    let reset = backend.handle(
        HttpRequest::new("POST", "/api/internal/passkey-reset")
            .with_header("x-pods-reset-key", "test-reset-secret"),
    );
    assert_eq!(reset.status_code, 200);
    let body: Value = serde_json::from_slice(&reset.body).unwrap();
    let token = body["enroll_url"]
        .as_str()
        .unwrap()
        .split("#enroll=")
        .nth(1)
        .unwrap();
    let options = backend.handle(
        HttpRequest::new("POST", "/api/auth/register/options")
            .with_json(&json!({ "token": token })),
    );
    assert_eq!(options.status_code, 200);
    let options_body: Value = serde_json::from_slice(&options.body).unwrap();
    let registered = backend.handle(HttpRequest::new("POST", "/api/auth/register").with_json(
        &json!({
            "state_id": options_body["state_id"],
            "credential": { "id": "cred-1" }
        }),
    ));
    assert_eq!(registered.status_code, 201);
    backend.local = local;
    cookie_pair(registered.headers.get("set-cookie").unwrap())
}

#[test]
fn tcp_server_serves_authenticated_artifact_range_with_passkey_session() {
    let (mut backend, _temp, manifest) = fixture();
    backend
        .auth
        .enable_passkey("test-reset-secret", "https://pods.mcgiv.dev");
    let cookie = enroll_scripted_session(&mut backend);
    let listener = pods_backend::server::serve(Arc::new(backend), "127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap().to_string();
    let path = format!("/api/artifacts/{}", manifest.hash);

    let missing = tcp_get(&addr, &path, "Range: bytes=2-5\r\n");
    assert_eq!(tcp_status_line(&missing), "HTTP/1.1 401 Unauthorized");
    let invalid = tcp_get(
        &addr,
        &path,
        "Range: bytes=2-5\r\nCookie: pods_session=invalid-token\r\n",
    );
    assert_eq!(tcp_status_line(&invalid), "HTTP/1.1 401 Unauthorized");

    let range = tcp_get(
        &addr,
        &path,
        &format!("Range: bytes=2-5\r\nCookie: {cookie}\r\n"),
    );
    let range_text = std::str::from_utf8(&range).unwrap();
    assert_eq!(tcp_status_line(&range), "HTTP/1.1 206 Partial Content");
    assert!(range_text.contains("Content-Range: bytes 2-5/8"));
    assert_eq!(range_text.matches("Content-Length:").count(), 1);
    assert!(range_text.contains("Content-Length: 4\r\n"));
    assert_eq!(tcp_body(&range), b"cdef");
}

#[test]
fn transcript_and_labels_require_real_text_complete_ids_and_evidence() {
    let segments = vec![
        Segment {
            id: "s0".into(),
            start: 0.0,
            end: 1.0,
            text: "Sponsored by Acme.".into(),
        },
        Segment {
            id: "s1".into(),
            start: 1.0,
            end: 2.0,
            text: "We discuss technology.".into(),
        },
    ];
    validate_segments(&segments).unwrap();
    let valid = json!({"labels":[{"segment_id":"s1","label":"content","evidence":"discuss"},{"segment_id":"s0","label":"ad","evidence":"Sponsored"}]});
    let ordered = validate_labels(&valid, &segments).unwrap();
    assert_eq!(ordered[0].segment_id, "s0");
    let mut invalid = valid.clone();
    invalid["labels"][0]["segment_id"] = json!("invented");
    assert!(validate_labels(&invalid, &segments).is_err());
    invalid = valid.clone();
    invalid["labels"][0]["evidence"] = json!("not in transcript");
    assert!(validate_labels(&invalid, &segments).is_err());
    invalid = valid;
    invalid["labels"].as_array_mut().unwrap().pop();
    assert!(validate_labels(&invalid, &segments).is_err());
}

#[test]
fn ad_blocks_must_cover_each_segment_once_and_preserve_source_quotes() {
    use pods_backend::local_worker::validate_blocks;
    let segments: Vec<_> = (0..4)
        .map(|i| Segment {
            id: format!("s{i}"),
            start: i as f64,
            end: (i + 1) as f64,
            text: format!("Source sentence {i}."),
        })
        .collect();
    let valid = json!({"blocks":[{"first":"s2","last":"s3","label":"content"},{"first":"s0","last":"s1","label":"ad"}]});
    let labels = validate_blocks(&valid, &segments).unwrap();
    assert_eq!(
        labels.iter().map(|l| l.label.as_str()).collect::<Vec<_>>(),
        ["ad", "ad", "content", "content"]
    );
    for (label, segment) in labels.iter().zip(&segments) {
        assert!(segment.text.contains(&label.evidence));
    }
    for invalid in [
        json!({"blocks":[]}),
        json!({"blocks":[{"first":"s1","last":"s3","label":"ad"}]}),
        json!({"blocks":[{"first":"s0","last":"s1","label":"ad"}]}),
        json!({"blocks":[{"first":"s0","last":"s2","label":"ad"},{"first":"s2","last":"s3","label":"content"}]}),
        json!({"blocks":[{"first":"s0","last":"s99","label":"ad"}]}),
        json!({"blocks":[{"first":"s0","last":"s3","label":"invented"}]}),
    ] {
        assert!(validate_blocks(&invalid, &segments).is_err());
    }
    let review = validate_blocks(
        &json!({"blocks":[{"first":"s0","last":"s3","label":"uncertain"}]}),
        &segments,
    )
    .unwrap();
    assert!(review.iter().all(|l| l.label == "content"));
}

#[test]
fn cut_timeline_preserves_content_and_maps_chapters_and_backward_seeks() {
    let segments = vec![Segment {
        id: "s0".into(),
        start: 5.0,
        end: 10.0,
        text: "An ad.".into(),
    }];
    let labels = vec![Label {
        segment_id: "s0".into(),
        label: "ad".into(),
        evidence: "ad".into(),
    }];
    let spans = retained_intervals(&segments, &labels, 20.0).unwrap();
    assert_eq!(spans.len(), 2);
    assert_eq!(original_time(&spans, 6.0), 11.0);
    assert_eq!(processed_time(&spans, 11.0), 6.0);
    assert_eq!(processed_time(&spans, 8.0), 5.0);
    assert_eq!(original_time(&spans, 2.0), 2.0);
    assert!(retained_intervals(&segments, &labels, f64::NAN).is_err());
}

#[test]
fn complete_ad_blocks_remove_inter_sentence_gaps_but_preserve_editorial_breaks() {
    let segments: Vec<_> = (0..3)
        .map(|i| Segment {
            id: format!("s{i}"),
            start: (i * 2 + 1) as f64,
            end: (i * 2 + 2) as f64,
            text: "Source.".into(),
        })
        .collect();
    let mut labels: Vec<_> = segments
        .iter()
        .map(|s| Label {
            segment_id: s.id.clone(),
            label: "ad".into(),
            evidence: "Source".into(),
        })
        .collect();
    let spans = retained_intervals(&segments, &labels, 8.0).unwrap();
    assert_eq!(
        spans
            .iter()
            .map(|s| (s.original_start, s.original_end))
            .collect::<Vec<_>>(),
        [(0.0, 1.0), (6.0, 8.0)]
    );
    labels[1].label = "content".into();
    let spans = retained_intervals(&segments, &labels, 8.0).unwrap();
    assert_eq!(
        spans
            .iter()
            .map(|s| (s.original_start, s.original_end))
            .collect::<Vec<_>>(),
        [(0.0, 1.0), (2.0, 5.0), (6.0, 8.0)]
    );
}

#[test]
fn refined_boundaries_reject_overlap_and_preserve_neighboring_editorial() {
    use pods_backend::local_worker::apply_boundaries;
    let segments: Vec<_> = (0..8)
        .map(|i| Segment {
            id: format!("s{i}"),
            start: i as f64,
            end: (i + 1) as f64,
            text: "Source.".into(),
        })
        .collect();
    let labels = apply_boundaries(&segments, &[(2, 3), (5, 6)]).unwrap();
    assert_eq!(
        labels.iter().map(|l| l.label.as_str()).collect::<Vec<_>>(),
        ["content", "content", "ad", "ad", "content", "ad", "ad", "content"]
    );
    for blocks in [
        vec![(3, 2)],
        vec![(2, 8)],
        vec![(2, 4), (4, 6)],
        vec![(5, 6), (2, 3)],
    ] {
        assert!(apply_boundaries(&segments, &blocks).is_err());
    }
}

#[test]
fn two_devices_preserve_rewinds_and_merge_equal_edits_and_watermarks() {
    let (backend, _temp, manifest) = fixture();
    let apply = |device: &str, id: &str, entity: &str, field: &str, value: Value, base: i64| {
        apply_actions(&backend, json!({"client_id":device,"device_name":device,"actions":[{
            "id":id,"sequence":1,"entity":entity,"field":field,"value":value,"base_revision":base
        }]})).unwrap()["results"][0].clone()
    };
    let first = apply("iPhone","phone-progress","1","position",json!({"seconds":12,"artifact_hash":manifest.hash}),0);
    let first_revision = first["revision"].as_i64().unwrap();
    let stale = apply("iPad","stale-progress","1","position",json!({"seconds":2,"artifact_hash":manifest.hash}),0);
    assert_eq!(stale["status"],"conflict");
    assert_eq!(snapshot(&backend).unwrap()["episodes"][0]["position_secs"],12.0);
    let rewind = apply("iPad","intentional-rewind","1","position",json!({"seconds":2,"artifact_hash":manifest.hash}),first_revision);
    assert_eq!(rewind["status"],"applied");
    assert_eq!(snapshot(&backend).unwrap()["episodes"][0]["position_secs"],2.0);
    let same = apply("iPhone","same-rewind","1","position",json!({"seconds":2,"artifact_hash":manifest.hash}),0);
    assert_eq!(same["status"],"applied");
    assert_eq!(same["revision"],rewind["revision"]);
    let theme=apply("iPad","theme","settings","theme",json!("dark"),0);
    assert_eq!(apply("iPhone","theme-identical","settings","theme",json!("dark"),0)["revision"],theme["revision"]);
    apply("iPhone","cleared-9","settings","notifications_cleared_through",json!(9),0);
    assert_eq!(apply("iPad","cleared-3","settings","notifications_cleared_through",json!(3),0)["status"],"applied");
    let state=snapshot(&backend).unwrap();
    assert_eq!(state["settings"]["notifications_cleared_through"],9);
    assert_eq!(state["writers"]["1:position"]["device"],"iPad");
    assert_eq!(state["versions"]["1:position"],rewind["revision"]);
}

#[test]
fn youtube_sync_subscribes_a_channel_and_queues_one_video_for_listen() {
    let _guard = pods_backend::youtube::YT_DLP_TEST_LOCK.lock().unwrap();
    let previous = std::env::var("PODS_YT_DLP").ok();
    std::env::set_var("PODS_YT_DLP", "/usr/bin/false");
    let temp = tempfile::tempdir().unwrap();
    let fetcher = Arc::new(MockFeedFetcher::default());
    let channel = "UCabcdefghijklmnopqrstuv";
    let feed = pods_backend::youtube::channel_feed_url(channel);
    fetcher.set(
        &feed,
        format!(
            r#"<?xml version="1.0"?><feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns:media="http://search.yahoo.com/mrss/" xmlns="http://www.w3.org/2005/Atom"><title>Synced Channel</title><entry><yt:videoId>oldvideo111</yt:videoId><title>Old</title><published>2024-01-01T00:00:00+00:00</published></entry><entry><yt:videoId>midvideo222</yt:videoId><title>Mid</title><published>2024-02-01T00:00:00+00:00</published></entry><entry><yt:videoId>newvideo333</yt:videoId><title>New</title><published>2024-03-01T00:00:00+00:00</published></entry></feed>"#
        ),
    );
    let probe = pods_backend::youtube::MapProbe::default();
    probe.videos.lock().unwrap().insert(
        "abcdefghijk".into(),
        pods_backend::youtube::VideoMeta {
            video_id: "abcdefghijk".into(),
            channel_id: "UCzyxwvutsrqponmlkjihgfe".into(),
            channel_title: "Synced Channel".into(),
            title: "Single".into(),
            thumbnail: String::new(),
            published_at: 1_700_000_000,
            description: String::new(),
        },
    );
    let mut backend = Backend::with_data_root(
        Database::open_in_memory().unwrap(),
        fetcher,
        Arc::new(DisabledDirectory),
        Some(temp.path().to_owned()),
    );
    backend.local = true;
    backend.set_youtube_probe(Arc::new(probe));
    let page = format!("https://www.youtube.com/channel/{channel}");
    let subscribed = apply_actions(
        &backend,
        json!({"client_id":"phone","device_name":"iPhone","actions":[
            {"id":"sub","sequence":1,"entity":"subscription","field":page,"value":true,"base_revision":0},
            {"id":"vid","sequence":2,"entity":"listen","field":"https://youtu.be/abcdefghijk","value":true,"base_revision":0}
        ]}),
    )
    .unwrap();
    assert_eq!(subscribed["results"][0]["status"], "applied");
    assert_eq!(subscribed["results"][1]["status"], "applied");
    assert!(pods_backend::local_worker::step(&backend).unwrap());
    let visible: Vec<String> = {
        let conn = backend.db.lock().unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT e.guid FROM episodes e JOIN podcasts p ON p.id=e.podcast_id LEFT JOIN episode_state s ON s.episode_id=e.id WHERE p.is_subscribed=1 AND s.archived_at IS NULL ORDER BY e.guid",
            )
            .unwrap();
        stmt.query_map([], |row| row.get(0))
            .unwrap()
            .map(|row| row.unwrap())
            .collect()
    };
    assert_eq!(visible, vec!["midvideo222".to_string(), "newvideo333".to_string()]);
    let single: String = backend
        .db
        .scalar_string(
            "SELECT e.audio_url FROM episodes e JOIN listen_episodes l ON l.episode_id=e.id WHERE e.guid='abcdefghijk'",
            [],
        )
        .unwrap()
        .unwrap();
    assert_eq!(single, "youtube:abcdefghijk");
    let single_subscribed: i64 = backend
        .db
        .scalar_i64(
            "SELECT p.is_subscribed FROM podcasts p JOIN episodes e ON e.podcast_id=p.id WHERE e.guid='abcdefghijk'",
            [],
        )
        .unwrap()
        .unwrap();
    assert_eq!(single_subscribed, 0);
    match previous {
        Some(value) => std::env::set_var("PODS_YT_DLP", value),
        None => std::env::remove_var("PODS_YT_DLP"),
    }
}

#[test]
fn youtube_handle_resolves_na_channel_id_and_keeps_two_videos() {
    let _guard = pods_backend::youtube::YT_DLP_TEST_LOCK.lock().unwrap();
    let previous = std::env::var("PODS_YT_DLP").ok();
    let dir = tempfile::tempdir().unwrap();
    let bin = dir.path().join("yt-dlp");
    std::fs::write(
        &bin,
        r#"#!/usr/bin/env python3
import sys
args = sys.argv[1:]
url = args[-1] if args else ""
printed = args[args.index("--print") + 1] if "--print" in args else ""
if "watch?v=F3YXg7AaKWE" in url and printed == "channel_id":
    print("UCbRP3c757lWg9M-U7TyEkXA")
    sys.exit(0)
if printed == "channel_id":
    print("NA")
    sys.exit(0)
if "%(id)s" in printed:
    print(printed.replace("%(channel_id)s", "NA").replace("%(id)s", "F3YXg7AaKWE"))
    sys.exit(0)
sys.exit(1)
"#,
    )
    .unwrap();
    std::fs::set_permissions(&bin, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    std::env::set_var("PODS_YT_DLP", &bin);
    let channel = "UCbRP3c757lWg9M-U7TyEkXA";
    let feed = pods_backend::youtube::channel_feed_url(channel);
    let fetcher = Arc::new(MockFeedFetcher::default());
    fetcher.set(
        &feed,
        r#"<?xml version="1.0"?><feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns:media="http://search.yahoo.com/mrss/" xmlns="http://www.w3.org/2005/Atom"><title>Theo - t3.gg</title><entry><yt:videoId>oldvideo111</yt:videoId><title>Old</title><published>2024-01-01T00:00:00+00:00</published><media:group><media:description>Old notes</media:description></media:group></entry><entry><yt:videoId>midvideo222</yt:videoId><title>Mid</title><published>2024-02-01T00:00:00+00:00</published><media:group><media:description>Mid notes</media:description></media:group></entry><entry><yt:videoId>newvideo333</yt:videoId><title>New</title><published>2024-03-01T00:00:00+00:00</published><media:group><media:description>New notes</media:description></media:group></entry></feed>"#,
    );
    let temp = tempfile::tempdir().unwrap();
    let mut backend = Backend::with_data_root(
        Database::open_in_memory().unwrap(),
        fetcher,
        Arc::new(DisabledDirectory),
        Some(temp.path().to_owned()),
    );
    backend.local = true;
    backend
        .db
        .execute(
            "INSERT INTO podcasts(feed_url,title,created_at,is_subscribed) VALUES('https://www.youtube.com/@t3dotgg','www.youtube.com',0,1)",
            [],
        )
        .unwrap();
    pods_backend::local_worker::step(&backend).unwrap();
    let stored: String = backend
        .db
        .scalar_string("SELECT feed_url FROM podcasts WHERE is_subscribed=1", [])
        .unwrap()
        .unwrap();
    assert_eq!(stored, feed);
    let visible: Vec<String> = {
        let conn = backend.db.lock().unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT e.guid FROM episodes e JOIN podcasts p ON p.id=e.podcast_id LEFT JOIN episode_state s ON s.episode_id=e.id WHERE p.is_subscribed=1 AND s.archived_at IS NULL ORDER BY e.guid",
            )
            .unwrap();
        stmt.query_map([], |row| row.get(0))
            .unwrap()
            .map(|row| row.unwrap())
            .collect()
    };
    assert_eq!(visible, vec!["midvideo222".to_string(), "newvideo333".to_string()]);
    match previous {
        Some(value) => std::env::set_var("PODS_YT_DLP", value),
        None => std::env::remove_var("PODS_YT_DLP"),
    }
}

fn library_request(url: &str) -> HttpRequest {
    HttpRequest::new("POST", "/api/internal/library").with_json(&json!({ "url": url }))
}

#[test]
fn pipeline_menu_ingests_a_channel_a_video_and_a_podcast_without_a_session() {
    let _guard = pods_backend::youtube::YT_DLP_TEST_LOCK.lock().unwrap();
    let previous = std::env::var("PODS_YT_DLP").ok();
    std::env::set_var("PODS_YT_DLP", "/usr/bin/false");
    let (backend, _temp, _) = fixture();
    backend
        .auth
        .enable_passkey("test-reset-secret", "https://pods.mcgiv.dev");
    assert_eq!(
        backend.handle(HttpRequest::new("GET", "/api/sync")).status_code,
        401
    );

    let channel = backend.handle(library_request("@t3dotgg"));
    assert_eq!(channel.status_code, 201, "{}", String::from_utf8_lossy(&channel.body));
    let channel_body: Value = serde_json::from_slice(&channel.body).unwrap();
    assert_eq!(channel_body["kind"], "channel");
    let stored: String = backend
        .db
        .scalar_string("SELECT feed_url FROM podcasts WHERE feed_url LIKE '%t3dotgg'", [])
        .unwrap()
        .unwrap();
    assert_eq!(stored, "https://www.youtube.com/@t3dotgg");
    assert_eq!(
        backend
            .db
            .scalar_string("SELECT value FROM settings WHERE key='browser_refresh_requested'", [])
            .unwrap()
            .as_deref(),
        Some("true")
    );

    let again = backend.handle(library_request("@t3dotgg"));
    assert_eq!(again.status_code, 201, "{}", String::from_utf8_lossy(&again.body));

    let bare = backend.handle(library_request("UCabcdefghijklmnopqrstuv"));
    assert_eq!(bare.status_code, 201, "{}", String::from_utf8_lossy(&bare.body));
    let bare_url: String = backend
        .db
        .scalar_string(
            "SELECT feed_url FROM podcasts WHERE feed_url LIKE '%UCabcdefghijklmnopqrstuv'",
            [],
        )
        .unwrap()
        .unwrap();
    assert_eq!(bare_url, "https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv");

    let video = backend.handle(library_request("https://youtu.be/abcdefghijk"));
    assert_eq!(video.status_code, 201, "{}", String::from_utf8_lossy(&video.body));
    let video_body: Value = serde_json::from_slice(&video.body).unwrap();
    assert_eq!(video_body["kind"], "video");
    let queued: String = backend
        .db
        .scalar_string(
            "SELECT value FROM settings WHERE key='browser_youtube_listen'",
            [],
        )
        .unwrap()
        .unwrap();
    assert!(queued.contains("https://youtu.be/abcdefghijk"));

    let podcast = backend.handle(library_request("https://feeds.example/show.xml"));
    assert_eq!(podcast.status_code, 201, "{}", String::from_utf8_lossy(&podcast.body));
    let podcast_body: Value = serde_json::from_slice(&podcast.body).unwrap();
    assert_eq!(podcast_body["kind"], "podcast");
    let feed: String = backend
        .db
        .scalar_string(
            "SELECT feed_url FROM podcasts WHERE feed_url='https://feeds.example/show.xml'",
            [],
        )
        .unwrap()
        .unwrap();
    assert_eq!(feed, "https://feeds.example/show.xml");

    let playlist = backend.handle(library_request("https://www.youtube.com/playlist?list=PL123"));
    assert_eq!(playlist.status_code, 422);
    let playlist_body: Value = serde_json::from_slice(&playlist.body).unwrap();
    assert_eq!(playlist_body["error"], "Paste a podcast feed, a channel, a video, or an article.");

    let browser = backend.handle(
        library_request("https://feeds.example/other.xml").with_header("origin", "https://pods.mcgiv.dev"),
    );
    assert_eq!(browser.status_code, 403);

    match previous {
        Some(value) => std::env::set_var("PODS_YT_DLP", value),
        None => std::env::remove_var("PODS_YT_DLP"),
    }
}

fn article_fixture() -> (Backend, tempfile::TempDir, Arc<MockFeedFetcher>) {
    let temp = tempfile::tempdir().unwrap();
    let db = Database::open_in_memory().unwrap();
    let fetcher = Arc::new(MockFeedFetcher::default());
    let mut backend = Backend::with_data_root(
        db,
        fetcher.clone(),
        Arc::new(DisabledDirectory),
        Some(temp.path().to_owned()),
    );
    backend.local = true;
    (backend, temp, fetcher)
}

#[test]
fn pipeline_menu_queues_article_html_and_still_subscribes_feeds() {
    let (backend, _temp, fetcher) = article_fixture();
    fetcher.set(
        "https://example.com/story",
        "<!DOCTYPE html><html><head><title>Story</title></head><body><p>Hi</p></body></html>",
    );
    fetcher.set(
        "https://feeds.example/show.xml",
        r#"<rss><channel><title>Show</title><item><title>Episode</title><enclosure url="https://example.org/a"/></item></channel></rss>"#,
    );

    let article = backend.handle(library_request("https://example.com/story"));
    assert_eq!(article.status_code, 201, "{}", String::from_utf8_lossy(&article.body));
    let article_body: Value = serde_json::from_slice(&article.body).unwrap();
    assert_eq!(article_body["kind"], "article");
    let queued: String = backend
        .db
        .scalar_string("SELECT value FROM settings WHERE key='browser_article_listen'", [])
        .unwrap()
        .unwrap();
    assert!(queued.contains("https://example.com/story"));

    let feed = backend.handle(library_request("https://feeds.example/show.xml"));
    assert_eq!(feed.status_code, 201, "{}", String::from_utf8_lossy(&feed.body));
    let feed_body: Value = serde_json::from_slice(&feed.body).unwrap();
    assert_eq!(feed_body["kind"], "podcast");

    // An unreachable URL keeps the legacy behavior: subscribe and let refresh report.
    let unreachable = backend.handle(library_request("https://down.example/feed"));
    assert_eq!(unreachable.status_code, 201);
    let unreachable_body: Value = serde_json::from_slice(&unreachable.body).unwrap();
    assert_eq!(unreachable_body["kind"], "podcast");
}

#[test]
fn article_drain_creates_episode_and_parks_job_without_burning_attempts() {
    let (backend, _temp, _) = article_fixture();
    pods_backend::articles::enqueue(&backend.db, "https://example.com/story").unwrap();
    assert!(pods_backend::local_worker::step(&backend).unwrap());

    let episode: i64 = backend
        .db
        .scalar_i64("SELECT id FROM episodes WHERE guid='https://example.com/story'", [])
        .unwrap()
        .unwrap();
    let show: String = backend
        .db
        .scalar_string("SELECT p.title FROM podcasts p JOIN episodes e ON e.podcast_id=p.id WHERE e.id=?", [episode])
        .unwrap()
        .unwrap();
    assert_eq!(show, "Articles");
    let audio_url: String = backend
        .db
        .scalar_string("SELECT audio_url FROM episodes WHERE id=?", [episode])
        .unwrap()
        .unwrap();
    assert_eq!(audio_url, "article:https://example.com/story");
    let queued: Option<i64> = backend
        .db
        .scalar_i64("SELECT COUNT(*) FROM browser_pending_jobs WHERE episode_id=?", [episode])
        .unwrap();
    assert_eq!(queued, Some(1));

    let stage: String = backend
        .db
        .scalar_string("SELECT stage FROM browser_jobs WHERE episode_id=?", [episode])
        .unwrap()
        .unwrap();
    assert_eq!(stage, "fetching");
    let attempts: i64 = backend
        .db
        .scalar_i64("SELECT attempts FROM browser_jobs WHERE episode_id=?", [episode])
        .unwrap()
        .unwrap();
    assert_eq!(attempts, 0);
    let error: String = backend
        .db
        .scalar_string("SELECT error FROM browser_jobs WHERE episode_id=?", [episode])
        .unwrap()
        .unwrap();
    assert_eq!(error, "article_pending");
    let deferred: i64 = backend
        .db
        .scalar_i64("SELECT next_retry_at > 0 FROM browser_jobs WHERE episode_id=?", [episode])
        .unwrap()
        .unwrap();
    assert_eq!(deferred, 1);
    let notices: i64 = backend
        .db
        .scalar_i64("SELECT COUNT(*) FROM browser_processing_notifications", [])
        .unwrap()
        .unwrap();
    assert_eq!(notices, 0);

    // Re-adding the same URL re-queues without touching resolved metadata.
    backend
        .db
        .execute("UPDATE episodes SET title='Real Title' WHERE id=?", [episode])
        .unwrap();
    pods_backend::articles::enqueue(&backend.db, "https://example.com/story").unwrap();
    pods_backend::local_worker::step(&backend).unwrap();
    let title: String = backend
        .db
        .scalar_string("SELECT title FROM episodes WHERE id=?", [episode])
        .unwrap()
        .unwrap();
    assert_eq!(title, "Real Title");
    let count: i64 = backend
        .db
        .scalar_i64("SELECT COUNT(*) FROM episodes WHERE guid='https://example.com/story'", [])
        .unwrap()
        .unwrap();
    assert_eq!(count, 1);
}

fn feedback_payload(id: &str, sequence: i64, report: &str, value: Value) -> Value {
    json!({"client_id":"phone","device_name":"iPhone","actions":[{
        "id":id,"sequence":sequence,"entity":"feedback","field":report,
        "value":value,"base_revision":0
    }]})
}

#[test]
fn feedback_action_stores_report_for_dispatch() {
    let (backend, _temp, _) = fixture();
    let result = apply_actions(
        &backend,
        feedback_payload(
            "op-1",
            1,
            "report-1",
            json!({"kind":"bug","body":"  crash on launch  ","created_at":1700000000}),
        ),
    )
    .unwrap();
    assert_eq!(result["results"][0]["status"], "applied");
    assert!(result["results"][0]["revision"].as_i64().unwrap() > 0);
    let row: (String, String, String, String, i64) = backend
        .db
        .lock()
        .unwrap()
        .query_row(
            "SELECT kind, body, device, status, created_at FROM browser_feedback WHERE id='report-1'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
        )
        .unwrap();
    assert_eq!(
        row,
        (
            "bug".to_string(),
            "crash on launch".to_string(),
            "iPhone".to_string(),
            "queued".to_string(),
            1700000000
        )
    );
}

#[test]
fn feedback_action_rejects_invalid_reports() {
    let (backend, _temp, _) = fixture();
    for (name, value, message) in [
        ("kind", json!({"kind":"rant","body":"nope"}), "unknown report kind"),
        ("body", json!({"kind":"bug","body":"   "}), "report body required"),
        (
            "length",
            json!({"kind":"feature","body":"x".repeat(5000)}),
            "report too long",
        ),
    ] {
        let error = apply_actions(&backend, feedback_payload(name, 1, name, value)).unwrap_err();
        assert_eq!(error.to_string(), message, "{name}");
    }
    let count: i64 = backend
        .db
        .scalar_i64("SELECT COUNT(*) FROM browser_feedback", [])
        .unwrap()
        .unwrap();
    assert_eq!(count, 0);
}

#[test]
fn feedback_redelivery_is_idempotent() {
    let (backend, _temp, _) = fixture();
    let payload = feedback_payload("op-1", 1, "report-1", json!({"kind":"feature","body":"dark mode"}));
    let first = apply_actions(&backend, payload.clone()).unwrap();
    assert_eq!(first, apply_actions(&backend, payload).unwrap());
    let count: i64 = backend
        .db
        .scalar_i64("SELECT COUNT(*) FROM browser_feedback", [])
        .unwrap()
        .unwrap();
    assert_eq!(count, 1);
}

#[test]
fn snapshot_includes_feedback_statuses() {
    let (backend, _temp, _) = fixture();
    backend
        .db
        .execute(
            "INSERT INTO browser_feedback(id,kind,body,device,client_id,created_at,status) VALUES('r1','bug','b','iPhone','phone',10,'done')",
            [],
        )
        .unwrap();
    let feedback = &snapshot(&backend).unwrap()["feedback"];
    assert_eq!(
        feedback,
        &json!([{"id":"r1","kind":"bug","status":"done","created_at":10}])
    );
}

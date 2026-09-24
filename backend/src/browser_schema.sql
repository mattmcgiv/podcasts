CREATE TABLE IF NOT EXISTS browser_publications (
    episode_id INTEGER PRIMARY KEY REFERENCES episodes(id) ON DELETE CASCADE,
    manifest_json TEXT NOT NULL,
    notes_json TEXT NOT NULL DEFAULT '[]',
    published_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS browser_jobs (
    episode_id INTEGER PRIMARY KEY REFERENCES episodes(id) ON DELETE CASCADE,
    stage TEXT NOT NULL DEFAULT 'queued',
    attempts INTEGER NOT NULL DEFAULT 0,
    next_retry_at INTEGER NOT NULL DEFAULT 0,
    error TEXT,
    priority INTEGER NOT NULL DEFAULT 0,
    completed_units INTEGER,
    total_units INTEGER
);
CREATE TABLE IF NOT EXISTS browser_operations (
    operation_id TEXT PRIMARY KEY,
    client_id TEXT NOT NULL,
    sequence INTEGER NOT NULL,
    payload TEXT NOT NULL,
    result TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_browser_operations_client_sequence
    ON browser_operations(client_id, sequence);
CREATE TABLE IF NOT EXISTS browser_field_versions (
    entity TEXT NOT NULL,
    field TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(entity, field)
);
CREATE TABLE IF NOT EXISTS browser_clock (id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS browser_field_writers (
    entity TEXT NOT NULL, field TEXT NOT NULL, device TEXT NOT NULL,
    updated_at INTEGER NOT NULL, PRIMARY KEY(entity, field)
);
-- Last sync moment per device. Pulls and action posts both refresh last_sync_at;
-- only action posts move last_actions_at. One row per client_id, no retention concern.
CREATE TABLE IF NOT EXISTS browser_sync_devices (
    client_id TEXT PRIMARY KEY,
    device TEXT NOT NULL,
    last_sync_at INTEGER NOT NULL,
    sync_count INTEGER NOT NULL DEFAULT 0,
    last_actions_at INTEGER NOT NULL DEFAULT 0
);
INSERT OR IGNORE INTO browser_clock VALUES(1,0);
CREATE TABLE IF NOT EXISTS browser_artifacts (
    hash TEXT PRIMARY KEY,
    episode_id INTEGER NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
    manifest_json TEXT NOT NULL
);
INSERT OR IGNORE INTO browser_artifacts SELECT json_extract(manifest_json,'$.hash'),episode_id,manifest_json FROM browser_publications;

-- Durable Listen failure notices. Newest id is the newest event.
-- Retention is 100 rows. The insert trigger prunes oldest ids after each insert.
CREATE TABLE IF NOT EXISTS browser_processing_notifications (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    episode_id INTEGER NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
    category TEXT NOT NULL,
    failed_stage TEXT NOT NULL,
    message TEXT NOT NULL,
    outcome TEXT NOT NULL CHECK(outcome IN ('retry','blocked')),
    created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_browser_processing_notifications_newest
    ON browser_processing_notifications(id DESC);
CREATE TRIGGER IF NOT EXISTS browser_processing_notifications_retain_100
AFTER INSERT ON browser_processing_notifications
BEGIN
    DELETE FROM browser_processing_notifications
    WHERE id NOT IN (
        SELECT id FROM browser_processing_notifications ORDER BY id DESC LIMIT 100
    );
END;

-- User-typed feature requests and bug reports synced from the browser.
-- status: queued (awaiting pi dispatch), running (pi child active),
-- done (pi exited 0), failed (terminal dispatch failure).
CREATE TABLE IF NOT EXISTS browser_feedback (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL CHECK(kind IN ('feature','bug')),
    body TEXT NOT NULL,
    device TEXT NOT NULL,
    client_id TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'queued' CHECK(status IN ('queued','running','done','failed')),
    attempts INTEGER NOT NULL DEFAULT 0,
    next_at INTEGER NOT NULL DEFAULT 0,
    started_at INTEGER NOT NULL DEFAULT 0,
    result TEXT
);
CREATE INDEX IF NOT EXISTS idx_browser_feedback_dispatch
    ON browser_feedback(status, next_at, created_at);

-- Spoken notes waiting on local Whisper. The audio file lives under voice/{id}.audio.
-- The JSON sync channel never carries these bytes. A finished transcript is not a
-- report until the browser submits it through the feedback action.
-- status: queued, running, done (transcript ready to confirm), failed.
CREATE TABLE IF NOT EXISTS browser_voice_notes (
    id TEXT PRIMARY KEY,
    client_id TEXT NOT NULL,
    mime TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'queued' CHECK(status IN ('queued','running','done','failed')),
    transcript TEXT,
    error TEXT,
    attempts INTEGER NOT NULL DEFAULT 0,
    next_at INTEGER NOT NULL DEFAULT 0,
    started_at INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_browser_voice_notes_dispatch
    ON browser_voice_notes(status, next_at, created_at);

-- Recreate views on every open. CREATE VIEW IF NOT EXISTS keeps a stale definition.
DROP VIEW IF EXISTS browser_pending_jobs;
DROP VIEW IF EXISTS browser_episode_catalog;
-- The old RSS parser imported CDATA wrappers as part of GUIDs. Keep those
-- historical rows intact, but suppress untouched duplicates of a canonical ID.
CREATE VIEW browser_episode_catalog AS
SELECT e.* FROM episodes e WHERE NOT (
    substr(e.guid,1,9)='<![CDATA[' AND substr(e.guid,-3)=']]>'
    AND EXISTS(SELECT 1 FROM episodes canonical WHERE canonical.podcast_id=e.podcast_id
        AND canonical.guid=substr(e.guid,10,length(e.guid)-12))
    AND NOT EXISTS(SELECT 1 FROM episode_state WHERE episode_id=e.id)
    AND NOT EXISTS(SELECT 1 FROM listen_episodes WHERE episode_id=e.id)
    AND NOT EXISTS(SELECT 1 FROM browser_publications WHERE episode_id=e.id)
);
CREATE VIEW browser_pending_jobs AS
SELECT j.* FROM browser_jobs j JOIN browser_episode_catalog e ON e.id=j.episode_id
JOIN podcasts p ON p.id=e.podcast_id LEFT JOIN episode_state s ON s.episode_id=e.id
WHERE (p.is_subscribed=1 OR EXISTS(SELECT 1 FROM listen_episodes WHERE episode_id=e.id))
AND s.played_at IS NULL AND s.archived_at IS NULL AND j.stage!='ready';
-- Four failed attempts is terminal. Matches local_worker::MAX_FAILED_ATTEMPTS.
UPDATE browser_jobs SET stage='blocked' WHERE attempts>=4 AND stage IN ('review','retry');
UPDATE browser_jobs SET stage='retry' WHERE stage='review' AND attempts<4;
UPDATE browser_jobs SET error='automatic processing failed validation' WHERE error LIKE '%requires review%';

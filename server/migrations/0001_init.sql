CREATE TABLE podcasts (
    id INTEGER PRIMARY KEY,
    feed_url TEXT NOT NULL UNIQUE,
    title TEXT NOT NULL DEFAULT '',
    description TEXT NOT NULL DEFAULT '',
    image_url TEXT NOT NULL DEFAULT '',
    site_url TEXT NOT NULL DEFAULT '',
    last_fetched_at INTEGER,
    created_at INTEGER NOT NULL
);

CREATE TABLE episodes (
    id INTEGER PRIMARY KEY,
    podcast_id INTEGER NOT NULL REFERENCES podcasts(id) ON DELETE CASCADE,
    guid TEXT NOT NULL,
    title TEXT NOT NULL DEFAULT '',
    notes_html TEXT NOT NULL DEFAULT '',
    audio_url TEXT NOT NULL,
    duration_secs INTEGER,
    published_at INTEGER NOT NULL DEFAULT 0,
    image_url TEXT NOT NULL DEFAULT '',
    UNIQUE (podcast_id, guid)
);

CREATE INDEX idx_episodes_pub ON episodes (published_at DESC, id DESC);
CREATE INDEX idx_episodes_podcast ON episodes (podcast_id, published_at DESC);

-- played_at: explicitly or automatically marked played (the "Played" view).
-- archived_at: silently out of Recent without being "played" (back-catalog
-- beyond the newest 2 at subscribe time). Resetting played also clears it.
CREATE TABLE episode_state (
    episode_id INTEGER PRIMARY KEY REFERENCES episodes(id) ON DELETE CASCADE,
    position_secs REAL NOT NULL DEFAULT 0,
    played_at INTEGER,
    archived_at INTEGER,
    updated_at INTEGER NOT NULL
);

CREATE TABLE settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- Standalone FTS5 table, maintained from Rust (no triggers): rowid = episodes.id
CREATE VIRTUAL TABLE episodes_fts USING fts5(title, notes);

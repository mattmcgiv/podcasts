CREATE TABLE IF NOT EXISTS podcasts (
        id INTEGER PRIMARY KEY,
        feed_url TEXT NOT NULL UNIQUE,
        title TEXT NOT NULL DEFAULT '',
        description TEXT NOT NULL DEFAULT '',
        image_url TEXT NOT NULL DEFAULT '',
        site_url TEXT NOT NULL DEFAULT '',
        last_fetched_at INTEGER,
        is_subscribed INTEGER NOT NULL DEFAULT 1,
        created_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS episodes (
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

    CREATE INDEX IF NOT EXISTS idx_episodes_pub ON episodes (published_at DESC, id DESC);
    CREATE INDEX IF NOT EXISTS idx_episodes_podcast ON episodes (podcast_id, published_at DESC);

    CREATE TABLE IF NOT EXISTS follows (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL COLLATE NOCASE UNIQUE,
        aliases_json TEXT NOT NULL,
        last_checked_at INTEGER,
        created_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS follow_candidates (
        id INTEGER PRIMARY KEY,
        follow_id INTEGER NOT NULL REFERENCES follows(id) ON DELETE CASCADE,
        source_episode_key TEXT NOT NULL,
        feed_url TEXT NOT NULL,
        feed_title TEXT NOT NULL,
        feed_image_url TEXT NOT NULL,
        guid TEXT NOT NULL,
        title TEXT NOT NULL,
        description TEXT NOT NULL,
        audio_url TEXT NOT NULL,
        duration_secs INTEGER,
        published_at INTEGER NOT NULL,
        image_url TEXT NOT NULL,
        evidence TEXT NOT NULL,
        confidence TEXT NOT NULL CHECK (confidence IN ('high', 'review')),
        status TEXT NOT NULL CHECK (status IN ('pending', 'accepted', 'rejected')) DEFAULT 'pending',
        created_at INTEGER NOT NULL,
        UNIQUE (follow_id, source_episode_key)
    );

    CREATE INDEX IF NOT EXISTS idx_follow_candidates_pending ON follow_candidates (follow_id, status, published_at DESC);
    CREATE UNIQUE INDEX IF NOT EXISTS idx_follow_candidates_identity ON follow_candidates (follow_id, feed_url, guid);

    CREATE TABLE IF NOT EXISTS follow_episodes (
        follow_id INTEGER NOT NULL REFERENCES follows(id) ON DELETE CASCADE,
        episode_id INTEGER NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
        PRIMARY KEY (follow_id, episode_id)
    );

    CREATE TABLE IF NOT EXISTS listen_episodes (
        episode_id INTEGER PRIMARY KEY REFERENCES episodes(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS episode_state (
        episode_id INTEGER PRIMARY KEY REFERENCES episodes(id) ON DELETE CASCADE,
        position_secs REAL NOT NULL DEFAULT 0,
        played_at INTEGER,
        archived_at INTEGER,
        updated_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS feed_refresh_state (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        last_attempt_at INTEGER,
        last_success_at INTEGER,
        last_source TEXT,
        last_refreshed INTEGER NOT NULL DEFAULT 0,
        last_errors INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS feed_refresh_runs (
        id INTEGER PRIMARY KEY,
        source TEXT NOT NULL,
        started_at INTEGER NOT NULL,
        finished_at INTEGER NOT NULL,
        refreshed INTEGER NOT NULL,
        errors INTEGER NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_feed_refresh_runs_finished ON feed_refresh_runs(finished_at DESC);

    -- Unlike feed_refresh_runs, this ledger records the start before network I/O.
    -- A subsequent process can therefore close a run interrupted by suspension,
    -- termination, or a crash instead of leaving the refresh state ambiguous.
    CREATE TABLE IF NOT EXISTS feed_refresh_attempts (
        id INTEGER PRIMARY KEY,
        source TEXT NOT NULL,
        started_at INTEGER NOT NULL,
        finished_at INTEGER,
        refreshed INTEGER,
        errors INTEGER,
        outcome TEXT NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_feed_refresh_attempts_outcome_started
        ON feed_refresh_attempts(outcome, started_at DESC);

    CREATE TABLE IF NOT EXISTS feed_http_cache (
        podcast_id INTEGER PRIMARY KEY REFERENCES podcasts(id) ON DELETE CASCADE,
        etag TEXT,
        last_modified TEXT
    );
    CREATE TABLE IF NOT EXISTS feed_parser_state (
        podcast_id INTEGER PRIMARY KEY REFERENCES podcasts(id) ON DELETE CASCADE,
        version INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS ad_removal_jobs (
        id TEXT PRIMARY KEY,
        episode_id INTEGER NOT NULL UNIQUE REFERENCES episodes(id) ON DELETE CASCADE,
        podcast_id INTEGER NOT NULL REFERENCES podcasts(id) ON DELETE CASCADE,
        stage TEXT NOT NULL,
        blocking_reason TEXT,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        failed_stage TEXT,
        last_error_code TEXT,
        last_error_message TEXT,
        retry_eligible INTEGER NOT NULL DEFAULT 1,
        next_retry_at INTEGER,
        audio_relative_path TEXT,
        audio_sha256 TEXT,
        audio_byte_count INTEGER,
        downloaded_at INTEGER,
        download_resume_relative_path TEXT,
        transcriber_version TEXT,
        transcribed_at INTEGER,
        classification_run_id TEXT,
        classifier_version TEXT,
        prompt_version TEXT,
        classifier_quantization TEXT,
        classified_at INTEGER,
        enrolled_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_ad_removal_jobs_stage
        ON ad_removal_jobs(stage, blocking_reason, enrolled_at);

    CREATE TABLE IF NOT EXISTS ad_removal_daily_usage (
        day_start INTEGER NOT NULL,
        episode_id INTEGER NOT NULL,
        reserved_at INTEGER NOT NULL,
        PRIMARY KEY (day_start, episode_id)
    );

    CREATE TABLE IF NOT EXISTS ad_transcript_segments (
        episode_id INTEGER NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
        segment_id TEXT NOT NULL,
        segment_index INTEGER NOT NULL,
        language TEXT NOT NULL,
        start_time REAL NOT NULL,
        end_time REAL NOT NULL,
        text TEXT NOT NULL,
        PRIMARY KEY (episode_id, segment_id),
        UNIQUE (episode_id, segment_index)
    );

    CREATE TABLE IF NOT EXISTS episode_show_notes (
        episode_id INTEGER NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
        chapter_index INTEGER NOT NULL,
        segment_id TEXT NOT NULL,
        start_time REAL NOT NULL,
        title TEXT NOT NULL,
        summary TEXT NOT NULL,
        model_id TEXT NOT NULL,
        prompt_version TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (episode_id, chapter_index),
        UNIQUE (episode_id, segment_id)
    );

    CREATE INDEX IF NOT EXISTS idx_episode_show_notes_episode_time
        ON episode_show_notes(episode_id, start_time);

    CREATE TABLE IF NOT EXISTS ad_skip_ranges (
        id TEXT PRIMARY KEY,
        episode_id INTEGER NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
        start_segment_id TEXT NOT NULL,
        end_segment_id TEXT NOT NULL,
        start_time REAL NOT NULL,
        end_time REAL NOT NULL,
        confidence REAL NOT NULL,
        reason TEXT NOT NULL,
        classifier_version TEXT NOT NULL,
        prompt_version TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        disabled INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (episode_id, start_segment_id)
            REFERENCES ad_transcript_segments(episode_id, segment_id) ON DELETE CASCADE,
        FOREIGN KEY (episode_id, end_segment_id)
            REFERENCES ad_transcript_segments(episode_id, segment_id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_ad_skip_ranges_episode_time
        ON ad_skip_ranges(episode_id, start_time, end_time);

    CREATE TABLE IF NOT EXISTS ad_classification_windows (
        run_id TEXT NOT NULL,
        episode_id INTEGER NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
        window_index INTEGER NOT NULL,
        segment_ids_json TEXT NOT NULL,
        correction_ids_json TEXT NOT NULL,
        prompt TEXT NOT NULL,
        raw_output TEXT NOT NULL,
        schema_valid INTEGER NOT NULL,
        validation_error TEXT,
        labels_json TEXT NOT NULL,
        model_id TEXT NOT NULL,
        model_revision TEXT NOT NULL,
        quantization TEXT NOT NULL,
        prompt_version TEXT NOT NULL,
        max_context_tokens INTEGER NOT NULL,
        max_output_tokens INTEGER NOT NULL,
        temperature REAL NOT NULL,
        top_p REAL NOT NULL,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (run_id, window_index)
    );

    CREATE INDEX IF NOT EXISTS idx_ad_classification_windows_episode
        ON ad_classification_windows(episode_id, created_at, window_index);

    CREATE TABLE IF NOT EXISTS ad_corrections (
        id TEXT PRIMARY KEY,
        podcast_id INTEGER NOT NULL REFERENCES podcasts(id) ON DELETE CASCADE,
        source_episode_id INTEGER NOT NULL,
        transcript_window TEXT NOT NULL,
        classification_context TEXT NOT NULL,
        classifier_version TEXT NOT NULL,
        prompt_version TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        active INTEGER NOT NULL DEFAULT 1
    );

    CREATE INDEX IF NOT EXISTS idx_ad_corrections_podcast_active
        ON ad_corrections(podcast_id, active, created_at);

    -- Immutable DeepSeek billing telemetry. No prompts, transcripts, or model text.
    -- episode_key is feed_url + guid so deleted episode IDs cannot be reused.
    CREATE TABLE IF NOT EXISTS deepseek_usage (
        id INTEGER PRIMARY KEY,
        record_id TEXT NOT NULL UNIQUE,
        episode_id INTEGER NOT NULL,
        episode_key TEXT NOT NULL,
        duration_secs INTEGER,
        request_kind TEXT NOT NULL CHECK (request_kind IN ('ad_detection', 'show_notes')),
        model TEXT NOT NULL,
        input_tokens INTEGER,
        cached_input_tokens INTEGER,
        output_tokens INTEGER,
        cost_usd REAL,
        created_at INTEGER NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_deepseek_usage_episode
        ON deepseek_usage(episode_id, created_at);
    CREATE INDEX IF NOT EXISTS idx_deepseek_usage_episode_key
        ON deepseek_usage(episode_key, created_at);
    CREATE UNIQUE INDEX IF NOT EXISTS idx_deepseek_usage_record_id
        ON deepseek_usage(record_id);

    CREATE TABLE IF NOT EXISTS ad_artifact_cleanup (
        relative_path TEXT PRIMARY KEY,
        reason TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT
    );

    CREATE VIRTUAL TABLE IF NOT EXISTS episodes_fts USING fts5(title, notes);

    CREATE TABLE IF NOT EXISTS passkey_credentials (
        credential_id TEXT PRIMARY KEY,
        user_handle TEXT NOT NULL,
        public_key_json TEXT NOT NULL,
        counter INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS auth_sessions (
        token_hash TEXT PRIMARY KEY,
        created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS auth_enroll_tokens (
        token_hash TEXT PRIMARY KEY,
        expires_at INTEGER NOT NULL,
        used INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS auth_webauthn_state (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        state_json TEXT NOT NULL,
        expires_at INTEGER NOT NULL
    );

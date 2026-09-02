import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case null
}

final class PodsDatabase {
    private let lock = NSRecursiveLock()
    private var db: OpaquePointer?

    init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            defer { sqlite3_close(handle) }
            throw PodsBackendError.database("could not open database")
        }
        db = handle
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
        try installSchemaIfNeeded()
    }

    deinit {
        sqlite3_close(db)
    }

    func installSchemaIfNeeded() throws {
        try executeScript(Self.schemaSQL)
        try addColumnIfMissing(table: "podcasts", column: "is_subscribed", definition: "INTEGER NOT NULL DEFAULT 1")
        try addColumnIfMissing(table: "ad_removal_jobs", column: "audio_relative_path", definition: "TEXT")
        try addColumnIfMissing(table: "ad_removal_jobs", column: "audio_sha256", definition: "TEXT")
        try addColumnIfMissing(table: "ad_removal_jobs", column: "audio_byte_count", definition: "INTEGER")
        try addColumnIfMissing(table: "ad_removal_jobs", column: "downloaded_at", definition: "INTEGER")
        try addColumnIfMissing(table: "ad_removal_jobs", column: "download_resume_relative_path", definition: "TEXT")
        try addColumnIfMissing(table: "ad_removal_jobs", column: "transcriber_version", definition: "TEXT")
        try addColumnIfMissing(table: "ad_removal_jobs", column: "transcribed_at", definition: "INTEGER")
        try addColumnIfMissing(table: "ad_removal_jobs", column: "classification_run_id", definition: "TEXT")
        try addColumnIfMissing(table: "ad_removal_jobs", column: "classifier_version", definition: "TEXT")
        try addColumnIfMissing(table: "ad_removal_jobs", column: "prompt_version", definition: "TEXT")
        try addColumnIfMissing(table: "ad_removal_jobs", column: "classifier_quantization", definition: "TEXT")
        try addColumnIfMissing(table: "ad_removal_jobs", column: "classified_at", definition: "INTEGER")
    }

    func withTransaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }

        try executeLocked("BEGIN IMMEDIATE", [])
        do {
            let result = try body()
            try executeLocked("COMMIT", [])
            return result
        } catch {
            try? executeLocked("ROLLBACK", [])
            throw error
        }
    }

    func execute(_ sql: String, _ values: [SQLiteValue] = []) throws {
        lock.lock()
        defer { lock.unlock() }
        try executeLocked(sql, values)
    }

    func executeScript(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? lastErrorMessage()
            sqlite3_free(error)
            throw PodsBackendError.database(message)
        }
    }

    func query<T>(_ sql: String, _ values: [SQLiteValue] = [], map: (OpaquePointer?) throws -> T) throws -> [T] {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw PodsBackendError.database(lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)

        var rows: [T] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                rows.append(try map(statement))
            } else if code == SQLITE_DONE {
                return rows
            } else {
                throw PodsBackendError.database(lastErrorMessage())
            }
        }
    }

    func scalarInt64(_ sql: String, _ values: [SQLiteValue] = []) throws -> Int64? {
        try query(sql, values) { statement in
            sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 0)
        }.first ?? nil
    }

    func lastInsertRowID() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return sqlite3_last_insert_rowid(db)
    }

    private func executeLocked(_ sql: String, _ values: [SQLiteValue]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw PodsBackendError.database(lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)

        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else {
            throw PodsBackendError.database(lastErrorMessage())
        }
    }

    private func addColumnIfMissing(table: String, column: String, definition: String) throws {
        let columns = try query("PRAGMA table_info(\(table))") { statement in
            sqliteString(statement, 1)
        }
        guard !columns.contains(column) else { return }
        try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer?) throws {
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let code: Int32
            switch value {
            case .int(let value):
                code = sqlite3_bind_int64(statement, position, value)
            case .double(let value):
                code = sqlite3_bind_double(statement, position, value)
            case .text(let value):
                code = sqlite3_bind_text(statement, position, value, -1, sqliteTransient)
            case .null:
                code = sqlite3_bind_null(statement, position)
            }
            guard code == SQLITE_OK else {
                throw PodsBackendError.database(lastErrorMessage())
            }
        }
    }

    private func lastErrorMessage() -> String {
        if let message = sqlite3_errmsg(db) {
            return String(cString: message)
        }
        return "unknown sqlite error"
    }

    private static let schemaSQL = """
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

    CREATE TABLE IF NOT EXISTS ad_artifact_cleanup (
        relative_path TEXT PRIMARY KEY,
        reason TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT
    );

    CREATE VIRTUAL TABLE IF NOT EXISTS episodes_fts USING fts5(title, notes);
    """
}

func sqliteString(_ statement: OpaquePointer?, _ index: Int32) -> String {
    guard let text = sqlite3_column_text(statement, index) else {
        return ""
    }
    return String(cString: text)
}

func sqliteOptionalString(_ statement: OpaquePointer?, _ index: Int32) -> String? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqliteString(statement, index)
}

func sqliteOptionalInt64(_ statement: OpaquePointer?, _ index: Int32) -> Int64? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, index)
}

use crate::error::Error;
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use std::path::Path;
use std::sync::{Mutex, MutexGuard};

pub struct Database {
    conn: Mutex<Connection>,
}

impl Database {
    pub fn open(path: &Path) -> Result<Self, Error> {
        let conn = Connection::open(path)?;
        conn.execute_batch("PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL;")?;
        conn.execute_batch(include_str!("schema.sql"))?;
        migrate_audio_metadata_columns(&conn)?;
        conn.execute_batch(include_str!("browser_schema.sql"))?;
        migrate_browser_progress(&conn)?;
        migrate_browser_operation_identity(&conn)?;
        migrate_browser_feedback_pipeline(&conn)?;
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    pub fn open_in_memory() -> Result<Self, Error> {
        let conn = Connection::open_in_memory()?;
        conn.execute_batch("PRAGMA foreign_keys = ON;")?;
        conn.execute_batch(include_str!("schema.sql"))?;
        migrate_audio_metadata_columns(&conn)?;
        conn.execute_batch(include_str!("browser_schema.sql"))?;
        migrate_browser_progress(&conn)?;
        migrate_browser_operation_identity(&conn)?;
        migrate_browser_feedback_pipeline(&conn)?;
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    pub fn lock(&self) -> Result<MutexGuard<'_, Connection>, Error> {
        self.conn
            .lock()
            .map_err(|_| Error::Database("database lock poisoned".into()))
    }

    pub fn with_transaction<T, F>(&self, f: F) -> Result<T, Error>
    where
        F: FnOnce(&Transaction<'_>) -> Result<T, Error>,
    {
        let mut conn = self.lock()?;
        let tx = conn.transaction()?;
        let result = f(&tx)?;
        tx.commit()?;
        Ok(result)
    }

    pub fn execute(&self, sql: &str, params: impl rusqlite::Params) -> Result<usize, Error> {
        Ok(self.lock()?.execute(sql, params)?)
    }

    pub fn last_insert_rowid(&self) -> Result<i64, Error> {
        Ok(self.lock()?.last_insert_rowid())
    }

    pub fn scalar_i64(&self, sql: &str, params: impl rusqlite::Params) -> Result<Option<i64>, Error> {
        let conn = self.lock()?;
        let mut stmt = conn.prepare(sql)?;
        Ok(stmt.query_row(params, |row| row.get::<_, Option<i64>>(0)).optional()?.flatten())
    }

    pub fn scalar_string(&self, sql: &str, params: impl rusqlite::Params) -> Result<Option<String>, Error> {
        let conn = self.lock()?;
        let mut stmt = conn.prepare(sql)?;
        Ok(stmt.query_row(params, |row| row.get::<_, String>(0)).optional()?)
    }
}

fn migrate_browser_operation_identity(conn: &Connection) -> Result<(), rusqlite::Error> {
    let sql: Option<String> = conn
        .query_row(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='browser_operations'",
            [],
            |row| row.get(0),
        )
        .optional()?;
    let Some(sql) = sql else { return Ok(()) };
    if !sql.contains("UNIQUE") || !sql.contains("client_id") || !sql.contains("sequence") {
        return Ok(());
    }
    // PRIMARY KEY already implies UNIQUE(operation_id). Only rebuild when sequence
    // identity is still a unique constraint; retries key off operation_id.
    if !sql.contains("UNIQUE(client_id, sequence)") && !sql.contains("UNIQUE (client_id, sequence)") {
        return Ok(());
    }
    conn.execute_batch(
        "CREATE TABLE browser_operations_v2 (
            operation_id TEXT PRIMARY KEY,
            client_id TEXT NOT NULL,
            sequence INTEGER NOT NULL,
            payload TEXT NOT NULL,
            result TEXT NOT NULL
        );
        INSERT INTO browser_operations_v2 SELECT operation_id, client_id, sequence, payload, result FROM browser_operations;
        DROP TABLE browser_operations;
        ALTER TABLE browser_operations_v2 RENAME TO browser_operations;
        CREATE INDEX IF NOT EXISTS idx_browser_operations_client_sequence ON browser_operations(client_id, sequence);",
    )?;
    Ok(())
}

fn migrate_browser_progress(conn: &Connection) -> Result<(), rusqlite::Error> {
    for name in ["completed_units", "total_units"] {
        let exists: i64 = conn.query_row(
            "SELECT COUNT(*) FROM pragma_table_info('browser_jobs') WHERE name=?",
            [name], |row| row.get(0))?;
        if exists == 0 {
            conn.execute(&format!("ALTER TABLE browser_jobs ADD COLUMN {name} INTEGER"), [])?;
        }
    }
    Ok(())
}

/// Widen the feedback status set for the verify/land/ship pipeline and add
/// the ship-attempt counter. A CHECK change needs a table rebuild; the guard
/// keeps it a one-time no-op afterwards.
fn migrate_browser_feedback_pipeline(conn: &Connection) -> Result<(), rusqlite::Error> {
    let sql: Option<String> = conn
        .query_row(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='browser_feedback'",
            [],
            |row| row.get(0),
        )
        .optional()?;
    let Some(sql) = sql else { return Ok(()) };
    if sql.contains("needs-review") {
        let exists: i64 = conn.query_row(
            "SELECT COUNT(*) FROM pragma_table_info('browser_feedback') WHERE name='ship_attempts'",
            [], |row| row.get(0))?;
        if exists == 0 {
            conn.execute("ALTER TABLE browser_feedback ADD COLUMN ship_attempts INTEGER NOT NULL DEFAULT 0", [])?;
        }
        return Ok(());
    }
    conn.execute_batch(
        "CREATE TABLE browser_feedback_v2 (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL CHECK(kind IN ('feature','bug')),
            body TEXT NOT NULL,
            device TEXT NOT NULL,
            client_id TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            status TEXT NOT NULL DEFAULT 'queued' CHECK(status IN ('queued','running','done','failed','ready','landed','deployed','needs-review')),
            attempts INTEGER NOT NULL DEFAULT 0,
            ship_attempts INTEGER NOT NULL DEFAULT 0,
            next_at INTEGER NOT NULL DEFAULT 0,
            started_at INTEGER NOT NULL DEFAULT 0,
            result TEXT
        );
        INSERT INTO browser_feedback_v2(id,kind,body,device,client_id,created_at,status,attempts,ship_attempts,next_at,started_at,result)
            SELECT id,kind,body,device,client_id,created_at,status,attempts,0,next_at,started_at,result FROM browser_feedback;
        DROP TABLE browser_feedback;
        ALTER TABLE browser_feedback_v2 RENAME TO browser_feedback;
        CREATE INDEX IF NOT EXISTS idx_browser_feedback_dispatch ON browser_feedback(status, next_at, created_at);",
    )?;
    Ok(())
}

#[test]
fn browser_operation_identity_drops_sequence_uniqueness() {
    let conn = Connection::open_in_memory().unwrap();
    conn.execute_batch(
        "CREATE TABLE browser_operations (
            operation_id TEXT PRIMARY KEY,
            client_id TEXT NOT NULL,
            sequence INTEGER NOT NULL,
            payload TEXT NOT NULL,
            result TEXT NOT NULL,
            UNIQUE(client_id, sequence)
        );
        INSERT INTO browser_operations VALUES('op1','phone',1,'{}','ok');",
    )
    .unwrap();
    migrate_browser_operation_identity(&conn).unwrap();
    migrate_browser_operation_identity(&conn).unwrap();
    conn.execute(
        "INSERT INTO browser_operations VALUES('op2','phone',1,'{}','ok')",
        [],
    )
    .unwrap();
    let count: i64 = conn
        .query_row("SELECT COUNT(*) FROM browser_operations WHERE client_id='phone' AND sequence=1", [], |r| r.get(0))
        .unwrap();
    assert_eq!(count, 2);
}

#[test]
fn browser_progress_migrates_existing_jobs_idempotently() {
    let conn = Connection::open_in_memory().unwrap();
    conn.execute_batch("CREATE TABLE browser_jobs(episode_id INTEGER PRIMARY KEY,stage TEXT); INSERT INTO browser_jobs VALUES(1,'transcribing');").unwrap();
    migrate_browser_progress(&conn).unwrap();
    conn.execute("UPDATE browser_jobs SET completed_units=180,total_units=200", []).unwrap();
    migrate_browser_progress(&conn).unwrap();
    let values: (String, i64, i64) = conn.query_row("SELECT stage,completed_units,total_units FROM browser_jobs", [], |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?))).unwrap();
    assert_eq!(values, ("transcribing".into(),180,200));
}

#[test]
fn browser_feedback_pipeline_widens_statuses_idempotently() {
    let conn = Connection::open_in_memory().unwrap();
    conn.execute_batch(
        "CREATE TABLE browser_feedback (
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
        INSERT INTO browser_feedback VALUES('r1','feature','dark mode','iPhone','client',7,'done',1,0,0,'pi exit 0');",
    )
    .unwrap();
    migrate_browser_feedback_pipeline(&conn).unwrap();
    migrate_browser_feedback_pipeline(&conn).unwrap();
    let kept: (String, i64, i64, String) = conn.query_row(
        "SELECT status, attempts, ship_attempts, result FROM browser_feedback WHERE id='r1'",
        [], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))).unwrap();
    assert_eq!(kept, ("done".to_string(), 1, 0, "pi exit 0".to_string()));
    conn.execute("UPDATE browser_feedback SET status='ready' WHERE id='r1'", []).unwrap();
    conn.execute("UPDATE browser_feedback SET ship_attempts=2 WHERE id='r1'", []).unwrap();
}

pub fn now_unix() -> i64 {
    chrono::Utc::now().timestamp()
}

pub fn setting(conn: &Connection, key: &str) -> Result<Option<String>, Error> {
    let mut stmt = conn.prepare("SELECT value FROM settings WHERE key = ?")?;
    Ok(stmt.query_row(params![key], |row| row.get(0)).optional()?)
}

pub fn migrate_audio_metadata_columns(conn: &Connection) -> Result<(), rusqlite::Error> {
    let columns = [
        "audio_relative_path TEXT",
        "audio_sha256 TEXT",
        "audio_byte_count INTEGER",
        "downloaded_at INTEGER",
        "download_resume_relative_path TEXT",
        "transcriber_version TEXT",
        "transcribed_at INTEGER",
        "classification_run_id TEXT",
        "classifier_version TEXT",
        "prompt_version TEXT",
        "classifier_quantization TEXT",
        "classified_at INTEGER",
    ];
    for column in columns {
        let name = column.split_whitespace().next().unwrap();
        let exists: i64 = conn.query_row(
            "SELECT COUNT(*) FROM pragma_table_info('ad_removal_jobs') WHERE name = ?",
            rusqlite::params![name],
            |r| r.get(0),
        )?;
        if exists == 0 {
            conn.execute(&format!("ALTER TABLE ad_removal_jobs ADD COLUMN {column}"), [])?;
        }
    }
    Ok(())
}

pub fn set_setting(conn: &Connection, key: &str, value: &str) -> Result<(), Error> {
    conn.execute(
        "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![key, value],
    )?;
    Ok(())
}

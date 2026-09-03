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
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    pub fn open_in_memory() -> Result<Self, Error> {
        let conn = Connection::open_in_memory()?;
        conn.execute_batch("PRAGMA foreign_keys = ON;")?;
        conn.execute_batch(include_str!("schema.sql"))?;
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

pub fn now_unix() -> i64 {
    chrono::Utc::now().timestamp()
}

pub fn setting(conn: &Connection, key: &str) -> Result<Option<String>, Error> {
    let mut stmt = conn.prepare("SELECT value FROM settings WHERE key = ?")?;
    Ok(stmt.query_row(params![key], |row| row.get(0)).optional()?)
}

pub fn set_setting(conn: &Connection, key: &str, value: &str) -> Result<(), Error> {
    conn.execute(
        "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![key, value],
    )?;
    Ok(())
}

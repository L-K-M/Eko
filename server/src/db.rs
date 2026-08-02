//! SQLite schema and pool.
//!
//! Everything the relay stores about an envelope is opaque: `aad` and `body`
//! are bytes it never interprets. The protocol's sequence numbers and
//! generations live inside the ciphertext, so the ordering column here is the
//! relay's own `envelope_id` and carries no Eko semantics.

use r2d2_sqlite::SqliteConnectionManager;
use rusqlite::Connection;

pub type Pool = r2d2::Pool<SqliteConnectionManager>;
pub type PooledConn = r2d2::PooledConnection<SqliteConnectionManager>;

const SCHEMA: &str = r#"
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
PRAGMA synchronous = FULL;

CREATE TABLE IF NOT EXISTS account (
    id            INTEGER PRIMARY KEY,
    username      TEXT    NOT NULL UNIQUE,
    password_hash TEXT    NOT NULL,
    is_admin      INTEGER NOT NULL DEFAULT 0,
    created_at    INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS device (
    id             INTEGER PRIMARY KEY,
    account_id     INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
    device_id      TEXT    NOT NULL UNIQUE,
    public_key_der BLOB    NOT NULL,
    name           TEXT    NOT NULL,
    platform       TEXT    NOT NULL,
    created_at     INTEGER NOT NULL,
    last_seen_at   INTEGER,
    revoked_at     INTEGER
);
CREATE INDEX IF NOT EXISTS device_account ON device(account_id);

-- A queue is directional: envelopes written by `sender` for `recipient`.
CREATE TABLE IF NOT EXISTS queue (
    id         INTEGER PRIMARY KEY,
    account_id INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
    sender     TEXT    NOT NULL,
    recipient  TEXT    NOT NULL,
    created_at INTEGER NOT NULL,
    -- Monotonic high-water, never derived from the envelope table: pruning
    -- empties that table and a MAX() over it would restart the sequence, which
    -- the recipient is required to reject as non-monotonic.
    next_envelope_id INTEGER NOT NULL DEFAULT 1,
    UNIQUE(sender, recipient)
);

CREATE TABLE IF NOT EXISTS envelope (
    queue_id    INTEGER NOT NULL REFERENCES queue(id) ON DELETE CASCADE,
    envelope_id INTEGER NOT NULL,
    aad         BLOB    NOT NULL,
    body        BLOB    NOT NULL,
    byte_len    INTEGER NOT NULL,
    created_at  INTEGER NOT NULL,
    PRIMARY KEY (queue_id, envelope_id)
);
CREATE INDEX IF NOT EXISTS envelope_age ON envelope(created_at);

CREATE TABLE IF NOT EXISTS cursor (
    queue_id          INTEGER NOT NULL REFERENCES queue(id) ON DELETE CASCADE,
    reader_device     TEXT    NOT NULL,
    acked_envelope_id INTEGER NOT NULL,
    updated_at        INTEGER NOT NULL,
    PRIMARY KEY (queue_id, reader_device)
);

CREATE TABLE IF NOT EXISTS setting (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS enrolment_token (
    token_hash  BLOB PRIMARY KEY,
    account_id  INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
    expires_at  INTEGER NOT NULL,
    consumed_at INTEGER
);

-- Device auth is challenge/response over the identity key; nonces are
-- single-use and short lived.
CREATE TABLE IF NOT EXISTS auth_nonce (
    nonce      BLOB PRIMARY KEY,
    device_id  TEXT    NOT NULL,
    expires_at INTEGER NOT NULL,
    consumed_at INTEGER
);

CREATE TABLE IF NOT EXISTS token (
    token_hash BLOB PRIMARY KEY,
    subject    TEXT    NOT NULL,   -- device_id or "user:<account_id>"
    account_id INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
    is_device  INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
);
"#;

pub fn open(path: &str) -> anyhow_lite::Result<Pool> {
    let manager = if path == ":memory:" {
        SqliteConnectionManager::memory()
    } else {
        SqliteConnectionManager::file(path)
    };
    // A relay serves a household, not a fleet; a small pool is ample and keeps
    // SQLite's writer lock contention trivially bounded.
    let pool = r2d2::Pool::builder()
        .max_size(8)
        .build(manager)
        .map_err(|e| anyhow_lite::Error::msg(format!("pool: {e}")))?;
    let conn = pool
        .get()
        .map_err(|e| anyhow_lite::Error::msg(format!("pool get: {e}")))?;
    init(&conn)?;
    Ok(pool)
}

pub fn init(conn: &Connection) -> anyhow_lite::Result<()> {
    conn.execute_batch(SCHEMA)
        .map_err(|e| anyhow_lite::Error::msg(format!("schema: {e}")))?;
    Ok(())
}

/// Minimal error helper so the crate does not pull in `anyhow`.
pub mod anyhow_lite {
    #[derive(Debug)]
    pub struct Error(pub String);
    impl Error {
        pub fn msg(m: impl Into<String>) -> Self {
            Error(m.into())
        }
    }
    impl std::fmt::Display for Error {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            write!(f, "{}", self.0)
        }
    }
    impl std::error::Error for Error {}
    pub type Result<T> = std::result::Result<T, Error>;
}

pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

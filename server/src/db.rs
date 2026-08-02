//! SQLite schema and pool.
//!
//! Everything the relay stores about an envelope is opaque: `aad` and `body`
//! are bytes it never interprets. The protocol's sequence numbers and
//! generations live inside the ciphertext, so the ordering column here is the
//! relay's own `envelope_id` and carries no Eko semantics.

use r2d2_sqlite::SqliteConnectionManager;
use rusqlite::Connection;

/// A relay serves a household, not a fleet; a small pool is ample and keeps
/// SQLite's writer lock contention trivially bounded. Public because the
/// concurrency tests size their bursts against it - a racer that blocks waiting
/// for a connection is not racing anything.
pub const MAX_POOL_CONNECTIONS: u32 = 8;

pub type Pool = r2d2::Pool<SqliteConnectionManager>;
pub type PooledConn = r2d2::PooledConnection<SqliteConnectionManager>;

const SCHEMA: &str = r#"
PRAGMA journal_mode = WAL;

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
    // foreign_keys, synchronous and busy_timeout are per-connection, so setting
    // them in the schema batch would only ever configure the one connection
    // that ran it. Enforcement currently survives that mistake because
    // rusqlite's bundled SQLite is built with SQLITE_DEFAULT_FOREIGN_KEYS=1 -
    // an implicit dependency on a crate feature flag rather than on anything
    // this code says. with_init makes it true by construction on every
    // connection the pool hands out.
    //
    // busy_timeout matters for the IMMEDIATE transactions in routes.rs: without
    // it a second concurrent writer fails instantly with SQLITE_BUSY instead of
    // waiting its turn.
    //
    // NORMAL rather than FULL. Under WAL both are crash-safe - NORMAL cannot
    // corrupt the database, it can only lose the last commits to a power cut -
    // and FULL costs an fsync per commit. Measured on this container's
    // filesystem, 4 KiB inserts: FULL p50 1.855 ms, NORMAL p50 0.035 ms. The
    // relay is a hot path of small writes (deposit, cursor, nonce), and it is
    // explicitly not the source of truth: the phone's outbox is, and the
    // resume protocol heals a relay database lost outright. Paying 50x per
    // commit to narrow a window that costs nothing to reopen is the wrong
    // trade.
    let configure = |c: &mut Connection| {
        c.execute_batch(
            "PRAGMA foreign_keys = ON;
             PRAGMA synchronous = NORMAL;
             PRAGMA busy_timeout = 5000;",
        )
    };
    let manager = if path == ":memory:" {
        SqliteConnectionManager::memory().with_init(configure)
    } else {
        SqliteConnectionManager::file(path).with_init(configure)
    };
    let pool = r2d2::Pool::builder()
        .max_size(MAX_POOL_CONNECTIONS)
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

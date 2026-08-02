//! Eko relay.
//!
//! A store-and-forward queue for opaque, end-to-end encrypted envelopes. The
//! relay authenticates *who may enqueue and drain*, orders envelopes, and
//! prunes them. It cannot read one: notification content is sealed to the
//! recipient's pinned identity key before it ever arrives here, and the Eko
//! protocol's own sequence numbers live inside that ciphertext.

pub mod auth;
pub mod db;
pub mod routes;

use axum::Router;
use std::net::SocketAddr;
use std::sync::Arc;

#[derive(Clone)]
pub struct AppState {
    pub pool: db::Pool,
    pub config: Arc<Config>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RegistrationOverride {
    /// Follow the persisted `registration_open` setting.
    Unset,
    /// Force open regardless of the database.
    Open,
    /// Force closed regardless of the database. Deliberately cannot be
    /// re-opened through the API, so locking down does not depend on the
    /// database staying honest.
    Closed,
}

#[derive(Debug, Clone)]
pub struct Config {
    pub bind: String,
    pub database: String,
    pub registration: RegistrationOverride,
    /// When set, the very first account creation must present this token. The
    /// shipped Compose file sets it, because a fresh internet-reachable server
    /// with open registration and no accounts can be claimed by a stranger.
    pub bootstrap_token: Option<String>,
    pub max_envelope_bytes: usize,
    pub retention_days: i64,
    pub account_quota_bytes: i64,
    pub token_ttl_secs: i64,
}

impl Config {
    pub fn from_env() -> Self {
        let registration = match std::env::var("EKO_REGISTRATION").ok().as_deref() {
            Some("open") => RegistrationOverride::Open,
            Some("closed") => RegistrationOverride::Closed,
            _ => RegistrationOverride::Unset,
        };
        Config {
            bind: env_or("EKO_BIND", "0.0.0.0:8080"),
            database: env_or("EKO_DATABASE", "/data/relay.db"),
            registration,
            bootstrap_token: std::env::var("EKO_BOOTSTRAP_TOKEN")
                .ok()
                .filter(|t| !t.is_empty()),
            max_envelope_bytes: env_num("EKO_MAX_ENVELOPE_BYTES", 1_048_576) as usize,
            retention_days: env_num("EKO_RETENTION_DAYS", 30),
            account_quota_bytes: env_num("EKO_ACCOUNT_QUOTA_BYTES", 512 * 1024 * 1024),
            token_ttl_secs: env_num("EKO_TOKEN_TTL_SECS", 24 * 3600),
        }
    }
}

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

fn env_num(key: &str, default: i64) -> i64 {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

pub fn app(state: AppState) -> Router {
    routes::router(state)
}

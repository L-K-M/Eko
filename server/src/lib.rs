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
            // A typo here fails open. Someone writing EKO_REGISTRATION=close
            // means to lock the deployment down and instead gets the database
            // toggle, which on a fresh server means registration is open. Say
            // so rather than let a silent fallback pass for a lock.
            Some(other) if !other.is_empty() => {
                tracing::warn!(
                    value = other,
                    "EKO_REGISTRATION is neither \"open\" nor \"closed\"; ignoring it and \
                     following the admin toggle instead"
                );
                RegistrationOverride::Unset
            }
            _ => RegistrationOverride::Unset,
        };
        Config {
            bind: env_or("EKO_BIND", "0.0.0.0:8080"),
            database: env_or("EKO_DATABASE", "/data/relay.db"),
            registration,
            bootstrap_token: std::env::var("EKO_BOOTSTRAP_TOKEN")
                .ok()
                .filter(|t| !t.is_empty()),
            max_envelope_bytes: env_num::<usize>("EKO_MAX_ENVELOPE_BYTES", 1_048_576),
            retention_days: env_num("EKO_RETENTION_DAYS", 30),
            account_quota_bytes: env_num("EKO_ACCOUNT_QUOTA_BYTES", 512 * 1024 * 1024),
            token_ttl_secs: env_num("EKO_TOKEN_TTL_SECS", 24 * 3600),
        }
    }
}

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

/// Positive numbers only, parsed straight into the target type.
///
/// Every numeric setting here is a size, a count or a duration, so none of them
/// mean anything at zero or below - but each one *did* something, and always
/// the wrong thing. `EKO_MAX_ENVELOPE_BYTES=-1` went through `as usize` and
/// became `usize::MAX`, removing the limit it was setting. A negative quota
/// refuses every deposit; a negative TTL expires every token as it is issued.
/// Parsing into `usize` rejects the first outright, and the range check catches
/// the rest.
fn env_num<T>(key: &str, default: T) -> T
where
    T: std::str::FromStr + PartialOrd + Default + Copy + std::fmt::Display,
{
    let Some(raw) = std::env::var(key).ok().filter(|v| !v.is_empty()) else {
        return default;
    };
    match raw.parse::<T>() {
        Ok(v) if v > T::default() => v,
        _ => {
            tracing::warn!(
                key,
                value = %raw,
                %default,
                "not a positive number, falling back to the default"
            );
            default
        }
    }
}

pub fn app(state: AppState) -> Router {
    routes::router(state)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Each case uses its own key: env vars are process-global and the test
    /// binary runs threads in parallel.
    fn with_env(key: &str, value: Option<&str>, f: impl FnOnce()) {
        match value {
            Some(v) => std::env::set_var(key, v),
            None => std::env::remove_var(key),
        }
        f();
        std::env::remove_var(key);
    }

    /// `-1` used to reach `usize` through an `as` cast and arrive as
    /// `usize::MAX`, so the setting that bounds an envelope removed the bound.
    #[test]
    fn a_negative_size_does_not_become_an_enormous_one() {
        with_env("EKO_TEST_NEG_USIZE", Some("-1"), || {
            assert_eq!(env_num::<usize>("EKO_TEST_NEG_USIZE", 1_048_576), 1_048_576);
        });
    }

    #[test]
    fn non_positive_and_unparseable_numbers_fall_back() {
        for (key, raw) in [
            ("EKO_TEST_NUM_A", "-1"),
            ("EKO_TEST_NUM_B", "0"),
            ("EKO_TEST_NUM_C", "not a number"),
            ("EKO_TEST_NUM_D", ""),
        ] {
            with_env(key, Some(raw), || {
                assert_eq!(env_num::<i64>(key, 30), 30, "{key} = {raw:?}");
            });
        }
    }

    #[test]
    fn a_positive_number_is_taken_as_given() {
        with_env("EKO_TEST_NUM_OK", Some("7"), || {
            assert_eq!(env_num::<i64>("EKO_TEST_NUM_OK", 30), 7);
            assert_eq!(env_num::<usize>("EKO_TEST_NUM_OK", 30), 7);
        });
        with_env("EKO_TEST_NUM_UNSET", None, || {
            assert_eq!(env_num::<i64>("EKO_TEST_NUM_UNSET", 30), 30);
        });
    }
}

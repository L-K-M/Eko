//! HTTP surface.
//!
//! Authorization rules worth stating once, because everything below depends on
//! them: a device token may only touch queues whose sender or recipient is that
//! device, and both endpoints of a queue must belong to the same account. The
//! relay therefore cannot be used to fan notifications to a device the account
//! does not own — and even if it were, the envelope is sealed to a pinned key
//! the relay does not have.

use crate::auth::{self, b64};
use crate::db::{now_ms, Pool};
use crate::{AppState, RegistrationOverride};
use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, patch, post};
use axum::{Json, Router};
use base64::Engine;
use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};

/// Bound on the decoded additional-authenticated-data of an envelope.
pub const MAX_AAD_BYTES: usize = 4096;

/// Accepted password length. The ceiling is not a strength policy - it bounds
/// what an unauthenticated caller can make the server hash. Argon2's cost is
/// mostly its memory parameters, but the password is still read and absorbed on
/// every login attempt, and there is no reason to carry a megabyte of it.
const PASSWORD_BYTES: std::ops::RangeInclusive<usize> = 12..=1024;

const MAX_USERNAME_BYTES: usize = 64;

/// Longest `device_id` anywhere. `enrol_device` has always enforced it, so a
/// longer one cannot name a real device and needs no other handling.
const MAX_DEVICE_ID_BYTES: usize = 128;

/// Unconsumed, unexpired enrolment tokens one account may hold at once.
const MAX_OUTSTANDING_ENROLMENT_TOKENS: i64 = 16;

/// Could `encoded` be base64 of at most `decoded_limit` bytes? base64url turns
/// three bytes into four characters, so this is the cheap check that lets a
/// decoded-size limit be enforced before anything is allocated. Deliberately
/// generous: it rejects only what the real limit would reject anyway, and the
/// exact check still runs afterwards.
fn encoded_fits(encoded: &str, decoded_limit: usize) -> bool {
    encoded.len() <= decoded_limit.saturating_add(2) / 3 * 4 + 4
}

// ---------------------------------------------------------------- errors ---

#[derive(Debug)]
pub struct ApiError(StatusCode, &'static str);

impl ApiError {
    fn new(code: StatusCode, msg: &'static str) -> Self {
        ApiError(code, msg)
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.0, Json(serde_json::json!({ "error": self.1 }))).into_response()
    }
}

type ApiResult<T> = Result<T, ApiError>;

fn bad(msg: &'static str) -> ApiError {
    ApiError::new(StatusCode::BAD_REQUEST, msg)
}
fn unauthorized() -> ApiError {
    ApiError::new(StatusCode::UNAUTHORIZED, "unauthorized")
}
fn forbidden(msg: &'static str) -> ApiError {
    ApiError::new(StatusCode::FORBIDDEN, msg)
}
fn internal() -> ApiError {
    ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "internal")
}

/// A unique-constraint violation is the caller's problem; anything else is
/// ours. Matched on SQLite's error code rather than on the words in its message,
/// which are not an interface.
fn conflict_or_internal(e: rusqlite::Error, msg: &'static str) -> ApiError {
    match e {
        rusqlite::Error::SqliteFailure(f, _)
            if f.code == rusqlite::ErrorCode::ConstraintViolation =>
        {
            ApiError::new(StatusCode::CONFLICT, msg)
        }
        _ => internal(),
    }
}

fn conn(pool: &Pool) -> ApiResult<crate::db::PooledConn> {
    pool.get().map_err(|_| internal())
}

// ------------------------------------------------------------- subjects ---

pub struct UserSubject {
    pub account_id: i64,
    pub is_admin: bool,
}

pub struct DeviceSubject {
    pub account_id: i64,
    pub device_id: String,
}

fn bearer(headers: &HeaderMap) -> ApiResult<Vec<u8>> {
    // RFC 6750 makes the scheme case-insensitive; strip_prefix("Bearer ") turned
    // a client that sends "bearer" into an authentication failure.
    let raw = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| {
            let (scheme, rest) = v.split_once(' ')?;
            scheme.eq_ignore_ascii_case("bearer").then_some(rest)
        })
        .ok_or_else(unauthorized)?;
    Ok(auth::sha256(raw.as_bytes()))
}

fn user_from(state: &AppState, headers: &HeaderMap) -> ApiResult<UserSubject> {
    let digest = bearer(headers)?;
    let c = conn(&state.pool)?;
    let row: Option<(i64, i64, i64)> = c
        .query_row(
            "SELECT account_id, is_device, expires_at FROM token WHERE token_hash = ?1",
            params![digest],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()
        .map_err(|_| internal())?;
    let (account_id, is_device, expires_at) = row.ok_or_else(unauthorized)?;
    if is_device != 0 || expires_at < now_ms() {
        return Err(unauthorized());
    }
    // A missing account row means the token outlived its account: 401. A
    // database failure is infrastructure: 500. Collapsing both into 401 made an
    // outage look like an auth problem.
    let is_admin: i64 = c
        .query_row(
            "SELECT is_admin FROM account WHERE id = ?1",
            params![account_id],
            |r| r.get(0),
        )
        .optional()
        .map_err(|_| internal())?
        .ok_or_else(unauthorized)?;
    Ok(UserSubject {
        account_id,
        is_admin: is_admin != 0,
    })
}

fn device_from(state: &AppState, headers: &HeaderMap) -> ApiResult<DeviceSubject> {
    let digest = bearer(headers)?;
    let c = conn(&state.pool)?;
    let row: Option<(i64, i64, i64, String)> = c
        .query_row(
            "SELECT account_id, is_device, expires_at, subject FROM token WHERE token_hash = ?1",
            params![digest],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .optional()
        .map_err(|_| internal())?;
    let (account_id, is_device, expires_at, subject) = row.ok_or_else(unauthorized)?;
    if is_device == 0 || expires_at < now_ms() {
        return Err(unauthorized());
    }
    // A revoked device keeps no access even while its token is unexpired.
    let revoked: Option<Option<i64>> = c
        .query_row(
            "SELECT revoked_at FROM device WHERE device_id = ?1",
            params![subject],
            |r| r.get(0),
        )
        .optional()
        .map_err(|_| internal())?;
    match revoked {
        Some(None) => {}
        _ => return Err(unauthorized()),
    }
    Ok(DeviceSubject {
        account_id,
        device_id: subject,
    })
}

fn issue_token(
    c: &rusqlite::Connection,
    account_id: i64,
    subject: &str,
    is_device: bool,
    ttl_secs: i64,
) -> ApiResult<(String, i64)> {
    let (token, digest) = auth::new_token();
    let expires_at = now_ms() + ttl_secs * 1000;
    c.execute(
        "INSERT INTO token (token_hash, subject, account_id, is_device, expires_at)
         VALUES (?1, ?2, ?3, ?4, ?5)",
        params![digest, subject, account_id, is_device as i64, expires_at],
    )
    .map_err(|_| internal())?;
    Ok((token, expires_at))
}

// ------------------------------------------------------------- settings ---

fn registration_open(state: &AppState, c: &rusqlite::Connection) -> bool {
    match state.config.registration {
        RegistrationOverride::Open => return true,
        RegistrationOverride::Closed => return false,
        RegistrationOverride::Unset => {}
    }
    let stored: Option<String> = c
        .query_row(
            "SELECT value FROM setting WHERE key = 'registration_open'",
            [],
            |r| r.get(0),
        )
        .optional()
        .ok()
        .flatten();
    // Absent means a fresh database, which must allow the first account.
    stored.map(|v| v == "true").unwrap_or(true)
}

/// Deliberately fallible. Defaulting to 0 on a database error would read as
/// "no accounts exist", which is exactly the answer that grants admin.
fn account_count(c: &rusqlite::Connection) -> ApiResult<i64> {
    c.query_row("SELECT COUNT(*) FROM account", [], |r| r.get(0))
        .map_err(|_| internal())
}

// ------------------------------------------------------------- accounts ---

#[derive(Deserialize)]
pub struct CreateAccount {
    username: String,
    password: String,
    #[serde(default)]
    bootstrap_token: Option<String>,
}

#[derive(Serialize)]
pub struct AccountCreated {
    account_id: i64,
    is_admin: bool,
}

/// Decide whether this request may create an account, and whether it would be
/// the first. Called twice per creation: once cheaply before the password is
/// hashed, once inside the write transaction where the answer is binding.
fn registration_gate(
    state: &AppState,
    c: &rusqlite::Connection,
    body: &CreateAccount,
) -> ApiResult<bool> {
    let first = account_count(c)? == 0;
    // Applies to the first account too. An environment override exists to lock
    // a deployment down, and a lock that still lets a stranger claim an
    // unclaimed server is not a lock. Setup means booting once with
    // EKO_REGISTRATION=open, not exempting the most valuable account.
    if !registration_open(state, c) {
        return Err(forbidden("registration is closed"));
    }
    // The first account is the one that can claim the deployment, so it is the
    // one the bootstrap token guards.
    if first {
        if let Some(expected) = state.config.bootstrap_token.as_deref() {
            match body.bootstrap_token.as_deref() {
                Some(given) if auth::constant_time_eq(given.as_bytes(), expected.as_bytes()) => {}
                _ => return Err(forbidden("bootstrap token required")),
            }
        }
    }
    Ok(first)
}

async fn create_account(
    State(state): State<AppState>,
    Json(body): Json<CreateAccount>,
) -> ApiResult<Json<AccountCreated>> {
    // Trimmed before it is stored, not merely for the emptiness check: storing
    // the untrimmed form made " alice " and "alice" two accounts that read as
    // one. `login` trims the same way, so an existing name still matches.
    let username = body.username.trim();
    if username.is_empty() || username.len() > MAX_USERNAME_BYTES {
        return Err(bad("username must be 1-64 bytes"));
    }
    if !(PASSWORD_BYTES).contains(&body.password.len()) {
        return Err(bad("password must be 12-1024 bytes"));
    }
    let mut c = conn(&state.pool)?;
    // Gate once here, before hashing. Argon2 is deliberately expensive, and an
    // unauthenticated caller who fails the bootstrap check must not be able to
    // spend a CPU core by asking. This read is advisory - it is not serialised
    // against a concurrent first account - so it is repeated authoritatively
    // inside the transaction below.
    registration_gate(&state, &c, &body)?;
    // Outside the transaction on purpose: hashing takes hundreds of
    // milliseconds, and BEGIN IMMEDIATE holds the database's single write lock
    // for its whole body. Hashing under it would stall every concurrent
    // deposit and cursor update for the duration.
    let hash = auth::hash_password(&body.password).map_err(|_| internal())?;

    // BEGIN IMMEDIATE takes the write lock before the count is read, so two
    // concurrent first-account requests cannot both observe an empty table and
    // both be granted admin. That account controls registration and device
    // enrolment, so the race is a privilege escalation, not a cosmetic one.
    let tx = c
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(|_| internal())?;
    let first = registration_gate(&state, &tx, &body)?;
    tx.execute(
        "INSERT INTO account (username, password_hash, is_admin, created_at)
         VALUES (?1, ?2, ?3, ?4)",
        params![username, hash, first as i64, now_ms()],
    )
    .map_err(|e| conflict_or_internal(e, "username taken"))?;
    let account_id = tx.last_insert_rowid();
    tx.commit().map_err(|_| internal())?;
    Ok(Json(AccountCreated {
        account_id,
        is_admin: first,
    }))
}

#[derive(Deserialize)]
pub struct Login {
    username: String,
    password: String,
}

#[derive(Serialize)]
pub struct TokenResponse {
    token: String,
    expires_at: i64,
}

async fn login(
    State(state): State<AppState>,
    Json(body): Json<Login>,
) -> ApiResult<Json<TokenResponse>> {
    // Bounded before any work happens. This is the endpoint an unauthenticated
    // caller can hit repeatedly, and it Argon2s on every attempt by design.
    // Rejecting on the caller's own input length tells them nothing they did
    // not already know, so it costs the unknown-username defence below nothing.
    let username = body.username.trim();
    if username.len() > MAX_USERNAME_BYTES || !(PASSWORD_BYTES).contains(&body.password.len()) {
        return Err(unauthorized());
    }
    let c = conn(&state.pool)?;
    let row: Option<(i64, String)> = c
        .query_row(
            "SELECT id, password_hash FROM account WHERE username = ?1",
            params![username],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(|_| internal())?;
    // Verify in both branches. Returning early on an unknown username made a
    // missing account answer in microseconds and a wrong password answer in
    // however long Argon2 takes, which enumerates usernames by stopwatch.
    let (account_id, hash) = match row {
        Some(found) => found,
        None => (-1, auth::dummy_password_hash().to_string()),
    };
    let password_ok = auth::verify_password(&body.password, &hash);
    if !password_ok || account_id < 0 {
        return Err(unauthorized());
    }
    let subject = format!("user:{account_id}");
    let (token, expires_at) =
        issue_token(&c, account_id, &subject, false, state.config.token_ttl_secs)?;
    Ok(Json(TokenResponse { token, expires_at }))
}

// ---------------------------------------------------------------- admin ---

#[derive(Deserialize)]
pub struct SettingsPatch {
    registration_open: bool,
}

#[derive(Serialize)]
pub struct SettingsView {
    registration_open: bool,
    forced_by_environment: bool,
}

async fn patch_settings(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<SettingsPatch>,
) -> ApiResult<Json<SettingsView>> {
    let user = user_from(&state, &headers)?;
    if !user.is_admin {
        return Err(forbidden("admin only"));
    }
    let forced = state.config.registration != RegistrationOverride::Unset;
    let c = conn(&state.pool)?;
    c.execute(
        "INSERT INTO setting (key, value) VALUES ('registration_open', ?1)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![if body.registration_open {
            "true"
        } else {
            "false"
        }],
    )
    .map_err(|_| internal())?;
    // Report what is actually in force, not what was requested: an env override
    // wins, and silently accepting a no-op would be a lie.
    Ok(Json(SettingsView {
        registration_open: registration_open(&state, &c),
        forced_by_environment: forced,
    }))
}

async fn get_settings(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> ApiResult<Json<SettingsView>> {
    let user = user_from(&state, &headers)?;
    if !user.is_admin {
        return Err(forbidden("admin only"));
    }
    let c = conn(&state.pool)?;
    Ok(Json(SettingsView {
        registration_open: registration_open(&state, &c),
        forced_by_environment: state.config.registration != RegistrationOverride::Unset,
    }))
}

#[derive(Serialize)]
pub struct EnrolmentToken {
    token: String,
    expires_at: i64,
}

async fn mint_enrolment_token(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> ApiResult<Json<EnrolmentToken>> {
    let user = user_from(&state, &headers)?;
    let c = conn(&state.pool)?;
    // One row per call, an hour before the sweep collects it, and any account on
    // a shared deployment can call it. A household needs a handful at once.
    let outstanding: i64 = c
        .query_row(
            "SELECT COUNT(*) FROM enrolment_token
             WHERE account_id = ?1 AND consumed_at IS NULL AND expires_at >= ?2",
            params![user.account_id, now_ms()],
            |r| r.get(0),
        )
        .map_err(|_| internal())?;
    if outstanding >= MAX_OUTSTANDING_ENROLMENT_TOKENS {
        return Err(ApiError::new(
            StatusCode::TOO_MANY_REQUESTS,
            "too many unused enrolment tokens; use or expire them first",
        ));
    }
    let (token, digest) = auth::new_token();
    let expires_at = now_ms() + 3600 * 1000;
    c.execute(
        "INSERT INTO enrolment_token (token_hash, account_id, expires_at) VALUES (?1, ?2, ?3)",
        params![digest, user.account_id, expires_at],
    )
    .map_err(|_| internal())?;
    Ok(Json(EnrolmentToken { token, expires_at }))
}

#[derive(Serialize)]
pub struct DeviceView {
    device_id: String,
    name: String,
    platform: String,
    created_at: i64,
    last_seen_at: Option<i64>,
    revoked: bool,
}

async fn list_devices(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> ApiResult<Json<Vec<DeviceView>>> {
    let user = user_from(&state, &headers)?;
    let c = conn(&state.pool)?;
    let mut stmt = c
        .prepare(
            "SELECT device_id, name, platform, created_at, last_seen_at, revoked_at
             FROM device WHERE account_id = ?1 ORDER BY created_at",
        )
        .map_err(|_| internal())?;
    let rows = stmt
        .query_map(params![user.account_id], |r| {
            Ok(DeviceView {
                device_id: r.get(0)?,
                name: r.get(1)?,
                platform: r.get(2)?,
                created_at: r.get(3)?,
                last_seen_at: r.get(4)?,
                revoked: r.get::<_, Option<i64>>(5)?.is_some(),
            })
        })
        .map_err(|_| internal())?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| internal())?;
    Ok(Json(rows))
}

async fn revoke_device(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(device_id): Path<String>,
) -> ApiResult<StatusCode> {
    let user = user_from(&state, &headers)?;
    let c = conn(&state.pool)?;
    let n = c
        .execute(
            "UPDATE device SET revoked_at = ?1 WHERE device_id = ?2 AND account_id = ?3",
            params![now_ms(), device_id, user.account_id],
        )
        .map_err(|_| internal())?;
    if n == 0 {
        return Err(ApiError::new(StatusCode::NOT_FOUND, "no such device"));
    }
    // `is_device = 1` is load-bearing, not hygiene. User sessions live in this
    // same table under subject "user:<account_id>", and device_id is free text,
    // so a device named "user:1" made this delete another account's session -
    // revoking your own device logged out whoever owns account 1.
    c.execute(
        "DELETE FROM token WHERE subject = ?1 AND is_device = 1",
        params![device_id],
    )
    .map_err(|_| internal())?;
    Ok(StatusCode::NO_CONTENT)
}

// -------------------------------------------------------------- devices ---

#[derive(Deserialize)]
pub struct Enrol {
    token: String,
    device_id: String,
    /// Uncompressed SEC1 P-256 point, base64url unpadded.
    public_key: String,
    name: String,
    platform: String,
}

async fn enrol_device(
    State(state): State<AppState>,
    Json(body): Json<Enrol>,
) -> ApiResult<Json<AccountCreated>> {
    if body.device_id.trim().is_empty() || body.device_id.len() > MAX_DEVICE_ID_BYTES {
        return Err(bad("device_id must be 1-128 characters"));
    }
    // device_id was bounded and these were not, though they are stored beside it
    // and handed back by list_devices.
    if body.name.len() > 256 || body.platform.len() > 64 {
        return Err(bad("name must be <=256 and platform <=64 bytes"));
    }
    let key = b64()
        .decode(body.public_key.as_bytes())
        .map_err(|_| bad("public_key must be base64url"))?;
    if p256::ecdsa::VerifyingKey::from_sec1_bytes(&key).is_err() {
        return Err(bad("public_key is not a valid P-256 point"));
    }

    let mut c = conn(&state.pool)?;
    // Same shape of race as create_account: without the write lock held across
    // the whole check-insert-consume, two concurrent requests can both see an
    // unconsumed token and a single-use enrolment token becomes multi-use.
    // A transaction rather than a conditional UPDATE, so that a failed device
    // insert rolls back and does not burn the operator's token.
    let tx = c
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(|_| internal())?;
    let digest = auth::sha256(body.token.as_bytes());
    let row: Option<(i64, i64, Option<i64>)> = tx
        .query_row(
            "SELECT account_id, expires_at, consumed_at FROM enrolment_token WHERE token_hash = ?1",
            params![digest],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()
        .map_err(|_| internal())?;
    let (account_id, expires_at, consumed_at) = row.ok_or_else(|| forbidden("bad token"))?;
    if consumed_at.is_some() || expires_at < now_ms() {
        return Err(forbidden("bad token"));
    }

    tx.execute(
        "INSERT INTO device (account_id, device_id, public_key_der, name, platform, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![
            account_id,
            body.device_id,
            key,
            body.name,
            body.platform,
            now_ms()
        ],
    )
    .map_err(|e| conflict_or_internal(e, "device already enrolled"))?;
    tx.execute(
        "UPDATE enrolment_token SET consumed_at = ?1 WHERE token_hash = ?2",
        params![now_ms(), digest],
    )
    .map_err(|_| internal())?;
    tx.commit().map_err(|_| internal())?;

    Ok(Json(AccountCreated {
        account_id,
        is_admin: false,
    }))
}

#[derive(Deserialize)]
pub struct ChallengeRequest {
    device_id: String,
}

#[derive(Serialize)]
pub struct ChallengeResponse {
    nonce: String,
    expires_at: i64,
}

async fn device_challenge(
    State(state): State<AppState>,
    Json(body): Json<ChallengeRequest>,
) -> ApiResult<Json<ChallengeResponse>> {
    // Unauthenticated, and it writes a row. Without this an anonymous caller
    // could park megabyte strings in auth_nonce at will. Bounding on the
    // caller's own input length is not an existence oracle - the answer does
    // not depend on anything stored - and a longer id could never name a device
    // anyway, because enrolment refuses one.
    if body.device_id.is_empty() || body.device_id.len() > MAX_DEVICE_ID_BYTES {
        return Err(bad("device_id must be 1-128 bytes"));
    }
    let c = conn(&state.pool)?;
    // Issue a nonce regardless of whether the device exists: a challenge that
    // only succeeds for enrolled devices is a device-existence oracle.
    let nonce = auth::random_bytes(32);
    let expires_at = now_ms() + 120 * 1000;
    c.execute(
        "INSERT INTO auth_nonce (nonce, device_id, expires_at) VALUES (?1, ?2, ?3)",
        params![nonce, body.device_id, expires_at],
    )
    .map_err(|_| internal())?;
    Ok(Json(ChallengeResponse {
        nonce: b64().encode(&nonce),
        expires_at,
    }))
}

#[derive(Deserialize)]
pub struct DeviceAuth {
    device_id: String,
    nonce: String,
    /// DER ECDSA signature, base64url unpadded.
    signature: String,
}

async fn device_auth(
    State(state): State<AppState>,
    Json(body): Json<DeviceAuth>,
) -> ApiResult<Json<TokenResponse>> {
    // Also unauthenticated, and also decoding caller-supplied base64. A nonce is
    // 32 bytes and a DER P-256 signature at most 72, so anything near these
    // bounds is already not one.
    if !encoded_fits(&body.nonce, 64)
        || !encoded_fits(&body.signature, 256)
        || body.device_id.is_empty()
        || body.device_id.len() > MAX_DEVICE_ID_BYTES
    {
        return Err(bad("nonce, signature or device_id out of bounds"));
    }
    let nonce = b64()
        .decode(body.nonce.as_bytes())
        .map_err(|_| bad("nonce must be base64url"))?;
    let signature = b64()
        .decode(body.signature.as_bytes())
        .map_err(|_| bad("signature must be base64url"))?;

    let c = conn(&state.pool)?;
    // Claim the nonce in one statement. Reading it, checking it in Rust and
    // then burning it with a separate UPDATE is the same check-then-act shape
    // as the races elsewhere in this file, and here it is a replay: concurrent
    // requests carrying one intercepted (nonce, signature) pair all saw
    // consumed_at IS NULL and all minted a token. SQLite serialises writes to
    // the row, so with the conditions in the UPDATE only the first caller
    // matches and every racer gets no row back.
    //
    // Still burned *before* the signature is verified, so a bad signature
    // cannot be retried against the same challenge.
    let now = now_ms();
    let claimed: Option<i64> = c
        .query_row(
            "UPDATE auth_nonce SET consumed_at = ?1
             WHERE nonce = ?2
               AND consumed_at IS NULL
               AND expires_at >= ?1
               AND device_id = ?3
             RETURNING 1",
            params![now, nonce, body.device_id],
            |r| r.get(0),
        )
        .optional()
        .map_err(|_| internal())?;
    if claimed.is_none() {
        return Err(unauthorized());
    }

    let device: Option<(i64, Vec<u8>, Option<i64>)> = c
        .query_row(
            "SELECT account_id, public_key_der, revoked_at FROM device WHERE device_id = ?1",
            params![body.device_id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()
        .map_err(|_| internal())?;
    let (account_id, public_key, revoked_at) = device.ok_or_else(unauthorized)?;
    if revoked_at.is_some() {
        return Err(unauthorized());
    }
    if !auth::verify_device_signature(&public_key, &nonce, &body.device_id, &signature) {
        return Err(unauthorized());
    }

    c.execute(
        "UPDATE device SET last_seen_at = ?1 WHERE device_id = ?2",
        params![now_ms(), body.device_id],
    )
    .ok();

    let (token, token_expires) = issue_token(
        &c,
        account_id,
        &body.device_id,
        true,
        state.config.token_ttl_secs,
    )?;
    Ok(Json(TokenResponse {
        token,
        expires_at: token_expires,
    }))
}

// --------------------------------------------------------------- queues ---

/// Look the queue up without creating it. `drain` is a GET, and a GET that
/// writes is a GET that a retry, a prefetch or a cache can turn into a row.
/// There is nothing to return for a queue nobody has deposited into anyway.
fn existing_queue_id(
    c: &rusqlite::Connection,
    account_id: i64,
    sender: &str,
    recipient: &str,
) -> ApiResult<Option<i64>> {
    c.query_row(
        "SELECT id FROM queue WHERE account_id = ?1 AND sender = ?2 AND recipient = ?3",
        params![account_id, sender, recipient],
        |r| r.get(0),
    )
    .optional()
    .map_err(|_| internal())
}

fn queue_id(
    c: &rusqlite::Connection,
    account_id: i64,
    sender: &str,
    recipient: &str,
) -> ApiResult<i64> {
    // Read-only fast path. Every drain and every cursor update runs through
    // here, and after the first envelope the row always exists, so the common
    // case must not take the write lock.
    if let Some(id) = c
        .query_row(
            "SELECT id FROM queue WHERE account_id = ?1 AND sender = ?2 AND recipient = ?3",
            params![account_id, sender, recipient],
            |r| r.get::<_, i64>(0),
        )
        .optional()
        .map_err(|_| internal())?
    {
        return Ok(id);
    }
    // The miss is racy: `drain` and `set_cursor` hold no transaction, so two
    // first readers of the same queue both miss the SELECT and both insert.
    // Plain INSERT gave the loser a UNIQUE violation, which `internal()` turned
    // into a 500. Upserting makes create-or-get one statement; DO UPDATE rather
    // than DO NOTHING because DO NOTHING returns no row for RETURNING to hand
    // back.
    c.query_row(
        "INSERT INTO queue (account_id, sender, recipient, created_at)
         VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT(sender, recipient) DO UPDATE SET created_at = queue.created_at
         RETURNING id",
        params![account_id, sender, recipient, now_ms()],
        |r| r.get(0),
    )
    // Deliberately the RETURNING value and not last_insert_rowid(): when the
    // upsert takes the DO UPDATE branch nothing is inserted, and
    // last_insert_rowid() would hand back whatever this pooled connection
    // inserted last - a different queue's id, silently.
    .map_err(|_| internal())
}

/// Both endpoints must be live devices of the caller's account.
fn require_same_account_peer(
    c: &rusqlite::Connection,
    account_id: i64,
    peer: &str,
) -> ApiResult<()> {
    let row: Option<(i64, Option<i64>)> = c
        .query_row(
            "SELECT account_id, revoked_at FROM device WHERE device_id = ?1",
            params![peer],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(|_| internal())?;
    match row {
        Some((acc, None)) if acc == account_id => Ok(()),
        _ => Err(forbidden("peer is not a device of this account")),
    }
}

#[derive(Deserialize)]
pub struct Deposit {
    /// Opaque additional authenticated data, base64url.
    aad: String,
    /// Opaque sealed body, base64url.
    body: String,
}

#[derive(Serialize)]
pub struct Deposited {
    envelope_id: i64,
}

async fn deposit(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(peer): Path<String>,
    Json(body): Json<Deposit>,
) -> ApiResult<Json<Deposited>> {
    let device = device_from(&state, &headers)?;
    // Bound the *encoded* strings before decoding them. The limits below are on
    // the decoded bytes, so without this a caller can make the server allocate
    // the decode buffer for a payload it is about to refuse.
    if !encoded_fits(&body.aad, MAX_AAD_BYTES) {
        return Err(bad("aad too large"));
    }
    if !encoded_fits(&body.body, state.config.max_envelope_bytes) {
        return Err(ApiError::new(
            StatusCode::PAYLOAD_TOO_LARGE,
            "envelope too large",
        ));
    }
    let aad = b64().decode(body.aad.as_bytes()).map_err(|_| bad("aad"))?;
    // The envelope format puts a version, two device ids and a queue id in the
    // aad; anything approaching this is not that. Unbounded, it was stored and
    // billed to nobody.
    if aad.len() > MAX_AAD_BYTES {
        return Err(bad("aad too large"));
    }
    let sealed = b64()
        .decode(body.body.as_bytes())
        .map_err(|_| bad("body"))?;
    if sealed.len() > state.config.max_envelope_bytes {
        return Err(ApiError::new(
            StatusCode::PAYLOAD_TOO_LARGE,
            "envelope too large",
        ));
    }

    let mut c = conn(&state.pool)?;
    // The same check-then-act shape as create_account and enrol_device: the
    // quota total, the sequence allocation and the insert have to be one
    // atomic step, or concurrent deposits each read the same total, each pass,
    // and the account stores well past its ceiling.
    let tx = c
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(|_| internal())?;
    require_same_account_peer(&tx, device.account_id, &peer)?;

    // A database error here previously read as "zero bytes stored", which
    // disables the quota rather than reporting a fault.
    let used: i64 = tx
        .query_row(
            "SELECT COALESCE(SUM(e.byte_len), 0) FROM envelope e
             JOIN queue q ON q.id = e.queue_id WHERE q.account_id = ?1",
            params![device.account_id],
            |r| r.get(0),
        )
        .map_err(|_| internal())?;
    let stored_len = (sealed.len() + aad.len()) as i64;
    if used + stored_len > state.config.account_quota_bytes {
        return Err(ApiError::new(
            StatusCode::INSUFFICIENT_STORAGE,
            "account quota exceeded",
        ));
    }

    let qid = queue_id(&tx, device.account_id, &device.device_id, &peer)?;
    // Monotonic per queue. The relay orders by this and nothing else; Eko's own
    // sequence numbers are inside the ciphertext and never seen here.
    let next: i64 = tx
        .query_row(
            "UPDATE queue SET next_envelope_id = next_envelope_id + 1
             WHERE id = ?1 RETURNING next_envelope_id - 1",
            params![qid],
            |r| r.get(0),
        )
        .map_err(|_| internal())?;
    tx.execute(
        "INSERT INTO envelope (queue_id, envelope_id, aad, body, byte_len, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![qid, next, aad, sealed, stored_len, now_ms()],
    )
    .map_err(|_| internal())?;
    tx.commit().map_err(|_| internal())?;

    Ok(Json(Deposited { envelope_id: next }))
}

#[derive(Deserialize)]
pub struct DrainQuery {
    #[serde(default)]
    after: i64,
    #[serde(default = "default_limit")]
    limit: i64,
}

fn default_limit() -> i64 {
    100
}

#[derive(Serialize)]
pub struct EnvelopeView {
    envelope_id: i64,
    aad: String,
    body: String,
    created_at: i64,
}

async fn drain(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(peer): Path<String>,
    Query(q): Query<DrainQuery>,
) -> ApiResult<Json<Vec<EnvelopeView>>> {
    let device = device_from(&state, &headers)?;
    let c = conn(&state.pool)?;
    require_same_account_peer(&c, device.account_id, &peer)?;
    // Draining reads the queue written *by* the peer *for* this device.
    let Some(qid) = existing_queue_id(&c, device.account_id, &peer, &device.device_id)? else {
        return Ok(Json(Vec::new()));
    };
    let limit = q.limit.clamp(1, 500);

    let mut stmt = c
        .prepare(
            "SELECT envelope_id, aad, body, created_at FROM envelope
             WHERE queue_id = ?1 AND envelope_id > ?2
             ORDER BY envelope_id LIMIT ?3",
        )
        .map_err(|_| internal())?;
    let rows = stmt
        .query_map(params![qid, q.after, limit], |r| {
            Ok(EnvelopeView {
                envelope_id: r.get(0)?,
                aad: b64().encode(r.get::<_, Vec<u8>>(1)?),
                body: b64().encode(r.get::<_, Vec<u8>>(2)?),
                created_at: r.get(3)?,
            })
        })
        .map_err(|_| internal())?
        // Not filter_map(Result::ok). A row that failed to convert used to
        // vanish from the response, and the client would then acknowledge past
        // it - so a decoding fault silently deleted an envelope instead of
        // reporting itself.
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| internal())?;

    c.execute(
        "UPDATE device SET last_seen_at = ?1 WHERE device_id = ?2",
        params![now_ms(), device.device_id],
    )
    .ok();
    Ok(Json(rows))
}

#[derive(Deserialize)]
pub struct CursorUpdate {
    acked_envelope_id: i64,
}

async fn set_cursor(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(peer): Path<String>,
    Json(body): Json<CursorUpdate>,
) -> ApiResult<StatusCode> {
    let device = device_from(&state, &headers)?;
    let mut c = conn(&state.pool)?;
    require_same_account_peer(&c, device.account_id, &peer)?;
    let qid = queue_id(&c, device.account_id, &peer, &device.device_id)?;
    // One transaction for the ack and the prune it authorises. Separately they
    // take the write lock twice, and a failure between them advances the cursor
    // while still reporting an error - self-healing on retry, but only because
    // the cursor cannot move backwards. Atomic is cheaper and needs no such
    // argument.
    let tx = c
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(|_| internal())?;

    // Never move a cursor backwards: a stale client must not resurrect pruned
    // positions or cause a re-delivery storm.
    tx.execute(
        "INSERT INTO cursor (queue_id, reader_device, acked_envelope_id, updated_at)
         VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT(queue_id, reader_device) DO UPDATE SET
           acked_envelope_id = MAX(cursor.acked_envelope_id, excluded.acked_envelope_id),
           updated_at = excluded.updated_at",
        params![qid, device.device_id, body.acked_envelope_id, now_ms()],
    )
    .map_err(|_| internal())?;

    // Acknowledged envelopes are dead weight; drop them immediately rather than
    // waiting for the retention sweep.
    tx.execute(
        "DELETE FROM envelope WHERE queue_id = ?1 AND envelope_id <= ?2",
        params![qid, body.acked_envelope_id],
    )
    .map_err(|_| internal())?;
    tx.commit().map_err(|_| internal())?;

    Ok(StatusCode::NO_CONTENT)
}

// ------------------------------------------------------------- lifecycle ---

/// The sweep is best effort and its only consumer logs a count, so the cause
/// is deliberately not propagated.
#[derive(Debug)]
pub struct SweepError;

pub fn sweep(pool: &Pool, retention_days: i64) -> Result<usize, SweepError> {
    let c = pool.get().map_err(|_| SweepError)?;
    // EKO_RETENTION_DAYS is an operator string parsed straight into an i64, and
    // both of its bad values delete rather than keep: a negative one puts the
    // cutoff in the future and takes every envelope including the ones that
    // arrived a second ago, and one large enough to overflow the multiply wraps
    // to the same place. Neither is worth a panic, but neither may run - the
    // safe reading of an unusable retention is "keep everything".
    let Some(cutoff) = retention_days
        .checked_mul(86_400_000)
        .and_then(|window| now_ms().checked_sub(window))
        .filter(|_| retention_days > 0)
    else {
        tracing::warn!(
            retention_days,
            "unusable retention, skipping sweep; expected a positive number of days"
        );
        return Ok(0);
    };
    let removed = c
        .execute(
            "DELETE FROM envelope WHERE created_at < ?1",
            params![cutoff],
        )
        .map_err(|_| SweepError)?;
    // Best effort, deliberately: expired nonces and tokens are already refused
    // on use, so failing to collect them is untidy rather than unsafe. Logged
    // because a cleanup that fails every hour is a database problem whose only
    // other symptom is a table growing without bound.
    for (what, sql) in [
        ("auth_nonce", "DELETE FROM auth_nonce WHERE expires_at < ?1"),
        ("token", "DELETE FROM token WHERE expires_at < ?1"),
        // One-hour TTL, refused on use once past it, and nothing collected them.
        (
            "enrolment_token",
            "DELETE FROM enrolment_token WHERE expires_at < ?1",
        ),
    ] {
        if let Err(e) = c.execute(sql, params![now_ms()]) {
            tracing::warn!(error = %e, table = what, "retention sweep cleanup failed");
        }
    }
    Ok(removed)
}

async fn healthz() -> &'static str {
    "ok"
}

async fn readyz(State(state): State<AppState>) -> ApiResult<&'static str> {
    let c = conn(&state.pool)?;
    c.query_row("SELECT 1", [], |r| r.get::<_, i64>(0))
        .map_err(|_| internal())?;
    Ok("ready")
}

pub fn router(state: AppState) -> Router {
    let routes = Router::new()
        .route("/healthz", get(healthz))
        .route("/readyz", get(readyz))
        .route("/api/v1/accounts", post(create_account))
        .route("/api/v1/accounts/login", post(login))
        .route(
            "/api/v1/admin/settings",
            patch(patch_settings).get(get_settings),
        )
        // Not under /admin: these manage the caller's *own* devices and are
        // deliberately open to any account, because enrolling your phone is not
        // a privileged act. Only deployment-wide state - the registration
        // toggle above - is admin-gated. The old /admin/devices path implied a
        // privilege boundary that the handlers never enforced and should not.
        .route(
            "/api/v1/account/enrolment-tokens",
            post(mint_enrolment_token),
        )
        .route("/api/v1/account/devices", get(list_devices))
        .route(
            "/api/v1/account/devices/{device_id}",
            axum::routing::delete(revoke_device),
        )
        .route("/api/v1/devices/enrol", post(enrol_device))
        .route("/api/v1/devices/challenge", post(device_challenge))
        .route("/api/v1/devices/auth", post(device_auth))
        .route("/api/v1/queues/{peer}/envelopes", post(deposit).get(drain))
        .route("/api/v1/queues/{peer}/cursor", post(set_cursor))
        .with_state(state);
    with_shared_layers(routes)
}

/// The stack every route sits behind. Separate from `router` so a test can put
/// a deliberately panicking handler behind exactly the same layers.
fn with_shared_layers(router: Router) -> Router {
    router
        .layer(tower_http::trace::TraceLayer::new_for_http())
        // Outermost, so a panic anywhere below becomes a 500 for that one
        // request instead of a dropped connection. Only reachable because the
        // release profile unwinds; see the note in Cargo.toml.
        .layer(tower_http::catch_panic::CatchPanicLayer::new())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Barrier};

    fn pool_with_account() -> (tempfile::TempDir, crate::db::Pool) {
        let dir = tempfile::tempdir().unwrap();
        let pool = crate::db::open(&dir.path().join("t.db").to_string_lossy()).unwrap();
        pool.get()
            .unwrap()
            .execute(
                "INSERT INTO account (id, username, password_hash, is_admin, created_at)
                 VALUES (1, 'u', 'h', 1, 0)",
                [],
            )
            .unwrap();
        (dir, pool)
    }

    /// `drain` and `set_cursor` call `queue_id` with no transaction held, so
    /// the first readers of a queue all miss the SELECT together. Check-then-
    /// insert gave every loser a UNIQUE violation, which `internal()` reported
    /// as a 500. Exercised here rather than over HTTP because the auth work a
    /// request does first spreads the racers out far enough to hide it.
    ///
    /// The interleave is forced, not hoped for. An unheld write lock lets the
    /// first racer finish SELECT *and* INSERT in tens of microseconds, so the
    /// others never overlap it and the bug hides; holding the lock parks every
    /// racer between its SELECT and its INSERT, which is exactly the state the
    /// bug needs and no amount of concurrency reliably produces on its own.
    #[test]
    fn concurrent_first_lookups_create_one_queue_and_no_errors() {
        let (_dir, pool) = pool_with_account();
        // One short of the pool, because the lock holder below takes a
        // connection too and a racer that blocks in `pool.get()` would never
        // reach the barrier.
        let racers = 7;
        // +1 for this thread, which releases the lock once everyone is parked.
        let gate = Arc::new(Barrier::new(racers + 1));

        let mut blocker = pool.get().unwrap();
        let held = blocker
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .unwrap();

        let handles: Vec<_> = (0..racers)
            .map(|_| {
                let pool = pool.clone();
                let gate = gate.clone();
                std::thread::spawn(move || {
                    let c = pool.get().unwrap();
                    gate.wait();
                    // WAL never blocks readers, so the SELECT returns "missing"
                    // for all of them; the INSERT then waits on busy_timeout.
                    queue_id(&c, 1, "phone-1", "mac-1").map_err(|e| format!("{} {}", e.0, e.1))
                })
            })
            .collect();

        gate.wait();
        std::thread::sleep(std::time::Duration::from_millis(200));
        held.rollback().unwrap();
        drop(blocker);

        let ids: Vec<_> = handles.into_iter().map(|h| h.join().unwrap()).collect();
        let failed: Vec<_> = ids.iter().filter_map(|r| r.as_ref().err()).collect();
        assert!(failed.is_empty(), "every racer must get an id: {failed:?}");

        // This is also what pins the upsert to its RETURNING value: with
        // last_insert_rowid() the losers take the DO UPDATE branch, insert
        // nothing, and report whatever their connection inserted last - id 0 on
        // a fresh one. Wrong queue, no error.
        let ids: Vec<i64> = ids.into_iter().map(Result::unwrap).collect();
        assert!(
            ids.windows(2).all(|w| w[0] == w[1]),
            "all racers must agree on one queue id, got {ids:?}"
        );
        let rows: i64 = pool
            .get()
            .unwrap()
            .query_row("SELECT COUNT(*) FROM queue", [], |r| r.get(0))
            .unwrap();
        assert_eq!(rows, 1, "exactly one queue row must exist");
    }

    /// EKO_RETENTION_DAYS is operator input. Both of its bad values move the
    /// cutoff into the future, which deletes everything rather than nothing.
    #[test]
    fn an_unusable_retention_keeps_everything_instead_of_wiping_it() {
        for days in [-1, 0, i64::MAX, i64::MAX / 86_400_000 + 1] {
            let (_dir, pool) = pool_with_account();
            let c = pool.get().unwrap();
            c.execute(
                "INSERT INTO queue (id, account_id, sender, recipient, created_at)
                 VALUES (1, 1, 'a', 'b', ?1)",
                params![now_ms()],
            )
            .unwrap();
            c.execute(
                "INSERT INTO envelope (queue_id, envelope_id, aad, body, byte_len, created_at)
                 VALUES (1, 1, x'00', x'00', 1, ?1)",
                params![now_ms()],
            )
            .unwrap();
            drop(c);

            assert_eq!(sweep(&pool, days).unwrap(), 0, "days = {days}");
            let left: i64 = pool
                .get()
                .unwrap()
                .query_row("SELECT COUNT(*) FROM envelope", [], |r| r.get(0))
                .unwrap();
            assert_eq!(left, 1, "a fresh envelope survived days = {days}");
        }
    }

    /// The ordinary case must still collect what is genuinely past retention.
    #[test]
    fn a_sane_retention_still_prunes_old_envelopes() {
        let (_dir, pool) = pool_with_account();
        let c = pool.get().unwrap();
        c.execute(
            "INSERT INTO queue (id, account_id, sender, recipient, created_at)
             VALUES (1, 1, 'a', 'b', 0)",
            [],
        )
        .unwrap();
        let old = now_ms() - 40 * 86_400_000;
        c.execute(
            "INSERT INTO envelope (queue_id, envelope_id, aad, body, byte_len, created_at)
             VALUES (1, 1, x'00', x'00', 1, ?1)",
            params![old],
        )
        .unwrap();
        c.execute(
            "INSERT INTO envelope (queue_id, envelope_id, aad, body, byte_len, created_at)
             VALUES (1, 2, x'00', x'00', 1, ?1)",
            params![now_ms()],
        )
        .unwrap();
        drop(c);

        assert_eq!(sweep(&pool, 30).unwrap(), 1);
        let left: i64 = pool
            .get()
            .unwrap()
            .query_row("SELECT COUNT(*) FROM envelope", [], |r| r.get(0))
            .unwrap();
        assert_eq!(left, 1, "only the 40-day-old envelope should go");
    }

    /// Queues are directional, and a repeat lookup must be stable.
    #[test]
    fn the_two_directions_are_distinct_stable_queues() {
        let (_dir, pool) = pool_with_account();
        let c = pool.get().unwrap();
        let first = queue_id(&c, 1, "phone-1", "mac-1").unwrap();
        let second = queue_id(&c, 1, "mac-1", "phone-1").unwrap();
        assert_ne!(first, second);
        assert_eq!(queue_id(&c, 1, "phone-1", "mac-1").unwrap(), first);
    }

    /// A panicking handler must fail one request, not the process. Note this
    /// asserts the layer is wired; unwinding itself is what `panic = "abort"`
    /// would defeat, which is why the release profile no longer sets it.
    #[tokio::test]
    async fn a_panicking_handler_becomes_a_500() {
        use tower::ServiceExt;
        // A named handler with a concrete return type: a bare `async { panic!()
        // }` has no type for axum to turn into a response.
        async fn boom() -> String {
            panic!("deliberate")
        }
        let app = with_shared_layers(Router::new().route("/boom", get(boom)));
        let res = app
            .oneshot(
                axum::http::Request::builder()
                    .uri("/boom")
                    .body(axum::body::Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::INTERNAL_SERVER_ERROR);
    }
}

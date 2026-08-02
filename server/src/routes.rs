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

// ---------------------------------------------------------------- errors ---

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
    let raw = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
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
    let is_admin: i64 = c
        .query_row(
            "SELECT is_admin FROM account WHERE id = ?1",
            params![account_id],
            |r| r.get(0),
        )
        .map_err(|_| unauthorized())?;
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

fn account_count(c: &rusqlite::Connection) -> i64 {
    c.query_row("SELECT COUNT(*) FROM account", [], |r| r.get(0))
        .unwrap_or(0)
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

async fn create_account(
    State(state): State<AppState>,
    Json(body): Json<CreateAccount>,
) -> ApiResult<Json<AccountCreated>> {
    if body.username.trim().is_empty() || body.username.len() > 64 {
        return Err(bad("username must be 1-64 characters"));
    }
    if body.password.len() < 12 {
        return Err(bad("password must be at least 12 characters"));
    }
    let c = conn(&state.pool)?;
    let existing = account_count(&c);
    let first = existing == 0;

    // Applies to the first account too. An environment override exists to lock
    // a deployment down, and a lock that still lets a stranger claim an
    // unclaimed server is not a lock. Setup means booting once with
    // EKO_REGISTRATION=open, not exempting the most valuable account.
    if !registration_open(&state, &c) {
        return Err(forbidden("registration is closed"));
    }
    // The first account is the one that can claim the deployment, so it is the
    // one the bootstrap token guards.
    if first {
        if let Some(expected) = state.config.bootstrap_token.as_deref() {
            match body.bootstrap_token.as_deref() {
                Some(given) if given == expected => {}
                _ => return Err(forbidden("bootstrap token required")),
            }
        }
    }

    let hash = auth::hash_password(&body.password).map_err(|_| internal())?;
    c.execute(
        "INSERT INTO account (username, password_hash, is_admin, created_at)
         VALUES (?1, ?2, ?3, ?4)",
        params![body.username, hash, first as i64, now_ms()],
    )
    .map_err(|e| {
        if e.to_string().contains("UNIQUE") {
            ApiError::new(StatusCode::CONFLICT, "username taken")
        } else {
            internal()
        }
    })?;
    Ok(Json(AccountCreated {
        account_id: c.last_insert_rowid(),
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
    let c = conn(&state.pool)?;
    let row: Option<(i64, String)> = c
        .query_row(
            "SELECT id, password_hash FROM account WHERE username = ?1",
            params![body.username],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(|_| internal())?;
    let (account_id, hash) = row.ok_or_else(unauthorized)?;
    if !auth::verify_password(&body.password, &hash) {
        return Err(unauthorized());
    }
    let subject = format!("user:{account_id}");
    let (token, expires_at) = issue_token(
        &c,
        account_id,
        &subject,
        false,
        state.config.token_ttl_secs,
    )?;
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
        params![if body.registration_open { "true" } else { "false" }],
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
        .filter_map(Result::ok)
        .collect();
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
    c.execute("DELETE FROM token WHERE subject = ?1", params![device_id])
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
    if body.device_id.trim().is_empty() || body.device_id.len() > 128 {
        return Err(bad("device_id must be 1-128 characters"));
    }
    let key = b64()
        .decode(body.public_key.as_bytes())
        .map_err(|_| bad("public_key must be base64url"))?;
    if p256::ecdsa::VerifyingKey::from_sec1_bytes(&key).is_err() {
        return Err(bad("public_key is not a valid P-256 point"));
    }

    let c = conn(&state.pool)?;
    let digest = auth::sha256(body.token.as_bytes());
    let row: Option<(i64, i64, Option<i64>)> = c
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

    c.execute(
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
    .map_err(|e| {
        if e.to_string().contains("UNIQUE") {
            ApiError::new(StatusCode::CONFLICT, "device already enrolled")
        } else {
            internal()
        }
    })?;
    // Single use: consumed only after the device row committed, so a failed
    // enrolment does not burn the operator's token.
    c.execute(
        "UPDATE enrolment_token SET consumed_at = ?1 WHERE token_hash = ?2",
        params![now_ms(), digest],
    )
    .map_err(|_| internal())?;

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
    let nonce = b64()
        .decode(body.nonce.as_bytes())
        .map_err(|_| bad("nonce must be base64url"))?;
    let signature = b64()
        .decode(body.signature.as_bytes())
        .map_err(|_| bad("signature must be base64url"))?;

    let c = conn(&state.pool)?;
    let row: Option<(String, i64, Option<i64>)> = c
        .query_row(
            "SELECT device_id, expires_at, consumed_at FROM auth_nonce WHERE nonce = ?1",
            params![nonce],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()
        .map_err(|_| internal())?;
    let (nonce_device, expires_at, consumed_at) = row.ok_or_else(unauthorized)?;
    if consumed_at.is_some() || expires_at < now_ms() || nonce_device != body.device_id {
        return Err(unauthorized());
    }
    // Burn the nonce before verifying, so a signature-verification failure
    // cannot be retried against the same challenge.
    c.execute(
        "UPDATE auth_nonce SET consumed_at = ?1 WHERE nonce = ?2",
        params![now_ms(), nonce],
    )
    .map_err(|_| internal())?;

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

fn queue_id(
    c: &rusqlite::Connection,
    account_id: i64,
    sender: &str,
    recipient: &str,
) -> ApiResult<i64> {
    if let Some(id) = c
        .query_row(
            "SELECT id FROM queue WHERE sender = ?1 AND recipient = ?2",
            params![sender, recipient],
            |r| r.get::<_, i64>(0),
        )
        .optional()
        .map_err(|_| internal())?
    {
        return Ok(id);
    }
    c.execute(
        "INSERT INTO queue (account_id, sender, recipient, created_at) VALUES (?1, ?2, ?3, ?4)",
        params![account_id, sender, recipient, now_ms()],
    )
    .map_err(|_| internal())?;
    Ok(c.last_insert_rowid())
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
    let aad = b64().decode(body.aad.as_bytes()).map_err(|_| bad("aad"))?;
    let sealed = b64()
        .decode(body.body.as_bytes())
        .map_err(|_| bad("body"))?;
    if sealed.len() > state.config.max_envelope_bytes {
        return Err(ApiError::new(
            StatusCode::PAYLOAD_TOO_LARGE,
            "envelope too large",
        ));
    }

    let c = conn(&state.pool)?;
    require_same_account_peer(&c, device.account_id, &peer)?;

    let used: i64 = c
        .query_row(
            "SELECT COALESCE(SUM(e.byte_len), 0) FROM envelope e
             JOIN queue q ON q.id = e.queue_id WHERE q.account_id = ?1",
            params![device.account_id],
            |r| r.get(0),
        )
        .unwrap_or(0);
    if used + sealed.len() as i64 > state.config.account_quota_bytes {
        return Err(ApiError::new(
            StatusCode::INSUFFICIENT_STORAGE,
            "account quota exceeded",
        ));
    }

    let qid = queue_id(&c, device.account_id, &device.device_id, &peer)?;
    // Monotonic per queue. The relay orders by this and nothing else; Eko's own
    // sequence numbers are inside the ciphertext and never seen here.
    let next: i64 = c
        .query_row(
            "UPDATE queue SET next_envelope_id = next_envelope_id + 1
             WHERE id = ?1 RETURNING next_envelope_id - 1",
            params![qid],
            |r| r.get(0),
        )
        .map_err(|_| internal())?;
    let len = sealed.len() as i64;
    c.execute(
        "INSERT INTO envelope (queue_id, envelope_id, aad, body, byte_len, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![qid, next, aad, sealed, len, now_ms()],
    )
    .map_err(|_| internal())?;

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
    let qid = queue_id(&c, device.account_id, &peer, &device.device_id)?;
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
        .filter_map(Result::ok)
        .collect();

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
    let c = conn(&state.pool)?;
    require_same_account_peer(&c, device.account_id, &peer)?;
    let qid = queue_id(&c, device.account_id, &peer, &device.device_id)?;

    // Never move a cursor backwards: a stale client must not resurrect pruned
    // positions or cause a re-delivery storm.
    c.execute(
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
    c.execute(
        "DELETE FROM envelope WHERE queue_id = ?1 AND envelope_id <= ?2",
        params![qid, body.acked_envelope_id],
    )
    .map_err(|_| internal())?;

    Ok(StatusCode::NO_CONTENT)
}

// ------------------------------------------------------------- lifecycle ---

pub fn sweep(pool: &Pool, retention_days: i64) -> Result<usize, ()> {
    let c = pool.get().map_err(|_| ())?;
    let cutoff = now_ms() - retention_days * 86_400_000;
    let removed = c
        .execute("DELETE FROM envelope WHERE created_at < ?1", params![cutoff])
        .map_err(|_| ())?;
    c.execute(
        "DELETE FROM auth_nonce WHERE expires_at < ?1",
        params![now_ms()],
    )
    .ok();
    c.execute("DELETE FROM token WHERE expires_at < ?1", params![now_ms()])
        .ok();
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
    Router::new()
        .route("/healthz", get(healthz))
        .route("/readyz", get(readyz))
        .route("/api/v1/accounts", post(create_account))
        .route("/api/v1/accounts/login", post(login))
        .route(
            "/api/v1/admin/settings",
            patch(patch_settings).get(get_settings),
        )
        .route("/api/v1/admin/enrolment-tokens", post(mint_enrolment_token))
        .route("/api/v1/admin/devices", get(list_devices))
        .route("/api/v1/admin/devices/{device_id}", axum::routing::delete(revoke_device))
        .route("/api/v1/devices/enrol", post(enrol_device))
        .route("/api/v1/devices/challenge", post(device_challenge))
        .route("/api/v1/devices/auth", post(device_auth))
        .route(
            "/api/v1/queues/{peer}/envelopes",
            post(deposit).get(drain),
        )
        .route("/api/v1/queues/{peer}/cursor", post(set_cursor))
        .layer(tower_http::trace::TraceLayer::new_for_http())
        .with_state(state)
}

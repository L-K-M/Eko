//! End-to-end exercise of the relay over its real HTTP surface.
//!
//! Covers the whole operator story: claim the deployment, close registration,
//! enrol two devices, move sealed envelopes between them, acknowledge, and
//! confirm the isolation and revocation rules actually hold.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use base64::Engine;
use eko_relay::{AppState, Config, RegistrationOverride};
use p256::ecdsa::{signature::Signer, Signature, SigningKey, VerifyingKey};
use serde_json::{json, Value};
use std::sync::Arc;
use tower::ServiceExt;

fn b64() -> base64::engine::general_purpose::GeneralPurpose {
    base64::engine::general_purpose::URL_SAFE_NO_PAD
}

struct Harness {
    app: axum::Router,
    _dir: tempfile::TempDir,
}

fn config_for(path: &str, registration: RegistrationOverride, bootstrap: Option<&str>) -> Config {
    Config {
        bind: "127.0.0.1:0".into(),
        database: path.to_string(),
        registration,
        bootstrap_token: bootstrap.map(|s| s.to_string()),
        max_envelope_bytes: 1_048_576,
        retention_days: 30,
        account_quota_bytes: 1024 * 1024,
        token_ttl_secs: 3600,
    }
}

/// A second router over the *same* database with different configuration, which
/// is what "boot open, set up, then set closed and recreate" actually looks
/// like to an operator.
fn reopen(h: &Harness, registration: RegistrationOverride) -> axum::Router {
    let path = h._dir.path().join("relay.db");
    let config = config_for(&path.to_string_lossy(), registration, None);
    let pool = eko_relay::db::open(&config.database).unwrap();
    eko_relay::app(AppState {
        pool,
        config: Arc::new(config),
    })
}

fn harness(registration: RegistrationOverride, bootstrap: Option<&str>) -> Harness {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("relay.db");
    let config = config_for(&path.to_string_lossy(), registration, bootstrap);
    let pool = eko_relay::db::open(&config.database).unwrap();
    let state = AppState {
        pool,
        config: Arc::new(config),
    };
    Harness {
        app: eko_relay::app(state),
        _dir: dir,
    }
}

async fn call(
    app: &axum::Router,
    method: &str,
    uri: &str,
    token: Option<&str>,
    body: Option<Value>,
) -> (StatusCode, Value) {
    let mut req = Request::builder().method(method).uri(uri);
    if let Some(t) = token {
        req = req.header("authorization", format!("Bearer {t}"));
    }
    let req = match body {
        Some(v) => req
            .header("content-type", "application/json")
            .body(Body::from(serde_json::to_vec(&v).unwrap()))
            .unwrap(),
        None => req.body(Body::empty()).unwrap(),
    };
    let res = app.clone().oneshot(req).await.unwrap();
    let status = res.status();
    let bytes = axum::body::to_bytes(res.into_body(), 8 * 1024 * 1024)
        .await
        .unwrap();
    let value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
    (status, value)
}

/// Enrol a device and authenticate it, returning (device_id, bearer token).
async fn enrol_and_auth(
    app: &axum::Router,
    user_token: &str,
    device_id: &str,
    platform: &str,
) -> (SigningKey, String) {
    let (status, tok) = call(
        app,
        "POST",
        "/api/v1/account/enrolment-tokens",
        Some(user_token),
        Some(json!({})),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "mint enrolment token: {tok}");
    let enrolment = tok["token"].as_str().unwrap().to_string();

    let signing = SigningKey::random(&mut rand::thread_rng());
    let public = VerifyingKey::from(&signing)
        .to_encoded_point(false)
        .as_bytes()
        .to_vec();

    let (status, body) = call(
        app,
        "POST",
        "/api/v1/devices/enrol",
        None,
        Some(json!({
            "token": enrolment,
            "device_id": device_id,
            "public_key": b64().encode(&public),
            "name": device_id,
            "platform": platform,
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "enrol: {body}");

    let token = authenticate(app, &signing, device_id).await;
    (signing, token)
}

async fn authenticate(app: &axum::Router, signing: &SigningKey, device_id: &str) -> String {
    let (status, ch) = call(
        app,
        "POST",
        "/api/v1/devices/challenge",
        None,
        Some(json!({ "device_id": device_id })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "challenge: {ch}");
    let nonce = b64().decode(ch["nonce"].as_str().unwrap()).unwrap();

    let mut message = Vec::new();
    message.extend_from_slice(b"eko-relay-auth-v1");
    message.extend_from_slice(&nonce);
    message.extend_from_slice(device_id.as_bytes());
    let sig: Signature = signing.sign(&message);

    let (status, body) = call(
        app,
        "POST",
        "/api/v1/devices/auth",
        None,
        Some(json!({
            "device_id": device_id,
            "nonce": ch["nonce"],
            "signature": b64().encode(sig.to_der().as_bytes()),
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "auth: {body}");
    body["token"].as_str().unwrap().to_string()
}

async fn first_account(app: &axum::Router, bootstrap: Option<&str>) -> String {
    let mut payload = json!({"username": "owner", "password": "correct horse battery"});
    if let Some(t) = bootstrap {
        payload["bootstrap_token"] = json!(t);
    }
    let (status, body) = call(app, "POST", "/api/v1/accounts", None, Some(payload)).await;
    assert_eq!(status, StatusCode::OK, "create account: {body}");
    assert_eq!(body["is_admin"], json!(true), "first account must be admin");

    let (status, body) = call(
        app,
        "POST",
        "/api/v1/accounts/login",
        None,
        Some(json!({"username": "owner", "password": "correct horse battery"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "login: {body}");
    body["token"].as_str().unwrap().to_string()
}

// --------------------------------------------------------------- tests ---

#[tokio::test]
async fn health_and_readiness() {
    let h = harness(RegistrationOverride::Unset, None);
    let (status, _) = call(&h.app, "GET", "/healthz", None, None).await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = call(&h.app, "GET", "/readyz", None, None).await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn first_account_becomes_admin_and_can_close_registration() {
    let h = harness(RegistrationOverride::Unset, None);
    let owner = first_account(&h.app, None).await;

    // Second account is allowed while registration is open.
    let (status, _) = call(
        &h.app,
        "POST",
        "/api/v1/accounts",
        None,
        Some(json!({"username": "second", "password": "another long password"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let (status, body) = call(
        &h.app,
        "PATCH",
        "/api/v1/admin/settings",
        Some(&owner),
        Some(json!({"registration_open": false})),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["registration_open"], json!(false));

    // Third is refused.
    let (status, body) = call(
        &h.app,
        "POST",
        "/api/v1/accounts",
        None,
        Some(json!({"username": "third", "password": "yet another password"})),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
}

#[tokio::test]
async fn environment_override_cannot_be_reopened_through_the_api() {
    let h = harness(RegistrationOverride::Closed, None);
    // Even the very first account is refused when the environment forces closed,
    // which is what makes the override a real lock rather than a preference.
    let (status, _) = call(
        &h.app,
        "POST",
        "/api/v1/accounts",
        None,
        Some(json!({"username": "owner", "password": "correct horse battery"})),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    // The property the name actually promises: with an admin already present
    // and the environment forcing closed, that admin cannot reopen. Set up
    // through an unset router, then reopen the same database as closed.
    let h = harness(RegistrationOverride::Unset, None);
    let owner = first_account(&h.app, None).await;
    let locked = reopen(&h, RegistrationOverride::Closed);

    let (status, body) = call(
        &locked,
        "PATCH",
        "/api/v1/admin/settings",
        Some(&owner),
        Some(json!({"registration_open": true})),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(
        body["registration_open"],
        json!(false),
        "the admin must not be able to reopen a locked deployment"
    );
    assert_eq!(body["forced_by_environment"], json!(true));

    // And the lock is real, not just reported: creation is still refused.
    let (status, _) = call(
        &locked,
        "POST",
        "/api/v1/accounts",
        None,
        Some(json!({"username": "after", "password": "correct horse battery"})),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

/// Deposits must not be able to race past the account quota.
#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
async fn concurrent_deposits_cannot_exceed_the_quota() {
    let h = harness(RegistrationOverride::Unset, None);
    let owner = first_account(&h.app, None).await;
    let (_, phone) = enrol_and_auth(&h.app, &owner, "phone-1", "android").await;
    let (_, mac) = enrol_and_auth(&h.app, &owner, "mac-1", "macos").await;

    // Quota is 1 MiB and each envelope is 64 KiB, so 16 fit; the rest must be
    // refused however concurrently they arrive.
    let mut joins = Vec::new();
    for _ in 0..40 {
        let app = h.app.clone();
        let phone = phone.clone();
        joins.push(tokio::spawn(async move {
            call(
                &app,
                "POST",
                "/api/v1/queues/mac-1/envelopes",
                Some(&phone),
                Some(json!({
                    "aad": b64().encode(b""),
                    "body": b64().encode(vec![0u8; 65536]),
                })),
            )
            .await
            .0
        }));
    }
    let mut accepted = 0;
    for j in joins {
        if j.await.unwrap() == StatusCode::OK {
            accepted += 1;
        }
    }

    let (status, list) = call(
        &h.app,
        "GET",
        "/api/v1/queues/phone-1/envelopes?after=0&limit=500",
        Some(&mac),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "drain must succeed: {list}");
    let items = list.as_array().unwrap();
    assert!(!items.is_empty(), "some deposits should have been accepted");
    let stored: i64 = items
        .iter()
        .map(|e| b64().decode(e["body"].as_str().unwrap()).unwrap().len() as i64)
        .sum();
    assert!(
        stored <= 1024 * 1024,
        "stored {stored} bytes against a 1 MiB quota (accepted {accepted})"
    );
    // A 200 that stored nothing would still satisfy the ceiling above, so tie
    // the two counts together: every acknowledged deposit must be drainable.
    assert_eq!(
        accepted,
        items.len(),
        "every accepted deposit must appear in the drain"
    );
}

#[tokio::test]
async fn bootstrap_token_guards_the_claim_window() {
    let h = harness(RegistrationOverride::Unset, Some("s3cret-bootstrap"));
    let (status, _) = call(
        &h.app,
        "POST",
        "/api/v1/accounts",
        None,
        Some(json!({"username": "squatter", "password": "correct horse battery"})),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "first account must require the bootstrap token"
    );
    let owner = first_account(&h.app, Some("s3cret-bootstrap")).await;
    assert!(!owner.is_empty());
}

#[tokio::test]
async fn weak_credentials_are_refused() {
    let h = harness(RegistrationOverride::Unset, None);
    let (status, _) = call(
        &h.app,
        "POST",
        "/api/v1/accounts",
        None,
        Some(json!({"username": "owner", "password": "short"})),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // Bounded above as well. This is the one endpoint an unauthenticated caller
    // can make run Argon2 at will, so it must not also choose how much of it.
    let (status, _) = call(
        &h.app,
        "POST",
        "/api/v1/accounts",
        None,
        Some(json!({"username": "owner", "password": "x".repeat(1025)})),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "oversized password");

    let (status, _) = call(
        &h.app,
        "POST",
        "/api/v1/accounts/login",
        None,
        Some(json!({"username": "owner", "password": "x".repeat(100_000)})),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED, "oversized login password");
}

/// `device_id` was bounded and its two free-text neighbours were not, though
/// they sit in the same row and come back out of `list_devices`.
#[tokio::test]
async fn device_name_and_platform_are_bounded() {
    let h = harness(RegistrationOverride::Unset, None);
    let owner = first_account(&h.app, None).await;
    let (status, tok) = call(
        &h.app,
        "POST",
        "/api/v1/account/enrolment-tokens",
        Some(&owner),
        Some(json!({})),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "mint: {tok}");

    let signing = SigningKey::random(&mut rand::thread_rng());
    let public = VerifyingKey::from(&signing)
        .to_encoded_point(false)
        .as_bytes()
        .to_vec();
    let (status, body) = call(
        &h.app,
        "POST",
        "/api/v1/devices/enrol",
        None,
        Some(json!({
            "token": tok["token"],
            "device_id": "phone-1",
            "public_key": b64().encode(&public),
            "name": "n".repeat(257),
            "platform": "android",
        })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "oversized name: {body}");

    // And platform, which the name of this test promised but did not check.
    // Enrolment tokens are single-use, so the second attempt needs its own.
    let (status, tok) = call(
        &h.app,
        "POST",
        "/api/v1/account/enrolment-tokens",
        Some(&owner),
        Some(json!({})),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "mint: {tok}");
    let (status, body) = call(
        &h.app,
        "POST",
        "/api/v1/devices/enrol",
        None,
        Some(json!({
            "token": tok["token"],
            "device_id": "phone-2",
            "public_key": b64().encode(&public),
            "name": "phone",
            "platform": "p".repeat(65),
        })),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::BAD_REQUEST,
        "oversized platform: {body}"
    );
}

#[tokio::test]
async fn envelopes_round_trip_and_acknowledgement_prunes() {
    let h = harness(RegistrationOverride::Unset, None);
    let owner = first_account(&h.app, None).await;
    let (_, phone) = enrol_and_auth(&h.app, &owner, "phone-1", "android").await;
    let (_, mac) = enrol_and_auth(&h.app, &owner, "mac-1", "macos").await;

    for i in 0..3u8 {
        let (status, body) = call(
            &h.app,
            "POST",
            "/api/v1/queues/mac-1/envelopes",
            Some(&phone),
            Some(json!({
                "aad": b64().encode(b"aad"),
                "body": b64().encode(vec![i; 32]),
            })),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "deposit: {body}");
        assert_eq!(body["envelope_id"], json!(i as i64 + 1));
    }

    let (status, list) = call(
        &h.app,
        "GET",
        "/api/v1/queues/phone-1/envelopes?after=0",
        Some(&mac),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "drain: {list}");
    let items = list.as_array().unwrap();
    assert_eq!(items.len(), 3);
    assert_eq!(items[0]["envelope_id"], json!(1));
    assert_eq!(
        b64().decode(items[2]["body"].as_str().unwrap()).unwrap(),
        vec![2u8; 32],
        "payload must survive the round trip byte for byte"
    );

    // Incremental drain honours the cursor parameter.
    let (_, list) = call(
        &h.app,
        "GET",
        "/api/v1/queues/phone-1/envelopes?after=2",
        Some(&mac),
        None,
    )
    .await;
    assert_eq!(list.as_array().unwrap().len(), 1);

    let (status, _) = call(
        &h.app,
        "POST",
        "/api/v1/queues/phone-1/cursor",
        Some(&mac),
        Some(json!({"acked_envelope_id": 3})),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    let (_, list) = call(
        &h.app,
        "GET",
        "/api/v1/queues/phone-1/envelopes?after=0",
        Some(&mac),
        None,
    )
    .await;
    assert!(
        list.as_array().unwrap().is_empty(),
        "acknowledged envelopes must be pruned"
    );

    // Sequence continues past pruned positions rather than restarting.
    let (_, body) = call(
        &h.app,
        "POST",
        "/api/v1/queues/mac-1/envelopes",
        Some(&phone),
        Some(json!({"aad": b64().encode(b"aad"), "body": b64().encode(b"next")})),
    )
    .await;
    assert_eq!(body["envelope_id"], json!(4));
}

#[tokio::test]
async fn a_cursor_never_moves_backwards() {
    let h = harness(RegistrationOverride::Unset, None);
    let owner = first_account(&h.app, None).await;
    let (_, phone) = enrol_and_auth(&h.app, &owner, "phone-1", "android").await;
    let (_, mac) = enrol_and_auth(&h.app, &owner, "mac-1", "macos").await;

    // Asserted, not fired and forgotten: if the setup silently fails, the real
    // assertions below still "pass" for entirely the wrong reason.
    for _ in 0..2 {
        let (status, body) = call(
            &h.app,
            "POST",
            "/api/v1/queues/mac-1/envelopes",
            Some(&phone),
            Some(json!({"aad": b64().encode(b""), "body": b64().encode(b"x")})),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "deposit: {body}");
    }
    let (status, body) = call(
        &h.app,
        "POST",
        "/api/v1/queues/phone-1/cursor",
        Some(&mac),
        Some(json!({"acked_envelope_id": 2})),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT, "ack: {body}");
    // A stale client replaying an old ack must not resurrect anything.
    let (status, _) = call(
        &h.app,
        "POST",
        "/api/v1/queues/phone-1/cursor",
        Some(&mac),
        Some(json!({"acked_envelope_id": 1})),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    let (_, list) = call(
        &h.app,
        "GET",
        "/api/v1/queues/phone-1/envelopes?after=0",
        Some(&mac),
        None,
    )
    .await;
    assert!(list.as_array().unwrap().is_empty());
}

#[tokio::test]
async fn devices_of_another_account_are_not_reachable() {
    let h = harness(RegistrationOverride::Unset, None);
    let owner = first_account(&h.app, None).await;
    let (_, phone) = enrol_and_auth(&h.app, &owner, "phone-1", "android").await;

    // A second account with its own device.
    let (status, body) = call(
        &h.app,
        "POST",
        "/api/v1/accounts",
        None,
        Some(json!({"username": "stranger", "password": "stranger password!!"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "stranger account: {body}");
    let (_, stranger) = call(
        &h.app,
        "POST",
        "/api/v1/accounts/login",
        None,
        Some(json!({"username": "stranger", "password": "stranger password!!"})),
    )
    .await;
    let stranger_token = stranger["token"].as_str().unwrap().to_string();
    enrol_and_auth(&h.app, &stranger_token, "other-mac", "macos").await;

    let (status, body) = call(
        &h.app,
        "POST",
        "/api/v1/queues/other-mac/envelopes",
        Some(&phone),
        Some(json!({"aad": b64().encode(b""), "body": b64().encode(b"x")})),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "cross-account deposit must be refused: {body}"
    );
}

#[tokio::test]
async fn a_revoked_device_loses_access_immediately() {
    let h = harness(RegistrationOverride::Unset, None);
    let owner = first_account(&h.app, None).await;
    let (_, phone) = enrol_and_auth(&h.app, &owner, "phone-1", "android").await;
    enrol_and_auth(&h.app, &owner, "mac-1", "macos").await;

    let (status, _) = call(
        &h.app,
        "DELETE",
        "/api/v1/account/devices/phone-1",
        Some(&owner),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    let (status, _) = call(
        &h.app,
        "POST",
        "/api/v1/queues/mac-1/envelopes",
        Some(&phone),
        Some(json!({"aad": b64().encode(b""), "body": b64().encode(b"x")})),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn a_challenge_nonce_is_single_use() {
    let h = harness(RegistrationOverride::Unset, None);
    let owner = first_account(&h.app, None).await;
    let (signing, _) = enrol_and_auth(&h.app, &owner, "phone-1", "android").await;

    let (_, ch) = call(
        &h.app,
        "POST",
        "/api/v1/devices/challenge",
        None,
        Some(json!({ "device_id": "phone-1" })),
    )
    .await;
    let nonce = b64().decode(ch["nonce"].as_str().unwrap()).unwrap();
    let mut message = Vec::new();
    message.extend_from_slice(b"eko-relay-auth-v1");
    message.extend_from_slice(&nonce);
    message.extend_from_slice(b"phone-1");
    let sig: Signature = signing.sign(&message);
    let payload = json!({
        "device_id": "phone-1",
        "nonce": ch["nonce"],
        "signature": b64().encode(sig.to_der().as_bytes()),
    });

    let (status, _) = call(
        &h.app,
        "POST",
        "/api/v1/devices/auth",
        None,
        Some(payload.clone()),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let (status, _) = call(&h.app, "POST", "/api/v1/devices/auth", None, Some(payload)).await;
    assert_eq!(
        status,
        StatusCode::UNAUTHORIZED,
        "replaying a consumed nonce must fail"
    );
}

#[tokio::test]
async fn a_forged_signature_is_refused() {
    let h = harness(RegistrationOverride::Unset, None);
    let owner = first_account(&h.app, None).await;
    enrol_and_auth(&h.app, &owner, "phone-1", "android").await;

    // Someone who knows the device id but not its key.
    let attacker = SigningKey::random(&mut rand::thread_rng());
    let (_, ch) = call(
        &h.app,
        "POST",
        "/api/v1/devices/challenge",
        None,
        Some(json!({ "device_id": "phone-1" })),
    )
    .await;
    let nonce = b64().decode(ch["nonce"].as_str().unwrap()).unwrap();
    let mut message = Vec::new();
    message.extend_from_slice(b"eko-relay-auth-v1");
    message.extend_from_slice(&nonce);
    message.extend_from_slice(b"phone-1");
    let sig: Signature = attacker.sign(&message);

    let (status, _) = call(
        &h.app,
        "POST",
        "/api/v1/devices/auth",
        None,
        Some(json!({
            "device_id": "phone-1",
            "nonce": ch["nonce"],
            "signature": b64().encode(sig.to_der().as_bytes()),
        })),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn an_oversized_envelope_is_refused() {
    let h = harness(RegistrationOverride::Unset, None);
    let owner = first_account(&h.app, None).await;
    let (_, phone) = enrol_and_auth(&h.app, &owner, "phone-1", "android").await;
    enrol_and_auth(&h.app, &owner, "mac-1", "macos").await;

    // One byte past the frame limit the protocol itself enforces.
    let oversized = vec![0u8; 1_048_577];
    let (status, _) = call(
        &h.app,
        "POST",
        "/api/v1/queues/mac-1/envelopes",
        Some(&phone),
        Some(json!({"aad": b64().encode(b""), "body": b64().encode(&oversized)})),
    )
    .await;
    assert_eq!(status, StatusCode::PAYLOAD_TOO_LARGE);

    // And exactly at the limit is still accepted. The encoded-length pre-check
    // that rejects before decoding has to be loose enough to let this through,
    // or the limit it guards would be unreachable.
    let at_limit = vec![0u8; 1_048_576];
    let (status, body) = call(
        &h.app,
        "POST",
        "/api/v1/queues/mac-1/envelopes",
        Some(&phone),
        Some(json!({"aad": b64().encode(b""), "body": b64().encode(&at_limit)})),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "envelope at the limit: {body}");
}

#[tokio::test]
async fn unauthenticated_and_user_tokens_cannot_touch_queues() {
    let h = harness(RegistrationOverride::Unset, None);
    let owner = first_account(&h.app, None).await;
    enrol_and_auth(&h.app, &owner, "mac-1", "macos").await;

    let (status, _) = call(
        &h.app,
        "GET",
        "/api/v1/queues/mac-1/envelopes?after=0",
        None,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    // A user token is not a device token; queues are device-scoped only.
    let (status, _) = call(
        &h.app,
        "GET",
        "/api/v1/queues/mac-1/envelopes?after=0",
        Some(&owner),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

// ----------------------------------------------------- concurrency ---

/// The first account becomes admin and controls registration and enrolment, so
/// two requests both seeing an empty table would be a privilege escalation.
#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
async fn concurrent_first_accounts_produce_exactly_one_admin() {
    let h = harness(RegistrationOverride::Unset, None);
    let mut joins = Vec::new();
    for i in 0..12 {
        let app = h.app.clone();
        joins.push(tokio::spawn(async move {
            call(
                &app,
                "POST",
                "/api/v1/accounts",
                None,
                Some(json!({
                    "username": format!("racer-{i}"),
                    "password": "correct horse battery",
                })),
            )
            .await
        }));
    }
    let mut admins = 0;
    let mut created = 0;
    for j in joins {
        let (status, body) = j.await.unwrap();
        if status == StatusCode::OK {
            created += 1;
            if body["is_admin"] == json!(true) {
                admins += 1;
            }
        }
    }
    assert!(created > 0, "at least one account should have been created");
    assert_eq!(admins, 1, "exactly one account may be admin, got {admins}");
}

/// A single-use enrolment token must stay single-use when several devices race
/// for it, or an intercepted token enrols a rogue device beside the real one.
#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
async fn an_enrolment_token_survives_concurrent_use_exactly_once() {
    let h = harness(RegistrationOverride::Unset, None);
    let owner = first_account(&h.app, None).await;
    let (status, tok) = call(
        &h.app,
        "POST",
        "/api/v1/account/enrolment-tokens",
        Some(&owner),
        Some(json!({})),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "mint enrolment token: {tok}");
    let token = tok["token"].as_str().unwrap().to_string();

    let mut joins = Vec::new();
    for i in 0..12 {
        let app = h.app.clone();
        let token = token.clone();
        joins.push(tokio::spawn(async move {
            let signing = SigningKey::random(&mut rand::thread_rng());
            let public = VerifyingKey::from(&signing)
                .to_encoded_point(false)
                .as_bytes()
                .to_vec();
            call(
                &app,
                "POST",
                "/api/v1/devices/enrol",
                None,
                Some(json!({
                    "token": token,
                    "device_id": format!("racer-{i}"),
                    "public_key": b64().encode(&public),
                    "name": "racer",
                    "platform": "android",
                })),
            )
            .await
        }));
    }
    let mut ok = 0;
    for j in joins {
        if j.await.unwrap().0 == StatusCode::OK {
            ok += 1;
        }
    }
    assert_eq!(ok, 1, "one token must enrol exactly one device, got {ok}");

    let (_, devices) = call(&h.app, "GET", "/api/v1/account/devices", Some(&owner), None).await;
    assert_eq!(devices.as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn an_oversized_aad_is_refused_and_aad_counts_against_quota() {
    let h = harness(RegistrationOverride::Unset, None);
    let owner = first_account(&h.app, None).await;
    let (_, phone) = enrol_and_auth(&h.app, &owner, "phone-1", "android").await;
    enrol_and_auth(&h.app, &owner, "mac-1", "macos").await;

    let (status, _) = call(
        &h.app,
        "POST",
        "/api/v1/queues/mac-1/envelopes",
        Some(&phone),
        Some(json!({
            "aad": b64().encode(vec![0u8; 4097]),
            "body": b64().encode(b"x"),
        })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "aad must be bounded");

    // An accepted aad is billed: the quota is 1 MiB in the harness, so ~300
    // envelopes of 4 KiB aad each must eventually be refused rather than stored
    // for free.
    let mut refused = false;
    for _ in 0..400 {
        let (status, _) = call(
            &h.app,
            "POST",
            "/api/v1/queues/mac-1/envelopes",
            Some(&phone),
            Some(json!({
                "aad": b64().encode(vec![0u8; 4096]),
                "body": b64().encode(b"x"),
            })),
        )
        .await;
        if status == StatusCode::INSUFFICIENT_STORAGE {
            refused = true;
            break;
        }
    }
    assert!(refused, "aad bytes must count against the account quota");
}

/// The boundary the `/api/v1/account/...` paths encode: managing your own
/// devices is not a privileged act, administering the deployment is. Enrolling
/// a phone must work for an ordinary account, or a non-admin user could never
/// use the relay at all; the registration toggle must not.
#[tokio::test]
async fn an_ordinary_account_manages_its_own_devices_but_not_the_deployment() {
    let h = harness(RegistrationOverride::Unset, None);
    let _owner = first_account(&h.app, None).await;

    let (status, _) = call(
        &h.app,
        "POST",
        "/api/v1/accounts",
        None,
        Some(json!({"username": "guest", "password": "another long password"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, body) = call(
        &h.app,
        "POST",
        "/api/v1/accounts/login",
        None,
        Some(json!({"username": "guest", "password": "another long password"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "login: {body}");
    let guest = body["token"].as_str().unwrap().to_string();

    // Its own devices: allowed, and the whole enrol/auth handshake must work.
    let (_, phone) = enrol_and_auth(&h.app, &guest, "guest-phone", "android").await;
    assert!(!phone.is_empty());
    let (status, devices) =
        call(&h.app, "GET", "/api/v1/account/devices", Some(&guest), None).await;
    assert_eq!(status, StatusCode::OK, "{devices}");
    assert_eq!(devices.as_array().unwrap().len(), 1);

    // The deployment: refused.
    let (status, body) = call(
        &h.app,
        "PATCH",
        "/api/v1/admin/settings",
        Some(&guest),
        Some(json!({"registration_open": false})),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
}

/// One intercepted (nonce, signature) pair must mint exactly one token. The
/// nonce was read, validated in Rust, and burned by a separate unconditional
/// UPDATE, so concurrent replays all saw `consumed_at IS NULL` and all
/// succeeded - the single-use challenge became multi-use.
///
/// Forced, not hoped for: an outside writer holds the database's write lock, so
/// every racer gets past the read and parks on the UPDATE. Releasing the lock
/// then runs all the burns back to back, which is the interleave the bug needs.
///
/// Real threads and a blocking barrier rather than tokio tasks. This runner has
/// four cores shared with every other test in the binary, and with spawned tasks
/// the last racer routinely had not issued its request before the others were
/// done - the concurrency the test claimed to create was not there. A
/// `std::sync::Barrier` cannot return until every thread has reached it, so
/// participation is guaranteed by construction rather than waited for.
#[test]
fn one_challenge_response_cannot_be_replayed_into_many_tokens() {
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .unwrap();

    let h = harness(RegistrationOverride::Unset, None);
    let (nonce_b64, sig_b64) = rt.block_on(async {
        let owner = first_account(&h.app, None).await;
        let (signing, _) = enrol_and_auth(&h.app, &owner, "phone-1", "android").await;

        // A single challenge, signed once - what an interceptor would have.
        let (status, ch) = call(
            &h.app,
            "POST",
            "/api/v1/devices/challenge",
            None,
            Some(json!({"device_id": "phone-1"})),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "challenge: {ch}");
        let nonce_b64 = ch["nonce"].as_str().unwrap().to_string();

        let mut message = Vec::new();
        message.extend_from_slice(b"eko-relay-auth-v1");
        message.extend_from_slice(&b64().decode(&nonce_b64).unwrap());
        message.extend_from_slice(b"phone-1");
        let sig: Signature = signing.sign(&message);
        (nonce_b64, b64().encode(sig.to_der().as_bytes()))
    });

    // A second pool over the same file, holding the write lock.
    let blocker_pool =
        eko_relay::db::open(&h._dir.path().join("relay.db").to_string_lossy()).unwrap();
    let mut blocker = blocker_pool.get().unwrap();
    let held = blocker
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .unwrap();

    let racers = 3;
    let gate = Arc::new(std::sync::Barrier::new(racers + 1));
    let handles: Vec<std::thread::JoinHandle<StatusCode>> = (0..racers)
        .map(|_| {
            let app = h.app.clone();
            let (nonce_b64, sig_b64) = (nonce_b64.clone(), sig_b64.clone());
            let gate = gate.clone();
            std::thread::spawn(move || {
                let rt = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .unwrap();
                gate.wait();
                rt.block_on(call(
                    &app,
                    "POST",
                    "/api/v1/devices/auth",
                    None,
                    Some(json!({
                        "device_id": "phone-1",
                        "nonce": nonce_b64,
                        "signature": sig_b64,
                    })),
                ))
                .0
            })
        })
        .collect();

    // Returns only once every racer thread is running.
    gate.wait();
    // Comfortably inside the 5 s busy_timeout: past that the racers stop waiting
    // on the lock and fail with "database is locked", which tests the harness
    // rather than the handler.
    std::thread::sleep(std::time::Duration::from_millis(300));
    let escaped = handles.iter().filter(|h| h.is_finished()).count();
    held.rollback().unwrap();
    drop(blocker);

    let codes: Vec<StatusCode> = handles.into_iter().map(|h| h.join().unwrap()).collect();
    let minted = codes.iter().filter(|s| **s == StatusCode::OK).count();

    // The security property.
    assert_eq!(
        minted, 1,
        "a single challenge minted {minted} tokens: {codes:?}"
    );
    // And the evidence it was actually contended: nobody had finished while the
    // lock was held, and every loser was turned away by the conditional UPDATE
    // finding the nonce already claimed - a 401 - rather than by giving up on
    // the lock, which would be a 500.
    assert_eq!(
        escaped, 0,
        "{escaped} racers finished before the lock was released; the race was not exercised"
    );
    assert!(
        codes
            .iter()
            .all(|s| *s == StatusCode::OK || *s == StatusCode::UNAUTHORIZED),
        "losers must be refused on the merits, not time out on the lock: {codes:?}"
    );
}

/// Revoking a device deleted every token whose `subject` matched the device id.
/// User sessions are stored in the same table under `user:<account_id>`, so a
/// device *named* `user:1` reached across accounts: enrol it, revoke it, and the
/// owner of account 1 is logged out. Device ids are free text and globally
/// unique, and account ids are small integers, so nothing made that hard.
#[tokio::test]
async fn revoking_a_device_cannot_log_out_another_account() {
    let h = harness(RegistrationOverride::Unset, None);
    let victim = first_account(&h.app, None).await;

    // Second account, the attacker. Registration is still open.
    let (status, _) = call(
        &h.app,
        "POST",
        "/api/v1/accounts",
        None,
        Some(json!({"username": "attacker", "password": "attacker password!"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, body) = call(
        &h.app,
        "POST",
        "/api/v1/accounts/login",
        None,
        Some(json!({"username": "attacker", "password": "attacker password!"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "login: {body}");
    let attacker = body["token"].as_str().unwrap().to_string();

    // The victim is account 1, so their session token has subject "user:1".
    enrol_and_auth(&h.app, &attacker, "user:1", "android").await;
    let (status, _) = call(
        &h.app,
        "DELETE",
        "/api/v1/account/devices/user:1",
        Some(&attacker),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT, "revoke own device");

    // The victim's session must be untouched.
    let (status, body) = call(
        &h.app,
        "GET",
        "/api/v1/account/devices",
        Some(&victim),
        None,
    )
    .await;
    assert_eq!(
        status,
        StatusCode::OK,
        "victim was logged out by another account's revocation: {body}"
    );
}

/// The TTL is checked on every authenticated request, and nothing exercised it.
/// Expiry is set by inserting a token that has already lapsed, so the test does
/// not depend on waiting for wall-clock time to pass.
#[tokio::test]
async fn an_expired_token_is_refused_on_both_subject_kinds() {
    let h = harness(RegistrationOverride::Unset, None);
    let owner = first_account(&h.app, None).await;
    let (_, phone) = enrol_and_auth(&h.app, &owner, "phone-1", "android").await;

    // Both tokens work while they are live.
    let (status, _) = call(&h.app, "GET", "/api/v1/account/devices", Some(&owner), None).await;
    assert_eq!(status, StatusCode::OK);
    let (status, body) = call(
        &h.app,
        "GET",
        "/api/v1/queues/phone-1/envelopes",
        Some(&phone),
        None,
    )
    .await;
    assert_eq!(
        status,
        StatusCode::OK,
        "device token works while live: {body}"
    );

    // Age both of them out.
    let pool = eko_relay::db::open(&h._dir.path().join("relay.db").to_string_lossy()).unwrap();
    let expired = pool
        .get()
        .unwrap()
        .execute("UPDATE token SET expires_at = 1", [])
        .unwrap();
    assert!(
        expired >= 2,
        "expected a user and a device token, got {expired}"
    );

    let (status, body) = call(&h.app, "GET", "/api/v1/account/devices", Some(&owner), None).await;
    assert_eq!(
        status,
        StatusCode::UNAUTHORIZED,
        "expired user token: {body}"
    );
    let (status, body) = call(
        &h.app,
        "POST",
        "/api/v1/queues/mac-1/envelopes",
        Some(&phone),
        Some(json!({"aad": b64().encode(b""), "body": b64().encode(b"x")})),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::UNAUTHORIZED,
        "expired device token: {body}"
    );
}

/// RFC 6750 makes the scheme case-insensitive.
#[tokio::test]
async fn the_bearer_scheme_is_matched_case_insensitively() {
    let h = harness(RegistrationOverride::Unset, None);
    let owner = first_account(&h.app, None).await;
    for scheme in ["Bearer", "bearer", "BEARER"] {
        let req = Request::builder()
            .method("GET")
            .uri("/api/v1/account/devices")
            .header("authorization", format!("{scheme} {owner}"))
            .body(Body::empty())
            .unwrap();
        let res = h.app.clone().oneshot(req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK, "scheme {scheme:?}");
    }
}

/// Storing the untrimmed name made " alice " and "alice" two accounts.
#[tokio::test]
async fn a_username_is_canonicalised_before_it_is_stored() {
    let h = harness(RegistrationOverride::Unset, None);
    let _ = first_account(&h.app, None).await;

    let (status, _) = call(
        &h.app,
        "POST",
        "/api/v1/accounts",
        None,
        Some(json!({"username": "  alice  ", "password": "a long enough password"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // The same name without the padding is the same account, not a new one.
    let (status, body) = call(
        &h.app,
        "POST",
        "/api/v1/accounts",
        None,
        Some(json!({"username": "alice", "password": "a long enough password"})),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "should collide: {body}");

    // And it can log in either way.
    for name in ["alice", " alice "] {
        let (status, body) = call(
            &h.app,
            "POST",
            "/api/v1/accounts/login",
            None,
            Some(json!({"username": name, "password": "a long enough password"})),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "login as {name:?}: {body}");
    }
}

/// A GET must not create rows; draining a queue nobody has deposited into is
/// simply empty.
#[tokio::test]
async fn draining_an_untouched_queue_creates_nothing() {
    let h = harness(RegistrationOverride::Unset, None);
    let owner = first_account(&h.app, None).await;
    enrol_and_auth(&h.app, &owner, "phone-1", "android").await;
    let (_, mac) = enrol_and_auth(&h.app, &owner, "mac-1", "macos").await;

    let (status, body) = call(
        &h.app,
        "GET",
        "/api/v1/queues/phone-1/envelopes",
        Some(&mac),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body.as_array().unwrap().len(), 0);

    let pool = eko_relay::db::open(&h._dir.path().join("relay.db").to_string_lossy()).unwrap();
    let queues: i64 = pool
        .get()
        .unwrap()
        .query_row("SELECT COUNT(*) FROM queue", [], |r| r.get(0))
        .unwrap();
    assert_eq!(queues, 0, "a GET created {queues} queue row(s)");
}

/// One account should not be able to fill the shared table with tokens it never
/// uses.
#[tokio::test]
async fn outstanding_enrolment_tokens_are_capped() {
    let h = harness(RegistrationOverride::Unset, None);
    let owner = first_account(&h.app, None).await;
    let mut refused = false;
    for i in 0..40 {
        let (status, _) = call(
            &h.app,
            "POST",
            "/api/v1/account/enrolment-tokens",
            Some(&owner),
            Some(json!({})),
        )
        .await;
        if status == StatusCode::TOO_MANY_REQUESTS {
            refused = true;
            assert!(i >= 8, "cap should leave room for real use, refused at {i}");
            break;
        }
        assert_eq!(status, StatusCode::OK);
    }
    assert!(refused, "unused enrolment tokens must be bounded");
}

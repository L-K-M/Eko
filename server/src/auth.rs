//! Credentials.
//!
//! Two subjects exist. A *user* authenticates with a password and administers
//! the deployment. A *device* never has a password: it proves possession of the
//! P-256 identity key it was enrolled with, which is the same key pairing
//! already pins, so no new secret is introduced anywhere.

use argon2::password_hash::{rand_core::OsRng, PasswordHasher, SaltString};
use argon2::{Argon2, PasswordHash, PasswordVerifier};
use base64::Engine;
use p256::ecdsa::{signature::Verifier, Signature, VerifyingKey};
use rand::RngCore;
use sha2::{Digest, Sha256};

/// Domain separation for the device challenge signature.
pub const AUTH_CONTEXT: &[u8] = b"eko-relay-auth-v1";

/// Borrowed, not returned by value: `GeneralPurpose` carries its encode and
/// decode tables inline, so returning it copied a few hundred bytes on every
/// token minted and every envelope decoded.
pub fn b64() -> &'static base64::engine::general_purpose::GeneralPurpose {
    &base64::engine::general_purpose::URL_SAFE_NO_PAD
}

pub fn hash_password(password: &str) -> Result<String, String> {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|h| h.to_string())
        .map_err(|e| e.to_string())
}

/// Compares byte *content* without short-circuiting - `==` on `&str` returns as
/// soon as two bytes differ, and the bootstrap token is the most privileged
/// credential the relay has.
///
/// Length is not treated as secret: unequal lengths return immediately, exactly
/// as `subtle`'s own slice `ct_eq` does ("short-circuits if the lengths of the
/// input slices are different"). Do not use this where the length itself is the
/// secret.
pub fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    use subtle::ConstantTimeEq;
    if a.len() != b.len() {
        return false;
    }
    a.ct_eq(b).into()
}

/// A valid hash of a value nobody knows, computed once. Verifying against it
/// costs the same as verifying a real one, which is what keeps a missing
/// username indistinguishable from a wrong password.
pub fn dummy_password_hash() -> &'static str {
    static DUMMY: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    DUMMY.get_or_init(|| {
        hash_password(&b64().encode(random_bytes(32)))
            .unwrap_or_else(|_| String::from(FALLBACK_DUMMY_HASH))
    })
}

/// Used only if `hash_password` itself fails. A real Argon2id hash of a
/// throwaway string, not a hand-written stand-in: the previous placeholder had
/// a 4-byte salt and 4-byte output, and `PasswordHash::new` rejects it with
/// "output size too short". `verify_password` would then return early on the
/// unknown-username path without doing any Argon2 work, which is exactly the
/// timing signal this whole mechanism exists to remove.
const FALLBACK_DUMMY_HASH: &str =
    "$argon2id$v=19$m=19456,t=2,p=1$ZWtvLXJlbGF5LWR1bW15LXYx$HP5jDkUdp9JOFsaRUYusNsQFwh4hlnlxjncUBHyvvJE";

pub fn verify_password(password: &str, stored: &str) -> bool {
    match PasswordHash::new(stored) {
        Ok(parsed) => Argon2::default()
            .verify_password(password.as_bytes(), &parsed)
            .is_ok(),
        Err(_) => false,
    }
}

/// `thread_rng` rather than `OsRng`, deliberately: it is a CSPRNG seeded from
/// the OS and reseeded periodically, and it does not pay a syscall per call.
/// `OsRng` appears above only because `SaltString::generate` asks for it.
pub fn random_bytes(n: usize) -> Vec<u8> {
    let mut buf = vec![0u8; n];
    rand::thread_rng().fill_bytes(&mut buf);
    buf
}

/// Opaque bearer token. Only its SHA-256 is stored, so a database leak does not
/// yield usable tokens. The digest is of the *encoded* string, which is what
/// arrives in the Authorization header - `bearer()` hashes the header value
/// directly, so both sides agree without decoding.
pub fn new_token() -> (String, Vec<u8>) {
    let raw = random_bytes(32);
    let encoded = b64().encode(&raw);
    let digest = sha256(encoded.as_bytes());
    (encoded, digest)
}

pub fn sha256(bytes: &[u8]) -> Vec<u8> {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hasher.finalize().to_vec()
}

/// The bytes a device signs: `AUTH_CONTEXT || nonce || device_id`. Public
/// because the tests were building this by hand from the same three literals,
/// which meant a change to the format here would leave them passing against a
/// server that no longer spoke it.
pub fn auth_message(nonce: &[u8], device_id: &str) -> Vec<u8> {
    let mut message = Vec::with_capacity(AUTH_CONTEXT.len() + nonce.len() + device_id.len());
    message.extend_from_slice(AUTH_CONTEXT);
    message.extend_from_slice(nonce);
    message.extend_from_slice(device_id.as_bytes());
    message
}

/// Verify `sig` over `auth_message` against a SEC1 public key. `device_id` is
/// bound into the signed message so a signature captured for one device cannot
/// be replayed as another.
pub fn verify_device_signature(
    public_key_sec1: &[u8],
    nonce: &[u8],
    device_id: &str,
    signature_der: &[u8],
) -> bool {
    let Ok(key) = VerifyingKey::from_sec1_bytes(public_key_sec1) else {
        return false;
    };
    let Ok(sig) = Signature::from_der(signature_der) else {
        return false;
    };
    key.verify(&auth_message(nonce, device_id), &sig).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use p256::ecdsa::{signature::Signer, SigningKey};

    #[test]
    fn password_round_trip() {
        let stored = hash_password("correct horse").unwrap();
        assert!(verify_password("correct horse", &stored));
        assert!(!verify_password("wrong horse", &stored));
    }

    #[test]
    fn device_signature_round_trip() {
        let signing = SigningKey::random(&mut rand::thread_rng());
        let verifying = VerifyingKey::from(&signing);
        let public = verifying.to_encoded_point(false).as_bytes().to_vec();
        let nonce = random_bytes(32);

        let sig: Signature = signing.sign(&auth_message(&nonce, "device-a"));

        assert!(verify_device_signature(
            &public,
            &nonce,
            "device-a",
            sig.to_der().as_bytes()
        ));
        // Same signature must not authenticate a different device.
        assert!(!verify_device_signature(
            &public,
            &nonce,
            "device-b",
            sig.to_der().as_bytes()
        ));
        // Nor a different nonce.
        assert!(!verify_device_signature(
            &public,
            &random_bytes(32),
            "device-a",
            sig.to_der().as_bytes()
        ));
    }

    #[test]
    fn constant_time_eq_matches_ordinary_equality() {
        assert!(constant_time_eq(b"abcdef", b"abcdef"));
        assert!(!constant_time_eq(b"abcdef", b"abcdeg"));
        assert!(!constant_time_eq(b"abcdef", b"abcde"));
        assert!(constant_time_eq(b"", b""));
    }

    #[test]
    fn the_dummy_hash_is_a_usable_argon2_hash() {
        // If it did not parse, verify_password would return early and the login
        // timing defence would silently stop working.
        let dummy = dummy_password_hash();
        assert!(dummy.starts_with("$argon2"));
        assert!(PasswordHash::new(dummy).is_ok());
        assert!(!verify_password("anything at all", dummy));
    }

    /// The branch above almost never runs, so testing `dummy_password_hash()`
    /// only ever exercises the live `hash_password` path and says nothing about
    /// the constant behind it. Assert the constant itself: the one it replaced
    /// looked plausible and did not parse.
    #[test]
    fn the_fallback_dummy_hash_parses_too() {
        assert!(
            PasswordHash::new(FALLBACK_DUMMY_HASH).is_ok(),
            "fallback must parse or the timing defence silently stops working"
        );
        assert!(!verify_password("anything at all", FALLBACK_DUMMY_HASH));
    }

    #[test]
    fn token_hash_is_not_the_token() {
        let (token, digest) = new_token();
        assert_ne!(token.as_bytes(), digest.as_slice());
        assert_eq!(sha256(token.as_bytes()), digest);
    }
}

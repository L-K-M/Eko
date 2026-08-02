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

pub fn b64() -> base64::engine::general_purpose::GeneralPurpose {
    base64::engine::general_purpose::URL_SAFE_NO_PAD
}

pub fn hash_password(password: &str) -> Result<String, String> {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|h| h.to_string())
        .map_err(|e| e.to_string())
}

pub fn verify_password(password: &str, stored: &str) -> bool {
    match PasswordHash::new(stored) {
        Ok(parsed) => Argon2::default()
            .verify_password(password.as_bytes(), &parsed)
            .is_ok(),
        Err(_) => false,
    }
}

pub fn random_bytes(n: usize) -> Vec<u8> {
    let mut buf = vec![0u8; n];
    rand::thread_rng().fill_bytes(&mut buf);
    buf
}

/// Opaque bearer token. Only its SHA-256 is stored, so a database leak does not
/// yield usable tokens.
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

/// Verify `sig` over `AUTH_CONTEXT || nonce || device_id` against a SEC1 public
/// key. `device_id` is bound into the signed message so a signature captured
/// for one device cannot be replayed as another.
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
    let mut message = Vec::with_capacity(AUTH_CONTEXT.len() + nonce.len() + device_id.len());
    message.extend_from_slice(AUTH_CONTEXT);
    message.extend_from_slice(nonce);
    message.extend_from_slice(device_id.as_bytes());
    key.verify(&message, &sig).is_ok()
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

        let mut message = Vec::new();
        message.extend_from_slice(AUTH_CONTEXT);
        message.extend_from_slice(&nonce);
        message.extend_from_slice(b"device-a");
        let sig: Signature = signing.sign(&message);

        assert!(verify_device_signature(
            &public,
            &nonce,
            "device-a",
            &sig.to_der().as_bytes().to_vec()
        ));
        // Same signature must not authenticate a different device.
        assert!(!verify_device_signature(
            &public,
            &nonce,
            "device-b",
            &sig.to_der().as_bytes().to_vec()
        ));
        // Nor a different nonce.
        assert!(!verify_device_signature(
            &public,
            &random_bytes(32),
            "device-a",
            &sig.to_der().as_bytes().to_vec()
        ));
    }

    #[test]
    fn token_hash_is_not_the_token() {
        let (token, digest) = new_token();
        assert_ne!(token.as_bytes(), digest.as_slice());
        assert_eq!(sha256(token.as_bytes()), digest);
    }
}

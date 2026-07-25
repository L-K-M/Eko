# Security model

## Security goals

Eko v1 is designed to:

- Keep notification bodies and OTPs confidential from passive observers on the LAN.
- Detect an active man-in-the-middle during first pairing when the user verifies the displayed code
  or scans the Mac's single-use QR token.
- Authenticate every normal reconnect to the exact certificates accepted during pairing.
- Prevent sequence replay, silent cursor rollback, generation collision, and acknowledgement-driven
  deletion of uncommitted Mac data.
- Limit unauthenticated discovery and listener traffic so a local attacker cannot trivially exhaust
  memory or leave pairing mode open indefinitely.
- Make retention loss explicit rather than claiming complete history after data is deliberately
  pruned.

## Scope and assumptions

The v1 threat model includes passive and active attackers on the same LAN, impersonation, pairing
MITM, frame replay, malicious discovery packets, and connection floods.

The following are outside the v1 threat model:

- A compromised or malicious paired phone or Mac.
- Malware running as the user on either endpoint.
- Physical access to an unlocked endpoint.
- Denial of service by an administrator, router, operating system, or RF jammer.
- Notification content exposed by the source app, Android, macOS previews, or the clipboard after
  Eko hands it to an authorized local feature.

## Device identity

Each Eko installation creates a long-lived self-signed P-256 certificate and private key. The device
identifier is the lowercase hexadecimal SHA-256 digest of the exact certificate DER bytes. The
certificate, not a name, IP address, Bluetooth address, or discovery identifier, is the identity.

The private Android key remains in Android Keystore. The private Mac key remains non-exportable and
non-synchronizable in the data-protection Keychain. Certificates use a long validity period because
changing certificate DER changes identity. Reinstall or intentional key rotation therefore requires
guided re-pairing.

Normal TLS verification compares the presented leaf certificate byte-for-byte with the confirmed
pin. A matching issuer, hostname, discovery fingerprint, or certificate chain is not sufficient.
After TLS, each `hello.device_id` must equal the fingerprint of the certificate used on that session.

## Discovery is not trust

Bonjour `_eko._tcp`, UDP port `48809`, last-known addresses, BLE advertising, names, and QR host/port
fields only help endpoints meet. Their identity claims are rechecked against the certificate inside
the TLS session. A mismatch aborts pairing or connection.

Discovery packets are bounded and rate-limited. The Mac caps concurrent unauthenticated sessions,
rate-limits source addresses, and closes sessions that do not complete TLS and `hello` promptly.
Pairing mode and QR tokens expire after a few minutes; tokens are single use.

## Pairing authentication

Both endpoints must be in explicit pairing mode. They first establish TLS while narrowly allowing
one unknown peer certificate into the pairing state machine. Unknown certificates are never accepted
for normal traffic.

For manual/discovery pairing, both sides use commit-then-reveal verification:

1. The phone creates a random 128-bit pairing-attempt identifier and each endpoint creates a random
   nonce of at least 128 bits.
2. Each endpoint commits to its attempt identifier, certificate, and nonce with a domain-separated
   SHA-256 value before revealing its nonce.
3. Each verifies the peer's reveal against the prior commitment.
4. Both derive the same eight-uppercase-hex-character code from the domain-separated, length-prefixed
   transcript with certificate/nonce owner binding.
5. The user compares the code. A mismatch or unexpected attempt is rejected.

The commitment prevents a live MITM from choosing its nonce after seeing the other side's value. The
remaining online success probability is 1 in 2^32 per rate-limited attempt. QR pairing adds a random,
single-use token and displays the code as confirmation.

Each side durably records the attempt, peer certificate, transcript hash, and pending state before
asking for confirmation. Confirm/result messages are idempotent and attempt-bound. Notification
traffic starts only after both confirmations. A reconnect can resume an unexpired pending attempt
without converting a half-pair into trust.

## Session and transport security

- Transport is TCP with TLS 1.3 only and mutual certificate authentication.
- There is no plaintext mode, TLS downgrade, or trust-on-name fallback.
- Frames have a four-byte big-endian length and one-byte type. Receivers validate the length before
  allocating and cap it at 1,048,576 bytes including frame type.
- Invalid UTF-8, malformed JSON, duplicate required keys, invalid required values, or messages that
  violate the negotiated schema close the session.
- Paired endpoints remember the highest protocol version observed and reject a later downgrade.
- A per-install persistent `conn_epoch` lets a strictly newer authenticated connection supersede an
  old socket. Equal or lower epochs lose, so wall-clock time is not an authority.

Application data is not additionally end-to-end encrypted inside TLS in v1 because the TLS peers are
the endpoints. A future untrusted relay requires a separate end-to-end envelope before it can carry
these frames.

## Replay, ordering, and deletion safety

Every committed phone event receives a monotonic sequence number within an unpredictable generation
identifier. Ordering is `(device identity, generation, sequence)` and never phone wall time.

The Mac commits an event or explicit gap and its `processed_through_seq` in one database transaction.
It sends a cumulative acknowledgement only after every position through that value is represented by
a committed event or committed gap. The phone rejects non-monotonic acknowledgements and values above
what that session sent or explicitly authorized. A lost acknowledgement can cause retention of data
or duplicate delivery, but the Mac's unique generation/sequence key gives an exactly-once database
effect.

A phone database replacement starts a new generation with sequence one. It never relabels old rows.
The Mac records a generation transition, keeps old history namespaced, and resets only the new
generation cursor. If a Mac cursor regresses below data the phone already acknowledged or pruned, the
phone sends an explicit `peer_cursor_regressed` or retained-gap interval before resuming at its floor.

The published durability guarantee is deliberately narrow: Eko loses no event whose phone
event-store transaction committed until an acknowledgement or explicit retention floor authorizes
deletion. Android callbacks queued but not committed and notifications Android never delivered are
outside that guarantee.

## Companion-device trust and OTPs

On Android 15 and newer, Android may redact sensitive notification content from untrusted listeners.
Eko uses an Android CompanionDeviceManager association to make the package trusted for the current
Android user. This trust is app/user-wide, not scoped to a particular Mac and not proof of Mac
identity.

Android caches listener trust when binding the notification listener. After an association changes,
Eko uses the supported unbind/disconnect/rebind sequence. It never toggles its component as a repair
kick. Revoking the last association can cause OTP content to be replaced until trust is restored and
the listener is rebound.

## At-rest security and backup

Android excludes the event database, identity material, and peer metadata from cloud backup and
device transfer. This prevents identity cloning, OTP upload through Auto Backup, and restored sequence
regression. The Mac database is in the app sandbox and relies on FileVault for at-rest encryption in
v1; payload columns are not separately encrypted.

Diagnostics are local-only and content-redacted by default. Enabling content applies to one export,
not future exports.

## Revocation

Connected unpair is acknowledged before final pin deletion. Offline unpair immediately blocks normal
traffic and leaves a minimal `revoked_pending` fingerprint/endpoint tombstone. Exact-certificate TLS
is then accepted only for idempotent `unpair` and `unpair_ack`; no welcome, sync, fetch, or notification
frame is allowed. The tombstone is deleted after acknowledgement or explicit **Forget without
notifying**.

## Operator checks

For a security-sensitive deployment, verify:

1. The Mac release is Developer ID signed, hardened, sandboxed, and notarized.
2. The APK checksum matches the release and updates retain the same signing-certificate digest.
3. Pairing codes match exactly and pairing mode closes after use.
4. No public router forwarding exposes Eko's listener or discovery ports.
5. FileVault and normal endpoint lock policies are enabled.
6. Diagnostics remain redacted unless the recipient and data scope justify content disclosure.
7. A certificate mismatch is handled as re-pairing, never bypassed as a network error.

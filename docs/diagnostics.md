# Diagnostics export and redaction

## Principles

- Diagnostics are created as local files. Eko never uploads them automatically.
- Notification content is redacted by default.
- Including content is a one-export decision and never becomes a persistent preference.
- A diagnostic timestamp is a fact, not proof that silence after that time indicates a stalled
  listener.
- A retention gap is definitive. A suspected capture gap records evidence and approximate time only;
  it must not invent a missing-event count.

## Export from Android

1. Open **Eko > Health and Diagnostics**.
2. Reproduce the problem once with a synthetic notification when safe.
3. Choose **Export diagnostics**.
4. Leave **Include notification content** off for the first export.
5. Review the preview, including the time range and categories to be included.
6. Save through Android's system document picker to a location you control.

The Android export should include:

- Eko version/build, Android API/release, manufacturer/model, and current boot identifier in redacted
  form where needed.
- Notification-access grant and listener bind transitions.
- Last callback, commit, and forward timestamps, clearly labeled as observations rather than health
  proof.
- Event-store generation/high-water, effective WAL and `synchronous` state, writer queue depth, and
  overflow evidence.
- Per-pairing acknowledged sequence, serve floor, retention policy, backlog count, and gap spans.
- Connection attempts, negotiated protocol/capabilities, epoch decisions, backoff, and error codes.
- CDM association count/type, presence state, redaction self-check, battery exemption, and recent
  process-exit reason.
- Foreground-service start/stop evidence and network type without raw credentials or full addresses.

## Export from macOS

1. Open **Eko > Settings > Advanced and Diagnostics**.
2. Reproduce the issue once when practical.
3. Choose **Export diagnostics**.
4. Keep content redaction enabled unless a specific event body is essential and the recipient is
   authorized to see it.
5. Save the file locally and inspect it before sharing.

The Mac export should include:

- Eko version/build, macOS version, signing/notarization state visible to the app, and sandbox path
  class without the user's home-directory name.
- Listener port and state, Network.framework state, Bonjour policy-denied state, Bluetooth state, and
  notification authorization state.
- Per-device current/retired generation, processed-through cursor, committed event/gap counts,
  active-snapshot reconciliation, and stale-fetch decisions.
- Connection epoch/supersession decisions, protocol/capabilities, heartbeat state, and clock-skew
  estimate.
- Database migration version, transaction errors, prune runs, and retention settings.
- Pairing/unpair state without private keys, full certificates, QR tokens, pairing nonces, or
  transcript secrets.

## Required default redaction

A default export must transform sensitive values before writing the archive, not merely hide them in
the UI.

| Value | Default export behavior |
|---|---|
| Notification title/body, text lines, messages, sender, extracted OTP | Replace with a redaction marker and retain only field presence, byte/character length, truncation flags, and a non-reversible per-export digest when correlation is needed |
| Notification key | Per-export salted digest; never emit the opaque original |
| App package and label | Per-export salted digest plus broad category only when needed |
| Device/user-assigned names | Replace with stable labels within the export such as `phone-1` and `mac-1` |
| Certificate fingerprint/device ID | Emit a short display prefix only, or a per-export salted digest |
| IP address, hostname, Wi-Fi SSID/BSSID | Remove or replace with address class and interface type |
| CDM association ID | Replace with a per-export local ordinal and retain association profile/type |
| QR token, pairing nonce, commitment input, private key, Keychain/Keystore secret | Never export |
| Filesystem username and home path | Remove or replace with the sandbox-relative path |
| Timestamps | Keep UTC timestamps needed to correlate endpoints; preview their range before export |

The random redaction salt belongs only inside the export process and must not be included in the
archive. Two exports therefore should not expose a durable cross-export tracking identifier.

## Optional content export

Only enable content when all of these are true:

1. A redacted export was insufficient.
2. The issue depends on a specific parser, truncation, redaction, or active-state payload.
3. The user has reviewed the selected time range and source apps.
4. The recipient and transfer method are approved for notification and OTP data.

Even with content enabled, Eko must never export private keys, reusable QR tokens, pairing nonces,
unknown-app installer credentials, Wi-Fi credentials, or clipboard history. OTP candidates should be
masked unless the user separately confirms that exact field is necessary; a real unexpired OTP should
never be shared.

## Inspect before sharing

Treat the archive as sensitive even when redacted. Work on a copy and do not extract it into a
cloud-synchronized folder by accident.

Useful checks on macOS or Linux are:

```sh
unzip -l eko-diagnostics.zip
mkdir -p /tmp/eko-diagnostics-review
unzip -q eko-diagnostics.zip -d /tmp/eko-diagnostics-review
```

Open every text/JSON file and search for a known synthetic canary used during reproduction, phone
numbers, email addresses, SSIDs, IP addresses, usernames, message text, and OTP-like digit groups.
Delete the review directory after inspection.

On Windows, use File Explorer's **Extract All** into a local nonsynchronized folder and perform the
same review. Do not rely on a filename or a `redacted: true` manifest flag without inspecting the
payload.

## Correlate two endpoints

1. Export both endpoints as soon as possible after reproduction.
2. Compare UTC ranges and allow for the displayed clock-skew estimate.
3. Match generation and sequence, not wall-clock order.
4. Find the phone commit first, then its send/authorization, the Mac database commit, and the later
   acknowledgement.
5. If a sequence is absent, require a committed explicit gap covering it before calling the state
   complete.
6. Distinguish `retention_count`, `retention_age`, and `peer_cursor_regressed` from a sequenced
   `capture_gap` with `confidence=suspected`.
7. If the phone has no committed row, inspect listener/process/writer evidence. Do not claim that the
   source notification existed solely from silence or user memory.

## Retention and disposal

Record the issue/reference number outside the archive, share through an approved encrypted channel,
and give access only to people investigating the issue. Delete local, received, extracted, and backup
copies when the investigation ends. Emptying a desktop trash does not guarantee erasure from SSD
snapshots or third-party backups, so avoid creating unnecessary copies in the first place.

For redaction defects, stop sharing the affected exporter version, preserve one securely restricted
sample only if needed to fix the defect, and treat previously shared archives as potentially
containing notification content.

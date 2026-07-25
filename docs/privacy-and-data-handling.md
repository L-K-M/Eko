# Privacy and data handling

## Plain-language statement

Eko v1 moves notifications directly between your Android phone and your Mac on the local network.
There is no Eko account, cloud relay, advertising SDK, or telemetry by default. Notification content
is not sent to an Eko-operated or other third-party service.

Downloading Eko, checking a release page, or using Obtainium contacts the release host chosen by the
user. That traffic is separate from notification mirroring. Eko's LAN discovery broadcasts reveal
that an Eko endpoint is present, but discovery data is never trusted as identity and contains no
notification body.

## Data Eko handles

For notifications Android delivers to Eko, the phone can store and forward:

- App package and locally resolved app label.
- Android user/profile identifier.
- Notification key as an opaque value.
- Post time, category, clearable/group state, and removal reason.
- Structured title, text, expanded text, subtext, summary, text lines, and messaging-style messages.
- Do Not Disturb state and suppression metadata.
- Evidence-backed listener/process intervals recorded as suspected capture-gap events.

The Mac derives search text and may derive an OTP candidate from those structured fields. OTP
extraction runs locally on the Mac. Eko does not read SMS storage or request `READ_SMS` in v1.

By default Eko skips its own notifications and ongoing/foreground-service notifications such as
navigation and media controls. Per-app phone rules can stop future capture. Mac-side mute only hides
banners or rows; it does not remove events from transport because doing so would create silent
sequence holes.

## Network handling

- Notification and control frames use mutually authenticated TLS 1.3 with exact certificate pins.
- There is no cleartext notification mode and no protocol downgrade path.
- Bonjour, UDP announcements, cached addresses, and QR/manual details are connection hints only.
- v1 does not intentionally use cellular transport or an Internet relay.
- A paired phone initiates the connection to the Mac. No router port forwarding is required or
  recommended.

## Storage and retention

### Android

The phone stores a durable shared event log and active-notification state in app-private SQLite
storage. The default availability window for each paired Mac is 48 hours or 2,000 events, whichever
limit advances first. Each Mac has its own acknowledgement and retention floor; one slow Mac cannot
cause deletion of rows another Mac still needs.

When retention removes an unacknowledged interval, Eko records the exact sequence span and reason
before deleting data. The Mac displays that definitive interval as unavailable. This is different
from a suspected capture gap, which means Android may not have delivered callbacks and cannot supply
a missing-event count.

The Android private identity key is non-exportable in Android Keystore. Certificates, peer pins,
endpoints, and cursor recovery metadata are app-private. Android cloud backup and device-transfer
rules exclude notification databases and all key/certificate material. Moving to another phone is a
new install with a new identity and requires pairing again.

### macOS

The Mac stores received event history in its sandbox container. The default is 7 days or 5,000
notifications per phone and is user-configurable. The private identity key is non-exportable,
non-synchronizable, and stored in the data-protection Keychain; peer certificates are public pin data
stored with the Eko database.

Eko v1 relies on macOS app sandbox protection and FileVault for database data at rest. Notification
payload columns are not separately encrypted. Users who need protection against offline disk access
should enable FileVault and lock the Mac when unattended.

## Native notifications and clipboard

Mirrored content shown by macOS Notification Center is then subject to macOS preview, lock-screen,
and notification-retention settings. Configure sensitive previews in **System Settings >
Notifications > Eko**.

Eko copies an OTP only after an explicit action unless auto-copy has been enabled for that source
app. Banking-style TAN messages are never auto-copied. Copied codes are marked with the pasteboard
concealed type so cooperating clipboard managers can omit them. Eko attempts to clear an unchanged
code after two minutes; it does not read and restore the previous clipboard. Other software with
clipboard access and macOS itself may still observe copied text.

## Diagnostics

Diagnostics are exported to a local file and are never uploaded automatically. Notification bodies,
OTP candidates, sender/title text, notification keys, addresses, and stable identifiers are redacted
or pseudonymized by default. Including notification content requires a fresh, explicit choice for
each export. See [Diagnostics](diagnostics.md) before sharing a file.

## Deletion and unpairing

Deleting history on the Mac removes its retained event, materialized notification, gap, and OTP rows
subject to normal filesystem behavior. Unpairing deletes pairing data and blocks normal traffic.

When both endpoints can connect, they exchange an authenticated, idempotent unpair acknowledgement
before deleting the final pin. When one endpoint is offline, Eko retains only a minimal revoked
tombstone containing the peer fingerprint and last endpoint so it can propagate unpair on next
contact. A tombstoned connection can exchange only unpair messages; it cannot send or accept
notification content. **Forget without notifying** deletes that tombstone at the user's explicit
request.

Android companion associations are independent of pairing records. Eko removes an association only
when no remaining Mac pairing relies on it and retains at least one while any Mac remains paired.

## Limits of the privacy claim

Eko cannot protect notification data after an endpoint, OS account, or paired device is compromised.
It cannot recover transient notifications Android never delivered to the listener. App labels,
notification previews, accessibility tools, backup tools outside Eko's sandbox, screenshots, and
clipboard history can disclose content under their own permissions.

Eko has no server-side user profile from which to retrieve or delete data. Data controls are local on
the paired phone and Mac.

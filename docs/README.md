# Eko documentation

Eko mirrors Android notifications to a Mac over the local network. These documents describe the
v1 user, support, QA, and release procedures in English.

## User guides

| Guide | Use it for |
|---|---|
| [Install and pair](install-and-pair.md) | Requirements, sideloading, first pairing, additional devices, updates, and unpairing |
| [Android access and OTP repair](android-access-and-otp-repair.md) | Restricted settings, notification access, CDM trust, redacted OTPs, and supported listener repair |
| [Battery and OEM reliability](battery-and-oem-reliability.md) | General battery setup and Samsung, Xiaomi, Huawei, and OnePlus guidance |
| [Privacy and data handling](privacy-and-data-handling.md) | What Eko reads, sends, stores, retains, exports, and deletes |
| [Security model](security-model.md) | Threat model, identity, pairing verification, transport security, replay protection, and limitations |
| [Diagnostics](diagnostics.md) | Safe export, redaction, inspection, sharing, and interpretation |

## Engineering and release guides

| Guide | Use it for |
|---|---|
| [Manual QA](manual-qa.md) | Release regression testing, accessibility, Android lifecycle behavior, and macOS TCC |
| [Release checklists](release-checklists.md) | Android signing and macOS Developer ID signing, notarization, and release gates |
| [Hardware spikes S1-S11](hardware-spikes.md) | Reproducible hardware validation procedures and evidence requirements |

## Support triage

Use this order for the most common reports:

1. Confirm both devices are on the same non-isolated LAN and Eko is open on the phone.
2. On Android, open Eko's Health and Diagnostics screen and check notification access, listener
   binding, at least one companion-device association, and the redaction self-check.
3. On the Mac, check whether only discovery is degraded by Local Network permission. Direct phone
   connections can still work when Mac-initiated discovery is denied.
4. If OTP text is hidden, follow [Android access and OTP repair](android-access-and-otp-repair.md).
5. If committed backlog grows or the process repeatedly exits, follow the detected manufacturer's
   section in [Battery and OEM reliability](battery-and-oem-reliability.md).
6. Export diagnostics from both endpoints with notification content redacted and compare UTC
   timestamps, generation, cursor, floor, gap, and connection state.

Notification silence alone is not proof that Android killed Eko or that the notification listener
stopped. Treat only listener transitions, process-exit records, foreground-service start failures,
writer overflow, and committed-but-unsent backlog growth as actionable evidence.

## Terminology

- A **committed event** is an Android callback whose event-store transaction completed.
- A **retention gap** is a definitive sequence interval that the phone explicitly made unavailable.
- A **suspected capture gap** is an evidence-backed interval in which Android may not have delivered
  notifications to Eko. It is not a count or proof of missing notifications.
- A **generation** is one sequence space in the phone event store. A database replacement starts a
  new generation rather than reusing old sequence numbers.
- A **pairing** is one phone-to-Mac trust relationship. A CDM association is Android app/user state
  used for trust and reliability; it is not a pairing identifier.

`PLAN.md` is the architecture source for these guides. The normative wire specification and test
vectors, when present under `/protocol`, take precedence for protocol behavior.

# Eko Relay — architecture and delivery plan

Status: **proposed**. Nothing here has shipped. This document is the design
review artifact for adding a self-hosted relay to Eko and is the reference for
the staged implementation that follows it.

Read [PLAN.md](../../PLAN.md) first; this changes §13 from "reserved seams" to a
built component and revises D1's consequences. It does not change D3 (identity),
D4 (phone-side durable outbox), D7 (OTP extraction on the Mac), or the v1 wire
protocol in [protocol/protocol.md](../../protocol/protocol.md).

---

## 1. Why

v1 syncs phone → Mac over mutually authenticated TLS on the LAN. Two properties
of that design are load-bearing problems, and only one of them was understood
when v1 was designed.

**Addressability.** D11 lists four discovery mechanisms — mDNS/Bonjour, UDP
announce, last-known-IP dial, QR/manual — with the note that *"every single
mechanism fails on some real network."* Four mechanisms exist because none is
sufficient. A relay replaces all four with a DNS name and an outbound
connection, which is the single most reliable operation available to a mobile
client behind NAT.

**Retention, which is a correctness problem and not a latency one.** The phone
keeps 48 h / 2'000 events. §9 defines a `backlog_gap` frame — `{"type":
"backlog_gap","from_seq":40000,"to_seq":41022,"reason":"retention"}` — whose
entire purpose is to tell the Mac that events existed and are gone. §2 calls
this "an honest gap indicator when retention is exceeded". So the direct design
does not make loss impossible; it makes loss *honest*. Any separation longer
than the retention window drops notifications permanently. A relay the phone can
always reach means the outbox drains continuously and never accumulates against
that window.

A third, smaller gain: §13.2 wants FCM as a wake-up tickle. In the direct model a
wake is speculative — it is spent attempting a connection to a Mac that may be
asleep or elsewhere, and FCM demotes pings that do not produce a visible
notification. With a relay every wake has somewhere to connect, so the wake
budget becomes usable.

### What this does not fix

The phone-side background execution problem (§1.3 — Doze, App Standby, OEM
battery managers) is unchanged. A relay moves the far end of the socket; it does
not keep the Android process alive. The durable outbox remains the mechanism
that makes process death survivable.

---

## 2. The central decision: the relay is not a protocol participant

**The relay stores and forwards opaque sealed envelopes. It never parses an Eko
protocol frame, and it cannot.**

The alternative — teaching the server the v1 session protocol — was rejected. It
would duplicate the state machine (§6), the generation/cursor rules (§8), the
replay transaction (§9) and the ACK semantics (§11) in a third implementation,
and every one of those would be a place for the three implementations to
disagree. It would also put notification plaintext on the server.

Instead the relay is a durable, authenticated, ordered byte queue. Everything
above it is unchanged v1 protocol, end-to-end encrypted between the two devices.

```
        phone                         relay                        Mac
  ┌───────────────┐            ┌───────────────┐           ┌───────────────┐
  │ v1 frames     │            │               │           │ v1 frames     │
  │  hello/event  │            │  queues of    │           │  welcome/ack  │
  ├───────────────┤            │  opaque       │           ├───────────────┤
  │ HPKE seal     │──envelope──▶  envelopes    │──envelope─▶ HPKE open     │
  │ (to Mac key)  │            │  + cursors    │           │ (own key)     │
  ├───────────────┤            │               │           ├───────────────┤
  │ Transport     │◀──── TLS ──▶  axum/SQLite  │◀─── TLS ──▶ Transport     │
  └───────────────┘            └───────────────┘           └───────────────┘
                                      │
                            sees: which device IDs,
                            when, how many, how big.
                            never: notification content.
```

The relay's TLS is ordinary server TLS (Caddy or a user-supplied reverse proxy)
and protects the device↔relay hop only. Confidentiality of notification content
against the relay comes from HPKE, not from that TLS.

### Two channels over one queue model

The v1 protocol is interactive: `hello` → `welcome` → sync → `ack`. Store-and-
forward has to work when the Mac is *not* there to answer. Both are expressed on
the same queue primitive:

| Channel | When | Shape |
| --- | --- | --- |
| **Session** | Both devices online | Relay bridges the two queues in near-real-time over WebSocket. The full v1 handshake runs end-to-end inside sealed envelopes. Identical to today's behaviour. |
| **Deposit** | Mac offline | Phone seals event frames and enqueues them without a handshake. The Mac drains on next connect and ingests through the existing cursor/generation path — the frames carry the same per-device sequence numbers the resume protocol already uses. |

The Mac's ingest rule from §9 — every position is represented by a committed
event row or a committed gap — is what makes the deposit channel safe. Drained
envelopes are just backlog arriving by a different road.

---

## 3. End-to-end encryption

**Scheme: HPKE (RFC 9180), `mode_auth`, DHKEM(P-256, HKDF-SHA256) + HKDF-SHA256
+ ChaCha20-Poly1305.**

No new shared secret and no new trust ceremony. D3 already gives every install a
long-lived P-256 identity keypair, and pairing already ends with each side
holding the other's exact pinned certificate DER. The sender seals to the
recipient's pinned public key; `mode_auth` mixes the sender's static private key
into key schedule, which authenticates the sender without a separate signature.
P-256 is forced by the existing identity keys — the Android key lives in the
Keystore and the macOS key in the Keychain, and neither can be re-typed without
re-pairing every install.

What each envelope carries:

```
envelope := {
  v:        1,                     # envelope format version
  enc:      <HPKE encapsulated key, 65 bytes>,
  ct:       <AEAD ciphertext of one or more v1 frames>,
}
aad := v || sender_device_id || recipient_device_id || relay_queue_id
```

Protocol-level metadata — sequence numbers, generations, notification keys —
stays *inside* the ciphertext. The relay orders envelopes by its own opaque
per-queue `envelope_id`, so it needs to understand nothing about Eko's sequence
space and learns nothing from it.

### Replay and ordering

HPKE alone does not prevent an envelope being delivered twice. Three layers
handle it, none new:

1. The relay enforces monotonic `envelope_id` per queue and delivers in order.
2. The recipient rejects a non-monotonic `envelope_id` from a given sender.
3. The v1 protocol is already idempotent on replay — a re-delivered event
   carries the same per-device sequence and lands on the same row.

`conn_epoch` (§7.2) continues to reject zombie sessions on the session channel.

### Key rotation and loss

A device that loses its key has lost its pairings today and that does not
change; recovery is re-pairing, which mints a new identity and a new relay
device credential. Deliberately no server-side key escrow — an escrowed key
would make the relay able to decrypt, which is the property this whole design
exists to avoid.

---

## 4. Accounts, devices, and closing registration

An account groups the devices allowed to exchange envelopes. It exists for
authorization and quota, not identity: **the account never authenticates the
end-to-end channel** — pairing and pinned identity keys do that, exactly as
today. A compromised account can deny service and observe metadata. It cannot
read notifications and cannot introduce a new device into an existing pairing,
because the phone and Mac pin each other's certificates independently of the
relay.

### Model

```
account(id, username, password_hash, is_admin, created_at)
device (id, account_id, device_id, public_key_der, name, platform, created_at,
        last_seen_at, revoked_at)
queue  (id, account_id, sender_device, recipient_device, created_at)
envelope(queue_id, envelope_id, aad, body, byte_len, created_at)
cursor (queue_id, reader_device, acked_envelope_id, updated_at)
setting(key, value)                  -- registration_open lives here
enrolment_token(token_hash, account_id, expires_at, consumed_at)
```

### Registration lifecycle

The requested "disable account creation after setup" is a persisted setting with
an environment override, and the first account to exist becomes the admin:

1. Fresh server boots with `registration_open = true`.
2. The first successful `POST /api/v1/accounts` creates the account **and sets
   `is_admin = 1`**. There is no bootstrap password to leak or forget.
3. Admin flips the switch: `PATCH /api/v1/admin/settings {"registration_open":
   false}`. Persisted in `setting`, effective immediately.
4. `EKO_REGISTRATION=closed` in the environment forces closed regardless of the
   database, so a deployment can be locked down without an API call and cannot be
   re-opened by anyone who reaches only the database.
5. With registration closed, new devices join through admin-minted single-use
   enrolment tokens rather than new accounts.

The window in step 1–2 is the one real exposure: a server reachable on the
internet with registration open and nobody registered yet can be claimed by a
stranger. Mitigations, in the order I recommend applying them: bring the server
up with `EKO_REGISTRATION=open` only for the setup window; or set
`EKO_BOOTSTRAP_TOKEN` and require it on the first account creation. The Compose
file ships with the bootstrap token required, because a self-hosted service that
is safe by default matters more than saving one paste during setup.

### Device authentication

Devices do not have passwords. A device proves possession of its identity key:

```
POST /api/v1/devices/challenge  {device_id}      -> {nonce, expires_at}
POST /api/v1/devices/auth       {device_id, nonce, sig}  -> {token, expires_at}
```

`sig` is ECDSA-P256-SHA256 over `"eko-relay-auth-v1" || nonce || device_id`,
verified against the registered public key. The returned bearer token is short
lived and scoped to that device's queues. This reuses the identity key that
already exists and adds no new secret to store.

---

## 5. HTTP and WebSocket surface

```
POST   /api/v1/accounts                     create account (gated)
POST   /api/v1/accounts/login               -> user token
PATCH  /api/v1/admin/settings               registration_open
POST   /api/v1/admin/enrolment-tokens       mint single-use device token
GET    /api/v1/admin/devices                list / revoke

POST   /api/v1/devices/enrol                {token, device_id, public_key}
POST   /api/v1/devices/challenge            -> nonce
POST   /api/v1/devices/auth                 -> bearer token

POST   /api/v1/queues/{peer}/envelopes      deposit (store-and-forward)
GET    /api/v1/queues/{peer}/envelopes?after=N   drain
POST   /api/v1/queues/{peer}/cursor         ack through N, allows pruning
GET    /api/v1/queues/{peer}/socket         WebSocket, live session channel

GET    /healthz                             liveness, no auth
GET    /readyz                              readiness incl. DB
```

Limits enforced server-side: envelope body ≤ 1 MiB (mirrors the §3 frame limit),
per-device deposit rate limit, per-account storage quota, and a retention sweep
(default 30 days, configurable — far longer than the phone's 48 h, which is the
point).

---

## 6. Client changes

### Transport abstraction

PLAN §13.1 claims v1 has "a transport interface with exactly one
implementation". That is half true and the gap has to close first. The frame
layer is already stream-shaped — `NormalPeerSession` reads and writes
`java.io.InputStream`/`OutputStream`, which is the expensive half and it is
done. But connection establishment is concrete: `NormalPeerSession.run(peer,
network)` takes an Android `Network` and builds TLS itself through
`TlsConnector`. There is no interface to implement.

```kotlin
interface EkoTransport {
    suspend fun connect(peer: ConfirmedPeer): EkoLink   // throws TransportException
}
interface EkoLink : Closeable {
    val input: InputStream
    val output: OutputStream
    val kind: TransportKind        // LAN | RELAY
}
```

`LanTransport` wraps today's `TlsConnector`. `RelayTransport` wraps the
WebSocket session channel and performs HPKE seal/open. The session code above it
does not change. The macOS side gets the symmetric treatment.

### Candidate selection

Ranked, per §13.2, with relay as the dependable rung rather than the last
resort:

1. Try LAN if a candidate endpoint is known and the network is plausible —
   still the fastest path and it works with no internet at all.
2. Otherwise, or on LAN failure within a short budget, use the relay.
3. Deposit unconditionally when no live link is available, so the outbox drains
   even with the Mac offline.

---

## 7. Threat model delta

What the relay operator (or anyone who compromises the relay) gains:

| | Before | After |
| --- | --- | --- |
| Notification content | not exposed | **still not exposed** (HPKE) |
| Which devices talk | not exposed | **exposed** |
| When, how often, message sizes | not exposed | **exposed** |
| Ability to withhold or delay | none | **yes** (denial of service) |
| Ability to inject | none | none — `mode_auth` rejects forged senders |
| Ability to add a device to a pairing | none | none — pinning is client-side |

Timing and size are a real side channel for a notification mirror: an observer
can infer *"this person received something from their bank at 14:32"* without
reading it. Mitigations available and worth doing if the relay is ever shared:
pad envelopes to size buckets, and batch deposits on a jitter. Not in phase 1.

The user-facing data-handling statement must change. It currently promises
*"device-to-device only — zero third-party traffic, no accounts, no telemetry by
default"*. With a relay configured that is no longer accurate, and the statement
needs a per-mode split (LAN-only vs relay-enabled) rather than a footnote.

**Operational reality, stated plainly:** a relay is a service someone has to keep
patched and up, and under GDPR the metadata above is personal data, so operating
one for other people carries processor obligations even though the content is
encrypted. Self-hosting for yourself and your household is a materially
different proposition from running a shared instance, and only the former is in
scope here.

---

## 8. Delivery plan

Staged, each stage independently reviewable and CI-verified.

| Phase | Contents | Verifiable in this environment? |
| --- | --- | --- |
| **1** | This document; protocol addendum (`relay-envelope-v1`), JSON schemas, test vectors | Yes — `scripts/check-protocol.py` |
| **2** | `server/` Rust crate: accounts, enrolment, device auth, queues, cursors, retention, admin settings; Docker Compose; integration tests | **Yes, fully** — build, run, and exercise over HTTP |
| **3** | HPKE envelope seal/open + a cross-language test vector suite both clients must satisfy | Partly — vectors verifiable, Swift half compile-checkable only |
| **4** | `EkoTransport` extraction on Android and macOS; no behaviour change | No — needs Android SDK / a Mac; CI only |
| **5** | `RelayTransport` on both clients, candidate ranking, settings UI | No — CI only |
| **6** | Data-handling statement, PLAN.md revision, operator docs | Yes |

**The honest constraint:** this environment has Docker, Rust and a Linux Swift
toolchain, but no Android SDK and no macOS. Phases 1–3 I can build and test here
end-to-end. Phases 4–5 I can write and CI can compile, but nobody can *run* them
until a Mac and a phone do. Given that the OTP work in #50 had three defects that
only showed up under execution — including one I introduced and one that hangs
the app — I would not claim phases 4–5 are done on the strength of a green
compile.

---

## 9. Open questions

1. **Shared instance or single-tenant?** The account model supports several
   accounts. If the intent is only ever "my household", dropping multi-account
   removes the admin surface entirely and shrinks the threat model.
2. **FCM wake-up in scope?** It composes well with the relay (§1) but adds a
   Firebase dependency that PLAN §5 currently rules out for v1.
3. **Does LAN survive long term?** Keeping it costs the D11 discovery stack
   forever. If relay reliability proves out, deleting LAN direct later is a large
   simplification — worth revisiting after phase 5 with real data.
4. **Padding and batching** — cheap to add later, but the metadata argument gets
   stronger the moment the relay is not solely yours.

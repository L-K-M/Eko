# Eko Protocol Version 1

Status: normative

This document defines Eko protocol version 1. It is the wire contract shared by
the Android phone and the macOS application. Implementations conform to v1 only
when they satisfy this document and the JSON Schemas in `schemas/`.

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT,
RECOMMENDED, NOT RECOMMENDED, MAY, and OPTIONAL are to be interpreted as in
BCP 14 when they appear in uppercase.

## 1. Scope and Roles

The phone is the TCP/TLS client. The Mac is the TCP/TLS server. In this
document `P -> M` means phone to Mac, `M -> P` means Mac to phone, and `both`
means either direction.

Version 1 carries notification events and controls in JSON frames. Binary
frames are reserved. Discovery is outside this protocol and is never an
identity or authorization source.

Every connection has exactly one of these modes, selected by the first JSON
message, `hello`:

* `normal`: a confirmed pairing may synchronize notification state.
* `pair`: an explicitly authorized, bounded TOFU pairing attempt may run.
* `unpair`: a locally revoked peer may run only the restricted unpair exchange.

A local revocation tombstone can also force a peer that sends `mode=normal`
into the restricted unpair state. It MUST NOT allow normal traffic merely
because the remote endpoint has not learned of the revocation yet.

## 2. Transport and Identity

### 2.1 TLS

All frames MUST be carried inside mutually authenticated TLS 1.3. There is no
cleartext mode and no TLS downgrade. Each installation has one long-lived,
self-signed P-256 leaf certificate and its corresponding private key.

For a confirmed pairing, the receiver MUST compare the exact presented leaf
certificate DER bytes with the stored pin. Certificate-chain validation alone
is not pin equality. Hostname validation is not used for raw IP endpoints.

Pair mode MAY accept one unknown leaf certificate only while the local user has
explicitly enabled pairing mode and only within the pairing limits in Section
7. Unpair mode MAY accept only the exact certificate retained in a revocation
tombstone.

### 2.2 Device identifiers

The device identifier is:

```
device_id = lowercase_hex(SHA-256(exact TLS leaf certificate DER))
```

It is exactly 64 ASCII characters matching `[0-9a-f]{64}`. Uppercase hex,
colon-separated fingerprints, hashes of PEM text, hashes of a public key, and
hashes of a re-encoded certificate are invalid.

Every field that claims the sender's identity, including `hello.device_id`,
`welcome.device_id`, and pairing-frame `device_id`, MUST equal the identifier
derived from the sender's leaf certificate on that TLS connection. A
`cert_der` value in pairing MUST decode byte-for-byte to that same leaf
certificate and its `device_id` MUST match the formula above. Reference
identifiers in unpair frames follow Section 14. Any mismatch is fatal.

## 3. Framing

Each frame is encoded as:

```
+----------------------+----------------+---------------------+
| length: u32, BE      | frame_type: u8 | payload             |
+----------------------+----------------+---------------------+
  4 bytes                1 byte           length - 1 bytes
```

`length` counts all bytes after the prefix, including the one-byte frame type.
The exact maximum `length` is 1,048,576 bytes. Therefore a JSON payload can be
at most 1,048,575 bytes.

A receiver MUST:

1. Read exactly four prefix bytes before interpreting the length.
2. Decode the prefix as an unsigned big-endian integer.
3. Reject `length=0` and `length>1048576` before allocating the frame body.
4. Read exactly `length` body bytes, allowing arbitrary TCP fragmentation.
5. Treat EOF in either the prefix or body as an incomplete frame and close.

Frame types are:

| Value | Meaning | v1 behavior |
| --- | --- | --- |
| `0x01` | UTF-8 JSON | Parse and validate as Section 4 requires. |
| `0x02` | Binary | Reserved; skip exactly `length-1` payload bytes. |
| Other | Unknown | Skip exactly `length-1` payload bytes. |

Skipping an unknown frame type does not authorize interpreting its payload.
The framing limit applies equally to known, reserved, and unknown types.

## 4. JSON Rules

The payload of frame type `0x01` MUST be a single UTF-8 encoded JSON object.
The following are fatal protocol errors:

* malformed or non-shortest-form UTF-8;
* a byte order mark;
* invalid JSON or trailing non-whitespace data;
* a top-level value other than an object;
* any duplicate object member name at any nesting level;
* a known field with the wrong JSON type;
* a known integer outside its defined range;
* failure of the applicable schema or a semantic rule in this document.

All protocol integers are JSON numbers in the inclusive range
`0..9007199254740991` (`2^53-1`) unless a smaller range is stated. On the wire,
known integer fields MUST use ordinary unsigned decimal notation without a
fraction, exponent, sign, or leading zero. A sequence-bearing event uses
`seq>=1`; cursors and state high-waters may be zero.

Unknown object members MUST be ignored after the complete frame has passed
the framing and JSON resource limits. Their names and values MUST NOT change
the meaning of known members. Unknown `type` values are fatal unless both
peers negotiated the `ext_types` capability. With `ext_types`, an unknown
message type is ignored as one whole frame. No core v1 behavior depends on
`ext_types`.

JSON Schemas express structural constraints. Requirements that schemas cannot
express, including duplicate-name rejection, UTF-8 byte limits, integer lexical
form, hash relationships, sequence coverage, and state-machine order, remain
normative.

## 5. Common Encodings

### 5.1 Identifiers

`outbox_gen`, `sync_id`, `request_id`, `unpair_id`, and `ping_id` are lowercase
canonical RFC 4122 version-4 UUID strings. They carry no ordering semantics.

`attempt_id` is exactly 16 random bytes from a CSPRNG, represented as 32
lowercase hex characters. Hash algorithms use the decoded 16 bytes, not the
ASCII hex representation.

SHA-256 values are the complete 32-byte digest represented as exactly 64
lowercase hex characters. Truncated hashes are forbidden except for the
human-visible SAS code defined in Section 7.3.

Certificate DER is represented with canonical RFC 4648 base64, including
required `=` padding and with no whitespace. A receiver MUST decode and
re-encode it to verify canonical form.

Pairing nonces are exactly 32 random bytes and are represented as 64 lowercase
hex characters. This exceeds the protocol's 128-bit minimum and removes a
variable-length interoperability choice in v1.

### 5.2 Capabilities

A capability list is a set: entries MUST be unique. Ordering has no semantic
meaning. A feature is enabled only when both endpoints advertised it.

Core v1 capability names are:

| Capability | Meaning |
| --- | --- |
| `notif` | Normal sync, event, active snapshot, fetch, and ACK support. |
| `dismiss` | The Mac may send `dismiss`. |
| `otp_context` | Structured notification extras and message arrays are present. |
| `ext_types` | Unknown JSON message types may be ignored. |

`notif` is REQUIRED in normal and pair hellos because a confirmed pair
transitions directly into normal sync. Unpairing is a core state-machine
function and does not depend on capability names.

### 5.3 Time

All wire times are Unix epoch milliseconds in the unsigned integer range from
Section 4. They are display or diagnostic data only. Ordering, expiry authority,
generation selection, replay, and supersession MUST NOT compare endpoint wall
clocks.

## 6. Connection State Machine

The first application frame after TLS readiness MUST be a JSON `hello` from the
phone. It MUST arrive within the local handshake timeout. Any other first frame
is fatal.

| State | Frames accepted |
| --- | --- |
| Await hello | `hello` only |
| Pairing | Pair frames, `ping`, `pong`, `error` |
| Await welcome | `welcome`, `unpair`, `ping`, `pong`, `error` |
| Synchronizing | Sync frames P -> M; `ack`, `ping`, `pong`, `unpair`, `error` |
| Live | Sequenced `event`; controls; a new sync is not allowed |
| Restricted unpair | `unpair`, `unpair_ack`, `error` only |
| Closing | No new application frames |

An endpoint MUST close on a frame that is valid in isolation but invalid in the
current state or direction. It MAY first send a fatal `error` if the frame can
be safely parsed and doing so does not disclose pairing data.

## 7. Hello, Versioning, and Pairing

### 7.1 `hello` (P -> M)

All hello modes carry the phone's certificate-derived `device_id`, display
name, Android version, capabilities, wall time, and `conn_epoch`.

`mode=normal` additionally carries `outbox_gen`.

`mode=pair` additionally carries `attempt_id`, `outbox_gen`, and optionally a
single-use `qr_token`. A QR token is 32 random bytes encoded as unpadded
base64url. It is a secret proof transported inside TLS, expires 300 seconds
after issue according to the Mac's monotonic clock, and MUST be consumed at
most once.

`mode=unpair` additionally carries the tombstone's `unpair_id`. It does not
need a working event store and therefore does not carry `outbox_gen`.

`proto_min` and `proto_max` form an inclusive range. The Mac chooses the
highest mutually supported version. V1 supports only version 1. No overlap
causes `error{code="incompatible"}` and close. For a confirmed peer, each side
MUST persist the highest protocol version previously used and MUST reject a
downgrade below that value.

### 7.2 Strict connection epochs

`conn_epoch` is one per-install counter shared by all phone pairings. It is
stored with identity data outside the replaceable event database, excluded
from backup, incremented before every connection attempt, never reset on reboot
or event-store replacement, and never wrapped.

For each peer certificate, the Mac durably stores the highest accepted epoch.
Acceptance of a hello and advancement of this high-water MUST be atomic. A
hello is eligible only when its epoch is strictly greater than the durable
high-water. A lower or equal epoch receives `error{code="superseded"}` and is
closed. This rule applies even when no older socket is currently live.

When a higher epoch is accepted while an older socket is live, the Mac first
reserves the new epoch, makes the new connection authoritative, closes the old
socket, and discards all frames buffered from the old connection. Messages
after hello do not carry epochs; authority is attached to the connection.

Pair attempts keep the same rule in bounded pending-attempt state keyed by
certificate and `attempt_id`. Revocation tombstones retain the epoch high-water
so restricted unpair connections also reject zombies.

### 7.3 Deterministic pairing hashes

The following byte encoding is used by every v1 pairing hash:

```
LP(X) = u32_be(byte_length(X)) || X
```

The length is an unsigned four-byte big-endian value and counts bytes, not
characters. Domain strings are the exact ASCII bytes shown, with no NUL and no
LP wrapper unless one is explicitly shown.

For endpoint `i`, with its exact leaf certificate DER `cert_i` and 32-byte
nonce `nonce_i`, the commitment is:

```
commit_i = SHA-256(
  ASCII("eko-pair-commit-v1") ||
  LP(attempt_id_bytes) ||
  LP(cert_i) ||
  nonce_i
)
```

The nonce is terminal and therefore is not separately length-prefixed in the
commitment input.

For the SAS, form each owner-bound tuple as:

```
tuple_i = LP(cert_i) || LP(nonce_i)
```

Sort the two complete tuples by unsigned lexicographic comparison of their
`cert_i` DER bytes only. The nonce always stays with its certificate. Equal
certificate DER values are invalid. If `(tuple_0, tuple_1)` is the sorted
order, then:

```
sas_digest = SHA-256(
  ASCII("eko-pair-sas-v1") ||
  LP(attempt_id_bytes) ||
  LP(tuple_0) ||
  LP(tuple_1)
)

transcript_hash = lowercase_hex(sas_digest)
verification_code = uppercase_hex(sas_digest)[0:8]
```

No timestamp, role, display name, discovery value, QR token, JSON spelling, or
network address enters these hashes. Golden byte inputs, LP lengths, and hash
outputs are in `test-vectors/sas.json`.

### 7.4 Pair frame flow

Pairing is allowed only when both local applications are in explicit pairing
mode. An attempt expires 300 seconds after its first accepted pair hello,
measured by each endpoint's monotonic clock. Expiry deletes pending state and
any pending event-DB pairing row, sends `error{code="pairing_expired"}` when a
safe connection exists, and requires a new `attempt_id`. Implementations also
bound concurrent attempts and rate-limit them.

1. The phone sends `hello{mode="pair"}`.
2. Each endpoint sends one idempotent `pair_request` containing its role,
   `attempt_id`, exact TLS leaf `cert_der`, derived `device_id`, display name,
   and method (`compare` or `qr`). Every repeated value MUST be identical. Both
   methods MUST match. `qr` is valid only after the Mac successfully validates
   and consumes the hello's QR token.
3. Each endpoint persists its nonce and sends `pair_commit`. An endpoint MUST
   NOT send `pair_reveal` until it has received and durably recorded the peer's
   commitment.
4. Each endpoint sends `pair_reveal`. It verifies the peer commitment before
   deriving or displaying a verification code. A mismatch is fatal and the
   attempt cannot be resumed.
5. Before requesting confirmation, each endpoint durably records the attempt,
   peer DER pin, transcript hash, nonce, and `pending` state.
6. Each endpoint sends an idempotent `pair_result{result="accept"}` after local
   confirmation, or `result="reject"` after local rejection. QR proof MAY make
   local acceptance automatic, but the same result frame is used.
7. After the phone has both accepts, it atomically creates the per-Mac event-DB
   pairing row with `acked_seq=H` and `serve_from_seq=H+1`, where `H` is the
   current durable `last_assigned_seq`. It sends
   `pair_result{result="ready",outbox_gen=G,initial_cursor=H}`.
8. The Mac atomically stores the confirmed pin, generation `G`, and
   `processed_through_seq=H`, then sends an exact echo in
   `pair_result{result="confirmed"}`.
9. The phone marks its identity-store pairing confirmed. The Mac sends
   `welcome` with cursor `H`; the connection then follows normal sync.

`pair_result` also carries the sender's `device_id` and `transcript_hash`.
`ready` may be sent only by the phone; `confirmed` may be sent only by the Mac.
The echoed generation and cursor MUST match exactly.

All pair frames are idempotent by `(attempt_id,type,sender device_id,result)`. A
different payload under the same idempotency key is fatal. A sender cannot
change `accept` to `reject`, or send both; rejection is terminal. After
disconnect, an unexpired pending attempt resumes under the same `attempt_id`,
same certificates, same nonces, same commitments, and same transcript. A new
connection uses a higher `conn_epoch`. Regenerating a nonce on retry is
forbidden. If the event generation changes before `confirmed`, the attempt is
aborted and must restart with a new attempt identifier.

No welcome, event, active state, cursor other than `initial_cursor`, or
notification data may be disclosed before the Mac has committed `ready`.

## 8. Normal Session Establishment and Generations

### 8.1 Generation namespace

`outbox_gen` is a random UUID created with the event-store metadata. It changes
if and only if the phone sequence space is replaced. Event identity is the
triple `(device_id,outbox_gen,seq)`.

After accepting a normal hello epoch, the Mac processes its generation before
sending `welcome`:

* If the incoming generation is current, use its durable cursor.
* If it is in the retired-generation set, send
  `error{code="stale_generation"}` and close.
* If it is unseen and differs from current, atomically retire the old
  generation, append a local generation-transition history marker, select the
  new generation, set its `processed_through_seq` to zero, and clear only the
  device's materialized current-active state. Old event history remains under
  its old namespace. This transition is not a sequence gap.

The Mac then sends `welcome` containing its certificate-derived `device_id`,
selected protocol, accepted `outbox_gen`, negotiated capabilities, and the
durable `processed_through_seq` as `cursor`.
`welcome.caps` is exactly the set intersection of capabilities supported by
the Mac and advertised in hello; it MUST contain `notif`.

The phone MUST reject a welcome whose `outbox_gen` differs from the generation
in its accepted hello.

If `welcome.cursor` is greater than the phone's durable
`meta.last_assigned_seq`, the phone MUST NOT clamp it and MUST NOT sync. It
MUST execute its journaled generation replacement: durably mark reset pending,
retire the old generation, allocate a new generation, advance `conn_epoch`,
create an empty event DB with high-water zero, rehydrate confirmed pairing rows
at cursor zero/floor one, close old-generation sockets, and complete the
journal. It then reconnects with another strictly higher epoch and the new
generation. Old rows MUST NOT be relabeled or copied into the new generation.

### 8.2 Cursor and availability

The Mac's cursor means `processed_through_seq`: every position from 1 through
the cursor is durably represented by either exactly one committed event row or
an explicit committed definitive gap marker. A `capture_gap` is an ordinary
event row occupying one sequence position; it is not a range hole.

For the current pairing, the phone computes:

```
effective_floor = max(pairing.serve_from_seq, pairing.acked_seq + 1)
requested_from  = welcome.cursor + 1
replay_from     = max(requested_from, effective_floor)
```

`welcome.cursor` is request authority. `effective_floor` is availability
authority. If `requested_from < effective_floor`, the phone reports every
unavailable position in that prefix with one or more `backlog_gap` frames.
Retained reasons are preserved; otherwise the reason is
`peer_cursor_regressed`.

## 9. Stable Replay Transaction

Every accepted `welcome` starts exactly one replay transaction, even when no
events are pending.

The phone obtains these values from one consistent event-DB read snapshot:

* `H = meta.last_assigned_seq`;
* all event rows in `[replay_from,H]`;
* all definitive gap spans needed to cover unavailable requested positions;
* the complete active-notification materialization at `H`.

It generates a fresh `sync_id`. `H`, the selected rows, gaps, active snapshot,
and `sync_id` are immutable for this replay. If the database API cannot hold
the read transaction while frames are sent, the phone MUST materialize the
same bounded result before releasing the transaction.

The phone's single outbound actor sends, in this exact order:

1. One `backlog_start` with `from_seq=replay_from`,
   `replay_to_seq=H`, and the exact number of sequenced event frames in
   `event_count`.
2. Zero or more non-overlapping `backlog_gap` frames ordered by `from_seq`.
   Adjacent spans with the same reason MUST be compacted when they fit.
3. Exactly `event_count` sequenced `event` frames in strictly increasing `seq`
   order. Every one has `flags.replayed=true` and this replay's `sync_id`.
4. One or more `active_chunk` frames. Indices start at zero and increase by
   one. Only the last has `final=true`. An empty active set is one frame with
   `index=0`, `final=true`, and an empty `active` array.
5. One `backlog_end` with `state_seq=H`.
6. Sequenced live events with `seq>H`, in order, with
   `flags.replayed=false`.

Every sync frame, including each replayed event, carries the identical
`sync_id`. A live or fetch event MUST NOT carry a `sync_id`. Both
`backlog_start.replay_to_seq` and `backlog_end.state_seq` equal `H`. Each active
entry has the key's own last materialized sequence as `state_seq`, not the
global `H`, and satisfies `1<=state_seq<=H`. Active keys MUST be unique across
all chunks. Every gap has `from_seq<=to_seq`.

The union of events and definitive gap spans MUST cover every requested
position through `H` that was not already at or below `welcome.cursor`.
Overlap between a gap and an event at the same position is fatal. A sequence
hole without a gap is fatal.

The Mac MAY commit replay events and gaps incrementally and ACK committed
coverage. It MUST NOT apply an active snapshot until all chunk indices and
`backlog_end` for that `sync_id` have arrived. A disconnect discards incomplete
active chunks. Already committed events, gaps, and processed-through progress
remain valid and make the next welcome resume later.

## 10. Events and Notification Hashes

### 10.1 Sequenced event variants

A sequenced `event` has one of four `ev` values:

* `posted`: create or replace active state for `key`.
* `updated`: replace active state for the existing opaque `key`.
* `removed`: delete active state for `key`; `h` is null and `remove_reason` is
  required.
* `capture_gap`: record an evidence-backed, suspected capture interval; `h` is
  null and no notification key or body is present.

Keys are opaque UTF-8 strings and MUST never be parsed. Posted and updated
events carry `app`, `n`, `dnd`, and the complete content hash. Removed events
carry metadata but no `n`. `capture_gap` carries `confidence="suspected"`, an
approximate interval, and one of the v1 evidence codes
`listener_disconnected`, `process_exit`, or `writer_overflow`. Ordinary
notification silence is not evidence and MUST NOT create a capture-gap event.
At least one interval bound MUST be non-null; when both are present,
`start_at<=end_at`.

`posted_at` is the notification's Android wall-clock post time and `user` is
its nonnegative Android user/profile identifier. `app.pkg` is the notifying
package, `app.label` is the phone-resolved display label, and `app.category` is
the nullable Android category. `dnd.filter` is one of `unknown`, `all`,
`priority`, `none`, or `alarms`; `dnd.suppressed` records per-notification
suppression. `remove_reason.code` is the nonnegative Android `REASON_*` value,
using zero when unavailable. For a phone-synthesized reconciliation removal,
both `remove_reason.reconciled` and `flags.reconciled` MUST be true; otherwise
`remove_reason.reconciled` is false. `truncated_fields` is empty when no field
was changed by Section 10.3.

Each callback transaction allocates exactly one new sequence. V1 does not
coalesce committed callbacks. Within a generation, sequences are never reused.

`flags.replayed` and a replay event's `sync_id` are transport metadata overlaid
for one peer. They are not stored in the shared outbox payload.
`flags.reconciled` marks a phone reconciliation event or a synthetic fetch
response as applicable.

### 10.2 Canonical `n` hash

For every posted, updated, active-snapshot, and successful fetch state:

```
h = lowercase_hex(SHA-256(JCS_UTF8(n)))
```

`JCS_UTF8(n)` is the UTF-8 encoding of the exact `n` object serialized under
RFC 8785 JSON Canonicalization Scheme. There is no Unicode normalization. All
members of `n`, including an extension member unknown to the receiver, enter
the canonicalization. The digest is always the full 64 lowercase hex
characters.

The phone computes and stores the hash. The Mac stores and compares the
phone-provided value and does not re-canonicalize notification bodies for sync
correctness. Phone conformance tests MUST nevertheless reproduce the golden
canonicalization vectors.

### 10.3 Deterministic extraction limits

The phone replaces unpaired UTF-16 surrogates with U+FFFD before measuring or
encoding text. It preserves all other Unicode scalar values and performs no
normalization. Limits count UTF-8 bytes and truncation keeps the longest prefix
that does not split a Unicode scalar.

Per-value limits are:

| Value | Maximum UTF-8 bytes |
| --- | ---: |
| notification `key` | 8192 |
| package name | 512 |
| app label | 2048 |
| category | 128 |
| `title`, `text`, `sub_text`, `info_text`, `summary_text`, `group_key` | 8192 each |
| `big_text` | 65536 |
| each `text_lines` entry | 8192 |
| each message sender | 4096 |
| each message text | 16384 |

Opaque `key` and package-name identifiers MUST NOT be truncated. If either
exceeds its limit, the callback is represented by a sequenced `capture_gap`
with `writer_overflow` evidence. App label and category are prefix-truncated
when needed and record `/app/label` or `/app/category` in
`truncated_fields`. Those app pointers precede body pointers, in label then
category order.

`text_lines` and `messages` each contain at most 64 entries. The total UTF-8
bytes across all string values inside `n` is at most 524288. The aggregate
budget is consumed in this exact traversal order:

1. `title`, `text`, `big_text`, `sub_text`, `info_text`, `summary_text`;
2. `text_lines` in array order;
3. each message's `sender`, then `text`, in message order;
4. `group_key`.

For each non-null source string, first apply its per-value limit, then consume
the remaining aggregate budget. If a non-empty source reaches zero remaining
budget, encode it as the empty string. Drop array entries beyond 64. Every
changed or dropped value is recorded once in `truncated_fields` using an RFC
6901 JSON Pointer, ordered by the traversal above. Dropping excess array items
records `/text_lines` or `/messages`; it does not enumerate absent indices.

This budget, the non-body limits, and the frame cap are independent. An event
that still cannot be encoded below the frame cap is a local capture error and
MUST be replaced by a sequenced `capture_gap` with `writer_overflow` evidence;
it MUST NOT block later ordered events.

## 11. Processed-Through and ACK

For each current generation, the Mac advances `processed_through_seq` only in
a transaction that commits the covering event row or definitive gap marker.
Given current value `C`:

* an event at `C+1` can advance to `C+1`;
* a gap with `from_seq<=C+1<=to_seq` can advance to `to_seq`;
* already committed duplicate positions are idempotent only when their stored
  meaning is identical;
* a position above `C+1` cannot advance the cursor until all preceding
  positions are covered.

An event and gap cannot both cover one position. Duplicate comparison ignores
the per-session `sync_id` and `flags.replayed`, but all durable event fields
must match. A duplicate sequence with a different durable body, event kind,
key, or hash is a fatal sequence conflict.

The Mac sends cumulative `ack{seq=N}` only after every position through `N` is
covered and the new processed-through value has committed. ACK batching is
recommended every 20 new events or one second, whichever comes first, but the
commit rule is mandatory.

For each connection, the phone initializes `authorized_through` to the accepted
welcome cursor and advances it only over contiguous positions for which it has
actually sent an event or definitive gap. Advertising `replay_to_seq` alone
does not authorize an ACK. An ACK is valid only when:

* `seq` is greater than or equal to the pairing's durable `acked_seq`; and
* `seq` is no greater than this connection's `authorized_through`.

Equal ACKs are idempotent. A lower ACK or ACK ahead of sent coverage causes
`error{code="invalid_ack"}` and close. After validation, the phone durably
advances `pairing.acked_seq` and may prune rows no pairing needs.

## 12. Active Snapshot and Fetch Freshness

Each active entry contains `key`, the full body hash `h`, and that key's
`active_notification.last_seq` as `state_seq`. The Mac assembles all chunks
for one sync before reconciliation.

At `backlog_end.state_seq=H`, the Mac atomically applies the snapshot:

* a locally active key absent from the snapshot becomes a local synthesized
  removal at state sequence `H`;
* a new key or one whose stored hash differs is queued for `fetch`;
* an equal key and hash requires no fetch.

`fetch` carries a fresh, connection-unique `request_id` and 1 through 128
unique keys. The Mac has at most one fetch request outstanding and sends the
next batch only after receiving one response for every key in the current
batch. The phone answers exactly once per key, in request order, from one read
transaction:

* an active key yields a synthetic `event` with no `seq`, `ev="posted"`, the
  request identifier, `state_seq=active_notification.last_seq`, and
  `flags={"replayed":false,"reconciled":true}`;
* an absent key yields `fetch_missing` with the request identifier and
  `state_seq=meta.last_assigned_seq` read in the same transaction as the
  absence.

Fetch responses do not consume sequences, change processed-through, or permit
an ACK. They are scoped to the connection's accepted generation.

For every key, the Mac tracks the greatest sequenced or snapshot state sequence
it has applied in the current generation. It MUST ignore a fetch event or
`fetch_missing` whose `state_seq` is lower than that value. At equal state
sequence, a fetch result may fill a missing body, but it MUST NOT contradict an
already complete state; a contradiction is a protocol error. State sequences
are never compared across generations.

## 13. Controls

### 13.1 Ping and pong

The phone may send `ping` with a fresh `ping_id` and its current `phone_time`.
The Mac returns `pong` with the same identifier, an exact echo of
`phone_time`, and its current `mac_time`. Times are diagnostic only.

While CPU and network scheduling are available, the phone targets a ping every
25 seconds, with the first jittered by up to 10 seconds, and closes after a
10-second pong deadline. The Mac targets a 90-second inbound-silence timeout.
Deep idle may suspend all timers, so these are awake-state latency targets and
not wall-clock recovery guarantees.

### 13.2 Dismiss

With the negotiated `dismiss` capability, the Mac may send `dismiss{key}`.
The phone calls the platform dismissal operation if that key is active. There
is no synchronous success frame. A resulting platform callback is a normal
sequenced `removed` event. An already absent key is an idempotent no-op.

### 13.3 Error

`error` is advisory and fatal unless its `fatal` member is false. Core v1 fatal
codes are listed in its schema. Framing corruption, invalid UTF-8, or resource
exhaustion MAY be closed without an error because a safe JSON response may not
be possible. Error text is diagnostic and MUST NOT be parsed for behavior.

## 14. Two-Phase Unpair

Unpair uses a stable random `unpair_id` and two wire messages: `unpair` and
`unpair_ack`. The security property is that a pin is not discarded by the
initiator until the authenticated peer has applied or already applied the
revocation.

### 14.1 Connected initiation

1. The initiator durably enters `revoked_pending`, stores the peer DER,
   `unpair_id`, epoch high-water, and any endpoint needed for contact, then
   blocks new normal traffic. It sends `unpair` with the initiator and peer
   device identifiers.
2. The receiver verifies that request `initiator_id` is the TLS sender and that
   `peer_id` is itself, in addition to verifying the TLS pin. In one local
   transaction it deletes the normal pairing data, releases its cursor/floor,
   removes only CDM associations unused by every remaining pairing, and writes
   an idempotent applied receipt retaining the peer DER and `unpair_id`.
3. The receiver sends `unpair_ack` with status `applied`, or
   `already_applied` for an exact retry, then closes after flushing it.
4. On a matching authenticated ACK, the initiator deletes its pairing data,
   history as required by product policy, pin, and pending tombstone.

An ACK reverses those roles: `initiator_id` still names the original request
sender, while `peer_id` MUST be the ACK's TLS sender. If the ACK is lost, the
initiator retries the same `unpair_id`; it never creates a new request for the
same local action. Because there is no third wire phase proving ACK delivery,
the receiver's minimal applied receipt MUST NOT expire by time. It remains
until an explicit local "forget without notifying" action or an explicitly
confirmed new pairing supersedes it. It authorizes only the restricted
exchange and contains no notification data.

### 14.2 Offline initiation and contact direction

An offline local unpair immediately deletes normal local data and creates the
same `revoked_pending` tombstone.

* A phone-side pending tombstone makes bounded dials to its retained Mac
  endpoint, sends `hello{mode="unpair"}`, then sends `unpair`.
* A phone-side applied receipt also makes bounded dials when needed to deliver
  a previously lost ACK. It sends `hello{mode="unpair"}` with the same
  `unpair_id`, then may send `unpair_ack{status="already_applied"}` immediately
  or answer the Mac's repeated request with that ACK.
* A Mac-side tombstone waits for the phone. If the unaware phone sends a normal
  hello, the Mac accepts the strictly newer epoch only into restricted unpair,
  sends its stored `unpair`, and accepts only the matching ACK.
* If both sides revoked offline, each request is independently idempotent. Both
  identifiers can be acknowledged on the one restricted connection before it
  closes.

No `welcome`, sync frame, event, fetch body, pairing frame, or ordinary control
is accepted or disclosed in restricted unpair. A normal hello admitted under
a retained revocation receipt receives `error{code="unpaired"}` or the pending
unpair exchange and then closes. After the certificate has been fully
forgotten, TLS rejects it as unknown unless both applications explicitly enter
new pairing mode; no application frame is then available for an error reply.

## 15. Frame Catalog

The schemas are the field-level source of truth. This table fixes direction and
state for every v1 JSON frame.

| Type | Direction | State and purpose |
| --- | --- | --- |
| `hello` | P -> M | First frame; selects normal, pair, or unpair mode. |
| `welcome` | M -> P | Selects protocol/generation and supplies durable cursor. |
| `pair_request` | both | Re-exchanges exact identity inside TLS. |
| `pair_commit` | both | Commits to the sender-owned pairing nonce. |
| `pair_reveal` | both | Reveals the committed nonce. |
| `pair_result` | both | Accept/reject and ready/confirmed completion phases. |
| `backlog_start` | P -> M | Opens one stable replay snapshot. |
| `backlog_gap` | P -> M | Definitive unavailable sequence span. |
| `active_chunk` | P -> M | Bounded chunk of active-state snapshot. |
| `backlog_end` | P -> M | Closes replay at the fixed high-water. |
| `event` | P -> M | Sequenced event or non-sequenced fetch result. |
| `ack` | M -> P | Cumulative committed event-or-gap coverage. |
| `fetch` | M -> P | Requests current bodies for active keys. |
| `fetch_missing` | P -> M | Reports an absent requested key. |
| `dismiss` | M -> P | Requests platform dismissal of one opaque key. |
| `ping` | P -> M | Liveness request. |
| `pong` | M -> P | Liveness response. |
| `unpair` | both | Authenticated idempotent revocation request. |
| `unpair_ack` | both | Authenticated revocation result. |
| `error` | both | Protocol or state error. |

## 16. Retention and Gap Requirements

Retention is virtual per pairing and physical deletion is global. Before a
retention policy advances `serve_from_seq` beyond an unacknowledged position,
the phone MUST transactionally insert or merge an exact `gap_span` for that
pairing and generation. Only then may it make those rows unavailable.

A physical outbox row may be deleted only when no pairing both has not ACKed it
and is still eligible to be served it. Unpairing removes that pairing from the
calculation. Gap spans remain available until the affected pairing has received
and advanced beyond them.

V1 definitive backlog gap reasons are:

* `retention_count`: the pairing's retained event-count limit advanced.
* `retention_age`: the pairing's retained age limit advanced.
* `peer_cursor_regressed`: the peer requested previously ACKed and deleted
  positions for which no more specific retained reason remains.

When count and age policies advance the floor in one transaction, compare
their independently computed floors. The reason for the newly unavailable
range is `retention_count` when the count floor is greater than or equal to the
age floor, and `retention_age` otherwise. The count reason therefore wins an
exact tie. Existing retained spans keep their original reason.

Generation replacement is never encoded as a backlog gap because old and new
sequence numbers inhabit different namespaces.

## 17. Failure Handling Summary

The receiver closes the connection on malformed framing, invalid JSON, schema
failure, identity mismatch, epoch regression, retired generation, invalid ACK,
sequence conflict, sync ordering error, pairing transcript mismatch, or a
forbidden frame in restricted unpair.

A reconnect always starts with a new strictly higher phone epoch. Normal resume
uses the Mac's durable processed-through cursor. At-least-once transport plus
generation-scoped uniqueness and ACK-after-commit yields an exactly-once
storage effect for committed positions.

The protocol guarantee is limited and precise: a phone event-store transaction
that committed is retained until a valid ACK or an explicitly transmitted
retention gap authorizes deletion. Inputs not committed and notifications never
delivered by Android are outside that guarantee. Evidence-backed uncertainty is
represented by sequenced `capture_gap` events, never by inventing definitive
missing events.

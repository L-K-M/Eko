# Eko reference and chaos tools

`eko_harness.py` is a dependency-free Python 3 reference model for Eko's store-and-forward rules and
a loopback fake phone/Mac framing simulator. It is deterministic for a given command line and exits
nonzero on the first violated invariant.

## Requirements

- Python 3.9 or newer.
- No packages outside the Python standard library.
- Linux, macOS, or Windows. The simulator uses `socketpair` where available and loopback TCP as a
  fallback.

Run commands from the repository root.

On Windows, use `py -3` in place of `python3` in the examples below.

## Chaos/reference model

```sh
python3 tools/eko_harness.py chaos --seed 20260724 --steps 1000 --pairings 3
```

Run a consecutive deterministic seed range:

```sh
python3 tools/eko_harness.py chaos --seed 1000 --runs 100 --steps 2000 --pairings 4
```

Machine-readable output is stable and contains no elapsed time or random UUID:

```sh
python3 tools/eko_harness.py chaos --seed 20260724 --json
```

The model performs and checks:

- One monotonic sequence space per phone generation.
- Multiple independent Mac pairings over one shared physical outbox.
- New-pairing high-water boundaries that prevent pre-pair history disclosure.
- Cumulative ACK validation. Per-session authorization starts at the accepted welcome cursor and
  advances only over sent event-or-gap coverage, so an equal ACK (including one on an otherwise
  empty session) is idempotently valid while non-monotonic and ahead-of-authorization ACKs are
  rejected.
- ACK loss followed by cursor-authoritative reconnect.
- Per-pairing count and age floors computed independently against a deterministic phone clock.
  Each advancing floor records an exact, reasoned gap before deletion; the count reason wins an
  exact floor tie, matching the protocol retention rule.
- The global prune rule: a row remains while any pairing still needs it.
- Partial backlog delivery and reconnect from the Mac's committed cursor.
- Mac database regression and explicit `peer_cursor_regressed` coverage.
- Phone generation reset without sequence comparison across generations.
- Sequenced `capture_gap` events as events, distinct from definitive retention spans.
- A final drain proving every post-pair sequence in the current generation for every active Mac is
  represented by exactly one event or explicit gap. Retired generations retain their already
  committed cursor coverage and a separate generation-transition marker.

The final SHA-256 digest covers the complete deterministic phone/Mac model state. Repeating identical
arguments must produce the same digest.

## Fake framed phone and Mac

Run a complete fragmented loopback exchange with a prefix retention gap:

```sh
python3 tools/eko_harness.py simulate --events 12 --gap-through 3
```

The fake phone sends `hello`, receives `welcome`, then sends `backlog_start`, an optional prefix
`backlog_gap`, ordered events, a final empty `active_chunk`, and `backlog_end`. Every replay frame
carries one `sync_id`. The fake Mac advances its cursor only across exact event-or-gap coverage,
requires the complete active snapshot, and returns a cumulative ACK. Every frame is split into
deterministic 1, 2, 3, 5, 8, and 13-byte socket writes so neither endpoint can assume message-aligned
reads. The fake phone also inserts an unknown `0x7f` frame so the fake Mac proves it can skip an
extension by its declared length without desynchronizing the stream.

Verify truncated-stream rejection at a chosen byte boundary:

```sh
python3 tools/eko_harness.py simulate --truncate-at 7
```

The simulator covers the application envelope `[u32 big-endian length][u8 type][payload]`, the
1,048,576-byte bound, strict UTF-8/JSON parsing helpers, and replay ordering. It deliberately uses
local unencrypted sockets. It is not evidence for TLS 1.3, mutual authentication, certificate pins,
Network.framework, Conscrypt, Room/SQLite durability, GRDB, or OS lifecycle behavior. Those require
the implementation and hardware procedures in `/docs/hardware-spikes.md`.

The importable classes `FakePhone`, `FakeMac`, `ReferencePhone`, and `ReferenceMac` can be adapted by
platform integration tests. Preserve the explicit insecure loopback boundary unless a test supplies
the production TLS stack.

## Tests

```sh
python3 -m unittest discover -s tools/tests -v
```

The suite includes framing fragmentation/malformed input, multi-pair pruning, ACK rejection,
welcome-cursor ACK authorization (equal empty ACKs, lost-ACK reconnects without new frames),
count/age retention floors with the exact-tie reason rule, retention gaps, reconnect after
partial delivery, cursor regression, generation reset, deterministic multi-seed chaos, and the
fake peer exchange.

## Interpreting failures

- `session coverage skipped` means the phone tried to send a later position without an event or gap.
- `cursor advanced without exact event-or-gap coverage` means the Mac committed an invalid cursor.
- `physical pruning mismatch` means a shared row was deleted too early or retained contrary to the
  modeled prune transaction.
- `ack exceeds sequence authorized` means an ACK could authorize deletion of data not sent as an event
  or explicit gap on that session.
- A different digest for identical arguments indicates nondeterminism even if both runs otherwise
  report pass.

When reporting a failure, include the full command, Python version, seed, step count, pairing count,
and output. A seed is a replay recipe; increasing run count without retaining the failing seed loses
that value.

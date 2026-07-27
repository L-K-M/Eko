# Eko Protocol Artifacts

`protocol.md` is the normative Eko v1 wire specification. The other files are
machine-readable conformance data shared by the Kotlin and Swift test suites.

## Layout

```
protocol.md
schemas/
  common.schema.json
  frame.schema.json
  <message>.schema.json
test-vectors/
  framing.json
  content-hash.json
  discovery.json
  sas.json
  malformed-frames.json
  scenarios/*.json
otp-corpus/*.yaml
```

All protocol and vector files are ASCII. Unicode appears only in OTP corpus
message strings whose purpose is to test Unicode or a non-English language.

## JSON Schemas

Schemas use JSON Schema Draft 2020-12. `schemas/frame.schema.json` is the union
of all twenty core v1 JSON message schemas:

```
hello             welcome           pair_request       pair_commit
pair_reveal       pair_result       backlog_start      backlog_gap
active_chunk      backlog_end       event              ack
fetch             fetch_missing     dismiss            ping
pong              unpair            unpair_ack         error
```

File names use hyphens where JSON `type` names use underscores. Relative `$ref`
values resolve against each schema's `$id`. A validator that does not retrieve
the `https://eko.local/` identifier space must preload every file in `schemas/`
into its local schema registry by `$id`.

Schemas intentionally permit unknown object members. This implements the
forward-compatibility rule in `protocol.md`; it does not weaken validation of a
known member. Stateful, byte-level, and relational rules are validated by the
scenario and framing suites rather than JSON Schema.

## Framing Vectors

`test-vectors/framing.json` has format `eko-framing-v1`.

Each ordinary vector supplies:

* `frame_type`: unsigned one-byte value in decimal;
* `payload_utf8` or `payload_hex`: exact payload bytes;
* `length`: expected big-endian prefix value, including the type byte;
* `prefix_hex`: exact four prefix bytes;
* `wire_hex`: exact prefix, type, and payload bytes;
* `expect`: `decode_json` or `skip`.

The maximum-size case uses `construction` instead of embedding more than one
million hex bytes. Concatenate `prefix_hex`, `frame_type_hex`, then repeat
`payload_octet_hex` exactly `payload_repeat` times. This is a complete,
deterministic byte construction.

TCP chunk boundaries have no semantic effect. A harness SHOULD run each
ordinary `wire_hex` once as one read and again split at every possible byte
boundary for short vectors.

## Content Hash Vectors

`test-vectors/content-hash.json` has format `eko-content-hash-v1`. For each
case, serialize `n` with RFC 8785 JCS, UTF-8 encode it, and compare both
`canonical_utf8_hex` and the complete lowercase `sha256`. `canonical_utf8` is a
human-readable copy of the same bytes.

## Discovery Constants

`test-vectors/discovery.json` has format `eko-discovery-v1`. Its fixed BLE
service UUID is advertised by the Mac and used by Android's companion-device
filter. Discovery remains an untrusted hint; this constant does not establish
peer identity.

## SAS Vectors

`test-vectors/sas.json` has format `eko-sas-v1`. Certificate and nonce inputs
are hex-encoded bytes. The vector supplies exact byte lengths, LP prefixes,
certificate-derived device identifiers, commitments, sorted tuple order, full
transcript hash, and displayed verification code.

A harness MUST execute every `input_orders` permutation and obtain the same
`expected.tuple_order`, transcript hash, and code. It MUST bind each nonce to
its named certificate before sorting. LP is always a four-byte unsigned
big-endian byte length followed by those bytes.

`additional_vectors` verifies that the attempt identifier changes both
commitments and SAS, and that swapping nonces between certificate owners does
not reproduce the primary SAS.

## Malformed Vectors

`test-vectors/malformed-frames.json` has format `eko-malformed-v1`. Cases are
independent.

An `input.wire_hex` is already framed. For `input.payload_utf8`, UTF-8 encode
the exact string, prepend `input.frame_type` (default `1`), and prepend the
computed four-byte length. `eof: true` means the stream ends immediately after
the supplied bytes. `context` establishes negotiated capabilities or protocol
state.

`expect.action` is one of `close`, `ignore`, or `skip`. Error labels are stable
test-harness labels; an implementation is not required to put that label on
the wire when `protocol.md` permits a silent close.

## Scenario Vectors

Every file in `test-vectors/scenarios/` uses format `eko-scenario-v1`. A file
contains either one ordered `steps` trace or independent `cases`.

Conventions are:

* `initial` and `precondition` define durable state before a trace.
* `from` identifies the sender.
* `connection` distinguishes concurrent or replacement sockets.
* `frame`, `receive`, `expect_send`, `captured_response`, and
  `buffered_old_connection_frame` are complete core v1 frames and must validate
  with `schemas/frame.schema.json`.
* `frame_from_step` reuses the complete frame captured at the numbered step.
* `exact_frame_references` replays the same semantic frame values; JSON object
  member order may change, but certificates, nonces, commitments, identifiers,
  decisions, and every other value may not.
* `action` names a local transaction, crash, disconnect, or scheduler action.
* `transport` injects a precisely located delivery failure.
* `expect` gives assertions immediately after that step.
* `final` and `final_assertions` give terminal durable-state assertions.

Object-member order in scenario frames is not significant. Sequence, frame
direction, connection authority, and transaction boundaries are significant.
Tests must not skip an assertion merely because the implementation combines
multiple local transactions more conservatively.

The scenarios cover normal resume and lost ACK, definitive retention spans,
sequenced suspected capture gaps, invalid ACKs, generation transition and
rollback, strict supersession, active chunks and stale fetch responses,
pending-pair retry, peer-cursor regression, multi-Mac retention isolation,
connected unpair, both offline-unpair directions, and an idempotent lost
unpair ACK.

## OTP Corpus

Each YAML file in `otp-corpus/` has format `eko-otp-corpus-v1`. All cases are
synthetic clean-room Eko fixtures and are released as CC0-1.0.

Cases are isolated. Within one case, `events` are ordered committed events for
one device. Omitted scalar notification fields are null, omitted arrays are
empty, and omitted `is_group_summary` is false. If `device_id` is omitted, the
harness uses a value unique to that case. If `at_ms` is omitted, events are one
second apart in listed order.

Recognized input keys are:

```
title text big_text sub_text info_text summary_text text_lines messages
is_group_summary notification_key at_ms
```

`title` is present in the format specifically to verify that the extractor
never searches it. A message object has `sender`, `text`, and `ts`.

Every event has an `expected` object:

* `code`: exact normalized code string, or null;
* `tier`: `origin_bound`, `heuristic`, or `none`;
* `banner`: whether this event fires a code banner after cross-key/device/time
  dedupe;
* `panel`: whether the event exposes the Copy-code affordance in history;
* `auto_copy_allowed`: policy eligibility, not the user's opt-in setting.

Heuristic digit groups separated by spaces or hyphens normalize to contiguous
ASCII digits. Arabic-Indic and Persian digits normalize to ASCII. An internal
hyphen in an alphanumeric token is preserved. Origin-bound `#` tokens are
returned verbatim. A group-summary event always has no code. Dedupe suppresses
only `banner`; it never removes a detected code from `panel`. Banking/TAN cases
are never eligible for auto-copy.

The corpus contains English, German, Swiss German/French/Italian/Rumantsch
cases, broader multilingual scripts, adversarial false positives, origin-bound
forms, Google `G-` and bracket artifacts, SMS Retriever prefix/hash handling,
grouped digits, Unicode digit normalization, group summaries, cross-key
dedupe, resend timing, and intermediate notification updates.

## Basic Data Validation

From the repository root, JSON syntax can be checked with:

```sh
jq empty protocol/schemas/*.json protocol/test-vectors/*.json protocol/test-vectors/scenarios/*.json
```

YAML should be loaded with duplicate-key rejection enabled. JSON Schema
validation must preload the local schema registry as described above and then
validate every complete frame object embedded in scenario files, not only
standalone examples.

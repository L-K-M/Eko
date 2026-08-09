# Eko

**Android notifications on your Mac.** A macOS menubar app plus an Android companion:
your phones forward their notifications over the local Wi-Fi network, the Mac shows them
live, and 2FA/OTP messages get a one-click **Copy code** action.

[![CI](https://github.com/L-K-M/Eko/actions/workflows/ci.yml/badge.svg)](https://github.com/L-K-M/Eko/actions/workflows/ci.yml)

**Source version:** v<!-- version -->1.0.0<!-- /version --> · [Latest release](https://github.com/L-K-M/Eko/releases/latest)

> [!IMPORTANT]
> LLM Disclosure: Eko is being built with substantial help from large language models,
> with agent guidance kept in [`AGENTS.md`](AGENTS.md).

> [!NOTE]
> **Status: implemented, not yet released.** Both apps, the shared protocol artifacts
> and the reference harness are in the tree and under CI; no signing keys are configured
> yet, so nothing is published. [`PLAN.md`](PLAN.md) remains the source of truth for
> scope and protocol semantics, [`CICD.md`](CICD.md) covers building and releasing, and
> [`docs/`](docs/README.md) holds the operational guides.

---

## What makes it different

Two hard requirements drive the design, and both are things comparable tools get wrong:

**Nothing is lost.** When a phone drops off the network — Wi-Fi loss, Doze, process death,
Mac asleep — every notification it missed is recovered on reconnect. KDE Connect has no
store-and-forward at all: on reconnect the desktop asks for the notifications still sitting
in the status bar, so anything posted *and dismissed* while the desktop was offline —
exactly the lifecycle of an OTP — is gone. Pushbullet's mirroring is explicitly ephemeral;
Join rides on FCM, which drops its whole offline queue past 100 messages.

Eko instead persists every notification event to a durable phone-side outbox *at post time,
before any send attempt*, with a per-device sequence number, and replays from each Mac's
last-acknowledged cursor. Android killing the app costs the connection, never the data.
Retention is bounded (48 h / 2'000 events per Mac) and exceeding it shows an honest **gap**
indicator rather than a silent hole — as does a *capture* gap, the window where the
listener itself was dead and the OS never delivered the events at all.

**OTPs actually arrive.** Since Android 15, notifications classified as containing 2FA
codes have their text replaced with "Sensitive notification content hidden" for ordinary
notification listeners. This is what broke Microsoft Phone Link's OTP mirroring. Eko gets
the real text by holding a CompanionDeviceManager association — which any third-party app
can create, and which AOSP's trust check accepts — established per paired Mac during
onboarding.

**Multiple phones per Mac**, each independently paired, connected and recoverable. Each is
its own unit on the Mac: own pinned certificate, session, cursor, backlog and UI section.

## How it works

The phone is the TCP/TLS client and the Mac the server — Android can't hold a listening
socket in the background, and macOS doesn't gate incoming TCP. Transport is TLS 1.3 with
mutual authentication over length-prefixed frames. Identity is a per-device self-signed
P-256 certificate pinned on first use, verified at pairing by a commit-then-reveal short
code so the code can't be ground down by an attacker in the middle. Discovery (mDNS, UDP
announce, last-known IP, QR) is only ever a *hint*: trust comes from the certificate the
TLS handshake authenticated, never from what discovery claimed.

[`PLAN.md`](PLAN.md) has the full architecture, the wire protocol, the failure-mode matrix,
and the primary sources behind every constraint above.

## Privacy

Notification contents and OTPs stay on your own paired devices and travel only over
mutually authenticated, encrypted connections on your own network. There is no Eko account,
no backend, and no analytics. v1 is LAN-only. See [`SECURITY.md`](SECURITY.md) for the
security baseline and how to report a vulnerability.

## Building

```sh
scripts/build.sh            # every artifact this host can build, staged into dist/
scripts/build.sh --check    # what it would build, without building it
scripts/install-debug.sh    # debug APK onto a phone connected over adb
```

Each tree also has its own documented commands — `android/` via Gradle, [`macos/`](macos/README.md)
via `Scripts/verify-macos.sh`, [`tools/`](tools/README.md) via `unittest` and the chaos
harness. CI runs exactly those, so a green local run means a green CI run; see
[`CICD.md`](CICD.md).

## Distribution

- **macOS** — Developer ID signed and notarized, sandboxed from day one.
- **Android** — sideload only, via GitHub Releases (and Obtainium). Not on Google Play, by
  design: sideloading frees the design from store policy, and CompanionDeviceManager is the
  friction-free path to unredacted OTPs either way.

Neither platform's signing secrets are configured yet. Until they are, a tag still produces
a release — an ad-hoc signed `.app` that Gatekeeper warns about, and an APK that is unsigned
and therefore not installable. [`CICD.md`](CICD.md) lists the secrets that turn each into the
real thing; the Android one matters most, because the signing certificate is also the upgrade
identity.

## Repository automation

- [`ci.yml`](.github/workflows/ci.yml) — on every PR and push to `main`: the protocol
  artifacts, the Python reference model and chaos harness, the Android build/lint/tests, and
  the macOS verification gate.
- [`release.yml`](.github/workflows/release.yml) — on a `v*` tag: re-proves the tagged
  commit, checks the tag against both committed versions, builds and signs both artifacts,
  and publishes them with SHA-256 sums.
- [`zai-code-review.yml`](.github/workflows/zai-code-review.yml) — GLM 5.2 reviews
  non-draft pull requests from this repository when `ZAI_API_KEY` is set. It deliberately
  skips fork pull requests: `pull_request_target` has access to repository secrets.
- Dependabot — weekly `github-actions`, `gradle` and `swift` updates.
- [`CLAUDE.md`](CLAUDE.md) — the shared pull-request review policy used across these repos.

## Documentation

| File | What it holds |
| --- | --- |
| [`PLAN.md`](PLAN.md) | The technical plan — architecture, protocol, security, roadmap, sources |
| [`AGENTS.md`](AGENTS.md) | Contributor/agent notes: build commands, architecture invariants, verification |
| [`CICD.md`](CICD.md) | The build/test/release pipeline and the secrets it expects |
| [`protocol/README.md`](protocol/README.md) | The wire spec and the schemas, vectors and OTP corpus both apps consume |
| [`docs/README.md`](docs/README.md) | Operational guides: install/pair, diagnostics, manual QA, release checklists |
| [`SECURITY.md`](SECURITY.md) | Security policy, scope, and vulnerability reporting |

## License

Public domain (Unlicense) — see [`LICENSE`](LICENSE).
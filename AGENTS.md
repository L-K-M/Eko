# Eko agent and contributor notes

Eko mirrors notifications from Android phones to a native macOS menubar app.
Read [PLAN.md](PLAN.md) before changing architecture or product behavior; it is
the current source of truth for scope, protocol semantics, and security.
[README.md](README.md) is the product-level summary; [CICD.md](CICD.md) covers
build, test and release automation; [docs/](docs/README.md) holds the
operational guides and release checklists.

## Current status

- Both apps are implemented and under CI. No signing keys are configured, so
  nothing is published yet — a tag still produces a release, but an unsigned
  one. See [CICD.md](CICD.md).
- The monorepo layout is `android/` (Gradle, six modules), `macos/` (SwiftPM
  package + XcodeGen app), `protocol/` (schemas, vectors, OTP corpus),
  `docs/`, `tools/` (dependency-free Python reference model), and `scripts/`.
- Do not add placeholder CI that cannot pass. A new CI job lands with the
  reproducible local command it runs, not before it.

## Build and verify

```sh
scripts/build.sh                                      # every artifact this host can build -> dist/
scripts/build.sh --check                              # the plan, without building
scripts/install-debug.sh                              # debug APK onto a connected phone

python3 scripts/check-protocol.py                     # schemas, vectors, corpus (needs jsonschema + PyYAML)
python3 -m unittest discover -s tools/tests -v        # reference model
(cd android && ./gradlew testDebugUnitTest lintDebug assembleDebug)
(cd macos && ./Scripts/verify-macos.sh)               # macOS only; generate, lint, swift test, xcodebuild test
```

Those four verification commands are exactly what `.github/workflows/ci.yml`
runs, so a green local run means a green CI run. Run the ones your change
touches; run the protocol checker whenever anything under `protocol/` moves,
because both apps consume those files.

Releases are cut with `scripts/release.sh X.Y.Z --push`, which moves the version
in lockstep across `android/app/build.gradle.kts` and `macos/project.yml`, bumps
both build numbers, updates the README marker, commits and tags. Never bump
either version file by hand and never create a `v*` tag by hand: `release.yml`
refuses a tag that disagrees with either file.

## Architecture invariants

- Android captures each notification durably before attempting delivery.
- Resume ordering uses the per-device sequence and Mac cursor, never wall time.
- An acknowledgement is sent only after the event and cursor transaction has
  committed on the Mac.
- Device identity comes from the certificate authenticated by TLS. Discovery
  metadata is only a hint and never establishes trust.
- Paired traffic uses mutual TLS with pinned identities. Do not add a cleartext
  or trust-all mode outside the explicitly bounded first-pairing flow.
- Notification text, OTPs, pairing material, certificates, and diagnostics are
  sensitive. Never log or commit real examples.
- Android is sideload-only; release APKs must be signed with Eko's unique key.

## Verification notes

- Android: wrapper validation runs in CI before anything executes the wrapper.
  The instrumented tests are not a CI job — `DurabilityInstrumentedTest` is
  about Room surviving process death, which an emulator models only partially;
  it stays in `docs/manual-qa.md` and the hardware spikes.
- macOS: `Scripts/verify-macos.sh` is the whole gate. Notification delivery,
  Local Network attribution, Keychain identities, launch at login and Bluetooth
  advertising need a *signed* build, so they are checklist items, not tests.
- Protocol: `scripts/check-protocol.py` validates every embedded scenario frame
  against `frame.schema.json`, which is what makes "both implementations consume
  the same vectors" enforceable rather than aspirational.
- Releases: re-run tests, verify the tag matches *both* committed versions, sign
  and verify artifacts, and publish SHA-256 checksums. The release workflow signs
  each platform when that platform's secrets are configured and falls back when
  they are not — configure the Android keystore before the first public release:
  the signing certificate is the upgrade identity, and an APK signed with
  anything else can never update an installed Eko.

## Repository automation

- `.github/workflows/zai-code-review.yml` reviews same-repository, non-draft
  pull requests when `ZAI_API_KEY` is configured. It intentionally does not run
  for fork pull requests because `pull_request_target` has access to secrets.
- Dependabot covers GitHub Actions, Gradle (`/android`) and Swift (`/macos`).
  `macos/project.yml` pins GRDB and Yams a second time for XcodeGen and
  Dependabot cannot see it — move those `exactVersion:` values with any
  `Package.swift` bump.
- `.github/workflows/ci.yml` proves all four trees on every PR and push to
  `main`, and `release.yml` calls it via `workflow_call` to re-prove a tagged
  commit before publishing. [CICD.md](CICD.md) documents both, the local
  equivalent of each job, the secrets they expect, and what a release does when
  those secrets are absent.
- Also in the Actions permission model: every workflow keeps `contents: read`
  except the release jobs that create the Release, cancels superseded PR runs
  but never an in-progress `main` run, and sets `timeout-minutes` on every job.
- `CLAUDE.md` carries the shared pull-request review policy used across these
  repos.

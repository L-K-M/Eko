# Eko agent and contributor notes

Eko mirrors notifications from Android phones to a native macOS menubar app.
Read [PLAN.md](PLAN.md) before changing architecture or product behavior; it is
the current source of truth for scope, protocol semantics, security, and the
planned repository layout. [README.md](README.md) is the product-level summary;
[CICD.md](CICD.md) covers build, test and release automation.

## Current status

- The repository is in the pre-scaffold/M0 phase. The Android and macOS
  projects do not exist yet, so there are no valid build, test, or release
  commands.
- The planned monorepo layout is `android/`, `macos/`, `protocol/`, `docs/`,
  and `tools/`.
- Do not add placeholder CI that cannot pass. Add target-specific CI when the
  corresponding project and reproducible local command exist.

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

## Planned verification

Once the projects exist, every change should run the relevant local equivalent
of the CI gate:

- Android: wrapper validation in CI, JVM tests, Android lint, and debug assembly
  from `android/`.
- macOS: Swift/unit tests and a signed development build on a macOS runner.
- Protocol: both implementations consume the same schemas, fixtures, and test
  vectors under `protocol/`.
- Releases: rerun tests, verify the tag matches the committed version, sign and
  verify artifacts, and publish SHA-256 checksums. Never publish unsigned APKs.

## Repository automation

- `.github/workflows/zai-code-review.yml` reviews same-repository, non-draft
  pull requests when `ZAI_API_KEY` is configured. It intentionally does not run
  for fork pull requests because `pull_request_target` has access to secrets.
- Dependabot currently covers GitHub Actions only. Add a Gradle updater with
  `directory: /android` after the Gradle root exists.
- Add `ci.yml`, `release.yml`, and local build/install/release scripts only
  after their real commands, artifact paths, application ID, version source,
  and signing model are established. [CICD.md](CICD.md) is the blueprint for
  each of those — the trigger that makes it addable, the family conventions it
  must follow, and the config to use — so landing them is mechanical rather
  than a fresh design.
- `CLAUDE.md` carries the shared pull-request review policy used across these
  repos.

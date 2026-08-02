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
  package + XcodeGen app), `server/` (Rust relay, proposed - see
  `docs/relay/ARCHITECTURE.md`), `protocol/` (schemas, vectors, OTP corpus),
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
(cd android && ./gradlew :core:test testDebugUnitTest lintDebug assembleDebug)
(cd macos && ./Scripts/verify-macos.sh)               # macOS only; generate, lint, swift test, xcodebuild test
(cd server && cargo fmt --check && cargo clippy --all-targets --locked -- -D warnings && cargo test --locked)
```

Those five verification commands are exactly what `.github/workflows/ci.yml`
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
- The shared rules below govern the pull-request review cycle.

<!-- shared-rules:start -->

## Working practices

- Follow explicit task instructions over the default workflow below.
- Before editing, inspect the branch and working tree, fetch remote updates,
  and fast-forward where safe. Never overwrite existing work to update.
- Resolve ambiguity before making consequential changes. State low-risk
  assumptions; ask when scope, safety, or expected behavior is unclear.
- Keep changes focused. Do not modify unrelated code, formatting, or comments.
- Prefer surgical edits over whole-file rewrites when the result is equivalent.
- Stage only intended files. Inspect the diff before committing.

## Communication

- Be concise, factual, and direct. Preserve necessary context and uncertainty.
- Avoid praise, motivational filler, emojis, and em dashes in new prose.
- Address the reader directly in user-facing copy.
- Report what was verified and what remains unverified. Never imply that an
  unavailable check passed.

## Code design

- Prefer early returns and shallow nesting. Separate logical blocks with
  blank lines.
- Use descriptive constants or enums for meaningful or repeated values.
  Use existing standard definitions for protocol/specification constants.
  Keep obvious, one-off values inline.
- Use enums for behavioral modes that would otherwise require ambiguous
  boolean arguments.
- Default members to private. Widen visibility only for required consumers,
  and review the change as an API design decision.
- Follow the repository's declared dependency boundaries. UI and controllers
  must use application services rather than directly accessing databases,
  subprocesses, sockets, or other low-level mechanisms.
- Encapsulate low-level mechanics behind domain-oriented interfaces.
- Reuse genuinely shared logic. Avoid speculative abstractions and layers
  that only forward calls.
- Prefer pure functions for business rules and immutable data where practical.
  Isolate side effects; document non-obvious state ownership or synchronization.
- Explain non-obvious intent, constraints, and tradeoffs in comments.
  Do not narrate obvious code. Add examples or diagrams when they clarify it.

## Validation and errors

- Validate untrusted input at entry points. Where practical, represent valid
  states in types and enforce persistent invariants in database schemas.
- Represent absence and failure explicitly.
- Use assertions for internal programming invariants, not external-input
  validation or required runtime error handling.
- Prefer explicit, actionable errors over silent failure or undocumented
  fallback. Document intentional recovery behavior.
- Never report a skipped or failed operation as successful.

## Bug fixes

1. Identify the root cause and define an observable success criterion.
2. Add a regression test and observe the relevant failure before fixing it.
3. Implement the fix and observe the test passing.
4. Check surrounding behavior for regressions and architectural consistency.

If an automated regression test is impractical, document the reproduction
and verification procedure. State any inability to reproduce the failure.

## Verification

- Run relevant tests and lint after changes.
- Choose coverage by affected behavior and risk, not patch size.
- Use integration or end-to-end tests for critical workflows and boundaries;
  test isolated business rules at the lowest effective level.
- Run broader suites for cross-cutting or high-risk changes, and the full
  required release checks before releasing.
- Validate the requested command, options, platform, and configuration.
  Unrelated green CI is not proof that the reported problem is fixed.
- Recheck after the final edit. Distinguish local checks from CI results.

## Commit messages

- Use a capitalized, imperative subject without a final period.
- Target 50 characters; never exceed 72.
- Separate the subject and body with one blank line.
- Wrap body text at 72 characters.
- Explain what changed and why. Leave implementation mechanics to the code.

## Implementation and review

Unless explicitly instructed otherwise:

1. Work on a focused branch and open a PR against main.
2. Inspect CI results and completed review feedback for the latest commit.
   A successful reviewer job does not mean the review found no problems.
3. Address important findings or explain why they do not apply. Handle minor
   findings according to the stopping rules below.
4. Evaluate each fix in the surrounding project, add regression coverage,
   and rerun affected checks before pushing.
5. Repeat until a stopping criterion is met.
6. Merge without asking again once the stopping criterion is met, required
   checks pass on the latest commit, and no unresolved blockers or required
   human review requests remain.

### Automated review stopping rules

Judge findings by verified impact, not the reviewer's severity label.
Important findings concern correctness, security, data loss, broken builds,
or materially degraded behavior/performance.

Track completed review rounds and consecutive rounds without important
findings. Reruns of the same revision and integration failures do not count.

- No applicable actionable feedback: finish immediately.
- First minor-only round: optionally fix worthwhile, low-risk findings.
  Do not manufacture another push merely to obtain another review.
- Two consecutive rounds without important findings: stop responding to
  automated nitpicks, even if actionable minor suggestions remain.
  Defer worthwhile leftovers rather than continuing the cycle.
- A confirmed important finding resets the minor-only streak. Address it
  and verify the fix before continuing.

After ten completed rounds, enter stabilization:

- Stop optional cleanup, refactoring, and nitpick fixes.
- One completed review without confirmed important findings is sufficient
  to finish, even if minor suggestions remain.
- Continue only for confirmed important defects. If resolving them stalls,
  report the blockers rather than continuing indefinitely.

These limits end optional automated-feedback work. They do not waive
confirmed blockers, unresolved human review requests, or required checks.

### Reviewer integration failures

After two consecutive reviewer-integration failures, stop and report the
review gap. Do not treat failures as approval. An explicit user instruction
may waive review; report that waiver rather than claiming review passed.

## Completion checklist

- The requested behavior is implemented without unrelated changes.
- Relevant checks pass for the latest code.
- Important review findings are addressed or rejected with reasons.
- Deferred suggestions, remaining risks, and validation gaps are disclosed.
- The final response accurately states whether work is committed, pushed,
  and merged.

<!-- shared-rules:end -->

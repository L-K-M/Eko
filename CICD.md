# CI/CD

Eko is a two-platform monorepo: an Android app under `android/`, a macOS menu-bar app under
`macos/`, the schemas/vectors/corpus both consume under `protocol/`, and a dependency-free
Python reference model under `tools/`. CI proves all four on every change; the release
workflow re-proves a tagged commit, builds and signs both apps, and publishes them with
SHA-256 sums to a GitHub Release.

The conventions here are the ones the sibling repos share — the canonical description lives
in the `lkm-project-conventions` skill in
[release-tool](https://github.com/L-K-M/release-tool); Blipbird is the closest Android model
and Shortking the closest macOS one.

## Workflows

| Workflow | Trigger | Purpose |
| --- | --- | --- |
| [`ci.yml`](.github/workflows/ci.yml) | PRs, pushes to `main`, manual dispatch, and `workflow_call` | Protocol artifacts, reference model, relay server, Android, macOS. |
| [`release.yml`](.github/workflows/release.yml) | Pushing a `v*` tag (e.g. `v1.2.0`) | Re-prove, version-gate, build, sign, publish. |
| [`zai-code-review.yml`](.github/workflows/zai-code-review.yml) | Non-draft PRs from this repository | GLM 5.2 review when `ZAI_API_KEY` is configured. |

`zai-code-review.yml` runs on `pull_request_target`, which hands repository secrets and a
write-capable token to a workflow triggered by a pull request — so the job is guarded on
`github.event.pull_request.head.repo.full_name == github.repository` and never runs for
forks, and the action is pinned to an immutable commit rather than a moving branch. It
no-ops cleanly when `ZAI_API_KEY` is unset.

Every workflow carries the **hardening trio**: least-privilege `permissions: contents:
read` (`write` only where a job creates the Release); `concurrency` keyed on the ref with
`cancel-in-progress` gated on `github.event_name == 'pull_request'`, so a superseded PR run
is cancelled but an in-progress `main` run never is — a permanently "cancelled" main commit
masks breakage and puts holes in CI-status bisection; and a `timeout-minutes` on every job,
so a wedged Gradle daemon or Swift build service can't burn the 6-hour default.

Dependabot covers **GitHub Actions**, **Gradle** (`/android`) and **Swift** (`/macos`),
weekly. Major-version bumps of `gradle/actions` are ignored deliberately: v6 relicensed its
caching component to a proprietary commercial ToU, so the family stays on the fully open v5
while still taking its minor and patch updates. One gap Dependabot cannot see:
`macos/project.yml` pins GRDB and Yams a second time for the XcodeGen spec — when a bump
lands in `macos/Package.swift`, move the matching `exactVersion:` with it, or the generated
project and the package disagree.

## Continuous integration (`ci.yml`)

Five independent jobs, listed here the way a failure should be read rather than the way they
are scheduled.

### `protocol` — the shared artifacts (ubuntu, ~1 min)

`python3 scripts/check-protocol.py`, with `jsonschema` and `PyYAML` installed for the job
only (`tools/` itself stays stdlib-only). It checks, in the order `protocol/README.md`
describes them:

1. Every JSON file parses **with duplicate object members rejected**. `jq empty` accepts a
   duplicate key and keeps the last one; a hand-edited vector that grew a second `seq` would
   then mean different things to different parsers.
2. Every file in `schemas/` is a valid JSON Schema Draft 2020-12 document.
3. The local schema registry resolves offline: every `$ref` in the twenty message schemas
   and in `frame.schema.json`'s union is retrievable by `$id` without touching the network.
   The `https://eko.local/` identifier space does not resolve, by design.
4. **Every complete frame embedded in a scenario validates against `frame.schema.json`** —
   100 of them today. This is the check that makes "both implementations consume the same
   vectors" enforceable rather than aspirational. On failure the frame is re-validated
   against the single branch its own `type` names, so the error points at the field
   (`$.steps[0].frame (hello) proto_max: 1 was expected`) instead of at "not valid under any
   of the given schemas".
5. Every OTP corpus file loads as YAML with duplicate keys rejected and declares
   `eko-otp-corpus-v1`.
6. Everything outside `otp-corpus/` is ASCII. Unicode belongs only in corpus message strings
   whose purpose is to test Unicode or a non-English language; a smart quote in a schema is a
   copy-paste artifact.

**Why this job matters first:** the Kotlin and Swift suites both read these files. A
malformed schema surfaces as two unrelated-looking platform failures — or, worse, as a
vector one side silently skips.


### `server` — the relay (ubuntu, ~3 min)

`cargo fmt --check`, `cargo clippy --all-targets --locked -- -D warnings`, and
`cargo test --locked`, all in `server/`, on a pinned 1.90 toolchain with the registry
cached between runs. The three commands are exactly the ones `server/README.md` gives a
developer, so a green local run means a green job.

`--locked` on both clippy and test is deliberate: the relay is the only component that
faces the internet, and a job that silently accepted an updated transitive dependency
would defeat the point of committing `Cargo.lock`.

The suite is 3 unit tests and 13 integration tests, the latter driving the real axum
router rather than a mock, so the authorization rules — cross-account isolation, immediate
revocation, single-use nonces, device-scoped queues — are exercised over real HTTP.
The container image is *not* built in CI; it is a thin wrapper over the same binary and
building it would add several minutes for little signal.

### `tools` — reference model and chaos (ubuntu, ~1 min)

`python3 -m unittest discover -s tools/tests -v`, then a **fixed** chaos seed range
(`--seed 20260724 --runs 100 --steps 2000 --pairings 4`) and both framed-loopback
simulations. The range is deliberately fixed rather than randomized per run: a seed is a
replay recipe, and a CI failure is only actionable if the same command reproduces it.
Widening it is a deliberate commit.

### `android` — build, lint, unit tests (ubuntu)

`gradle/actions/wrapper-validation` **first**, as a supply-chain gate against a tampered
`gradle-wrapper.jar`, before anything executes the wrapper. Then Temurin JDK 17,
`gradle/actions/setup-gradle` rooted at `android/`, and `./gradlew :core:test
testDebugUnitTest lintDebug assembleDebug`. The debug APK is uploaded as a 14-day artifact.

The instrumented tests under `androidTest/` are **not** here. `DurabilityInstrumentedTest`
is about Room surviving process death and power loss, which an emulator models only
partially; it stays in the manual matrix ([`docs/manual-qa.md`](docs/manual-qa.md)) and the
hardware spikes until there is a reason to trust an emulator run of it. Blipbird's
`instrumentation` job is the template if that changes.

### `macos` — the repo's own verification gate (macos-15)

Xcode pinned to **16.3** via `maxim-lobanov/setup-xcode`, `brew install xcodegen`, then
`macos/Scripts/verify-macos.sh` — unmodified. That script regenerates the project from
`project.yml`, lints `Info.plist` and the entitlements with `plutil`, runs the package tests
with `swift test`, then the app-hosted project tests with `xcodebuild test`. Running the
documented local command rather than a CI-only reimplementation is the point: the two can't
drift.

Xcode 16.3 is not arbitrary — `macos/Package.swift` declares `swift-tools-version: 6.1` and
`macos/project.yml` declares `xcodeVersion: "16.3"`. Bump all three together.

### Running CI locally

```sh
python3 scripts/check-protocol.py                     # needs jsonschema + PyYAML
python3 -m unittest discover -s tools/tests -v
(cd android && ./gradlew :core:test testDebugUnitTest lintDebug assembleDebug)
(cd macos && ./Scripts/verify-macos.sh)               # macOS only
```

`scripts/build.sh` is the friendlier local wrapper around the two build steps: it builds
every artifact this host can build, stages each into `dist/`, and prints one summary. A
target that can't build here (no Android SDK, not macOS) is *skipped* on a default run and
*fails* when named explicitly — so `scripts/build.sh` is safe to run anywhere and
`scripts/build.sh apk` still tells you your toolchain is missing. `--check` prints the plan
without building.

## Releases (`release.yml`)

Cut a release with the helper:

```sh
scripts/release.sh 1.2.3 --push
```

Eko has **two** version sources that must agree:

| File | Fields |
| --- | --- |
| `android/app/build.gradle.kts` | `versionName`, `versionCode` |
| `macos/project.yml` | `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` |

No single `lkm-release` engine kind bumps both, which is why `scripts/release.sh` is a
bespoke script rather than the usual ~25-line stub over the shared engine. The rule the
engine exists to enforce is unchanged: **one** command moves everything and creates the tag.
It bumps both marketing versions, auto-increments both build numbers and keeps them equal to
each other (so one number identifies a build across both platforms in the release record),
updates the README `<!-- version -->` marker, commits, tags `vX.Y.Z`, and with `--push`
pushes branch + tag. `--dry-run` prints every edit and writes nothing. It refuses to run on
a dirty tree, refuses a tag that already exists, refuses to proceed when the two version
files already disagree, and restores every edited file if any single edit fails — a
half-applied bump can never be committed.

The tag push then triggers four jobs:

**1. `ci`** — calls `ci.yml` in full via `workflow_call`. A `v*` tag can land on any commit,
including one CI never saw, and for a sideloaded app the release feed *is* the update
channel: a broken release is a broken updater, not just a bad download.

**2. `version`** — asserts the tag matches both committed versions, and fails with the
mismatch spelled out. Two version files means two ways to ship a release named `v1.5.0`
containing something else. The read patterns are the tolerant ones `scripts/release.sh` can
produce, so a valid bump can never fail the release it just cut.

**3. `android`** — assembles the release APK, then:

| Signing secrets | What happens |
| --- | --- |
| All four set | `zipalign` + `apksigner sign`, then `apksigner verify --print-certs` — the certificate digest goes into the log for comparison against the release record. |
| None set | Attaches `eko-<version>-unsigned.apk` with a `::warning::`. |
| Some set | Fails with the list of missing ones. |

**4. `macos`** — archives the Release configuration, then:

| Signing secrets | What happens |
| --- | --- |
| All seven set | `xcodebuild -exportArchive` with `method: developer-id`, then notarize, staple, and verify with `stapler validate` and `spctl --assess`. |
| None set | Ad-hoc signs the archived app inside-out, with the same hardened runtime and entitlements the Release configuration applies. |
| Some set | Fails with the list of missing ones. |

`-exportArchive` is used rather than `codesign --deep` because
[`docs/release-checklists.md`](docs/release-checklists.md) requires inside-out signing —
every nested framework signed by the expected Team ID *before* the outer bundle — which is
exactly what `--deep` does not do. The ad-hoc fallback signs nested code first by hand for
the same reason.

Both jobs attach to the same tag's release and append their own notes section. A tag
containing a hyphen (`v1.3.0-rc.1`) is published as a pre-release. Checksums are computed
**after** stapling, because stapling changes bytes.

### About the fallbacks

The partial-configuration failure is not a policy, it is a typo guard: half a keystore
configuration is a misspelled secret name, not a decision to publish something nobody can
install.

The two unsigned fallbacks are **not** equivalent, and the release notes say so per
artifact:

- An **ad-hoc signed `.app`** is usable. Gatekeeper warns, and the right-click-Open or
  `xattr -dr com.apple.quarantine` workaround gets past it. What is lost is identity
  continuity: an ad-hoc cdhash is stable within one artifact, so grants survive for that
  copy, but every release is a different app to TCC and notification/Local Network/Bluetooth
  consent is re-asked on each update.
- An **unsigned APK** is not usable at all. Android rejects an APK with no signature, and
  signing it yourself produces an app no official release can ever update — on Android the
  signing certificate *is* the upgrade identity. It is attached as a reproducible build
  artifact, not as a download.

That asymmetry is the argument for configuring the Android secrets before the first public
release, and for configuring them first.

### Why signing is worth configuring at all

Beyond Gatekeeper: `macos/Scripts/verify-macos.sh` proves the app builds and its tests pass,
but notification delivery, Local Network privacy attribution, Keychain identities, launch at
login and Bluetooth advertising all behave differently under a real signature.
[`docs/release-checklists.md`](docs/release-checklists.md) is the manual gate for those, and
it assumes signed artifacts throughout.

## Secrets

`ci.yml` needs none. `release.yml` takes the signed path per platform when that platform's
secrets are all set, and the fallback path when none of them are.

### Android

| Secret | What it is |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | The release keystore, base64-encoded (`base64 < release.jks \| tr -d '\n'`) |
| `ANDROID_KEYSTORE_PASSWORD` | Keystore password |
| `ANDROID_KEY_ALIAS` | Key alias inside the keystore |
| `ANDROID_KEY_PASSWORD` | Key password |

### macOS

| Secret | What it is |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Developer ID Application certificate + private key, exported as `.p12` and base64-encoded |
| `DEVELOPER_ID_P12_PASSWORD` | The password set when exporting the `.p12` |
| `KEYCHAIN_PASSWORD` | Any random string; protects the temporary keychain for the length of the run |
| `APPLE_TEAM_ID` | The 10-character Apple Developer team identifier |
| `AC_API_KEY_BASE64` | App Store Connect API key (`AuthKey_XXXX.p8`), base64-encoded |
| `AC_API_KEY_ID` | The key's ID (the `XXXX` in the filename) |
| `AC_API_ISSUER_ID` | The issuer UUID from App Store Connect → Users and Access → Integrations |

`zai-code-review.yml` uses `ZAI_API_KEY` and skips itself cleanly when it is unset.

Base64 secrets are decoded through `tr -d ' \t\r\n'` first, so a 76-column wrapped paste or
a stray carriage return doesn't fail the release — only genuinely invalid base64 does. Create
them with `base64 < file | tr -d '\n'`: `-w0` is GNU-only and errors out on macOS's BSD
`base64`, which is where these secrets actually get made.

The release keystore is a product identity and a recovery asset, not just a credential.
[`docs/release-checklists.md`](docs/release-checklists.md) has the custody rules, and they
are not optional: a casual key rotation forces uninstall/reinstall and destroys outbox data,
grants, associations and pairings.

## Troubleshooting

- **`Android signing is partially configured` / `macOS signing is partially configured`** —
  some of that platform's secrets are set and some aren't, which is almost always a
  misspelled secret name. Set the missing ones, or clear the rest to take the fallback path
  deliberately, then re-push the tag.
- **A release published unsigned when you expected it signed** — the workflow logs a
  `::warning::` in the "Resolve the signing path" step. Repository secrets aren't available
  to runs triggered from a fork, and environment-scoped secrets aren't visible to a job with
  no `environment:`; check where the secrets live.
- **`Tag vX.Y.Z does not match versionName` / `MARKETING_VERSION`** — the tag was created by
  hand, or only one of the two files was bumped. Delete the tag and re-cut with
  `scripts/release.sh`.
- **`committed versions disagree`** from `scripts/release.sh` — the two version files were
  edited separately at some point. Fix them by hand so they agree, then re-run.
- **`No 'Developer ID Application' identity found`** — the `.p12` holds an *Apple
  Development* certificate, which cannot be notarized. Export a Developer ID Application
  certificate instead.
- **Notarization rejected** — `xcrun notarytool log <submission-id> --keychain-profile
  eko-notary` gives the per-binary reason. Usually a nested binary missing the hardened
  runtime or a secure timestamp.
- **`$.steps[N].frame (type) field: message`** from the protocol job — a scenario vector no
  longer matches its schema. Fix the vector or the schema, not the checker: both apps read
  these files.

## One Eko-specific caution

[`PLAN.md`](PLAN.md) §15's soak rig, device matrix and permission-grant QA are **not** CI
jobs and should not be forced into one: they need real phones, a Wi-Fi AP that can be
toggled, and system dialogs that only reset via VM snapshots. CI covers unit tests, lint,
protocol conformance against the shared vectors, the OTP corpus, and the simulator
harnesses. The rest stays a documented manual script —
[`docs/manual-qa.md`](docs/manual-qa.md),
[`docs/hardware-spikes.md`](docs/hardware-spikes.md) and
[`docs/release-checklists.md`](docs/release-checklists.md).

Notification text, OTPs, pairing material, certificates and diagnostics are sensitive. No
workflow, fixture or test vector may contain a real example — this applies to CI logs and
uploaded artifacts as much as to committed files.

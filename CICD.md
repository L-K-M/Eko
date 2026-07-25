# CI/CD

Eko is in the **pre-scaffold (M0)** phase. The `android/`, `macos/`, `protocol/`, `docs/`
and `tools/` trees described in [PLAN.md](PLAN.md) §15 do not exist yet, so there are no
build, test or release commands to run — and therefore no `ci.yml`, no `release.yml` and no
`scripts/`.

That absence is deliberate, and [AGENTS.md](AGENTS.md) states the rule: *do not add
placeholder CI that cannot pass.* A workflow that reports red on every pull request from
the day it lands teaches everyone to ignore the red, and a `scripts/build.sh` that has
nothing to build is worse than no script at all.

This file is the blueprint, so that adding each piece is a mechanical step at the moment it
becomes real rather than a design exercise. The conventions below are the ones the sibling
repos share — the canonical description lives in the `lkm-project-conventions` skill in
[release-tool](https://github.com/L-K-M/release-tool); Blipbird is the closest Android
model and Shortking the closest macOS one.

## What is wired up today

| Workflow | Trigger | Purpose |
| --- | --- | --- |
| [`zai-code-review.yml`](.github/workflows/zai-code-review.yml) | Non-draft PRs from this repository | GLM 5.2 review when `ZAI_API_KEY` is configured. |

It runs on `pull_request_target`, which hands repository secrets and a write-capable token
to a workflow triggered by a pull request — so the job is guarded on
`github.event.pull_request.head.repo.full_name == github.repository` and never runs for
forks, and the action is pinned to an immutable commit rather than a moving branch. The job
no-ops cleanly when `ZAI_API_KEY` is unset.

Dependabot currently covers **GitHub Actions only**, weekly. Major-version bumps of
`gradle/actions` are ignored deliberately: v6 relicensed its caching component to a
proprietary commercial ToU, so the family stays on the fully open v5 while still taking its
minor and patch updates.

## What lands, and when

### 1. `.github/dependabot.yml` — a Gradle updater

**Trigger to add it:** the Gradle root exists at `android/`.

```yaml
  - package-ecosystem: gradle
    directory: /android
    schedule:
      interval: weekly
    open-pull-requests-limit: 10
```

Swift Package Manager dependencies in `macos/` get a `swift` ecosystem entry at the same
point, if the Xcode project takes any.

### 2. `.github/workflows/ci.yml`

**Trigger to add it:** the first project that builds reproducibly from a documented local
command. Add the matching job then, not the whole matrix up front — a job per target, each
landing when its target does.

Every workflow in the family carries the **hardening trio**, with the explanatory comments:

```yaml
permissions:
  contents: read              # 1. least privilege

concurrency:
  group: ci-${{ github.ref }} # 2. cancel superseded PR runs, never an in-progress
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
                              #    main run — a permanently "cancelled" main commit
                              #    masks breakage and breaks CI bisection

jobs:
  <job>:
    timeout-minutes: <n>      # 3. a wedged build must not burn 6 h of runner time
```

Planned jobs, per [AGENTS.md](AGENTS.md)'s verification list:

| Job | Runner | Steps |
| --- | --- | --- |
| `android` | `ubuntu-latest` | `gradle/actions/wrapper-validation` **first** (supply-chain gate against a tampered `gradle-wrapper.jar`), Temurin JDK 17, `gradle/actions/setup-gradle`, then `testDebugUnitTest lintDebug assembleDebug` from `android/` |
| `macos` | `macos-14`, Xcode pinned via `maxim-lobanov/setup-xcode` | `swift test` / `xcodebuild test`, then a development build |
| `protocol` | `ubuntu-latest` | Both implementations consume the same schemas, fixtures and test vectors under `protocol/` — this job is what makes that claim enforceable rather than aspirational |
| `otp-corpus` | `ubuntu-latest` | The ~120-case YAML corpus (PLAN.md §15) gating extraction precision/recall |

Pin toolchains — Xcode version, JDK, `compileSdk` — so a runner-image bump can't silently
change them. Storage-migration tests (Room + GRDB, old DB → current) belong here as CI
fixtures, not as a manual matrix.

### 3. `scripts/build.sh` and `scripts/release.sh`

**Trigger to add them:** a real build command, artifact path, application ID, version
source and signing model exist.

Both are ~25-line **stubs** over the shared engines in
[release-tool](https://github.com/L-K-M/release-tool) (install: clone + `./install.sh`).
They export `BUILD_*` / `RELEASE_*` config and `exec` the engine; nothing repo-specific
goes in them. Never inline a bespoke release script when an engine kind fits — and if none
fits, add a kind upstream.

Eko is a two-platform monorepo, which is the one thing that needs deciding rather than
copying:

- **`scripts/build.sh`** — Séance is the model. A repo with several artifacts and
  toolchains gets a bespoke orchestrator in the family house style rather than a stub:
  header comment doubling as `--help`, `set -uo pipefail` **without** `-e` so failures
  aggregate, per-target feasibility (a missing toolchain *skips* on a default run but
  *fails* when that target was named explicitly), one `Summary` block, and every artifact
  staged into a gitignored `dist/`.
- **`scripts/release.sh`** — the version has to move in lockstep across
  `android/app/build.gradle.kts` (`versionName` + an auto-incremented `versionCode`) and
  the macOS bundle. No single engine kind covers both, so pick one at that point:
  `gradle-android` with a `RELEASE_POST_BUMP` that syncs the macOS version, or `tag-only`
  with each platform's version derived from the tag in CI. Whichever it is, the rule is
  that **one** command bumps everything and creates the tag.

Add `scripts/install-debug.sh` (build + `adb install` onto a connected phone) alongside;
Blipbird's is directly reusable.

### 4. `README.md` version marker

The release engine keeps a marker in the README in step with the committed version:

```
**Latest release:** v<!-- version -->1.0.0<!-- /version --> · [Download](https://github.com/L-K-M/Eko/releases/latest)
```

Not present yet, because nothing in the repo declares a version to track. It goes in with
`scripts/release.sh`.

### 5. `.github/workflows/release.yml`

**Trigger to add it:** signing keys exist for both platforms.

Family shape: `on: push: tags: ['v*']`, `concurrency: release-${{ github.ref }}` with
`cancel-in-progress: false`, `permissions: contents: write`, version derived from the tag
as `${GITHUB_REF_NAME#v}`, published with `softprops/action-gh-release`. Several jobs may
each attach their artifact to the same tag's release. A pre-release tag (one containing a
hyphen) must set `prerelease: true`.

Four rules, all of which Eko's own docs already commit to:

1. **Re-prove the tagged commit.** A `v*` tag can land on any commit, including one CI
   never saw. Tests run before anything publishes.
2. **Assert the tag matches the committed version** and fail loudly if not — otherwise a
   release named `v1.5.0` ships a `0.1.0` build.
3. **Fail closed on missing signing secrets**, before building. Both platforms:
   Developer ID + notarization + stapling on macOS; Eko's own APK signing key on Android.
   *Never publish an unsigned APK or an unsigned application bundle* — an app that reads
   every notification on the phone has no business being distributed unsigned, and on
   Android the signing certificate is also the upgrade identity: a differently signed APK
   cannot update an installed Eko.
4. **Publish SHA-256 checksums** next to every artifact, and verify signatures in CI
   (`apksigner verify --print-certs`, `stapler validate`, `spctl --assess`) rather than
   assuming the signing step worked.

Expected secrets, using the family's standard names:

| Platform | Secrets |
| --- | --- |
| Android | `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` |
| macOS | `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `KEYCHAIN_PASSWORD`, `APPLE_TEAM_ID`, `AC_API_KEY_BASE64`, `AC_API_KEY_ID`, `AC_API_ISSUER_ID` |

Sideloaded Android distribution means users update through an in-app check or Obtainium
against GitHub Releases, so the release feed is the update channel — a broken or unsigned
release is a broken updater, not just a bad download.

## One Eko-specific caution

PLAN.md §15's soak rig, device matrix and permission-grant QA are **not** CI jobs and
should not be forced into one: they need real phones, a Wi-Fi AP that can be toggled, and
system dialogs that only reset via VM snapshots. CI covers unit tests, lint, protocol
conformance against shared vectors, the OTP corpus, storage migrations, and the simulator
harnesses (`tools/`). The rest stays a documented manual script.

Notification text, OTPs, pairing material, certificates and diagnostics are sensitive. No
workflow, fixture or test vector may contain a real example — this applies to CI logs and
uploaded artifacts as much as to committed files.

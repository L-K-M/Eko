#!/usr/bin/env bash
#
# Build every Eko artifact this host can build, and print one clear summary.
# The single local entry point; CI builds the same artifacts in
# .github/workflows/ci.yml and release.yml.
#
#   apk — Android APK from android/ (needs a JDK and an Android SDK)
#   app — macOS Eko.app from macos/ (needs macOS, Xcode, XcodeGen and Node)
#
# Usage:
#   scripts/build.sh                 # every target this host can build
#   scripts/build.sh apk             # just this one (naming a target turns an
#                                    # infeasible target into an error, not a skip)
#   scripts/build.sh --debug         # debug/Debug builds instead of release
#   scripts/build.sh --clean         # wipe build output first
#   scripts/build.sh --install       # build the macOS app and install it into
#                                    # /Applications, then reveal it
#   scripts/build.sh --check         # print resolved config; build nothing
#
# Every produced file is also copied into dist/ at the repo root — one folder
# with the final artifacts — and on macOS dist/ is opened in the Finder when
# anything landed there.
#
# A release-configuration APK built here is UNSIGNED and cannot be installed;
# release signing lives in CI (.github/workflows/release.yml). Use --debug, or
# scripts/install-debug.sh, to get something a phone will accept.
#
# Exit status is non-zero if any requested target fails to build. Targets that
# simply can't build on this host are reported as skipped, and only fail the run
# when you named them explicitly.
set -uo pipefail

# Absolute path to this script — usage() must find it after the cd below, even
# when invoked via a relative path from a subdirectory.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

PROFILE="release"
CLEAN=false
INSTALL=false
CHECK=false
declare -a REQUESTED=()
EXPLICIT=0

usage() {
  # Print the leading comment block (the file header), minus the shebang.
  awk 'NR==1 && /^#!/ {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$SELF"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --debug) PROFILE="debug"; shift ;;
    --clean) CLEAN=true; shift ;;
    --install) INSTALL=true; shift ;;
    --check) CHECK=true; shift ;;
    apk|app) REQUESTED+=("$1"); EXPLICIT=1; shift ;;
    all) REQUESTED=(apk app); EXPLICIT=1; shift ;;
    *) echo "unknown argument: $1" >&2; usage 1 ;;
  esac
done

# --install is about the macOS app: with no explicit targets it builds just
# that, and with explicit targets it makes sure `app` is among them.
if $INSTALL; then
  if [[ ${#REQUESTED[@]} -eq 0 ]]; then
    REQUESTED=(app); EXPLICIT=1
  else
    found=0
    for t in "${REQUESTED[@]}"; do [[ "$t" == "app" ]] && found=1; done
    [[ $found -eq 0 ]] && REQUESTED+=(app)
  fi
fi

if [[ ${#REQUESTED[@]} -eq 0 ]]; then
  REQUESTED=(apk app)
fi

case "$(uname -s)" in
  Darwin) HOST="macos" ;;
  Linux) HOST="linux" ;;
  MINGW*|MSYS*|CYGWIN*) HOST="windows" ;;
  *) HOST="unknown" ;;
esac

# The committed version, read from the same file release.yml's gate reads.
VERSION="$(sed -nE 's/^[[:space:]]*versionName[[:space:]]*=[[:space:]]*"([^"]*)".*$/\1/p' android/app/build.gradle.kts | head -n 1)"
[[ -n "$VERSION" ]] || VERSION="unknown"
# VERSION becomes part of staged artifact names (eko-v$VERSION-*.apk), which
# stage() passes to rm -rf — refuse anything that could escape dist/.
[[ "$VERSION" =~ ^[0-9A-Za-z.-]+$ || "$VERSION" == "unknown" ]] \
  || { echo "error: versionName '$VERSION' is not safe for artifact names" >&2; exit 1; }

echo "Eko build"
echo "  host:    $HOST ($(uname -s))"
echo "  profile: $PROFILE"
echo "  version: $VERSION"
echo "  targets: ${REQUESTED[*]}"
echo

have() { command -v "$1" >/dev/null 2>&1; }

declare -a RESULTS=()
record() { RESULTS+=("$1"); }

DIST="$ROOT/dist"
STAGED=0
stage() {
  local src="$1"
  local name="${2:-$(basename "$1")}"
  mkdir -p "$DIST" || return 1
  rm -rf "${DIST:?}/$name" || return 1
  cp -R "$src" "$DIST/$name" || return 1
  STAGED=$((STAGED + 1))
  echo "-- staged dist/$name"
}

was_named() {
  [[ $EXPLICIT -eq 1 ]] || return 1
  local t
  for t in "${REQUESTED[@]}"; do [[ "$t" == "$1" ]] && return 0; done
  return 1
}

# Skip a target: a soft skip on a default run, a hard error when named.
skip_or_fail() {
  local target="$1" reason="$2"
  if was_named "$target"; then
    echo "!! $target: cannot build on this host — $reason" >&2
    record "$target: FAILED ($reason)"
    return 1
  fi
  echo ".. $target: skipped — $reason"
  record "$target: skipped ($reason)"
  return 0
}

# What separates "can build the APK" from a long doomed Gradle run.
detect_android_sdk() {
  local c
  for c in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" \
           "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
    [[ -n "$c" && -d "$c/platforms" ]] && { echo "$c"; return 0; }
  done
  # A committed-free local.properties is the other supported way to point
  # Gradle at an SDK, and it wins over the environment for the Gradle run.
  if [[ -f android/local.properties ]] && grep -q '^sdk\.dir=' android/local.properties; then
    sed -nE 's/^sdk\.dir=(.*)$/\1/p' android/local.properties | head -n 1
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
build_apk() {
  echo "== apk (Android) =="

  local task apk out
  if [[ "$PROFILE" == "release" ]]; then
    task="assembleRelease"
    apk="android/app/build/outputs/apk/release/app-release-unsigned.apk"
    out="eko-v$VERSION-release-unsigned.apk"
  else
    task="assembleDebug"
    apk="android/app/build/outputs/apk/debug/app-debug.apk"
    out="eko-v$VERSION-debug.apk"
  fi

  # --check answers "what would this run do", so it reports the plan even on a
  # host that couldn't carry it out.
  if $CHECK; then
    echo "-- would run: (cd android && ./gradlew $task)"
    echo "-- would stage: dist/$out"
    record "apk: checked (would build $task)"
    return 0
  fi

  if ! have java; then skip_or_fail apk "no JDK on PATH (java)"; return; fi
  local sdk
  if ! sdk="$(detect_android_sdk)"; then
    skip_or_fail apk "no Android SDK found (set ANDROID_SDK_ROOT, or write android/local.properties)"; return
  fi
  echo "-- Android SDK: $sdk"

  if $CLEAN; then
    echo "-- gradlew clean"
    ( cd android && ./gradlew clean ) || { record "apk: FAILED (clean)"; return 1; }
  fi

  echo "-- gradlew $task"
  if ( cd android && ./gradlew "$task" ); then
    if [[ -f "$apk" ]]; then
      if ! stage "$apk" "$out"; then
        echo "!! apk: failed to stage $apk as dist/$out" >&2
        record "apk: FAILED (staging)"; return 1
      fi
      record "apk: built ($PROFILE) -> dist/$out"
    else
      echo "!! apk: $task succeeded but $apk is missing" >&2
      record "apk: FAILED (artifact not found)"; return 1
    fi
  else
    echo "!! apk: ./gradlew $task failed" >&2
    record "apk: FAILED (gradle)"; return 1
  fi
}

# ---------------------------------------------------------------------------
build_app() {
  echo "== app (macOS) =="

  local config="Release"
  [[ "$PROFILE" == "debug" ]] && config="Debug"
  # Under build/, which .gitignore already covers, and separate from macos/.build
  # so SwiftPM's tree and xcodebuild's DerivedData don't share a directory.
  local derived="$ROOT/build/macos-derived"

  if $CHECK; then
    echo "-- would run: macos/Scripts/generate-project.sh"
    echo "-- would run: xcodebuild -project macos/Eko.xcodeproj -scheme Eko -configuration $config build"
    echo "-- would stage: dist/Eko.app"
    record "app: checked (would build $config)"
    return 0
  fi

  if [[ "$HOST" != "macos" ]]; then
    skip_or_fail app "macOS is required (Network.framework, Security.framework, AppKit, CoreBluetooth)"; return
  fi
  if ! have xcodebuild; then skip_or_fail app "Xcode command line tools (xcodebuild) not found"; return; fi
  if ! have xcodegen; then skip_or_fail app "XcodeGen not found — install it with: brew install xcodegen"; return; fi
  if ! have node; then skip_or_fail app "Node.js not found (the icon generator needs it)"; return; fi

  if $CLEAN; then
    echo "-- removing $derived"
    rm -rf "$derived"
  fi

  echo "-- generate-project.sh"
  if ! ( cd macos && ./Scripts/generate-project.sh ); then
    echo "!! app: project generation failed" >&2
    record "app: FAILED (xcodegen)"; return 1
  fi

  # Plain `build` (and CI) use the certificate-free ad-hoc path: CODE_SIGNING
  # off, then an explicit ad-hoc signature so the bundle launches on Apple
  # Silicon. Developer ID signing for release is release.yml's job.
  #
  # `--install` is different: the app is sandboxed and stores its identity key in
  # the Data Protection Keychain, which an ad-hoc signature cannot access
  # (errSecMissingEntitlement) and which refuses to launch with a keychain
  # access-group entitlement but no provisioning profile. So a local install is
  # built with Apple Development automatic signing and a provisioning profile.
  # Override the team with EKO_DEVELOPMENT_TEAM.
  local dev_team="${EKO_DEVELOPMENT_TEAM:-RY935S6RFA}"
  local -a sign_args
  if $INSTALL; then
    sign_args=(CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$dev_team"
               CODE_SIGN_IDENTITY="Apple Development" -allowProvisioningUpdates)
  else
    sign_args=(CODE_SIGNING_ALLOWED=NO)
  fi

  echo "-- xcodebuild ($config)"
  if ! ( cd macos && xcodebuild build \
        -project Eko.xcodeproj -scheme Eko -configuration "$config" \
        -derivedDataPath "$derived" \
        -destination 'generic/platform=macOS' \
        "${sign_args[@]}" ); then
    echo "!! app: xcodebuild failed" >&2
    record "app: FAILED (xcodebuild)"; return 1
  fi

  local built
  built="$(find "$derived/Build/Products/$config" -maxdepth 1 -name 'Eko.app' -print -quit 2>/dev/null)"
  if [[ -z "$built" ]]; then
    echo "!! app: built Eko.app not found under $derived" >&2
    record "app: FAILED (product not found)"; return 1
  fi
  # Ad-hoc re-sign only on the certificate-free path; the --install path is
  # already signed by xcodebuild and overwriting it would strip the profile.
  if ! $INSTALL; then
    codesign --force --options runtime \
      --entitlements macos/Config/Eko.entitlements --sign - "$built" || {
      echo "!! app: ad-hoc signing failed" >&2
      record "app: FAILED (codesign)"; return 1
    }
  fi

  if ! stage "$built" "Eko.app"; then
    echo "!! app: failed to stage $built as dist/Eko.app" >&2
    record "app: FAILED (staging)"; return 1
  fi
  record "app: built ($config) -> dist/Eko.app"

  if $INSTALL; then
    echo "-- installing /Applications/Eko.app"
    rm -rf "/Applications/Eko.app"
    # ditto preserves the signature, resource forks and permissions.
    if ditto "$built" "/Applications/Eko.app"; then
      INSTALLED="/Applications/Eko.app"
      record "app: installed -> /Applications/Eko.app"
      # --install builds with a stable Apple Development identity, so the cdhash
      # is stable across rebuilds and TCC grants (notifications, Local Network,
      # Bluetooth) persist. This is the local-run path; release uses Developer ID.
      echo "-- signed with Apple Development identity; grants persist across rebuilds."
    else
      record "app: install FAILED (ditto)"; return 1
    fi
  fi
}

# ---------------------------------------------------------------------------
FAILED=0
INSTALLED=""
for target in "${REQUESTED[@]}"; do
  case "$target" in
    apk) build_apk || FAILED=1 ;;
    app) build_app || FAILED=1 ;;
  esac
  echo
done

echo "Summary"
for line in "${RESULTS[@]}"; do echo "  $line"; done

if [[ -n "$INSTALLED" ]]; then
  echo "  installed: $INSTALLED"
  [[ "$(uname -s)" == "Darwin" ]] && open -R "$INSTALLED"
elif [[ "$STAGED" -gt 0 ]]; then
  echo "  artifacts: $DIST"
  [[ "$(uname -s)" == "Darwin" ]] && open "$DIST"
fi

exit "$FAILED"

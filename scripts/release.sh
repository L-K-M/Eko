#!/usr/bin/env bash
#
# Cuts a release: moves the version in lockstep across both platforms, updates
# the README marker, commits, tags "v<version>", and with --push pushes branch +
# tag — which triggers .github/workflows/release.yml to re-prove the tagged
# commit, build both artifacts, sign them, and publish the GitHub Release.
#
#   scripts/release.sh 1.3.0          # bump both version files + README, commit, tag v1.3.0
#   scripts/release.sh 1.3.0 --push   # …also push the commit + tag (CI then publishes)
#   scripts/release.sh                # tag the current committed version as-is
#   scripts/release.sh 1.3.0 --dry-run  # show every edit, change nothing
#
# Usage: scripts/release.sh [X.Y[.Z]] [--push] [--dry-run]
#
# Why this is a bespoke script and not a stub over the shared lkm-release engine
# (https://github.com/L-K-M/release-tool): Eko is a two-platform monorepo with
# two version sources that must agree —
#
#   android/app/build.gradle.kts   versionName + versionCode
#   macos/project.yml              MARKETING_VERSION + CURRENT_PROJECT_VERSION
#
# — and no single engine kind bumps both. The rule the engine exists to enforce
# still holds and is enforced here: ONE command moves everything and creates the
# tag, and release.yml refuses to publish a tag that disagrees with either file.
#
# The build numbers (versionCode, CURRENT_PROJECT_VERSION) are auto-incremented
# and deliberately kept equal to each other, so one number identifies a build
# across both platforms in the release record (docs/release-checklists.md).
# Android requires a strictly increasing versionCode per release; macOS treats
# CURRENT_PROJECT_VERSION as the build that distinguishes two bundles sharing a
# marketing version.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GRADLE_FILE="android/app/build.gradle.kts"
PROJECT_FILE="macos/project.yml"
README_FILE="README.md"

usage() {
  awk 'NR==1 && /^#!/ {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$SELF"
  exit "${1:-0}"
}

die() { echo "error: $*" >&2; exit 1; }

NEW_VERSION=""
PUSH=false
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --push) PUSH=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -*) echo "unknown option: $1" >&2; usage 1 ;;
    *)
      [[ -z "$NEW_VERSION" ]] || die "give at most one version"
      NEW_VERSION="$1"; shift ;;
  esac
done

if [[ -n "$NEW_VERSION" ]]; then
  [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?(-[0-9A-Za-z.-]+)?$ ]] \
    || die "version must look like 1.2 or 1.2.3 (optionally 1.2.3-rc.1), got '$NEW_VERSION'"
fi

# --- read the current state -------------------------------------------------
read_gradle() { sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"?([^\"[:space:]]+)\"?.*$/\1/p" "$GRADLE_FILE" | head -n 1; }
read_yaml()   { sed -nE "s/^[[:space:]]*$1:[[:space:]]*\"?([^\"[:space:]]+)\"?.*$/\1/p" "$PROJECT_FILE" | head -n 1; }

CUR_ANDROID_VERSION="$(read_gradle versionName)"
CUR_ANDROID_CODE="$(read_gradle versionCode)"
CUR_MACOS_VERSION="$(read_yaml MARKETING_VERSION)"
CUR_MACOS_BUILD="$(read_yaml CURRENT_PROJECT_VERSION)"

[[ -n "$CUR_ANDROID_VERSION" ]] || die "could not read versionName from $GRADLE_FILE"
[[ -n "$CUR_ANDROID_CODE" ]] || die "could not read versionCode from $GRADLE_FILE"
[[ -n "$CUR_MACOS_VERSION" ]] || die "could not read MARKETING_VERSION from $PROJECT_FILE"
[[ -n "$CUR_MACOS_BUILD" ]] || die "could not read CURRENT_PROJECT_VERSION from $PROJECT_FILE"

# Both files must already agree, or the "one command moves everything" rule was
# broken by a hand edit and this script would paper over it.
[[ "$CUR_ANDROID_VERSION" == "$CUR_MACOS_VERSION" ]] \
  || die "committed versions disagree: $GRADLE_FILE says $CUR_ANDROID_VERSION, $PROJECT_FILE says $CUR_MACOS_VERSION. Fix by hand, then re-run."

VERSION="${NEW_VERSION:-$CUR_ANDROID_VERSION}"
TAG="v$VERSION"

echo "Eko release"
echo "  current: $CUR_ANDROID_VERSION (android build $CUR_ANDROID_CODE, macOS build $CUR_MACOS_BUILD)"
echo "  release: $VERSION -> tag $TAG"
$DRY_RUN && echo "  mode:    dry run (nothing is written)"
echo

# --- preconditions ----------------------------------------------------------
git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  die "tag $TAG already exists — pick another version, or delete the tag if it was never pushed"
fi
if [[ -n "$(git status --porcelain)" ]] && ! $DRY_RUN; then
  die "working tree is not clean; commit or stash first (a release commit must contain only the bump)"
fi

# --- the bump ---------------------------------------------------------------
if [[ -z "$NEW_VERSION" ]]; then
  echo "-- no version given: tagging the committed version as-is"
else
  NEXT_BUILD=$(( (CUR_ANDROID_CODE > CUR_MACOS_BUILD ? CUR_ANDROID_CODE : CUR_MACOS_BUILD) + 1 ))
  echo "-- version $CUR_ANDROID_VERSION -> $VERSION, build -> $NEXT_BUILD (both platforms)"

  # Restore every edited file if anything below fails, so a half-applied bump
  # can never be committed.
  restore() { git checkout -- "$GRADLE_FILE" "$PROJECT_FILE" "$README_FILE" 2>/dev/null || true; }
  # EXIT, not ERR: die() exits explicitly, and an explicit exit never fires an
  # ERR trap — which would leave a half-applied bump sitting in the tree. The
  # trap is cleared once the bump is committed.
  $DRY_RUN || trap restore EXIT

  edit() { # edit <file> <sed-expression>
    local file="$1" expr="$2"
    if $DRY_RUN; then
      echo "   would apply to $file: $expr"
      return 0
    fi
    local tmp
    tmp="$(mktemp)"
    sed -E "$expr" "$file" > "$tmp"
    # sed exits 0 on a pattern that matched nothing, so compare instead.
    if cmp -s "$file" "$tmp"; then
      rm -f "$tmp"
      die "no change applied to $file (expression: $expr) — the file's format moved"
    fi
    mv "$tmp" "$file"
  }

  edit "$GRADLE_FILE" "s/^([[:space:]]*versionName[[:space:]]*=[[:space:]]*\").*(\".*)$/\1$VERSION\2/"
  edit "$GRADLE_FILE" "s/^([[:space:]]*versionCode[[:space:]]*=[[:space:]]*)[0-9]+(.*)$/\1$NEXT_BUILD\2/"
  edit "$PROJECT_FILE" "s/^([[:space:]]*MARKETING_VERSION:[[:space:]]*).*$/\1$VERSION/"
  edit "$PROJECT_FILE" "s/^([[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*).*$/\1$NEXT_BUILD/"
  edit "$README_FILE" "s|(<!-- version -->).*(<!-- /version -->)|\1$VERSION\2|"
fi

# --- verify what we are about to tag ----------------------------------------
if ! $DRY_RUN; then
  for check in "versionName:$(read_gradle versionName)" \
               "MARKETING_VERSION:$(read_yaml MARKETING_VERSION)"; do
    name="${check%%:*}"; value="${check#*:}"
    [[ "$value" == "$VERSION" ]] || die "$name is '$value' after the bump, expected '$VERSION'"
  done
fi

if $DRY_RUN; then
  echo
  echo "Dry run complete — nothing was written."
  exit 0
fi

# --- commit and tag ---------------------------------------------------------
if [[ -n "$NEW_VERSION" ]]; then
  git add "$GRADLE_FILE" "$PROJECT_FILE" "$README_FILE"
  git commit -m "Release $TAG"
  # Committed: the bump is now history, so stop trying to restore it. A later
  # failure (tag, push) leaves the commit in place to be dealt with directly.
  trap - EXIT
  echo "-- committed the bump"
fi

git tag -a "$TAG" -m "Eko $TAG"
echo "-- tagged $TAG"

if $PUSH; then
  BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  git push -u origin "$BRANCH"
  git push origin "$TAG"
  echo
  echo "Pushed $BRANCH and $TAG."
  echo "CI (release.yml) will now re-prove the tagged commit, build the Android APK and"
  echo "the macOS app, sign each where its secrets are configured, and publish the"
  echo "GitHub Release with a SHA-256 sum per artifact."
else
  echo
  echo "Nothing was pushed. When ready:"
  echo "  git push -u origin $(git rev-parse --abbrev-ref HEAD) && git push origin $TAG"
fi

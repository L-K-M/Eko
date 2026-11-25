#!/usr/bin/env bash
# Update the self-hosted relay without changing its Compose project or volumes.
# Usage: ./update.sh [checked-out-branch]
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
cd "$root"

fail() { printf 'update: %s\n' "$*" >&2; exit 1; }
compose() { (cd "$root/server" && docker compose "$@"); }
compose_running_profile() {
    if [[ -n $caddy_running ]]; then
        compose -p "$project" --profile tls "$@"
    else
        compose -p "$project" "$@"
    fi
}
compose_project() {
    compose config --format json 2>/dev/null |
        python3 -c 'import json, sys; print(json.load(sys.stdin)["name"])' 2>/dev/null
}

case ${1:-} in
    -h|--help)
        printf '%s\n' 'Usage: ./update.sh [checked-out-branch]'
        exit 0
        ;;
esac
(( $# <= 1 )) || fail 'usage: ./update.sh [checked-out-branch]'
for tool in git docker python3; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing prerequisite: $tool"
done

current=$(git symbolic-ref --quiet --short HEAD) || fail 'check out a branch before updating'
branch=${1:-$current}
git check-ref-format --branch "$branch" >/dev/null 2>&1 || fail "invalid branch name: $branch"
[[ $branch == "$current" ]] || fail "branch $branch is not checked out"
[[ -z $(git status --porcelain --untracked-files=no) ]] ||
    fail 'tracked files have local changes; commit or stash them first'

compose version >/dev/null 2>&1 || fail 'Docker Compose is unavailable'
[[ -r server/.env ]] || fail 'server/.env is required; copy server/.env.example'
compose config --quiet >/dev/null 2>&1 || fail 'the current relay Compose configuration is invalid'
project=$(compose_project) || fail 'cannot resolve the current Compose project name'
[[ -n $project ]] || fail 'the current Compose project name is empty'
caddy_running=$(compose -p "$project" --profile tls ps --status running --quiet caddy) ||
    fail 'cannot inspect the running Caddy service'

printf 'Fetching %s from origin...\n' "$branch"
git fetch --no-tags origin "+refs/heads/$branch:refs/remotes/origin/$branch"
git merge --ff-only "origin/$branch"

# A changed project name would select a fresh relay-data volume and appear to
# lose every account and queued envelope. Stop before building or recreating.
compose config --quiet >/dev/null 2>&1 || fail 'the updated relay Compose configuration is invalid'
updated_project=$(compose_project) || fail 'cannot resolve the updated Compose project name'
[[ $updated_project == "$project" ]] ||
    fail 'the update changes the Compose project name; migrate the volume manually'

printf 'Building the relay image...\n'
compose -p "$project" build --pull relay

if [[ -n $caddy_running ]]; then
    printf 'Refreshing the running Caddy service...\n'
    compose -p "$project" --profile tls pull caddy
fi

printf 'Starting the relay and waiting for health...\n'
compose_running_profile up -d --no-build --wait --wait-timeout 120
compose_running_profile ps

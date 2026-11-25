#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
fixture=$(mktemp -d)
trap 'rm -r "$fixture"' EXIT

git init --bare --quiet --initial-branch=main "$fixture/origin.git"
git clone --quiet "$fixture/origin.git" "$fixture/work"
mkdir -p "$fixture/work/server" "$fixture/bin"
cp "$repo/update.sh" "$fixture/work/update.sh"
printf 'services: {}\n' > "$fixture/work/server/docker-compose.yml"
printf 'EKO_BOOTSTRAP_TOKEN=test\n' > "$fixture/work/server/.env"
printf 'server/.env\n' > "$fixture/work/.gitignore"
git -C "$fixture/work" add update.sh server/docker-compose.yml .gitignore
git -C "$fixture/work" -c user.name='Update test' -c user.email='update@example.invalid' \
    commit --quiet -m 'Initial deployment'
git -C "$fixture/work" push --quiet --set-upstream origin main

cat > "$fixture/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >> "$TEST_DOCKER_LOG"
case " $* " in
    *' config --format json '*)
        if grep -q '^name:' docker-compose.yml; then
            printf '{"name":"renamed"}\n'
        else
            printf '{"name":"eko"}\n'
        fi
        ;;
    *' ps --status running --quiet caddy '*)
        if [[ ${TEST_CADDY_RUNNING:-0} == 1 ]]; then
            printf 'caddy-container\n'
        fi
        ;;
    *' ps --status running --quiet relay '*)
        if [[ ${TEST_RELAY_PRESENT:-1} == 1 ]]; then
            printf 'relay-container\n'
        fi
        ;;
    *' build --pull relay '*)
        if [[ ${TEST_BUILD_FAIL:-0} == 1 ]]; then exit 1; fi
        ;;
esac
EOF
chmod +x "$fixture/bin/docker"
export TEST_DOCKER_LOG="$fixture/docker.log"

# Use the system Bash so a Mac run also covers Bash 3.2 compatibility.
# A branch argument must not merge another branch into the checked-out one.
if (cd "$fixture/work" && PATH="$fixture/bin:$PATH" /bin/bash ./update.sh other >"$fixture/output" 2>&1); then
    printf '%s\n' 'update.sh accepted another branch' >&2
    exit 1
fi
grep -q 'is not checked out' "$fixture/output"
[[ ! -s $TEST_DOCKER_LOG ]]

# Local edits must not be mixed with remote source during deployment.
printf '# local edit\n' >> "$fixture/work/server/docker-compose.yml"
if (cd "$fixture/work" && PATH="$fixture/bin:$PATH" /bin/bash ./update.sh >"$fixture/output" 2>&1); then
    printf '%s\n' 'update.sh accepted a dirty checkout' >&2
    exit 1
fi
grep -q 'tracked files have local changes' "$fixture/output"
git -C "$fixture/work" restore server/docker-compose.yml

# An updater must not create a parallel Compose project on an unrecognized host.
export TEST_RELAY_PRESENT=0
: > "$TEST_DOCKER_LOG"
if (cd "$fixture/work" && PATH="$fixture/bin:$PATH" /bin/bash ./update.sh >"$fixture/output" 2>&1); then
    printf '%s\n' 'update.sh accepted a missing relay deployment' >&2
    exit 1
fi
grep -q 'no running relay container' "$fixture/output"
if grep -Eq ' (build|pull|up) ' "$TEST_DOCKER_LOG"; then
    printf '%s\n' 'update.sh changed containers without an existing relay' >&2
    exit 1
fi
export TEST_RELAY_PRESENT=1

git clone --quiet "$fixture/origin.git" "$fixture/pusher"
git -C "$fixture/pusher" -c user.name='Update test' -c user.email='update@example.invalid' \
    commit --quiet --allow-empty -m 'Advance main'
git -C "$fixture/pusher" push --quiet origin main

# A running Caddy must be pulled and kept active. The relay is built first.
export TEST_CADDY_RUNNING=1
: > "$TEST_DOCKER_LOG"
if ! (cd "$fixture/work" && PATH="$fixture/bin:$PATH" /bin/bash ./update.sh >"$fixture/output" 2>&1); then
    cat "$fixture/output" >&2
    exit 1
fi
[[ $(git -C "$fixture/work" rev-parse HEAD) == "$(git -C "$fixture/pusher" rev-parse HEAD)" ]]
grep -Fq '|compose -p eko build --pull relay' "$TEST_DOCKER_LOG"
grep -Fq '|compose -p eko --profile tls pull caddy' "$TEST_DOCKER_LOG"
grep -Fq '|compose -p eko --profile tls up -d --no-build --wait --wait-timeout 120' "$TEST_DOCKER_LOG"
if grep -Eq ' (down|up -d --build|up -d --remove-orphans)' "$TEST_DOCKER_LOG"; then
    printf '%s\n' 'update.sh used a destructive Compose operation' >&2
    exit 1
fi

# A failed build leaves the running stack alone.
export TEST_BUILD_FAIL=1
: > "$TEST_DOCKER_LOG"
if (cd "$fixture/work" && PATH="$fixture/bin:$PATH" /bin/bash ./update.sh >"$fixture/output" 2>&1); then
    printf '%s\n' 'update.sh ignored a failed build' >&2
    exit 1
fi
if grep -q ' up -d ' "$TEST_DOCKER_LOG"; then
    printf '%s\n' 'update.sh recreated the stack after a failed build' >&2
    exit 1
fi
unset TEST_BUILD_FAIL

# A relay without Caddy must stay on the relay-only profile.
export TEST_CADDY_RUNNING=0
: > "$TEST_DOCKER_LOG"
if ! (cd "$fixture/work" && PATH="$fixture/bin:$PATH" /bin/bash ./update.sh >"$fixture/output" 2>&1); then
    cat "$fixture/output" >&2
    exit 1
fi
grep -Fq '|compose -p eko up -d --no-build --wait --wait-timeout 120' "$TEST_DOCKER_LOG"
if grep -Eq ' pull caddy| --profile tls up ' "$TEST_DOCKER_LOG"; then
    printf '%s\n' 'update.sh activated an inactive Caddy service' >&2
    exit 1
fi

# A changed project name would select a different relay-data volume.
printf 'name: renamed\nservices: {}\n' > "$fixture/pusher/server/docker-compose.yml"
git -C "$fixture/pusher" add server/docker-compose.yml
git -C "$fixture/pusher" -c user.name='Update test' -c user.email='update@example.invalid' \
    commit --quiet -m 'Rename Compose project'
git -C "$fixture/pusher" push --quiet origin main
: > "$TEST_DOCKER_LOG"
if (cd "$fixture/work" && PATH="$fixture/bin:$PATH" /bin/bash ./update.sh >"$fixture/output" 2>&1); then
    printf '%s\n' 'update.sh accepted a new Compose project name' >&2
    exit 1
fi
grep -q 'changes the Compose project name' "$fixture/output"
if grep -Eq ' (build|pull|up) ' "$TEST_DOCKER_LOG"; then
    printf '%s\n' 'update.sh touched containers after the project-name change' >&2
    exit 1
fi

printf '%s\n' 'Eko Compose updater checks passed'

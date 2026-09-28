#!/usr/bin/env bash
# roles/la-compose/files/recreate-drifted-services.sh against a real Docker fixture.
# `up --no-recreate` kept branding-init on its old command after the template gained a
# chmod (#422, hub assets 0640 -> nginx 403). The script must recreate an exited
# one-shot whose definition changed, and leave alone a one-shot that did not change and,
# without --running, a RUNNING service whose definition changed (that is downtime, not
# allowed in production). With --running (CI/staging) the drifted running service is
# recreated too: a JAVA_OPTS fix otherwise never reached la_biocache-hub.
# ~15s, needs Docker.
set -eu
cd "$(dirname "$0")/.."
SCRIPT="$PWD/roles/la-compose/files/recreate-drifted-services.sh"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
proj="la_test_oneshot_$$"
cleanup() { (cd "$tmp" && docker compose -p "$proj" down -v --remove-orphans >/dev/null 2>&1) || true; rm -rf "$tmp"; }
trap cleanup EXIT

write() { # init-cmd same-cmd live-cmd
  cat >"$tmp/docker-compose.yml" <<YML
services:
  init:
    image: alpine:3.20
    command: ["sh", "-c", "echo $1 > /out/v"]
    volumes: [out:/out]
  same:
    image: alpine:3.20
    command: ["sh", "-c", "echo $2"]
  live:
    image: alpine:3.20
    command: ["sh", "-c", "$3"]
    restart: unless-stopped
    stop_grace_period: 1s
volumes:
  out:
YML
}
cd "$tmp"
export COMPOSE_PROJECT_NAME="$proj"

write old same "sleep 3600"
docker compose up -d >/dev/null 2>&1 || { docker compose pull >/dev/null 2>&1; docker compose up -d >/dev/null; }
docker compose wait init same >/dev/null 2>&1 || true
live_before=$(docker compose ps -q live)
same_before=$(docker compose ps -a -q same)

write new same "sleep 3601"
docker compose up -d --no-recreate >/dev/null 2>&1
sleep 2
[ "$(docker compose run --rm --no-deps -v "${proj}_out:/o" --entrypoint cat init /o/v 2>/dev/null)" = old ] ||
  fail "fixture: expected --no-recreate to keep the stale one-shot"

out="$(bash "$SCRIPT")" || fail "script failed: $out"
sleep 2
echo "$out" | grep -qx "recreated init" || fail "drifted one-shot not recreated: $out"
[ "$(docker compose run --rm --no-deps -v "${proj}_out:/o" --entrypoint cat init /o/v 2>/dev/null)" = new ] ||
  fail "recreated one-shot did not run its new command"
pass "an exited one-shot whose definition changed is recreated and runs the new command"

[ "$(docker compose ps -q live)" = "$live_before" ] || fail "a running service was recreated (downtime)"
[ "$(docker compose ps -a -q same)" = "$same_before" ] || fail "an unchanged one-shot was recreated"
echo "$out" | tail -1 | grep -qx "recreated 1" || fail "expected 'recreated 1': $out"
pass "without --running, running services and unchanged one-shots are left alone"

out="$(bash "$SCRIPT" --running)" || fail "script --running failed: $out"
echo "$out" | grep -qx "recreated live" || fail "--running did not recreate the drifted running service: $out"
[ "$(docker compose ps -q live)" != "$live_before" ] || fail "--running left the drifted running service in place"
docker inspect -f '{{json .Config.Cmd}}' "$(docker compose ps -q live)" | grep -q 'sleep 3601' ||
  fail "the recreated running service does not carry the new definition"
[ "$(docker compose ps -a -q same)" = "$same_before" ] || fail "--running recreated an unchanged one-shot"
pass "with --running, a drifted running service is recreated with its new definition"

out="$(bash "$SCRIPT" --running)"
echo "$out" | tail -1 | grep -qx "recreated 0" || fail "second run not idempotent: $out"
pass "a second run recreates nothing"

# Wiring: the role passes --running only through docker_recreate_drifted, and that is
# off in production (the non-destructive redeploy contract keeps only the drift warning).
cd "$OLDPWD"
grep -q "recreate-drifted-services.sh{{ ' --running' if docker_recreate_drifted" roles/la-compose/tasks/main.yml ||
  fail "main.yml does not gate --running on docker_recreate_drifted"
grep -qx "docker_recreate_drifted: \"{{ (la_env | default('ci')) != 'production' }}\"" roles/la-compose/defaults/main.yml ||
  fail "docker_recreate_drifted is not off by default in production"
pass "--running is gated on docker_recreate_drifted, off in production"

#!/usr/bin/env bash
# roles/docker-housekeeping/templates/containerd-gc.sh.j2 must not prune while a deploy
# is in progress. #428: the nightly timer fired at 02:10 during `docker compose up` on
# host2 and deleted ala-bie-hub:4.1.3, pulled minutes earlier but not yet used by any
# container ("No such image"). la-compose touches a marker for the length of a deploy.
# Renders the real template and runs it with a shimmed `docker` that records its calls:
#   1. fresh marker -> no prune at all;
#   2. marker older than the max age (a deploy that died) -> prunes;
#   3. no marker -> prunes.
# ~5s, no Docker, no root.
set -eu
cd "$(dirname "$0")/.."
ANSIBLE_PLAYBOOK="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}ansible-playbook"
command -v "$ANSIBLE_PLAYBOOK" >/dev/null || ANSIBLE_PLAYBOOK=ansible-playbook

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
marker="$tmp/la-compose-deploy.marker"

cat >"$tmp/play.yml" <<YML
- hosts: localhost
  connection: local
  gather_facts: false
  vars_files:
    - $PWD/roles/docker-housekeeping/defaults/main.yml
  tasks:
    - ansible.builtin.template:
        src: $PWD/roles/docker-housekeeping/templates/containerd-gc.sh.j2
        dest: $tmp/containerd-gc.sh
        mode: '0755'
YML
ANSIBLE_LOCALHOST_WARNING=false "$ANSIBLE_PLAYBOOK" -i localhost, "$tmp/play.yml" \
  -e "docker_housekeeping_deploy_marker=$marker" >"$tmp/render.log" 2>&1 ||
  { cat "$tmp/render.log" >&2; fail "template did not render"; }

mkdir -p "$tmp/bin"
cat >"$tmp/bin/docker" <<EOF
#!/bin/sh
echo "\$*" >>"$tmp/docker-calls"
EOF
chmod +x "$tmp/bin/docker"

run() { : >"$tmp/docker-calls"; PATH="$tmp/bin:$PATH" bash "$tmp/containerd-gc.sh" >"$tmp/out" 2>&1 ||
  { cat "$tmp/out" >&2; fail "$1: the gc script failed"; }; }

touch "$marker"
run fresh
[ ! -s "$tmp/docker-calls" ] || fail "fresh marker: the gc still ran: $(tr '\n' ';' <"$tmp/docker-calls")"
grep -q "deploy is in progress" "$tmp/out" || fail "fresh marker: no skip message"
pass "a deploy in progress (fresh marker) skips the prune"

touch -d '7 hours ago' "$marker"
run stale
grep -q "^image prune" "$tmp/docker-calls" || fail "stale marker: the prune was skipped forever"
pass "a marker older than the max age (a dead deploy) no longer blocks the prune"

rm -f "$marker"
run none
grep -q "^image prune" "$tmp/docker-calls" || fail "no marker: no prune"
pass "without a marker the prune runs as before"
echo "All checks passed."

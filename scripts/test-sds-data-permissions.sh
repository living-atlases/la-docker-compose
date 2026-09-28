#!/usr/bin/env bash
# roles/la-compose/tasks/sds-data-permissions.yml against a data dir written under the
# hardened umask of the gbif.es hosts (0027). nginx serves the three SDS XML files as its
# unprivileged user, so a 0750 dir / 0640 files answer 403 on every .xml while the service
# is healthy (gatus datos-sensibles.gbif.es, 2026-09-28). The task must open exactly what
# nginx serves: the dir and the three files, not config/. ~5s, no Docker, no root.
set -eu
cd "$(dirname "$0")/.."
TASKS="$PWD/roles/la-compose/tasks/sds-data-permissions.yml"
ANSIBLE_PLAYBOOK="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}ansible-playbook"
command -v "$ANSIBLE_PLAYBOOK" >/dev/null || ANSIBLE_PLAYBOOK=ansible-playbook

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
d="$tmp/data"
(
  umask 0027
  mkdir -p "$d/sds/config"
  for f in sensitive-species-data.xml sensitivity-zones.xml sensitivity-categories.xml; do
    echo '<?xml version="1.0"?><x/>' >"$d/sds/$f"
  done
  echo secret >"$d/sds/config/sds-config.json"
)
mode() { stat -c '%a' "$1"; }
[ "$(mode "$d/sds")" = 750 ] && [ "$(mode "$d/sds/sensitivity-zones.xml")" = 640 ] ||
  fail "fixture not written under umask 0027"

cat >"$tmp/play.yml" <<YML
- hosts: localhost
  connection: local
  gather_facts: false
  vars:
    data_dir: $d
  tasks:
    - ansible.builtin.include_tasks: $TASKS
YML
out="$("$ANSIBLE_PLAYBOOK" -i localhost, "$tmp/play.yml" 2>&1)" || fail "playbook failed: $out"

[ "$(mode "$d/sds")" = 755 ] || fail "sds dir is $(mode "$d/sds"), nginx cannot traverse it"
for f in sensitive-species-data.xml sensitivity-zones.xml sensitivity-categories.xml; do
  [ "$(mode "$d/sds/$f")" = 644 ] || fail "$f is $(mode "$d/sds/$f"), nginx cannot read it"
done
pass "the dir and the three XML files nginx serves are world-readable"

[ "$(mode "$d/sds/config")" = 750 ] && [ "$(mode "$d/sds/config/sds-config.json")" = 640 ] ||
  fail "config/ was opened up too"
pass "config/, which nginx never serves, keeps its mode"

out="$("$ANSIBLE_PLAYBOOK" -i localhost, "$tmp/play.yml" 2>&1)"
echo "$out" | grep -q 'changed=0' || fail "second run is not idempotent: $out"
pass "a second run changes nothing"

#!/usr/bin/env bash
# roles/la-compose/tasks/build-images.yml: pinned image tags are pulled only when missing,
# mutable ones (:latest, untagged) every time. `docker compose pull` re-resolved ~40
# manifests per host on every run (4.4 min of each #430/#431 playbook, all cached).
# Runs the real pull tasks against a shimmed `docker` that serves a compose config and
# records the pull commands:
#   1. default: `pull --policy missing`, then `pull --policy always` for exactly the
#      mutable services (not pinned tags, digests, or build-only services);
#   2. la_compose_pull_policy=always: one `pull --policy always`, as before.
# ~10s, no Docker, no root.
set -eu
cd "$(dirname "$0")/.."
SRC="$PWD/roles/la-compose/tasks/build-images.yml"
ANSIBLE_PLAYBOOK="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}ansible-playbook"
command -v "$ANSIBLE_PLAYBOOK" >/dev/null || ANSIBLE_PLAYBOOK=ansible-playbook
PY="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}python3"  # needs PyYAML
command -v "$PY" >/dev/null || PY=python3
# Modules run under the python that runs ansible-playbook (the venv's), not the agent's
# /usr/bin/python3 (#429).
PYARG='ansible_python_interpreter={{ ansible_playbook_python }}'

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/config.json" <<'JSON'
{"services": {
  "pinned": {"image": "livingatlases/regions:4.1.0"},
  "latest": {"image": "livingatlases/ala-i18n:latest"},
  "untagged": {"image": "nginx"},
  "port-untagged": {"image": "registry:5000/team/app"},
  "port-pinned": {"image": "registry:5000/team/app:2"},
  "digest": {"image": "cassandra@sha256:0123abcd"},
  "built": {"build": {"context": "."}}
}}
JSON
mkdir -p "$tmp/bin"
cat >"$tmp/bin/docker" <<SH
#!/bin/sh
case "\$*" in
  "compose config --format json") cat "$tmp/config.json" ;;
  "compose pull"*) echo "\$*" >>"$tmp/calls" ;;
  *) echo "unexpected: \$*" >&2; exit 1 ;;
esac
SH
chmod +x "$tmp/bin/docker"

"$PY" - "$SRC" "$tmp/tasks.yml" <<'PY'
import sys, yaml
src, out = sys.argv[1:3]
want = {"List the services whose image tag is mutable", "Split the services by image tag",
        "Pull Docker images", "Pull the images with a mutable tag"}
tasks = [t for t in yaml.safe_load(open(src)) if t.get("name") in want]
if len(tasks) != len(want):
    sys.exit("missing pull tasks in " + src)
open(out, "w").write(yaml.safe_dump(tasks, sort_keys=False))
PY

cat >"$tmp/play.yml" <<YML
- hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - ansible.builtin.include_tasks: $tmp/tasks.yml
YML
run() {
  : >"$tmp/calls"
  PATH="$tmp/bin:$PATH" ANSIBLE_LOCALHOST_WARNING=false "$ANSIBLE_PLAYBOOK" -i localhost, -e "$PYARG" \
    "$tmp/play.yml" -e ansible_become=false -e docker_registry=docker.io \
    -e "docker_compose_data_dir=$tmp" "$@" >"$tmp/run.log" 2>&1 ||
    { cat "$tmp/run.log" >&2; fail "playbook failed"; }
}

run
expected="compose pull --policy missing
compose pull --policy always latest untagged port-untagged"
[ "$(cat "$tmp/calls")" = "$expected" ] ||
  fail "default: expected
$expected
got
$(cat "$tmp/calls")"
pass "pinned tags and digests are pulled only when missing; :latest and untagged images always"

run -e la_compose_pull_policy=always
[ "$(cat "$tmp/calls")" = "compose pull --policy always" ] ||
  fail "la_compose_pull_policy=always: got $(tr '\n' ';' <"$tmp/calls")"
pass "la_compose_pull_policy=always pulls everything, once"
echo "All checks passed."

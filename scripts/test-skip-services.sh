#!/usr/bin/env bash
# skip_services reaches the la-compose role in every form a caller sends it, and only the
# named services are skipped (la_skip_services, roles/la-compose/defaults/main.yml):
#   1. the toolkit's extra var string "sds-static-home" skips that one and keeps 'sds'
#      (the bug: extra vars outrank set_fact, so the old in-place normalize never ran and
#      reject('in', <string>) dropped every service whose name is a substring of it);
#   2. "a, b" (comma list), a JSON list (the Jenkinsfile) and nothing at all;
#   3. no consumer in the role reads the raw skip_services any more.
# ~10s, no hosts: ansible-playbook on localhost.
set -eu
cd "$(dirname "$0")/.."

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

AP=""
for c in "${VENV_MOLECULE:-/nonexistent}/bin/ansible-playbook" "$PWD/.venv-molecule/bin/ansible-playbook" ansible-playbook; do
  command -v "$c" >/dev/null 2>&1 && { AP="$c"; break; }
done
[ -n "$AP" ] || fail "no ansible-playbook"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/play.yml" <<'PLAY'
- hosts: localhost
  gather_facts: false
  vars_files:
    - ROLE/defaults/main.yml
  tasks:
    # set_fact, not play vars: the role defaults in vars_files outrank play vars.
    - ansible.builtin.set_fact:
        docker_services_desc:
          sds: {group: sds}
          sdsStaticHome: {group: sds-static-home}
          sensitiveDataService: {group: sensitive-data-service}
          alerts: {group: alerts-service}
        services_enabled: [sds, sdsStaticHome, sensitiveDataService, alerts]
    - name: The role's own filter (setup-facts.yml), on the normalized list
      ansible.builtin.set_fact:
        kept: >-
          {{ services_enabled
             | reject('in', la_skip_services)
             | reject('in', docker_services_desc | dict2items
                 | selectattr('value.group', 'in', la_skip_services)
                 | map(attribute='key') | list)
             | list }}
    - ansible.builtin.copy:
        content: "{{ {'skip': la_skip_services, 'kept': kept} | to_json }}"
        dest: "{{ out }}"
PLAY
sed -i "s#ROLE#$PWD/roles/la-compose#" "$tmp/play.yml"

run() { # $1 = expected JSON, rest = ansible-playbook extra args
  local want="$1"; shift
  ANSIBLE_LOCALHOST_WARNING=false "$AP" -i localhost, -c local "$tmp/play.yml" \
    -e "out=$tmp/out.json" "$@" >"$tmp/log" 2>&1 || { cat "$tmp/log" >&2; fail "ansible-playbook $*"; }
  python3 - "$tmp/out.json" "$want" <<'PY' || fail "$* -> $(cat "$tmp/out.json")"
import json, sys
got, want = json.load(open(sys.argv[1])), json.loads(sys.argv[2])
sys.exit(0 if got == want else 1)
PY
}

run '{"skip": ["sds-static-home"], "kept": ["sds", "sensitiveDataService", "alerts"]}' -e skip_services=sds-static-home
pass "the toolkit's string skips sds-static-home and keeps sds"

run '{"skip": ["sds-static-home", "alerts"], "kept": ["sds", "sensitiveDataService"]}' -e 'skip_services="sds-static-home, alerts"'
run '{"skip": ["sds-static-home", "alerts"], "kept": ["sds", "sensitiveDataService"]}' -e '{"skip_services": ["sds-static-home", "alerts"]}'
run '{"skip": [], "kept": ["sds", "sdsStaticHome", "sensitiveDataService", "alerts"]}'
pass "a comma list, a JSON list and no skip_services"

raw=$(grep -rnE "(^|[^_a-z])skip_services( \||\)| *$|\])" roles/la-compose/tasks roles/la-compose/templates |
  grep -v "la_skip_services | default(skip_services | default(\[\]))" | grep -v "^[^:]*:[0-9]*: *#" || true)
[ -z "$raw" ] || { echo "$raw" >&2; fail "3: the role still reads the raw skip_services"; }
pass "no consumer reads the raw skip_services"

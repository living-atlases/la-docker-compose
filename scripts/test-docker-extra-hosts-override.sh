#!/usr/bin/env bash
# docker_extra_hosts_override replaces single names of the generated docker_extra_hosts_dict.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
python3 - "$ROOT" "$tmp" <<'PY'
import sys,yaml
root,tmp=sys.argv[1:3]
tasks=yaml.safe_load(open(f"{root}/roles/la-compose/tasks/generate-compose.yml"))
t=[x for x in tasks if x.get("name")=="Apply docker_extra_hosts_override"]
assert len(t)==1, "task not found"
yaml.safe_dump([{"hosts":"localhost","connection":"local","gather_facts":False,
 "vars":{"docker_extra_hosts_dict":{"datos.gbif.es":"172.16.16.207","auth.gbif.es":"172.16.16.61"}},
 "tasks":[t[0],{"ansible.builtin.debug":{"msg":"{{ docker_extra_hosts_dict | to_json }}"}}]}],open(f"{tmp}/pb.yml","w"))
PY
pass=0; fail=0
out=$(ansible-playbook "$tmp/pb.yml" -i localhost, -e '{"docker_extra_hosts_override":{"datos.gbif.es":"193.146.75.109"}}' 2>&1)
echo "$out" | grep -q '193.146.75.109' && echo "$out" | grep -q '172.16.16.61' && ! echo "$out" | grep -q '172.16.16.207' \
  && { echo "PASS override replaces only the named host"; pass=$((pass+1)); } || { echo "FAIL override"; fail=$((fail+1)); }
out=$(ansible-playbook "$tmp/pb.yml" -i localhost, 2>&1)
echo "$out" | grep -q '172.16.16.207' && { echo "PASS no override leaves the dict untouched"; pass=$((pass+1)); } || { echo "FAIL no override"; fail=$((fail+1)); }
echo "== $pass passed, $fail failed"; [ "$fail" -eq 0 ]

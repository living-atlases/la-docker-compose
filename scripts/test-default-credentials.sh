#!/usr/bin/env bash
# assert-no-default-credentials.yml: warns about, and (when required) refuses, services that would
# start with a well-known default password.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok() { echo "PASS $1"; pass=$((pass+1)); }
ko() { echo "FAIL $1"; fail=$((fail+1)); }

cat > "$tmp/pb.yml" <<EOF
- hosts: localhost
  connection: local
  gather_facts: false
  vars_files: ["$ROOT/roles/la-compose/defaults/main.yml"]
  tasks:
    - ansible.builtin.include_tasks: "$ROOT/roles/la-compose/tasks/assert-no-default-credentials.yml"
EOF
run() { ansible-playbook "$tmp/pb.yml" -i localhost, "$@" >"$tmp/out" 2>&1; }

run -e '{"services_enabled":["geoserver"],"la_require_non_default_credentials":false}'
{ [ $? -eq 0 ] && grep -q "container will start with" "$tmp/out"; } && ok "unset password warns but does not fail when not required" || ko "warn-only case"
run -e '{"services_enabled":["geoserver"],"la_require_non_default_credentials":true}'
[ $? -ne 0 ] && grep -q "CREDENTIAL GATE" "$tmp/out" && ok "unset password fails when required" || ko "unset+required should fail"
run -e '{"services_enabled":["geoserver"],"la_require_non_default_credentials":true,"geoserver_password":"geoserver"}'
[ $? -ne 0 ] && ok "the literal default fails when required" || ko "default literal should fail"
run -e '{"services_enabled":["geoserver"],"la_require_non_default_credentials":true,"geoserver_password":"s3cr3t-x"}'
[ $? -eq 0 ] && ! grep -q "well-known default\|not set" "$tmp/out" && ok "a real password passes silently" || ko "real password should pass"
run -e '{"services_enabled":["nginx"],"la_require_non_default_credentials":true}'
[ $? -eq 0 ] && ok "a disabled service is not checked" || ko "disabled service should pass"
run -e '{"services_enabled":["geoserver"],"la_env":"production"}'
[ $? -ne 0 ] && ok "la_env=production requires non-default credentials" || ko "production should fail"

echo "== $pass passed, $fail failed"; [ "$fail" -eq 0 ]

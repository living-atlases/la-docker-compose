#!/usr/bin/env bash
# schema-migrations.yml: logger_authorize_ip_list reaches logger's remote_address table.
# logger-service answers 401 to event POSTs from an IP that is not in that table, and
# biocache-service only logs a WARN, so moving it to a new host loses download statistics
# with every health check still green. The ala-install task that fills the table is skipped
# on compose deploys. This runs the real tasks against a stub `docker`:
#   - only the IPs missing from the table are inserted, and a second run inserts nothing;
#   - an empty list, a host without logger-service or a missing table insert nothing;
#   - nothing is ever deleted.
# ~20 s, no Docker needed.
set -u
cd "$(dirname "$0")/.."
REPO=$PWD
ANSIBLE="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}ansible-playbook"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
pass() { printf '[PASS] %s\n' "$*"; }
bad()  { printf '[FAIL] %s\n' "$*" >&2; fail=1; }

mkdir "$T/bin"
cat > "$T/bin/docker" <<'EOF'
#!/bin/sh
echo "$*" >> "$DOCKER_LOG"
case "$*" in
  *information_schema.TABLES*remote_address*) echo "$TABLE_COUNT" ;;
  *"SELECT ip FROM"*) printf '%s\n' $KNOWN_IPS ;;
esac
EOF
chmod +x "$T/bin/docker"

cat > "$T/play.yml" <<EOF
- hosts: localhost
  connection: local
  gather_facts: false
  vars:
    mysql_root_password: fixture
    db_compose_services: {stdout_lines: [mysql]}
  tasks:
    - ansible.builtin.include_tasks: $REPO/roles/la-compose/tasks/schema-migrations.yml
EOF

# run <known ips> <table count> <ip list> <server groups as json>
run() {
  : > "$T/docker.log"
  DOCKER_LOG="$T/docker.log" KNOWN_IPS="$1" TABLE_COUNT="$2" PATH="$T/bin:$PATH" \
    ANSIBLE_LOCALHOST_WARNING=False "$ANSIBLE" -i localhost, "$T/play.yml" \
    -e ansible_become=false -e "logger_authorize_ip_list='$3'" \
    -e "{\"physical_server_groups\": $4}" > "$T/ansible.log" 2>&1 \
    || { cat "$T/ansible.log" >&2; bad "the migrations failed"; }
}
inserted() { grep -o "VALUES ('[^']*'" "$T/docker.log" | cut -d"'" -f2 | sort | tr '\n' ' '; }

run "10.0.0.1" 1 "10.0.0.1, 10.0.0.2,10.0.0.3" '["logger-service"]'
[ "$(inserted)" = "10.0.0.2 10.0.0.3 " ] && pass "only the missing IPs are inserted" \
  || bad "inserted '$(inserted)', expected 10.0.0.2 and 10.0.0.3"
grep -qi "delete" "$T/docker.log" && bad "a migration deleted something" || pass "nothing is deleted"

run "10.0.0.1 10.0.0.2 10.0.0.3" 1 "10.0.0.1, 10.0.0.2,10.0.0.3" '["logger-service"]'
[ -z "$(inserted)" ] && pass "a second run inserts nothing" || bad "second run inserted '$(inserted)'"

run "" 1 "" '["logger-service"]'
[ -z "$(inserted)" ] && pass "an empty list inserts nothing" || bad "empty list inserted '$(inserted)'"

run "" 1 "10.0.0.2" '["collectory"]'
[ -z "$(inserted)" ] && pass "a host without logger-service inserts nothing" \
  || bad "host without logger-service inserted '$(inserted)'"

run "" 0 "10.0.0.2" '["logger-service"]'
[ -z "$(inserted)" ] && pass "a missing table inserts nothing" || bad "missing table inserted '$(inserted)'"

exit $fail

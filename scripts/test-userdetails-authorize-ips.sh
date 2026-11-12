#!/usr/bin/env bash
# schema-migrations.yml: userdetails_authorize_ip_list reaches emmet's authorised_system table.
# userdetails answers 401 to its web-service calls from a host that is not in that table, and
# the callers say nothing a health check would catch: ala-hub's user profile and its saved-fields
# download just come back empty. The ala-install task that fills the table runs auth-ip.sql from
# the userdetails role's vm-tasks.yml, so it is skipped on compose deploys and every host added
# to the stack afterwards needs a manual INSERT. This runs the real tasks against a stub
# `docker`:
#   - only the hosts missing from the table are inserted, and a second run inserts nothing;
#   - an empty list, a host without cas-servers or a missing table insert nothing;
#   - the row matches what auth-ip.sql writes (empty description, version 1);
#   - with logger on the same host the two migrations do not cross: each list reaches its own
#     table and neither spills into the other;
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
# The information_schema probes name the table they ask about, so they have to be matched
# before the plain SELECTs or a probe would answer with a list of hosts.
# One log line per invocation: the tasks fold their SQL over two indented lines, which a bare
# `echo "$*"` would keep, and then no single line carries both the table and its VALUES.
cat > "$T/bin/docker" <<'EOF'
#!/bin/sh
{ echo "$*" | tr '\n' ' '; echo; } >> "$DOCKER_LOG"
case "$*" in
  *information_schema.TABLES*authorised_system*) echo "$AUTH_TABLE_COUNT" ;;
  *information_schema.TABLES*remote_address*)    echo "$LOGGER_TABLE_COUNT" ;;
  *"SELECT host FROM"*) printf '%s\n' $KNOWN_HOSTS ;;
  *"SELECT ip FROM"*)   printf '%s\n' $KNOWN_IPS ;;
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

# run <known hosts> <authorised_system exists 0|1> <userdetails list> <groups json> [logger list] [known ips]
run() {
  : > "$T/docker.log"
  DOCKER_LOG="$T/docker.log" KNOWN_HOSTS="$1" AUTH_TABLE_COUNT="$2" \
  KNOWN_IPS="${6-}" LOGGER_TABLE_COUNT=1 PATH="$T/bin:$PATH" \
    ANSIBLE_LOCALHOST_WARNING=False "$ANSIBLE" -i localhost, "$T/play.yml" \
    -e ansible_become=false -e "userdetails_authorize_ip_list='$3'" \
    -e "logger_authorize_ip_list='${5-}'" \
    -e "{\"physical_server_groups\": $4}" > "$T/ansible.log" 2>&1 \
    || { cat "$T/ansible.log" >&2; bad "the migrations failed"; }
}
# The first quoted value of an INSERT aimed at one table, so the two migrations never
# get counted as each other.
inserted_into() {
  grep "INSERT INTO [a-z_]*\.$1" "$T/docker.log" \
    | grep -o "VALUES ('[^']*'" | cut -d"'" -f2 | sort | tr '\n' ' '
}
auth() { inserted_into authorised_system; }

run "10.0.0.1" 1 "10.0.0.1, 10.0.0.2,10.0.0.3" '["cas-servers"]'
[ "$(auth)" = "10.0.0.2 10.0.0.3 " ] && pass "only the missing hosts are inserted" \
  || bad "inserted '$(auth)', expected 10.0.0.2 and 10.0.0.3"
grep -qi "delete" "$T/docker.log" && bad "a migration deleted something" || pass "nothing is deleted"
# auth-ip.sql writes (host, '', 1); a row that differs would make the two sources disagree.
if grep -q "authorised_system (host, description, version)" "$T/docker.log" \
   && grep -q "VALUES ('10.0.0.2', '', 1)" "$T/docker.log"; then
  pass "the row matches what auth-ip.sql writes: empty description, version 1"
else
  bad "the inserted row does not match auth-ip.sql: $(grep -o "authorised_system.*" "$T/docker.log" | head -1)"
fi

run "10.0.0.1 10.0.0.2 10.0.0.3" 1 "10.0.0.1, 10.0.0.2,10.0.0.3" '["cas-servers"]'
[ -z "$(auth)" ] && pass "a second run inserts nothing" || bad "second run inserted '$(auth)'"

run "" 1 "" '["cas-servers"]'
[ -z "$(auth)" ] && pass "an empty list inserts nothing" || bad "empty list inserted '$(auth)'"

run "" 1 "10.0.0.2" '["collectory"]'
[ -z "$(auth)" ] && pass "a host without cas-servers inserts nothing" \
  || bad "host without cas-servers inserted '$(auth)'"

run "" 0 "10.0.0.2" '["cas-servers"]'
[ -z "$(auth)" ] && pass "a missing table inserts nothing" || bad "missing table inserted '$(auth)'"

# Both services on one host: each list has to land in its own table and nowhere else.
run "" 1 "10.2.0.1" '["cas-servers", "logger-service"]' "10.1.0.1" ""
if [ "$(auth)" = "10.2.0.1 " ] && [ "$(inserted_into remote_address)" = "10.1.0.1 " ]; then
  pass "with logger on the same host each list reaches only its own table"
else
  bad "the two migrations crossed: authorised_system got '$(auth)', remote_address got '$(inserted_into remote_address)'"
fi

exit $fail

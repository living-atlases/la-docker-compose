#!/usr/bin/env bash
# roles/docker-housekeeping/tasks/auditd.yml: a CIS image leaves auditd on keep_logs
# (audit.log.N never deleted) and halt (host powered off when / fills); on
# gbif-es-docker-cluster-2023 that was ~1 GB on a 29 GB root. The role warns by
# default and only edits auditd.conf when the portal opts in. Runs the real tasks
# against a temp auditd.conf with a shimmed `service`:
#   1. no auditd.conf -> nothing, no warning;
#   2. keep_logs + halt, not opted in -> warning, file untouched, no reload;
#   3. opted in -> rotate + syslog, one reload; a second run changes nothing;
#   4. already on rotate -> no warning.
# ~15s, no root, no auditd.
set -eu
cd "$(dirname "$0")/.."
ANSIBLE_PLAYBOOK="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}ansible-playbook"
command -v "$ANSIBLE_PLAYBOOK" >/dev/null || ANSIBLE_PLAYBOOK=ansible-playbook
# Modules run under the python that runs ansible-playbook (the venv's), see #429.
PYARG='ansible_python_interpreter={{ ansible_playbook_python }}'

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
conf="$tmp/auditd.conf"

cat >"$tmp/play.yml" <<YML
- hosts: localhost
  connection: local
  gather_facts: false
  vars_files:
    - $PWD/roles/docker-housekeeping/defaults/main.yml
  tasks:
    - ansible.builtin.import_tasks: $PWD/roles/docker-housekeeping/tasks/auditd.yml
YML

mkdir -p "$tmp/bin"
cat >"$tmp/bin/service" <<SH
#!/bin/sh
echo "\$*" >>"$tmp/service-calls"
SH
chmod +x "$tmp/bin/service"

run() {
  : >"$tmp/service-calls"
  PATH="$tmp/bin:$PATH" ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_NOCOLOR=1 \
    "$ANSIBLE_PLAYBOOK" -i localhost, -e "$PYARG" -e "docker_housekeeping_auditd_conf=$conf" \
    "$@" "$tmp/play.yml" >"$tmp/out" 2>&1 || { cat "$tmp/out" >&2; fail "playbook failed: $*"; }
}
changed() { sed -n 's/.*changed=\([0-9]*\).*/\1/p' "$tmp/out" | head -1; }

cis_conf() {
  cat >"$conf" <<'CONF'
log_file = /var/log/audit/audit.log
max_log_file = 10
num_logs = 5
max_log_file_action = keep_logs
space_left = 75
space_left_action = email
admin_space_left_action = halt
disk_full_action = halt
CONF
}

run
! grep -q "WARNING: auditd" "$tmp/out" || fail "no auditd.conf: warned anyway"
[ "$(changed)" = 0 ] || fail "no auditd.conf: changed=$(changed)"
pass "a host without auditd is left alone"

cis_conf
cp "$conf" "$tmp/before"
run
grep -q "WARNING: auditd" "$tmp/out" || fail "keep_logs+halt: no warning"
grep -q "keep_logs" "$tmp/out" && grep -q "halt" "$tmp/out" || fail "keep_logs+halt: warning does not name both"
cmp -s "$conf" "$tmp/before" || fail "not opted in: auditd.conf was modified"
[ ! -s "$tmp/service-calls" ] || fail "not opted in: auditd was reloaded"
pass "keep_logs + halt without opt-in: warns and touches nothing"

run -e docker_housekeeping_auditd_rotate=true
for kv in "max_log_file = 50" "num_logs = 5" "max_log_file_action = rotate" \
  "disk_full_action = syslog" "admin_space_left_action = syslog" "space_left_action = email"; do
  grep -qx "$kv" "$conf" || fail "opt-in: missing '$kv' in $(tr '\n' ';' <"$conf")"
done
! grep -qiE '^(max_log_file_action = keep_logs|.*= halt)$' "$conf" || fail "opt-in: keep_logs/halt left in place"
[ "$(wc -l <"$conf")" -eq 8 ] || fail "opt-in: lines were added instead of replaced"
grep -qx "auditd reload" "$tmp/service-calls" || fail "opt-in: auditd was not reloaded"
! grep -q "WARNING: auditd" "$tmp/out" || fail "opt-in: still warned"
pass "opt-in switches to rotate + syslog in place and reloads auditd"

run -e docker_housekeeping_auditd_rotate=true
[ "$(changed)" = 0 ] || fail "opt-in second run: changed=$(changed)"
[ ! -s "$tmp/service-calls" ] || fail "opt-in second run: reloaded again"
pass "a second opted-in run changes nothing"

run
! grep -q "WARNING: auditd" "$tmp/out" || fail "rotate: warned anyway"
pass "an auditd already on rotate gets no warning"
echo "All checks passed."

#!/usr/bin/env bash
# validate-postfix-relay.yml against a real boky/postfix, the way gbif.es -3 lost its relay:
#   1. main.cf (a volume) has an active myhostname from an earlier start, and this start gets
#      HOSTNAME="" -> boky logs the relay but main.cf has no relayhost: the check restarts the
#      container once, the relay is back, the task reports changed;
#   2. the same container again -> ok, nothing restarted;
#   3. a relay that differs from the rendered one even after the restart -> the task fails;
#   4. no postfix container on the host -> skipped, ok.
# Needs Docker and the boky/postfix image (pulled if missing); ~2 min. Its containers and
# volume are removed on exit.
set -u
cd "$(dirname "$0")/.."
ROLES="$PWD/roles"
ANSIBLE_PLAYBOOK="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}ansible-playbook"
command -v "$ANSIBLE_PLAYBOOK" >/dev/null || ANSIBLE_PLAYBOOK=ansible-playbook
docker info >/dev/null 2>&1 || { echo "[SKIP] no Docker here"; exit 0; }
IMG="boky/postfix:$(sed -n "s/.*postfix_version | default('\([^']*\)').*/\1/p" roles/la-compose/templates/docker-compose/infrastructure/postfix.yml.j2)"
T=$(mktemp -d); C=pfxrelaytest$$; V=pfxrelaytest$$vol
trap 'docker rm -f "$C" >/dev/null 2>&1; docker volume rm "$V" >/dev/null 2>&1; rm -rf "$T"' EXIT
fail=0
ok()  { echo "[PASS] $1"; }
bad() { echo "[FAIL] $1" >&2; fail=1; }
RELAY='[smtp.example.org]:587'
# The compose file's healthcheck, faster: the check waits for healthy before it reads main.cf.
pfx() { docker run -d --name "$C" -v "$V:/etc/postfix" -e ALLOWED_SENDER_DOMAINS=example.org \
  --health-cmd "nc -w 3 127.0.0.1 25 </dev/null | grep -q '^220'" --health-interval 3s --health-start-period 5s \
  "$@" "$IMG" >/dev/null; }
relay_now() { docker exec "$C" postconf -h relayhost; }

cat > "$T/play.yml" <<YML
- hosts: localhost
  gather_facts: false
  tasks:
    - ansible.builtin.include_role:
        name: la-compose
        tasks_from: validate-postfix-relay.yml
YML
run() { ANSIBLE_ROLES_PATH="$ROLES" ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_NOCOLOR=1 \
  "$ANSIBLE_PLAYBOOK" -i localhost, -c local -e ansible_become=false -e "postfix_container_name=$C" \
  -e postfix_relay_check_timeout=60 -e email_sender=a@example.org -e email_sender_password=p \
  -e 'ansible_python_interpreter={{ ansible_playbook_python }}' "$@" "$T/play.yml" >"$T/run.log" 2>&1; }
recap() { grep -oE 'changed=[0-9]+ +unreachable=[0-9]+ +failed=[0-9]+' "$T/run.log" | tr -s ' '; }

docker image inspect "$IMG" >/dev/null 2>&1 || docker pull -q "$IMG" >/dev/null
# An earlier start that wrote an active myhostname into the volume.
pfx -e HOSTNAME=old.example.org; sleep 8; docker rm -f "$C" >/dev/null
pfx -e HOSTNAME= -e "RELAYHOST=$RELAY" -e RELAYHOST_USERNAME=a@example.org -e RELAYHOST_PASSWORD=p; sleep 8
[ -z "$(relay_now)" ] || echo "[INFO] boky kept the relay this time: case 1 does not exercise the restart"

run -e "email_sender_server=$RELAY"
[ "$(recap)" = "changed=1 unreachable=0 failed=0" ] && [ "$(relay_now)" = "$RELAY" ] && grep -q "FIXED by one restart" "$T/run.log" &&
  ok "a relay boky dropped is caught, one restart brings it back, the task reports changed" ||
  { bad "case 1: $(recap), relay now '$(relay_now)'"; cat "$T/run.log" >&2; }

run -e "email_sender_server=$RELAY"
[ "$(recap)" = "changed=0 unreachable=0 failed=0" ] && grep -qF "OK: relayhost='$RELAY'" "$T/run.log" &&
  ok "the right relay: ok, no restart" || { bad "case 2: $(recap)"; cat "$T/run.log" >&2; }

run -e "email_sender_server=[other.example.org]:25"
[ "$(recap)" = "changed=0 unreachable=0 failed=1" ] && grep -q "STILL WRONG after a restart" "$T/run.log" &&
  ok "a relay still wrong after the restart fails the deploy" || { bad "case 3: $(recap)"; cat "$T/run.log" >&2; }

docker rm -f "$C" >/dev/null
run -e "email_sender_server=$RELAY"
[ "$(recap)" = "changed=0 unreachable=0 failed=0" ] && grep -q "SKIP: $C is not running" "$T/run.log" &&
  ok "no postfix container: skipped" || { bad "case 4: $(recap)"; cat "$T/run.log" >&2; }

exit $fail

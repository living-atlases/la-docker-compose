#!/usr/bin/env bash
# The apply phase of the config-change restart used to look for the container by the name
# la_<service>. namematching's container is la_namematching_service, so the lookup never
# found it, printed "SKIP no-container" on every deploy, and a corrected groups.json stayed
# on disk while the service kept serving the old groups from memory (#456: every bird still
# tagged "Fishes" after the right file had been deployed). The id must come from compose.
# Runs the shell of the real task against a stand-in docker.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"; pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }

python3 - "$ROOT" "$tmp" <<'PY'
import sys, yaml, jinja2
root, tmp = sys.argv[1:3]
tasks = yaml.safe_load(open(f"{root}/roles/la-compose/tasks/config-restart-apply.yml"))
t = [x for x in tasks if x.get("name") == "Config-apply: restart services whose config changed"]
assert len(t) == 1, "task not found"
for item in ("namematching-service", "biocache-service"):
    open(f"{tmp}/{item}.sh", "w").write(jinja2.Template(t[0]["ansible.builtin.shell"]).render(item=item, config_preup_epoch=2_000_000_000))
PY

# compose knows the real container; its name is NOT la_<service>
cat > "$tmp/bin/docker" <<EOF
#!/bin/bash
echo "\$*" >>"$tmp/calls"
case "\$*" in
  "compose ps -q namematching-service") echo cid-nm ;;
  "inspect -f {{.State.StartedAt}} cid-nm") echo 2020-01-01T00:00:00Z ;;
  "inspect -f {{.State.StartedAt}} la_namematching-service") exit 1 ;;   # the guessed name never existed
  "compose ps -q biocache-service") ;;                                   # not on this host
  "compose restart"*) ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/docker"
run() { (cd "$tmp" && PATH="$tmp/bin:$PATH" bash "$tmp/$1.sh" 2>&1); }

out=$(run namematching-service)
[ "$out" = RESTARTED ] && ok "a container named la_namematching_service is found through compose and restarted" || bad "namematching: $out"
grep -qx 'compose restart namematching-service' "$tmp/calls" && ok "it restarts the compose service" || bad "no compose restart call"

: > "$tmp/calls"
out=$(run biocache-service)
[ "$out" = "SKIP no-container" ] && ok "a service with no container on this host is skipped" || bad "absent service: $out"
grep -q 'compose restart' "$tmp/calls" && bad "restarted a service that has no container" || ok "and nothing is restarted"

# a container compose up has just recreated is not restarted a second time
sed -i 's/2020-01-01T00:00:00Z/2099-01-01T00:00:00Z/' "$tmp/bin/docker"; : > "$tmp/calls"
out=$(run namematching-service)
[ "$out" = "SKIP recreated-by-compose-up" ] && ok "a container recreated by compose up is left alone" || bad "recreated: $out"

# The task itself must survive Ansible's argument splitting: a free-form shell body whose first
# line is a comment with an apostrophe died with "unbalanced jinja2 block or quotes" in #457,
# which no shell-level test sees. Run the real task, no docker on PATH => "SKIP no-container".
if command -v ansible-playbook >/dev/null 2>&1; then
  cat > "$tmp/pb.yml" <<PB
- hosts: localhost
  connection: local
  gather_facts: false
  vars: {docker_compose_data_dir: /tmp, config_changed_services: [la_x], config_preup_epoch: 1}
  tasks:
    - ansible.builtin.include_tasks: $PWD/roles/la-compose/tasks/config-restart-apply.yml
PB
  res=$(ANSIBLE_BECOME=false ansible-playbook "$tmp/pb.yml" 2>&1)
  grep -q 'failed at splitting arguments' <<<"$res" && bad "ansible cannot split the restart task" || ok "ansible parses the restart task"
  grep -q 'SKIP no-container' <<<"$res" && ok "and runs it" || bad "restart task did not run"
else
  echo "skip ansible-playbook not installed"
fi
echo "== $pass passed, $fail failed"; [ "$fail" -eq 0 ]

#!/usr/bin/env bash
# roles/la-compose/tasks/config-files.yml (docker_config_files) against a real .ini inventory,
# with the list in [docker_compose:vars] as a portal writes it: the ini format is the contract.
# Two local "hosts" with their own data_dir and services; no Docker, no root.
#   1. each entry lands only on the host that runs its service, owner and mode as asked;
#   2. a second run changes nothing;
#   3. an entry whose service no host runs is a warning, not a copy;
#   4. a changed src is copied again (the config hash then restarts that service);
#   5. a dest outside a service config dir fails the deploy.
# ~10s.
set -u
cd "$(dirname "$0")/.."
ROLES="$PWD/roles"
ANSIBLE_PLAYBOOK="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}ansible-playbook"
command -v "$ANSIBLE_PLAYBOOK" >/dev/null || ANSIBLE_PLAYBOOK=ansible-playbook
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "[PASS] $1"; }
bad() { echo "[FAIL] $1" >&2; fail=1; }

mkdir -p "$T/inv/files/ala-hub" "$T/inv/files/biocache" \
  "$T/a/ala-hub/config" "$T/a/bie-index/config" "$T/b/biocache/config" "$T/b/ala-hub/config"
echo '{"charts": "es"}' > "$T/inv/files/ala-hub/charts.json"
echo '<p>Hola</p>' > "$T/inv/files/biocache/download-email-es.html"
echo '[{"id": "dr888"}]' > "$T/conservation-lists.json"   # absolute src, outside the inventory
echo '{"charts": "ALA"}' > "$T/a/ala-hub/config/charts.json"  # what ala-install left there
uid=$(id -u); gid=$(id -g)

cat > "$T/inv/hosts.ini" <<INI
[docker_compose]
host-a ansible_connection=local data_dir=$T/a services_enabled='["ala_hub", "bie_index"]'
host-b ansible_connection=local data_dir=$T/b services_enabled='["biocache_service"]'

[docker_compose:vars]
docker_container_uid=$uid
docker_container_gid=$gid
hub_instances=[]
docker_config_files = [{"src": "files/ala-hub/charts.json", "dest": "/data/ala-hub/config/charts.json"}, {"src": "$T/conservation-lists.json", "dest": "/data/bie-index/config/conservation-lists.json"}, {"src": "{{ inventory_dir }}/files/biocache/download-email-es.html", "dest": "/data/biocache/config/download-email-es.html", "mode": "0640"}, {"src": "files/ala-hub/charts.json", "dest": "/data/ala-hubb/config/charts.json"}]
INI
# The portal writes /data/...; each test host has its own data_dir.
sed -i 's#"dest": "/data/#"dest": "{{ data_dir }}/#g' "$T/inv/hosts.ini"

cat > "$T/play.yml" <<YML
- hosts: docker_compose
  gather_facts: false
  tasks:
    - ansible.builtin.include_role:
        name: la-compose
        tasks_from: config-files.yml
YML

run() { ANSIBLE_ROLES_PATH="$ROLES" ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_NOCOLOR=1 \
  "$ANSIBLE_PLAYBOOK" -i "$T/inv/hosts.ini" -e 'ansible_python_interpreter={{ ansible_playbook_python }}' "$T/play.yml" "$@"; }

run >"$T/run1.log" 2>&1 || { cat "$T/run1.log" >&2; echo "[FAIL] first run failed" >&2; exit 1; }

# 1. placement, content, owner, mode
cmp -s "$T/inv/files/ala-hub/charts.json" "$T/a/ala-hub/config/charts.json" &&
  ok "relative src: charts.json replaces ALA's on the hub's host" || bad "charts.json on host-a: $(cat "$T/a/ala-hub/config/charts.json")"
cmp -s "$T/conservation-lists.json" "$T/a/bie-index/config/conservation-lists.json" &&
  ok "absolute src: conservation-lists.json on the bie-index host" || bad "conservation-lists.json missing on host-a"
[ "$(stat -c '%a %u' "$T/b/biocache/config/download-email-es.html" 2>/dev/null)" = "640 $uid" ] &&
  ok "{{ inventory_dir }} src, mode '0640', owner docker_container_uid" ||
  bad "download-email-es.html on host-b: $(stat -c '%a %u' "$T/b/biocache/config/download-email-es.html" 2>&1)"
[ "$(stat -c '%a' "$T/a/bie-index/config/conservation-lists.json")" = 644 ] && ok "default mode 0644" || bad "default mode"
[ ! -e "$T/a/biocache/config/download-email-es.html" ] && [ ! -e "$T/b/ala-hub/config/charts.json" ] &&
  ok "nothing lands on a host that does not run the service (even if its dir exists)" || bad "an entry reached the wrong host"

# 3. orphan entry
grep -q "WARNING docker_config_files: no host of this play runs the service of .*/ala-hubb/config/charts.json" "$T/run1.log" &&
  [ ! -e "$T/a/ala-hubb" ] && ok "an entry for a service no host runs is a warning" || bad "no orphan warning"
[ "$(grep -c 'WARNING docker_config_files' "$T/run1.log")" = 1 ] && ok "the warning is printed once" || bad "warning count"

# 2. idempotent
run >"$T/run2.log" 2>&1 || { cat "$T/run2.log" >&2; bad "second run failed"; }
grep -Eq '^host-a .*changed=0 ' "$T/run2.log" && grep -Eq '^host-b .*changed=0 ' "$T/run2.log" &&
  ok "a second run changes nothing" || bad "second run: $(grep -E '^host-' "$T/run2.log")"

# 4. a changed source is copied again
echo '{"charts": "es", "v": 2}' > "$T/inv/files/ala-hub/charts.json"
run >"$T/run3.log" 2>&1
cmp -s "$T/inv/files/ala-hub/charts.json" "$T/a/ala-hub/config/charts.json" && grep -Eq '^host-a .*changed=1 ' "$T/run3.log" &&
  grep -Eq '^host-b .*changed=0 ' "$T/run3.log" && ok "a changed src is copied again, on its host only" || bad "update: $(grep -E '^host-' "$T/run3.log")"

# 5. a dest outside a config dir fails
if run -e '{"docker_config_files": [{"src": "files/ala-hub/charts.json", "dest": "/etc/charts.json"}]}' >"$T/run4.log" 2>&1; then
  bad "a dest outside a config dir was accepted"
else
  grep -q "dest must be a file inside a service's config dir" "$T/run4.log" && [ ! -e /etc/charts.json ] &&
    ok "a dest outside a config dir fails the deploy" || bad "wrong failure: $(tail -5 "$T/run4.log")"
fi

exit $fail

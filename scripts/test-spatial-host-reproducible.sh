#!/usr/bin/env bash
# Things a spatial host needed by hand after a migration, now driven from the inventory:
#  - <key>_local_config_file installs a service's application-local-config.yml from the inventory;
#  - spatial_hub_views_src / spatial_hub_assets_src copy the hub layout and its files;
#  - geoserver_controlflow writes the data dir's controlflow.properties;
#  - geoserver-init repoints a migrated LayersDB store (host=localhost) to the postgres container,
#    and leaves a correct one alone.
# The two tasks are extracted from the role by name and run with real ansible (become stripped);
# the init script is rendered and run against a stub curl.
set -eu
cd "$(dirname "$0")/.."
repo=$PWD
ANSIBLE_PLAYBOOK=${ANSIBLE_PLAYBOOK:-$(command -v ansible-playbook || echo .venv-molecule/bin/ansible-playbook)}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "[PASS] $1"; }
ko() { echo "[FAIL] $1"; fail=1; }

python3 - "$repo/roles/la-compose/tasks" "$tmp/tasks.yml" <<'EOF'
import sys, yaml
d, out = sys.argv[1], sys.argv[2]
def walk(ts):
    for t in ts or []:
        yield t
        yield from walk(t.get('block'))
want = {"Install application-local-config.yml from the inventory (<key>_local_config_file)",
        "Install spatial-hub views / assets from the inventory (spatial_hub_views_src / _assets_src)",
        "Geoserver init: control-flow rules (geoserver_controlflow)"}
got = [t for f in ('main.yml', 'init-geoserver.yml') for t in walk(yaml.safe_load(open(f'{d}/{f}'))) if t.get('name') in want]
assert len(got) == 3, [t['name'] for t in got]
for t in got: t.pop('become', None)
yaml.safe_dump(got, open(out, 'w'), sort_keys=False)
EOF

# --- local config + controlflow ---
mkdir -p "$tmp/inv/files" "$tmp/data/spatial-hub/config" "$tmp/data/spatial-service/config" "$tmp/data/geoserver_data_dir"
printf 'startup:\n  baselayers: {default: osm}\n' > "$tmp/inv/files/hub-local.yml"
echo 'old: placeholder' > "$tmp/data/spatial-hub/config/application-local-config.yml"
echo 'hand: edit' > "$tmp/data/spatial-service/config/application-local-config.yml"
mkdir -p "$tmp/inv/files/views/layouts" "$tmp/inv/files/assets/css" "$tmp/data/spatial-hub/assets"
echo '<html/>' > "$tmp/inv/files/views/layouts/portal-x.gsp"
echo 'png' > "$tmp/inv/files/assets/icon_contextual-layer.png"
echo 'a{}' > "$tmp/inv/files/assets/css/x.css"
echo 'keep' > "$tmp/data/spatial-hub/assets/hand.txt"
cat > "$tmp/play.yml" <<EOF
- hosts: all
  gather_facts: false
  vars:
    data_dir: $tmp/data
    docker_container_uid: "$(id -u)"
    docker_container_gid: "$(id -g)"
  tasks:
    - ansible.builtin.import_tasks: $tmp/tasks.yml
EOF
printf 'localhost ansible_connection=local ansible_python_interpreter=%s\n' "$(command -v python3)" > "$tmp/inv/hosts.ini"
"$ANSIBLE_PLAYBOOK" -i "$tmp/inv/hosts.ini" "$tmp/play.yml" \
  -e '{"services_enabled": ["spatial", "spatial_service", "geoserver"]}' \
  -e "spatial_hub_local_config_file={{ inventory_dir }}/files/hub-local.yml" \
  -e "spatial_hub_views_src={{ inventory_dir }}/files/views" -e "spatial_hub_assets_src={{ inventory_dir }}/files/assets" \
  -e '{"geoserver_controlflow": {"ows.wms.getmap": 16, "ip": 40, "user.ows.wps.execute": "1000/d;30s"}}' \
  > "$tmp/log" 2>&1 || { ko "playbook failed"; tail -30 "$tmp/log"; exit 1; }
cmp -s "$tmp/inv/files/hub-local.yml" "$tmp/data/spatial-hub/config/application-local-config.yml" \
  && ok "spatial_hub_local_config_file replaces the placeholder" || ko "hub local config not installed"
grep -qx 'hand: edit' "$tmp/data/spatial-service/config/application-local-config.yml" \
  && ok "unset spatial_service_local_config_file leaves the host file alone" || ko "spatial-service file touched"
[ -f "$tmp/data/spatial-hub/views/layouts/portal-x.gsp" ] && [ -f "$tmp/data/spatial-hub/assets/css/x.css" ] \
  && [ -f "$tmp/data/spatial-hub/assets/icon_contextual-layer.png" ] && ok "views/assets copied from the inventory" || ko "views/assets not copied"
[ -f "$tmp/data/spatial-hub/assets/hand.txt" ] && ok "host-only asset kept" || ko "host-only asset removed"
cf="$tmp/data/geoserver_data_dir/controlflow.properties"
if [ "$(grep -v '^#' "$cf" | tr '\n' ' ')" = "ip=40 ows.wms.getmap=16 user.ows.wps.execute=1000/d;30s " ]; then
  ok "controlflow.properties from geoserver_controlflow"; else ko "controlflow: $(cat "$cf")"; fi

rm "$cf"
"$ANSIBLE_PLAYBOOK" -i "$tmp/inv/hosts.ini" "$tmp/play.yml" -e '{"services_enabled": []}' > "$tmp/log" 2>&1 \
  || { ko "playbook (unset) failed"; tail -30 "$tmp/log"; }
[ ! -e "$cf" ] && ok "unset geoserver_controlflow writes nothing" || ko "controlflow written while unset"

# --- geoserver-init LayersDB repoint ---
mkdir -p "$tmp/r/roles/r/tasks" "$tmp/bin" "$tmp/gs"
ln -s "$repo/roles/la-compose/templates" "$tmp/r/roles/r/templates"
cat > "$tmp/r/roles/r/tasks/main.yml" <<'EOF'
- ansible.builtin.template: {src: geoserver-init.sh.j2, dest: "{{ out }}/geoserver-init.sh"}
EOF
printf -- '- hosts: all\n  gather_facts: false\n  roles: [r]\n' > "$tmp/r/play.yml"
"$ANSIBLE_PLAYBOOK" -i "$tmp/inv/hosts.ini" "$tmp/r/play.yml" -e out="$tmp/gs" -e layers_db_password=x \
  > "$tmp/log" 2>&1 || { ko "init render failed"; tail -30 "$tmp/log"; exit 1; }
# Stub curl: LayersDB existence/content from $STORE ("" = missing, else its host); logs writes.
cat > "$tmp/bin/curl" <<'EOF'
#!/bin/sh
url=; method=GET; w=
for a in "$@"; do case "$a" in http*) url=$a;; -X*) method=${a#-X};; %\{http_code\}) w=1;; esac; done
case "$method" in POST|PUT) case "$url" in *datastores*) [ -z "${url##*/featuretypes*}" ] || echo "$method $url" >> "$CURL_LOG";; esac;; esac
case "$url" in
  */datastores/LayersDB.xml) [ -n "$STORE" ] && echo "<dataStore><connectionParameters><entry key=\"host\">$STORE</entry></connectionParameters></dataStore>";;
  */datastores/LayersDB) [ -n "$w" ] && { [ -n "$STORE" ] && printf 200 || printf 404; };;
  *) [ -n "$w" ] && printf 200;;
esac
exit 0
EOF
chmod +x "$tmp/bin/curl"
init() { : > "$tmp/calls"; STORE=$1 CURL_LOG="$tmp/calls" PATH="$tmp/bin:$PATH" sh "$tmp/gs/geoserver-init.sh" > /dev/null 2>&1; cat "$tmp/calls"; }
c=$(init ""); case "$c" in "POST "*/workspaces/ALA/datastores) ok "missing store -> POST";; *) ko "missing store: '$c'";; esac
c=$(init localhost); case "$c" in "PUT "*/datastores/LayersDB) ok "host=localhost -> PUT repoint";; *) ko "localhost store: '$c'";; esac
c=$(init postgres); [ -z "$c" ] && ok "host=postgres -> untouched" || ko "postgres store rewritten: '$c'"
exit $fail

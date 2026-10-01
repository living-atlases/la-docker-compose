#!/usr/bin/env bash
# A portal with its own spatial-hub layout (skin.layout -> /data/spatial-hub/views/layouts/<x>.gsp,
# as gbif-es runs it on VMs) rendered unstyled in docker: the hub only mounted the views dir for the
# Living Atlas skin, and the files the layout loads with <asset:*> tags 404 because the hub cannot
# copy /data/spatial-hub/assets into a jar. spatial_hub_external_views mounts both into the hub;
# spatial_hub_extra_assets makes nginx (which must see the dir at the same path) serve those files.
# Runs real ansible so the role defaults and inventory precedence are exercised.
set -eu
cd "$(dirname "$0")/.."
repo=$PWD
ANSIBLE_PLAYBOOK=${ANSIBLE_PLAYBOOK:-$(command -v ansible-playbook || echo .venv-molecule/bin/ansible-playbook)}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/roles/r/tasks"
ln -s "$repo/roles/la-compose/defaults" "$tmp/roles/r/defaults"
ln -s "$repo/roles/la-compose/templates" "$tmp/roles/r/templates"
cat > "$tmp/roles/r/tasks/main.yml" <<'EOF'
- ansible.builtin.template:
    src: docker-compose/services/spatial-hub.yml.j2
    dest: "{{ out }}/hub.yml"
EOF
cat > "$tmp/play.yml" <<'EOF'
- hosts: all
  gather_facts: false
  vars: {data_dir: /data, datastore_endpoints: {}, services_enabled: [spatial]}
  roles: [r]
EOF

fail=0
run() {  # label, inventory host vars
  printf 'localhost ansible_connection=local ansible_python_interpreter=%s %s\n' "$(command -v python3)" "$2" > "$tmp/inv.ini"
  if ! "$ANSIBLE_PLAYBOOK" -i "$tmp/inv.ini" "$tmp/play.yml" -e out="$tmp" > "$tmp/log" 2>&1; then
    echo "[FAIL] $1: render failed"; tail -20 "$tmp/log"; fail=1; return 1
  fi
  python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$tmp/hub.yml" || { echo "[FAIL] $1: not valid YAML"; fail=1; }
}
has() {  # label, expect(yes|no), mount
  if grep -qF -- "- $3" "$tmp/hub.yml"; then got=yes; else got=no; fi
  if [ "$got" = "$2" ]; then echo "[PASS] $1: $3 mounted=$2"; else echo "[FAIL] $1: $3 mounted=$got, want $2"; fail=1; fi
}

if run "default" ""; then
  has "default" no "/data/spatial-hub/views:/data/spatial-hub/views:ro"
  has "default" no "/data/spatial-hub/assets:/data/spatial-hub/assets:ro"
fi
if run "external views" "spatial_hub_external_views=true"; then
  has "external views" yes "/data/spatial-hub/views:/data/spatial-hub/views:ro"
  has "external views" yes "/data/spatial-hub/assets:/data/spatial-hub/assets:ro"
fi

# nginx: the alias map entry only appears with spatial_hub_extra_assets.
map() {  # extra_assets json -> the dirs nginx would mount for a spatial-hub host
  python3 - "$1" <<'EOF'
import json, re, sys
src = open("roles/la-compose/templates/docker-compose/infrastructure/nginx.yml.j2").read()
m = re.search(r"'spatial-hub':\s*(\(.*?\)),\n", src, re.S)
expr = m.group(1)
import jinja2
env = jinja2.Environment()
print(json.dumps(env.from_string("{{ " + expr + " }}").render(
    data_dir="/data", spatial_hub_extra_assets=json.loads(sys.argv[1]))))
EOF
}
got=$(map '[]'); [ "$got" = '"[]"' ] && echo "[PASS] nginx: no extra assets -> no mount" || { echo "[FAIL] nginx: no extra assets -> $got"; fail=1; }
got=$(map '["css/x.css"]'); case $got in *'/data/spatial-hub/assets'*) echo "[PASS] nginx: extra assets -> /data/spatial-hub/assets";; *) echo "[FAIL] nginx: extra assets -> $got"; fail=1;; esac

# ala-install spatial-hub role: one alias location per listed asset.
paths=$(python3 - <<'PY'
import json, re, yaml, jinja2
tasks = yaml.safe_load(open("ala-install/ansible/roles/spatial-hub/tasks/main.yml"))
t = next(t for t in tasks if t.get("name") == "Serve the portal's own hub assets from nginx")
env = jinja2.Environment()
env.filters["regex_replace"] = lambda v, p, r="": re.sub(p, r, v)
out = env.from_string(t["vars"]["nginx_paths"]).render(
    spatial_hub_extra_assets=["css/x-extra.css"], spatial_hub_context_path="/", data_dir="/data")
print(json.dumps(yaml.safe_load(out)))
PY
)
want='[{"path": "/assets/css/x-extra.css", "sort_label": "2-css-x-extra-css", "is_proxy": false, "alias": "/data/spatial-hub/assets/css/x-extra.css"}]'
[ "$paths" = "$want" ] && echo "[PASS] role: nginx_paths $paths" || { echo "[FAIL] role: nginx_paths $paths, want $want"; fail=1; }
exit $fail

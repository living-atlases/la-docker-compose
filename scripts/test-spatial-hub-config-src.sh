#!/usr/bin/env bash
# Every deploy re-templated menu-config.json / view-config.json / spatial-hub-config.yml from
# the ala-install role, wiping a portal's own (translated) menus. The role now takes an
# inventory file per config (spatial_hub_menu_config_json, spatial_hub_view_config_json,
# spatial_hub_config_yml). Runs the real role tasks: without the vars the role templates
# are used; with them, the portal's files land in the config dir.
set -eu
cd "$(dirname "$0")/.."
repo=$PWD
ANSIBLE_PLAYBOOK=${ANSIBLE_PLAYBOOK:-$(command -v ansible-playbook || echo .venv-molecule/bin/ansible-playbook)}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/files"
echo '[{"name": "Añadir", "items": []}]' > "$tmp/files/menu-config.json"
# The role's spatial-hub-config.yml needs a whole portal inventory to render; a portal file
# for it keeps this test self-contained and covers spatial_hub_config_yml too.
echo 'skin.layout: portal-test' > "$tmp/files/spatial-hub-config.yml"
cat > "$tmp/play.yml" <<EOF
- hosts: all
  gather_facts: true
  vars_files:
    - $repo/ala-install/ansible/group_vars/all/vars.yml
  tasks:
    - ansible.builtin.include_role:
        name: $repo/ala-install/ansible/roles/spatial-hub
        apply: {tags: [spatial-hub-config]}
      tags: [always]
EOF

fail=0
run() {  # label, extra args...
  local label=$1; shift
  rm -rf "$tmp/data"
  printf 'localhost ansible_connection=local ansible_python_interpreter=%s\n' "$(command -v python3)" > "$tmp/inv.ini"
  if ! "$ANSIBLE_PLAYBOOK" -i "$tmp/inv.ini" "$tmp/play.yml" --tags spatial-hub-config \
      -e data_dir="$tmp/data" -e tomcat_user="$(id -un)" -e spatial_hub_portal=default \
      -e webserver_nginx=false -e deployment_type=container -e skip_handlers=true \
      -e spatial_hub_config_yml="$tmp/files/spatial-hub-config.yml" "$@" > "$tmp/log" 2>&1; then
    echo "[FAIL] $label: play failed"; tail -20 "$tmp/log"; fail=1; return 1
  fi
}
check() {  # label, file, expected source
  if cmp -s "$tmp/data/spatial-hub/config/$2" "$3"; then echo "[PASS] $1: $2"
  else echo "[FAIL] $1: $2 is not $3"; fail=1; fi
}

roles=ala-install/ansible/roles/spatial-hub/templates/default
if run "role templates"; then
  check "role templates" spatial-hub-config.yml "$tmp/files/spatial-hub-config.yml"
  check "role templates" menu-config.json "$roles/menu-config.json"
  check "role templates" view-config.json "$roles/view-config.json"
fi
if run "portal menu" -e spatial_hub_menu_config_json="$tmp/files/menu-config.json"; then
  check "portal menu" menu-config.json "$tmp/files/menu-config.json"
  check "portal menu" view-config.json "$roles/view-config.json"
fi
exit $fail

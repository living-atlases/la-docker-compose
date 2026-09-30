#!/usr/bin/env bash
# The geoserver image tag used to be a separate knob (geoserver_image_tag, hardcoded
# default 2.23.2) that ignored ala-install's geoserver_version, so an inventory pinned
# for VMs deployed a different -- older -- GeoServer in docker. A GeoServer data dir
# cannot be downgraded. The tag must follow geoserver_version (inventory first, then the
# ala-install geoserver role default), with geoserver_image_tag as explicit override.
# Runs real ansible so variable precedence (role defaults < inventory < -e) is exercised.
set -eu
cd "$(dirname "$0")/.."
repo=$PWD
ANSIBLE_PLAYBOOK=${ANSIBLE_PLAYBOOK:-$(command -v ansible-playbook || echo .venv-molecule/bin/ansible-playbook)}

ala_default=$(sed -n 's/^geoserver_version: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' ala-install/ansible/roles/geoserver/defaults/main.yml)
[ -n "$ala_default" ] || { echo "[FAIL] no geoserver_version in ala-install geoserver defaults" >&2; exit 1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/roles/gs/tasks"
ln -s "$repo/roles/la-compose/defaults" "$tmp/roles/gs/defaults"
cat > "$tmp/roles/gs/tasks/main.yml" <<EOF
- ansible.builtin.template:
    src: $repo/roles/la-compose/templates/docker-compose/services/geoserver.yml.j2
    dest: "{{ out }}"
EOF
cat > "$tmp/play.yml" <<'EOF'
- hosts: all
  gather_facts: false
  vars: {data_dir: /data, datastore_endpoints: {}}
  roles: [gs]
EOF

fail=0
run() {  # label, expected tag, inventory host vars, extra args...
  local label=$1 want=$2 hv=$3; shift 3
  printf 'localhost ansible_connection=local ansible_python_interpreter=%s la_compose_ala_install_dir=%s %s\n' \
    "$(command -v python3)" "$repo/ala-install" "$hv" > "$tmp/inv.ini"
  if ! "$ANSIBLE_PLAYBOOK" -i "$tmp/inv.ini" "$tmp/play.yml" -e out="$tmp/out.yml" "$@" > "$tmp/log" 2>&1; then
    echo "[FAIL] $label: render failed"; tail -20 "$tmp/log"; fail=1; return
  fi
  local got; got=$(sed -n 's/^ *image: *//p' "$tmp/out.yml")
  if [ "$got" = "kartoza/geoserver:$want" ]; then echo "[PASS] $label -> $got"
  else echo "[FAIL] $label: want kartoza/geoserver:$want, got $got"; fail=1; fi
}

run "ala-install default" "$ala_default" ""
run "inventory geoserver_version" "2.25.2" "geoserver_version=2.25.2"
run "inventory geoserver_image_tag override" "2.28.5" "geoserver_version=2.25.2 geoserver_image_tag=2.28.5"
run "-e geoserver_image_tag override" "2.28.5" "geoserver_version=2.25.2" -e geoserver_image_tag=2.28.5
exit $fail

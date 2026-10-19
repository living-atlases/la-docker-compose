#!/usr/bin/env bash
# GeoNetwork is not published by default (geonetwork_public: false): no ALA code reads it
# and 2026-10-19 espacial.gbif.es still served a 3.4.4 catalogue with Log4Shell to the
# internet. Runs the real "Register geonetwork nginx vhost" task's conditions from
# generate-compose.yml with the role defaults (include_role swapped for a marker), so
# precedence (defaults < inventory < -e) applies. ~10s.
set -eu
cd "$(dirname "$0")/.."
repo=$PWD
ANSIBLE_PLAYBOOK=${ANSIBLE_PLAYBOOK:-$(command -v ansible-playbook || echo .venv-molecule/bin/ansible-playbook)}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/roles/gn/tasks"
ln -s "$repo/roles/la-compose/defaults" "$tmp/roles/gn/defaults"
python3 - "$repo" "$tmp/roles/gn/tasks/main.yml" <<'PY'
import sys, yaml
repo, out = sys.argv[1:]
tasks = yaml.safe_load(open(repo + "/roles/la-compose/tasks/generate-compose.yml"))
vhost = [t for t in tasks if t.get("name") == "Register geonetwork nginx vhost (docker-local proxy to container)"]
assert len(vhost) == 1, "geonetwork vhost task not found in generate-compose.yml"
marker = {"name": "vhost marker", "ansible.builtin.copy": {"content": "published\n", "dest": "{{ out }}"},
          "when": vhost[0]["when"]}
yaml.safe_dump([marker], open(out, "w"), sort_keys=False)
PY
cat > "$tmp/play.yml" <<'PLAY'
- hosts: all
  gather_facts: false
  roles: [gn]
PLAY

fail=0
run() {  # label, want (published|internal), inventory host vars, extra args...
  local label=$1 want=$2 hv=$3; shift 3
  printf 'localhost ansible_connection=local ansible_python_interpreter=%s %s\n' "$(command -v python3)" "$hv" > "$tmp/inv.ini"
  rm -f "$tmp/out"
  if ! "$ANSIBLE_PLAYBOOK" -i "$tmp/inv.ini" "$tmp/play.yml" -e out="$tmp/out" "$@" > "$tmp/log" 2>&1; then
    echo "[FAIL] $label: play failed"; tail -20 "$tmp/log"; fail=1; return
  fi
  local got=internal; [ -f "$tmp/out" ] && got=published
  if [ "$got" = "$want" ]; then echo "[PASS] $label -> $got"; else echo "[FAIL] $label: want $want, got $got"; fail=1; fi
}

on='-e {"services_enabled":["geonetwork"]}'
run "role default" internal "geonetwork_hostname=spatial.example.org" $on
run "inventory geonetwork_public=true" published "geonetwork_hostname=spatial.example.org geonetwork_public=true" $on
run "-e geonetwork_public=false over inventory true" internal "geonetwork_hostname=spatial.example.org geonetwork_public=true" $on -e geonetwork_public=false
run "public but service disabled" internal "geonetwork_hostname=spatial.example.org geonetwork_public=true" -e '{"services_enabled":[]}'
run "public without hostname" internal "geonetwork_public=true" $on
exit $fail

#!/usr/bin/env bash
# geonetwork:3.4.4-postgres (the old default) ships log4j-core 2.7 with JndiLookup and a
# JDK 8u181: Log4Shell (CVE-2021-44228/45046, in CISA KEV). The default must be a tag with
# log4j >= 2.17.1, and an inventory pin to an older tag must fail the render instead of
# quietly bringing it back. Runs the real assert task from generate-compose.yml and the
# real template with the role defaults, so precedence (defaults < inventory < -e) applies.
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
guard = [t for t in tasks if "Log4Shell" in str(t.get("name", ""))]
assert len(guard) == 1, "geonetwork Log4Shell guard task not found in generate-compose.yml"
render = {"ansible.builtin.template": {
    "src": repo + "/roles/la-compose/templates/docker-compose/services/geonetwork.yml.j2",
    "dest": "{{ out }}"}}
yaml.safe_dump(guard + [render], open(out, "w"), sort_keys=False)
PY
cat > "$tmp/play.yml" <<'PLAY'
- hosts: all
  gather_facts: false
  vars: {data_dir: /data, datastore_endpoints: {}, services_enabled: [geonetwork], geonetwork_db_password: x}
  roles: [gn]
PLAY

fail=0
run() {  # label, expected image (or FAIL), inventory host vars, extra args...
  local label=$1 want=$2 hv=$3; shift 3
  printf 'localhost ansible_connection=local ansible_python_interpreter=%s la_compose_ala_install_dir=%s %s\n' \
    "$(command -v python3)" "$repo/ala-install" "$hv" > "$tmp/inv.ini"
  rm -f "$tmp/out.yml"
  if "$ANSIBLE_PLAYBOOK" -i "$tmp/inv.ini" "$tmp/play.yml" -e out="$tmp/out.yml" "$@" > "$tmp/log" 2>&1; then
    local got; got=$(sed -n 's/^ *image: *//p' "$tmp/out.yml")
    if [ "$want" = FAIL ]; then echo "[FAIL] $label: rendered $got, want the guard to refuse it"; fail=1
    elif [ "$got" = "$want" ]; then echo "[PASS] $label -> $got"
    else echo "[FAIL] $label: want $want, got $got"; fail=1; fi
    python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$tmp/out.yml" || { echo "[FAIL] $label: not valid YAML"; fail=1; }
  elif [ "$want" = FAIL ] && grep -q "Log4Shell" "$tmp/log"; then echo "[PASS] $label -> refused"
  else echo "[FAIL] $label: render failed"; tail -20 "$tmp/log"; fail=1; fi
}

run "role default" "geonetwork:3.12.12-postgres" ""
run "inventory pin 3.4.4-postgres" FAIL "geonetwork_image_tag=3.4.4-postgres"
run "-e pin 3.10.6-postgres" FAIL "" -e geonetwork_image_tag=3.10.6-postgres
run "inventory pin 3.12.12 (no suffix)" "geonetwork:3.12.12" "geonetwork_image_tag=3.12.12"
run "inventory pin 4.2.8" "geonetwork:4.2.8" "geonetwork_image_tag=4.2.8"
run "non-numeric tag not judged" "geonetwork:latest" "geonetwork_image_tag=latest"
run "own registry" "reg.example/geonetwork:3.12.12-postgres" "geonetwork_registry=reg.example"
run "geonetwork_database reaches the entrypoint" "geonetwork:3.12.12-postgres" "geonetwork_database=gndb"
if grep -q 'POSTGRES_DB_NAME: "gndb"' "$tmp/out.yml"; then echo "[PASS] POSTGRES_DB_NAME follows geonetwork_database"
else echo "[FAIL] POSTGRES_DB_NAME does not follow geonetwork_database"; fail=1; fi
exit $fail

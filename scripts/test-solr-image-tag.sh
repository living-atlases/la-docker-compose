#!/usr/bin/env bash
# Solr 8.0-8.11.0 ship log4j-core with JndiLookup (Log4Shell, CVE-2021-44228/45046, in CISA
# KEV) and Solr logs the params of every query, which biocache-ws/bie/lists pass on from the
# user. Inventories pin solrcloud_version=8.9.0, so a vulnerable 8.x pin must render as the
# patched 8.x image, say so in the play, and an explicit solr_image_tag must still win.
# Renders the real template with the role defaults (defaults < inventory < -e).
set -eu
cd "$(dirname "$0")/.."
repo=$PWD
ANSIBLE_PLAYBOOK=${ANSIBLE_PLAYBOOK:-$(command -v ansible-playbook || echo .venv-molecule/bin/ansible-playbook)}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/roles/solr/tasks"
ln -s "$repo/roles/la-compose/defaults" "$tmp/roles/solr/defaults"
python3 - "$repo" "$tmp/roles/solr/tasks/main.yml" <<'PY'
import sys, yaml
repo, out = sys.argv[1:]
tasks = yaml.safe_load(open(repo + "/roles/la-compose/tasks/generate-compose.yml"))
report = [t for t in tasks if "Solr pins replaced" in str(t.get("name", ""))]
assert len(report) == 1, "Solr Log4Shell report task not found in generate-compose.yml"
render = {"ansible.builtin.template": {
    "src": repo + "/roles/la-compose/templates/docker-compose/infrastructure/solr.yml.j2",
    "dest": "{{ out }}"}}
yaml.safe_dump(report + [render], open(out, "w"), sort_keys=False)
PY
cat > "$tmp/play.yml" <<'PLAY'
- hosts: all
  gather_facts: false
  vars: {data_dir: /data, datastore_endpoints: {}, services_enabled: [solrcloud]}
  roles: [solr]
PLAY

fail=0
run() {  # label, expected image, expect the report (yes/no), inventory host vars, extra args...
  local label=$1 want=$2 report=$3 hv=$4; shift 4
  printf 'localhost ansible_connection=local ansible_python_interpreter=%s la_compose_ala_install_dir=%s %s\n' \
    "$(command -v python3)" "$repo/ala-install" "$hv" > "$tmp/inv.ini"
  rm -f "$tmp/out.yml"
  if ! "$ANSIBLE_PLAYBOOK" -i "$tmp/inv.ini" "$tmp/play.yml" -e out="$tmp/out.yml" "$@" > "$tmp/log" 2>&1; then
    echo "[FAIL] $label: render failed"; tail -20 "$tmp/log"; fail=1; return
  fi
  local got; got=$(sed -n 's/^ *image: *//p' "$tmp/out.yml")
  python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$tmp/out.yml" || { echo "[FAIL] $label: not valid YAML"; fail=1; }
  if [ "$got" != "$want" ]; then echo "[FAIL] $label: want $want, got $got"; fail=1; return; fi
  if [ "$report" = yes ] && ! grep -q "ships a log4j with Log4Shell" "$tmp/log"; then
    echo "[FAIL] $label: swapped the image without saying so"; fail=1; return
  fi
  if [ "$report" = no ] && grep -q "ships a log4j with Log4Shell" "$tmp/log"; then
    echo "[FAIL] $label: reported a swap that did not happen"; fail=1; return
  fi
  echo "[PASS] $label -> $got"
}

run "inventory pin 8.9.0 (generator default)" "solr:8.11.4" yes "solrcloud_version=8.9.0"
run "inventory pin 8.0.0" "solr:8.11.4" yes "solrcloud_version=8.0.0"
run "inventory pin 8.11.0" "solr:8.11.4" yes "solrcloud_version=8.11.0"
run "inventory pin 8.11.1 (log4j 2.16, kept)" "solr:8.11.1" no "solrcloud_version=8.11.1"
run "inventory pin 9.7.0 (kept)" "solr:9.7.0" no "solrcloud_version=9.7.0"
run "no pin: template default" "solr:9.4" no ""
run "non-numeric tag not judged" "solr:latest" no "solrcloud_version=latest"
run "explicit solr_image_tag wins" "solr:8.9.0" no "solrcloud_version=8.9.0 solr_image_tag=8.9.0"
run "-e solrcloud_version 8.9.0" "solr:8.11.4" yes "" -e solrcloud_version=8.9.0
exit $fail

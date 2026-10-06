#!/usr/bin/env bash
# ala-install a81a0b76 replaced species_groups_variant with namematching_groups_file and
# biocache_groups_file, and moved groups-col.json out of the role. Passing the old variable
# became a silent no-op, so the CI went back to ALA's groups.json on a COL index and every
# bird came back tagged "Fishes" (e2e species-groups.cy.ts). The COL file is ours to ship and
# to pass; an inventory that provides its own (gbif.es) must still win.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }

col="$ROOT/roles/la-compose/files/species-groups/groups-col.json"
ala="$ROOT/ala-install/ansible/roles/namematching-service/files/groups.json"
python3 - "$col" "$ala" <<'PY' && ok "groups-col.json keeps exactly ALA's group names (they are i18n codes, a rename breaks translations)" || bad "groups-col.json group names differ from ALA's groups.json"
import json, sys
names = lambda p: [g["name"] for g in json.load(open(p))]
col, ala = names(sys.argv[1]), names(sys.argv[2])
sys.exit(0 if sorted(col) == sorted(ala) else 1)
PY

grep -qE "^[[:space:]]+species_groups_variant:" "$ROOT/roles/la-compose/tasks/generate-compose.yml" \
  && bad "generate-compose.yml still passes species_groups_variant (a no-op since a81a0b76)" \
  || ok "the retired species_groups_variant is gone"
grep -q "namematching_groups_file: \"{{ la_species_groups_file }}\"" "$ROOT/roles/la-compose/tasks/generate-compose.yml" \
  && ok "namematching gets the file" || bad "namematching is not given namematching_groups_file"
grep -q "biocache_groups_file: \"{{ la_biocache_groups_file }}\"" "$ROOT/roles/la-compose/tasks/generate-compose.yml" \
  && ok "biocache gets the file" || bad "biocache is not given biocache_groups_file"

python3 - "$ROOT" "$tmp" <<'PY'
import sys, yaml
root, tmp = sys.argv[1:3]
tasks = yaml.safe_load(open(f"{root}/roles/la-compose/tasks/generate-compose.yml"))
t = [x for x in tasks if x.get("name") == "Pick the species group files that match the name index we load"]
assert len(t) == 1, "task not found"
yaml.safe_dump([{"hosts": "localhost", "connection": "local", "gather_facts": False,
  "tasks": [t[0], {"ansible.builtin.debug": {"msg": "NM={{ la_species_groups_file }} BC={{ la_biocache_groups_file }}"}}]}],
  open(f"{tmp}/pb.yml", "w"))
PY
run() { ansible-playbook "$tmp/pb.yml" -i localhost, -e role_path=/R "$@" 2>&1 | sed -n 's/.*"msg": "\(NM=.*\)".*/\1/p'; }
col_rel=/R/files/species-groups/groups-col.json

[ "$(run)" = "NM=$col_rel BC=$col_rel" ] && ok "no inventory file: both use the shipped COL file" || bad "default: $(run)"
[ "$(run -e namematching_groups_file=/inv/g.json)" = "NM=/inv/g.json BC=/inv/g.json" ] \
  && ok "an inventory namematching file wins, and biocache follows it" || bad "nm override: $(run -e namematching_groups_file=/inv/g.json)"
[ "$(run -e namematching_groups_file=/inv/g.json -e biocache_groups_file=/inv/b.json)" = "NM=/inv/g.json BC=/inv/b.json" ] \
  && ok "an inventory biocache file is kept apart from namematching's" || bad "bc override: $(run -e namematching_groups_file=/inv/g.json -e biocache_groups_file=/inv/b.json)"
echo "== $pass passed, $fail failed"; [ "$fail" -eq 0 ]

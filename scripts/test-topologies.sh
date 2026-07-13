#!/usr/bin/env bash
# Topology matrix (Level 1) — validate every topologies/*.placement.json
# variant against its committed fixture inventory, WITHOUT real hosts or
# docker (resolved-hostvars checks only, seconds per variant).
#
# Per variant:
#   0. Fixture freshness: recompute the variant .yo-rc from base+placement and
#      diff it against the committed fixture .yo-rc (catches edited placements
#      whose fixtures were not regenerated with regen-topology-fixtures.sh).
#   1. Scope-leak check (molecule/multihost/converge.yml): no inter-service
#      dependency var resolving to localhost/127.0.0.1 on any host.
#   2. Topology invariants (playbooks/validate-topology.yml): no orphan
#      service groups, no duplicated public vhosts, single placement per app,
#      private IPs present.
#
# The single-host FULL-RENDER path is covered separately by
# scripts/validate-config-gen.sh against inventories/testing/lademo-inventories
# (fixture hosts here are la-mh-*, not reachable, so no render is possible).
#
# Usage: scripts/test-topologies.sh [variant ...]   (default: all)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
BASE="topologies/base.lademo.yo-rc.json"
FIXTURES="inventories/testing/topologies"
VENV_MOLECULE="${VENV_MOLECULE:-.venv-molecule}"

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
pass() { echo -e "${GREEN}✔ PASS${RESET} $*"; }
fail() { echo -e "${RED}✗ FAIL${RESET} $*"; FAILURES=$((FAILURES + 1)); }
section() { echo -e "\n${CYAN}${BOLD}=== $* ===${RESET}"; }

ANSIBLE_PLAYBOOK="ansible-playbook"
[ -x "${VENV_MOLECULE}/bin/ansible-playbook" ] && ANSIBLE_PLAYBOOK="${VENV_MOLECULE}/bin/ansible-playbook"
export ANSIBLE_ROLES_PATH="roles:ala-install/ansible/roles"

if [ "$#" -gt 0 ]; then
  VARIANTS=("$@")
else
  VARIANTS=()
  for p in topologies/*.placement.json; do
    VARIANTS+=("$(basename "$p" .placement.json)")
  done
fi

FAILURES=0
for variant in "${VARIANTS[@]}"; do
  section "Topology: ${variant}"
  placement="topologies/${variant}.placement.json"
  inv="${FIXTURES}/${variant}/lademo-inventories/lademo-inventory.ini"
  fixture_rc="${FIXTURES}/${variant}/.yo-rc.json"

  if [ ! -f "$placement" ]; then fail "${variant}: no placement file ${placement}"; continue; fi
  if [ ! -f "$inv" ] || [ ! -f "$fixture_rc" ]; then
    fail "${variant}: fixture missing — run scripts/regen-topology-fixtures.sh ${variant} and commit"
    continue
  fi

  # 0. Fixture freshness
  tmp_rc="$(mktemp)"
  if python3 scripts/apply-topology.py apply --base "$BASE" --placement "$placement" --out "$tmp_rc" >/dev/null \
     && python3 -c "
import json, sys
a = json.load(open('$tmp_rc')); b = json.load(open('$fixture_rc'))
sys.exit(0 if a == b else 1)"; then
    pass "${variant}: fixture .yo-rc is up to date with placement"
  else
    fail "${variant}: fixture is STALE — run scripts/regen-topology-fixtures.sh ${variant} and commit"
    rm -f "$tmp_rc"; continue
  fi
  rm -f "$tmp_rc"

  # 1. Scope-leak check
  if "$ANSIBLE_PLAYBOOK" molecule/multihost/converge.yml -i "$inv" --limit docker_compose >/tmp/topo-scope-${variant}.log 2>&1; then
    pass "${variant}: scope-leak check (no localhost in inter-service deps)"
  else
    fail "${variant}: scope-leak check — see /tmp/topo-scope-${variant}.log"
    tail -25 "/tmp/topo-scope-${variant}.log"
  fi

  # 2. Topology invariants
  if "$ANSIBLE_PLAYBOOK" playbooks/validate-topology.yml -i "$inv" --limit docker_compose >/tmp/topo-invariants-${variant}.log 2>&1; then
    pass "${variant}: topology invariants (orphans/vhosts/placement/IPs)"
  else
    fail "${variant}: topology invariants — see /tmp/topo-invariants-${variant}.log"
    tail -25 "/tmp/topo-invariants-${variant}.log"
  fi
done

echo
if [ "$FAILURES" -gt 0 ]; then
  echo -e "${RED}${BOLD}${FAILURES} topology check(s) failed${RESET}"
  exit 1
fi
echo -e "${GREEN}${BOLD}All topology variants passed${RESET}"

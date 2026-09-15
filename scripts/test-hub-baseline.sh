#!/usr/bin/env bash
# Data hub baseline (Level 1): adding a hub must not change what the PORTAL renders.
#
# A hub joins the portal's canonical service groups through [<group>:children], so
# every group-derived fact can mistake a hub alias for the portal running that
# service on that machine. That is the failure class issue #14 is about, and it is
# invisible in a deploy log: the portal simply gets an extra container, an extra
# vhost or a re-pointed variable on a host where it never placed the service.
#
# So: compute the portal's facts from the fixture inventory ALONE, then again with
# the hub inventories added, and require them to be identical. Resolved hostvars
# only -- no render, no docker, no real hosts. Seconds per variant.
#
# Usage: scripts/test-hub-baseline.sh [variant ...]   (default: every variant with hubs)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
FIXTURES="${FIXTURES:-inventories/testing/topologies}"
VENV_MOLECULE="${VENV_MOLECULE:-.venv-molecule}"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
FAILURES=0
pass() { echo -e "${GREEN}✔ PASS${RESET} $*"; }
fail() { echo -e "${RED}✗ FAIL${RESET} $*"; FAILURES=$((FAILURES + 1)); }

ANSIBLE_PLAYBOOK="ansible-playbook"
[ -x "${VENV_MOLECULE}/bin/ansible-playbook" ] && ANSIBLE_PLAYBOOK="${VENV_MOLECULE}/bin/ansible-playbook"
export ANSIBLE_ROLES_PATH="roles:ala-install/ansible/roles"

# The facts every downstream artifact is derived from. services_enabled drives which
# compose fragments and which ala-install roles run; service_aliases decides whose
# variables each role reads; physical_server_groups gates the infrastructure and the
# volumes; the alias list is what nginx serves and what other hosts resolve.
DUMP="$(mktemp -t hub-baseline-play-XXXX.yml)"
cat > "$DUMP" <<'PLAY'
- name: "Hub baseline: dump the portal's group-derived facts"
  hosts: docker_compose
  gather_facts: false
  connection: local
  tasks:
    - ansible.builtin.import_role:
        name: la-compose
        tasks_from: setup-facts.yml
    - ansible.builtin.copy:
        dest: "{{ dump_dir }}/{{ inventory_hostname }}.json"
        mode: "0644"
        content: |
          {{ {
               'services_enabled': services_enabled | sort,
               'physical_server_groups': physical_server_groups | sort,
               'service_aliases': service_aliases,
               'nginx_aliases': (nginx_docker_internal_aliases | default('[]')),
               'portal_instance': (hub_instances | default([])) | selectattr('is_portal') | list,
             } | to_nice_json }}
      delegate_to: localhost
PLAY
trap 'rm -f "$DUMP"' EXIT

if [ "$#" -gt 0 ]; then
  VARIANTS=("$@")
else
  VARIANTS=()
  for d in "${FIXTURES}"/*/; do
    v="$(basename "$d")"
    compgen -G "${d}"'*-inventories/*-inventory.ini' >/dev/null || continue
    # Only variants that actually declare a hub are worth comparing.
    [ "$(ls -d "${d}"*-inventories 2>/dev/null | wc -l)" -gt 1 ] && VARIANTS+=("$v")
  done
  # Discovery globs the fixture tree, so an incomplete checkout (or fixtures that were
  # never regenerated) would silently leave nothing to compare and the script would
  # report success having checked nothing. Same guard as test-compose-includes.sh.
  if [ "${#VARIANTS[@]}" -eq 0 ]; then
    echo -e "${RED}✗ FAIL${RESET} no topology variant carries a data hub inventory under ${FIXTURES}/"
    echo "  The test itself is broken (or the fixtures are missing), not the role:"
    echo "  run scripts/regen-topology-fixtures.sh to rebuild them."
    exit 1
  fi
fi

for variant in "${VARIANTS[@]}"; do
  echo
  echo -e "${CYAN}${BOLD}=== Hub baseline: ${variant} ===${RESET}"
  inv="${FIXTURES}/${variant}/lademo-inventories/lademo-inventory.ini"
  if [ ! -f "$inv" ]; then
    fail "${variant}: portal inventory missing — run scripts/regen-topology-fixtures.sh ${variant}"
    continue
  fi

  hub_args=()
  for hubdir in "${FIXTURES}/${variant}"/*-inventories; do
    hubpkg="$(basename "$hubdir" -inventories)"
    hubinv="${hubdir}/${hubpkg}-inventory.ini"
    [ "$hubinv" = "$inv" ] && continue
    [ -f "$hubinv" ] && hub_args+=(-i "$hubinv")
  done
  if [ "${#hub_args[@]}" -eq 0 ]; then
    fail "${variant}: no hub inventory to compare against"
    continue
  fi

  without="$(mktemp -d)"; with="$(mktemp -d)"
  log="/tmp/hub-baseline-${variant}.log"
  if ! "$ANSIBLE_PLAYBOOK" "$DUMP" -i "$inv" --limit docker_compose \
        -e "dump_dir=${without}" >"$log" 2>&1; then
    fail "${variant}: fact dump WITHOUT hubs failed — see ${log}"
    tail -25 "$log"; rm -rf "$without" "$with"; continue
  fi
  if ! "$ANSIBLE_PLAYBOOK" "$DUMP" -i "$inv" "${hub_args[@]}" --limit docker_compose \
        -e "dump_dir=${with}" >>"$log" 2>&1; then
    fail "${variant}: fact dump WITH hubs failed — see ${log}"
    tail -25 "$log"; rm -rf "$without" "$with"; continue
  fi

  if diff -ru "$without" "$with" >"/tmp/hub-baseline-${variant}.diff" 2>&1; then
    pass "${variant}: the portal's facts are identical with and without its data hubs"
  else
    fail "${variant}: a data hub CHANGED the portal's facts"
    head -40 "/tmp/hub-baseline-${variant}.diff"
  fi
  rm -rf "$without" "$with"
done

echo
if [ "$FAILURES" -gt 0 ]; then
  echo -e "${RED}${BOLD}${FAILURES} hub baseline check(s) failed${RESET}"
  exit 1
fi
echo -e "${GREEN}${BOLD}Every data hub leaves the portal's facts untouched${RESET}"

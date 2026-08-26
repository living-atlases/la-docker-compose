#!/usr/bin/env bash
# Render an ala-install service's config from an inventory, WITHOUT connecting to any host.
#
# Why this exists
# ---------------
# The normal way to obtain a rendered .properties is to run the playbooks, which needs a
# reachable host and writes to that host's /data. That makes three ordinary jobs awkward:
#
#   - checking what a template change actually produces, before deploying it;
#   - comparing what two inventories produce for the same service, key by key;
#   - producing a clean config tree to extract a drift baseline from, rather than reading a
#     live /data that accumulates hand-kept variants (.last, .es, .tests) next to the real file.
#
# So this resolves host variables offline (`ansible-inventory --host` never connects) and
# renders the role's Jinja templates from a `connection: local` play. No host is contacted and
# nothing is written outside --output.
#
# Output handling
# ---------------
# The script writes rendered config to disk and prints NOTHING from it. Rendered config
# contains whatever the inventory contains, including credentials, so --output belongs in a
# scratch directory outside every git repo, and results are meant to be read through
# scripts/compare-rendered-config.py, which classifies and redacts before emitting anything.
#
# Usage
#   scripts/render-properties-offline.sh --inventory <file|dir> [--inventory <more>] \
#       --output <scratch-dir> [--service <name>] [--list-services] [--vault-password-file <f>]
#
# Exit codes: 0 all requested services rendered; 1 usage/precondition error; 2 one or more
# services failed to render (each failure is named, never silently skipped).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROLES="$REPO_ROOT/ala-install/ansible/roles"

INVENTORIES=()
OUTPUT=""
ONLY_SERVICE=""
LIST_ONLY=false
VAULT_FILE=""
ALLOW_ALL_FALLBACK=true

# service | role | template (relative to the role) | destination basename | role params | groups
#
# The group is how we find a host to resolve variables for. ala-install inventories name the
# group after the service, but the exact name varies between inventories, so the alternatives
# are listed pipe-separated and tried in order.
#
# "role params" are variables the ala-install PLAYBOOKS pass as role parameters rather than
# define anywhere a role or inventory can supply, e.g.
#     - { role: biocache-hub, biocache_hub: ala-hub }
# There is nowhere else to read them from, so they are declared here. Comma-separated k=v.
SERVICES=(
  "biocache-service|biocache3-properties|templates/biocache-config.properties|biocache-config.properties||biocache-service|biocache-service-clusterdb|biocache-backend"
  "biocache-hub|biocache-hub|templates/config/config.properties|ala-hub-config.properties|biocache_hub=ala-hub|biocache-hub|ala-hub"
  "collectory|collectory|templates/config/collectory-config.properties|collectory-config.properties||collectory"
  "bie-index|bie-index|templates/bie-index-config.yml|bie-index-config.yml||bie-index|bie_index"
  "bie-hub|bie-hub|templates/bie-hub-config.yml.j2|bie-hub-config.yml||bie-hub|ala-bie-hub"
  "regions|regions|templates/regions-config.properties|regions-config.properties||regions"
  "logger|logger-service|templates/logger-config.properties|logger-config.properties||logger-service|logger"
  "alerts|alerts|templates/alerts-config.properties|alerts-config.properties||alerts-service|alerts"
  "spatial-service|spatial-service|templates/spatial-service-config.yml|spatial-service-config.yml||spatial-service|spatial"
  "data-quality|data_quality_filter_service|templates/config/config.properties|data-quality-config.properties||data_quality_filter_service"
  "sensitive-data-service|sensitive-data-service|templates/sensitive-data-service-config.yml|sensitive-data-service-config.yml||sensitive-data-service|sds"
)

die() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --inventory) INVENTORIES+=("$2"); shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --service) ONLY_SERVICE="$2"; shift 2 ;;
    --list-services) LIST_ONLY=true; shift ;;
    --vault-password-file) VAULT_FILE="$2"; shift 2 ;;
    --no-all-fallback) ALLOW_ALL_FALLBACK=false; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ ${#INVENTORIES[@]} -gt 0 ]] || die "--inventory is required"
$LIST_ONLY || [[ -n "$OUTPUT" ]] || die "--output is required"

# Expand directories into their files. Inventory files do not necessarily carry a .ini
# extension, and a *.ini glob silently misses the ones that do not -- do not reintroduce one.
INV_ARGS=()
for inv in "${INVENTORIES[@]}"; do
  [[ -e "$inv" ]] || die "inventory not found: $inv"
  if [[ -d "$inv" ]]; then
    while IFS= read -r f; do INV_ARGS+=(-i "$f"); done \
      < <(find "$inv" -maxdepth 1 -type f ! -name '.*' | sort)
  else
    INV_ARGS+=(-i "$inv")
  fi
done
[[ ${#INV_ARGS[@]} -gt 0 ]] || die "no inventory files found under: ${INVENTORIES[*]}"

# Vault: without the password a template renders partially and then diffs as drift that is not
# there. Fail loudly instead of producing something misleading.
for ((i = 1; i < ${#INV_ARGS[@]}; i += 2)); do
  if head -c 64 "${INV_ARGS[$i]}" 2>/dev/null | grep -q '\$ANSIBLE_VAULT'; then
    [[ -n "$VAULT_FILE" ]] || die "vault-encrypted inventory: ${INV_ARGS[$i]} (pass --vault-password-file)"
  fi
done
[[ -n "$VAULT_FILE" ]] && INV_ARGS+=(--vault-password-file "$VAULT_FILE")

INV_JSON="$(ansible-inventory "${INV_ARGS[@]}" --list 2>/dev/null)" \
  || die "ansible-inventory could not parse the inventory"

# First host of the first group that exists. Returns the host name for use as a play target;
# it is never echoed, since host names are part of what stays inside --output.
resolve_host() {
  local groups="$1"
  IFS='|' read -ra names <<< "$groups"
  for g in "${names[@]}"; do
    local h
    h="$(printf '%s' "$INV_JSON" | python3 -c '
import json,sys
d=json.load(sys.stdin); g=sys.argv[1]
hosts=(d.get(g) or {}).get("hosts") or []
print(hosts[0] if hosts else "")' "$g")"
    [[ -n "$h" ]] && { printf '%s' "$h"; return 0; }
  done
  # Fallback: the first host of `all`. Group names differ between inventories and chasing each
  # one would mean reading inventories this script deliberately never reads. In a per-service
  # inventory every host belongs to that service anyway, so `all` is the right answer there;
  # in a multi-service inventory the named groups above match first, so this never fires.
  if [[ "$ALLOW_ALL_FALLBACK" == "true" ]]; then
    local a
    a="$(printf '%s' "$INV_JSON" | python3 -c '
import json,sys
d=json.load(sys.stdin)
hosts=(d.get("all") or {}).get("hosts") or []
if not hosts:
    hosts=(d.get("ungrouped") or {}).get("hosts") or []
    if not hosts:
        meta=(d.get("_meta") or {}).get("hostvars") or {}
        hosts=sorted(meta)
print(hosts[0] if hosts else "")')"
    [[ -n "$a" ]] && { printf '%s' "$a"; return 0; }
  fi
  return 1
}

if $LIST_ONLY; then
  for row in "${SERVICES[@]}"; do
    IFS='|' read -r svc _rest <<< "$row"
    groups="${row#*|*|*|*|*|}"
    if resolve_host "$groups" > /dev/null; then
      echo "$svc: present"
    else
      echo "$svc: no group among ($groups)"
    fi
  done
  exit 0
fi

mkdir -p "$OUTPUT"
PLAY="$(mktemp)"
trap 'rm -f "$PLAY"' EXIT

failed=()
rendered=0

for row in "${SERVICES[@]}"; do
  IFS='|' read -r svc role tpl dest params _ <<< "$row"
  groups="${row#*|*|*|*|*|}"
  [[ -z "$ONLY_SERVICE" || "$ONLY_SERVICE" == "$svc" ]] || continue

  if ! host="$(resolve_host "$groups")"; then
    # Not a failure: an inventory that does not deploy a service legitimately has no group for
    # it. Recorded so the comparison can say "not present" rather than "no differences".
    echo "SKIP $svc (no group in this inventory)"
    echo "not-present" > "$OUTPUT/$svc.status"
    continue
  fi

  # Everything the templates need beyond plain inventory vars, established by rendering
  # collectory and following each failure to its source:
  #   group_vars/all/vars.yml     supported_ansible_version (read by common/setfacts)
  #   common + role defaults      tomcat/java/data_dir defaults
  #   role vars/main.yml          <service>_data_dir and friends
  #   common/tasks/setfacts.yml   the derived facts the templates actually interpolate
  # gather_facts is on because setfacts branches on ansible_os_family / distribution version.
  #
  # Those branches only match the Ubuntu releases ala-install supports, so on any other
  # controller (Debian 13 here) NO branch runs and the facts they set -- `mysql`, `tomcat`,
  # `java` -- stay undefined, which fails the render with a message that looks like a template
  # bug. The OS facts are therefore pinned below, identically for every inventory rendered, so
  # the choice cannot become a difference between two sides being compared. It does mean any
  # value derived from the OS reflects the pin rather than the target host; those are package
  # and path names, not endpoints, and the comparison is about endpoints.
  cat > "$PLAY" <<YAML
- name: Render $svc offline
  hosts: "{{ target_host }}"
  connection: local
  gather_facts: true
  become: false
  vars_files:
$( [[ -f "$ROLES/$role/vars/main.yml" ]] && echo "    - \"$ROLES/$role/vars/main.yml\"" )
    - "/dev/null"
  tasks:
    # Role DEFAULTS are the lowest-precedence source in Ansible: the inventory overrides them.
    # Loading them through vars_files inverts that -- play vars_files outrank inventory group
    # vars -- so the default wins and the render is quietly wrong. That is not hypothetical:
    # bie-hub rendered every URL against the upstream production stack because the role default
    # bie_base_url clobbered the [all:vars] entry, and it only came to light on comparing the
    # output against the live file, which was correct. So defaults are loaded into a namespace
    # and then applied ONLY to names the inventory does not already provide.
    #
    # role vars/ above stays in vars_files, because vars/ really does outrank the inventory.
    - ansible.builtin.set_fact:
        _inventory_names: "{{ hostvars[inventory_hostname].keys() | list }}"
    - ansible.builtin.include_vars:
        file: "$REPO_ROOT/ala-install/ansible/group_vars/all/vars.yml"
        name: _defaults_global
    - ansible.builtin.include_vars:
        file: "$ROLES/common/defaults/main.yml"
        name: _defaults_common
$( if [[ -f "$ROLES/$role/defaults/main.yml" ]]; then
     echo "    - ansible.builtin.include_vars:"
     echo "        file: \"$ROLES/$role/defaults/main.yml\""
     echo "        name: _defaults_role"
   else
     echo "    - ansible.builtin.set_fact:"
     echo "        _defaults_role: {}"
   fi )
    - ansible.builtin.set_fact:
        _defaults: "{{ _defaults_global | combine(_defaults_common) | combine(_defaults_role) }}"
    - ansible.builtin.set_fact:
        "{{ item.key }}": "{{ item.value }}"
      loop: "{{ _defaults | dict2items }}"
      when: item.key not in _inventory_names
      loop_control:
        label: "{{ item.key }}"

    - ansible.builtin.include_tasks: "$ROLES/common/tasks/setfacts.yml"
    - ansible.builtin.template:
        src: "$ROLES/$role/$tpl"
        dest: "$OUTPUT/$dest"
        mode: "0600"
YAML
  # ansible_become as an inventory VARIABLE beats the play's `become: false` keyword, so it has
  # to be overridden as an extra var (which beats everything) -- otherwise the render writes
  # root-owned 0600 files the caller cannot read afterwards.
  EXTRA=(-e "target_host=$host"
         -e ansible_become=false
         -e ansible_os_family=Debian
         -e ansible_distribution=Ubuntu
         -e ansible_distribution_version=22.04
         -e ansible_architecture=x86_64)
  if [[ -n "$params" ]]; then
    IFS=',' read -ra kvs <<< "$params"
    for kv in "${kvs[@]}"; do EXTRA+=(-e "$kv"); done
  fi

  if ansible-playbook "${INV_ARGS[@]}" "${EXTRA[@]}" "$PLAY" \
       > "$OUTPUT/$svc.render.log" 2>&1; then
    echo "OK   $svc -> $dest"
    echo "rendered" > "$OUTPUT/$svc.status"
    rendered=$((rendered + 1))
  else
    echo "FAIL $svc (see $OUTPUT/$svc.render.log)"
    echo "render-failed" > "$OUTPUT/$svc.status"
    failed+=("$svc")
  fi
done

echo "rendered=$rendered failed=${#failed[@]}"
if [[ ${#failed[@]} -gt 0 ]]; then
  # Named, never silently dropped: a file missing from the comparison must be visible, because
  # "no differences" and "never compared" look identical in a report.
  echo "not compared: ${failed[*]}" >&2
  exit 2
fi

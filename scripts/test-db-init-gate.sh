#!/usr/bin/env bash
# Regression test: database provisioning must run wherever this stack runs a datastore
# container, regardless of where CAS lives.
#
# Why this exists: the gate used to be
#     'cas-servers' in physical_server_groups or 'image-service' in physical_server_groups
# which is a proxy for "is there a datastore here" that only holds when CAS is deployed
# inside the stack. gbif-es runs an external CAS (a VM), so the condition was false on all
# three docker hosts and init-databases.yml never ran once. Verified in production on
# 2026-08-06: la_mysql held only `collectory` (left over from an older deploy — the volume
# is external) and la_postgres held none of layersdb, geonetwork, images or doi. Every
# MySQL/Postgres user the stack needs was missing, species-list and logger-service
# crash-looped on "Access denied", and the health gate burned its full budget on them.
#
# Both the enable_* facts and the gate itself are extracted from the role at run time, so
# this cannot drift from a hand-copied duplicate.
#
# Run: scripts/test-db-init-gate.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK_DIR="$(mktemp -d -t la-db-init-gate-XXXXXX)"
cleanup() { [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]] && rm -rf -- "$WORK_DIR"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# ── Fixture: gbif-es shape — CAS on a production VM, datastores inside the stack ──
# d1 holds the MySQL consumers (and therefore la_mysql), d3 holds a Postgres consumer
# (la_postgres), d2 holds neither.
cat > "$WORK_DIR/inventory.ini" <<'EOF'
[docker_compose]
d1.docker_compose ansible_host=docker-1
d2.docker_compose ansible_host=docker-2
d3.docker_compose ansible_host=docker-3

[cas-servers]
vmauth.cas ansible_host=vm-auth-prod

[collectory]
d1.collectory ansible_host=docker-1

[species-list]
d1.species ansible_host=docker-1

[logger-service]
d1.logger ansible_host=docker-1

[spatial-service]
d3.spatialsvc ansible_host=docker-3

[spatial]
d3.spatial ansible_host=docker-3

[bie-hub]
d2.bie ansible_host=docker-2
EOF

# ── Extract the enable_* facts and the gate from the role ────────────────────
python3 - "$REPO_ROOT" "$WORK_DIR" <<'PY'
import sys, yaml, os

repo, work = sys.argv[1], sys.argv[2]

facts = yaml.safe_load(open(os.path.join(repo, 'roles/la-compose/tasks/setup-facts.yml')))
enable = [t for t in facts
          if isinstance(t, dict) and t.get('name', '').startswith('Determine if MySQL is required')]
if not enable:
    sys.exit("could not find the enable_* fact task in setup-facts.yml")

main = yaml.safe_load(open(os.path.join(repo, 'roles/la-compose/tasks/main.yml')))


def walk(node):
    """The include lives inside nested blocks; yield every task dict."""
    if isinstance(node, list):
        for item in node:
            yield from walk(item)
    elif isinstance(node, dict):
        yield node
        for key in ('block', 'tasks', 'rescue', 'always', 'pre_tasks', 'post_tasks'):
            if key in node:
                yield from walk(node[key])


gate = [t for t in walk(main)
        if t.get('name', '').startswith('Initialize databases')]
if not gate:
    sys.exit("could not find the 'Initialize databases' task in main.yml")

conds = gate[0]['when']
if isinstance(conds, str):
    conds = [conds]
# auto_deploy is orthogonal to what is under test here.
conds = [c for c in conds if 'auto_deploy' not in str(c)]

yaml.safe_dump(
    [{'name': 'enable_* facts (from the role)',
      'ansible.builtin.set_fact': enable[0]['ansible.builtin.set_fact']},
     {'name': 'gate (from the role)',
      'ansible.builtin.set_fact': {'db_init_would_run': "{{ (%s) }}" % ') and ('.join(str(c) for c in conds)}}],
    open(os.path.join(work, 'gate.yml'), 'w'), default_flow_style=False, width=10000)
PY

cat > "$WORK_DIR/play.yml" <<'EOF'
- hosts: docker_compose
  gather_facts: false
  tasks:
    # Same definition as setup-facts.yml.
    - name: Compute physical_server_groups
      ansible.builtin.set_fact:
        physical_server_groups: >-
          {%- set r = [] -%}
          {%- for host in groups['all'] -%}
            {%- if hostvars[host].get('ansible_host', host)
                   == hostvars[inventory_hostname].get('ansible_host', inventory_hostname) -%}
              {%- for g in hostvars[host].get('group_names', []) -%}
                {%- if g not in ['all', 'docker_compose', 'docker-common', 'ungrouped']
                       and not g.endswith('_group') -%}
                  {%- set _ = r.append(g) -%}
                {%- endif -%}
              {%- endfor -%}
            {%- endif -%}
          {%- endfor -%}
          {{ r | unique | sort }}

    - name: Evaluate the role's own facts and gate
      ansible.builtin.include_tasks: gate.yml

    - name: "[TC7a] The host running la_mysql provisions, even with an external CAS"
      ansible.builtin.assert:
        that:
          - db_init_would_run | bool
        fail_msg: >
          FAIL TC7a: {{ inventory_hostname }} holds the MySQL consumers (and therefore
          la_mysql) but database provisioning would not run. This is the gbif-es defect:
          an external CAS made the gate false everywhere and no user was ever created.
      when: inventory_hostname == 'd1.docker_compose'

    - name: "[TC7b] The host running la_postgres provisions too"
      ansible.builtin.assert:
        that:
          - db_init_would_run | bool
        fail_msg: >
          FAIL TC7b: {{ inventory_hostname }} runs a Postgres consumer (layersdb,
          geonetwork) but provisioning would not run there.
      when: inventory_hostname == 'd3.docker_compose'

    - name: "[TC7c] A host with no datastore does not provision"
      ansible.builtin.assert:
        that:
          - not (db_init_would_run | bool)
        fail_msg: >
          FAIL TC7c: {{ inventory_hostname }} runs no datastore container, so
          init-databases would `docker exec` against containers that do not exist there.
      when: inventory_hostname == 'd2.docker_compose'
EOF

echo "== TC7: database provisioning gate (external CAS) =="
cd "$WORK_DIR"
if ! ANSIBLE_LOCALHOST_WARNING=False ANSIBLE_DEPRECATION_WARNINGS=False \
     ansible-playbook -i inventory.ini play.yml --connection=local > out.log 2>&1; then
  sed -n '/FAIL TC7/,+5p' out.log || cat out.log
  fail "assertions did not pass (full log above)"
fi

echo "PASS TC7a: MySQL host provisions despite an external CAS"
echo "PASS TC7b: Postgres host provisions"
echo "PASS TC7c: datastore-less host stays out"
echo "OK"

#!/usr/bin/env bash
# Regression test: on a mixed VM+Docker inventory, the compose alias for a datastore
# that THIS stack deploys must resolve to a docker host, never to a production VM.
#
# Why this exists: `datastore_cluster_spec[*].groups` mixes the datastore's own group
# with its CONSUMERS ('collectory', 'species-list', 'logger-service', ... for mysql).
# On gbif-es those consumer groups also contain production VMs, and the endpoint
# computation took `groups[g] | first` blindly. Result, verified in production on
# 2026-08-06: inside every non-co-located docker container, `mysql` resolved to
# 172.16.16.61 — the production CAS VM — while la_mysql actually ran on docker host 1.
# Nothing consumed it at the time, so it went unnoticed; moving any MySQL-backed
# service to host 2 or 3 would have pointed it at the production database.
#
# The test evaluates the REAL expression, extracted from the role at run time, so it
# cannot drift from a hand-copied duplicate.
#
# Run: scripts/test-datastore-owner.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROLE_TASKS="$REPO_ROOT/roles/la-compose/tasks/generate-compose.yml"
SETUP_FACTS="$REPO_ROOT/roles/la-compose/tasks/setup-facts.yml"

WORK_DIR="$(mktemp -d -t la-datastore-owner-XXXXXX)"
cleanup() { [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]] && rm -rf -- "$WORK_DIR"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# ── Fixture: a mixed VM+Docker inventory shaped like gbif-es ──────────────────
# The production VM is listed FIRST among the datastore's groups (cas-servers comes
# before collectory in the mysql spec), which is exactly what made the old code pick it.
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

[alerts-service]
vmmisc.alerts ansible_host=vm-misc-prod

[spatial]
d3.spatial ansible_host=docker-3

[solrcloud]
vmsolr.solr ansible_host=vm-solrcloud-prod

[cassandra3]
vmcass.cass ansible_host=vm-cassandra-prod

[zookeeper]
vmzk.zk ansible_host=vm-zookeeper-prod
EOF

# ── Extract the live expression from the role ────────────────────────────────
python3 - "$ROLE_TASKS" "$WORK_DIR/compute.yml" "$WORK_DIR/guard.yml" \
  "$SETUP_FACTS" "$WORK_DIR/locality.yml" <<'PY'
import sys, yaml

tasks = yaml.safe_load(open(sys.argv[1]))

# The stage hosts and the datastore locality come from setup-facts.yml, which runs before
# generate-compose.yml. Taken from the role as well, for the same reason as below.
facts = yaml.safe_load(open(sys.argv[4]))
locality = [t for t in facts if isinstance(t, dict) and t.get('name', '') in (
    "Determine the docker hosts of this host's stage",
    'Determine which datastores are deployed inside this docker stack (vs external VMs)')]
if len(locality) != 2:
    sys.exit("could not find the stage and locality tasks in setup-facts.yml")
for t in locality:
    t.pop('tags', None)
yaml.safe_dump(locality, open(sys.argv[5], 'w'), default_flow_style=False, width=10000)


def find(prefix):
    hits = [t for t in tasks
            if isinstance(t, dict) and t.get('name', '').startswith(prefix)]
    if not hits:
        sys.exit("could not find a task named %r in the role" % prefix)
    return hits[0]


compute = find('Compute datastore endpoints')
guard = find('Validate: a stack-local datastore is never owned')

# Both are exercised as the role defines them. Copying either into the test would let the
# role drift away from what is being asserted.
yaml.safe_dump(
    [{'name': 'Compute datastore endpoints (under test)',
      'ansible.builtin.set_fact':
          {'datastore_endpoints': compute['ansible.builtin.set_fact']['datastore_endpoints']}}],
    open(sys.argv[2], 'w'), default_flow_style=False, width=10000)

guard_task = {'name': 'Guard (under test)',
              'ansible.builtin.assert': dict(guard['ansible.builtin.assert'])}
yaml.safe_dump([guard_task], open(sys.argv[3], 'w'),
               default_flow_style=False, width=10000)
PY

cat > "$WORK_DIR/play.yml" <<'EOF'
- hosts: docker_compose
  gather_facts: false
  vars:
    docker_extra_hosts_dict:
      docker-1: "10.0.0.1"
      docker-2: "10.0.0.2"
      docker-3: "10.0.0.3"
      vm-auth-prod: "172.16.16.61"
      vm-misc-prod: "172.16.16.173"
      vm-solrcloud-prod: "172.16.16.118"
      vm-cassandra-prod: "172.16.16.15"
      vm-zookeeper-prod: "172.16.16.119"
    physical_server_groups: []
    datastore_cluster_spec:
      cassandra: {groups: ['cassandra5', 'cassandra3', 'cassandra'], port: 9042, aliases: ['cassandra', 'la_cassandra']}
      solr: {groups: ['solrcloud', 'solr'], port: 8983, aliases: ['solr', 'la_solr']}
      zookeeper: {groups: ['solrcloud', 'solr', 'zookeeper'], port: 2181, aliases: ['zookeeper', 'la_zookeeper']}
      mysql: {groups: ['mysql', 'cas-servers', 'collectory', 'species-list', 'logger-service', 'alerts-service'], port: 3306, aliases: ['mysql', 'la_mysql']}
      postgres: {groups: ['postgres', 'spatial', 'image-service', 'doi-service', 'data_quality_filter_service'], port: 5432, aliases: ['postgres', 'la_postgres']}
      mongodb: {groups: ['mongo', 'mongodb', 'cas-servers', 'ecodata'], port: 27017, aliases: ['mongodb', 'la_mongodb']}
  tasks:
    - name: Compute stage hosts and datastore locality (from setup-facts.yml)
      ansible.builtin.include_tasks: locality.yml

    - name: Run the role's own endpoint computation
      ansible.builtin.include_tasks: compute.yml

    - name: "[TC6a] A datastore deployed in this stack must be owned by a docker host"
      ansible.builtin.assert:
        that:
          - datastore_endpoints.mysql.ip == '10.0.0.1'
          - datastore_endpoints.postgres.ip == '10.0.0.3'
        fail_msg: >
          FAIL TC6a: mysql owner={{ datastore_endpoints.mysql.owner }}
          ip={{ datastore_endpoints.mysql.ip }} (expected 10.0.0.1),
          postgres ip={{ datastore_endpoints.postgres.ip }} (expected 10.0.0.3).
          A stack-local datastore resolved to a host outside groups['docker_compose'] —
          on a mixed inventory that is a production VM.
      run_once: true

    - name: "[TC6b] A genuinely external datastore must keep pointing at its VM"
      ansible.builtin.assert:
        that:
          - datastore_endpoints.solr.ip == '172.16.16.118'
          - datastore_endpoints.zookeeper.ip == '172.16.16.118'
          - datastore_endpoints.cassandra.ip == '172.16.16.15'
        fail_msg: >
          FAIL TC6b: an external datastore was redirected into the docker stack.
          solr={{ datastore_endpoints.solr.ip }},
          zookeeper={{ datastore_endpoints.zookeeper.ip }},
          cassandra={{ datastore_endpoints.cassandra.ip }}.
          Mixed VM+Docker deployments consume the production Solr/Cassandra on purpose.
      run_once: true

    # owner_in_stack is what the role's own guard assertion keys on. It must compare
    # ansible_host, not inventory names: the owner is a service alias ('d1.collectory')
    # while groups['docker_compose'] holds 'd1.docker_compose' for the same box. A guard
    # that compared names would never match and would fire on every deployment.
    - name: "[TC6c] owner_in_stack is computed on ansible_host, not on inventory names"
      ansible.builtin.assert:
        that:
          - datastore_endpoints.mysql.owner_in_stack
          - datastore_endpoints.postgres.owner_in_stack
          - not datastore_endpoints.solr.owner_in_stack
          - not datastore_endpoints.cassandra.owner_in_stack
          - not datastore_endpoints.mongodb.owner_in_stack
        fail_msg: >
          FAIL TC6c: owner_in_stack is wrong.
          mysql={{ datastore_endpoints.mysql.owner_in_stack }} (owner
          {{ datastore_endpoints.mysql.owner }}),
          solr={{ datastore_endpoints.solr.owner_in_stack }}.
          The role's guard assertion keys on this flag; if it is computed by comparing
          inventory names it never matches and the guard misfires.
      run_once: true

    - name: "[TC6d] The role's own guard passes on a correctly-resolved deployment"
      ansible.builtin.include_tasks: guard.yml
EOF

# TC6e lives in its own play: a rescued failure still makes ansible-playbook exit 2, so a
# block/rescue inside the main play would be indistinguishable from a real failure. Here the
# expectation is inverted — this play MUST fail — which is unambiguous.
cat > "$WORK_DIR/play-negative.yml" <<'EOF'
- hosts: docker_compose[0]
  gather_facts: false
  vars:
    # Exactly what gbif-es produced in production: mysql is deployed inside the stack
    # (datastore_docker_local true) yet owned by the CAS production VM.
    datastore_docker_local:
      mysql: true
    datastore_endpoints:
      mysql:
        owner: vmauth.cas
        colocated: false
        ip: "172.16.16.61"
        port: 3306
        aliases: ['mysql', 'la_mysql']
        owner_in_stack: false
  tasks:
    - name: Guard must reject this
      ansible.builtin.include_tasks: guard.yml
EOF

echo "== TC6: datastore owner on a mixed VM+Docker inventory =="
cd "$WORK_DIR"
if ! ANSIBLE_LOCALHOST_WARNING=False ANSIBLE_DEPRECATION_WARNINGS=False \
     ansible-playbook -i inventory.ini play.yml --connection=local > "$WORK_DIR/out.log" 2>&1; then
  sed -n '/FAIL TC6/,+6p' "$WORK_DIR/out.log" || cat "$WORK_DIR/out.log"
  fail "assertions did not pass (full log above)"
fi

echo "PASS TC6a: stack-local datastores (mysql, postgres) owned by docker hosts"
echo "PASS TC6b: external datastores (solr, zookeeper, cassandra) still on their VMs"
echo "PASS TC6c: owner_in_stack computed on ansible_host"
echo "PASS TC6d: role guard passes on a correct deployment"

# Inverted expectation: a guard that cannot fail is decoration.
if ANSIBLE_LOCALHOST_WARNING=False ANSIBLE_DEPRECATION_WARNINGS=False \
   ansible-playbook -i inventory.ini play-negative.yml --connection=local \
   > "$WORK_DIR/out-negative.log" 2>&1; then
  fail "TC6e: the guard accepted mysql owned by a host outside the stack — the exact
gbif-es production defect. It cannot detect a regression."
fi
if ! grep -q "outside" "$WORK_DIR/out-negative.log"; then
  cat "$WORK_DIR/out-negative.log"
  fail "TC6e: the negative play failed, but not on the guard assertion (see log above)"
fi
echo "PASS TC6e: role guard fires on the production failure shape"

# ── TC7: one datastore per stage ─────────────────────────────────────────────
# gbif.es, migrating service by service: production compose hosts (real data) next to
# staging ones (services still empty). Each stage runs its own mysql; a production host
# must never be pointed at the staging one, nor staging at production.
cat > "$WORK_DIR/inventory-stages.ini" <<'EOF2'
[docker_compose]
p1.docker_compose ansible_host=docker-1 docker_stage=production
s2.docker_compose ansible_host=docker-2 docker_stage=staging
p3.docker_compose ansible_host=docker-3 docker_stage=production
s4.docker_compose ansible_host=docker-4 docker_stage=staging

[cas-servers]
vmauth.cas ansible_host=vm-auth-prod

[collectory]
p1.collectory ansible_host=docker-1

[species-list]
s2.species ansible_host=docker-2

[spatial]
p3.spatial ansible_host=docker-3

[solrcloud]
vmsolr.solr ansible_host=vm-solrcloud-prod
EOF2

sed -e '/^  tasks:/,$d' "$WORK_DIR/play.yml" > "$WORK_DIR/play-stages.yml"
sed -i 's/      docker-3: "10.0.0.3"/      docker-3: "10.0.0.3"\n      docker-4: "10.0.0.4"/' "$WORK_DIR/play-stages.yml"
cat >> "$WORK_DIR/play-stages.yml" <<'EOF2'
  tasks:
    - name: Compute stage hosts and datastore locality (from setup-facts.yml)
      ansible.builtin.include_tasks: locality.yml

    - name: Run the role's own endpoint computation
      ansible.builtin.include_tasks: compute.yml

    - name: "[TC7a] production hosts use the production mysql"
      ansible.builtin.assert:
        that: datastore_endpoints.mysql.ip == '10.0.0.1'
        fail_msg: "FAIL TC7a: {{ inventory_hostname }} mysql at {{ datastore_endpoints.mysql.ip }}, expected 10.0.0.1"
      when: docker_stage == 'production'

    - name: "[TC7b] staging hosts use the staging mysql"
      ansible.builtin.assert:
        that: datastore_endpoints.mysql.ip == '10.0.0.2'
        fail_msg: "FAIL TC7b: {{ inventory_hostname }} mysql at {{ datastore_endpoints.mysql.ip }}, expected 10.0.0.2"
      when: docker_stage == 'staging'

    - name: "[TC7c] a datastore only another stage runs gets no endpoint"
      ansible.builtin.assert:
        that: "'postgres' not in datastore_endpoints"
        fail_msg: "FAIL TC7c: {{ inventory_hostname }} got postgres at {{ datastore_endpoints.postgres | default({}) }}, which only production runs"
      when: docker_stage == 'staging'

    - name: "[TC7d] external datastores stay on their VM in both stages"
      ansible.builtin.assert:
        that: datastore_endpoints.solr.ip == '172.16.16.118'
        fail_msg: "FAIL TC7d: {{ inventory_hostname }} solr at {{ datastore_endpoints.solr.ip }}"

    - name: "[TC7e] the role's own guard passes in both stages"
      ansible.builtin.include_tasks: guard.yml
EOF2

if ! ANSIBLE_LOCALHOST_WARNING=False ANSIBLE_DEPRECATION_WARNINGS=False \
     ansible-playbook -i inventory-stages.ini play-stages.yml --connection=local \
     > "$WORK_DIR/out-stages.log" 2>&1; then
  grep -A4 "FAIL TC7\|fatal:" "$WORK_DIR/out-stages.log" || cat "$WORK_DIR/out-stages.log"
  fail "TC7: one datastore per stage (log above)"
fi
echo "PASS TC7: each stage resolves its own mysql; staging gets no production-only datastore"
echo "OK"

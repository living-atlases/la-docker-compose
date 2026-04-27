# Testing Patterns

**Analysis Date:** 2026-04-27

## Test Framework

**Linting:**
- `yamllint` — YAML syntax/style validation
  - Config: `.yamllint` (project root)
  - Ignores: `ala-install/`, `.git/`, `molecule/`, `*.j2`
- `ansible-lint` — Ansible best-practice validation
  - Config: datadog role has its own `.ansible-lint`; project uses standard defaults
  - Run from project root against roles and playbooks

**Role Testing:**
- Molecule — integration testing for roles
  - Driver: `docker`
  - Platform image: `geerlingguy/docker-ubuntu2204-ansible` (Ubuntu 22.04 with systemd)
  - Verifier: `ansible`
  - Scenario: `roles/la-compose/molecule/default/`

**Run Commands:**
```bash
# Lint
yamllint .
ansible-lint

# Syntax check only (fast)
ansible-playbook -i inventories/local playbooks/site.yml --syntax-check

# Molecule full test cycle
cd roles/la-compose && molecule test

# Molecule converge only (faster iteration)
cd roles/la-compose && molecule converge

# Molecule idempotence check
cd roles/la-compose && molecule idempotence

# Molecule verify
cd roles/la-compose && molecule verify
```

## Test File Organization

**Location:** `tests/` directory (project root) + `roles/la-compose/molecule/`

```
tests/
├── test-full-flow.yml            # Variable loading flow tests (include_role public=true)
├── test-common-vars.yml          # Common variable availability tests
├── test-no-localhost-configs.yml # Validates no localhost refs in generated configs
├── variable-collision-test/      # Variable isolation tests across service aliases
│   ├── inventories/              # Test-specific inventories
│   ├── playbooks/                # Collision test playbooks
│   └── roles/                   # Test roles
└── delegate_to_test/             # delegate_to pattern tests

roles/la-compose/molecule/
└── default/
    ├── molecule.yml              # Molecule scenario config
    └── converge.yml              # Molecule converge playbook
```

## Test Structure

**Molecule Scenario** (`roles/la-compose/molecule/default/molecule.yml`):
```yaml
driver:
  name: docker
platforms:
  - name: la-test
    image: geerlingguy/docker-ubuntu2204-ansible
    privileged: true
    volume_mounts:
      - "/sys/fs/cgroup:/sys/fs/cgroup:rw"
    command: /lib/systemd/systemd
    groups:
      - docker_compose
      - cas-servers
      - mysql
      - mongodb
provisioner:
  name: ansible
  inventory:
    links:
      group_vars: ../../../../../inventories/local/group_vars
verifier:
  name: ansible
```

**Molecule Converge** (`roles/la-compose/molecule/default/converge.yml`):
```yaml
- name: Molecule Converge
  hosts: all
  become: yes
  vars:
    auto_deploy: false   # No actual containers in CI
  tasks:
    - import_role: {name: la-volumes}
    - import_role: {name: la-compose}
```

**Assert pattern in test playbooks:**
```yaml
- name: "Verify gatus_config_dir is available"
  assert:
    that:
      - gatus_config_dir is defined
      - gatus_config_dir == "/data/gatus/config"
    success_msg: "✅ gatus_config_dir correctly loaded: {{ gatus_config_dir }}"
    fail_msg: "❌ gatus_config_dir not loaded correctly"
```

## Local Testing Inventories

Two inventories for rapid local testing without remote machines:

**Full inventory** (`inventories/local/hosts.ini`) — 27 services:
```bash
ansible-playbook -i inventories/local playbooks/site.yml --syntax-check
ansible-playbook -i inventories/local playbooks/config-gen.yml --check --diff
```

**Dev inventory** (`inventories/dev/hosts.ini`) — CAS + Collectory + Branding:
```bash
ansible-playbook -i inventories/dev playbooks/config-gen.yml --check --diff
ansible-playbook -i inventories/dev playbooks/config-gen.yml --limit collectory --check --diff -vvv
```

**Validate inventory syntax:**
```bash
ansible-inventory -i inventories/local/hosts.ini --list
ansible-inventory -i inventories/dev/hosts.ini --list
```

**With deployment_type override:**
```bash
ansible-playbook -i inventories/local playbooks/site.yml -e deployment_type=container --check --diff
```

## CI/CD Test Pipeline (Jenkins)

**Job:** `la-docker-compose-tests`
- URL: `https://jenkins.gbif.es/job/la-docker-compose-tests/`
- Branch: `main` (la-docker-compose repo)
- Trigger: SCM changes + manual

**Pipeline parameters:**
| Parameter | Default | Purpose |
|-----------|---------|---------|
| `FORCE_REDEPLOY` | false | Force redeploy even without changes |
| `CLEAN_MACHINE` | true | Wipe /data and purge Docker before run |
| `ONLY_CLEAN` | false | Clean only, skip deployment |
| `GENERATOR_BRANCH` | master | generator-living-atlas branch |
| `AUTO_DEPLOY` | true | Start containers after config gen |

**Pipeline stages:**
1. **Clean machines** — stops containers, prunes Docker, wipes `/data`, restarts daemon
2. **Prepare environment** — git submodule update (ala-install), creates Python venv, installs Ansible
3. **Update dependencies** — clone/update generator-living-atlas
4. **Decide redeploy** — SHA comparison of generator + self; skip if unchanged
5. **Install generator deps** — `npm ci` in generator dir
6. **Regenerate inventories** — runs `yo living-atlas --replay-dont-ask --force`
7. **Pre-Deploy Docker Cleanup** — nuclear: removes `/var/lib/docker/*`, restarts daemon
8. **Run Playbooks** — `ansible-playbook playbooks/site.yml` or `config-gen.yml`
9. **Validate Deployment** — verifies `docker-compose.yml` exists and passes `docker compose config`

**Ansible environment in Jenkins:**
```bash
ANSIBLE_ROLES_PATH="${WORKSPACE}/ala-install/ansible/roles:${WORKSPACE}/roles"
ANSIBLE_FORCE_COLOR=true
ANSIBLE_STDOUT_CALLBACK=yaml
ANSIBLE_HOST_KEY_CHECKING=False
```

**Checking CI failures via MCP:**
```bash
# Last build status
jenkins_getBuild jobFullName=la-docker-compose-tests

# Last 100 lines of log
jenkins_getBuildLog jobFullName=la-docker-compose-tests limit=-100

# Search specific error
jenkins_searchBuildLog jobFullName=la-docker-compose-tests pattern="fatal:" contextLines=5
```

## Test Types

**Lint tests (fastest):**
- `yamllint .` — YAML syntax
- `ansible-lint` — Ansible best practices
- `ansible-playbook --syntax-check` — Ansible syntax

**Unit/integration tests (local):**
- `tests/test-full-flow.yml` — variable loading, include_role public=true pattern
- `tests/test-common-vars.yml` — common variables availability
- `tests/variable-collision-test/` — variable isolation between service aliases (Issue #10)

**Functional tests (local, check mode):**
- `ansible-playbook -i inventories/local playbooks/config-gen.yml --check --diff` — config generation
- `tests/test-no-localhost-configs.yml` — validates no localhost refs in generated configs
- `playbooks/validate-compose.yml` — validates generated docker-compose.yml syntax

**Molecule tests (role-level):**
- `roles/la-compose/molecule/default/` — full role converge in Docker container
- Tests `la-volumes` + `la-compose` roles together
- `auto_deploy: false` — skips actual container start in CI

**End-to-end (Jenkins only):**
- Full pipeline: clean → generate inventory → deploy → validate
- Target: `docker_compose` group hosts (`gbif-es-docker-cluster-2023-*`)
- Validates `docker-compose.yml` on each target host post-deployment

## Idempotence Testing

Idempotence is a hard requirement (not optional):

```bash
# Run molecule idempotence explicitly
cd roles/la-compose && molecule idempotence

# Local idempotence test: run playbook twice, check no spurious changes
ansible-playbook -i inventories/local playbooks/config-gen.yml --check --diff
ansible-playbook -i inventories/local playbooks/config-gen.yml --check --diff  # second run
```

Docker Compose idempotence pattern tested in `roles/la-compose/tasks/main.yml:106-140` — always runs `down --remove-orphans` before `up`.

## Coverage Areas

**Covered:**
- Role task execution (Molecule)
- YAML/Ansible syntax (yamllint + ansible-lint)
- Variable loading patterns (test-full-flow.yml)
- Variable collision isolation (variable-collision-test/)
- Config generation without localhost refs (test-no-localhost-configs.yml)
- Full deployment pipeline (Jenkins CI)
- docker-compose.yml validity post-deploy (Validate Deployment stage)

## Missing Test Coverage

**Not automated:**
- **deployment_type guard correctness** — no automated test verifying VM tasks skip when `deployment_type=container` and vice versa
- **Template output correctness** — no structural validation of generated service configs (only localhost absence check)
- **Health checks post-deploy** — Jenkins validates compose syntax but not running service health
- **Inventory completeness** — no test that all 27 services generate valid config
- **Molecule verify step** — `molecule.yml` sets verifier but `converge.yml` has no verify tasks
- **Cross-service variable isolation** — `variable-collision-test/` exists but coverage is manual
- **ala-install role guards** — 66 deployment_type guards in ala-install are tested only via Jenkins CI, not locally
- **Rollback behavior** — no test for failed deployment recovery

---

*Testing analysis: 2026-04-27*

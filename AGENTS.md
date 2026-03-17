# agents.md

Practical guidelines for using AI agents (Copilot/LLMs) to develop **Ansible playbooks/roles** for **Debian/Ubuntu** environments executed over **SSH**.

This document is designed to reduce hallucinations, shorten feedback loops, and keep work reproducible.

**Current Project**: `la-docker-compose` - Containerized Living Atlas deployment using docker-compose

---

## 📍 Current Project Status

### Working Repositories

| Repo | Purpose | Location | Branch | Status |
|------|---------|----------|--------|--------|
| **la-docker-compose** | Docker-compose orchestration | `~/proyectos/gbif/dev/la-docker-compose` | `main` | ✅ Active |
| **ala-install** (our fork) | ALA roles with deployment_type guards | `~/proyectos/gbif/dev/ala-install` | `docker-compose-min-pr` | ✅ PR-ready |
| **ala-install-docker** | POC reference (docker-compose-poc branch) | `~/proyectos/gbif/dev/ala-install-docker` | `docker-compose-poc` | 📖 Reference |
| **generator-living-atlas** | Inventory generator (npm package) | Used via npm | `master` | ✅ Stable |

### ala-install Usage

**Our branch: `docker-compose-min-pr`**
- Contains 66 deployment_type guards across 13 roles
- 1 atomic commit: `1067145658346b10d0b3ebd173cf379971fe1402`
- Purpose: Allow la-docker-compose to use ala-install roles without modification
- Status: Ready for GitHub push + PR creation
- Default in Jenkinsfile: ✅ Updated (commit ef5b606)

**Roles modified in docker-compose-min-pr:**
- common (1 guard) - validation update
- apikey (4 guards) - VM guards
- logger-service (11 guards) - VM guards
- image-service (6 guards) - VM guards
- namematching-service (2 guards) - Swarm/container guards
- sensitive-data-service (2 guards) - Swarm/container guards
- solrcloud (2 guards) - inverse VM guards
- species-list (2 guards) - inverse VM guards
- gatus (3 guards + task split) - mixed patterns
- spatial-hub (2 guards) - VM guards
- spatial-service (1 guard) - VM guards
- userdetails (2 guards + task split) - mixed patterns
- pipelines (27 guards) - mixed patterns (apt/docker/hadoop)

---

## 🎯 Goals

- Ship small, reviewable changes.
- Make failures fast (seconds/minutes) via lint + local tests.
- Keep roles idempotent and predictable on Debian/Ubuntu.
- Avoid agent-generated surprises (invented modules/parameters, non-deterministic shell).
- Support multiple deployment types (VM, Swarm, Container) from single codebase.

---

## Repo conventions

### Preferred structure

- Use **roles** for reusable logic.
- Use **playbooks** as thin orchestration wrappers.

Recommended layout:

- `playbooks/`
- `roles/<role_name>/`
  - `defaults/main.yml`
  - `vars/Debian.yml` (optional)
  - `tasks/main.yml`
  - `handlers/main.yml`
  - `templates/`
  - `files/`
  - `meta/main.yml`
- `collections/requirements.yml` (if using collections)
- `molecule/<scenario>/` (role tests)
- `.config/` or `.github/workflows/` (CI)

### Variable contract

Every role should define:

- `defaults/main.yml` with safe defaults
- clear variable names scoped by role (e.g. `nginx_*`, `users_*`)
- `assert` checks early for required vars or invalid types/values

### deployment_type Variable (NEW)

When adding new tasks or roles to support container deployments:

- Add `deployment_type` guards using these patterns:
  - **VM default** (most tasks): `when: deployment_type == 'vm' or deployment_type is undefined`
  - **Swarm/Container tasks**: `when: deployment_type == 'swarm' or deployment_type == 'container'`
  - **Inverse VM check**: `when: deployment_type != 'vm'`
  - **Container only**: `when: deployment_type == 'container'`

- Never modify tasks that apply to all deployment types (config generation, templates)
- Split tasks if some parts are deployment-type specific
- **Valid values:**
  - `vm` (default) - Traditional VM deployment
  - `container` (recommended for docker-compose) - Docker Compose standalone
  - `swarm` (legacy, maintained for compatibility) - Docker Swarm orchestration

**Note:** All `*-docker.yml` playbooks in ala-install now default to `deployment_type: container` but accept inventory overrides for Swarm compatibility.

---

## Working agreement for agents

When asking an agent for changes, always provide:

1. Target OS: `Debian` / `Ubuntu` (+ version if known)
2. Inventory example (hosts/groups) and connection type: `ansible_connection=ssh`
3. Role/playbook scope (files to touch, expected outputs)
4. Constraints:
   - avoid `shell`/`command` unless unavoidable
   - must pass `ansible-lint` and `yamllint`
   - must be idempotent
   - must support `--check` when possible
   - must respect deployment_type guards pattern

### Prompt template

Use this template to keep the agent grounded:

- Task: <what you want>
- OS: Debian/Ubuntu
- Connection: SSH
- Files allowed to change: <list>
- Must use modules first, avoid shell.
- Idempotent: yes (define changed_when/failed_when if needed)
- Deployment types: vm|container|swarm (specify which apply)
- Provide:
  - updated YAML files
  - a minimal playbook snippet to run it
  - molecule scenario updates (if role)
  - verification steps (commands)

---

## Local fast feedback (recommended)

Even if you run remotely via SSH, develop roles with a local loop:

### Lint/syntax

- `ansible-playbook --syntax-check playbooks/<name>.yml`
- `yamllint .`
- `ansible-lint`

### Role tests with Molecule (Docker/Podman)

Use Molecule to validate:

- converge
- idempotence
- verify (assertions)

Common commands:

- `molecule test`
- `molecule converge`
- `molecule idempotence`
- `molecule verify`

If containers are not an option, keep at least lint + syntax-check and run playbooks against a short-lived VM.

---

## 🗂️ Local Testing Inventories

For rapid playbook development and testing without remote machines, use the local inventories provided in `inventories/local/` and `inventories/dev/`.

### Purpose

- **`inventories/local/hosts.ini`** - Full deployment inventory (27 services)
  - Tests configuration generation, templates, variable inheritance
  - Mirrors lademo structure for compatibility
  - Use when you need comprehensive coverage of all services

- **`inventories/dev/hosts.ini`** - Minimal dev inventory (CAS + Collectory + Branding)
  - Rapid iteration for single-service testing
  - Faster playbook runs for quick feedback loops
  - Use with `--limit collectory` to test specific services

### Inventory Structure

Both inventories use the pattern `localhost.<service>` (e.g., `localhost.cas`, `localhost.collectory`):

```
[cas_servers]
localhost.cas ansible_host=localhost ansible_connection=local

[collectory]
localhost.collectory ansible_host=localhost ansible_connection=local
```

**Why `localhost.<service>`?**
- Ansible uses `inventory_hostname` (not `ansible_host`) as the primary key for hostvars
- Multiple hosts with same `ansible_host=localhost` require unique inventory names to avoid variable collisions
- Pattern matches lademo structure for maintainability

### Database Hostname Mapping

Both inventories include a `[docker_compose_hosts:vars]` section that maps service database variables to docker-compose container names:

```ini
[docker_compose_hosts:vars]
collectory_db_host_address = la_mysql
cas_db_hostname = la_mysql
user_store_db_hostname = la_mysql
# ... etc
```

This ensures services connect to the correct containers when running locally.

### Quick-Start Commands

**Validate inventory syntax:**
```bash
ansible-inventory -i inventories/local/hosts.ini --list
ansible-inventory -i inventories/dev/hosts.ini --list
```

**Syntax check playbooks with full inventory:**
```bash
ansible-playbook -i inventories/local playbooks/site.yml --syntax-check
```

**Test config generation with minimal dev setup:**
```bash
ansible-playbook -i inventories/dev playbooks/config-gen.yml --check --diff
```

**Limit to single service for debugging:**
```bash
ansible-playbook -i inventories/dev playbooks/config-gen.yml --limit collectory --check --diff -vvv
```

**Run with container deployment type:**
```bash
ansible-playbook -i inventories/local playbooks/site.yml -e deployment_type=container --check --diff
```

### Regenerating Inventories

If services are added/removed or the inventory structure changes:

```bash
cd la-docker-compose
python3 scripts/create_local_inventory.py full > inventories/local/hosts.ini
python3 scripts/create_local_inventory.py dev > inventories/dev/hosts.ini
```

The script maintains service-to-group mappings and database hostname overrides. For future generator-living-atlas integration, `.yo-rc.json` can be added to automate regeneration.

### Reusable Variables

Both inventories inherit from `inventories/local/group_vars/all.yml`, which contains:

- Service versions
- Database credentials (test values only)
- URLs, ports, and endpoints
- Deployment type: `deployment_type: container`

This file should be updated with test values for new services added to the local inventory.

---

## Remote SSH execution practices (Debian/Ubuntu)

### Inventory hygiene

- Use group vars and host vars rather than embedding values in playbooks.
- Keep SSH config stable:
  - `ansible_user`
  - `ansible_port`
  - `ansible_ssh_private_key_file` (if needed)

### Safe flags for real runs

- Dry-run: `--check --diff`
- More context: `-vvv`
- Limit blast radius: `--limit <host_or_group>`
- Run subsets: `--tags <tag>` / `--skip-tags <tag>`

### Tagging policy

Mark slow or risky operations:

- `tags: [slow]` for downloads, compiles, migrations, big updates
- `tags: [risky]` for operations that could disrupt services
- `tags: [config]`, `[packages]`, `[service]` for common grouping

Default development loop should avoid slow/risky tags.

---

## Idempotence rules

- Prefer Ansible modules over shell.
- If `command`/`shell` is unavoidable:
  - use `creates` / `removes` when applicable
  - define `changed_when` and `failed_when`
  - avoid fragile pipelines

Use handlers for restarts/reloads:

- templates notify a handler
- handler restarts/reloads the service once per run

### Inventory Re-executability Requirement

**Critical**: Inventories must be executable **multiple times without errors or data loss**:

- Running playbooks against the same inventory twice should result in identical state (idempotent)
- Re-running should not overwrite configuration or corrupt data
- Failed deployments must be resumable without manual cleanup
- Database volumes and persistent data are protected via `external: true` in docker-compose.yml

This is essential for:
- CI/CD robustness (retries on transient failures)
- Development iteration (running playbooks repeatedly during debugging)
- Production safety (predictable state transitions)

Example problematic patterns to AVOID:
```yaml
# ❌ BAD: Destructive without cleanup (state metadata orphaned)
- name: Start services
  command: docker compose up -d

# ✅ GOOD: Idempotent with cleanup
- name: Clean orphaned state
  block:
    - command: docker compose down --remove-orphans
      chdir: "{{ compose_dir }}"
      failed_when:
        - result.rc != 0
        - "'No such file or directory' not in result.stderr"
    - command: docker system prune -f --volumes
      ignore_errors: true
      
- name: Start services
  command: docker compose up -d --remove-orphans
```

### Docker Compose Idempotence Issues

**Problem**: `docker compose` can leave orphaned state metadata that causes "No such container" errors on subsequent runs.

**Root Cause**: When containers are recreated between deployments, Docker Compose maintains internal state references (metadata, networks, partially-deleted state trees) that the daemon no longer knows about.

**Solution Pattern**:
1. Always run `docker compose down --remove-orphans` before `docker compose up`
2. Follow immediately with `docker system prune -f --volumes` to clean dangling resources
3. Use `--remove-orphans` flag in `docker compose up` as final safeguard
4. Define all data volumes as `external: true` to prevent accidental deletion

**See**: `roles/la-compose/tasks/main.yml:106-140` for reference implementation.

---

## Debian/Ubuntu specifics

### Packages

- Use `ansible.builtin.apt` or `ansible.builtin.package`
- Ensure cache updates are explicit and not repeated unnecessarily
- Avoid full-upgrades unless intentional and tagged as `risky` or `slow`

### Services

- Use `ansible.builtin.service` or `ansible.builtin.systemd`
- Always define the desired enable/running state explicitly

### Files and templates

- Use `template` for config files
- Set ownership and permissions explicitly
- Use `validate` (when available) for config syntax checks, e.g. nginx

---

## Error handling and clarity

- Fail early with `assert` for required variables.
- For risky blocks, use `block/rescue/always` to provide actionable errors.
- Keep tasks short and readable; avoid complex one-liners.

---

## Pull request checklist

Before merging:

- `yamllint` passes
- `ansible-lint` passes (or justified waivers documented)
- Molecule `test` passes (for changed roles)
- Playbook runs with `--check --diff` cleanly where possible
- No secrets committed
- Variables documented in `README.md` for each role
- deployment_type guards added where VM-only tasks exist
- No task duplication across roles

---

## Minimal "definition of done" for agent-generated changes

A change is acceptable when it includes:

- code updates limited to the requested scope
- idempotent tasks
- lint clean
- at least one verification path:
  - molecule scenario, or
  - a reproducible remote run command with `--limit` and `--check --diff`
- deployment_type guards applied consistently
- no breaking changes to existing VM deployments

---

## Suggested tooling (optional but useful)

- `pre-commit` hooks:
  - `yamllint`
  - `ansible-lint`
- Pinned dependencies:
  - `ansible-core`
  - `ansible-lint`
  - collections in `collections/requirements.yml`

---

## Example run commands

Remote (safe):

- `ansible-playbook -i inventory.ini playbooks/site.yml --limit web --check --diff`
- `ansible-playbook -i inventory.ini playbooks/site.yml --limit web -vvv`

Role development:

- `cd roles/<role_name> && molecule test`

Docker-compose deployment (with deployment_type):

- `ansible-playbook -i inventory.ini playbooks/site.yml -e deployment_type=container`
- `ansible-playbook -i inventory.ini playbooks/site.yml -e deployment_type=vm --check --diff`

---

## 📚 Related Documentation

- `la-docker-compose-plan.md` - Detailed project plan and architecture
- `la-docker-compose-overview.md` - System overview and deployment types
- `Jenkinsfile` - CI/CD pipeline (uses ALA_INSTALL_BRANCH parameter)

---

## 🔍 Jenkins CI/CD References

### Main Testing Job

- **Job**: `la-docker-compose-tests`
  - URL: https://jenkins.gbif.es/job/la-docker-compose-tests/
  - Branch: `main` (la-docker-compose repo)
  - Trigger: SCM changes + manual
  - Parameters:
    - `ALA_INSTALL_BRANCH` - which ala-install branch to use (default: `docker-compose-min-pr`)
    - `GENERATOR_BRANCH` - inventory generator branch (default: `master`)
    - `AUTO_DEPLOY` - auto-run playbooks after inventory generation
    - `FORCE_REDEPLOY` - force full redeployment
    - `CLEAN_MACHINE` - clean machines before deploy
  - Pipeline stages: Clean machines → Prepare env → Update deps → Decide redeploy → Install generator → Regenerate inventories → Run Playbooks → Validate

### When to Check Logs

Use MCP commands to quickly check recent failures:

```bash
# Check last build status and result
jenkins_getBuild jobFullName=la-docker-compose-tests

# Get last 100 lines of logs (use negative limit for end of log)
jenkins_getBuildLog jobFullName=la-docker-compose-tests limit=-100

# Search for specific error pattern
jenkins_searchBuildLog jobFullName=la-docker-compose-tests pattern="ERROR.*pattern" contextLines=5
```

### Common Failures to Check

1. **Missing files** - look for `Could not find or access` errors
2. **Ansible syntax** - look for `FAILED! Error parsing`
3. **Include/import failures** - look for `Could not find or access` in playbooks/
4. **Task execution** - look for `fatal:` or `failed=1` in PLAY RECAP

---

## 📚 Architecture & Design Documentation

### Build #83: CAS Configuration Directory Fix Analysis

**Location:** `BUILD_83_FIX.md`

This document captures the root cause analysis, solution design, and testing approach for the Build #83 CAS container startup failure. Key learnings:

**The Problem:**
- Service roles in `generate-compose.yml` used conditions like `when: "'cas-servers' in group_names"`
- In docker-compose architecture, services are host aliases (e.g., `hostname.cas`), not group memberships
- Group membership checks fail when executing playbook against the physical host

**The Pattern:**
- Use dynamically-calculated `service_aliases` fact instead of static group membership checks
- Fact maps service groups to their actual host aliases at runtime
- Provides safe fallback if alias doesn't exist (check fails safely)

**Why It Matters:**
- Reveals a fundamental architectural pattern for multi-service deployments
- Shows how to properly include roles when services are represented as aliases
- Demonstrates collision-risk testing (Issue #10) to verify variable isolation

**When to Reference:**
- Before modifying service role inclusion conditions in `generate-compose.yml`
- When adding new services to the deployment
- When debugging why services aren't starting (check if role inclusion is skipped)
- When reviewing related changes to understand the inventory architecture

**Recommended Reading:**
Start with "The Problem in Detail" section to understand the context, then skip to "The Solution" for the fix pattern.

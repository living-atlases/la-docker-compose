<!-- refreshed: 2026-04-27 -->
# Architecture

**Analysis Date:** 2026-04-27

## System Overview

```text
┌─────────────────────────────────────────────────────────────────────┐
│                    Operator Workflow                                 │
│  la-toolkit (Flutter UI) → generator-living-atlas (Yeoman/Node.js)  │
└────────────────────────────────┬────────────────────────────────────┘
                                 │ produces Ansible inventory
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Ansible Inventory                                 │
│  inventories/local/  inventories/dev/  (or lademo/lademo-inventories)│
│  hosts, group_vars, service variables                               │
└────────────────────────────────┬────────────────────────────────────┘
                                 │ consumed by
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                  la-docker-compose (this repo)                      │
│                                                                     │
│  playbooks/site.yml                                                 │
│      ├─ roles/la-compose           (orchestration)                  │
│      │   ├─ tasks/setup-facts.yml  (service detection)              │
│      │   ├─ tasks/generate-compose.yml (config generation)          │
│      │   ├─ tasks/init-databases.yml   (DB init)                    │
│      │   ├─ tasks/validate-*.yml       (pre/post deploy validation) │
│      │   └─ templates/docker-compose/  (Jinja2 compose templates)   │
│      └─ roles/la-volumes          (Docker volume management)        │
│                                                                     │
│  External: ala-install/ansible/roles/  (config generation logic)    │
│      ├─ common, cas5, userdetails, apikey, cas-management           │
│      ├─ collectory, species-list, bie-hub, bie-index                │
│      ├─ biocache-hub, biocache3-service, biocache3-properties       │
│      ├─ image-service, logger-service, namematching-service         │
│      ├─ solrcloud_config, biocache3-db                              │
│      └─ nginx, nginx_vhost, gatus                                   │
└────────────────────────────────┬────────────────────────────────────┘
                                 │ generates
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│               Generated Docker Compose Output (/data/docker-compose)│
│                                                                     │
│  docker-compose.yml          (base compose file, service includes)  │
│  .env                        (secrets, passwords, JAVA_OPTS)        │
│  infrastructure/             (nginx, mysql, mongodb, solr, etc.)    │
│  services/                   (cas, collectory, bie-hub, etc.)       │
│  nginx/                      (nginx.conf, sites-enabled/, conf.d/)  │
│  gatus/config/config.yaml    (health monitoring)                    │
│  dockerfiles/                (branding build context)               │
│  solr/init/  cassandra/init/ (DB initialization files)             │
└─────────────────────────────────────────────────────────────────────┘
                                 │ runs via
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                  Docker Compose Runtime                             │
│                                                                     │
│  Infrastructure: la_nginx, la_mysql, la_mongodb, la_solr            │
│                  la_cassandra, la_elasticsearch, la_postgres         │
│                  la_postfix/la_mailhog, la_gatus                    │
│                                                                     │
│  ALA Services:   la_cas, la_cas_management, la_userdetails          │
│                  la_apikey, la_collectory, la_species_list           │
│                  la_bie_hub, la_bie_index, la_biocache_hub           │
│                  la_biocache_service, la_image_service               │
│                  la_logger_service, la_namematching_service          │
│                  la_doi_service, la_sensitive_data_service           │
│                  la_pipelines, la_branding, la_ala_i18n              │
└─────────────────────────────────────────────────────────────────────┘
```

## Component Responsibilities

| Component | Responsibility | File |
|-----------|----------------|------|
| `playbooks/site.yml` | Main deployment entry point | `playbooks/site.yml` |
| `playbooks/config-gen.yml` | Config-only (no container start) | `playbooks/config-gen.yml` |
| `roles/la-compose` | Core orchestration: generate, deploy, validate | `roles/la-compose/` |
| `roles/la-volumes` | Create external Docker volumes (DB persistence) | `roles/la-volumes/` |
| `tasks/setup-facts.yml` | Detect services from inventory; compute physical_server_groups, service_aliases | `roles/la-compose/tasks/setup-facts.yml` |
| `tasks/generate-compose.yml` | Drive config gen via ala-install roles; generate all compose YAMLs | `roles/la-compose/tasks/generate-compose.yml` |
| `tasks/main.yml` | Top-level orchestration: setup→generate→validate→deploy | `roles/la-compose/tasks/main.yml` |
| `tasks/init-databases.yml` | CAS/MySQL/MongoDB schema init sequence | `roles/la-compose/tasks/init-databases.yml` |
| `tasks/validate-pre-deploy.yml` | Pre-deploy checks (compose file validity, SSL) | `roles/la-compose/tasks/validate-pre-deploy.yml` |
| `tasks/validate-post-deploy.yml` | Post-deploy health checks (container status, HTTP) | `roles/la-compose/tasks/validate-post-deploy.yml` |
| `templates/docker-compose/base.yml.j2` | Root compose file; includes infrastructure/ and services/ | `roles/la-compose/templates/docker-compose/base.yml.j2` |
| `ala-install/ansible/roles/` | Service config generation (Jinja2 templates → /data/<svc>/config/) | `ala-install/ansible/roles/` |
| `Jenkinsfile` | CI/CD pipeline (Jenkins) | `Jenkinsfile` |
| `inventories/local/` | Full 27-service test inventory (localhost aliases) | `inventories/local/` |
| `inventories/dev/` | Minimal 3-service dev inventory (CAS, Collectory, Branding) | `inventories/dev/` |

## Pattern Overview

**Overall:** Ansible-orchestrated Docker Compose generation with ala-install config reuse.

**Key Characteristics:**
- Config logic lives in `ala-install` (never duplicated in `la-docker-compose`)
- `la-docker-compose` is the thin "orchestration layer" — compose YAML generation + lifecycle management
- Service detection is dynamic: `setup-facts.yml` walks inventory to find which services share the physical host
- `deployment_type=container` is enforced in `generate-compose.yml` via `set_fact` (higher precedence than inventory vars)
- All data volumes marked `external: true` — never deleted on `docker compose down`

## Layers

**Orchestration Layer (la-compose role):**
- Purpose: Drive full deployment lifecycle
- Location: `roles/la-compose/tasks/main.yml`
- Contains: setup, generate, validate, deploy, init tasks
- Depends on: ala-install roles, la-volumes
- Used by: `playbooks/site.yml`, `playbooks/config-gen.yml`

**Config Generation Layer (ala-install roles):**
- Purpose: Generate service config files and nginx vhosts
- Location: `ala-install/ansible/roles/<service>/`
- Contains: Jinja2 templates, vars, defaults
- Depends on: inventory variables, deployment_type=container
- Used by: `generate-compose.yml` via `include_role`

**Template Layer (Jinja2 compose templates):**
- Purpose: Generate docker-compose YAML files for each service
- Location: `roles/la-compose/templates/docker-compose/`
- Contains: `base.yml.j2`, `infrastructure/*.yml.j2`, `services/*.yml.j2`
- Depends on: facts set during generate-compose.yml
- Used by: ansible template tasks in generate-compose.yml

**Inventory Layer:**
- Purpose: Single source of truth for all service config and topology
- Location: `inventories/local/`, `inventories/dev/`, or lademo inventories
- Contains: hosts, group_vars, service versions, credentials
- Depends on: generator-living-atlas (production); scripts/create_local_inventory.py (local)
- Used by: all playbooks

## Data Flow

### Full Deployment (site.yml)

1. Ansible reads inventory; `docker_compose` host is target (`playbooks/site.yml`)
2. `roles/la-compose/tasks/main.yml` starts; sets UID/GID facts
3. `setup-facts.yml` — walks all hosts sharing same `ansible_host`; computes `physical_server_groups`, `service_aliases`, `services_enabled`
4. `la-volumes` role — ensures external Docker volumes exist (mysql-data, postgres-data, mongodb-data, etc.)
5. `generate-compose.yml` — enforces `deployment_type=container`; runs ala-install `common` role for base facts
6. Per service: bulk-loads vars from service alias hostvar context → re-normalizes DB hostnames → `include_role` for ala-install service config generation (writes `/data/<service>/config/` files)
7. Generates `.env`, `docker-compose.yml`, `infrastructure/*.yml`, `services/*.yml`, nginx config, gatus config
8. `validate-pre-deploy.yml` — checks compose file, SSL certs
9. `docker compose down --remove-orphans` + `docker system prune -f --volumes`
10. `init-databases.yml` — runs DB init containers (MySQL, MongoDB)
11. `docker compose up -d --remove-orphans`
12. `init-cas-admin.yml` — registers OIDC service definitions
13. `validate-post-deploy.yml` — checks container status, HTTP endpoints

### Config-Only (config-gen.yml)

Same as above steps 1–8, but `auto_deploy=false` skips steps 9–13.

**State Management:**
- All mutable state lives in `/data/docker-compose/` on the target host
- Ansible facts computed fresh each run (no persistent fact cache required)
- External volumes persist data across redeployments

## Key Abstractions

**`service_aliases`:**
- Purpose: Maps service group names to their inventory hostname aliases (e.g., `cas-servers → localhost.cas`)
- Computed by: `setup-facts.yml`
- Used by: `generate-compose.yml` for bulk var loading and conditional role inclusion

**`physical_server_groups`:**
- Purpose: All service groups deployed on the same physical server as the `docker_compose` host
- Computed by: `setup-facts.yml` (walks hostvars matching `ansible_host`)
- Used by: service detection, conditional compose YAML generation

**`docker_services_desc`:**
- Purpose: Registry of all known services with group name, version variable, container name, etc.
- Location: `roles/la-compose/vars/docker-services-desc.yaml`
- Used by: `setup-facts.yml` for service detection, `generate-compose.yml` for build metadata

**`deployment_type`:**
- Purpose: Guards ala-install tasks to skip VM-specific operations in container deployments
- Value: always `container` in la-docker-compose (enforced via set_fact)
- Pattern: `when: deployment_type == 'vm' or deployment_type is undefined` in ala-install tasks

## Entry Points

**Full Deploy:**
- Location: `playbooks/site.yml`
- Triggers: Jenkins `la-docker-compose-tests` job, or `ansible-playbook -i inventories/local playbooks/site.yml`
- Responsibilities: Install Docker, generate configs, deploy containers

**Config Only:**
- Location: `playbooks/config-gen.yml`
- Triggers: `ansible-playbook -i inventories/dev playbooks/config-gen.yml`
- Responsibilities: Generate all config files without starting containers

**DB Init:**
- Location: `playbooks/db-init.yml`
- Triggers: Manual or post-deploy
- Responsibilities: Initialize MySQL/MongoDB schemas only

## Architectural Constraints

- **Idempotence required:** All tasks must be re-runnable. DB volumes `external: true` prevent accidental deletion. `docker compose down --remove-orphans` + `docker system prune` clears orphaned state before each deploy.
- **ala-install is external:** Never modify `ala-install/` directly. Use `deployment_type` guards in the fork branch (`docker-compose-min-pr`).
- **service_aliases pattern:** Use `service_aliases.get('group-name')` to check service presence — never `group_names` for service role inclusion in `generate-compose.yml`. Group membership checks fail because `docker_compose` host is not in service groups.
- **Global state:** `docker_services_desc` and `service_aliases` are computed per-run as Ansible facts; no module-level singletons.
- **Circular imports:** None known. ala-install roles are included via `include_role` (not imported), so late binding applies.
- **Container naming:** Convention `la_<service>` (e.g., `la_cas`, `la_mysql`). Used for nginx `proxy_pass` directives and cross-container networking.

## Anti-Patterns

### Using `group_names` for service role inclusion in generate-compose.yml

**What happens:** A task condition like `when: "'cas-servers' in group_names"` is used inside `generate-compose.yml`
**Why it's wrong:** `inventory_hostname` is the `docker_compose` host, which is not a member of service groups like `cas-servers`; the condition is always false
**Do this instead:** Use `when: service_aliases.get('cas-servers') is defined` — checks computed fact from `setup-facts.yml` (`roles/la-compose/tasks/setup-facts.yml`)

### Modifying ala-install roles without deployment_type guards

**What happens:** A task in an ala-install role runs unconditionally
**Why it's wrong:** VM-specific tasks (apt install, systemd, etc.) will fail in container context
**Do this instead:** Add `when: deployment_type == 'vm' or deployment_type is undefined` to VM tasks; use `when: deployment_type == 'container'` for container-only tasks

### Running `docker compose up` without cleanup

**What happens:** `docker compose up -d` called without prior `down --remove-orphans`
**Why it's wrong:** Leaves orphaned state metadata causing "No such container" errors on next run
**Do this instead:** Follow `roles/la-compose/tasks/main.yml:129-154` — always run `down --remove-orphans` + prune before `up`

## Error Handling

**Strategy:** Fail fast with assert blocks; use block/rescue for cleanup operations.

**Patterns:**
- Pre-deploy asserts: SSL certs, compose file validity, required variables
- DB init: `failed_when` guards on container exec commands
- compose down: `failed_when` allows "No such file/container" — idempotent teardown
- Post-deploy: HTTP endpoint health checks with retry logic

## Cross-Cutting Concerns

**Logging:** Service logs written to `/data/docker-compose/var-log-atlas/<service>/` via Docker volume mounts
**Validation:** 4-layer validation: pre-deploy (syntax, SSL), post-deploy (container status, HTTP), + ansible syntax-check, yamllint
**Authentication:** CAS is the auth hub; `init-cas-admin.yml` registers all OIDC clients after startup

---

*Architecture analysis: 2026-04-27*

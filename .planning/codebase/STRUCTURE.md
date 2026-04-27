# Codebase Structure

**Analysis Date:** 2026-04-27

## Directory Layout

```
la-docker-compose/
├── playbooks/                    # Ansible playbook entry points
│   ├── site.yml                  # Full deploy (config gen + docker run)
│   ├── config-gen.yml            # Config generation only (no container start)
│   ├── db-init.yml               # Database init only
│   ├── db-init-quick.yml         # Quick DB init (skip health waits)
│   ├── validate-compose.yml      # Validate generated compose files
│   ├── verify-inventory.yml      # Verify inventory structure
│   ├── test-config-gen.yml       # Test config generation
│   ├── test-services.yml         # Test running services
│   └── ansible.cfg               # Ansible config (roles_path, ala-install path)
│
├── roles/
│   ├── la-compose/               # Core role: orchestrate compose lifecycle
│   │   ├── defaults/main.yml     # Default vars (auto_deploy, enable_db_backup, etc.)
│   │   ├── vars/
│   │   │   ├── main.yml          # Internal vars (uid/gid, compose_dir, etc.)
│   │   │   └── docker-services-desc.yaml  # Service registry (group→container→version var)
│   │   ├── tasks/
│   │   │   ├── main.yml          # Top-level orchestration task flow
│   │   │   ├── setup-facts.yml   # Detect services: physical_server_groups, service_aliases
│   │   │   ├── generate-compose.yml  # Config gen: run ala-install roles + write compose YAMLs
│   │   │   ├── normalize-hostnames.yml  # Rewrite DB hostnames (localhost→container names)
│   │   │   ├── common.yml        # Shared setup (dirs, Docker install check)
│   │   │   ├── build-images.yml  # Branding image build (docker buildx bake)
│   │   │   ├── determine-java-versions.yml  # Map service version→Java version fact
│   │   │   ├── init-databases.yml    # MySQL/MongoDB schema init sequence
│   │   │   ├── init-cas-admin.yml    # CAS OIDC service registration (post-startup)
│   │   │   ├── validate-pre-deploy.yml   # SSL + compose file checks before deploy
│   │   │   ├── validate-post-deploy.yml  # Container status + HTTP health checks
│   │   │   ├── validate-docker-compose.yml  # Compose file syntax validation
│   │   │   └── validate-db-init.yml  # DB schema validation
│   │   ├── templates/
│   │   │   ├── docker-compose/
│   │   │   │   ├── base.yml.j2           # Root compose file (includes infrastructure + services)
│   │   │   │   ├── gatus/config.yaml.j2  # Gatus monitoring config
│   │   │   │   ├── infrastructure/       # One .yml.j2 per infra service
│   │   │   │   │   ├── nginx.yml.j2
│   │   │   │   │   ├── mysql.yml.j2
│   │   │   │   │   ├── mongodb.yml.j2
│   │   │   │   │   ├── postgres.yml.j2
│   │   │   │   │   ├── solr.yml.j2
│   │   │   │   │   ├── cassandra.yml.j2
│   │   │   │   │   ├── elasticsearch.yml.j2
│   │   │   │   │   ├── branding.yml.j2
│   │   │   │   │   ├── i18n.yml.j2
│   │   │   │   │   ├── mailhog.yml.j2
│   │   │   │   │   ├── postfix.yml.j2
│   │   │   │   │   ├── gatus.yml.j2
│   │   │   │   │   └── db-backup.yml.j2
│   │   │   │   └── services/             # One .yml.j2 per ALA service
│   │   │   │       ├── cas.yml.j2
│   │   │   │       ├── cas-management.yml.j2
│   │   │   │       ├── userdetails.yml.j2
│   │   │   │       ├── apikey.yml.j2
│   │   │   │       ├── collectory.yml.j2
│   │   │   │       ├── species-list.yml.j2
│   │   │   │       ├── bie-hub.yml.j2
│   │   │   │       ├── bie-index.yml.j2
│   │   │   │       ├── biocache-hub.yml.j2
│   │   │   │       ├── biocache-service.yml.j2
│   │   │   │       ├── image-service.yml.j2
│   │   │   │       ├── logger-service.yml.j2
│   │   │   │       ├── namematching-service.yml.j2
│   │   │   │       ├── sensitive-data-service.yml.j2
│   │   │   │       ├── pipelines.yml.j2
│   │   │   │       ├── userdetails.yml.j2
│   │   │   │       └── _i18n_volumes.yml.j2  # Shared i18n volume snippet
│   │   │   ├── docker-compose.env.j2     # .env file (secrets, JAVA_OPTS)
│   │   │   ├── docker-bake.hcl.j2        # Docker Buildx bake config (branding)
│   │   │   ├── java-opts-builder.j2      # JAVA_OPTS macro for each service
│   │   │   ├── determine_java_version.j2 # Java version lookup macro
│   │   │   ├── cert-validator.sh         # SSL cert validation script
│   │   │   └── gatus-endpoint.yaml.j2    # Per-service gatus endpoint snippet
│   │   ├── files/docker/branding/        # Branding Dockerfile build context
│   │   └── molecule/default/             # Molecule test scenario (converge.yml, molecule.yml)
│   │
│   └── la-volumes/                       # Role: ensure external Docker volumes exist
│       └── tasks/main.yml                # Creates named volumes (mysql-data, etc.)
│
├── inventories/
│   ├── local/                            # Full 27-service local test inventory
│   │   ├── hosts                         # hosts.ini with localhost.<service> aliases
│   │   └── group_vars/all.yml            # Service versions, credentials, URLs
│   └── dev/                              # Minimal 3-service dev inventory
│       └── hosts.ini                     # CAS + Collectory + Branding only
│
├── tests/
│   ├── README.md
│   ├── test-common-vars.yml              # Common variable tests
│   ├── test-full-flow.yml                # Full flow integration test
│   ├── test-no-localhost-configs.yml     # Verify no localhost in DB hostnames
│   ├── playbooks/                        # Test-only playbooks
│   ├── delegate_to_test/                 # Tests for delegate_to behavior
│   │   ├── inventories/
│   │   └── playbooks/
│   └── variable-collision-test/          # Issue #10: variable isolation tests
│       ├── inventories/
│       ├── playbooks/
│       └── roles/
│
├── scripts/
│   ├── create_local_inventory.py         # Generate inventories/local and inventories/dev
│   ├── diagnose-failure.sh               # Post-failure diagnostic script
│   ├── validate-ansible.sh               # Run yamllint + ansible-lint
│   ├── validate-local.sh                 # Run local validation suite
│   ├── verify-uid-fix.sh                 # Verify container UID/GID
│   └── wait-for-health.sh                # Poll container health endpoints
│
├── ala-install/                          # Git submodule: ALA roles (branch: docker-compose-min-pr)
│   └── ansible/roles/<service>/          # Config generation roles for each service
│
├── Jenkinsfile                           # CI/CD pipeline (la-docker-compose-tests job)
├── AGENTS.md                             # Agent/AI development guidelines
├── README.md                             # Project overview
├── TODO.org                              # Open tasks (Org mode)
├── VALIDATION.md                         # Validation strategy docs
├── BUILD_*.md                            # Build failure analyses and fix summaries
└── test-inventory.yml                    # Quick inventory test playbook
```

## Directory Purposes

**`playbooks/`:**
- Purpose: Deployment and maintenance entry points
- Contains: Site, config-gen, db-init, validate, test playbooks
- Key files: `playbooks/site.yml`, `playbooks/config-gen.yml`

**`roles/la-compose/`:**
- Purpose: Core orchestration role — the only code that is unique to this repo
- Contains: All tasks for generating, deploying, and validating the docker-compose stack
- Key files: `roles/la-compose/tasks/main.yml`, `roles/la-compose/tasks/generate-compose.yml`, `roles/la-compose/tasks/setup-facts.yml`

**`roles/la-compose/templates/docker-compose/`:**
- Purpose: Jinja2 templates that produce the actual docker-compose YAML files
- Contains: `base.yml.j2` (root), `infrastructure/*.yml.j2` (DBs, nginx, etc.), `services/*.yml.j2` (ALA services)
- Key files: `roles/la-compose/templates/docker-compose/base.yml.j2`

**`roles/la-compose/vars/docker-services-desc.yaml`:**
- Purpose: Central registry of all known ALA services
- Contains: service group name, container name, version variable, image name, healthcheck
- Used by `setup-facts.yml` and `generate-compose.yml` for service detection and metadata

**`roles/la-volumes/`:**
- Purpose: Idempotent creation of named Docker volumes with `external: true`
- Contains: Single tasks file (`main.yml`)
- Key files: `roles/la-volumes/tasks/main.yml`

**`inventories/local/`:**
- Purpose: Full 27-service test inventory for local development
- Contains: `hosts` (localhost aliases per service), `group_vars/all.yml` (all service config)
- Key files: `inventories/local/group_vars/all.yml`

**`inventories/dev/`:**
- Purpose: Minimal 3-service inventory for rapid iteration
- Contains: `hosts.ini` with CAS, Collectory, Branding
- Key files: `inventories/dev/hosts.ini`

**`tests/`:**
- Purpose: Integration and unit test playbooks
- Contains: Variable collision tests, delegate_to tests, flow tests
- Key files: `tests/variable-collision-test/` (Issue #10 regression tests)

**`scripts/`:**
- Purpose: Dev tooling and CI helpers
- Contains: Inventory generator, validators, diagnostic tools
- Key files: `scripts/create_local_inventory.py`, `scripts/validate-ansible.sh`

**`ala-install/`:**
- Purpose: External dependency (git submodule) — config generation roles
- Generated: No — vendored via git submodule (branch: `docker-compose-min-pr`)
- Committed: Submodule reference only; full content synced from fork

## Key File Locations

**Entry Points:**
- `playbooks/site.yml`: Full deploy (use with `inventories/local` or production inventory)
- `playbooks/config-gen.yml`: Config generation without deploy
- `playbooks/db-init.yml`: Database init sequence

**Configuration:**
- `playbooks/ansible.cfg`: Sets `roles_path = roles:ala-install/ansible/roles`
- `roles/la-compose/defaults/main.yml`: Toggle defaults (`auto_deploy`, `force_redeploy`, etc.)
- `roles/la-compose/vars/docker-services-desc.yaml`: Service registry (add new services here)
- `inventories/local/group_vars/all.yml`: Full local test config

**Core Logic:**
- `roles/la-compose/tasks/setup-facts.yml`: Service detection
- `roles/la-compose/tasks/generate-compose.yml`: Config generation loop
- `roles/la-compose/tasks/main.yml`: Lifecycle orchestration
- `roles/la-compose/tasks/normalize-hostnames.yml`: DB hostname rewriting

**Testing:**
- `tests/variable-collision-test/`: Variable isolation regression tests
- `roles/la-compose/molecule/default/converge.yml`: Molecule converge scenario

## Naming Conventions

**Files:**
- Ansible tasks: `kebab-case.yml` (e.g., `setup-facts.yml`, `init-databases.yml`)
- Jinja2 templates: `<service-name>.yml.j2` matching group name (e.g., `cas.yml.j2`, `bie-hub.yml.j2`)
- Inventory hosts: `localhost.<service>` pattern (e.g., `localhost.cas`, `localhost.collectory`)

**Directories:**
- Role subdirs: standard Ansible layout (`tasks/`, `templates/`, `defaults/`, `vars/`, `files/`)
- Template subdirs mirror output layout: `templates/docker-compose/infrastructure/`, `templates/docker-compose/services/`

**Variables:**
- Service group: `<service>-servers` or `<service>_servers` (ala-install convention)
- Container names: `la_<service>` with underscores (e.g., `la_cas`, `la_mysql`, `la_bie_hub`)
- Volume names: `<service>-data` with dashes (e.g., `mysql-data`, `postgres-data`)
- Compose output dir: `/data/docker-compose/` on target host

## Where to Add New Code

**New ALA Service (e.g., `my-service`):**
1. Add entry to `roles/la-compose/vars/docker-services-desc.yaml` with group, container name, version var, image
2. Add ala-install role to `ala-install/ansible/roles/my-service/` with `deployment_type` guards
3. Create compose template: `roles/la-compose/templates/docker-compose/services/my-service.yml.j2`
4. Add service include block to `roles/la-compose/tasks/generate-compose.yml` (follow existing pattern)
5. Add to `inventories/local/group_vars/all.yml` and `inventories/local/hosts`
6. Run `scripts/create_local_inventory.py` if using auto-generated inventory

**New Infrastructure Service (e.g., `redis`):**
1. Create compose template: `roles/la-compose/templates/docker-compose/infrastructure/redis.yml.j2`
2. Add volume in `roles/la-volumes/tasks/main.yml` if persistent data needed
3. Add conditional include in `roles/la-compose/templates/docker-compose/base.yml.j2`
4. Add enable flag to `roles/la-compose/defaults/main.yml` (e.g., `enable_redis: false`)

**New Playbook:**
- Place in `playbooks/`
- Include `roles/la-compose` or specific tasks via `include_tasks`
- Use `-i inventories/local` or `-i inventories/dev` for local testing

**Shared Helpers / Utilities:**
- Jinja2 macros: `roles/la-compose/templates/` (e.g., `java-opts-builder.j2`, `determine_java_version.j2`)
- Shell scripts: `scripts/`
- Test playbooks: `tests/playbooks/`

## Special Directories

**`ala-install/`:**
- Purpose: ALA config generation roles (vendored git submodule)
- Generated: No
- Committed: Submodule pointer; never edit directly

**`.ansible/`:**
- Purpose: Ansible collections and modules cache
- Generated: Yes (ansible-galaxy install)
- Committed: No

**`roles/la-compose/molecule/`:**
- Purpose: Molecule test scenarios for la-compose role
- Generated: No
- Committed: Yes

**`graphify-out/`:**
- Purpose: Knowledge graph output (generated by graphify skill)
- Generated: Yes
- Committed: No (in .gitignore or ignored)

**`BUILD_*.md` files:**
- Purpose: Post-mortem analyses and fix summaries for Jenkins CI failures
- Use as: Reference docs when debugging similar failures in future builds

---

*Structure analysis: 2026-04-27*

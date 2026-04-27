# Technology Stack

**Analysis Date:** 2026-04-27

## Languages

**Primary:**
- YAML - Ansible playbooks, roles, inventories, docker-compose templates
- Jinja2 - Template engine for docker-compose and config file generation (`.j2` files)
- Python 3 - Ansible runtime, inventory generation scripts, validation helpers

**Secondary:**
- Bash/Shell - Jenkins pipeline inline scripts, validation/diagnostic scripts (`scripts/*.sh`)
- Groovy - Jenkins declarative pipeline (`Jenkinsfile`)
- Node.js / JavaScript - `generator-living-atlas` inventory generator (npm package, Yeoman-based)

## Runtime

**Environment:**
- Python 3 (3.13+ on dev host, venv per CI run)
- Node.js 22 (Jenkins `node-22` tool, `branding_node_version: 18` for branding builds)
- Docker Engine + Docker Compose v2 plugin (`docker compose` CLI)

**Package Manager:**
- pip (Python, for Ansible venv in CI: `python3 -m venv` + `pip install ansible`)
- npm / `npm ci` (for `generator-living-atlas` and inventory regeneration in CI)
- npm lockfile strategy: uses `npm ci` when `package-lock.json` present, else `npm install --ignore-scripts`

## Frameworks

**Core:**
- Ansible Core 2.17.3 - Orchestrates config generation and deployment
  - Config: `playbooks/ansible.cfg`
  - Role path: `../ala-install/ansible/roles:../roles`
  - Fact caching: jsonfile at `/tmp/ansible_facts` (3600s TTL)
- Docker Compose v2 - Container orchestration for Living Atlas services
  - Generated output: `/data/docker-compose/docker-compose.yml`
  - Multi-file compose: `include:` directives for infrastructure + services

**Inventory Generation:**
- Yeoman (`yo`) + `generator-living-atlas` npm package - generates `lademo-inventory.ini`
  - Run via: `node ./node_modules/yo/lib/cli.js living-atlas --replay-dont-ask --force`
  - Dependencies: `yo`, `yeoman-environment`, `yeoman-generator`, `generator-living-atlas@latest`

**Testing/Validation:**
- Molecule - Role testing (`roles/la-compose/molecule/`)
- `yamllint` - YAML syntax validation
- `ansible-lint` - Ansible best-practice linting
- `scripts/validate-local.sh` - Local full-stack validation
- `scripts/validate-ansible.sh` - Ansible lint + syntax check

**Monitoring:**
- Gatus (`twinproduction/gatus:latest`) - Service health dashboard
  - Config generated via `roles/la-compose/templates/docker-compose/infrastructure/gatus.yml.j2`

## Key Dependencies

**Critical:**
- `ala-install` (git submodule, branch `docker-compose-min-pr`) - Provides 13+ ALA roles used in dry-run mode; 66 `deployment_type` guards added
- `generator-living-atlas` (npm, `@latest`) - Generates Ansible inventory from `.yo-rc.json`
- `la-docker-images` (external, assumed at `/data/la-docker-images/`) - Pre-built ALA service Docker images consumed by generated compose

**Infrastructure (Docker images used in templates):**
- `mysql:8.0-debian` - Relational DB for CAS, Collectory, Userdetails, Apikey, SpeciesList
- `mongo:7` - MongoDB for CAS ticket registry, audit, sessions
- `postgres:16-alpine` - PostgreSQL for Spatial, Image Service, DOI Service
- `solr:9.4` (default, `solrcloud_version` var) - SolrCloud for biocache/bie indexing
- `elasticsearch:8.10.0` (docker.elastic.co) - Search for Image Service, Events, DOI
- `cassandra:5.0.6` (default, `cassandra_version` var) - NoSQL for biocache occurrence data
- `nginx:1.25` (default, `docker_nginx_version`) - Reverse proxy / TLS termination
- `boky/postfix` - Outbound SMTP relay
- `alpine/openssl:latest` - SSL certificate validator init container
- `livingatlases/l-a-site-certs:latest` - Demo TLS certs init container (optional)
- `node:18-bookworm-slim` / `nginx:1.27-alpine` - Branding multi-stage build

## Configuration

**Environment:**
- `deployment_type: container` - Set globally in `inventories/local/group_vars/all.yml` and `roles/la-compose/defaults/main.yml`
- Valid values: `vm`, `container`, `swarm`
- Key vars in `inventories/local/group_vars/all.yml`: service versions, DB credentials (test values), URLs, ports
- Runtime secrets injected as env vars via `.env` file generated from template `docker-compose.env.j2`

**Build:**
- Docker BuildKit / `docker buildx bake` - Used for branding image builds (`docker-bake.hcl.j2` template)
- Multi-stage `Dockerfile` in `roles/la-compose/files/docker/branding/Dockerfile`
- Supports Brunch and Vite build systems for branding

**Ansible:**
- `playbooks/ansible.cfg` - Roles path, collection paths, fact caching, `interpreter_python = auto_silent`
- `ANSIBLE_ROLES_PATH` injected by Jenkinsfile: `${WORKSPACE}/ala-install/ansible/roles:${WORKSPACE}/roles`
- `ANSIBLE_STDOUT_CALLBACK=yaml`, `ANSIBLE_FORCE_COLOR=true`

## Platform Requirements

**Development:**
- Docker Engine with Compose v2 plugin
- Python 3 + pip (for Ansible)
- Node.js 18+ (for generator-living-atlas)
- `ala-install` repo cloned as git submodule
- `/data/` directory writable (volumes and config output)

**Production (CI/CD):**
- Jenkins with `nodejs 'node-22'` tool configured
- Target hosts: `gbif-es-docker-cluster-2023-1/2/3` (SSH accessible from Jenkins)
- Python venv at `${HOME}/ala-install-docker-tests/.venv-ansible`
- SSH key access from Jenkins agent to target hosts

---

*Stack analysis: 2026-04-27*

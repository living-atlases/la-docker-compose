# Living Atlas Docker Compose

This repository generates `docker-compose.yml` configurations and handles local deployments of the Living Atlas ecosystem. It bridges the gap between Ansible playbooks (designed for VMs) and containerized local development without duplicating configuration logic.

## Overview

Unlike traditional deployments where `ala-install` directly mutates the state of a VM, this project uses the same `ala-install` roles in "dry-run" mode to generate all necessary configuration files, certificates, and database schemas. It then wraps them in a `docker-compose.yml` file, mounts these configurations as volumes, and runs the official `la-docker-images` containers.

### Key benefits

- Reuses >90% of existing `ala-install` logic.
- Maintains a single source of truth for inventory variables.
- Enables the "dev-overlay" pattern for local frontend/backend development.

---

## Directory Structure

- `playbooks/`: Entrypoints for Ansible runs (`site.yml`, `config-gen.yml`).
- `inventories/local/`: Typical local inventory to deploy a full subset of services.
- `inventories/dev/`: Specialized local development inventory using the `localhost.service` pattern.
- `roles/la-compose/`: The core role that parses `ala-install` facts and generates `docker-compose.yml`.
- `roles/la-volumes/`: Role managing persistent Docker volumes.

---

## Getting Started

### Prerequisites

You must have `ala-install` cloned alongside this repository.

```bash
/data/
├── ala-install/
├── la-docker-images/
└── la-docker-compose/
```

### 1. Generating local compose (dry-run)

If you only want to generate the configuration files and the `docker-compose.yml` file without automatically starting the containers (useful for inspecting the generated compose stack):

```bash
ansible-playbook playbooks/config-gen.yml -i inventories/local/hosts.ini
```

### 2. Deploying a local stack

This generates the configuration and automatically runs `docker compose up -d`:

```bash
ansible-playbook playbooks/site.yml -i inventories/local/hosts.ini
```

### 3. Database Initialization (CAS, Userdetails, Apikey)

The first time you deploy, or if you wipe the volumes, you must initialize the databases and users:

```bash
ansible-playbook playbooks/db-init.yml -i inventories/local/hosts.ini
```

This playbook:

- Starts MySQL and MongoDB.
- Creates necessary databases and users.
- Runs CAS for Flyway migrations.
- Creates the default CAS admin account.
- Registers OIDC services.

---

## Working in "dev-overlay" mode

The "dev-overlay" pattern is designed for developers who want to run 1-2 services locally (e.g., Collectory, Branding) while consuming the rest of the ecosystem from a production or staging cluster.

### How it works

1. Your local `nginx` intercepts traffic for the services you are running locally.
2. It uses `proxy_pass` to route all other traffic to the remote `proxy_remote_portal`.
3. Java applications resolve remote DBs through `docker_extra_hosts`.

### Usage

Edit `inventories/dev/hosts.ini` to uncomment/comment the services you wish to run locally:

```ini
[docker_compose]
localhost.collectory    ansible_host=localhost ansible_connection=local
#localhost.cas-servers   ansible_host=localhost ansible_connection=local
```

Then limit your playbook run:

```bash
ansible-playbook playbooks/config-gen.yml -i inventories/dev/hosts.ini --limit collectory
# Start only what you need
cd /data/docker-compose && docker compose up -d
```

---

## Testing & Dry-run

### Local Inventories for Testing

Two pre-configured inventories are available for testing playbooks without remote hosts:

#### `inventories/local/hosts.ini` - Full deployment
- All 27 Living Atlas services
- Uses `localhost.<service>` pattern (no SSH)
- Mirrors lademo structure for compatibility
- Use for comprehensive testing

#### `inventories/dev/hosts.ini` - Minimal dev setup
- 4 services: CAS, Collectory, Branding, docker_compose
- Fast feedback loop for development
- Use for rapid iteration or testing single services

### Quick-Start Testing Commands

#### 1. Validate inventory loads correctly (fastest)
```bash
cd /home/vjrj/proyectos/gbif/dev/la-docker-compose
ansible-playbook -i inventories/local/hosts.ini test-inventory.yml --check
```
Shows:
- All 27 hosts loaded correctly
- `deployment_type=container` verified
- Group assignments and variables inherited

#### 2. Syntax check playbooks (safe, no execution)
```bash
# Full playbook
ansible-playbook -i inventories/local/hosts.ini playbooks/site.yml --syntax-check

# Config generation only
ansible-playbook -i inventories/dev/hosts.ini playbooks/config-gen.yml --syntax-check
```

#### 3. Dry-run with changes preview (--check --diff)
```bash
# See what would be generated (limited to docker_compose host)
ansible-playbook -i inventories/local/hosts.ini playbooks/config-gen.yml \
  --limit docker_compose --check --diff -v | head -200

# Full dry-run with minimal dev setup
ansible-playbook -i inventories/dev/hosts.ini playbooks/config-gen.yml --check --diff
```

### Advanced Testing Scenarios

#### View all hosts in inventory
```bash
ansible -i inventories/local/hosts.ini all --list-hosts
```

#### Check variables for a specific host
```bash
ansible -i inventories/local/hosts.ini localhost.cas -m debug -a "var=deployment_type"
```

#### Test specific group
```bash
ansible-playbook -i inventories/local/hosts.ini playbooks/config-gen.yml \
  --limit docker_compose_hosts --check
```

### Regenerating Inventories

If services are added/removed or inventory structure changes:

```bash
cd /home/vjrj/proyectos/gbif/dev/la-docker-compose
python3 scripts/create_local_inventory.py full > inventories/local/hosts.ini
python3 scripts/create_local_inventory.py dev > inventories/dev/hosts.ini
```

The script `create_local_inventory.py` contains service mappings that can be easily updated:
- `SERVICES_FULL` dict (26 services)
- `SERVICES_DEV` dict (4 services)
- `GROUP_MAPPING` (group-to-service associations)

For future integration with `generator-living-atlas`, a `.yo-rc.json` config can be added to automate this.

### Inventory Structure Details

Both inventories use the `localhost.<service>` pattern:

```ini
[collectory]
localhost.collectory ansible_host=localhost ansible_connection=local

[docker_compose]
localhost.docker_compose ansible_host=localhost ansible_connection=local

[docker_compose_hosts:vars]
deployment_type = container
collectory_db_host_address = la_mysql
# ... database hostname overrides for docker-compose containers
```

**Why `localhost.<service>`?**
- Ansible uses `inventory_hostname` (not `ansible_host`) as the primary key for hostvars
- Multiple hosts with same `ansible_host=localhost` require unique names to avoid variable collisions
- Pattern matches lademo structure for maintainability and future generator integration

### Shared Variables

Both inventories inherit from `inventories/local/group_vars/all.yml`:
- Service versions (CAS, Collectory, etc.)
- Database credentials (test values only)
- URLs, ports, and endpoints
- `deployment_type: container` (set in `[docker_compose_hosts:vars]`)
- Docker network configuration

---

## Testing Strategy

A comprehensive testing pipeline is available to validate configuration and services at every stage.

### Testing Phases

```
┌─────────────────────────────────────────────────────────────┐
│ 1. Inventory & Variables                                    │
│    verify-inventory.yml ──► Validate variables are loaded   │
└─────────────────────────────────────────────────────────────┘
                    ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. Configuration Generation                                 │
│    config-gen.yml ──► Generate docker-compose.yml + .env    │
└─────────────────────────────────────────────────────────────┘
                    ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. Generated Config Validation                              │
│    validate-compose.yml ──► Verify YAML syntax & structure  │
└─────────────────────────────────────────────────────────────┘
                    ▼
┌─────────────────────────────────────────────────────────────┐
│ 4. Deploy & Runtime Tests                                   │
│    site.yml ──► docker-compose up -d                        │
│    test-services.yml ──► Health checks & connectivity       │
└─────────────────────────────────────────────────────────────┘
```

### Phase 1: Inventory & Variables Verification

**Purpose:** Catch missing or invalid variables early before generation

```bash
# Verify all hosts load correctly and have required variables
ansible-playbook playbooks/verify-inventory.yml -i inventories/local/hosts.ini

# Show variables for a specific host
ansible -i inventories/local/hosts.ini localhost.cas -m debug -a "var=deployment_type"

# Show all variables for a host
ansible -i inventories/local/hosts.ini localhost.docker_compose -m debug -a "var=hostvars[inventory_hostname]" | head -50
```

**What it checks:**
- ✓ All hosts load from inventory
- ✓ Critical variables defined (org_short_name, org_name_long, deployment_type)
- ✓ deployment_type is valid (vm, container, or swarm)
- ✓ Database hostname mappings configured
- ✓ docker_compose_hosts group populated
- ✓ Total variable count

### Phase 2: Configuration Generation (--check mode)

**Purpose:** Generate configuration files and detect issues without applying

```bash
# Dry-run: See what would be generated
ansible-playbook playbooks/config-gen.yml -i inventories/local/hosts.ini --check -v

# Dry-run limited to docker_compose host (faster)
ansible-playbook playbooks/config-gen.yml -i inventories/local/hosts.ini --limit docker_compose --check -v

# Actual generation (creates files)
ansible-playbook playbooks/config-gen.yml -i inventories/local/hosts.ini
```

**What it generates:**
- ✓ `/data/docker-compose/docker-compose.yml` (v3.8 format)
- ✓ `/data/docker-compose/.env` (database credentials)
- ✓ `/data/docker-compose/infrastructure/*.yml` (nginx, mysql, postgres, mongodb)
- ✓ `/data/docker-compose/services/*.yml` (all enabled services)
- ✓ `/data/logs/` directories for each service

### Phase 3: Generated Configuration Validation

**Purpose:** Verify the generated docker-compose.yml is valid and complete

```bash
# Validate generated configuration
ansible-playbook playbooks/validate-compose.yml -i inventories/local/hosts.ini

# Show all services in compose file
ansible-playbook playbooks/validate-compose.yml -i inventories/local/hosts.ini -v
```

**What it validates:**
- ✓ docker-compose.yml exists and is valid YAML
- ✓ .env file exists with passwords
- ✓ Infrastructure files present (nginx, databases)
- ✓ Service files generated (collectory, etc.)
- ✓ Volume definitions correct
- ✓ External volumes configured

### Phase 4: Deployment & Service Health

**Purpose:** Deploy containers and verify they start correctly

```bash
# Deploy (runs docker-compose up -d automatically)
ansible-playbook playbooks/site.yml -i inventories/local/hosts.ini

# Or use config-gen.yml alone and manually start
ansible-playbook playbooks/config-gen.yml -i inventories/local/hosts.ini
cd /data/docker-compose
docker-compose up -d

# Test all running services
ansible-playbook playbooks/test-services.yml -i inventories/local/hosts.ini
```

**What it tests:**
- ✓ Docker daemon accessible
- ✓ All containers running
- ✓ Nginx connectivity (port 80)
- ✓ MySQL connectivity (port 3306)
- ✓ MongoDB connectivity (port 27017)
- ✓ CAS, Collectory service ports
- ✓ Volume mounts and data persistence
- ✓ Container logs for errors
- ✓ HTTP endpoint reachability

### Quick Test Scenarios

**Scenario 1: Validate Everything Before Deploying**
```bash
# Step-by-step validation
ansible-playbook playbooks/verify-inventory.yml -i inventories/local/hosts.ini
ansible-playbook playbooks/config-gen.yml -i inventories/local/hosts.ini --check
ansible-playbook playbooks/validate-compose.yml -i inventories/local/hosts.ini --check
```

**Scenario 2: Full Deployment with Tests**
```bash
# Generate, deploy, and test
ansible-playbook playbooks/config-gen.yml -i inventories/local/hosts.ini
cd /data/docker-compose && docker-compose up -d
ansible-playbook playbooks/test-services.yml -i inventories/local/hosts.ini
```

**Scenario 3: Test Only One Service**
```bash
# Generate config for Collectory only
ansible-playbook playbooks/config-gen.yml -i inventories/dev/hosts.ini --limit collectory
cd /data/docker-compose && docker-compose up -d collectory
# Check service
docker-compose logs -f collectory
```

**Scenario 4: Check Health After Changes**
```bash
# After modifying inventory variables, validate
ansible-playbook playbooks/verify-inventory.yml -i inventories/local/hosts.ini --diff
# Then regenerate
ansible-playbook playbooks/config-gen.yml -i inventories/local/hosts.ini
# Test
ansible-playbook playbooks/test-services.yml -i inventories/local/hosts.ini
```

### Manual Testing Commands

**Check docker-compose YAML syntax:**
```bash
cd /data/docker-compose
docker-compose config  # Validates and outputs composed config
docker-compose config --resolve-image-digests  # With digests
```

**View logs:**
```bash
cd /data/docker-compose
docker-compose logs -f                    # All services
docker-compose logs -f collectory         # Specific service
docker-compose logs --tail 50 mysql       # Last 50 lines
```

**Container inspection:**
```bash
cd /data/docker-compose
docker-compose ps                         # Running containers
docker-compose stats                      # CPU/memory usage
docker-compose exec nginx ls -la /etc/nginx/  # Access container filesystem
```

**Connectivity tests:**
```bash
# Test services from host
curl -v http://localhost/gatus/
curl -v http://localhost/collectory

# Test from inside container
docker-compose exec nginx curl http://collectory:8080/

# Test database from host
timeout 5 bash -c 'cat < /dev/null > /dev/tcp/localhost/3306'
```

### Linting and Validation Tools

**YAML Syntax Validation:**
```bash
# Lint all YAML files
yamllint inventories/local/ roles/ playbooks/

# Ansible playbook syntax check
ansible-playbook playbooks/config-gen.yml --syntax-check
ansible-playbook playbooks/validate-compose.yml --syntax-check
ansible-playbook playbooks/site.yml --syntax-check
```

**Ansible Best Practices:**
```bash
# Run ansible-lint on roles and playbooks
ansible-lint roles/la-compose/
ansible-lint playbooks/
```

**Docker Compose Validation:**
```bash
cd /data/docker-compose
docker-compose config > /dev/null && echo "Valid" || echo "Invalid"
```

### Troubleshooting Tests

**If config-gen fails:**
1. Check inventory loads: `ansible-playbook playbooks/verify-inventory.yml -i inventories/local/hosts.ini -vvv`
2. Check specific variables: `ansible -i inventories/local/hosts.ini localhost.docker_compose -m debug -a "var=VARIABLE_NAME"`
3. Run with more verbosity: `ansible-playbook playbooks/config-gen.yml -i inventories/local/hosts.ini -vvv`

**If services don't start:**
1. Check Docker daemon: `docker ps`
2. Check logs: `docker-compose logs SERVICE_NAME`
3. Verify volumes: `docker volume ls | grep la_`
4. Check ports: `netstat -tulpn | grep LISTEN`

**If connectivity tests fail:**
1. Check container is running: `docker-compose ps`
2. Check port is exposed: `docker-compose exec SERVICE nc -zv localhost PORT`
3. Check logs: `docker-compose logs -f SERVICE`
4. Restart service: `docker-compose restart SERVICE`

---

## Recent Fixes & Architecture Documentation

### Build #83: CAS Configuration Directory Fix

See **[BUILD_83_FIX.md](BUILD_83_FIX.md)** for comprehensive analysis of:

- **Problem:** Jenkins Build #83 failed—CAS container crashed with `Config data location '/data/cas/config/' does not exist`
- **Root Cause:** Service role inclusion logic in `generate-compose.yml` checked for group membership (`'cas-servers' in group_names`), but in the docker-compose architecture, services are represented as host aliases, not groups
- **Solution:** Updated all 11 service role conditions to use a dynamically-calculated `service_aliases` fact
- **Status:** ✅ Fixed in commit `1c309e3` — ready for Jenkins Build #84 validation

**Key sections in BUILD_83_FIX.md:**
- The Problem in Detail — how group membership checks fail in docker-compose
- The Solution — how `service_aliases` works
- Testing & Validation — how we verified variable collisions (Issue #10) are prevented
- Expected Behavior — what Build #84 should show
- Design patterns — why this matters for multi-service deployments

**Recommended reading:** If you modify service role inclusion logic or add new services, start here to understand the architectural constraints.

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

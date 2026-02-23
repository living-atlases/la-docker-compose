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

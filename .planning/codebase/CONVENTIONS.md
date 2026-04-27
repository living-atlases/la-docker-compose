# Coding Conventions

**Analysis Date:** 2026-04-27

## Naming Patterns

**Files:**
- Task files: `kebab-case.yml` (e.g., `generate-compose.yml`, `init-databases.yml`, `setup-facts.yml`)
- Template files: `kebab-case.j2` (e.g., `docker-compose.env.j2`, `gatus-endpoint.yaml.j2`)
- Playbooks: `kebab-case.yml` (e.g., `config-gen.yml`, `site.yml`, `validate-compose.yml`)
- Roles: `kebab-case` directories (e.g., `la-compose`, `la-volumes`)
- Inventory files: `kebab-case-inventory.ini` pattern from generator

**Variables:**
- Snake_case throughout: `docker_compose_data_dir`, `deployment_type`, `auto_deploy`
- Role-scoped prefixes: `docker_compose_*`, `cas_*`, `collectory_*`, `nginx_*`
- Boolean vars use descriptive names: `auto_deploy`, `webserver_nginx`, `skip_handlers`
- Version vars: `<service>_version` (e.g., `cas_version`, `collectory_version`)

**Groups/Hosts:**
- Inventory groups: `kebab-case` (e.g., `cas-servers`, `docker_compose`, `docker_compose_hosts`)
- Host aliases: `localhost.<service>` pattern (e.g., `localhost.cas`, `localhost.collectory`)
  - Enables unique `inventory_hostname` per service despite same `ansible_host=localhost`

**Roles:**
- Local project roles: `la-<function>` prefix (e.g., `la-compose`, `la-volumes`)
- ala-install roles: referenced from `../ala-install/ansible/roles/`

## Code Style

**YAML formatting:**
- 2-space indentation (enforced by `.yamllint`)
- `indent-sequences: true` — lists indented under parent key
- Max line length: 160 chars (warning-only)
- Trailing spaces: warning-only (for multiline `|` blocks)
- Max 1 empty line at end of file
- Truthy values: `true`/`false`/`yes`/`no`/`on`/`off` all allowed

**Task structure:**
- Each task has explicit `name:` with human-readable description
- Complex task names use prefix for context: `"Deployment preparation: Ensure log directories"`
- Long descriptions use quoted strings: `name: "=== APPROACH 1: include_role with public=true ==="`
- `become: true` explicit per-task, not inherited globally
- `become: false` explicitly set when overriding inherited become

**Module usage:**
- Prefer Ansible modules over `shell`/`command`
- `file:` for directory creation, always with explicit `mode:`, `owner:`, `group:`
- `set_fact:` for computed variables, often with `tags: [always]`
- `import_role:` for static role inclusion; `include_role:` when dynamic (with `public: true`)
- `include_tasks:` for task file splitting within a role
- `include_vars:` for conditional variable loading from ala-install roles

## Ansible/YAML Conventions

**ansible.cfg settings** (`playbooks/ansible.cfg`):
- `roles_path = ../ala-install/ansible/roles:../roles:~/.ansible/roles:...` — ala-install roles first
- `gathering = smart` with `fact_caching = jsonfile` (1h TTL in `/tmp/ansible_facts`)
- `interpreter_python = auto_silent`
- `host_key_checking = False`

**Block usage:**
- `block:` wraps related tasks: `when: "inventory_hostname in groups['docker_compose']"`
- Guards at block level, not repeated per-task where possible

**Handler pattern:**
- `skip_handlers: true` set in defaults — handlers are skipped (config generation flow, not live deployment)
- Service restart via explicit tasks, not handlers, for docker-compose

**Variable precedence management:**
- `set_fact` used to enforce `deployment_type: container` at task level (overrides inventory)
- `defaults/main.yml` provides safe fallbacks for all role variables
- `inventories/local/group_vars/all.yml` provides test-time overrides
- `include_vars:` from ala-install roles used for service-specific variables

**Assert pattern:**
- `assert:` tasks for validation with `success_msg` and `fail_msg` for clear output
- Used in test playbooks extensively

## deployment_type Guard Patterns

This is the **critical convention** for multi-deployment-type support:

**VM-default guard (most ala-install tasks):**
```yaml
when: deployment_type == 'vm' or deployment_type is undefined
```

**Container/Swarm guard:**
```yaml
when: deployment_type == 'swarm' or deployment_type == 'container'
```

**Inverse VM check:**
```yaml
when: deployment_type != 'vm'
```

**Container-only:**
```yaml
when: deployment_type == 'container'
```

**Enforcement in generate-compose flow** (`roles/la-compose/tasks/generate-compose.yml`):
```yaml
- name: Enforce deployment_type=container for all included roles
  set_fact:
    deployment_type: container
  tags:
    - always
```
This uses `set_fact` (higher precedence than inventory) to prevent ala-install `setfacts.yml` from resetting to `vm`.

**Valid deployment_type values:**
- `container` — Docker Compose standalone (default for this project)
- `vm` — Traditional VM deployment (ala-install default)
- `swarm` — Docker Swarm (legacy, maintained for compatibility)

## Template Patterns

**Template location:** `roles/la-compose/templates/`
- `docker-compose/` — service-specific compose snippets
- `services/` — service configuration templates
- `infrastructure/` — nginx, mysql, other infrastructure configs
- Top-level `.j2` files for main compose and env files

**Jinja2 style:**
- `{{ variable | default('fallback') }}` for safe defaults
- `{{ variable | bool }}` for boolean coercion
- `{{ variable | from_json if variable is string else variable }}` for JSON string normalization
- Complex logic in `set_fact` tasks before template rendering (keeps templates readable)
- `{%- -%}` whitespace control used in complex dict-building macros

**Container hostname convention:**
- Services reference each other by container name, not `localhost`
- Database containers: `la_mysql`, `la_mongodb`, `la_postgres`
- Verified by `tests/test-no-localhost-configs.yml`

## Tagging Policy

Standard tag taxonomy in `la-compose` role:
- `always` — facts and setup tasks that must always run
- `only` — core generation tasks
- `docker-compose` — compose file generation
- `build` — image building tasks
- `docker` — Docker installation/setup

Usage pattern — multiple tags per task:
```yaml
tags:
  - always
  - only
  - docker-compose
  - build
```

## Documentation Standards

**File headers:**
```yaml
---
# Brief description of what this file does
# More context if needed
```

**Section separators** in long files:
```yaml
# ============================================
# Section Name
# ============================================
```

**Inline comments:**
- Explain WHY, not WHAT for non-obvious decisions
- Document known workarounds: `# Prevent ala-install roles from resetting it to 'vm'`
- Mark future work: `# TODO: ...`

**BUILD_*.md docs:** Root-level markdown files document significant build failures and their fixes. Pattern: `BUILD_<N>_<TOPIC>.md`. Critical reference for understanding architectural decisions.

**AGENTS.md:** Primary AI agent guidance; canonical source for deployment_type conventions and inventory patterns.

## Idempotence Requirements

- All playbooks must be re-runnable without data loss
- `docker compose up` always preceded by `docker compose down --remove-orphans`
- Data volumes defined as `external: true` to prevent accidental deletion
- `--remove-orphans` flag used in `docker compose up` as final safeguard
- `changed_when`/`failed_when` required on `shell`/`command` tasks

## Variable Collision Prevention

- `inventory_hostname` pattern: `localhost.<service>` ensures unique hostvars per service
- `system_vars_blacklist` defined in `generate-compose.yml` prevents Ansible internal vars from leaking:
  `inventory_hostname`, `group_names`, `groups`, `playbook_dir`, `role_names`, etc.
- `deployment_type` is in the blacklist (enforced separately via `set_fact`)

---

*Convention analysis: 2026-04-27*

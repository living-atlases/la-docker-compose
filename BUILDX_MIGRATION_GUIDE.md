# Docker Buildx Migration Guide for Init Containers

## Overview

This document outlines the pattern for migrating init containers from `docker compose build` to `docker buildx bake`, which eliminates the "No such container" errors that occur when containers are recreated.

## Problem Statement

When docker-compose.yml includes a `build:` section for any container, Docker Compose tracks build metadata. When containers are removed and recreated:

1. `docker compose down` removes containers but metadata persists
2. `docker compose build` recreates containers
3. `docker compose up` attempts to RECREATE containers (not CREATE fresh ones)
4. On subsequent deployments, Docker tries to recreate containers that no longer exist physically
5. Result: "No such container: <hash>" errors

## Solution Pattern

Build images **outside** docker-compose using `docker buildx bake`, then reference pre-built images in docker-compose.yml without any `build:` section.

## Current Status

### ✅ Migrated
- **branding-init** (commit 58beb96)
  - Custom build per portal (local source or git)
  - Now uses docker buildx bake pattern

### Pre-Built (No Migration Needed)
These init containers use public Docker Hub images, so no migration is required:

- **i18n-init**: Uses `livingatlases/ala-i18n:latest`
- **certs-init**: Uses `livingatlases/l-a-site-certs:latest`
- **cert-validator**: Uses `alpine/openssl:latest`
- **solr-init**: Uses base `solr:X.X` image
- **cassandra_init**: Uses base `cassandra:X.X` image

### Potential Future Migrations
Init containers that might need custom builds:

- **db-backup**: Currently uses public image, could support custom backups
- **postgres/mysql**: Currently use public images, could support custom init scripts
- **mongodb**: Currently uses public image, could support custom init data

## Migration Checklist

If you add a custom-built init container, follow this pattern:

### 1. Prepare the build context
- Place Dockerfile and build files in `roles/la-compose/files/docker/<service>/`
- Ensure Dockerfile has appropriate stages (e.g., `builder-production`)

### 2. Create docker-bake.hcl.j2 template
```hcl
target "myservice" {
  dockerfile = "Dockerfile"
  context = "{{ docker_compose_data_dir }}/dockerfiles/myservice"
  target = "builder-production"
  args = {
    # Define build arguments as needed
  }
  tags = ["myservice-builder:{{ myservice_version | default('latest') }}"]
  output = ["type=docker"]
}
```

### 3. Add build tasks to build-images.yml
```yaml
- name: Check docker buildx availability
  command: docker buildx version
  register: buildx_check
  failed_when: false
  changed_when: false
  when:
    - "'myservice' in services_enabled"

- name: Fail if docker buildx not available
  fail:
    msg: "docker buildx is required but not available"
  when:
    - "'myservice' in services_enabled"
    - buildx_check.rc != 0

- name: Generate docker-bake.hcl for myservice
  template:
    src: docker-bake.hcl.j2
    dest: "{{ docker_compose_data_dir }}/docker-bake.hcl"
    mode: '0644'
  when:
    - "'myservice' in services_enabled"

- name: Build myservice using docker buildx bake
  command: docker buildx bake -f docker-bake.hcl myservice
  args:
    chdir: "{{ docker_compose_data_dir }}"
  changed_when: true
  when:
    - "'myservice' in services_enabled"
```

### 4. Update service template
Remove all `build:` configuration, keeping only the image reference:

```yaml
myservice-init:
  container_name: la_myservice-init
  # Image built by docker buildx bake - must exist before docker compose up
  image: myservice-builder:{{ myservice_version | default('latest') }}
  pull_policy: never
  # ... rest of service config ...
```

### 5. Define variables in defaults/main.yml
```yaml
myservice_version: "latest"
myservice_build_source: "local"  # or "git"
myservice_source: "/path/to/source"
# ... other variables ...
```

### 6. Test the pattern
```bash
# Syntax check
ansible-playbook playbooks/config-gen.yml --syntax-check

# Generate config
ansible-playbook playbooks/config-gen.yml --check --diff

# Verify docker-bake.hcl is generated
cat docker-compose-output/docker-bake.hcl

# Test buildx
cd docker-compose-output
docker buildx bake -f docker-bake.hcl myservice --dry-run

# Deploy
docker-compose up myservice-init
```

## Advantages of This Pattern

1. **No Metadata Tracking**: Images are built outside docker-compose, eliminating metadata issues
2. **Idempotent Deployments**: Can redeploy multiple times without state conflicts
3. **Faster Rebuilds**: Docker buildx can leverage better caching strategies
4. **CI/CD Friendly**: Jenkins can trigger builds independently from deployment
5. **Cross-Platform**: `docker buildx bake` supports multi-architecture builds

## Disadvantages

1. **Requires docker buildx**: Must be available on all build systems (Docker 19.03+)
2. **Two-stage process**: Images must be built before compose configuration is used
3. **Dependency ordering**: Build must happen before `docker compose up`

## Troubleshooting

### "docker buildx not available"
- Update Docker to 19.03 or later
- On Linux, install docker-buildx plugin: https://github.com/docker/buildx

### "No such container" still occurs
- Ensure docker-bake.hcl was generated: `cat docker-compose-output/docker-bake.hcl`
- Verify image exists: `docker images | grep builder`
- Check docker-compose.yml has NO `build:` section for that container

### Image not found when docker-compose up runs
- Ensure build-images.yml runs BEFORE the docker-compose task
- Check ansible task order in playbooks/site.yml
- Verify `output = ["type=docker"]` in docker-bake.hcl

## References

- Current implementation: Commit 58beb96 (branding-init migration)
- POC reference: ala-install-docker@docker-compose-poc
- Docker Buildx docs: https://docs.docker.com/engine/build/bake/
- Docker Compose build section: https://docs.docker.com/compose/compose-file/build/

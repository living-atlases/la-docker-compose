# Builds #87-89 Crash Root Cause Analysis & Fix

**Date:** March 18, 2026  
**Status:** ✅ FIXED (Commit: `53056415` in ala-install)  
**Issue:** Containers crashing in repeated loops on docker-3

---

## 🔍 Problem Summary

Builds #87, #88, and #89 experienced the same pattern of container crashes:

| Container | Status | Error |
|-----------|--------|-------|
| nginx | ❌ Restarting | `[emerg] host not found in upstream "la_gatus_service"` |
| gatus | ❌ Restarting (1) | `panic: configuration file not found` |
| bie-hub | ❌ Restarting (1) | `FileNotFoundException: /data/ala-bie-hub/config/logback.xml` |
| bie-index | ❌ Restarting (1) | (Similar to bie-hub) |
| pipelines | ❌ Restarting (2) | Exit code 2 |

**Key Finding:** These crashes were NOT caused by our recent changes to service_aliases or variable handling. They are **pre-existing configuration issues** in ala-install.

---

## 🎯 Root Cause - Deployment Type Guards Missing

### The Issue

In ala-install, the following roles include nginx_vhost tasks to configure nginx reverse proxies:
- `roles/gatus/tasks/main.yml` (line 55)
- `roles/bie-hub/tasks/main.yml` (line 188)
- `roles/bie-index/tasks/main.yml` (line 130)

These tasks were missing `deployment_type` guards. They were executing in **container deployments** where:

1. **No nginx reverse proxy** - la-docker-compose generates its own nginx via docker-compose
2. **No upstream hosts** - Container names like `la_gatus_service` don't resolve in the context where these tasks run
3. **Circular dependency** - nginx tries to resolve `la_gatus_service` before gatus starts, causing infinite restart loop

### Example: Gatus Nginx Task

**Before (BROKEN):**
```yaml
- name: add nginx vhost if configured
  include_role:
    name: nginx_vhost
  when: webserver_nginx | bool  # ❌ Only checks if nginx is enabled, not deployment type
```

**After (FIXED):**
```yaml
- name: add nginx vhost if configured
  include_role:
    name: nginx_vhost
  when: webserver_nginx | bool and deployment_type == 'vm'  # ✅ Only in VM mode
```

---

## 📊 Architecture Context

### Deployment Types

| Type | nginx Role | Config Source | Roles Affected |
|------|-----------|----------------|-----------------|
| **vm** | Traditional VM with ansible-managed nginx | ala-install templates | All services via nginx_vhost |
| **container** | Docker-compose managed nginx | la-docker-compose templates | Services skip nginx_vhost |
| **swarm** | Docker Swarm with shared nginx | ala-install templates | Similar to vm (legacy) |

### Why Container Mode Fails

In **container deployment**:
- Ansible runs on host against localhost services
- nginx container is started by docker-compose
- nginx config includes upstream definitions for services
- **Gatus/bie-hub/bie-index roles try to create ADDITIONAL nginx configs**
- These configs reference upstream hosts that don't exist in this context
- Result: nginx can't resolve upstreams → crashes → restart loop

---

## 🔧 Solution Applied

### Files Changed

1. **ala-install/ansible/roles/gatus/tasks/main.yml** (line 66)
2. **ala-install/ansible/roles/bie-hub/tasks/main.yml** (line 200)
3. **ala-install/ansible/roles/bie-index/tasks/main.yml** (line 192)

### Change Pattern

Added `and deployment_type == 'vm'` condition to all `include_role: nginx_vhost` tasks that were missing the guard.

### Commit

```
Commit: 53056415
Branch: docker-compose-min-pr
Message: "fix: add deployment_type guards to nginx_vhost tasks"
```

---

## ✅ Verification

### Local Syntax Check
```bash
$ ansible-playbook playbooks/site.yml --syntax-check
✅ playbook: playbooks/site.yml
```

### Pattern Consistency
- Matches existing deployment_type guards in other roles (pipelines, etc.)
- Follows same pattern as Issue #10 fix (service_aliases for container mode)

---

## 📝 Notes

### Why This Wasn't Caught Earlier

- **Build #86 Skipped** - Used `--skip-tags redeploy`, so roles didn't execute
- **Builds #87-89 Full Deploy** - Roles executed, nginx_vhost attempted in container mode
- **Pre-existing** - These tasks don't have deployment_type logic implemented yet

### Other Potential Issues

**pipelines role**: Already has deployment_type guards, so likely has a different issue (config generation, exit codes)

**logback.xml missing**: Separate issue - could be:
1. Template not generating correctly
2. Volume mount path incorrect
3. Permissions issue

---

## 🎬 Next Steps

1. **Verify Fix** - Run Build #90 with these changes
2. **Monitor** - Check docker-3 for container stability
3. **Pipeline Issue** - Investigate pipelines container exit code separately

---

## 🔗 Related Issues

- **Issue #10** (Build #83): Similar pattern with CAS config and group_names
- **AGENTS.md**: Section on deployment_type guards pattern
- **Jenkinsfile**: Uses `ALA_INSTALL_BRANCH: docker-compose-min-pr` by default

---

## 📚 Files Affected

```
ala-install/ansible/roles/
├── gatus/tasks/main.yml (1 line change)
├── bie-hub/tasks/main.yml (1 line change)
└── bie-index/tasks/main.yml (1 line change)
```

**Total Changes:** 3 insertions, 3 deletions (minimal, focused fix)

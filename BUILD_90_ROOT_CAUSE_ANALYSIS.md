# Build #90 Root Cause Analysis & Solutions

**Status:** 🔴 FAILURE  
**Duration:** 953 seconds (~16 min)  
**Date:** 2026-03-19  
**Build:** https://jenkins.gbif.es/job/la-docker-compose-tests/90/

---

## 📊 EXECUTIVE SUMMARY

Build #90 failed with **TWO DISTINCT ROOT CAUSES:**

### Issue #1: CAS Configuration Generation Failure (BLOCKING)
- **Impact:** Host 1 (gbif-es-docker-cluster-2023-1) - NO docker-compose.yml generated
- **Root Cause:** `cas_server_name` variable undefined in CAS role
- **Symptom:** `AnsibleUndefinedVariable: 'cas_server_name' is undefined` 
- **Line:** ala-install/ansible/roles/cas5/tasks/main.yml:47
- **Result:** Role execution halts, docker-compose.yml never generated, 0/10 services running

### Issue #2: Service Health Check Failures (DEGRADATION)  
- **Impact:** Host 2 & 3 - Partial deployment with restart loops
- **Root Cause:** Multiple services fail to start properly:
  - **bie-hub:** Restarting (1) - likely config/dependency issue
  - **bie-index:** Restarting (1) - likely config/dependency issue  
  - **gatus:** Restarting (2) - config validation or upstream issue
  - **nginx:** Restarting (1) - config or upstream connectivity
  - **la_pipelines:** Restarting (2) - dependency on unready services
- **Symptom:** Health check timeout after 300s, only 2/7 services healthy (Cassandra, Mailhog)
- **Result:** Incomplete deployment, services unable to stabilize

---

## 🔴 ISSUE #1: CAS CONFIGURATION FAILURE (PRIMARY)

### The Problem

When processing Host 1, the `la-compose` role attempts to include the `cas5` configuration role:

**File:** `roles/la-compose/tasks/generate-compose.yml:360-370`

```yaml
- name: Run cas configuration generation
  include_role:
    name: cas5
  vars:
    deployment_type: container
  when:
    - "'cas' in services_enabled"
    - "service_aliases.get('cas-servers') is defined"
  tags:
    - cas
    - config
```

**The Error (Build #90 logs, line 18738):**

```
fatal: [gbif-es-docker-cluster-2023-1.docker_compose]: FAILED! => changed=false
  msg: 'AnsibleUndefinedVariable: ''cas_server_name'' is undefined'
```

**Location:** `/var/lib/jenkins/workspace/ala-install/ansible/roles/cas5/tasks/main.yml:47`

### Why This Happens

The `cas5` role requires `cas_server_name` variable to be set. This variable is typically defined in:
- Inventory group_vars for VM deployments
- Or set dynamically by configuration generation tasks

**For docker-compose deployments:**
- The variable is not automatically set in the inventory
- The role tries to use it before it's defined
- Host 1 has CAS services but no `cas_server_name` set

### Expected vs. Actual

| Aspect | Expected | Actual |
|--------|----------|--------|
| Task | Generate CAS config in container mode | Role fails with undefined variable |
| Variable | `cas_server_name` provided via defaults | Not set in docker-compose context |
| Fallback | Should use default value or skip gracefully | Hard error, stops playbook |
| Result | docker-compose.yml generated | Role failure, no docker-compose.yml |

### Impact Chain

```
CAS role fails
    ↓
generate-compose.yml playbook halts
    ↓
docker-compose.yml NEVER generated on Host 1
    ↓
docker compose up attempts to start services
    ↓
"no configuration file provided: not found" error
    ↓
0/10 services running on Host 1
    ↓
Build #90 FAILS
```

---

## 🟡 ISSUE #2: SERVICE HEALTH CHECK FAILURES (SECONDARY)

### Host 3 Health Status (After 300s)

```
Health Status:
✓ cassandra - HEALTHY
✓ mailhog - HEALTHY
✗ bie-hub - UNHEALTHY (Restarting 1)
✗ bie-index - UNHEALTHY (Restarting 1)
✗ gatus - UNHEALTHY (Restarting 2)
✗ nginx - UNHEALTHY (Restarting 1)
✗ la_pipelines - UNHEALTHY (Restarting 2)

Summary: Healthy: 2 | Starting: 0 | Unhealthy: 5 | Unknown: 0
```

### Service-Specific Failures

#### BIE Services (bie-hub, bie-index)

**Symptoms:**
- Restarting with exit code 1
- Never reach "healthy" state within 300s

**Likely Causes:**
1. Configuration not mounted/generated correctly
2. Dependency on unavailable upstream service (nginx not ready)
3. Memory/resource constraints
4. Application startup error

**Evidence:** Both services fail together, suggesting shared dependency

#### Gatus Service

**Symptoms:**
- Restarting with exit code 2
- Despite our `feb65904` fix for config.yaml generation

**Likely Causes:**
1. Config validation still failing (need to verify config.yaml content)
2. Missing upstream configurations (nginx not ready)
3. Template rendering error in infrastructure/gatus.yml
4. Upstream service URLs incorrect

#### Nginx Service  

**Symptoms:**
- Restarting with exit code 1
- Taking >300s to stabilize

**Likely Causes:**
1. Invalid nginx.conf syntax
2. Upstream services not responding when nginx starts (bie-hub, bie-index)
3. SSL certificate issues (despite cert-validator)
4. Port binding conflict

**Key Observation:** nginx depends on bie-hub/bie-index being ready to properly configure upstreams. If they're not ready, nginx config validation fails.

#### Pipelines Service

**Symptoms:**
- Restarting with exit code 2
- Error: `bash: -c: option requires an argument`

**Likely Causes:**
1. Command wrapper syntax error
2. Environment variable interpolation failing
3. Docker CMD parsing issue

---

## ✅ SOLUTIONS

### SOLUTION #1: Fix CAS Role Initialization for Docker-Compose

**Files to modify:**
- `ala-install/ansible/roles/cas5/defaults/main.yml`
- `ala-install/ansible/roles/cas5/tasks/main.yml`

**Fix Pattern:**

```yaml
# In ala-install/ansible/roles/cas5/defaults/main.yml

# Add safe defaults for docker-compose deployment
cas_server_name: "{{ cas_server_name | default('cas.l-a.site') }}"
cas_port: "{{ cas_port | default(8080) }}"
cas_use_proxy: "{{ cas_use_proxy | default(true) }}"

# In ala-install/ansible/roles/cas5/tasks/main.yml:47

# Change from hard reference to conditional/default
- name: copy application.yml
  template:
    src: "{{ role_path }}/templates/application.yml.j2"
    dest: "{{ data_dir }}/cas/application.yml"
    mode: "0644"
  vars:
    cas_server_name: "{{ cas_server_name | default('cas.l-a.site') }}"  # ← Add default
    deployment_type: "{{ deployment_type | default('vm') }}"
```

**OR: More robust approach - Add early assertion:**

```yaml
# In ala-install/ansible/roles/cas5/tasks/main.yml (add at start of role)

- name: Assert required CAS variables are set
  assert:
    that:
      - cas_server_name is defined or deployment_type == 'container'
    fail_msg: |
      cas_server_name is required for CAS role
      Set it in inventory group_vars or provide a default for deployment_type: container
    success_msg: "CAS configuration variables validated"
  when: deployment_type != 'container'

- name: Set CAS defaults for container deployment
  set_fact:
    cas_server_name: "{{ cas_server_name | default('cas.l-a.site') }}"
    cas_port: "{{ cas_port | default(8080) }}"
  when: deployment_type == 'container'
```

**Why this works:**
- Provides sensible defaults for docker-compose context
- Doesn't change VM deployment behavior
- Follows pattern from other roles
- Allows inventory override if needed

---

### SOLUTION #2: Improve Service Startup Dependencies

**File:** `docker-compose/base.yml.j2` (template)

**Issue:** Services start simultaneously without waiting for dependencies

**Fix:** Add `depends_on` with `condition` clauses:

```yaml
# In docker-compose/base.yml.j2

bie-hub:
  depends_on:
    nginx:
      condition: service_healthy
    cassandra:
      condition: service_healthy

bie-index:
  depends_on:
    nginx:
      condition: service_healthy
    cassandra:
      condition: service_healthy

gatus:
  depends_on:
    nginx:
      condition: service_healthy

nginx:
  depends_on:
    cassandra:
      condition: service_healthy
    mailhog:
      condition: service_healthy

la_pipelines:
  depends_on:
    cassandra:
      condition: service_healthy
```

**Why this helps:**
- Services wait for their actual dependencies
- Reduces restart loops from missing upstreams
- Follows Docker Compose best practices
- Service startup becomes sequential and predictable

---

### SOLUTION #3: Increase Health Check Timeout (Short-term)

**File:** `roles/la-compose/tasks/validate-post-deploy.yml:59`

**Current:** 300 seconds (5 minutes)  
**Proposed:** 600 seconds (10 minutes) for full cluster startup

```yaml
- name: Run health check with custom timeout
  command: |
    "{{ docker_compose_data_dir }}/wait-for-health.sh" \
      --compose-dir "{{ docker_compose_data_dir }}" \
      --timeout {{ health_check_timeout | default(600) }} \
      --check-interval {{ health_check_interval | default(5) }}
```

**Why:** Gives slow services more time to stabilize while we fix upstream issues

---

### SOLUTION #4: Add Service Startup Logging

**File:** `scripts/wait-for-health.sh` (enhancement)

**Current behavior:** Reports generic "UNHEALTHY" status  
**Needed:** Container logs for failed services

```bash
# In wait-for-health.sh, after timeout:

echo "[INFO] Collecting logs for failed services..."
for service in ${UNHEALTHY_SERVICES[@]}; do
  echo "=== Container logs for $service ==="
  docker compose -f "$COMPOSE_DIR/docker-compose.yml" logs "$service" | tail -20
done
```

**Why:** Makes it easier to diagnose service startup failures

---

## 🛠️ IMPLEMENTATION PRIORITY

### Phase 1: CRITICAL (Unblocks docker-compose.yml generation)

1. **Fix CAS role variable initialization** in ala-install
   - Add `cas_server_name` default for container deployment
   - Commit: minimal change, focused fix
   - Impact: Allows Host 1 to generate docker-compose.yml

2. **Push to ala-install `docker-compose-min-pr` branch**
   - Already existing branch ready for PR
   - Update to include CAS fix

3. **Update Jenkinsfile to reference updated commit**
   - Modify `ALA_INSTALL_BRANCH` parameter default if needed

### Phase 2: IMPORTANT (Improves service stability)

4. **Add `depends_on` clauses** to docker-compose template
   - Prevents restart loops
   - Makes startup sequential

5. **Increase health check timeout** to 600s
   - Temporary fix while services stabilize

### Phase 3: QUALITY (Better observability)

6. **Add service logging** to health check script
   - Helps diagnose future failures

---

## 📋 VERIFICATION CHECKLIST

After implementing fixes:

- [ ] CAS role initializes without undefined variable errors
- [ ] Host 1 generates docker-compose.yml successfully
- [ ] docker compose up starts all services
- [ ] All services reach "healthy" state within 600s
- [ ] No restart loops (containers stable after health check passes)
- [ ] Health check reports correct service counts
- [ ] Jenkins build #91+ shows SUCCESS
- [ ] All three hosts have running services

---

## 📝 NOTES & RELATED ISSUES

### Similar Pattern from Build #83
- This is similar to Build #83 CAS inclusion issue (group membership vs service_aliases)
- Different manifestation: variable initialization rather than role inclusion
- Related learning: ala-install roles need explicit defaults for docker-compose context

### Service Dependency Chain
```
cassandra, mailhog (foundation)
    ↓
nginx (depends on foundation, upstream config)
    ↓
bie-hub, bie-index, gatus (depend on nginx upstreams)
    ↓
la_pipelines (depends on cassandra, possibly bie services)
```

### Files Affected Summary

**ala-install (our docker-compose-min-pr branch):**
- `ansible/roles/cas5/defaults/main.yml` - Add defaults
- `ansible/roles/cas5/tasks/main.yml` - Safe variable references

**la-docker-compose (main branch):**
- `roles/la-compose/tasks/generate-compose.yml` - No changes needed (already correct)
- `roles/la-compose/tasks/validate-post-deploy.yml` - Increase timeout
- `templates/docker-compose/base.yml.j2` - Add depends_on clauses
- `scripts/wait-for-health.sh` - Add logging for diagnostics

---

## 🔗 RELATED DOCUMENTATION

- Build #83 Analysis: `BUILD_83_FIX.md` - Service role inclusion patterns
- AGENTS.md: deployment_type guards and ala-install usage
- Docker Compose Best Practices: Service dependencies and health checks


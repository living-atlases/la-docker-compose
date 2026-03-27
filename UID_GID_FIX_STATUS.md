# UID/GID 1000 Fix - Status Report

**Date:** 2026-03-27
**Commit:** 61e47c5
**Status:** ✅ Code complete, ⏳ Awaiting Jenkins validation

---

## Problem Summary

**Root Cause:**
- la-docker-images hardcodes all containers to run as UID/GID 1000
- la-docker-compose was creating config files using `ansible_user_id` (usernames like "ubuntu", "jenkins")
- File ownership mismatch prevented containers from reading their configuration
- CAS and other services failed to start with permission errors

**Impact:**
- Build #109 failed with 6/10 services running (health check failures)
- CAS container repeatedly restarting due to inability to read config files

---

## Solution Implemented

**Changes Made:**

1. **roles/la-compose/defaults/main.yml**
   - Added `docker_container_uid: 1000` and `docker_container_gid: 1000`
   - Documented requirement to match la-docker-images Dockerfiles

2. **roles/la-compose/tasks/main.yml**
   - Changed from `ansible_user_id` → `docker_container_uid` (numeric 1000)
   - Changed from `ansible_user_gid` → `docker_container_gid` (numeric 1000)

3. **roles/la-compose/tasks/generate-compose.yml**
   - Updated ALL service user variables to use `docker_container_uid`
   - Removed complex fallback chains
   - Affected services: tomcat, nginx, cas, collectory, userdetails, apikey, namematching, sensitive_data

4. **tests/playbooks/test-uid-permissions.yml** (NEW)
   - Verification test for UID/GID 1000 ownership
   - Checks all config directories and files
   - Fails fast with actionable error messages

5. **tests/README.md** (NEW)
   - Documentation for permission verification tests

**Commit Details:**
```
61e47c5 fix: Use numeric UID/GID 1000 for container file ownership
Author: vjrj
Date: 2026-03-27
Branch: main
Status: Pushed to GitHub
```

---

## Verification Status

### ❌ Blocked: Jenkins MCP Connection Failure

**Problem:**
The Jenkins MCP server is returning "Session not found" errors for all requests:
```
Session not found: a2c3eab3-53b8-447b-a20f-f60618380dfb
```

**Impact:**
Cannot check build status via MCP tools. Build #110 should have been triggered automatically by GitHub push, but we cannot verify its status.

**Workaround:**
Created manual verification script: `scripts/verify-uid-fix.sh`

---

## Manual Verification Required

### Step 1: Check Jenkins Build Status

**Via Jenkins Web UI:**
1. Go to: https://jenkins.gbif.es/job/la-docker-compose-tests/
2. Look for Build #110 (should be triggered by commit 61e47c5)
3. Check build status: SUCCESS or FAILURE

**Expected outcomes:**

✅ **SUCCESS indicators:**
- Build status: GREEN
- PLAY RECAP shows: `failed=0`
- Final validation: "10/10" or "11/11 services healthy"
- No "Permission denied" errors in logs

❌ **FAILURE indicators:**
- Build status: RED
- Logs contain: "Permission denied"
- Services stuck in "starting" state
- CAS or other containers unhealthy

### Step 2: Run Verification Script

If you have SSH access to Jenkins agent or deployment target:

```bash
# Copy script to target machine
scp scripts/verify-uid-fix.sh user@target:/tmp/

# Run verification
ssh user@target "/tmp/verify-uid-fix.sh"
```

**Script checks:**
1. Git commit SHA (should be 61e47c5)
2. Config file ownership (all should be UID 1000)
3. Critical service configs (cas, collectory, userdetails, apikey)
4. Docker container status (healthy vs unhealthy)
5. Permission errors in container logs

### Step 3: Check Container Logs (if failure)

```bash
# On deployment target
docker logs la_cas_1 2>&1 | grep -i "permission"
docker logs la_collectory_1 2>&1 | grep -i "permission"
docker logs la_userdetails_1 2>&1 | grep -i "permission"

# Check file ownership
ls -ln /data/la-docker-compose/config/cas/
# Should show UID 1000, not 1001 or other
```

---

## Corrective Actions (if verification fails)

### If build used wrong commit
```bash
# Trigger manual build with correct commit
# Via Jenkins UI or CLI
```

### If files have wrong ownership
```bash
# Force re-generation of configs
ansible-playbook -i inventory.ini playbooks/config-gen.yml

# Or manual fix (NOT RECOMMENDED - doesn't solve root cause)
sudo chown -R 1000:1000 /data/la-docker-compose/config/
```

### If containers still failing
```bash
# Check specific container logs
docker logs la_cas_1 --tail 100

# Restart containers after fixing ownership
cd /data/la-docker-compose
docker compose restart cas
```

---

## Next Steps

### Immediate (waiting for completion)
- [ ] Verify Jenkins Build #110 status
- [ ] Run verification script on target machines
- [ ] Confirm all services healthy (10/10 or 11/11)

### Short-term (after successful verification)
- [ ] Add permission test to Jenkinsfile
  - Insert after "Regenerate inventories" stage
  - Before "Run Playbooks" stage
  - Use: `ansible-playbook tests/playbooks/test-uid-permissions.yml`

### Long-term
- [ ] Document UID/GID requirements in la-docker-compose README
- [ ] Consider adding pre-commit hook for UID/GID consistency checks
- [ ] Update la-docker-compose-plan.md with permission architecture

---

## Technical Details

### Why Numeric UID Matters

**Ansible file module behavior:**
- Accepts both usernames (string) and UIDs (integer)
- When given `owner: 1000`, uses UID directly (no system user lookup)
- When given `owner: "ubuntu"`, looks up UID from /etc/passwd
- System UIDs may differ across machines (ubuntu=1001 on some, 1000 on others)

**Docker container behavior:**
- la-docker-images Dockerfiles: `useradd -u 1000 -g 1000 <service>`
- Container always runs as UID 1000 regardless of username
- File ownership must match container UID for read access

**The fix:**
```yaml
# OLD (broken)
docker_compose_userid: "{{ ansible_user_id }}"  # Returns "ubuntu" (string)
cas_user: "{{ docker_compose_userid }}"         # Becomes "ubuntu"
# Ansible looks up "ubuntu" → creates file as UID 1001
# Container runs as UID 1000 → permission denied

# NEW (working)
docker_compose_userid: "{{ docker_container_uid }}"  # Returns 1000 (integer)
cas_user: "{{ docker_container_uid }}"               # Becomes 1000
# Ansible creates file as UID 1000
# Container runs as UID 1000 → success
```

---

## Related Files

**Modified:**
- roles/la-compose/defaults/main.yml
- roles/la-compose/tasks/main.yml
- roles/la-compose/tasks/generate-compose.yml

**Created:**
- tests/playbooks/test-uid-permissions.yml
- tests/README.md
- scripts/verify-uid-fix.sh (this fix)
- UID_GID_FIX_STATUS.md (this document)

**Reference:**
- AGENTS.md (deployment_type patterns)
- la-docker-compose-plan.md (architecture)
- BUILD_83_FIX.md (related CAS config fix)

---

## Contact

If Jenkins validation fails or verification script shows errors:
1. Check Jenkins console output for Build #110
2. Review script output from verify-uid-fix.sh
3. Examine container logs on deployment targets
4. Report findings with specific error messages

**Do NOT** proceed with production deployment until verification passes.

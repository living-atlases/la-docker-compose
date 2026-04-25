# Jenkins MCP Issue Report

**Date:** 2026-03-27 11:43 CET
**Issue:** Jenkins MCP server session errors blocking automated verification
**Impact:** Cannot verify UID/GID fix build status via automation

---

## Error Details

**Error Message:**
```
Session not found: a2c3eab3-53b8-447b-a20f-f60618380dfb
```

**Affected Operations:**
- jenkins_getBuild
- jenkins_getJob
- jenkins_getStatus
- jenkins_whoAmI
- All Jenkins MCP tools

**Error Pattern:**
- Consistent "Session not found" error
- Session ID: a2c3eab3-53b8-447b-a20f-f60618380dfb
- HTTP error in HttpServletStreamableServerTransportProvider

---

## Root Cause Analysis

**Likely causes:**
1. Jenkins MCP plugin session timeout/expiration
2. Session storage issue in Jenkins
3. MCP server restart without session persistence
4. Client-side session ID stale reference

**Technical stack trace points to:**
- PluginClassLoader for mcp-server
- HttpServletStreamableServerTransportProvider.doPost:453
- Endpoint.process:156

---

## Workaround Implemented

Since automated verification via MCP is blocked, implemented manual verification approach:

**Created:**
1. `scripts/verify-uid-fix.sh` - Automated shell script for on-machine verification
2. `UID_GID_FIX_STATUS.md` - Comprehensive manual verification guide
3. Documented Jenkins UI verification steps

**Manual verification paths:**
- Jenkins Web UI: https://jenkins.gbif.es/job/la-docker-compose-tests/
- SSH to target machines: Run verify-uid-fix.sh
- Direct Docker inspection: Check container health and logs

---

## What Still Needs Verification

**Critical: Build #110 or #111 status**

Our commits that need verification:
- `61e47c5` - UID/GID 1000 fix (pushed ~30 minutes ago)
- `34ac942` - Verification tools (pushed ~5 minutes ago)

**Expected Jenkins behavior:**
- SCM poll should detect commits
- Auto-trigger builds #110 and #111
- Both should complete within 10-20 minutes

**What we cannot confirm via MCP:**
- Whether builds actually triggered
- Build status (SUCCESS/FAILURE)
- Console output and error messages
- Service health check results

---

## Required Manual Actions

**IMMEDIATE (High Priority):**

1. **Check Jenkins UI for build status**
   ```
   URL: https://jenkins.gbif.es/job/la-docker-compose-tests/
   Look for: Build #110 or #111
   Check: Result (SUCCESS/FAILURE)
   Verify: Used commit 61e47c5 or 34ac942
   ```

2. **If build failed, run verification script**
   ```bash
   # On Jenkins agent or deployment target
   curl -O https://raw.githubusercontent.com/living-atlases/la-docker-compose/main/scripts/verify-uid-fix.sh
   chmod +x verify-uid-fix.sh
   ./verify-uid-fix.sh
   ```

3. **Report findings**
   - Build number and status
   - Commit SHA used
   - Service health counts (X/Y healthy)
   - Any error messages

---

## Success Criteria

Build is successful if ALL of these are true:

✅ Build status: SUCCESS (green)
✅ PLAY RECAP: failed=0
✅ Final validation: "10/10" or "11/11 services healthy"
✅ CAS container: state=healthy
✅ No "Permission denied" in logs
✅ Config files: UID=1000 (verified by script)

---

## If Build Failed

**Diagnostic steps:**

1. Check console output for error patterns:
   - "Permission denied"
   - "Cannot read"
   - "fatal:"
   - UID/GID mismatch messages

2. Run verification script output:
   - Which files have wrong UID?
   - Which containers are unhealthy?
   - What errors in container logs?

3. Verify correct commit was used:
   - Should be 61e47c5 or later
   - Check git SHA in build changeSet

**Corrective actions if needed:**

- Re-run config-gen.yml to regenerate with correct UID
- Check if old files need manual chown
- Restart unhealthy containers after fix
- Trigger new build if wrong commit was used

---

## Jenkins MCP Troubleshooting

**To potentially fix MCP session issue:**

1. **Restart Jenkins MCP plugin:**
   - Jenkins → Manage Jenkins → Plugin Manager
   - Find "MCP Server" plugin
   - Restart plugin or Jenkins instance

2. **Check MCP server logs:**
   - Jenkins → System Log
   - Filter for "mcp-server"
   - Look for session management errors

3. **Alternative access methods:**
   - Jenkins CLI (if configured)
   - Jenkins REST API with auth token
   - Direct Jenkins UI access

---

## Status: BLOCKED on Manual Verification

**Code status:** ✅ Complete and pushed
**Test tools:** ✅ Available and documented  
**Jenkins MCP:** ❌ Not functioning
**Build verification:** ⏳ Awaiting manual check

**Next step:** Human verification required via Jenkins UI or target machine access.

---

## Related Files

- scripts/verify-uid-fix.sh (verification script)
- UID_GID_FIX_STATUS.md (comprehensive status)
- JENKINS_MCP_ISSUE.md (this file)

## Commits

- 61e47c5 - UID/GID 1000 fix
- 34ac942 - Verification tools

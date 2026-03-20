# Build #94 Failure & Fix Analysis

**Build #94**: ❌ FAILED - Invalid `include_role` parameter  
**Commit**: `750d5a4` (fix applied)  
**Expected Next**: Build #95 (should succeed with maven_repo_url fix)

---

## 🔍 What Happened in Build #94

### The Error
```
ERROR! Invalid options for include_role: from_static

The error appears to be in '/var/lib/jenkins/workspace/la-docker-compose-tests/roles/la-compose/tasks/generate-compose.yml': line 157
```

### Root Cause
Commit `c61299f` attempted to use `include_role` with a parameter `from_static: false` which **does not exist** in the Ansible `include_role` module.

```yaml
# BROKEN (Build #94)
- name: Run ala-install common role
  include_role:
    name: common
    from_static: false  # ❌ INVALID PARAMETER
  vars:
    deployment_type: "{{ deployment_type | default('container') }}"
```

### Why I Added It (Incorrectly)
I was confused about:
1. Whether `include_role` needed explicit parameters to force dynamic execution
2. Possibly mixing up syntax with `import_role` (which uses different parameters)

### The Reality
- **`include_role`** is **always dynamic** (executes at runtime, not parse-time)
- **`import_role`** is static (processes at parse-time)
- Valid parameters for `include_role`: `name`, `tasks_from`, `vars_from`, `defaults_from`, `handlers_from`, `public`, `allow_duplicates`, `rolespec_validate`, `apply`
- **No `from_static` parameter exists** (this was my invention)

---

## ✅ The Fix

### Applied in Commit `750d5a4`

**Change**: Simply remove the non-existent parameter

```yaml
# FIXED (Build #95 onwards)
- name: Run ala-install common role
  include_role:
    name: common
  vars:
    deployment_type: "{{ deployment_type | default('container') }}"
  tags:
    - always
    - config
    - common
```

### Why This Works
1. `include_role: name: common` finds the role via `ansible.cfg: roles_path = ../ala-install/ansible/roles:roles`
2. Executes the complete `common` role in runtime (dynamic, as needed)
3. `common/tasks/main.yml` → `common/tasks/setfacts.yml` runs and defines `maven_repo_url`
4. All other ala-install roles (cas5, apikey, userdetails) can now access `maven_repo_url`
5. No additional parameters needed - defaults are sufficient

---

## 📊 Original Fix Still Valid

**The conceptual fix from `c61299f` is STILL CORRECT**:

| Aspect | Status | Notes |
|--------|--------|-------|
| **Problem identified** | ✅ CORRECT | `maven_repo_url` was undefined because we only loaded static vars |
| **Solution approach** | ✅ CORRECT | Running the complete `common` role was the right fix |
| **Module choice** | ✅ CORRECT | `include_role` (dynamic) was the right choice |
| **Syntax/parameters** | ❌ WRONG | `from_static: false` parameter doesn't exist |

**What was broken**: Only the syntax/parameter, not the logic.

---

## 🎯 Build #95 Expectations

With commit `750d5a4` pushed, Jenkins will trigger Build #95 which should:

1. ✅ **Pass syntax validation** - No more "Invalid options for include_role"
2. ✅ **Execute common role** - From `ala-install/ansible/roles/common`
3. ✅ **Define maven_repo_url** - Via `common/tasks/setfacts.yml` set_fact
4. ✅ **Define deployment_type** - Passed as var to common role
5. ✅ **Allow apikey to run** - Will find `maven_repo_url` and download JAR
6. ✅ **Generate docker-compose.yml** - On cluster-2023-1 (no longer fails)
7. ⚠️ **May hit new issues** - Other undefined variables or role inclusion problems

---

## 🔄 Timeline

| Build | Status | Issue | Fix |
|-------|--------|-------|-----|
| #92 | ❌ | `maven_repo_url undefined` | Include common role (c61299f) |
| #93 | ❌ | No playbook change, just docs | No deploy |
| #94 | ❌ | Invalid `from_static` parameter | Remove param (750d5a4) |
| #95 | ⏳ | TBD | Monitor logs |

---

## 🎓 Learnings

### About `include_role` vs `import_role`

**`include_role` (dynamic)**:
- Executes at **runtime**
- Variables passed via `vars:` are available inside the role
- Conditional inclusion via `when:` works on the whole role
- **Use when**: You need runtime flexibility, variable passing, or conditional execution

**`import_role` (static)**:
- Processed at **parse-time**
- Variables available after role execution
- Conditional inclusion via `when:` NOT supported (role is imported regardless)
- **Use when**: You need compile-time knowledge or static role structure

**In our case**: `include_role` is correct because:
1. Common role must run after `docker_facts` are set (runtime dependency)
2. We pass variables to the role: `vars: { deployment_type: ... }`
3. We may want conditional execution later (via tags or when:)

### Parameter vs Feature Confusion

I confused "wanting something to be dynamic" with "passing a parameter to make it dynamic."

- Dynamic execution is **built into `include_role`** - it's always dynamic
- No special parameter needed to enable this
- If you want static, you use `import_role` instead

---

## 🚀 Next Steps

1. **Monitor Build #95** when Jenkins detects the push
2. **Check logs** for:
   - Syntax errors (should be none)
   - `maven_repo_url` definition (should appear in common role output)
   - Apikey role successful execution (should work now)
   - New undefined variable errors (if any)
3. **If #95 succeeds**:
   - Document the complete fix in a summary
   - Update AGENTS.md with lessons learned about include_role
4. **If #95 fails on different error**:
   - Continue with root cause analysis
   - Fix will be similar process: syntax check → identify issue → push → rebuild

---

## 🔗 Related Commits

- **`c61299f`**: Original maven_repo_url fix (had syntax error)
- **`750d5a4`**: Remove invalid parameter (syntax fix)


# delegate_to_test: Service Alias Variable Loading

## Overview

This test validates a solution for Build #90, where CAS configuration generation failed with `AnsibleUndefinedVariable: 'cas_server_name' is undefined` when the playbook executed against `docker_compose` host instead of the `cas-servers` group host.

## Test Results

✅ **ALL TESTS PASSED**

```
PLAY RECAP
localhost.docker_compose: ok=16  changed=0  unreachable=0  failed=0  skipped=0  rescued=0  ignored=0
```

## What the Tests Prove

### TEST 1: Variable Undefined in Default Context
- **Purpose:** Establish baseline - confirm `cas_server_name` is not available in `docker_compose` context
- **Result:** ✅ PASSED - Variable is correctly undefined
- **Implication:** Build #90 failure was legitimate (variable was missing from context)

### TEST 2: hostvars Successfully Loads Single Variable
- **Purpose:** Verify `hostvars[service_alias][variable_name]` pattern works
- **Method:** Access `cas_server_name` via `hostvars[service_aliases['cas-servers']]`
- **Result:** ✅ PASSED - `cas_server_name=https://test-cas.example.com`
- **Implication:** Can access service-specific variables from docker_compose context

### TEST 3: hostvars Loads Multiple Variables
- **Purpose:** Verify pattern scales to multiple variables (real use case)
- **Method:** Load `cas_host_name` and `cas_context_path` in same set_fact task
- **Result:** ✅ PASSED - Both variables loaded correctly
- **Implication:** No performance penalty, pattern is maintainable

### TEST 4: ansible_host Remains Correct
- **Purpose:** Verify both aliases execute on same physical server
- **Method:** Compare `ansible_host` from both docker_compose and .cas contexts
- **Result:** ✅ PASSED - Both contexts have `ansible_host=localhost`
- **Implication:** Task execution happens on correct server (important for local connection)

## How It Works

### Inventory Structure
```ini
[docker_compose]
localhost.docker_compose ansible_host=localhost

[cas-servers]
localhost.cas ansible_host=localhost

[cas-servers:vars]
cas_server_name=https://test-cas.example.com
# ... other CAS variables
```

### Key Insight
- Both service aliases (`localhost.docker_compose` and `localhost.cas`) have same `ansible_host=localhost`
- Each alias has independent `group_names` and group variables
- `hostvars` dictionary provides access to all variables from any inventory context
- `service_aliases` (calculated in setup-facts.yml) maps group names to inventory alias hostnames

### The Pattern
```yaml
# In generate-compose.yml, before include_role:
- name: Load CAS variables from service alias context
  set_fact:
    cas_server_name: "{{ hostvars[service_aliases['cas-servers']]['cas_server_name'] }}"
    cas_host_name: "{{ hostvars[service_aliases['cas-servers']]['cas_host_name'] }}"
    # ... load all required CAS variables
  when: service_aliases.get('cas-servers') is defined

# Then include the role normally (variables now available)
- name: Run cas5 configuration generation
  include_role:
    name: cas5
  vars:
    deployment_type: container
  when: service_aliases.get('cas-servers') is defined
```

## Why This Works Better Than delegate_to

### Attempted: delegate_to with include_role
```yaml
- name: Run cas configuration generation
  include_role:
    name: cas5
  delegate_to: "{{ service_aliases['cas-servers'] }}"
```

**Problem:** Ansible validates all variables in the task BEFORE applying `delegate_to`, causing undefined variable errors during task parsing.

### Solution: Pre-load Variables (SUCCESSFUL)
```yaml
- name: Load variables from service context
  set_fact:
    # hostvars lookup happens in docker_compose context
    variable_name: "{{ hostvars[service_alias]['variable_name'] }}"

- name: Include role (variables now available)
  include_role:
    name: cas5
```

**Why it works:** 
- Variable lookups happen in current context (docker_compose)
- No delegate_to needed - tasks execute on same physical server anyway
- No variable validation issues
- Clean separation: load → include

## Next Steps

### Phase 2: Apply to generate-compose.yml
Apply the pattern to all 11 services that need it:
1. cas5 (36 variables)
2. cas-management (similar count)
3. userdetails
4. apikey
5. collectory
6. species-list
7. bie-hub
8. bie-index
9. biocache-hub
10. biocache3-properties
11. biocache3-service

### Phase 3: Test with lademo inventory
Run full test suite with real lademo inventory to verify:
- Config generation succeeds
- Variables load correctly
- No undefined variable errors
- Build #91 produces 10/10 services (vs 0/10 in Build #90)

## Running the Test

```bash
cd la-docker-compose

# Run the complete test
ansible-playbook -i tests/delegate_to_test/inventories/hosts.ini \
                 tests/delegate_to_test/playbooks/test-delegate-to.yml -v

# Run with specific tags for debugging
ansible-playbook -i tests/delegate_to_test/inventories/hosts.ini \
                 tests/delegate_to_test/playbooks/test-delegate-to.yml \
                 --tags "test2,test3" -v
```

## Files

- `inventories/hosts.ini` - Minimal test inventory with docker_compose and cas-servers groups
- `playbooks/test-delegate-to.yml` - 4 test scenarios (validation, single var, multiple vars, ansible_host)

## Conclusion

The `hostvars[service_alias]` pattern provides a reliable, maintainable solution for accessing service-specific variables from the docker_compose execution context. This enables role inclusion without breaking changes to ala-install roles.

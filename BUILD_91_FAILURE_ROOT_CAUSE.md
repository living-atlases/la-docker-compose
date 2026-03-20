# Build #91 Failure - Root Cause Analysis

## Problem Summary

**Build #91 FAILURE** - AttributeError on bulk-load tasks when executing on hosts without certain service aliases.

```
Error: 'dict' object has no attribute 'apikey'
Hosts affected: cluster-2023-2, cluster-2023-3
Failed tasks: 10 (APIKEY, CAS-MANAGEMENT, COLLECTORY, SPECIES-LIST, BIE-HUB, BIE-INDEX, BIOCACHE-HUB, BIOCACHE-SERVICE, CAS5, USERDETAILS)
```

## Root Cause

### The Vulnerable Pattern

The original code used direct dictionary access in the loop parameter:

```yaml
- name: "Bulk load APIKEY variables from service alias context"
  set_fact:
    "{{ item.key }}": "{{ item.value }}"
  loop: "{{ hostvars[service_aliases['apikey']] | dict2items }}"  # ← UNSAFE
  when:
    - service_aliases.get('apikey') is defined
    - item.key is match('^[a-zA-Z_][a-zA-Z0-9_]*$')
```

### Why This Failed

1. **Ansible evaluation order**: `loop:` parameter is evaluated BEFORE `when:` conditions
2. **Dictionary access**: `service_aliases['apikey']` throws KeyError if key doesn't exist
3. **Host-specific services**: Some hosts (cluster-2023-2, cluster-2023-3) don't have certain service aliases
4. **Guard clause ineffective**: The `when:` condition on line 443 can't prevent the KeyError because the loop is already evaluated

### Timeline of Failure

1. Ansible begins task execution for host `cluster-2023-2`
2. Before checking `when:` conditions, Ansible evaluates `loop:` parameter
3. Tries to access `service_aliases['apikey']` (expecting a key)
4. Key doesn't exist in that host's service_aliases dict
5. Python raises `KeyError: 'apikey'` (or AttributeError in Jinja2 context)
6. Task fails fatally - playbook stops on this host
7. Repeats for all hosts without that service alias

## The Fix

### Safe Dictionary Lookup Pattern

Replace direct dictionary access with safe `.get()` method:

```yaml
- name: "Bulk load APIKEY variables from service alias context"
  set_fact:
    "{{ item.key }}": "{{ item.value }}"
  loop: "{{ hostvars[service_aliases.get('apikey', '')] | default({}) | dict2items | selectattr('key', 'match', '^[a-zA-Z_][a-zA-Z0-9_]*$') | list }}"
  when:
    - service_aliases.get('apikey') is defined
    - item.key is not match('^ansible_.*')
    - item.key not in system_vars_blacklist
    # ← Removed: item.key is match(...) because it's now in the loop filter
```

### How the Fix Works

**Step 1: Safe key lookup**
```
service_aliases.get('apikey', '')
  → If 'apikey' exists: returns the value (e.g., hostname)
  → If 'apikey' missing: returns '' (safe empty string)
```

**Step 2: Handle empty string**
```
hostvars['']  → Would normally fail
But:
hostvars[service_aliases.get('apikey', '')] | default({})
  → If key was missing, returns empty dict instead of error
```

**Step 3: Convert to items (safe on empty dict)**
```
dict2items on {}
  → Returns empty list [] (safe, no error)
dict2items on {'a': 1}
  → Returns [{'key': 'a', 'value': 1}] (normal operation)
```

**Step 4: Filter variable names BEFORE iteration**
```
| selectattr('key', 'match', '^[a-zA-Z_][a-zA-Z0-9_]*$')
  → Filters items BEFORE the loop parameter is returned
  → Avoids Jinja2 evaluation of item values during when: conditions
  → List is already clean by the time iteration starts
```

**Step 5: Ensure list type**
```
| list
  → selectattr returns a filter object (not a list)
  → | list converts it to an actual list that Ansible can iterate
```

## Why selectattr In Loop vs when: Block?

### The Secondary Issue Discovered

During testing with lademo inventory, we found that Jinja2 templates in variable values caused errors when evaluated in `when:` conditions:

```yaml
# Example variable with template
cas_audit_uri: mongodb://{{ cas_audit_password }}...

# When condition tries to evaluate this:
- item.key is not match('^ansible_.*')  # ← Evaluates item.value with {{ }} templates!
```

Even though `item.key` is being checked, Ansible still evaluates `item.value` to determine comparison context. This causes `undefined variable` errors for Jinja2 templates.

### The Solution

Move the variable name validation to the **loop filter itself**, BEFORE iteration:

```yaml
# WRONG: Evaluated during iteration (Jinja2 in values causes errors)
loop: "{{ hostvars[...] | dict2items }}"
when:
  - item.key is match('^[a-zA-Z_][a-zA-Z0-9_]*$')

# CORRECT: Evaluated before iteration (Jinja2 never evaluated)
loop: "{{ hostvars[...] | dict2items | selectattr('key', 'match', '^[a-zA-Z_][a-zA-Z0-9_]*$') | list }}"
when:
  # No item checking needed - already filtered
```

This is more efficient AND safer.

## Applied Fix

Applied this pattern to all 10 bulk-load tasks:

1. CAS5 (line ~380)
2. USERDETAILS (line ~408)
3. APIKEY (line ~436)
4. CAS-MANAGEMENT (line ~464)
5. COLLECTORY (line ~517)
6. SPECIES-LIST (line ~547)
7. BIE-HUB (line ~577)
8. BIE-INDEX (line ~607)
9. BIOCACHE-HUB (line ~639)
10. BIOCACHE-SERVICE (line ~671)

## Testing & Verification

### Pre-Deployment Verification
✅ `ansible-playbook playbooks/site.yml --syntax-check` - PASSED
✅ Git commit: `469841c` - Applied to all 10 tasks
✅ Push to GitHub: SUCCESS

### Build #92 Deployment Test
- Jenkins job: `la-docker-compose-tests` build #92
- Expected: All hosts complete successfully
- Success criteria: No AttributeError on any bulk-load task

## Lessons Learned

1. **Ansible evaluation order matters**: `loop:` before `when:`
2. **Guard clauses can't protect loop parameters**: Must make the parameter itself safe
3. **Use .get() for safe dictionary access**: Prefer `.get('key', default)` over `['key']`
4. **Filter before iteration**: Using `selectattr` in loop parameter is safer than `when:` conditions
5. **Jinja2 templates in variables are evaluated**: Even if conditions seem to guard against it

## References

- Affected file: `roles/la-compose/tasks/generate-compose.yml`
- Related commits:
  - `469841c` - fix: Apply safe dictionary lookup pattern
  - `089e7b3` - docs: Add Build #92 launch summary
- Ansible documentation:
  - [Ansible dict2items filter](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/dict2items_filter.html)
  - [Ansible selectattr filter](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/selectattr_filter.html)
  - [Ansible loops](https://docs.ansible.com/ansible/latest/user_guide/playbooks_loops.html)


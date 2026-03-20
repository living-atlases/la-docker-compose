🚀 BUILD #92 - SAFE DICTIONARY LOOKUP PATTERN FIX
================================================

✅ COMPLETED ACTIONS:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. Applied selectattr filter to all 8 remaining bulk-load tasks:
   ✓ APIKEY (cas-servers)
   ✓ CAS-MANAGEMENT (cas-servers)
   ✓ COLLECTORY (collectory)
   ✓ SPECIES-LIST (species-list)
   ✓ BIE-HUB (bie-hub)
   ✓ BIE-INDEX (bie-index)
   ✓ BIOCACHE-HUB (biocache-hub)
   ✓ BIOCACHE-SERVICE (biocache-service-clusterdb)

2. Verified syntax and committed:
   ✓ ansible-playbook syntax-check: PASS
   ✓ Commit: 469841c (safe dictionary lookup pattern)
   ✓ Push to GitHub: SUCCESS

3. Build #92 Triggered:
   ✓ Jenkins job: la-docker-compose-tests
   ✓ Branch: main (with our commit 469841c)
   ✓ Status: RUNNING (16% progress)
   ✓ Parameters:
     - ALA_INSTALL_BRANCH: docker-compose-min-pr
     - AUTO_DEPLOY: true
     - CLEAN_MACHINE: false

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🔧 TECHNICAL DETAILS - FIX PATTERN:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

PROBLEM (Build #91):
  - AttributeError: 'dict' object has no attribute 'key-name'
  - Hosts cluster-2023-2 and cluster-2023-3 don't have certain service aliases
  - Direct dictionary access: hostvars[service_aliases['key']]
  - Crashes when key doesn't exist

ROOT CAUSE:
  - Ansible evaluates loop: parameter BEFORE when: conditions
  - Guard clauses can't prevent the KeyError
  - Jinja2 templates in variables cause evaluation errors during when: checks

SOLUTION:
  Replace:
    loop: "{{ hostvars[service_aliases['key']] | dict2items }}"
    
  With:
    loop: "{{ hostvars[service_aliases.get('key', '')] | default({}) | dict2items | selectattr('key', 'match', '^[a-zA-Z_][a-zA-Z0-9_]*$') | list }}"

  Remove from when: block:
    - item.key is match('^[a-zA-Z_][a-zA-Z0-9_]*$')

WHY THIS WORKS:
  1. .get('key', '') returns '' instead of throwing KeyError
  2. | default({}) handles empty string, returns empty dict
  3. dict2items on empty dict → empty list (safe)
  4. selectattr filters BEFORE loop iteration (no Jinja2 eval errors)
  5. Loop iteration on empty list → task skipped (safe)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

⏱️ BUILD #92 TIMELINE:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Current Status: 16% progress (~5-10 min into build)
Expected Total: ~200-220 minutes (3.5-4 hours)

Phases:
  1. Prepare environment          (5-10 min) ✓ IN PROGRESS
  2. Update dependencies          (10 min)
  3. Install generator            (5 min)
  4. Regenerate inventories       (10 min)
  5. Run playbooks (big phase)    (150-180 min) ← Main test
     - Cleanup/prepare
     - Inventory validation
     - Service config generation (all 10 bulk-load tasks)
     - Bulk-load variable tests
  6. Finalize results             (5 min)

Success Criteria:
  ✓ No AttributeError on bulk-load tasks
  ✓ Variables loaded successfully on all hosts
  ✓ All 3 docker_compose hosts execute without failures
  ✓ Services start successfully

Expected Result Time: ~20:45 UTC (approximately 3.5 hours from now)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📊 COMPARISON WITH BUILD #91:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Build #91 (Previous):
  - Status: FAILURE
  - Error: AttributeError on APIKEY, CAS-MANAGEMENT, COLLECTORY, etc.
  - Duration: 417 seconds (~7 minutes)
  - Failed at: Bulk-load task loop evaluation
  - Root cause: Direct dict access with missing keys

Build #92 (Current):
  - Status: RUNNING (expected to PASS)
  - Fix: Safe .get() pattern + selectattr filter
  - Expected duration: 200-220 minutes
  - Should handle: All 8 remaining bulk-load tasks safely
  - Expected result: All hosts succeed, services start

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🔗 JENKINS LINK:
  https://jenkins.gbif.es/job/la-docker-compose-tests/92/


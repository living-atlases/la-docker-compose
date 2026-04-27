# Codebase Concerns

**Analysis Date:** 2026-04-27

---

## Tech Debt

### Hardcoded 11-Service List in generate-compose.yml

- Issue: Services are hardcoded one-by-one in `roles/la-compose/tasks/generate-compose.yml` (1630 lines). Each service requires a bulk-load task + an `include_role` block. Adding a new service means duplicating ~20 lines in two places manually.
- Files: `roles/la-compose/tasks/generate-compose.yml`
- Impact: File is hard to read, error-prone to extend, and does not enforce consistent patterns across services. Current count: 15 `include_role` calls + 17 bulk-load tasks.
- Fix approach: Replace with a data-driven loop structure (documented in `BUILD_83_FIX.md` "Future Enhancements"). Define a `services_to_configure` list with `name` and `group` keys, then loop with `include_role`.

---

### generate-compose.yml Monolithic Size

- Issue: Single task file at 1630 lines handles service config generation for all 11+ services.
- Files: `roles/la-compose/tasks/generate-compose.yml`
- Impact: Slow to review, high merge conflict risk, cognitive overhead for contributors.
- Fix approach: Split into per-service include files (e.g., `generate-compose-cas.yml`, `generate-compose-collectory.yml`) imported from a thin orchestrator.

---

### generate-compose.yml.backup Committed

- Issue: `roles/la-compose/tasks/generate-compose.yml.backup` exists in the repo — backup file from mid-edit.
- Files: `roles/la-compose/tasks/generate-compose.yml.backup`
- Impact: Confuses agents and reviewers about which file is canonical.
- Fix approach: Delete and add `*.backup` to `.gitignore`.

---

### Stale BUILD_*.md Proliferation

- Issue: Root contains 7+ `BUILD_*.md` docs (`BUILD_83_FIX.md`, `BUILD_87_89_FIX.md`, `BUILD_90_COMPLETION_SUMMARY.md`, `BUILD_90_ROOT_CAUSE_ANALYSIS.md`, `BUILD_90_PHASE_2B.md`, `BUILD_91_FAILURE_ROOT_CAUSE.md`, `BUILD_92_LAUNCH.md`, `BUILD_94_FIX.md`). These are incident post-mortems that accumulate without archiving.
- Files: `BUILD_*.md` (root directory)
- Impact: Root is noisy; newer developers cannot tell which docs are current vs resolved.
- Fix approach: Move to `.planning/incidents/` after resolution. Only keep `AGENTS.md`, `README.md`, and active status docs at root.

---

### Service Documentation Mismatches

- Issue: `BUILD_83_FIX.md` documents a "Future Enhancement" — parameterize the service list — never implemented (as of analysis date). `TODO.org` contains 3 open items none of which are tracked in the backlog.
- Files: `TODO.org`, `BUILD_83_FIX.md`
- Impact: Technical intent exists but not tracked formally, may be re-discovered painfully.
- Fix approach: Move `TODO.org` items to `.planning/` backlog. Archive resolved BUILD docs.

---

## Known Bugs / Open Issues

### nginx Fails When Upstream Container Not Ready (TODO.org)

- Symptoms: `nginx: [emerg] host not found in upstream "la_cas-management"` causes nginx restart loop. Entire stack degrades because nginx depends on upstream hostnames resolving at startup.
- Files: nginx vhost templates in ala-install (`roles/nginx_vhost/`), `TODO.org` line 6-8
- Trigger: Any service container that is slow to start (or not deployed) causes nginx to refuse to start.
- Workaround: None documented. Nginx container must be restarted after all upstreams are available.
- Fix path: Use nginx `resolver` with docker DNS + `set $upstream` pattern so DNS failures don't crash nginx. Alternatively use `valid_addresses` or a health-check-based startup order.

---

### CAS Cannot Write to /tmp (TODO.org)

- Symptoms: CAS container fails to write to `/tmp` at runtime.
- Files: `TODO.org` line 4
- Trigger: CAS container starts. Note was added that a fix was believed added to `la-docker-images` but not confirmed.
- Workaround: Unknown.
- Status: Unresolved; requires cross-repo verification with `la-docker-images`.

---

### CAS DB Initialization Not Confirmed (TODO.org)

- Symptoms: CAS fails to authenticate — databases may not be initialized with users/passwords via the `cas5-dbs` role from ala-install.
- Files: `TODO.org` line 5, `roles/la-compose/tasks/init-databases.yml`
- Trigger: Fresh deployment without prior DB init.
- Workaround: Unknown. Requires manual verification.

---

### apikey nginx Upstream Uses 127.0.0.1 (TODO.org)

- Symptoms: `proxy_pass http://127.0.0.1:9002/apikey` — other services use container name pattern, apikey does not.
- Files: nginx vhost template for apikey (exact path TBD — in ala-install `roles/apikey/` or `roles/nginx_vhost/`), `TODO.org` line 1-2
- Trigger: nginx proxying apikey requests.
- Fix path: Change to use container hostname `la_apikey` or equivalent docker-compose service name.

---

## Security Concerns

### Plaintext Test Credentials Committed in inventories/

- Risk: `inventories/local/group_vars/all.yml` contains plaintext credentials used for local/dev testing: `mysql_root_password: "password"`, `cas_oauth_access_token_encryption_key: "AAAA...=="`, `user_create_password: "password"`, `apikey_db_password: "password"`, `mongodb_root_password: "password"`, `specieslist_db_password: "password"`, `oauth_providers_flickr_secret: "flickr"`.
- Files: `inventories/local/group_vars/all.yml`
- Current mitigation: Inventories labeled "local" — assumed not used in production. No vault encryption.
- Recommendations: Add a linting check that production inventories do NOT inherit from local group_vars. Mark file explicitly as `# FOR LOCAL TESTING ONLY — NOT FOR PRODUCTION`. Consider ansible-vault for any secret that might be copied to real inventory.

---

### nginx Runs as root Inside Container

- Risk: `nginx_user: root` is set in `inventories/local/group_vars/all.yml:94`.
- Files: `inventories/local/group_vars/all.yml`
- Current mitigation: Only for local testing inventory; production inventory may differ.
- Recommendations: Verify production inventory does not inherit `nginx_user: root`. nginx should run as unprivileged user.

---

## Performance Bottlenecks

### Bulk Variable Loading Per Service (N×M Variable Copies)

- Problem: Each of 9+ services performs a `set_fact` loop to copy all hostvars from its service alias context into the current host context. With 200+ variables per service, this is ~1800+ `set_fact` operations per playbook run.
- Files: `roles/la-compose/tasks/generate-compose.yml` (bulk-load tasks, lines ~43–460)
- Cause: Variable isolation architecture (Issue #10) prevents direct `hostvars[alias].varname` access inside `include_role`, so vars must be pre-loaded.
- Improvement path: Pass only needed vars via `include_role: vars:` block per service instead of bulk-loading all hostvars. Requires identifying the minimal variable set per role.

---

## Fragile Areas

### Ansible `loop:` Evaluated Before `when:` (KeyError Risk)

- Files: `roles/la-compose/tasks/generate-compose.yml` (bulk-load tasks)
- Why fragile: As documented in `BUILD_91_FAILURE_ROOT_CAUSE.md`, `loop:` parameters are evaluated before `when:` guards. If `service_aliases.get()` is used without the safe `.get('key', '')` + `| default({})` pattern in `loop:`, a missing alias causes a fatal KeyError on unaffected hosts.
- Safe modification: All `loop:` parameters that access `service_aliases` MUST use `service_aliases.get('key', '') | default({}) | dict2items` pattern. Never use `service_aliases['key']` directly in `loop:`.
- Test coverage: `tests/delegate_to_test/playbooks/test-bulk-load.yml` — run before modifying bulk-load tasks.

---

### service_aliases Fact Timing

- Files: `roles/la-compose/tasks/setup-facts.yml`, `roles/la-compose/tasks/generate-compose.yml`
- Why fragile: `service_aliases` must be calculated (in `setup-facts.yml`) before `generate-compose.yml` runs. If task order changes or `setup-facts.yml` is skipped by tags, subsequent `service_aliases.get()` calls will fail with undefined variable.
- Safe modification: Never tag `setup-facts.yml` tasks with service-specific tags that could be skipped. Ensure `setup-facts.yml` runs with `tags: always` or equivalent.

---

### Docker Compose Orphaned State

- Files: `roles/la-compose/tasks/main.yml:106-140`
- Why fragile: Docker Compose tracks internal state metadata for containers. If containers are deleted outside of compose (e.g., `docker rm`), subsequent `docker compose up` raises "No such container" errors. This is a known docker-compose design limitation.
- Safe modification: Always run `docker compose down --remove-orphans` followed by `docker system prune -f --volumes` before `docker compose up`. Reference implementation in `roles/la-compose/tasks/main.yml:106-140`.
- Test coverage: No automated test — relies on `AGENTS.md` documentation.

---

### Containers with `build:` Section Cause Recreate Errors

- Files: `BUILDX_MIGRATION_GUIDE.md`, `roles/la-compose/tasks/generate-compose.yml` (branding-init)
- Why fragile: Any init container using a `build:` section in docker-compose.yml causes Docker to track build metadata. On subsequent deployments, Docker tries to RECREATE containers (not CREATE), fails with "No such container: <hash>".
- Safe modification: Never add `build:` sections to docker-compose.yml. Use `docker buildx bake` externally and reference pre-built images. See `BUILDX_MIGRATION_GUIDE.md`.
- Current status: `branding-init` migrated. Other custom init containers may need future migration.

---

## Scaling Limits

### Single Physical Host Architecture (Current Lab Setup)

- Current capacity: All services deployed across 3 hosts in `la-docker-compose` lab. No auto-scaling, no load balancing at service level.
- Limit: Adding more services requires manual inventory extension + new service blocks in `generate-compose.yml`.
- Scaling path: Data-driven service list (see Tech Debt #1) would allow dynamic service addition without code changes.

---

### UID/GID 1000 Hardcoded in All Container Images

- Current capacity: All service containers in `la-docker-images` run as UID/GID 1000.
- Limit: Config files generated by Ansible must be owned by UID 1000. If the Ansible runner runs as a different UID (e.g., `ubuntu=1001` on some machines), permission errors occur.
- Documented in: `UID_GID_FIX_STATUS.md`, `roles/la-compose/defaults/main.yml:64`
- Status: Fixed via `docker_container_uid: 1000` default, but constraint is not enforced at CI level (no pre-flight check in Jenkinsfile).

---

## Dependencies at Risk

### ala-install Fork Dependency

- Risk: `la-docker-compose` depends on a fork of ala-install at branch `docker-compose-min-pr`. This branch contains 66 `deployment_type` guards across 13 roles. If the upstream ala-install merges breaking changes, the fork must be rebased.
- Impact: Upstream drift could silently break container deployments if guards are overwritten.
- Migration plan: Push `docker-compose-min-pr` branch as PR to upstream ala-install. If merged, switch to upstream. Until then, track upstream changes in `ALA_INSTALL_BRANCH` Jenkinsfile parameter.
- Reference: `AGENTS.md` "ala-install Usage" section.

---

### generator-living-atlas npm Package

- Risk: Inventory generation relies on `generator-living-atlas` npm package. Local inventories in `inventories/local/` and `inventories/dev/` are maintained manually via `scripts/create_local_inventory.py`. There is no `.yo-rc.json` for generator-living-atlas integration — regeneration is a manual process.
- Files: `scripts/create_local_inventory.py`, `inventories/local/`, `inventories/dev/`
- Impact: If inventory structure changes, local inventories can drift from production pattern.
- Migration plan: Add `.yo-rc.json` to enable `yo living-atlas:update` to regenerate local inventories automatically (documented in `AGENTS.md`).

---

## Missing Critical Features

### No Secrets Management

- Problem: No ansible-vault, HashiCorp Vault, or other secrets backend is integrated. All secrets are plaintext in inventory files. Production deployments rely on file-system access control only.
- Blocks: Secure production deployments; sharing inventories safely.

---

### No Automated Permission Pre-flight in Jenkinsfile

- Problem: `UID_GID_FIX_STATUS.md` documents that a permission verification test (`tests/playbooks/test-uid-permissions.yml`) exists but is NOT integrated into the Jenkinsfile pipeline stages.
- Blocks: Catching UID/GID mismatches before deployment (they currently cause silent runtime failures).
- Fix: Add `ansible-playbook tests/playbooks/test-uid-permissions.yml` between "Regenerate inventories" and "Run Playbooks" stages in `Jenkinsfile`.

---

### No Service Dependency Validation

- Problem: `BUILD_83_FIX.md` "Future Enhancements #2" documents the absence of pre-flight validation that all required service groups exist in inventory before roles execute.
- Files: `roles/la-compose/tasks/generate-compose.yml`
- Blocks: Early failure on misconfigured inventories; currently fails mid-run with cryptic errors.

---

## Test Coverage Gaps

### Docker Compose Orphan Cleanup

- What's not tested: The `down --remove-orphans` + `system prune` idempotence pattern has no molecule or integration test.
- Files: `roles/la-compose/tasks/main.yml:106-140`
- Risk: Regressions in the cleanup sequence can cause "No such container" errors that only appear on second deployment.
- Priority: High

---

### nginx Upstream Availability at Startup

- What's not tested: No test validates that nginx starts correctly when upstream containers are not yet ready.
- Files: nginx vhost templates
- Risk: nginx restart loop degrades entire stack silently.
- Priority: High

---

### CAS DB Init

- What's not tested: `roles/la-compose/tasks/init-databases.yml` and `init-cas-admin.yml` have no validation that CAS auth database is correctly seeded.
- Files: `roles/la-compose/tasks/init-databases.yml`, `roles/la-compose/tasks/validate-db-init.yml`
- Risk: CAS starts but authentication fails — no early diagnostic.
- Priority: Medium

---

*Concerns audit: 2026-04-27*

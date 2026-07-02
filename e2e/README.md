# Living Atlas deployment smoke/e2e suite

Browser-level checks (Cypress) that verify a deployed Living Atlas is actually **working**,
not just that its containers report healthy. It catches the failure class a status-code check
misses: pages that return HTTP 200/302 but are broken (blank CAS login from null branding, hub
layout NPE 500, collections/species 500).

This is **Layer 2** of deployment verification. **Layer 1** is
[`scripts/verify-deployment.sh`](../scripts/verify-deployment.sh), a lightweight gate that reads
the Gatus API — run it first; it's cheaper and needs no browser.

## Targets are inventory-driven (never hardcoded)

Specs never hardcode a hostname or path. They call `serviceUrl('records', '/…')` and get whatever
URL the **inventory** resolved — a subdomain (`https://records.l-a.site`) or a path
(`https://portal/biocache-hub`), depending on the portal. The resolved URLs come from a manifest,
`e2e-targets.json`, emitted by the deployment's config-gen from the same variables that drive
nginx and Gatus (`*_base_url` / `*_context_path`, `gatus_url`, `cas_url`).

- The deployment writes it to `/data/docker-compose/e2e-targets.json` (the compose data dir).
- Point Cypress at a specific manifest with `CYPRESS_TARGETS_FILE`. Default: the path above.

## Running

Requires Node 20+ (or use the `cypress/browsers` Docker image, as CI does).

```bash
npm ci

# Against the local single-host deployment (reads /data/docker-compose/e2e-targets.json)
CYPRESS_TARGET_ENV=local npm run cypress:run
CYPRESS_TARGET_ENV=local npm run cypress:open      # interactive / debug

# Against a remote deployment: point at that deployment's generated manifest
CYPRESS_TARGETS_FILE=/path/to/e2e-targets.json CYPRESS_TARGET_ENV=lademo npm run cypress:run
```

The local deployment serves services by subdomain per its inventory; resolve those names to your
host via `/etc/hosts` or a wildcard DNS entry.

### Authentication tests (gated)

The CAS/OIDC login spec (`cypress/e2e/8-auth/`) is **off by default**. It logs in as a seeded
**demo/demo** user (`demo@l-a.site` / `demo`) — a low-privilege, demo-only account the deployment
creates when `e2e_demo_user_enabled: true` (see `roles/la-compose/tasks/init-e2e-user.yml`). No
Jenkins secret required.

```bash
CYPRESS_ENABLE_AUTH_TESTS=true CYPRESS_TARGET_ENV=lademo npm run cypress:run
# override if your deployment seeded a different account:
CYPRESS_ENABLE_AUTH_TESTS=true \
CYPRESS_LADEMO_USERNAME=demo@l-a.site CYPRESS_LADEMO_PASSWORD=demo \
CYPRESS_TARGET_ENV=lademo npm run cypress:run
```

> ⚠️ Security: demo/demo is intentionally weak and demo-only. Never set `e2e_demo_user_enabled`
> on a production deployment.

## In CI (Jenkins)

Both layers run as report-only post-deploy stages, gated behind the `RUN_E2E` build parameter
(default off), so they can't destabilise the pipeline. Promote to blocking with `E2E_BLOCKING=true`
once stable. See the `E2E Smoke Tests` stage in the repo `Jenkinsfile`.

`ENABLE_AUTH_TESTS=true` is a **single toggle**: it seeds the demo/demo user during the deploy
(`e2e_demo_user_enabled`) *and* runs the login spec — no extra inventory edit or Jenkins secret
needed. (For a purely local run, set `e2e_demo_user_enabled: true` in your inventory/extras so the
user exists.)

## Layout

```
cypress/e2e/
  1-homepage/    branding renders (blank-page / null-branding canary)
  2-biocache/    occurrence search returns records (API + hub)
  3-species/     BIE species search (API + hub)
  4-collections/ collectory loads
  5-spatial/     spatial hub loads with a map
  6-lists/       species lists load
  7-monitoring/  gatus dashboard + API
  8-auth/        CAS/OIDC login (GATED)
cypress/support/
  services.ts    manifest loader + serviceUrl()
  checks.ts      shared data-robust assertions
  commands.ts    cy.login() for CAS/OIDC
  e2e.ts         setup + benign-error suppression
```

Assertions are deliberately **data-robust**: generic queries (`q=*:*`, `q=Acacia`), no fixed
counts or portal-specific content, so the suite works against any inventory's data.

## Credits / Inspiration

This suite is inspired by and adapted from the excellent end-to-end tests of the
**[Vlaams Biodiversiteitsportaal](https://github.com/inbo/vlaams-biodiversiteitsportaal)** by
[INBO](https://www.inbo.be/) (Research Institute for Nature and Forest, Flanders). We reused their
overall Cypress structure, the environment-parameterised config idea, the `cy.session()` login
pattern, benign-error suppression, and the "delete videos of passing specs" trick.

Both that project and this repository are licensed under the **Mozilla Public License 2.0
(MPL-2.0)**, so the adaptation is fully licence-compatible. Thank you, INBO. 🙏

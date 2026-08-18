# Living Atlas Docker Compose

This repository generates `docker-compose.yml` configurations and runs the
Living Atlas ecosystem with plain **Docker Compose** (no Swarm, no Kubernetes).
It bridges the gap between the `ala-install` Ansible playbooks (designed for VMs)
and containerized deployments without duplicating configuration logic.

The Compose stack can be split across **several machines**: each service runs in
its own container but the whole set behaves as if it were a single VM, with
hosts and name resolution handled through nginx (see
[Hosts & resolution](#hosts--resolution)).

## Usage

The easiest way to use this repository is through
[la-toolkit](https://github.com/living-atlases/la-toolkit), which drives the
playbooks and produces compatible inventories via the Living Atlas Yeoman
generator ([`generator-living-atlas`](https://github.com/living-atlases/generator-living-atlas)).
la-toolkit and the generator pull this repo in automatically, so most users never
clone it directly — the [Prerequisites](#prerequisites) and
[Testing & local development](#testing--local-development) sections below are
aimed at contributors working on this repo itself.

### A configuration to start from

Configuring a first portal in la-toolkit from an empty form means guessing which
services this stack actually implements, and one of those guesses is a dead end:
the legacy standalone **solr** and **biocache-store** path is not deployed here.
Indexing is pipelines + solrcloud + zookeeper. Leaving the legacy services enabled
strands them — they have no docker support, so a Docker Compose cluster will not
take them.

`inventories/testing/topologies/1host/.yo-rc.json` is a working single-host
configuration you can import with the **(+)** button in la-toolkit and edit from
there. It is the fixture the CI topology matrix runs against, sanitized: hosts
renamed to `la-mh-*`, IPs to `10.77.0.*`, secrets replaced. It carries
`LA_use_solr: false` and no biocache-store, with `solrcloud`, `zookeeper` and
`pipelines` all on the one host.

After importing, replace the hostnames, IPs, domain and project name with your own,
then configure your SSH keys. [`topologies/README.md`](topologies/README.md)
describes the 2- and 3-host variants and how the placement overlays are generated.

## Project status

What works, and what you should not rely on yet. Read this before planning a
deployment around it.

**Deployed and exercised on every CI run.** The core stack — nginx, CAS, the
datastores (MySQL, PostgreSQL, MongoDB, Cassandra, Solr/ZooKeeper,
Elasticsearch), collectory, biocache (service and hub), bie (index and hub),
species-list, spatial, image-service, logger, alerts, regions, data-quality,
geoserver, geonetwork, doi and the sensitive-data services — is deployed on
every build of the CI matrix, across four host topologies (1, 2 and 3 hosts),
and gated on all containers reporting healthy.

**Experimental — Airflow / pipelines ingestion.** The ingestion side is not
finished. The `pipelines-airflow` submodule is not even initialized in a default
checkout, heap tuning for `la_pipelines` is still pending, and paths have not
been moved from `hdfs://` to `file:///data/...`. There is an end-to-end ingest
test, but treat the whole area as a preview.

**Caveats worth knowing before you start.**

- `sensitive-data-service` runs the *legacy* ALA image, matched to a vintage
  name index. Its upstream data files need repairing at deploy time (malformed
  XML, and species entries referencing categories and zones by display name
  instead of id), which this repo does for you — but it means the service is
  pinned to that legacy combination.
- `sds-static-home` (the nextgen static home) is not deployed.
- The `ala-install` submodule points at
  [`vjrj/ala-install@docker-compose-min-pr`](https://github.com/vjrj/ala-install/tree/docker-compose-min-pr),
  a fork carrying the container-mode adaptations. Splitting it into minimal PRs
  to upstream ALA is pending, so expect that pin to move.
- A deployment split across VMs *and* containers (some datastores on VMs, the
  rest in Compose) is supported but is the least-travelled path; it is where
  most of the recent bugs have surfaced.

## Overview

Unlike a traditional deployment, where `ala-install` directly mutates the state of
a VM, this project runs the `ala-install` roles in **config-only mode** — reusing
the tasks that are *not* VM-specific — to generate the configuration files, nginx
vhosts, database schemas, etc. that each service needs. (Docker itself is still
installed on the host; almost everything else is rendered into files rather than
applied to the machine.) It then wraps the result in a `docker-compose.yml`,
mounts those configurations as volumes, and runs the service containers built by
the separate
[`la-docker-images`](https://github.com/living-atlases/la-docker-images) project.

Alongside `docker-compose.yml`, the generator writes a `.env` file holding the
variables the Compose file references (image tags, host ports, paths, generated
secrets). Like every other artifact under `/data/docker-compose/`, `.env` is
regenerated on each run and should not be hand-edited — see the
[Testing & local development](#testing--local-development) automation-only rule.

For how to reconfigure a deployment — selecting image registries/tags, JVM
tuning, and **persistent overrides that survive `ansiblew`** (`.env-custom`,
per-service `application-local-config.yml`, `*-local-extras.ini`) — see
[Configuration & customization](#configuration--customization).

### Key benefits

- **Reuses `ala-install`** — the canonical ALA deployment tooling, with years of
  accumulated logic, fixes, and field-tested configuration across many Living
  Atlas portals. We inherit all of that instead of re-implementing (and
  re-debugging) it for containers.
- Maintains a single source of truth for inventory variables.
- Generated artifacts are reproducible: everything comes from Ansible.

---

## Repository layout

- `ala-install/` — ALA Ansible roles, pulled in as a **git submodule**.
  Currently a small [fork](https://github.com/vjrj/ala-install) (branch
  `docker-compose-min-pr`) that keeps changes minimal, aiming at an upstream PR
  to `ala-install` that does not affect VM deployments.
- `roles/la-compose/` — core role that parses `ala-install` facts and generates
  `docker-compose.yml`.
- `roles/la-volumes/` — role managing persistent Docker volumes.
- `playbooks/` — Ansible entrypoints (`site.yml`, `config-gen.yml`,
  `db-init.yml`, plus validation helpers).
- `inventories/testing/lademo-inventories/` — inventory generated by
  `yo living-atlas`, used by CI and local validation.
- `scripts/` — developer-loop tooling. See [`scripts/README.md`](scripts/README.md).
- `molecule/unit/` — Molecule unit tests for `la-compose` helpers.
- `Jenkinsfile` — CI pipeline; the source of truth for how the stack is tested
  and deployed in real VMs.

The generated runtime stack lives in `/data/docker-compose/` (configurable via the
`docker_compose_data_dir` Ansible variable).

---

## Prerequisites

> For contributors working on this repo directly. Regular users go through
> [la-toolkit](https://github.com/living-atlases/la-toolkit) (see [Usage](#usage)).

Versions that actually matter:

| | |
|---|---|
| Docker Compose | **≥ 2.20** — the generated `docker-compose.yml` uses the top-level `include:` key, added in 2.20. Older versions fail to parse it. |
| Node | **22** — what CI pins for the Yeoman generator and the Cypress suites. |
| Docker Engine / Ansible | No hard floor established. CI runs Docker 29.x with the containerd snapshotter and ansible-core 2.19. |

Clone the repository **with submodules** so that `ala-install/` is populated:

```bash
git clone --recurse-submodules <repo-url>
# or, on an existing checkout:
git submodule update --init --recursive
```

You also need the Living Atlas Yeoman generator
([`generator-living-atlas`](https://github.com/living-atlases/generator-living-atlas))
installed to (re)generate the testing inventory.

---

## How it works

The flow is always: **generate config → deploy the stack** (containers, volumes,
networks, …).

1. `config-gen.yml` runs the `ala-install` roles in config-only mode and the
   `la-compose` role to produce `/data/docker-compose/docker-compose.yml`,
   `.env`, and the per-service config files.
2. `site.yml` does the same and then runs `docker compose up -d`.
3. The first time (or after wiping volumes) `db-init.yml` initializes the
   datastores and users (MySQL/MongoDB, Cassandra, SOLR, CAS Flyway migrations,
   default CAS admin, OIDC service registration, …).

Inspect the generated stack at any time:

```bash
cd /data/docker-compose
docker compose config
docker compose ps
docker compose logs -f <service>
```

---

## Hosts & resolution

Living Atlas services address each other by hostname (e.g. `collectory.l-a.site`,
`biocache.l-a.site`, or similar). In this stack those hostnames resolve to the
nginx reverse proxy, which routes each request to the right container — so a
service does not need to know whether its peer lives in the same container, the
same machine, or a different one. This is what lets the same inventory run as a
single all-in-one host or spread across **several machines** while the services
keep talking to each other by their public hostnames.

This is not very different from how `ala-install` already works when LA services
are spread across (or co-located on) VMs; here the same model is mapped onto
containers behind nginx.

---

## SSL & certificates

Running a real ALA deployment **without SSL is not recommended**.

SSL is configured the same way as in `ala-install`, through Ansible variables
(`ssl_certificate_server_dir`, `ssl_cert_file`, `ssl_key_file`, …), so a real
deployment provides its own certificates for its own domain.

For evaluation, the stack ships a **test mode** so that developers new to the
community can try Living Atlas without owning a domain or its SSL certificates:
`use_la_site_certs` serves wildcard certificates for subdomains of `l-a.site`.
This is auto-detected: when the configured domain is `l-a.site` (or a subdomain
of it), SSL is configured automatically with the bundled wildcard certificates,
so a developer can try the stack without providing any certificate of their own.
See the upstream guidance on
[domains and subdomains to use](https://github.com/AtlasOfLivingAustralia/documentation/wiki/Before-Start-Your-LA-Installation#domain-or-subdomains-to-use).

---

## Regenerating the inventory

The testing inventory is generated, not hand-edited. Regenerate it with the
Living Atlas Yeoman generator from the `inventories/testing/` directory:

```bash
cd inventories/testing
yo living-atlas --replay-dont-ask --force
```

This produces the inventory under
[`inventories/testing/lademo-inventories/`](inventories/testing/lademo-inventories/)
(`lademo-inventory.ini`).

---

## Configuration & customization

How to reconfigure a deployment: which knobs exist, where to set them, and which
overrides **survive** a re-run of `ansiblew`.

### Configuration layers (precedence, low → high)

1. **Role defaults** — `roles/la-compose/defaults/main.yml`.
2. **ala-install group_vars** — `ala-install/ansible/group_vars/all/`.
3. **Generated inventory** — `<deployment>-inventory.ini`, produced by
   `generator-living-atlas`. Regenerated; **do not hand-edit**.
4. **`<deployment>-local-extras.ini`** — operator override layer that **survives**
   inventory regeneration (git-ignored). A **la-toolkit convention**: each
   deployment/inventory has its own `*-local-extras.ini` for overriding any
   inventory variable.
5. **Per-service bulk-load** (`generate-compose.yml`) — highest precedence.

To change a generated value permanently, set the Ansible variable in
`*-local-extras.ini` (or inventory) and regenerate. To override runtime env or
per-service app config *without* inventory, use `.env-custom` or
`application-local-config.yml` (below).

### Selecting images

Each ALA service image resolves to `{{ registry }}/{{ image }}:{{ tag }}`.

- **Registry — global**: `docker_registry` (empty = Docker Hub).
- **Registry — per-service**: `<service>_registry` overrides the global registry
  for a single service (falls back to `docker_registry`). The variable name uses
  the service's version-variable prefix, e.g. `collectory_registry`,
  `biocache_hub_registry`, `cas_registry`. Third-party images expose
  `geoserver_registry` (default `kartoza`) and `geonetwork_registry` (default
  Docker Hub).
- **Tag / version**: `<service>_version` (or `<service>_image_tag` /
  `<service>_docker_tag` for some), set in inventory / `*-local-extras.ini`, or
  one-off via `-e cas_version=6.6.0`.

```ini
[all:vars]
docker_registry=livingatlases
# pull only collectory from a private registry:
collectory_registry=registry.example.org/atlas
collectory_version=1.6.4
```

Version-variable per service lives in
`roles/la-compose/vars/docker-services-desc.yaml` (`version_variable`); the image
name and tag var are in each `services/*.yml.j2`. **Not configurable without
rebuilding the image** (in
[`la-docker-images`](https://github.com/living-atlases/la-docker-images)): the
container UID/GID (1000) and bundled Java version.

### JVM tuning

Per-service options are emitted to `.env` as `<SERVICE>_JAVA_OPTS`. Tune via
inventory / `*-local-extras.ini`: `<service>_max_memory` (default `2g` → `-Xmx`),
`<service>_min_memory` (default `1g` → `-Xms`), `java_security_opts`.

> **Images built before 2026-08-17 ignore this.** The Java image templates
> expanded `JAVA_OPTS` when the Dockerfile was generated, so the defaults
> (`-Xmx2g -Xms2g -Xss512k`) were baked into the image `CMD` and the runtime
> variable was never read. This side is correct: the value does reach the
> container environment, and `docker exec <c> env | grep JAVA_OPTS` shows it.
> To confirm whether an image is affected, check whether its own command still
> carries the flags:
> ```bash
> docker inspect <container> --format '{{.Config.Cmd}}'
> ```
> Fixed in la-docker-images (see its issue #3); services need rebuilt images
> for `*_max_memory` / `*_min_memory` to take effect.

Because a service sets `JAVA_OPTS: ${<SERVICE>_JAVA_OPTS}`, that variable **replaces**
the image's own `ENV JAVA_OPTS` instead of adding to it. So `.env` has to carry every
option the image would otherwise supply, not just the memory ones — including
`-Dspring.config.additional-location=/data/<artifact>/config/` and
`-Dspring.config.name=application,application-local-config`, which is how a service
picks up `application-local-config.yml`.

That did not matter while the flags were frozen into the image `CMD`: they arrived
regardless of what `.env` said. With rebuilt images they only arrive from here, so
`.env` now emits them and `scripts/test-java-opts-env.sh` keeps it that way. A handful
of services (alerts, ecodata, image-service…) also re-add them in a `command:`
override, written back when that was the only way to honour `JAVA_OPTS` at all; those
are redundant now but harmless, since a later `-D` on the command line wins.

### Persistent overrides (survive `ansiblew`)

- **Environment / `.env` → `.env-custom`.** `.env` is regenerated each run. For
  persistent env overrides (passwords, `<SERVICE>_JAVA_OPTS`, `COMPOSE_PROFILES`),
  edit `/data/docker-compose/.env-custom`: Ansible creates it **once**
  (`force: no`) and never overwrites it. Compose loads `.env` then `.env-custom`
  (`COMPOSE_ENV_FILES=.env,.env-custom`, wired by the role), so `.env-custom`
  wins. For manual runs, `export COMPOSE_ENV_FILES=.env,.env-custom` first.
  Requires Docker Compose ≥ v2.24.
- **Per-service app config (Spring Boot).** Services logger, alerts,
  image-service, doi, regions, data-quality, spatial-service, spatial-hub,
  ecodata, biocollect start with
  `-Dspring.config.name=application,application-local-config,...`, so editing
  `/data/<service>/config/application-local-config.yml` overrides the generated
  config. Ansible seeds an explanatory placeholder once (`force: no`).
- **Grails services (limitation).** collectory, biocache-hub, bie-hub, bie-index
  and species-list load a single generated external config and have **no**
  second-level local-override file. Change them via `*-local-extras.ini` /
  inventory and regenerate.

### Selecting which services run

- **Per-host**: from inventory groups (`services_enabled`) — a service is
  generated only on the host whose inventory declares it.
- **Compose profiles** (`COMPOSE_PROFILES`, from `compose_profiles`): `infra`,
  `dbs`, `core-auth`, `app-core`, `monitoring`, `full`.
- **`skip_services`**: list of service keys to omit from generation/build even if
  their group is present.

### Branding & Spatial skin

When a branding source is deployed for the deployment (either a local path or a
git URL), config-gen **auto-detects** it and enables `use_branding`, and the
Spatial hub automatically switches from the generic ALA layout to the portal's
`spatial-layout` skin. The detection is keyed off the cluster-wide
`branding_source` (not per-host build lists), so it also applies **cross-host**:
the skin is materialized on the host that owns Spatial even when branding lives on
a different machine. See the auto-detect logic in
`ala-install/.../generate-compose.yml`. To force the layout explicitly, set
`spatial_hub_skin_layout` in `*-local-extras.ini` / inventory.

---

## Production redeploys (non-destructive contract)

Re-running the deploy (`ansiblew` / `site.yml`) over a **live** stack is designed
to be safe: it must destroy nothing, apply configuration changes, and keep
services up. The pieces that enforce this (all in `roles/la-compose/`):

- **Data**: DB volumes are external and never removed; DB/Solr/CAS inits are
  create-if-missing; `tasks/schema-migrations.yml` applies check-then-`ALTER`
  migrations to *existing* databases (so CREATE-time fixes reach aged volumes
  without a clean deploy).
- **Backups**: `tasks/pre-deploy-backup.yml` dumps MySQL/MongoDB/PostgreSQL via
  `docker exec` *before* anything mutates (the container port of ala-install's
  `db-backup` role; complements the scheduled `la_db-backup` container).
  Default on when `la_env=production`; a failed dump aborts the deploy.
- **Uptime**: the normal-path `docker compose up` runs with `--no-recreate`, so
  it converges the topology (creates missing services, starts stopped ones) but
  never recreates or stops a live container — a redeploy over an unchanged stack
  is a no-op, with no new container IDs and no nginx rebind/downtime window.
  `la_nginx` is never force-removed; regenerated vhosts are applied with
  `nginx -t` + graceful reload, and services whose bind-mounted config content
  changed are selectively restarted (`tasks/config-restart-detect.yml` /
  `-apply.yml`). Containers found unhealthy at deploy time are **restarted, not
  recreated** (`tasks/pre-deploy-container-cleanup.yml`): a restart resets the
  sticky health state exactly like a recreate but keeps the container and its ID. A deliberate full recreate stays available via
  `docker_force_recreate` (CI/staging only — `enforce-production-safety` forbids
  it in production).
- **Guard rails**: `tasks/validate-service-consistency.yml` aborts if
  `up --remove-orphans` would delete a running service that vanished from the
  generated compose (override: `-e allow_service_removal=true`). With
  `la_env=production` in the inventory, destructive flags
  (`docker_force_recreate`, `force_db_init`, `allow_service_removal`,
  `docker_desktop_workaround`) fail the run before anything is touched.

Key variables (see `roles/la-compose/defaults/main.yml`): `la_env` (`ci` |
`staging` | `production`), `pre_deploy_backup`, `la_backup_dir`,
`pre_deploy_backup_keep`, `config_change_restart`, `allow_service_removal`,
`docker_desktop_workaround`.

The Jenkins parameter `TEST_REDEPLOY` verifies the contract end-to-end: after a
green deploy it seeds canary data, probes nginx availability every second,
re-runs the playbooks without cleaning, and fails the build on any data loss,
nginx downtime, or spurious container recreation. The CI-only destructive
stages (`CLEAN_MACHINE`, nuclear Docker cleanup) additionally refuse hosts not
matching `CLEAN_HOSTS_ALLOW_REGEX`.

---

## Migrating an existing portal (VMs → Docker)

Moving a Living Atlas that runs on VMs into this deployment means carrying over
the data that cannot be regenerated: the CAS user accounts, the collectory
registry, species lists, logger history, alerts, image metadata, DOIs, data
quality profiles and the spatial/geonetwork databases. Two playbooks do it, both
run by hand — nothing in a normal `ansiblew` can trigger or repeat a restore.

Occurrence data is deliberately **not** migrated. Cassandra, SOLR and
Elasticsearch content is regenerable by re-ingesting the source DwCAs with
pipelines, and is orders of magnitude too large to move as a dump.

### One database at a time, never the whole cluster

This is the rule the whole design rests on. `mysqldump --all-databases` carries
`mysql.user`, `pg_dumpall` carries roles-with-passwords, and a
mongodump/mongorestore of `admin` carries the Mongo accounts. Restoring any of
them would replace the credentials Ansible generated from the inventory, and
every service would instantly lose its own database auth. So each application
database is dumped and restored on its own, into the databases and roles
`init-databases.yml` already created. A useful side effect: the source VM's root
password is never needed on the restore side.

`apikey` is excluded for the same class of reason — the Docker services use keys
from the inventory, seeded by `seed-apikeys.yml`, so a restored `apikey` table
would hold keys nothing reads.

### 1. Deploy the Docker stack first

Migrate into a stack that is already deployed and green. The restore loads data
into databases that must already exist with the right owners.

### 2. Fetch a dump set from the source portal

Configure the source in `playbooks/vars/portal-migration.yml` (hosts,
credentials, which databases to move), then:

```bash
ansible-playbook -i <inventory> playbooks/portal-migrate-fetch.yml -e migration_portal=<portal>
```

This is **read-only on the source portal**: it runs dumps and exact `COUNT(*)`
queries, writes only under `/tmp` on the source hosts, and cleans that up on the
way out. It refuses to run against a `docker_compose` host, and source hosts must
be named explicitly — in a mixed inventory the service groups contain both the
production VMs and the Docker hosts, so deriving them with `groups[x] | first`
can silently pick the wrong machine.

The result lands on the controller as
`/data/migration/<portal>/<timestamp>/` containing `dumps/`, `counts/` and
`manifest.json`.

### 3. Restore into the Docker stack

```bash
ansible-playbook -i <inventory> playbooks/db-restore.yml -e db_restore=true -e db_restore_confirm=<portal> -e migration_src_dir=/data/migration/<portal>/<timestamp>
```

Four things stand between this command and an accident:

| Guard | Behaviour |
|---|---|
| `db_restore=true` plus the portal name typed back | The confirmation is checked against `manifest.json`, so it forces a look at *which* dump set is about to load — the mistake that actually happens is right command, wrong directory |
| Mandatory pre-restore backup | `pre-deploy-backup.yml` runs unconditionally first; if the dump fails, nothing is mutated |
| Per-dump-set marker | Re-running is a no-op, and a **second** portal cannot be stacked on top of the first without `-e db_restore_force=true` |
| Per-database restores | The generated datastore credentials are never in scope |

There is no `la_env=production` gate. Migrating into a stack that is already
production is the whole point; forcing the operator to downgrade `la_env` would
disable the safety rails at the exact moment they matter.

### 4. What the restore reconciles afterwards

A dump carries the source portal's world with it. `restore-reconcile.yml` fixes
four things, in order:

1. **PostgreSQL ownership.** `pg_restore` runs with `--no-owner` (that is what
   keeps the source roles out of this cluster), so every restored object belongs
   to the superuser and the service gets `permission denied for table ...`. Each
   object is handed to the role that owns the *database*, which
   `init-databases.yml` set at `CREATE DATABASE` time.
2. **Schema migrations.** Portals on VMs predate the `utf8mb4_unicode_ci` switch,
   so a restored `emmet` usually arrives with the old collation. Left alone, CAS's
   `sp_get_user_attributes` dies with MySQL error 1267 and hands out a principal
   with no attributes — every login succeeds and every authorisation fails.
3. **Application restart**, so services re-read the databases underneath them and
   Flyway/GORM migrate a restored schema forward to what the images expect.
4. **CAS re-registration.** The restored `cas-service-registry` holds the *source*
   portal's OIDC clients and redirect URIs, so every login would bounce.
   `init-cas-admin.yml` deletes and re-inserts one document per service, replacing
   them with the URIs generated for this deployment. Then `seed-apikeys.yml` adds
   this deployment's keys alongside any restored ones.

### 5. Verify before trusting it

```bash
scripts/verify-migration.sh /data/migration/<portal>/<timestamp>
```

Run on each Docker host that carries a datastore (engines not present on a host
are skipped). It compares the exact per-table and per-collection counts recorded
at the source against the restored stack and fails if anything that had rows lost
them. Extra rows are expected and reported as such — a deployed stack seeds its
own. It also checks that the generated MySQL and MongoDB accounts survived, which
is the regression check against a cluster-wide restore sneaking back in.

Then check by hand: log into CAS with a migrated account, confirm collectory
lists its resources, and confirm an image renders.

### What is not covered

- **Binary file trees** — the image-service store, collectory uploads and
  biocache downloads are bind mounts, not database rows, and are not yet moved by
  these playbooks. Copy them with `rsync` into `{{ data_dir }}/<service>/...` on
  the target host and `chown` them to the container UID/GID.
- **Occurrence data** — re-ingest the source DwCAs with pipelines.
- **Hostnames stored inside the data.** Service configuration is regenerated by
  Ansible, but if a restored table holds URLs pointing at the old portal, no
  restore will rewrite them.

---

## Experimental: Airflow ingestion

> **Status: experimental / work in progress.** The end-to-end ingestion harness
> works and runs in CI, but the Airflow-driven pipeline is **not yet operational**
> as a supported deployment target — treat it as a moving part. Tracking:
> [#5](https://github.com/living-atlases/la-docker-compose/issues/5).

Biodiversity data ingestion (DwCA → la-pipelines → Solr + biocache-service) can be
driven by the separate **`pipelines-airflow`** overlay. la-compose renders an
override that plugs the overlay into this stack:

- **Ingestion e2e** — `scripts/e2e-airflow-ingest.sh` ingests a tiny fixed DwCA
  (8 records, `e2e/fixtures/dr-test/`) through the **real** pipeline and asserts
  the records land in Solr + biocache-service. It runs against the
  **already-running** stack (all access via `docker exec`, no Airflow REST/public
  DNS), triggering the `Ingest_small_datasets` DAG directly with
  `run_indexing=true`. The ingested data doubles as the fixture for the Cypress
  biocache/species suites (meaningless on an empty index). Report-only by default;
  `--blocking` gates CI.
- **Cross-host wiring** — `roles/la-compose/templates/docker-compose.airflow.override.yml.j2`
  gives the overlay's Airflow containers the same `extra_hosts` map every other
  la-compose consumer gets, so DAGs reach `biocache`/`collectory` (public URLs) and
  `solr`/`zookeeper` cross-host. Single-host: the map is empty → no-op.
- **Skippable stages** — SDS is made optional at runtime via `pipelines_skip_stages`
  in the DAG run conf (defaults to skipping `sds`), so sensitive-data-service need
  not be deployed for a smoke ingest.

**What's still missing**: operational validation on a real cluster (beyond the
smoke ingest) and stabilization of the overlay startup path.

---

## Testing & local development

> **Automation-only rule.** Every change to the Docker stack must go through
> Ansible (`ansiblew`), never through manual commands. The files in
> `/data/docker-compose/` are **generated artifacts** — editing them by hand
> desynchronizes them from the source of truth, and the next Ansible run will
> overwrite the manual fix. If something is broken, fix the role/template/task in
> this repo (the source of truth), regenerate, and verify the change is
> idempotent. If you just want to experiment
> or try something custom, copy `/data/docker-compose/` elsewhere and work on the
> copy.

### Local dev loop

Three ways to deploy/iterate locally, documented in
[`scripts/README.md`](scripts/README.md) in this repo:

- **Watch + full deploy** (default, safe): `scripts/watch-and-test.sh` —
  re-runs `validate-config-gen.sh` + `ansiblew` on every detected change.
- **Fast iterate on one service**: `scripts/iterate-service.sh <service>`.
- **`ansiblew` directly**: explicit deploy, optionally scoped with `--tags`
  (`docker-compose`, `deploy`, `db-init`, `db-password-sync`, `docker-volumes`).

### Diagnosing deploy failures

On deploy failure, a `block/rescue` in `roles/la-compose/tasks/main.yml` writes:

- `/tmp/la-docker-deploy-failure.root.log` — root-cause first line per unhealthy
  container. **Read this before committing any `fix(...)`.**
- `/tmp/la-docker-deploy-failure.log` — full dump (`docker compose ps`, status,
  and `docker logs --tail 100` per container).

Further tooling: `scripts/diagnose-failure.sh --service <name>` and
`scripts/wait-for-health.sh --service <name> --verbose`.

### End-to-end verification

Beyond `docker compose config`, a green deploy is verified in **two layers**:

- **Layer 1 — deployment gate** (`scripts/verify-deployment.sh`): polls the Gatus
  API for every service (or `--direct` curl paths as a fallback) against an
  inventory-driven manifest, `e2e-targets.json`, generated by
  `roles/la-compose/tasks/generate-e2e-targets.yml` (resolves each service URL from
  its `*_base_url` / `*_context_path`, subdomain or path style). Report-only by
  default; `--blocking` returns an honest exit code.
- **Layer 2 — browser suite** (`e2e/`, Cypress): 8 specs exercising the real UIs —
  `1-homepage` (branding), `2-biocache` (occurrence search), `3-species` (BIE),
  `4-collections` (collectory), `5-spatial` (map), `6-lists`, `7-monitoring`
  (Gatus), and `8-auth` (CAS/OIDC login, gated). Queries are robust (`q=*:*`,
  `q=Acacia`) rather than pinned to fixed counts.

In CI these are controlled by the Jenkins parameters `RUN_E2E` (opt-in),
`E2E_BLOCKING` (promote failures to build failures) and `ENABLE_AUTH_TESTS`
(inject CAS credentials from the inventory for spec `8-auth`).

---

## CI (Jenkins)

The [`Jenkinsfile`](Jenkinsfile) is the source of truth for testing and
deployment in real testing VMs. Its key stages are:

1. **Unit tests** — `molecule test -s unit`.
2. **Regenerate inventories** — `yo living-atlas --replay-dont-ask --force`
   (with a fresh `generator-living-atlas` version) produces `lademo-inventory.ini`.
3. **Run playbooks** — `site.yml` / `config-gen.yml` via `ansiblew` against the
   generated inventory (`--limit docker_compose`, `auto_deploy=...`).
4. **Validate deployment** —
   `docker compose -f /data/docker-compose/docker-compose.yml config`.
5. **Verify Gatus health** — Layer-1 gate (`scripts/verify-deployment.sh`).
6. **Hot Redeploy Test** — the non-destructive contract, end-to-end
   (`TEST_REDEPLOY`; see [Production redeploys](#production-redeploys-non-destructive-contract)).
7. **Airflow Ingest e2e** — real DwCA ingest against the running stack
   (`RUN_AIRFLOW_INGEST`; independent of redeploy, and seeds the Cypress data).
8. **E2E Smoke Tests** — the Cypress suite (`RUN_E2E` / `E2E_BLOCKING` /
   `ENABLE_AUTH_TESTS`).

Redeploy behaviour is chosen by `FORCE_REDEPLOY` (the pipeline otherwise decides
whether to redeploy from what changed).

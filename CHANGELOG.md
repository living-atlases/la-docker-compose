# Changelog

Changes per release tag, newest first. A tag is only cut on a commit a green
la-docker-compose-tests build validated; each entry says which build. Entries up to
v1.9.0 were rebuilt from the annotated tag messages (commit subjects where a tag had
no message).

<a name="unreleased"></a>

<a name="v1.10.0"></a>

## v1.10.0 - 2026-09-28

**every Gatus endpoint green, and data hubs that serve every path on every host**

Green on 5aaf24b: build #426 (SUCCESS, CLEAN_MACHINE=true, 149 min), after the
redeploys #424 and #425 (SUCCESS). All 137 Gatus endpoints healthy through the new
total-green gate, Cypress 62/63 passing with 1 pending. First green since #413,
after the #414-#423 red streak. The hot-redeploy test (#427) was still running
when this was tagged.

Gatus
- feat(gatus): verify-deployment.sh --all-endpoints and a blocking "Verify Gatus
  Total Green" stage (GATUS_ALL_BLOCKING, default true). The group gates only read
  "Deep checks" and "Data checks", 14 of 137 endpoints, so #413 went SUCCESS with
  hub.l-a.site/ answering 404.
- fix(ci): a broken or failing e2e/gatus gate is never reported as a green build.

Data hubs across hosts
- fix(nginx): a hostname split across hosts is shared even with one member on
  this host. That member used to render in fast mode and the cross-host stubs
  re-assembled the file without it (host2 lost /species, host3 /regions).
- fix(nginx): the hub root is proxied to the branding owner's nginx over https,
  so every copy of the vhost serves '/'.
- fix(nginx): shared vhost hostnames were never detected; a shared vhost whose
  paths are all stubs no longer fails; stubs no longer shadow item.
- fix(gatus): shared-vhost stubs no longer duplicate the owner's checks.
- feat(hubs): hubs under a path serve there (server.servlet.context-path), their
  biocache-hubs are refreshed after the ingest, and the data-hub inventories are
  handed to the playbook run.
- fix(branding): the hub branding ships its commonui-bs3-2019 submodule; the
  controller init runs git as the checkout owner and repairs root-owned leftovers.
- guard: fail when two nginx vhost files declare the same server_name.

Redeploys and mounts
- fix(compose): remove the directories Docker leaves at file mount paths (nginx.conf
  and mounted files) before rendering.
- fix(compose): recreate exited one-shot init containers whose definition changed,
  and drifted running services outside production.
- fix(health): a container without a healthcheck must stay up before it counts as up.

Services
- fix(sds): nginx can read the SDS XML files it serves.
- fix(ala_hub): pass the Java 17 --add-opens the VM role already adds.
- fix(spatial-service): run the war exploded so task specs load.
- fix(layersdb): stop when layersdb exists without the upstream schema.
- fix(bie-hub): languageCodesUrl and blacklist point at the container mount.

CI and tests
- fix(e2e): retry the Cypress image pull, publish only this run's results.
- test: wait-for-health converge fixture fails loudly and retries once;
  refresh-biocache-fields never hangs; molecule multihub TC21-TC22.
- docs: CONTRIBUTING.md and a "How to help" section.

Known at tag time: the "Check if ports are listening" task probes
<host>.docker_compose, which does not resolve, so it always reports FAILED and is
ignored.

<a name="v1.9.0"></a>

## v1.9.0 - 2026-09-19

**Gatus "Data checks" now gate CI once their data is seeded**

Green: builds #395 (clean-machine deploy) and #396 (seed stages, GATE-PASSED on all 14 Deep+Data checks).

- feat(gatus): verify-deployment.sh --gate-data-checks; new Jenkins stage "Verify Gatus Data Checks" (runs when ingest + BIE import + lists seed all ran)
- feat(e2e): UI-driven species-list seed (6-lists/manage.cy.ts, adapted from inbo/vlaams-biodiversiteitsportaal, MPL-2.0), public list so the anonymous "lists count" check sees it; RUN_LISTS_SEED param
- fix(alerts): dataSource.dbCreate=none for alerts >= 5; Hibernate created tables before Liquibase and left alerts in an exit-0 crash-loop that aborted the health gate (builds #391-394)
- chore: wait_for_solr_collection_limit kept at 120 (init-solr runs after compose up; a longer wait only added dead time)

Caveats: E2E stages remain report-only unless E2E_BLOCKING; the Upload-form DOM ids come from the Flanders spec and were validated only by the passing CI run.

<a name="v1.8.0"></a>

## v1.8.0 - 2026-09-16

**el gate de Gatus corre por primera vez, y nadie elige nuestras versiones por nosotros**

Verde en CI: build #390 (SUCCESS, 127 min, CLEAN_MACHINE=true, TOPOLOGY=default),
sobre 025e61c. Serie de tres sesiones trabajando en paralelo.

Gatus: la Capa 1 de verificacion llevaba desde antes de #385 siendo un check
hueco, y por dos motivos independientes. verify-deployment.sh buscaba
e2e-targets.json en el agente de Jenkins, donde esa ruta no existe; y una vez
arreglado eso seguia sin resolver, porque NINGUN host emitia la clave gatus en el
manifiesto -- ni siquiera el que corre gatus. gatus_url vive en [gatus:vars], o
sea en <host>.gatus, mientras el manifiesto lo escribe <host>.docker_compose: la
misma trampa de scope ya conocida del vhost de gatus y de los *_upstream_host de
nginx. El filtro de URL absoluta se comia la clave en silencio. Resuelto via
groups['gatus'], que es global. En #390 el gate emitio por fin su veredicto real:
GATE-PASSED, los 9 endpoints de 'Deep checks' sanos.

El stage sigue en report-only, que aplana todo a exit 0, asi que el contrato
ahora es un marcador explicito por salida (GATE-PASSED / GATE-NOT-RUN) y el stage
exige el bueno: un verde sin veredicto en el log ya no cuela.

Imagenes: cinco terceras partes dejan de pedir lo que upstream sirva ese dia
(gatus v5.36.0, mailhog v1.0.1, postfix 5.1.0, alpine/openssl 3.5.8, clamav
1.5.4 -- 'stable' se mueve igual que 'latest'). Todas pinneadas a lo que ya
resolvian, asi que no cambian nada hoy; solo cierran la puerta por la que se colo
lo de db-backup.

Tests: scripts/test-verify-deployment.sh (26 asserts sobre las 6 inventories de
topologia committeadas) cableado al stage Unit tests, y .andon/checks.json pasa a
git para que el mapeo fichero->check viaje con el repo.

<a name="v1.7.0"></a>

## v1.7.0 - 2026-09-16

**data hubs across compose hosts, and a backup image that still exists**

Verde en CI: build #389 (SUCCESS, 128 min, CLEAN_MACHINE=true, TOPOLOGY=default),
sobre c59d53a.

Issue #14: un data hub puede repartir sus front-ends entre varios hosts del
cluster compose. La identidad del hub vive en las rutas del HOST; dentro del
contenedor las rutas no cambian, porque la imagen de stock lee las fijas. Los
alias de hub dejan de contaminar physical_server_groups -> services_enabled, que
era lo que hacia que colocar solo el branding de un hub en un host montara el
branding del PORTAL ahi. Certificado con molecule (multihub, TC13-TC16), la
matriz de topologias y el baseline de hub.

Y el motivo real de la racha #386-#388: tiredofit/db-backup se retiro. El 9 de
septiembre su tag latest paso a ser un stub distroless sin shell, asi que
["CMD","test","-d","/backup"] ya no se podia ni ejecutar y el health gate
quemaba su presupuesto entero en los dos hosts que lo llevaban. Sucesor
nfrastack/db-backup 5.0.2, pinneado, con el healthcheck propio de la imagen.
scripts/validate-healthcheck-commands.sh le pregunta a cada imagen si trae el
binario que su healthcheck ejecuta, antes del gate: en #389 dio 16/15/10 ok,
0 missing.

<a name="v1.6.0"></a>

## v1.6.0 - 2026-09-09

**species groups match the backbone they run on**

Build #385, 43/43 green, on 53927ec.

groups.json maps display groups onto taxon names that are resolved against the
deployed name index, so a file is only valid for the backbone it was written
against. Ours is COL; the shipped file is written against ALA's taxonomy, where
`Osteichthyes` does not resolve at all. On COL it resolves to an unranked clade
whose lft/rgt range contains Aves and Mammalia, so all 2072 birds of the CI
dataset came back tagged Birds AND Fishes -- through 300-odd green builds,
because nothing ever asserted on species_group.

  - groups-col.json, selected by species_groups_variant (defaults to
    nameindex_to_use, so ALA deployments are untouched). It changes only the
    taxa, never the group names: the occurrence facet publishes them as
    species_group.<Name> i18n codes, and renaming one breaks its translations.
  - scripts/validate-species-groups.sh checks a groups file against a live
    index -- every taxon resolves, resolves to the name asked for, lands inside
    its parent's subtree, siblings stay disjoint, no group is empty, names match
    a reference. 19 failures for the ALA file on COL, 0 for the COL variant.
  - Jenkins stage validating the file the deployment ACTUALLY installed, and a
    Cypress spec asserting a dataset-independent invariant on explore/groups
    plus a non-empty common_name facet.

Two infrastructure bugs surfaced on the way, both silent no-ops:

  - The config-change detector watched the CONTAINER path for
    namematching-service and sensitive-data-service, so hashing a directory that
    does not exist never changed and neither service was ever restarted for a
    config change. The corrected file reached the disk in #383 while the service
    kept serving the old groups from memory.
  - check-jinja-syntax.py: Ansible compiles a template only when it renders it,
    so a malformed expression first fails mid-deploy on every host. #384 spent 40
    minutes to die on a `#` inside a Jinja list. Layer 1 now parses them.

Verified end to end after the reingest: explore/groups gives Fishes 0 with 2067
birds, and namematching answers Vulpes vulpes with Animals, Mammals.

Open: subgroups.json has the same backbone-specific origin and is not measured
yet; groups.json says "Fishes" while subgroups.json says "Fish". Vernacular names
come back in an arbitrary language (Greek, Spanish, Italian and Afrikaans in one
dataset) -- nothing applies a language preference at ingest. Upstream, the ALA
file has 5 pre-existing defects of its own on ALA's own index. See gh-13.

<a name="v1.5.1"></a>

## v1.5.1 - 2026-08-23

**fix a dead link in the biocache alias migration message**

Validated by CI build #370 (SUCCESS): full deploy from a wiped cluster, ingest of
~2,072 real occurrences into Solr and biocache-service, and the new rendered-config
guard passing in CI for the first time.

init-solr's skip message pointed at docs/airflow-parity.md for the alias migration
steps. `docs` is in .gitignore and nothing under it is tracked, so that reference
resolved to nothing for anyone cloning the repo. The commands are inlined in the
message instead, which is where an operator is standing when they need them.

Message-only; no task, template or service behaviour changes.

<a name="v1.5.0"></a>

## v1.5.0 - 2026-08-23

**Airflow ingestion validated, and biocache becomes a Solr alias**

Validated by CI build #369 (SUCCESS): full deploy from a wiped cluster, plus an
ingest of ~2,072 real occurrences reaching both Solr and biocache-service.

BREAKING for existing deployments: `biocache` is now published as a Solr ALIAS
over a real collection (`biocache-seed` by default), because that is what the
Airflow reindex path swaps -- SolrCloud refuses an alias named after an existing
collection. Fresh deployments get this automatically. Existing ones are left
untouched on purpose: init-solr detects the legacy collection, changes nothing,
and prints the migration, which costs the current index and so stays an operator
decision. Queries, updates and /admin/luke all resolve through an alias, so
biocache-service, gatus and the Cypress suites need no change.

Airflow ingestion moves from smoke test to validated:
- the EMR-isms the overlay never translated -- `sudo -u hadoop`, /tmp files that
  only exist via cluster BootstrapActions, python3 assumed on the pipelines host,
  and ActionOnFailure -- are handled, so steps stop dying opaquely
- MinIO and the shared volume are reconnected: s3-dist-cp does a real copy, and
  the dataset download is translated instead of no-op'd, which is what Load_dataset
  and Ingest_all_datasets depend on
- CI ingests a real ~2k-occurrence archive by default rather than 8 hand-written
  records, so a green build means the pipeline processed something
- sampling targets the configured service with a key the jar accepts

Also in this release:
- the 11 hand-rolled `command:` overrides are retired in favour of generated env
- nginx follows ALA's 1.30 line; add_header_inherit is no longer emitted
- gatus stops monitoring route prefixes that answer 404 everywhere, and the disk
  check's hairpin branch works again
- logger gets a writable log dir instead of /tmp

Known gaps: Full_index_to_solr has never run end to end, and sampling is proven
only as far as "no longer aborts" -- a real sampling run needs layers loaded in
spatial-service.

<a name="v1.4.1"></a>

## v1.4.1 - 2026-08-19

**the two notes that stop someone undoing v1.4.0**

Build #360 green on 1889e0a (2026-08-19). Documentation only, no behaviour
change: v1.4.0 is where the substance is. Tagged because both notes are
operational, and because it puts the newest tag back on main's head -- v1.4.0
sits on 7fac10d, the commit #359 validated, with these two on top of it.

scripts/README.md gains a runbook for "does the .env actually reach the JVM?".
Four commands, and the two most obvious ones lie, both in the same direction:
`docker exec <c> java -XX:+PrintFlagsFinal` starts a NEW jvm that never sees
JAVA_OPTS (5.5G {ergonomic} measured against a real 2G {command line}), and
/proc/1/cmdline is the sh wrapper, not the jvm -- right by accident on the old
images, showing `${JAVA_OPTS}` unexpanded on the rebuilt ones. All four returned
a false result to someone during the la-docker-images#3 migration.

generate-compose.yml gains the reason there is no -Xss and why -Xms defaults to
1g. Comparing a container from before the rebuild with one from after shows
-Xss512k vanishing and -Xms dropping 2g -> 1g, which reads like tuning lost in
the migration. It is not: build.py:655 says outright it was replicating
tomcat_java_opts, the TOMCAT role's default, applied to services that on VMs ran
as exec-war and never set -Xss at all. The line here is identical to exec-war's.
Without that note the obvious reaction is to add the flags back.

[] -> 83 fields, hub 500 -> 200.

Known limitations are unchanged from v1.4.0 -- read that tag's message, in
particular the hub cold-start 500 whose mechanism is still unknown.

<a name="v1.4.0"></a>

## v1.4.0 - 2026-08-19

**records search that repairs itself, and a portal with no data is not a failure**

Build #359 green on 7fac10d (2026-08-19), 15 commits after v1.3.1. Tagged on the
commit CI actually validated, not on main's head: the two commits after it are
documentation and no build has run on them.

The theme is a stack that stops lying about its own health.

RECORDS SEARCH. biocache-service reads its index field list once at boot from
/admin/luke, which only reports fields present in the index SEGMENTS, so any boot
against an index with zero documents caches an empty list for the life of the
process. /index/fields then answers `[]` with HTTP 200 -- healthy to every gate we
had -- and the hub 500s on every /occurrences/search. #356 shipped green that way
with the portal unable to search. The gate now counts documents rather than
collections (an existing-but-empty collection is no better than a missing one, and
logs no error at all), and scripts/refresh-biocache-fields.sh closes the half a
deploy-time gate structurally cannot: it runs after the ingest, restarts
biocache-service when the field list is empty while the index holds records, then
biocache-hub once records-ws serves fields. Validated repairing itself unattended
in #357, #358 and #359 -- `[]` -> 83 fields, hub 500 -> 200, in about 90 seconds.

NO DATA IS NOT A FAILED INSTALL. verify-deployment.sh failed the build when any
"Deep checks" endpoint was red, and two of them go red on a portal that simply has
no records. A docker-compose portal has no dataResources, runs no e2e suite and may
not deploy Airflow at all. Those two checks moved to their own "Data checks" group,
which the deployment gate does not read. For the same reason the Solr gate gives up
in ~30s once the collection answers and is empty, instead of spending its full
budget to be told something a deploy can never change.

MIGRATION (feature). playbooks/portal-migrate-fetch.yml and playbooks/db-restore.yml
move a portal from VMs to Docker Compose one application database at a time --
never cluster-wide, because mysqldump --all-databases, pg_dumpall and a mongorestore
of admin each carry credentials that would replace the ones init-databases.yml
generated. The fetch play is read-only on the source and the only code here that
opens SSH to production VMs.

JAVA_OPTS. `JAVA_OPTS: ${<SERVICE>_JAVA_OPTS}` REPLACES the image's own ENV rather
than adding to it, so .env now emits spring.config too -- since la-docker-images#3
the image no longer supplies it. Guarded by scripts/test-java-opts-env.sh.

KNOWN LIMITATIONS AT TAG TIME

- biocache-hub 500s on /occurrences/search after a deploy, on an <alatag:message>
  NPE, and only a restart clears it. Mechanism UNKNOWN. Ruled out: the i18n volume,
  biocache-service's empty field list (the hub makes no /facets/i18n call), and an
  upstream fix (unchanged since 2021, so 8.3.0 == 8.1.0). #359 answered one open
  question: it still 500s on the REBUILT image, so la-docker-images#3 did not change
  its initialisation. The guard above is a remedy, not a fix.
  scripts/probe-hub-cold-start.sh (PROBE_HUB_COLD_START, off) would settle it.
- The migration playbooks are committed but NOT covered by CI. Run by hand.
- -Dhttp.agent falls back to /develop for 8 services (ala_hub, userdetails,
  species_lists, spatial, images, doi, namematching, sensitiveDataService): the
  template looks up <key>_version while the inventory names it differently.
  Cosmetic, reaches an outgoing User-Agent only.
- The Solr gate's fast bail did not trigger in #357-#359: the collection was not
  queryable at all during its window, so it still spent ~6 minutes.

<a name="v1.3.1"></a>

## v1.3.1 - 2026-08-13

- chore(ala-install): bump to the SDS nameindex Lucene guard
- fix(branding): survive a build cache that outlived its image store

<a name="v1.3.0"></a>

## v1.3.0 - 2026-08-13

**a stack that boots healthy on its own, and datastores it points at correctly**

Green on CI build #349 (failed=0 on all three hosts), 24 commits after v1.2.0.
Where v1.2.0 was about getting the legacy services deployed at all, this one is
mostly about the stack coming up right without a human nudging it.

Boot ordering, so services stop needing a restart to work
- biocache-service now gates its boot on the Solr collection existing, instead
  of racing it
- biocache-hub waits for i18n rather than serving 500 until someone restarts it
- API keys are seeded after la_apikey is up, not against tables that do not
  exist yet
- databases are provisioned where the datastores actually are, not where CAS is

Health gate
- crash loops are detected instead of quietly consuming the whole budget
- a service still booting is waited out, not called a failure

Datastores in mixed VM+Docker deployments
- every *_docker_local fact now comes from one alias-aware predicate. The old
  ones intersected raw inventory group members, but the generated inventory
  gives each service its own alias for the same machine, so the test was empty
  by construction and read false on an all-docker deployment
- stack-local datastores are no longer pointed at production VMs

Also
- feat(ingest-e2e): the dataResource is registered, so a clean deploy can ingest
- ala-install min-PR branch rebased onto upstream 7b1fe41c and restructured
- FQCN enforced across the role, and the 18 copies of the service-alias loader
  replaced by one
- README now states what is solid, what is experimental, and the version floor

Not included: the VM-to-Docker portal migration playbooks, still in progress and
not covered by this build.

Caveats unchanged from v1.2.0: airflow/pipelines ingestion is experimental, and
ala-install still points at the vjrj/ala-install fork.

<a name="v1.2.0"></a>

## v1.2.0 - 2026-08-06

**legacy doi, sds and sensitive-data-service deploy as compose services**

First clean green (CI build #337, failed=0 on all three hosts) with the three
previously-skipped legacy services actually deployed.

Features
- sds: legacy sds-webapp2 as a compose service, co-existing with the integrated one
- sensitive-data-service: legacy image, its own fixed nameindex directory, and its
  data files repaired downstream instead of in ala-install
- doi: a dedicated version-matched ES 7.x sidecar, so grails-elasticsearch's
  TransportClient can run against a stack whose shared Elasticsearch is 8.x
- gatus: alert on host disk usage at 80% rather than at ENOSPC
- docker-housekeeping: image-layer GC, log rotation and a journal cap for hosts
  running the containerd snapshotter

Fixes worth calling out
- health gate: the timeout(1) wrapper allowed health_check_timeout + 60 while the
  script's worst case included its converge rounds, so it killed the gate at
  exactly 13:00 with rc=124 and converge-by-retry was dead code. Both budgets now
  derive from the same variables. This cost a gbif-es production deploy.
- cassandra: biocache_db_host was hardcoded to the la_cassandra compose alias, which
  resolves nowhere when Cassandra lives on the VM leg of a mixed deployment.

Known caveats
- airflow / pipelines ingestion is experimental
- ala-install still points at vjrj/ala-install@docker-compose-min-pr
- gbif-es (mixed VM+Docker) has not been redeployed against this yet; it needs
  -e docker_force_recreate=true for the postfix healthcheck fix to land

<a name="v1.1.7"></a>

## v1.1.7 - 2026-07-29

**fix the SSL diagnostics task an apostrophe made unparseable, and guard against it**

- fix(diagnostics): an apostrophe in a comment broke the whole task

<a name="v1.1.6"></a>

## v1.1.6 - 2026-07-29

**nginx starts in the containers: no IPv6 listen, and nginx logs in the SSL diagnostics**

- fix(nginx): don't listen on IPv6 inside the containers

<a name="v1.1.5"></a>

## v1.1.5 - 2026-07-29

**certificate validation no longer runs against stale containers**

--no-recreate starts an existing container with the bind mounts it was created with, so
after v1.1.4 moved the certificate mount to the docker host, an older cert-validator
kept mounting the previous (empty) directory and the validation could never pass. The
validation now recreates only the services whose compose config-hash drifted.

<a name="v1.1.4"></a>

## v1.1.4 - 2026-07-29

**site certificates mounted from the docker host + self-diagnosing nginx SSL validation**

- fix(certs): with use_la_site_certs=false, nginx and cert-validator bind-mounted
  <inventory_dir>/certs/, a path on the ANSIBLE CONTROLLER. On a remote docker host it
  does not exist, so Docker created it empty and mounted it over the certificate
  directory: cert-validator found no certificate, exited non-zero, and nginx (which
  waits on it with service_completed_successfully) never started. Certificates now come
  from the docker host itself, at the same path; /etc/letsencrypt is mounted whole when
  the cert dir lives under it, so live/<domain>/*.pem symlinks into ../../archive/ still
  resolve. Override with ssl_certs_host_mount_dir.
- fix(certs): preflight stats the real cert and key on the docker host before starting
  nginx; `docker compose up nginx` no longer ends in '|| true', and a failure now
  carries 'docker compose ps' and the cert-validator logs. DOCKER_HOST on every docker
  command in the block, retries instead of a fixed sleep, and the asserts against a
  hardcoded l-a.site path are gone.
- test: new molecule scenario 'certs' covering both certificate sources.
- fix(cas): index the Mongo audit repository so login stops timing out.
- fix(mysql): probe over TCP so first-boot init cannot report healthy too early.
- fix(nginx): mount every ala-install static 'alias' dir, not one service at a time.
- fix(biocache): mount the offline-download dirs into biocache-service and nginx.

<a name="v1.1.3"></a>

## v1.1.3 - 2026-07-24

**branding brunch/vite autodetect + SSH perf + ala-install maxent GitHub-mirror fix**

- chore(ala-install): bump submodule to include maxent GitHub-mirror fix

<a name="v1.1.2"></a>

## v1.1.2 - 2026-07-24

**branding brunch/vite autodetect + SSH pipelining/ControlPersist perf**

- fix(branding): detect brunch vs vite; add SSH pipelining/ControlPersist

<a name="v1.1.1"></a>

## v1.1.1 - 2026-07-21

**Fix for branding build**

- Fix for branding build

<a name="v1.1.0"></a>

## v1.1.0 - 2026-07-20

Highlights since v1.0.0:
- fix(topology): ensure host 'nginx' user/group exists before docker-common vhost chown
- fix(biocache-hub): tolerate path/URL in grouped_facets_json/overlays_json + stage custom facets file
- feat(la-compose): non-destructive hot redeploy for production
- feat(topologies): validate alternative service->host layouts
- multiple spatial skin/layout and redeploy robustness fixes

<a name="v1.0.0"></a>

## v1.0.0 - 2026-07-07

**ala-install min-PR rebased on latest ALA upstream, squashed; full stack green (CI + local)**

- ala-install docker-compose support rebased onto AtlasOfLivingAustralia/ala-install
  master and squashed to 6 reviewable commits (logging, nginx_vhost, pipelines,
  gatus, deployment_type gates, per-service container config).
- Minimized for upstream acceptability: fork-specific docs/comments trimmed,
  pipelines host-provisioning gated by deployment_type (not deleted), gatus
  up-condition configurable.
- Fixes: nginx_vhost fragment idempotency (duplicate /apikey), spatial-hub
  lists_version guard, latin-1-safe template comments, layersdb table ownership
  for spatial-service.
- Verified green in CI and local against the new la-pipelines image.

<a name="v0.6.0"></a>

## v0.6.0 - 2026-07-06

**Airflow pipelines-airflow overlay: ingest e2e + multihost + notifications**

- Real-ingestion e2e harness (phase E4): scripts/e2e-airflow-ingest.sh triggers
  Ingest_small_datasets directly (run_indexing=true) against the live stack; fixed
  DwCA fixture (e2e/fixtures/dr-test). CI param RUN_AIRFLOW_INGEST, decoupled from
  redeploy.
- CI safety guard: ingest-only runs never redeploy or wipe (isManual via MCP no
  longer forces the nuclear cleanup).
- Multihost reachability: cross-host extra_hosts for la_pipelines and the airflow
  overlay; biocache_url derived from inventory (generic, no hardcoded domains).
- Optional stage skipping (PIPELINES_SKIP_STAGES) makes SDS optional without
  touching pipelines-airflow.
- Generic provider-agnostic notifications (Telegram/Slack) via Airflow cluster
  policy - mirrors ALA, zero DAG changes.

Not pushed until the CI build on this HEAD is green (green-tag convention).

<a name="v0.5.0"></a>

## v0.5.0 - 2026-07-04

**CI green (#267, Gatus 0/119 down)**

Since v0.4.0 (#259): data-quality OIDC scope + i18n mount (post-login 500 fixed); OIDC-honest healthchecks for dq/logger (self-heal boot-ordering on clean redeploy); mailhog static proxy_pass for cross-host extra_hosts upstream (502 fixed); logger pinned via logger_version; spatial base-branding skin auto-detect for git-URL branding; e2e robustness (map assertion, login force-click, clean results); Jenkinsfile redeploy+e2e by default. Pending: spatial skin still portal, biocache empty index (records-ws 400), e2e report staleness.

<a name="v0.4.0"></a>

## v0.4.0 - 2026-07-03

**build #259 verde (SUCCESS)**

Hito verde de la-docker-compose-tests sobre 157e020. 4 commits desde v0.3.0.

Destacado
- fix(solr): schema biocache vendorizado de pipelines@feature/ala-upgrade - records-ws
  /occurrences/search 400→200 (biocache-service 3.8.1 pedía firstLoadedDate/_nest_parent_
  ausentes en el schema v2 de ala-install). Issue #2.
- fix(gatus): cert-checks sin dns-resolver externo + interval 15m - fin del flapping espurio.
- fix(e2e): spatial hub test auth-aware (/ está CAS-gated) + fix(collectory) scope OIDC ROLE_ADMIN.

Conocido (no bloquea el verde de CI): e2e SKIPPED en #259 (gate DO_REDEPLOY; requiere
FORCE_REDEPLOY); records hub 500 con índice vacío; data-quality /data-profiles y logger /admin
500 (regresiones a investigar). Ver TODO.org.

<a name="v0.3.0"></a>

## v0.3.0 - 2026-07-02

**build #257 verde (failed=0 en 2023-1/2/3)**

Hito verde de la-docker-compose-tests sobre 90a9849. 20 commits desde v0.2.1.

Destacado
- feat(e2e): framework de verificación de despliegue (gate API Gatus + Cypress)
- feat(airflow): admin password generado cableado al overlay pipelines; airflow_hostname vhost
- fix(cas-oidc): _id determinista + registro fail-loud; no romper deploy por servicios OIDC no desplegados
- fix(auth): userdetails forzado a OIDC (arregla StackOverflow /myprofile)
- fix(cas/mysql): emmet con collation utf8mb4_unicode_ci
- fix(spatial): context-path /ws; data-quality escucha 0.0.0.0; fast-mode off en vhosts compartidos
- fix(ci): CLEAN_MACHINE borra volúmenes external de datastores
- fix(health-gate): converge timeout 180->600 para re-cache branding bie-hub

Limitaciones conocidas (WIP, no bloquean el verde)
- Tests e2e en desarrollo: fallos e2e son no-bloqueantes (E2E_BLOCKING=false).
- Scopes OIDC sin afinar: ROLE_ADMIN sigue fallando en collectory.

<a name="v0.2.1"></a>

## v0.2.1 - 2026-07-01

**Airflow NO-AWS overlay working on the pipelines host, CI #241 green**

The pipelines-airflow overlay (Airflow + MinIO, opt-in via use_airflow) now deploys
and boots on the pipelines node in the multi-host CI.

Fixes build #240 (red, 2023-3 failed=1): the overlay start task chdir'd into the
controller's playbook_dir, which does not exist on the remote pipelines host ->
"Unable to change directory". Now stages the overlay tree + submodule DAGs onto the
host under docker_compose_data_dir (same pattern as the core stack / init-*.yml) and
chdir's there with absolute host paths. Startup is best-effort (failed_when: false)
so a heavy/opt-in Airflow flake never reds the core CI.

Verified CI #241 green: 3 hosts failed=0, "Airflow overlay started" on 2023-3.

<a name="v0.2.0"></a>

## v0.2.0 - 2026-06-30

**spatial stack re-enabled (4/5 heavy services functional), CI #236 green**

Re-enabled from SKIP_SERVICES (incremental, taking ala-install as reference):
- spatial-hub, spatial-service: Logback config (was the crash-loop), spatial-service CAS appServerName
- geoserver: RUN_AS_ROOT + functional init (ALA workspace + LayersDB PostGIS datastore)
- geonetwork: postgres SCRAM->md5
- layersdb: uuid-ossp extension

Also fixes CI #229 (COMPOSE_ENV_FILES absolute paths). Still deferred: doi-service (4.1.0
incompatible with ES 8.10 via grails-elasticsearch; migrated to atlas-index) and SDS.

<a name="v0.1.1"></a>

## v0.1.1 - 2026-06-29

**last green before new-services work (build #219)**

Multi-host CI green (eacc261, inventory scope-leak check). Last known-good
prior to the alerts/regions/doi/data-quality/spatial/geoserver/geonetwork work
that opened the #220+ red streak.

<a name="v0.1.0"></a>

## v0.1.0 - 2026-06-29

**first green multi-host CI (build #210)**

First failed=0 across all 3 hosts (2023-1/2/3) since #86; bie-hub config-dir
permissions fix (c330f44). Baseline known-good before the new-services work.

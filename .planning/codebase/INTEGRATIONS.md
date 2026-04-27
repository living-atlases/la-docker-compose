# External Integrations

**Analysis Date:** 2026-04-27

## APIs & External Services

**Living Atlas Ecosystem (ALA/GBIF):**
- All services communicate over the internal Docker network `internal` (bridge driver)
- Service-to-service calls use Docker network aliases (e.g., `la_collectory`, `la_cas`)
- External URLs configured in inventory (`collectory_base_url`, `biocache_service_url`, etc.)

**Demo TLS Certificates:**
- Service: `livingatlases/l-a-site-certs:latest` Docker image
- Purpose: Provides wildcard cert for `*.l-a.site` domain (demo/dev use)
- Control var: `use_la_site_certs: false` (disabled by default)
- Template: `roles/la-compose/templates/docker-compose/infrastructure/nginx.yml.j2`

**External ALA Services (dev-overlay mode):**
- Remote portal proxied via nginx `proxy_pass` to `proxy_remote_portal` var
- Java apps resolve remote DBs via `docker_extra_hosts` entries
- Use case: run 1-2 services locally, consume rest from production/staging

## Data Storage

**Databases:**

- **MySQL 8.0-debian** (`la_mysql` container)
  - Used by: CAS, Collectory, Userdetails, Apikey, SpeciesList, Logger
  - Volume: `la_mysql-data` (external Docker volume, `/data/mysql`)
  - Init: `roles/la-compose/templates/mysql/init/` scripts
  - Connection env var: `MYSQL_ROOT_PASSWORD`, per-service vars e.g. `collectory_db_host_address`
  - Template: `roles/la-compose/templates/docker-compose/infrastructure/mysql.yml.j2`
  - Default port: 3306 (internal only; `expose_db_ports_for_init` to expose temporarily)

- **MongoDB 7** (`la_mongodb` container)
  - Used by: CAS (ticket registry, audit log, sessions, OIDC services), Ecodata
  - Volume: `la_mongodb-data` (external)
  - Init: `roles/la-compose/templates/docker-compose/infrastructure/mongodb.yml.j2`
  - Env: `MONGODB_ROOT_USERNAME`, `MONGODB_ROOT_PASSWORD`
  - Default port: 27017 (internal only)

- **PostgreSQL 16-alpine** (`la_postgres` container)
  - Used by: Spatial Hub, Image Service, DOI Service, Data Quality Filter Service
  - Volume: `la_postgres-data` (external)
  - Env: `POSTGRES_PASSWORD`
  - Template: `roles/la-compose/templates/docker-compose/infrastructure/postgres.yml.j2`
  - Default port: 5432 (internal only)

- **Apache Cassandra 5.0.6** (`la_cassandra` container)
  - Used by: Biocache Service (occurrence data, `occ` keyspace)
  - Volume: `la_cassandra-data` (external)
  - Config var: `cassandra_keyspace_create_cql`, `biocache_db_host: la_cassandra`
  - Template: `roles/la-compose/templates/docker-compose/infrastructure/cassandra.yml.j2`
  - Ports: 9042 (CQL), 9160 (Thrift), 7000/7001 (cluster) — internal only

**Search / Indexing:**

- **Apache Solr 9.4** (`la_solr` container, SolrCloud mode)
  - Used by: Biocache Service (occurrence search), BIE Index (species search)
  - Volume: `la_solr-data` (external)
  - ZooKeeper: embedded/single-node (`zoo1:2181`)
  - Config vars: `solrcloud_version`, `solr_url`, `docker_solr_zk_hosts`
  - Template: `roles/la-compose/templates/docker-compose/infrastructure/solr.yml.j2`
  - Port: 8983 (internal only)

- **Elasticsearch 8.10.0** (`la_elasticsearch` container)
  - Used by: Image Service, Events, DOI Service, Ecodata
  - Volume: `la_elasticsearch-data` (external)
  - Single-node mode, xpack.security disabled
  - Template: `roles/la-compose/templates/docker-compose/infrastructure/elasticsearch.yml.j2`
  - Port: 9200/9300 (internal only)

**File Storage:**
- Local filesystem at `/data/` on Docker host (bind mounts into containers)
- Docker external volumes for persistent DB data (named `la_*-data`)
- `i18n` translations shared via Docker volume `ala-i18n-data` (populated by init container)
- Branding assets via `la_branding-assets` Docker volume

**Caching:**
- Ansible fact cache: jsonfile at `/tmp/ansible_facts` (1 hour TTL)
- Docker layer cache: `/home/<user>/.cache/docker-buildx`

## Authentication & Identity

**Auth Provider:**
- CAS 6.x (`la_cas` container, image: `cas:{{ cas_version }}`, default `6.5.6-3`)
  - Protocol: CAS + OIDC
  - Backend stores: MySQL (user data), MongoDB (tickets/sessions/audit)
  - OIDC discovery: `https://<cas_host>/cas/oidc/.well-known`
  - Admin init: `roles/la-compose/tasks/init-cas-admin.yml`
  - Config vars: `cas_tgc_crypto_*`, `cas_webflow_*`, `cas_oauth_*` (encryption keys)
  - Port: 9000 (internal)

- **Userdetails** (`la_userdetails`, port 9001) - User profile service backed by MySQL
- **Apikey** (`la_apikey`, port 9002) - API key management, backed by MySQL
- **CAS Management** (`la_cas-management`, port 8070) - Admin UI for CAS service registry

**Service Auth Pattern:**
- All services authenticate via `auth_base_url` / `auth_cas_url`
- API calls authenticated with `api_key` / `registry_api_key` / `speciesList_api_key`
- Cookie: `ALA-Auth` (`auth_cookie_name`)
- PAC4J cookie encryption: `pac4j_cookie_encryption_key`, `pac4j_cookie_signing_key`

## Monitoring & Observability

**Health Monitoring:**
- Gatus (`twinproduction/gatus:latest`, `la_gatus_service` container)
  - Dashboard port: 8080 (internal, proxied by nginx)
  - Config: `{{ data_dir }}/gatus/config/` (generated from `gatus-endpoint.yaml.j2`)
  - Data volume: `la_gatus-data`
  - Template: `roles/la-compose/templates/docker-compose/infrastructure/gatus.yml.j2`
  - Control: `monitoring_enabled: false` (disabled by default in `defaults/main.yml`)

**Docker Healthchecks:**
- All containers define `healthcheck` (curl, mysqladmin ping, pg_isready, etc.)
- Compose `depends_on: condition: service_healthy` enforces startup order
- Pre/post deploy validation: `roles/la-compose/tasks/validate-pre-deploy.yml`, `validate-post-deploy.yml`

**Logs:**
- Container logs via Docker json-file driver (default)
- LA Pipelines: `max-size: 10m`, `max-file: 3`
- Nginx: `/var/log/nginx/` (within container)
- Jenkins pipeline stdout via `ansiColor('xterm')`

## CI/CD & Deployment

**Hosting:**
- Production target: `gbif-es-docker-cluster-2023-1/2/3` (SSH, 3 nodes)
- Data dir: `/data/docker-compose/` on each target host

**CI Pipeline:**
- Jenkins (job: `la-docker-compose-tests`, URL: `https://jenkins.gbif.es/job/la-docker-compose-tests/`)
- Pipeline: `Jenkinsfile` (declarative, Groovy)
- Stages: Clean machines → Prepare env → Update deps → Decide redeploy → Install generator → Regenerate inventories → Pre-Deploy Docker Cleanup → Run Playbooks → Validate Deployment
- Parameters: `FORCE_REDEPLOY`, `CLEAN_MACHINE`, `ONLY_CLEAN`, `GENERATOR_BRANCH`, `AUTO_DEPLOY`
- Change detection: SHA files at `${BASE_DIR}/.last_sha_gen` and `.last_sha_self`
- Ansible venv: `${BASE_DIR}/.venv-ansible` (created fresh if missing)

**Git Submodule:**
- `ala-install` pinned at branch `docker-compose-min-pr` (SHA `1067145658346b10d0b3ebd173cf379971fe1402`)
- Updated by: `git submodule update --init --recursive --remote`

## Webhooks & Callbacks

**Incoming:**
- Jenkins SCM polling trigger on `la-docker-compose` repo changes
- Jenkins manual trigger (detected via `hudson.model.Cause$UserIdCause`)

**Outgoing:**
- `generator-living-atlas` cloned from `https://github.com/living-atlases/generator-living-atlas.git`
- Docker images pulled from Docker Hub and `docker.elastic.co` at container startup

## Service-to-Service Communication Patterns

**Internal (Docker network `internal`):**
- All ALA services on same bridge network with DNS aliases (e.g. `la_cas`, `la_mysql`)
- Nginx (`la_nginx` / `la_nginx_service`) is the single ingress, routes by virtual host
- Services expose ports internally only (`expose:` not `ports:`)

**Nginx Reverse Proxy:**
- Config generated by ala-install nginx_vhost role + la-compose overrides
- Config output: `{{ docker_compose_data_dir }}/nginx/` (bind-mounted into nginx container)
- TLS termination at nginx; upstream services are plain HTTP

**Email:**
- Postfix container (`la_postfix`, `boky/postfix` image) for outbound SMTP
- Config vars: `email_sender_server`, `email_sender`, `email_sender_password`, `email_allowed_domains`
- MailHog used in dev/test (`docker_mail_development_mode: true`)

**Volume-based data sharing:**
- i18n translations: `ala-i18n-data` volume (i18n-init container → all Java services)
- Branding: `la_branding-assets` volume (branding-init container → nginx)

---

*Integration audit: 2026-04-27*

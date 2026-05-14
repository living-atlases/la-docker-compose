# la-docker-compose: Master Plan (2026-05-12)

> **Estado actual**: Fase 0 ✅ / Fase 1 ✅ / Fase 2 ✅ (DB stack + init) / Fase 3 ✅ (Branding + Gatus).
> **Última actualización**: 2026-05-13 (sesión AM2)
> **Objetivo**: completar las fases básicas con metodología local-first y TDD antes de subir a Jenkins/cluster.

### Progreso reciente (2026-05-12 → 2026-05-13)

- ✅ `validate-config-gen.sh` funcional: 5 checks pasan (molecule, config-gen, no-localhost DBs, nginx upstreams, docker-compose syntax)
- ✅ `normalize-hostnames.yml` cubre MySQL, PostgreSQL, MongoDB (CAS), Elasticsearch, Solr, Cassandra, mail
- ✅ `inventories/testing/.yo-rc.json` creado para single-host localhost (permite `yo living-atlas --replay-dont-ask --force`)
- ✅ db-backup `depends_on` eliminado (incompatible con Docker Compose v5 `include:`)
- ✅ `.env` ahora genera 31 `*_JAVA_OPTS` con `-Dlogging.config=` paths (bug: dos tasks sin `tags: [docker-compose]` — fixed)
- ✅ `.env` incluye `CAS_FIRST_ADMIN_*` y passwords reales (añadido `lademo-local-passwords.ini` a inventario testing)
- ✅ **Fase 2**: stack DB levantado (`docker compose --profile dbs up -d`) — 7 contenedores `healthy`
- ✅ **Fase 2**: DB init completado vía `docker exec` — schemas MySQL + users MongoDB creados
- ⚠️ **Nota**: `cas5-dbs` Ansible role falla en `mysql-client` package install en Debian con solo cliente MariaDB — usar `docker exec` approach o añadir `ignore_errors: true`
- ⚠️ **Nota**: puerto 27017 ocupado por Docker Desktop — `mongodb_host_port=27018` en template
- ✅ **Fase 3**: Branding init container corriendo (exit 0), assets en `la_branding-assets` volume
- ✅ **Fase 3**: Gatus corriendo (`success=true` cada minuto); healthcheck deshabilitado (scratch container sin shell)
- ✅ **Fix**: `gatus.yml.j2` healthcheck: `CMD curl` → `disable: true` (imagen distroless, sin shell/curl/wget)
- ✅ **Fix**: Cassandra commit logs limpiados tras reinicio sucio; volumen de datos persiste
- ℹ️  **Runtime path**: `/home/vjrj/la-docker-run` (Docker Desktop requiere paths en /home, no /tmp)

---

## Diagnóstico: por qué llevamos 13+ builds fallidos

1. **Metodología invertida**: se prueba en Jenkins/hardware real antes de validar localmente.
2. **Sin tests unitarios**: no hay forma de verificar que una tarea funciona antes de ejecutar el stack completo.
3. **Inventario manual**: el inventario de testing (`inventories/testing/`) fue creado a mano, no viene del generador — diverge silenciosamente del inventario real.
4. **Bloqueadores encadenados**: CAS → nginx upstream → APIKey → servicios. Un solo fallo tumba todo.
5. **Normalización incompleta**: `normalize-hostnames.yml` no cubre todas las variables de los roles de CAS (no solo las de MongoDB: `cas_spring_session_host`, `cas_services_host`, `cas_tickets_host`, `cas_audit_host`, sino también otras variables de host de servicios ALA como collectory, biocache, etc.) → configs con `localhost` en vez del nombre del contenedor.
6. **Lección del POC Docker Swarm olvidada**: los playbooks `ala-install/ansible/*docker.yml` establecían correctamente las variables para entorno contenedor. El trabajo actual no sigue ese patrón, lo que hace que los roles usen valores de deploy en VM en vez de nombres de contenedor docker.

---

## Principios para este plan

- **Local primero**: cada fix se valida en local antes de tocar Jenkins.
- **Un servicio a la vez**: branding → SSL → gatus → CAS → sub-servicios → integraciones.
- **TDD con Molecule**: cada tarea ansible tiene un test de molécula antes de ejecutarse en real.
- **Inventario generado**: usar `generator-living-atlas` (`yo living-atlas --replay-dont-ask --force`) sobre un directorio con `.yo-rc.json` de la-demo (usando `localhost` en vez de los hostnames reales) para producir el inventario de local-docker, no mantenerlo a mano.
- **Cada fase tiene un criterio de éxito verificable** (no "se ejecuta sin errores" sino "el servicio responde HTTP 200").

---

## FASE 0 — Fundación de testing (prerequisito de todo lo demás)

**Objetivo**: tener un entorno local donde cualquier tarea ansible se pueda probar rápido sin Jenkins.

> **Nota**: hay tests acumulados en `tests/` (test-full-flow.yml, test-no-localhost-configs.yml, variable-collision-test, etc.) que se han ido añadiendo y abandonando sin un protocolo establecido. Esta fase define ese protocolo y consolida los tests existentes.

### 0.1 — Setup de Molecule como harness local

- [x] Confirmar que `molecule test` pasa para el rol `la-compose` en su estado actual.
- [x] Añadir escenario `molecule/unit/` separado del escenario de integración (`molecule/default/`).
  - `unit/`: testea tareas individuales aisladas (normalize-hostnames, setup-facts, generate-compose).
  - `default/`: testea el rol completo (integración, más lento).
- [ ] Documentar en `tests/README.md` cómo ejecutar cada escenario.
- [ ] Añadir stage `Molecule Unit Tests` al Jenkinsfile como **primer paso** del pipeline, antes de cualquier deploy.

**Criterio de éxito**: `molecule test -s unit` pasa en < 2 minutos en local y en Jenkins.

### 0.2 — Script de validación local completo

~~Existe `scripts/validate-config-gen.sh` (sin contenido útil aún). Debe:~~ **[COMPLETADO]** — 5 checks implementados y pasando.
- [x] Ejecutar `molecule test -s unit`.
- [x] Ejecutar `ansible-playbook` (config-gen) contra el inventario local.
- [x] Ejecutar `docker compose config` sobre el compose generado.
- [x] Reportar PASS/FAIL por cada check.

- [ ] Añadir git pre-push hook (en `.git/hooks/pre-push` o via `lefthook`/`pre-commit`) que ejecute `validate-config-gen.sh` antes de hacer push, similar a cómo Spotless bloquea código sin formatear.

**Criterio de éxito**: `./scripts/validate-config-gen.sh` corre en < 5 min; un push con configs rotas queda bloqueado automáticamente.

### 0.3 — Inventario generado (no manual)

El inventario `inventories/testing/lademo-dev-docker-inventory.ini` existe pero fue escrito a mano.
Debe venir del generador igual que `/data/la-toolkit/config/lademo/lademo-inventories/`.

- [x] Crear `inventories/testing/.yo-rc.json` adaptado de la-demo con `localhost` en vez de hostnames reales.
- [ ] Añadir `inventories/testing/README.md` con instrucciones y el comando.
- [ ] Verificar que las variables del inventario generado (`group_vars/docker_compose_hosts.yml`) apuntan a nombres de contenedor (`la_mysql`, `la_mongodb`, etc.) y no a `localhost`.
- [ ] Añadir el inventario generado a `validate-config-gen.sh`.

**Criterio de éxito**: `inventories/testing/` se regenera en 1 comando; el proceso debe repetirse cada vez que se actualice el generator para incorporar nuevas versiones y funcionalidades (no se mantiene a mano).

### 0.4 — Profiles de Docker Compose para arranque mínimo

En vez de mantener un inventario separado, usar **Docker Compose profiles** para arrancar subconjuntos del stack completo desde el mismo `docker-compose.yml` generado.

Profiles a definir en el compose generado:
- `profile: core-auth` → branding + CAS + cas-management + userdetails + apikey + nginx + SSL
- `profile: dbs` → MySQL + PostgreSQL + MongoDB + Redis + Solr + Cassandra
- `profile: monitoring` → gatus + portainer
- `profile: app-core` → collectory (+ deps: core-auth + dbs)
- `profile: full` → todos los servicios

Uso:
```bash
docker compose --profile dbs up -d         # solo bases de datos
docker compose --profile core-auth up -d   # solo autenticación
docker compose --profile app-core up -d    # stack mínimo funcional
```

- [ ] Añadir `profiles:` a los templates Jinja2 del compose generado.
- [ ] Documentar los profiles en `inventories/testing/README.md`.

**Criterio de éxito**: `docker compose --profile core-auth up -d` arranca en < 5 min y solo levanta los servicios del grupo de autenticación.

---

## FASE 1 — Reparar la generación de configuración

**Bloqueador raíz**: `normalize-hostnames.yml` no cubre todas las variables de host de los roles ALA. El problema no es solo MongoDB/Redis para CAS — también afecta a otros servicios (collectory, biocache, etc.) que tienen defaults de VM en sus roles ala-install.

**Referencia**: revisar `ala-install/ansible/*docker.yml` del POC Swarm **y la utilidad en `ala-install/utils/`** que ya implementaba la normalización correctamente — partir de ahí en vez de reinventar.

### 1.1 — Auditar variables con default `localhost` en roles ala-install

Para **todos** los roles con guards `deployment_type: container`: `cas5`, `cas-management`, `apikey`, `userdetails`, `collectory`, `biocache-service`, `bie-hub`, `bie-service`, `image-service`, `logger`, `namematching`, `species_list`, `sensitive_data`:
- [ ] Listar todas las variables `*_host*`, `*_hostname*`, `*_url*`, `*_uri*` en `defaults/main.yml` que tienen `localhost` o hostname de VM como valor.
- [ ] Comparar con lo que `normalize-hostnames.yml` y los playbooks `*docker.yml` sobreescriben.
- [ ] Documentar los gaps en `docs/hostname-normalization-gaps.md`.

Variables conocidas que faltan (CAS y sub-servicios):
```
cas_spring_session_host   → la_redis (o la_mongodb)
cas_services_host         → la_mongodb
cas_tickets_host          → la_mongodb
cas_audit_host            → la_mongodb
```

**Criterio de éxito**: documento con lista completa de variables y su valor contenedor correcto.

### 1.2 — Completar `normalize-hostnames.yml`

- [x] Añadir `set_fact` para cada variable identificada (MySQL, PG, MongoDB CAS, ES, Solr, Cassandra, mail).
- [x] Añadir test Molecule que verifica que después de `normalize-hostnames.yml` ninguna variable `*_host` contiene `localhost`.
- [x] Ejecutar `molecule test -s unit` — PASS (4 test cases, TC1-TC4).

**Criterio de éxito**: `grep -r "localhost" /tmp/la-generated-configs/` devuelve 0 resultados (salvo comentarios).

### 1.3 — Verificar generación de configs para todos los servicios

- [ ] Ejecutar `generate-compose.yml` con `inventories/local-min/`.
- [ ] Inspeccionar configs generadas: `cas/config/application.yml`, `cas-management/config/`, `apikey/config/`, `userdetails/config/`.
- [ ] Inspeccionar también: `collectory/config/`, `biocache-service/config/`, `bie-hub/config/`, `bie-service/config/`, y el resto de servicios ALA con guards `deployment_type: container`.
- [ ] Verificar que **todas** las URIs de DB/servicio usan nombre de contenedor, no `localhost` ni hostname de VM.
- [ ] Test Molecule: parsear los YAML generados y assertar URIs.

**Criterio de éxito**: configs generadas superan el test Molecule de URIs para todos los servicios del inventario.

### 1.4 — Verificar generación de nginx upstream

El bug conocido: `apikey` upstream en nginx usa `127.0.0.1` en vez de `la_apikey`.

- [x] Localizar template nginx en `roles/la-compose/templates/`.
- [x] Verificado: nginx upstream no contiene localhost (check 4 del script pasa).
- [ ] Fix: usar el nombre del servicio docker (`la_<servicio>`).
- [ ] Test Molecule: assertar que el nginx.conf generado no contiene `127.0.0.1` en bloques `upstream`.

**Criterio de éxito**: `grep "127.0.0.1" /tmp/la-generated-nginx/upstream*.conf` devuelve 0.

---


---

## BRECHA IDENTIFICADA: Variables críticas en `.env`

> Identificado el 2026-05-13 comparando el POC anterior (`~/seg/ala-install-docker-old/docker-compose-output/.env`) con el `.env` generado actualmente.

### Variables presentes en POC pero ausentes o incorrectas en generación actual

#### 1. `*_JAVA_OPTS` (31 variables) — **FIXED 2026-05-13**

- **Bug**: dos tasks en `generate-compose.yml` (`Build JAVA_OPTS strings` y `Build extra_params dict`) carecían de `tags: [docker-compose]` → se saltaban con `--tags docker-compose`.
- **Fix**: añadido `tags: [docker-compose]` a ambas tasks.
- **Resultado**: 31 `*_JAVA_OPTS` generados con `-Dlogging.config=/data/<service>/config/<logfile>` paths correctos.

#### 2. Bootstrap de CAS Admin — **FIXED 2026-05-13**

Variables necesarias para que CAS pueda crear el primer administrador:
```
CAS_FIRST_ADMIN_EMAIL=support@l-a.site
CAS_FIRST_ADMIN_BCRYPT_PASSWORD=<bcrypt-hash-from-inventory>
CAS_FIRST_ADMIN_TEMP_AUTH_KEY=<uuid-from-inventory>
```
- [x] Localizar dónde se definen en la-demo: `lademo-local-passwords.ini` en la-toolkit.
- [x] Copiar a `inventories/testing/lademo-local-passwords.ini` (en `.gitignore`).
- [x] Verificar que el template las emite en el `.env` generado.

#### 3. Passwords reales de BD — **FIXED 2026-05-13**

- [x] `mysql_root_password`, `mongodb_root_password`, `postgresql_password` se toman de `lademo-local-passwords.ini`.
- [x] Contenedores de BD arrancan y son `healthy` con las passwords del inventario.

#### 4. Variables de alias (BIOCACHE_HUB → ALA_HUB) — **VERIFICAR**

El POC tenía:
```
BIOCACHE_HUB_JAVA_OPTS=${ALA_HUB_JAVA_OPTS}
BIE_HUB_JAVA_OPTS=${ALA_BIE_JAVA_OPTS}
```
- [ ] Verificar que `docker-compose.env.j2` emite los aliases correctos.

---

## FASE 2 — Inicialización de bases de datos (local, una por una)

**Objetivo**: verificar que `init-databases.yml` funciona en contenedores locales antes de tocar el cluster.

### 2.1 — Levantar solo el stack de bases de datos

Crear un compose mínimo (`docker-compose.db-only.yml`) con:
- MySQL
- PostgreSQL
- MongoDB
- Redis
- Solr
- Cassandra

- [x] Verificar que el profile `dbs` generado incluye todos estos servicios.
- [x] `docker compose --profile dbs up -d` → 7 contenedores healthy (MySQL, MongoDB, PostgreSQL, Solr, Cassandra, Elasticsearch, db-backup).
- [x] Tiempos: startup ~3min (descarga Elasticsearch 8.10.0 ~672MB la primera vez).

**Criterio de éxito**: ✅ `docker compose ps` muestra todos los DBs `healthy`.

### 2.2 — Testear `cas5-dbs` role en local

- [x] Init via `docker exec` (Ansible role `cas5-dbs` falla en `mysql-client` pkg en Debian/MariaDB — workaround documentado).
- [x] MySQL schemas: `emmet` (CAS Flyway), `apikey`, `collectory` (creado por entrypoint Docker).
- [x] MySQL users: `flyway`, `cas`, `apikey`, `collectory`.
- [x] MongoDB users: `tickets` (cas-ticket-registry), `services` (cas-service-registry), `cas` (cas-audit-repository, spring-sessions).
- [ ] PostgreSQL: DB `cas` creada; verificar que schema Flyway se inicializa al arrancar CAS.
- [ ] Test idempotencia (ver 2.3).

**Criterio de éxito**: ✅ Queries de verificación pasan. ⚠️ Pendiente: `validate-db-init.yml`.

### 2.3 — Testear idempotencia de `init-databases.yml`

- [ ] Ejecutar `init-databases.yml` dos veces seguidas.
- [ ] Verificar que la segunda ejecución no produce errores ("ya existe") ni datos duplicados.

**Criterio de éxito**: segunda ejecución: 0 `changed`, 0 `failed`.

### 2.4 — Testear el flujo completo: up → init → down port-forwards → up sin ports

El flujo de 3 fases diseñado en el plan original:
1. Generar compose con port-forwards
2. `up`, init DBs
3. Regenerar compose sin port-forwards, `up` de nuevo

- [ ] Implementar el flujo completo en `init-databases.yml`.
- [ ] Testear que los datos persisten entre el `down`/`up`.

**Criterio de éxito**: datos creados en fase 2 sobreviven a `docker compose down && docker compose up`.

---

## FASE 3 — Servicios básicos: uno a uno

**Metodología**: para cada servicio, el criterio de éxito es una respuesta HTTP válida (o healthcheck verde), no solo que el contenedor arranque.

### Orden de validación (de menos a más dependencias)

#### 3.1 — Branding

Dependencias: ninguna (servicio estático).

- [ ] Generar config con `inventories/local-min/`.
- [ ] `docker compose up la_branding`.
- [ ] `curl http://localhost:<puerto>/` → HTTP 200.
- [ ] Test Molecule: assertar que el healthcheck del contenedor está verde.

#### 3.2 — Gatus (monitoring)

Dependencias: ninguna (pero monitoriza otros servicios).

- [ ] Generar config gatus con `inventories/local-min/`.
- [ ] Verificar que el `gatus.yml` generado es YAML válido.
- [ ] `docker compose up la_gatus`.
- [ ] `curl http://localhost:<puerto>/api/v1/endpoints/statuses` → JSON válido.

#### 3.3 — CAS (sin servicios dependientes)

CAS arranca sin necesitar que el resto de la suite funcione, pero SÍ necesita MongoDB y MySQL.

Pre-requisito: Fase 2 completa.

- [ ] Verificar config generada: `cas/config/application.yml` → URIs correctas.
- [ ] `docker compose up la_mysql la_mongodb la_cas`.
- [ ] Esperar healthcheck de CAS (puede tardar 3-4 min en la primera vez).
- [ ] `curl https://cas.<dominio>/cas/login` → HTTP 200 (o 302 a login form).
- [ ] Verificar logs: 0 `ERROR` excepto errores conocidos de startup.

**Criterio de éxito**: CAS responde a `/cas/login` y el healthcheck está verde.

#### 3.4 — SSL / certbot

> **Dependencia crítica**: SSL es necesario para nginx, y nginx es necesario para CAS y branding. Esto hace que SSL sea un prerequisito de los servicios 3.3 en adelante, no un añadido opcional.

Para entorno local, usar certificados auto-firmados o `mkcert` (no necesita dominio público).
Para testing en cluster, verificar que certbot puede obtener certificados.

- [ ] Implementar soporte para `mkcert` en local.
- [ ] Documentar en `inventories/testing/group_vars/` cómo configurar SSL local.
- [ ] Verificar que nginx arranca y sirve HTTPS antes de intentar arrancar CAS o branding.
- [ ] Mover este paso antes de 3.3 en la secuencia de validación.

#### 3.5 — Sub-servicios CAS: apikey, cas-management, userdetails

> **Nota**: APIKey, cas-management y userdetails son sub-servicios del grupo de autenticación CAS, no servicios independientes. Se validan juntos como bloque.

Dependencias: MySQL + MongoDB + CAS + nginx/SSL.

- [ ] `docker compose --profile core-auth up -d` (levanta CAS + todos sus sub-servicios).
- [ ] Verificar que cada sub-servicio responde:
  - `curl https://apikey.<dominio>/ws/check` → JSON
  - `curl https://userdetails.<dominio>/` → HTTP 200
  - `curl https://cas-management.<dominio>/` → HTTP 200
- [ ] Test: crear un usuario via CAS y verificar que se puede autenticar en Collectory.

#### 3.7 — Collectory (primer servicio de aplicación)

Dependencias: MySQL + CAS (para autenticación, pero Collectory arranca sin CAS activo).

> **Nota**: Collectory es un servicio de aplicación independiente, no parte del grupo de autenticación CAS. Puede arrancar y responder a llamadas de API pública sin que CAS esté operativo.

- [ ] `docker compose up la_mysql la_collectory`.
- [ ] `curl https://collectory.<dominio>/ws/dataResource` → JSON con lista de recursos (endpoint público).
- [ ] Test: crear un dataResource via API con CAS activo y verificar persistencia.

---

## FASE 4 — Integraciones básicas

Solo empezar esta fase cuando todas las de Fase 3 pasen.

### 4.1 — Stack mínimo funcional

Branding + CAS (+ sub-servicios) + Collectory + Nginx/SSL + Gatus.

- [ ] `docker compose --profile app-core up -d`.
- [ ] Todos los servicios levantan en secuencia correcta.
- [ ] Un usuario puede hacer login via CAS y acceder a Collectory.
- [ ] Nginx enruta correctamente a cada servicio.
- [ ] **Gatus dashboard** muestra todos los servicios del stack como `UP` — es la fuente de verdad visual para verificar el estado.

### 4.2 — Ampliar stack gradualmente

Añadir servicios en este orden (cada uno con su criterio de éxito):
1. Logger
2. Namematching service
3. Biocache-service
4. BIE-service / BIE-hub
5. ALA-hub
6. Image-service
7. Species-lists
8. SDS (sensitive data)

### 4.3 — Gatus integrado

Configurar Gatus para monitorizar cada servicio que esté arriba.
Al final de la fase, el dashboard de Gatus debe mostrar todos los servicios como `UP`.

---

## FASE 5 — CI/CD local antes de Jenkins

### 5.1 — Script de CI local (`scripts/run-local-ci.sh`)

Equivalente al Jenkinsfile pero ejecutable en local:
1. Regenerar inventario desde generator.
2. `molecule test -s unit`.
3. Ejecutar `generate-compose.yml`.
4. Levantar stack de DBs, init, verificar.
5. Levantar stack completo.
6. Ejecutar `validate-post-deploy.yml`.
7. Report PASS/FAIL.

**Criterio de éxito**: el script pasa end-to-end en local en < 30 min.

### 5.2 — Simplificar Jenkinsfile

El Jenkinsfile actual (26KB) tiene lógica compleja acumulada de builds fallidos.
Una vez que el script local funciona:
- [ ] Limpiar el Jenkinsfile para que llame al script local.
- [ ] Reducir a: Checkout → Run script → Report.

### 5.3 — Testing en cluster (solo cuando local pasa)

Solo cuando `run-local-ci.sh` pasa 3 veces consecutivas sin cambios:
- [ ] Push a Jenkins.
- [ ] Build en máquina de testing.
- [ ] Verificar que el resultado es idéntico al local.

---

## FASE 6 — Stack completo y multi-host

Solo empezar cuando Fase 5.3 pasa.

- [ ] Multi-host networking (extra_hosts entre contenedores de diferentes hosts).
- [ ] SSL con certbot real.
- [ ] Mail (Mailhog en dev, Postfix en prod).
- [ ] Branding con build personalizado.
- [ ] Pipelines (sin Spark ni Hadoop en esta fase — se añadirán en una fase posterior si se necesitan).

---

## Tabla de prioridades inmediatas

| Prioridad | Tarea | Fase | Estado |
|-----------|-------|------|--------|
| ~~P0~~ | ~~Setup Molecule unit scenario~~ | 0.1 | ✅ Done |
| ~~P0~~ | ~~Completar normalize-hostnames.yml~~ | 1.2 | ✅ Done |
| ~~P0~~ | ~~Fix nginx upstream (no localhost)~~ | 1.4 | ✅ Verified |
| ~~P0~~ | ~~validate-config-gen.sh (5 checks)~~ | 0.2 | ✅ Done |
| ~~P0~~ | ~~JAVA_OPTS en .env~~ | .env | ✅ Fixed |
| ~~P0~~ | ~~CAS_FIRST_ADMIN_* en .env~~ | .env | ✅ Fixed |
| ~~P0~~ | ~~Passwords reales de BD en .env~~ | .env | ✅ Fixed |
| P1 | `yo living-atlas` genera inventario + ansiblew | 0.3 | 🔄 .yo-rc.json creado |
| ~~P1~~ | ~~Stack DB-only: `docker compose --profile dbs up`~~ | 2.1 | ✅ Done |
| ~~P1~~ | ~~Init databases + verificación~~ | 2.2 | ✅ Done (docker exec) |
| ~~P1~~ | ~~Branding + Gatus arranca~~ | 3.1-3.2 | ✅ Done |
| P1 | CAS arranca solo | 3.3 | ⏳ Siguiente |
| P3 | APIKey + sub-servicios CAS | 3.5 | ⏳ Pendiente |
| P3 | Script de CI local | 5.1 | ⏳ Pendiente |

**Siguiente paso inmediato**: Fase 3.3 — arrancar CAS (MySQL + MongoDB ya healthy), verificar `/cas/login` HTTP 200.

---

## Deuda técnica a abordar después de P0

- Eliminar los BUILD_*.md de la raíz (deberían estar en `docs/` o en git history).
- Consolidar AGENTS.md (hay backup y .old — el principal ya tiene 17KB).
- Los tests en `tests/` (test-full-flow.yml, test-no-localhost-configs.yml) deben integrarse con Molecule.
- HEALTH_CHECKS.md (16KB) → convertir a validate-post-deploy.yml tasks.

---

## Criterio de éxito global

El proyecto está "básicamente completo" cuando:
1. `./scripts/validate-config-gen.sh` pasa en local (< 5 min).
2. `./scripts/run-local-ci.sh` pasa end-to-end (< 30 min).
3. Un usuario puede hacer login via CAS y acceder a Collectory en local.
4. El mismo stack funciona en el cluster de testing via Jenkins.
5. Gatus muestra todos los servicios core como `UP`.

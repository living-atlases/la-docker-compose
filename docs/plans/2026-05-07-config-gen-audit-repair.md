# la-docker-compose: Config Generation Audit & Repair Plan

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Auditar, reparar y validar localmente la generación de configuración para servicios docker-compose (CAS, cas-management, apikey, userdetails, gatus) antes de volver a probar en hardware real.

**Architecture:** El problema raíz es que `generate-compose.yml` llama roles de ala-install pero las variables `cas_spring_session_host`, `cas_services_host`, `cas_tickets_host`, `cas_audit_host` no se normalizan al nombre de contenedor docker (`la_mongodb`) antes de invocar los roles. Los roles tienen `localhost` como default, por lo que las configs generadas contienen URIs incorrectas. El flujo correcto es: inventario → group_vars con container names → generate-compose.yml normaliza hostnames → roles ala-install generan configs → configs correctas.

**Tech Stack:** Ansible, ala-install roles, Jinja2 templates, docker-compose, inventarios locales (`inventories/local/`), patrón `la-data-generator`.

---

## Resumen de Issues y Sus Fixes

| Issue | Causa | Fix |
|---|---|---|
| `localhost` en mongodb URI de cas-management/apikey/userdetails | `cas_spring_session_host` etc. no normalizados antes de `include_role` | Fase 2 |
| cas-management unhealthy → cascada de fallos en node-1 | Config incorrecta → no conecta MongoDB → health check falla | Fase 2 + 3 |
| APT lock en node-2 (CI) | `killall unattended-upgrades` no mata todos los procesos apt | Fase 5 |
| Sin validación local | No hay forma de probar configs sin hardware real | Fase 3 + 4 |

**Orden de ejecución:** Fase 1 → 2 → 3 → 4 → 5 → push CI

---

## Fase 1: Auditoría — confirmar hipótesis

### Task 1: Identificar todas las variables que llegan como `localhost` a los roles

**Files:**
- Read: `roles/la-compose/tasks/normalize-hostnames.yml`
- Read: `roles/la-compose/tasks/generate-compose.yml`
- Read: `inventories/local/group_vars/docker_compose_hosts.yml`
- Read: `ala-install/ansible/roles/cas-management/defaults/main.yml`
- Read: `ala-install/ansible/roles/userdetails/defaults/main.yml`
- Read: `ala-install/ansible/roles/apikey/defaults/main.yml`

- [ ] **Step 1: Auditar normalize-hostnames.yml**

```bash
cat roles/la-compose/tasks/normalize-hostnames.yml
```

Verificar: además de `cas_spring_session_host`, `cas_services_host`, `cas_tickets_host`, `cas_audit_host`, ¿cubre también las variables equivalentes usadas en los playbooks `*docker.yml` del POC en `ala-install`?

- [ ] **Step 2: Grep en generate-compose.yml**

```bash
grep -n "include_role\|cas_spring_session\|cas_services_host\|cas_tickets\|cas_audit\|mongodb_host\|mongo_uri" \
  roles/la-compose/tasks/generate-compose.yml | head -80
```

¿Hay algún `set_fact` para estas 4 variables antes de `include_role: cas5`, `cas-management`, `apikey`, `userdetails`?

- [ ] **Step 3: Comparar con todos los playbooks `*docker.yml` de ala-install**

```bash
ls /home/vjrj/proyectos/gbif/dev/ala-install/ansible/*docker.yml
grep -n "set_fact\|cas_spring_session_host\|cas_services_host\|cas_tickets_host\|cas_audit_host\|_db_host\|_db_hostname"   /home/vjrj/proyectos/gbif/dev/ala-install/ansible/*docker.yml
```

Listar variables que esos playbooks setean inline para despliegues Docker/Swarm y que `generate-compose.yml` no setea todavía. Aunque Swarm esté deprecado, mantener la misma estrategia de normalización explícita para entorno contenedor.

- [ ] **Step 4: Confirmar defaults en los roles ala-install**

```bash
grep -r "cas_spring_session_host\|cas_services_host\|cas_tickets_host\|cas_audit_host" \
  ala-install/ansible/roles/cas5/defaults/ \
  ala-install/ansible/roles/cas-management/defaults/ \
  ala-install/ansible/roles/userdetails/defaults/ \
  ala-install/ansible/roles/apikey/defaults/
```

Esperado: confirmar que el default es `localhost` o un hostname real de VM.

- [ ] **Step 5: Documentar gaps encontrados**

```bash
# Crear resumen de gaps
cat > /tmp/config-gen-audit.txt << 'EOF'
Variables con default localhost en roles ala-install:
- cas_spring_session_host: [valor default]
- cas_services_host: [valor default]
- cas_tickets_host: [valor default]
- cas_audit_host: [valor default]

¿normalize-hostnames.yml las cubre? [SI/NO]
¿generate-compose.yml las sobreescribe antes de include_role? [SI/NO]
EOF
```

---

## Fase 2: Fix en normalize-hostnames.yml y generate-compose.yml

### Task 2: Normalizar hostnames MongoDB antes de include_role para CAS y derivados

**Files:**
- Modify: `roles/la-compose/tasks/normalize-hostnames.yml`
- Modify: `roles/la-compose/tasks/generate-compose.yml` (si normalize-hostnames.yml no es suficiente)

- [ ] **Step 1: Añadir normalización de MongoDB vars a normalize-hostnames.yml**

Agregar al final de `normalize-hostnames.yml`:

```yaml
# MongoDB connection vars for CAS services
- name: Normalize MongoDB connection vars for CAS services (container mode)
  ansible.builtin.set_fact:
    cas_spring_session_host: >-
      {{ 'la_mongodb' if (deployment_type == 'container' and
         (cas_spring_session_host is undefined or cas_spring_session_host == 'localhost'))
         else cas_spring_session_host | default('localhost') }}
    cas_services_host: >-
      {{ 'la_mongodb' if (deployment_type == 'container' and
         (cas_services_host is undefined or cas_services_host == 'localhost'))
         else cas_services_host | default('localhost') }}
    cas_tickets_host: >-
      {{ 'la_mongodb' if (deployment_type == 'container' and
         (cas_tickets_host is undefined or cas_tickets_host == 'localhost'))
         else cas_tickets_host | default('localhost') }}
    cas_audit_host: >-
      {{ 'la_mongodb' if (deployment_type == 'container' and
         (cas_audit_host is undefined or cas_audit_host == 'localhost'))
         else cas_audit_host | default('localhost') }}
```

- [ ] **Step 2: Verificar que normalize-hostnames.yml se llama antes de cada include_role afectado**

```bash
grep -n "normalize-hostnames\|include_role.*cas5\|include_role.*cas-management\|include_role.*apikey\|include_role.*userdetails" \
  roles/la-compose/tasks/generate-compose.yml
```

Si `normalize-hostnames.yml` se llama una sola vez al principio (antes de todos los roles), el fix de Step 1 es suficiente. Si se llama por servicio, verificar el orden.

- [ ] **Step 3: Sintaxis check**

```bash
ansiblew ansible-playbook -i inventories/local playbooks/generate-compose.yml --syntax-check
```

Esperado: sin errores.

- [ ] **Step 4: Commit**

```bash
git add roles/la-compose/tasks/normalize-hostnames.yml
git commit -m "fix(config-gen): normalize MongoDB container hostnames for CAS services"
```

---

## Fase 3: Validación local — generar configs sin desplegar

### Task 3: Verificar que las configs generadas tienen `la_mongodb`, no `localhost`

**Files:**
- Execute: `ansiblew ansible-playbook` con tags

- [ ] **Step 1: Identificar el tag correcto para solo generación de configs**

```bash
grep -r "tags:" ala-install/ansible/roles/cas5/tasks/ \
  ala-install/ansible/roles/cas-management/tasks/ \
  --include="*.yml" | grep -v "^#" | head -30
```

El tag típico en ala-install es `properties-file`. Confirmar que existe.

- [ ] **Step 2: Generar configs en directorio temporal**

```bash
ansiblew ansible-playbook -i inventories/local \
  playbooks/generate-compose.yml \
  --tags properties-file \
  -e deployment_type=container \
  -e docker_compose_data_dir=/tmp/la-docker-test \
  -v 2>&1 | tail -50
```

(`ansiblew` no se combina con `ansiblew ansible-playbook`: si tu inventario trae `./ansiblew`, ese wrapper ya ejecuta Ansible y recibe el playbook como argumento, p.ej. `./ansiblew --alainstall=/ruta/a/ala-install -i … docker_compose …`. En este repo los ejemplos usan `ansiblew ansible-playbook` desde la raíz, alineado con [AGENTS.md](../../AGENTS.md) y el Jenkinsfile.)

- [ ] **Step 3: Inspeccionar configs generadas**

```bash
grep -r "mongodb://" /tmp/la-docker-test/ 2>/dev/null
grep -r "://localhost" /tmp/la-docker-test/ 2>/dev/null
```

Esperado:
- `grep mongodb://` → muestra URIs con `la_mongodb`
- `grep localhost` → sin resultados

Si aparece `localhost` → volver a Task 2 y corregir.

- [ ] **Step 4: Comparar con configs del servidor real (evidencia del bug)**

```bash
# Las configs malas del servidor real (ejemplo del bug reportado):
# /data/cas-management/config/application.yml → mongodb://...@localhost:27017
# Las nuestras generadas deben tener:
# mongodb://...@la_mongodb:27017

diff <(grep -r "mongodb://" /tmp/la-docker-test/) \
     <(echo "mongodb://services:cas_services_password@la_mongodb:27017/cas-service-registry")
# Solo verificación visual, no diff exacto
```

---

## Fase 4: Script de validación local (herramienta permanente)

### Task 4: Crear script inspirado en la-data-generator

**Files:**
- Create: `scripts/validate-config-gen.sh`

- [ ] **Step 1: Leer la-data-generator como referencia**

```bash
cat /home/vjrj/proyectos/gbif/dev/ala-install/utils/la-data-generator
```

- [ ] **Step 2: Crear script (ansiblew ansible-playbook)**

```bash
cat > scripts/validate-config-gen.sh << 'SCRIPT'
#!/bin/bash
# Genera configs en directorio temporal y valida que no contienen 'localhost'
# Uso: ./scripts/validate-config-gen.sh [inventario] [data_dir]
set -e

INVENTORY="${1:-inventories/local}"
OUTPUT_DIR="${2:-/tmp/la-docker-config-test}"

mkdir -p "$OUTPUT_DIR"

echo "=== Generating configs from $INVENTORY ==="
ansiblew ansible-playbook \
  -i "$INVENTORY" \
  playbooks/generate-compose.yml \
  --tags properties-file \
  -e deployment_type=container \
  -e docker_compose_data_dir="$OUTPUT_DIR" \
  -v

echo ""
echo "=== Checking for localhost in generated configs ==="
BAD=$(grep -r "://localhost" "$OUTPUT_DIR/" 2>/dev/null || true)
if [ -n "$BAD" ]; then
  echo "ERROR: Found localhost references in generated configs:"
  echo "$BAD"
  exit 1
else
  echo "OK: No localhost references found"
fi

echo ""
echo "=== MongoDB URIs found ==="
grep -r "mongodb://" "$OUTPUT_DIR/" 2>/dev/null || echo "(none found)"
SCRIPT
chmod +x scripts/validate-config-gen.sh
```

- [ ] **Step 3: Ejecutar script para validar**

```bash
./scripts/validate-config-gen.sh
```

Esperado: `OK: No localhost references found`

- [ ] **Step 4: Commit**

```bash
git add scripts/validate-config-gen.sh
git commit -m "feat(scripts): add local config generation validator"
```

---

## Fase 5: Test de arranque local con docker-compose

### Task 5: Probar arranque de servicios críticos en local

**Prerequisito:** Docker y docker-compose instalados localmente. Configs generadas en Fase 3/4 son correctas.

- [ ] **Step 1: Generar docker-compose.yml local completo**

```bash
ansiblew ansible-playbook -i inventories/local \
  playbooks/generate-compose.yml \
  -e deployment_type=container \
  -e docker_compose_data_dir=/tmp/la-docker-test \
  -v
```

- [ ] **Step 2: Arrancar infraestructura (MySQL + MongoDB)**

```bash
cd /tmp/la-docker-test
docker compose up -d la_mysql la_mongodb
sleep 30
docker compose ps la_mysql la_mongodb
```

Esperado: ambos en estado `healthy`.

- [ ] **Step 3: Arrancar CAS**

```bash
docker compose up -d la_cas
sleep 30
docker compose logs --tail=30 la_cas | grep -i "error\|started\|ready"
```

Esperado: CAS arranca sin errores de conexión.

- [ ] **Step 4: Arrancar cas-management, apikey, userdetails**

```bash
docker compose up -d la_cas_management la_apikey la_userdetails
sleep 60
docker compose ps la_cas_management la_apikey la_userdetails
```

Esperado: los 3 en estado `healthy` o `running`.

```bash
# Verificar que no hay errores de MongoDB en logs
docker compose logs la_cas_management 2>&1 | grep -i "error\|exception\|localhost\|connect" | head -20
docker compose logs la_apikey 2>&1 | grep -i "error\|exception\|localhost" | head -10
docker compose logs la_userdetails 2>&1 | grep -i "error\|exception\|localhost" | head -10
```

- [ ] **Step 5: Arrancar gatus y verificar health checks**

```bash
docker compose up -d la_gatus
sleep 15
curl -s http://localhost:${GATUS_PORT:-8080}/api/v1/endpoints/statuses | python3 -m json.tool | grep -E '"name"|"status"'
```

Esperado: endpoints con status `HEALTHY` o `UP`.

- [ ] **Step 6: Cleanup local**

```bash
docker compose down --remove-orphans
docker system prune -f
```

---

## Fase 6: Fix APT lock en CI

### Task 6: Resolver APT lock persistente en node-2

**Contexto:** Build #151 falló en node-2 con error `Failed to lock apt: process 1571665 (apt-get) holds lock /var/lib/apt/lists/lock`. La estrategia actual de kill unattended-upgrades no es suficiente cuando hay otros procesos apt activos.

**Files:**
- Modify: `Jenkinsfile` (sección de limpieza apt)

- [ ] **Step 1: Ver bloque actual de gestión apt en Jenkinsfile**

```bash
grep -n "apt\|unattended\|flock\|dpkg\|lock" Jenkinsfile | head -40
```

- [ ] **Step 2: Reemplazar bloque de kill/wait por versión más agresiva**

Reemplazar el bloque actual por:

```bash
# Kill ALL apt/dpkg processes
sudo killall -9 apt apt-get dpkg unattended-upgrades needrestart 2>/dev/null || true
# Remove lock files directly (seguro en CI — no hay operaciones apt legítimas en paralelo)
sudo rm -f /var/lib/dpkg/lock-frontend \
           /var/lib/dpkg/lock \
           /var/cache/apt/archives/lock \
           /var/lib/apt/lists/lock 2>/dev/null || true
# Reparar dpkg si quedó inconsistente
sudo dpkg --configure -a 2>/dev/null || true
sleep 5
# Verificar que el lock está libre
sudo flock --nonblock /var/lib/dpkg/lock-frontend echo "APT lock free" || {
  echo "ERROR: dpkg lock still held after forced cleanup"
  exit 1
}
```

- [ ] **Step 3: Commit y push**

```bash
git add Jenkinsfile
git commit -m "fix(ci): force-clear all apt locks before package install on cluster nodes"
git push origin main
```

---

## Notas sobre estrategia

### Por qué no abandonar los roles de ala-install

Los roles de ala-install hacen trabajo real más allá de generar configs:
- Inicialización de bases de datos
- Configuración de nginx
- Generación de certificados
- Validación de servicios

La estrategia correcta es **usarlos** pero garantizar que reciben las variables correctas para el contexto de contenedor.

### Patrón la-data-generator como modelo

`ala-install/utils/la-data-generator` demuestra que ala-install fue diseñado para separar "generar configs" de "desplegar". El tag `--tags properties-file` permite solo la generación. Deberíamos integrar este patrón en nuestro CI como paso de validación antes del despliegue real.

### Validación local antes de CI

El flujo correcto que falta actualmente:
```
fix código → ./scripts/validate-config-gen.sh → docker compose up local → OK → push → CI
```
Sin este paso intermedio, cada iteración cuesta un build CI completo (~40 min).

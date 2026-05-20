# Scripts: developer workflow

Tres formas de desplegar/iterar en local. Elige según lo que estás cambiando.

## Árbol de decisión rápido

```
¿Qué cambiaste?
├─ Plantilla/inventario/variables ansible ........... → "Watch + full deploy"   (A)
├─ Solo la config/imagen de UN servicio (cas, ...) .. → "iterate-service.sh"    (B)
└─ Quiero un deploy limpio y verificar todo ......... → "ansiblew directo"      (C)
```

> Si dudas, usa **(A) Watch**. Es el modo "siempre seguro" — re-genera todo,
> valida y despliega. Cuesta ~1 minuto.

---

## (A) Watch + full deploy

Modo por defecto. Re-corre `validate-config-gen.sh` + `ansiblew` (toda la
generación de config + DB init + `docker compose up`) en cada cambio detectado
de `roles/`, `playbooks/`, `inventories/testing/`, `ala-install/ansible/roles/`,
`molecule/` o el propio script.

```bash
scripts/watch-and-test.sh
```

**Controles (interactivos)**:
- `Enter` o `r` → re-ejecutar manualmente.
- `q` → salir.

**Logs**:
- `/tmp/la-docker-watch.log` — rolling, todas las ejecuciones.
- `/tmp/la-docker-watch-last.log` — solo la última.

**Al fallar el deploy**, el `block/rescue` en
`roles/la-compose/tasks/main.yml` ahora deja:
- `/tmp/la-docker-deploy-failure.log` — dump completo (`docker compose ps`,
  estado y `docker logs --tail 100` de cada contenedor no-`healthy`).
- `/tmp/la-docker-deploy-failure.root.log` — primera línea de causa raíz por
  contenedor (`Caused by:`, `FATAL`, `Access denied`, etc.).

El watch imprime el `root.log` en pantalla y en la notificación. **No
comitear ningún `fix(...)` sin haber leído este fichero antes**.

---

## (B) Fast iterate sobre UN servicio

Cuando estás depurando un único servicio (p.ej. CAS) y no quieres pagar las
~924 tareas de ansible por ciclo. Asume que `docker-compose.yml` ya está
generado.

```bash
scripts/iterate-service.sh <servicio>          # one-shot, recreate + health
scripts/iterate-service.sh cas --follow        # + tail de logs hasta ctrl-C
scripts/iterate-service.sh cas --timeout 180   # subir timeout
scripts/iterate-service.sh cas --no-recreate   # solo poll health (sin tocar)
```

Termina con veredicto binario **GREEN/RED**, y en RED extrae la primera línea
canónica del log del contenedor (`Caused by:`, `Access denied`, etc.).

### Modo `SERVICE=` integrado en el watch

```bash
SERVICE=cas scripts/watch-and-test.sh
```

Igual que (A) pero, en cada disparo, llama a `iterate-service.sh cas` en vez de
`validate-config-gen.sh + ansiblew`. Útil si quieres reaccionar a cambios en
templates de un único servicio sin re-correr la pipeline entera.

---

## (C) `ansiblew` directo

Si quieres un deploy explícito sin watch (p.ej. para confirmar verde después
de un fix puntual, o para correr solo unas tags):

```bash
cd inventories/testing/lademo-inventories
ANSIBLE_CONFIG=../../../playbooks/ansible.cfg \
./ansiblew \
    --alainstall=/dev/null \
    --ladocker=$(pwd)/../../.. \
    --nodryrun \
    --docker-local \
    --skip=docker \
    --extra="auto_deploy=true" \
    all
```

**Tags útiles para deploys parciales** (`--extra="auto_deploy=true" --tags ...`):
- `docker-compose` — generar/desplegar todo el stack.
- `deploy` — solo la fase de `docker compose up` (asume compose ya generado).
- `db-init` — solo inicialización de bases de datos.
- `db-password-sync` — solo re-sincronizar contraseñas de usuarios MySQL CAS
  (idempotente, útil tras rotar contraseñas en el inventario).
- `docker-volumes` — solo crear volúmenes externos.
- `validate` / `pre-deploy` / `post-deploy` — validaciones.

---

## Contexto docker (importante)

El deploy ansible usa `become: true` → habla con el daemon docker del sistema
(`/var/run/docker.sock`). Asegúrate de que tu CLI sin sudo también apunta
ahí:

```bash
docker context show          # debe ser 'default'
groups | grep docker         # debe incluir 'docker' (logout/login tras
                             #   `sudo usermod -aG docker $USER`)
echo "${DOCKER_HOST:-unset}" # debe ser 'unset'
```

Si tienes Docker Desktop, párvalo (`systemctl --user stop docker-desktop`) o
al menos no lo uses como contexto activo — la divergencia de contextos
docker hace que `docker ps` (user) y `sudo docker ps` muestren stacks
distintos y el debugging se vuelve incomprensible.

---

## Diagnóstico cuando algo falla

1. `cat /tmp/la-docker-deploy-failure.root.log` — primera línea de causa raíz
   por contenedor no-healthy.
2. `less /tmp/la-docker-deploy-failure.log` — dump completo (estado + logs).
3. `scripts/diagnose-failure.sh --service <name>` — colección detallada en
   `/tmp/la-diagnose/<service>-report.txt` (inspect, env, volúmenes, red).
4. `scripts/wait-for-health.sh --service <name> --verbose` — polling con
   diagnóstico al fallar.
5. Para problemas de contraseña MySQL:
   ```bash
   sudo docker exec la_mysql mysql -u<user> -p"<pwd from inventory>" -e "SELECT 1"
   ```
   Si "Access denied" pese a credenciales del inventario: re-sincroniza con
   `ansiblew --tags db-password-sync ...`.

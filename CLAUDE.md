# CLAUDE.md — la-docker-compose

## ⚠️🔥 REGLA ABSOLUTA: NUNCA COMANDOS MANUALES 🔥⚠️

> **TODO cambio al entorno Docker debe hacerse vía Ansible (ansiblew), NO manualmente.**
>
> - ❌ `docker compose up <servicio>` — PROHIBIDO como fix
> - ❌ `docker exec mysql mysql -e "CREATE USER..."` — PROHIBIDO
> - ❌ Editar ficheros en `/home/vjrj/la-docker-run/` directamente — PROHIBIDO
> - ❌ `sed -i` en confs nginx generadas — PROHIBIDO
>
> ✅ **Lo correcto**: si algo no funciona, el fix va en un role/task/template Ansible,
>    se regenera con `ansiblew`, y se verifica que el cambio es idempotente.
>
> **Razón**: los ficheros en `la-docker-run/` son artefactos generados. Editarlos
> directamente los desincroniza del source-of-truth (Ansible). La próxima ejecución
> de `ansiblew` sobrescribirá el fix manual y el problema volverá.

### Cómo hacer cambios correctamente

```
1. Identificar el role/template que genera el artefacto roto
2. Editar el source en ala-install/ansible/roles/... o roles/la-compose/...
3. Regenerar: cd inventories/testing/lademo-inventories && ./ansiblew --ladocker=... --nodryrun all
4. Verificar que el artefacto generado contiene el fix
5. Commit del source, NO del artefacto
```

### Excepción única permitida

Solo se permite editar `la-docker-run/` TEMPORALMENTE para diagnosticar el root cause
(encontrar cuál template/role hay que tocar), pero NUNCA como fix final.

---

## Stack y contexto

- **Proyecto**: la-docker-compose — Living Atlas en Docker Compose
- **Source Ansible**: `ala-install/ansible/` (upstream ALA, cambios mínimos)
- **Templates Docker**: `roles/la-compose/templates/`
- **Inventario de test**: `inventories/testing/lademo-inventories/`
- **Runtime**: `/home/vjrj/la-docker-run/` — artefactos generados, NO editar directamente
- **Regla VMs**: los cambios en ala-install NO deben romper despliegues en VMs

## Flujo de trabajo

```bash
# Generar configs
cd inventories/testing/lademo-inventories
./ansiblew --alainstall=/dev/null --ladocker=<repo> --nodryrun --docker-local \
  --tags=docker-compose --skip=docker all

# Levantar servicios (siempre via compose generado)
cd /home/vjrj/la-docker-run
docker compose --profile <profile> up -d

# Validar
cd <repo> && scripts/validate-config-gen.sh
```

## Plan activo

Ver `docs/plans/2026-05-12-master-plan.md`

# Build #137 Failure — Root Cause Analysis and Fix

**Date**: 2026-04-25  
**Build**: [#137](https://jenkins.gbif.es/job/la-docker-compose-tests/137/)  
**Status**: FAILURE → Fixed in commit `e7af586`, verified by build #138  

---

## Summary

Two independent failures on cold-start (`CLEAN_MACHINE=true`):

1. **Cluster-1**: `docker compose up` exits rc=1 because `la_cas-management`, `la_apikey`, and `la_userdetails` fail their healthchecks before becoming healthy — caused by insufficient `start_period` values.
2. **Cluster-2/3**: `wait-for-health.sh` times out at 300s because `mailhog` has an image-defined healthcheck that never transitions to `healthy`.

---

## Failure 1: CAS-Dependent Services Healthcheck Timeout

### Symptom

```
Error response from daemon: No such container: ...
docker compose up exited with rc=1
```

`la_cas-management`, `la_apikey`, `la_userdetails` containers fail healthcheck during cold start.

### Root Cause

Docker `start_period` is the grace window before failed healthchecks count as failures.  
On a clean machine, CAS itself needs up to `start_period: 180s` to boot.

Services that **depend on `cas: condition: service_healthy`** only start their own boot  
*after* CAS is healthy. Their `start_period` clock starts at container creation, not  
after the dependency is satisfied — so the window was already partially or fully  
consumed by the time their Spring app actually began initializing.

| Service | Old start_period | New start_period | Depends on |
|---|---|---|---|
| cas-management | 90s | 180s | cas: service_healthy |
| apikey | 60s | 120s | cas: service_healthy |
| userdetails | 60s | 120s | cas: service_healthy |

### Fix

`roles/la-compose/templates/docker-compose/services/cas-management.yml.j2` — 90s → 180s  
`roles/la-compose/templates/docker-compose/services/apikey.yml.j2` — 60s → 120s  
`roles/la-compose/templates/docker-compose/services/userdetails.yml.j2` — 60s → 120s  

---

## Failure 2: mailhog Blocks wait-for-health.sh

### Symptom

```
[WARN] mailhog - STARTING/INITIALIZING
[ERROR] Timeout reached after 301s
Summary: Healthy: 5 | Starting: 1 | Unhealthy: 0 | Unknown: 0
```

`wait-for-health.sh` exits rc=1 after 300s with mailhog stuck in STARTING.

### Root Cause

The `mailhog/mailhog:latest` Docker image defines its own `HEALTHCHECK` in its  
Dockerfile. Our template comment said "healthcheck disabled — minimal Go binary  
without shell tools", but no explicit override was set.

Docker inherits the image's HEALTHCHECK, which apparently never passes (likely  
tries to reach a port that isn't responding as expected, or the image's check  
command isn't available in the container). `wait-for-health.sh` correctly reads  
`State.Health.Status == "starting"` and waits — but it never transitions to `healthy`.

### Fix

`roles/la-compose/templates/docker-compose/infrastructure/mailhog.yml.j2`:

```yaml
healthcheck:
  disable: true
```

This overrides the image-defined HEALTHCHECK. Since `wait-for-health.sh` falls  
back to checking `State.Running == true` when no healthcheck is defined (status  
returns `"none"`), mailhog will be treated as healthy-when-running, which is  
correct for a dev-only mail catcher.

---

## Commit

```
e7af586  fix(healthcheck): increase start_period for CAS-dependent services; disable mailhog healthcheck
```

4 files changed:
- `infrastructure/mailhog.yml.j2` — disable healthcheck
- `services/cas-management.yml.j2` — 90s → 180s
- `services/apikey.yml.j2` — 60s → 120s
- `services/userdetails.yml.j2` — 60s → 120s

---

## Pattern: CAS-Dependent Service start_period Rule

Any service with `depends_on: cas: condition: service_healthy` should have:

```
start_period >= (cas start_period) - (cas typical boot time after healthy)
             + (own Spring app boot time)
```

In practice: CAS takes ~180s. Services depending on it need at least 120s of their  
own `start_period` to cover their Spring initialization after CAS is up.

Services **not** yet audited for this (may need bumping if they also depend on CAS):
- `collectory.yml.j2` — start_period: 60s
- `species-list.yml.j2` — start_period: 60s
- `bie-hub.yml.j2`, `biocache-hub.yml.j2` — check if CAS-dependent

---

## wait-for-health.sh Behavior Reference

Script: `scripts/wait-for-health.sh`

| `State.Health.Status` | Script return | wait-for-health behavior |
|---|---|---|
| `healthy` | 0 | counts as done |
| `starting` | 2 | keeps waiting |
| `unhealthy` | 1 | logs error, keeps waiting |
| `none` | checks `State.Running` | if true → done (no healthcheck) |

**Implication**: any service with an image-defined healthcheck that takes longer  
than `--timeout` (default 300s) will block the script indefinitely. Always add  
`healthcheck: disable: true` for services where health is not critical or where  
the image healthcheck is unreliable.

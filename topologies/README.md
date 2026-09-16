# Topologies — alternative service→host layouts

The repo has historically been deployed with ONE fixed layout (3 VMs, same
service split). Everything placement-dependent (co-location gates,
`[svc:vars]` scoping, `service_aliases`, cross-host `extra_hosts`, published
datastore ports) is exactly the class of bugs that only shows up when the
layout changes — this directory exists to exercise other layouts, both
offline (Level 1) and with real deploys (Level 2).

## Files

| File | What |
|---|---|
| `base.lademo.yo-rc.json` | Sanitized copy of the CI's la-toolkit `.yo-rc.json` (hosts renamed to `la-mh-*`, IPs to `10.77.0.*`, secrets replaced). The base every fixture derives from. |
| `<variant>.placement.json` | Small declarative overlay: host slots + service→slot map + optional per-data-hub front-end placement + runtime `skip_services` for reduced variants. |
| `../inventories/testing/topologies/<variant>/` | COMMITTED generated fixture (`.yo-rc.json`, `lademo-inventories/lademo-inventory.ini` and one `<pkg>-inventories/<pkg>-inventory.ini` per data hub) for each variant. |

Variants: `default-3host` (control — the current CI split; the matrix must
always pass it), `3host-alt` (same 3 hosts, deliberately shuffled split),
`2host` (auth+apps / datastores, heavy services skipped), `hub-split`
(control portal layout, but a data hub spread across two hosts where the
portal runs no front-end), `1host`
(all-in-one, aggressive skips), `shared-hostname-2host` / `shared-hostname-3host`
(portal's `ala_hub`/`ala_bie`/`regions` front-ends point at ONE shared
hostname on different paths, each placed on a different host — the
Austria/Tanzania-style layout from `ala-install#256`; exercises the
cross-host stub-proxy split described below).

### Cross-host path-split vhosts (`shared_hostname` / `shared_vhost_splits`)

A placement may point more than one service (or a data hub's front-ends) at
the SAME public hostname on different paths, and place the owners on
different hosts — e.g. `portal-shared.l-a.site/records` on host1,
`/species` and `/regions` on host2. Declare it with:

```json
"shared_hostname": {
  "<hostname>": {"<service>": "<path>", ...}
},
"shared_vhost_splits": ["<hostname>"]
```

`shared_hostname` rewrites each listed service's `LA_<svc>_url`/`_path`
(and turns off `_uses_subdomain`) before alias computation; `shared_vhost_splits`
opts the hostname out of `apply-topology.py`'s normal "one alias, one host"
`die()` (also auto-added for every `shared_hostname` key). At runtime, each
host that owns part of a split hostname proxies the paths it doesn't own to
the sibling that does, over a plain-HTTP container-to-container hop
(`roles/la-compose/tasks/register-shared-vhost-stubs.yml`, fed by the
`nginx_shared_vhost_topology` fact in `setup-hub-facts.yml`) — no
`ala-install` changes, no TLS/SNI. `validate-topology.yml` check #2 only
allows a duplicate alias through when this stub-proxy mechanism actually
covers it (i.e. it appears in `nginx_shared_vhost_topology` with owners on
more than one host); an undeclared duplicate elsewhere still fails.

### Known blind spot: one host per service

`<variant>.placement.json` maps each service to exactly ONE slot, because the
generator models placement as a single `LA_<service>_hostname`. Production does
not always match: gbif-es runs `namematching-service` on all three docker hosts.
Anything that behaves differently when a service spans several hosts is
therefore invisible to this matrix. It bit us once — the nameindex was installed
with `run_once`, so only the first host of the play got the 2 GB Lucene index
and the other two crash-looped with `FileNotFoundException:
/data/lucene/namematching-nm/cb` while every CI variant stayed green.

Until a variant can place a service on several slots, that class of bug is
covered statically by `scripts/check-per-host-artifacts.sh` (run in the "Unit
tests" stage), not by a deploy.

The generator does NOT derive `LA_docker_extra_hosts_by_host` /
`LA_nginx_docker_internal_aliases_by_host` / `LA_etc_hosts` from the
per-service hostnames on `--replay` (they are opaque la-toolkit variables) —
`scripts/apply-topology.py` recomputes them coherently from the placement.
Its derivation reproduces the real CI dicts exactly for the control variant.

## Level 1 — offline matrix (every CI build, no VMs)

```bash
scripts/test-topologies.sh              # all variants; or: scripts/test-topologies.sh 2host
```

Per variant: fixture freshness (placement vs committed fixture), the
scope-leak check (`molecule/multihost/converge.yml` — no inter-service var
resolving to localhost), and topology invariants
(`playbooks/validate-topology.yml` — no orphan service groups, no public
vhost served from two hosts, apps placed on exactly one host, private IPs
present). Runs in seconds, no docker/node/real hosts. CI runs it in the
"Topology matrix" stage on every build.

A second check runs alongside it, `scripts/test-hub-baseline.sh`: it computes the
portal's group-derived facts from the portal inventory alone and again with the data
hub inventories added, and requires them to be identical. A hub joins the portal's
canonical service groups through `[<group>:children]`, so without this a hub alias
reads as "the portal runs this service here" and quietly adds a container, a vhost or
a re-pointed variable on a host where the portal never placed the service.

The single-host FULL-RENDER path is covered separately by
`scripts/validate-config-gen.sh` (against `inventories/testing/lademo-inventories`);
a full multi-host render cannot run without the target hosts (see the header
of `molecule/multihost/converge.yml`).

### Editing / adding a variant

1. Create/edit `topologies/<name>.placement.json` (slots are mapped by ORDER
   to the base host list; sub-services follow their parent; services sharing
   a public vhost must share a host — `apply-topology.py` enforces both).
2. Regenerate + commit the fixture (needs `npm i -g yo generator-living-atlas`):
   ```bash
   scripts/regen-topology-fixtures.sh <name>
   ```
3. `scripts/test-topologies.sh <name>` must pass. A stale fixture fails the
   matrix with a "run regen" message.

### Data hubs in a topology

A data hub (`LA_hubs`) is placed per front-end, so it may be SPREAD across hosts:
records on one, species and regions on another. Each front-end follows the PORTAL's
slot for the same service unless the placement says otherwise:

```json
"hubs": { "lademohub": { "ala_hub": "host2", "branding": "host2", "ala_bie": "host3" } }
```

Front-end keys are `ala_hub`, `ala_bie`, `regions` and `branding`; a hub only carries
the ones it declares. Their public vhosts join the per-host alias list and the
cross-host `extra_hosts` map, so a hub is visible to nginx and to the duplicate-vhost
invariant like any other service.

The portal inventory declares the `[hub-<pkg>]` groups EMPTY on purpose, so a hub's
placement lives only in its own `<pkg>-inventories/<pkg>-inventory.ini`. The fixtures
keep those files and the checks pass them alongside the portal's, exactly as the hub's
own `ansiblew` does. `hub-split` is the variant that puts a hub where the portal runs
no front-end at all.

To refresh `base.lademo.yo-rc.json` after la-toolkit config changes:
```bash
python3 scripts/apply-topology.py sanitize \
  --base /data/la-toolkit/config/lademo/.yo-rc.json \
  --out topologies/base.lademo.yo-rc.json
scripts/regen-topology-fixtures.sh
```

## Level 2 — real deploy on the CI VMs (manual builds only)

The Jenkins `TOPOLOGY` parameter (`default` | `3host-alt` | `2host` | `1host`)
deploys a variant on the CI cluster. SCM-triggered builds refuse non-default
topologies; a plain push always deploys the default layout.

What a non-default build does:

- Backs up the agent's la-toolkit `.yo-rc.json` once
  (`.yo-rc.json.la-toolkit-base`) and derives the variant `.yo-rc` from that
  pristine base on every run (repeated alt builds never compound).
- Trims `TARGET_HOSTS` to the variant's host count (`2host` → VMs 1-2,
  `1host` → VM 1). **Unused VMs are neither cleaned nor deployed to** — the
  previous stack keeps running there, out of the request path. Wipe one
  manually with an `ONLY_CLEAN` build + job-level `TARGET_HOSTS` override if
  needed.
- Merges the variant's `skip_services` with the `SKIP_SERVICES` parameter.
- Runs the same verification layers (Gatus gate + Cypress) against the
  trimmed host set.

The next `TOPOLOGY=default` build restores the la-toolkit `.yo-rc` from the
backup and deletes it. **Only re-sync the `.yo-rc` from la-toolkit while the
cluster is on the default topology** (no backup file present on the agent),
or the restore will clobber your sync.

### Front proxy (external Apache, ansible-extras)

Public subdomains are routed per-VM by the external Apache proxy, so each
variant needs its routing applied BEFORE the build and reverted when going
back to default. The build log prints the map; you can also generate it
locally:

```bash
python3 scripts/apply-topology.py proxy-map \
  --base topologies/base.lademo.yo-rc.json \
  --placement topologies/3host-alt.placement.json
```

(la-mh-N/10.77.0.N correspond 1:1, in order, to the real CI VMs/IPs.)

### Recommended test order

1. `TOPOLOGY=3host-alt` — same VM count, only the split changes (highest
   signal, lowest risk).
2. `TOPOLOGY=2host`
3. `TOPOLOGY=1host`
4. `TOPOLOGY=default` — restore and confirm the normal path is intact.

### Known reduced-variant caveats

- `2host`/`1host` skip heavy services (spatial stack, pipelines/spark/hadoop,
  doi, data-quality, sds, regions…) via `skip_services`; Cypress specs for
  skipped services will fail until the suite learns to skip absent services —
  keep e2e report-only (`E2E_BLOCKING=false`) on reduced variants.
- Airflow is deployed by the pipelines overlay and is not a
  `skip_services`-able group; on reduced variants it is placed but its
  ingestion has nothing to feed (pipelines skipped). Leave
  `RUN_AIRFLOW_INGEST=false` for `2host`/`1host`.

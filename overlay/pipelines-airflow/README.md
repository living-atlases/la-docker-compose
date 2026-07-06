# pipelines-airflow NO-AWS overlay

Run the **unmodified** pipelines-airflow DAGs against the local `la_pipelines`
container of [la-docker-compose](https://github.com/living-atlases/la-docker-compose),
with **zero changes to the pipelines-airflow repo** (least impact on ALA).

## How it works (3 pieces, all validated in the spike)

1. **Storage → MinIO, no code change.** boto3 honours `AWS_ENDPOINT_URL_S3`, so the
   DAGs' `boto3.client/resource("s3")` calls hit MinIO. (Spike E1: PASS.)
2. **Compute → local shims, no DAG edits.** [`sitecustomize.py`](sitecustomize.py) runs at
   interpreter startup and swaps the 4 EMR operator/sensor classes
   (`EmrCreateJobFlowOperator`, `EmrAddStepsOperator`, `EmrStepSensor`,
   `EmrJobFlowSensor`) for local shims. The shims read the standard EMR step dicts the
   DAGs build: `s3-dist-cp` copies become no-ops (data on the shared volume);
   `command-runner` bash steps run with `--cluster`→`--embedded` inside `la_pipelines`
   (`--embedded` is the one local Spark mode every stage accepts; `--local` is rejected
   by uuid/image-sync/sample/solr/…).
   This covers BOTH the 12 DAGs that call `run_large_emr` and the 5 that inline the EMR
   operators. (Spike E2: PASS — mechanism + translation.)
3. **Config → seeded Variables.** The committed `ala_config.py` is AWS-hardcoded and reads
   ~40 Variables at import. [`variables/airflow-variables.local.json`](variables/airflow-variables.local.json)
   provides real LA service URLs + harmless EMR/EC2/S3 dummies (the shims ignore the dummies).

## Usage

```bash
export PIPELINES_AIRFLOW_REPO=/path/to/pipelines-airflow
export LA_NETWORK=<la-docker-compose network name>   # e.g. la
# merge with the la-docker-compose stack (so DAGs resolve solr/collectory/... by hostname):
docker compose -f /data/docker-compose/docker-compose.yml \
               -f overlay/compose/docker-compose.airflow.yml up -d
# Airflow UI: http://localhost:8088  (user "admin"; password = $AIRFLOW_ADMIN_PASSWORD, default "admin")
```

Execution target: by default the shim does `docker exec la_pipelines bash -lc "<cmd>"`
(needs the mounted docker socket). Alternatively set `PIPELINES_LOCAL_BIN=1` and give the
Airflow worker the la-pipelines volume + binary to run without the socket.

## Admin password & rotation

The admin user is created by [`compose/seed.sh`](compose/seed.sh) with
`airflow users create --username admin --password "${AIRFLOW_ADMIN_PASSWORD:-admin}" ... || true`.

- **Where the password comes from.** Deployed as part of la-docker-compose with
  `use_airflow: true`, Ansible passes `AIRFLOW_ADMIN_PASSWORD` from the inventory variable
  `airflow_admin_password` — a random passphrase written to `<project>-local-passwords.ini`
  (`[all:vars]`) by generator-living-atlas ≥ 1.8.28. It reaches the overlay both via the
  launch task's `environment:` and via the stack `.env` (`COMPOSE_ENV_FILES`). Run
  standalone, it falls back to `admin` unless you `export AIRFLOW_ADMIN_PASSWORD` yourself.
- **Idempotency caveat — changing the value does NOT rotate an existing user.** `seed.sh`
  runs only at `airflow-init` time and ends in `|| true`. On a redeploy the init container
  is recreated (its env changed) and `seed.sh` re-runs, but `airflow users create` fails on
  the already-existing `admin` and `|| true` swallows it, so the password stays as first
  seeded.

To actually rotate the password:

```bash
# surgical: delete + recreate the admin with the new password (after regenerating .env)
docker exec la_airflow airflow users delete -u admin
docker exec la_airflow airflow users create --username admin \
  --password "$AIRFLOW_ADMIN_PASSWORD" --firstname a --lastname a \
  --role Admin --email admin@example.org

# or clean-slate: wipe the overlay's metadata DB so seed.sh reseeds admin
#   (WARNING: -v also drops MinIO buckets + Airflow run history for the overlay)
docker compose -f docker-compose.airflow.yml down -v
docker compose -f docker-compose.airflow.yml up -d
```

## Prerequisite in la-docker-compose (not part of this overlay)

The `la_pipelines` container config (`la-pipelines-local.yaml`) currently points at
`hdfs://...` but no Hadoop is deployed. Switch those paths to `file:///data/...` (or create
the referenced `la-pipelines-docker.yaml.j2`) and tune JVM heap (the container OOMs / Exit
137). This is the open item for the E4 end-to-end run.

## Where this lives & how it stays maintainable

Host this overlay **inside la-docker-compose** (it is deployment glue and is meaningless
without that stack); consume pipelines-airflow as a checkout/submodule pinned to a SHA. A
separate repo is only worth it with ≥2 independent consumers. The runtime shim
(`sitecustomize.py` + `pa_local_compute.py`) is kept Airflow-free and self-contained so it
*could* be extracted later if that day comes.

An overlay couples to upstream internals, so it needs a tripwire. **Run the contract test on
every bump of the pinned pipelines-airflow** — it turns silent drift into a loud failure:

```bash
# static (no Airflow needed) — var sync + translation rules + class swap:
PIPELINES_AIRFLOW_REPO=/path/to/pipelines-airflow python3 tests/test_contract_static.py
# DAG-level (inside the running Airflow container) — no real EMR operator survives:
tests/run-in-airflow.sh
```

(The static test already caught one missing Variable — `spark_submit_args` — that a
line-based grep had missed.)

## Ingestion e2e (real single-dataset ingest → Solr)

`scripts/e2e-airflow-ingest.sh` (in the la-docker-compose repo root) ingests a tiny
fixed DwCA (`e2e/fixtures/dr-test/`, 8 records) through the **real** pipeline and
asserts the records reach Solr + biocache-service. Run it on the host where the
stack lives (all access is `docker exec`, no REST API):

```bash
# on the stack host (or: ssh <host> ... bash /tmp/e2e-airflow-ingest.sh):
DR_UID=dr-e2e-test scripts/e2e-airflow-ingest.sh --report-only
```

Design notes:
- Triggers **`Ingest_small_datasets` directly with `run_indexing=true`** — the only
  single-dataset path that reaches Solr (`Load_dataset` triggers ingest with
  `run_indexing=false`, so it never indexes).
- The archive is seeded straight into `la_pipelines` at
  `{{dwca_import_dir}}/<dr>/<dr>.zip` (where `dwca-avro` reads it); the S3-copy
  bootstrap step is a no-op in the overlay. `--seed-minio` also pushes it to MinIO.
- **SDS is optional**: the run passes `pipelines_skip_stages: "sds"` in the DAG conf;
  `sitecustomize` reads it (conf > Airflow Variable `pipelines_skip_stages` > env
  `PIPELINES_SKIP_STAGES`) and no-ops the `sds` stage — so sensitive-data-service
  need not be deployed. Add more stages to skip the same way (comma-separated).
- In CI: param `RUN_AIRFLOW_INGEST=true` runs the `Airflow Ingest E2E` Jenkins stage
  against the already-running stack (independent of redeploy).

## Notifications (generic, provider-agnostic)

`airflow_local_settings.py` (auto-loaded by Airflow from the overlay's PYTHONPATH)
attaches notifications to every DAG/task via cluster policies — **no DAG changes**,
mirroring ALA (per-task failure + per-DAG-run success). Provider is auto-detected
from credentials placed in `.env-custom` (never committed):

```bash
# .env-custom (Telegram wins over Slack; unset + no creds => silent no-op)
NOTIFICATIONS_ENABLED=true
TELEGRAM_BOT_TOKEN=123:abc
TELEGRAM_CHAT_ID=-100123
# or: SLACK_WEBHOOK_URL=https://hooks.slack.com/services/...
PIPELINES_ENV_LABEL=lademo      # optional prefix in the message
```

The DAGs' own Slack path stays off (`SLACK_NOTIFICATION=false`); this overlay layer
handles everything generically.

## Files
- `sitecustomize.py` — bootstrap: swaps the 4 EMR classes for local shims.
- `airflow_local_settings.py` — cluster policy: generic Telegram/Slack notifications.
- `pa_local_compute.py` — Airflow-free step translation (s3-dist-cp→no-op; `--cluster`→`--embedded`; `PIPELINES_SKIP_STAGES` stage no-op).
- `variables/airflow-variables.local.json` — 75 Variables mapped to committed `ala_config` names.
- `compose/Dockerfile.airflow` — Airflow image + providers + docker CLI.
- `compose/docker-compose.airflow.yml` — Airflow (+MinIO) services for la-docker-compose.
- `compose/seed.sh` — init: DB, Variables, dummy connections, MinIO buckets.
- `tests/` — contract tests (static + DAG-level) and the in-container runner.

See `./SPIKE_RESULTS.md` for the evidence and the overlay-vs-PR rationale, and `./HANDOFF.md`
for the E4 integration brief.

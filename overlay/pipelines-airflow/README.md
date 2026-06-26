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
# Airflow UI: http://localhost:8088  (admin/admin)
```

Execution target: by default the shim does `docker exec la_pipelines bash -lc "<cmd>"`
(needs the mounted docker socket). Alternatively set `PIPELINES_LOCAL_BIN=1` and give the
Airflow worker the la-pipelines volume + binary to run without the socket.

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

## Files
- `sitecustomize.py` — bootstrap: swaps the 4 EMR classes for local shims.
- `pa_local_compute.py` — Airflow-free step translation (s3-dist-cp→no-op; `--cluster`→`--embedded`).
- `variables/airflow-variables.local.json` — 75 Variables mapped to committed `ala_config` names.
- `compose/Dockerfile.airflow` — Airflow image + providers + docker CLI.
- `compose/docker-compose.airflow.yml` — Airflow (+MinIO) services for la-docker-compose.
- `compose/seed.sh` — init: DB, Variables, dummy connections, MinIO buckets.
- `tests/` — contract tests (static + DAG-level) and the in-container runner.

See `./SPIKE_RESULTS.md` for the evidence and the overlay-vs-PR rationale, and `./HANDOFF.md`
for the E4 integration brief.

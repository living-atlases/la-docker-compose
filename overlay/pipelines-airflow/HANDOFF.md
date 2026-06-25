# Handoff — pipelines-airflow NO-AWS overlay (phase E4)

Goal: run the **unmodified** Apache Airflow DAGs from the `pipelines-airflow` repo
(AWS/EMR orchestration of the ALA/GBIF pipelines) **without AWS**, for the generic Living
Atlas community, reusing this repo's `la_pipelines` container. Decision is locked:
**overlay hosted here, zero changes to pipelines-airflow** (least impact on ALA). A spike
already proved viability; phase **E4** is the real end-to-end integration.

## Read first (all under `overlay/pipelines-airflow/`)
- `SPIKE_RESULTS.md` — evidence + the overlay-vs-PR decision.
- `README.md` — how the overlay works + maintainability/contract test.

## What already exists (don't rewrite — integrate)
- `overlay/pipelines-airflow/sitecustomize.py` — swaps the 4 EMR operator/sensor classes
  for local shims at interpreter startup (activated by `PIPELINES_COMPUTE_BACKEND=local`).
  Covers the 12 DAGs using `run_large_emr` AND the 5 that inline EMR operators.
- `overlay/pipelines-airflow/pa_local_compute.py` — Airflow-free step translation
  (`s3-dist-cp`→no-op; `command-runner` `--cluster`→`--local`).
- `overlay/pipelines-airflow/variables/airflow-variables.local.json` — 75 Airflow Variables
  matching the COMMITTED `dags/ala/ala_config.py` (service URLs + harmless EMR dummies).
- `overlay/pipelines-airflow/compose/` — `Dockerfile.airflow`, `docker-compose.airflow.yml`,
  `seed.sh` (DB + Variables + dummy connections + MinIO buckets).
- `overlay/pipelines-airflow/tests/` — contract tests (static PASSES today; DAG-level runs
  inside the container) — the tripwire against overlay drift.

## Verified facts
- Storage without code change: boto3 honours `AWS_ENDPOINT_URL_S3` → MinIO (E1 PASS).
- EMR-step→local translation + the `sitecustomize` swap timing (E2 PASS).
- `pipelines-airflow` is at `develop` (clean). `la-pipelines` already runs `--local`.
- Reference for local stage invocation: `ala-install/.../roles/pipelines_jenkins` already
  runs every stage (Interpret/UUID/Sample/SDS/Index/Solr/…) without EMR — mirror its
  semantics. The `la-pipelines` image is built in `la-docker-images/services/la-pipelines`.

## Your task (E4 — end to end)
1. Fix the `la_pipelines` container for no-Hadoop/no-AWS: in
   `ala-install/.../roles/pipelines/templates/la-pipelines-local.yaml` (and/or create the
   referenced-but-missing `la-pipelines-docker.yaml.j2`) switch `hdfs://...` paths to
   `file:///data/...`; resolve the Exit 137 (OOM) via `PIPELINES_JAVA_OPTS`.
2. Integrate the overlay: add the Airflow service to the stack on the SAME network, mounting
   the pipelines-airflow `dags/` + this overlay on PYTHONPATH, with
   `PIPELINES_COMPUTE_BACKEND=local`, `PIPELINES_CONTAINER=la_pipelines`, the docker socket,
   and the MinIO env. Seed via `seed.sh`. Prefer turning it into a role/template using the
   `deployment_type == 'container'` pattern, not a loose compose file.
3. Verify end to end: launch the `Load_dataset` DAG with a small dataset; confirm object in
   MinIO, `la-pipelines --local` in the logs, populated Solr collection, records via
   biocache-service.
4. Adjust the Variables' hostnames/ports to the real la-docker-compose service names.

## Setup / constraints
- Consume `pipelines-airflow` as a checkout/submodule pinned to a SHA; export
  `PIPELINES_AIRFLOW_REPO=/path/to/pipelines-airflow` (compose requires it).
- After pinning/bumping that SHA, ALWAYS run the contract test before deploying:
  `python3 overlay/pipelines-airflow/tests/test_contract_static.py` and, with the stack up,
  `overlay/pipelines-airflow/tests/run-in-airflow.sh`.
- Do NOT modify the pipelines-airflow repo (overlay only). Work on this branch
  (`feature/pipelines-airflow-no-aws-overlay`).

Start by exploring how this repo generates the `la_pipelines` service and its network, then
propose a plan before changing anything.

#!/usr/bin/env bash
#
# e2e-airflow-ingest.sh — Airflow ingestion e2e (pipelines-airflow overlay, phase E4).
#
# Ingests a tiny FIXED DwCA (8 records, e2e/fixtures/dr-test/) through the REAL
# pipeline and asserts the records land in Solr + biocache-service. The ingested
# data (dataResourceUid=$DR_UID) doubles as a fixture for the downstream Cypress
# biocache/species suites, which are meaningless on an empty index.
#
# Runs ON the host where the stack's Docker daemon lives (the CI stage scp's this
# script + the fixture to the target and runs it over ssh; you can do the same by
# hand: `ssh <host> DR_UID=... bash /tmp/e2e-airflow-ingest.sh`). All stack access
# is via `docker exec` — no Airflow REST API, no public DNS.
#
# Triggers `Ingest_small_datasets` DIRECTLY with run_indexing=true so a single
# dataset reaches Solr (Load_dataset triggers ingest with run_indexing=false).
# SDS is made optional via the overlay's runtime skip (pipelines_skip_stages in the
# DAG run conf -> sitecustomize no-ops the `sds` stage) so sensitive-data-service
# need not be deployed.
#
# Exit codes: 0 = records indexed (or report-only) | 1 = ingest/verify failed | 2 = preconditions unmet
# Report-only by default (exits 0, prints WARN); pass --blocking to gate CI.
#
# Usage:
#   scripts/e2e-airflow-ingest.sh [--blocking] [--report-only] [--seed-minio]
#                                 [--seed-collectory] [--timeout SEC]
set -euo pipefail

# --- config (env-overridable; defaults match the la-docker-compose stack) --------
AIRFLOW_CONTAINER="${AIRFLOW_CONTAINER:-la_airflow}"
PIPELINES_CONTAINER="${PIPELINES_CONTAINER:-la_pipelines}"
DR_UID="${DR_UID:-dr-e2e-test}"
DAG_ID="${DAG_ID:-Ingest_small_datasets}"
SOLR_COLLECTION="${SOLR_COLLECTION:-biocache}"
SOLR_URL="${SOLR_URL:-http://solr:8983/solr}"                 # reachable from la_airflow (overlay var)
BIOCACHE_WS="${BIOCACHE_WS:-http://biocache-service:8080/ws}" # reachable from la_airflow (overlay var)
COLLECTORY_WS="${COLLECTORY_WS:-http://collectory:8080/ws}"
# Where la-pipelines' dwca-avro reads the archive: {{dwca_import_dir}}/{dr}/{dr}.zip.
# In container mode the generator sets dwca_import_dir=/data/la-pipelines/dwca-import
# (matches the bind mount in pipelines.yml.j2), NOT the VM-style /dwca-exports the
# inventory carries. Override if your deployment differs.
DWCA_IMPORT_DIR="${DWCA_IMPORT_DIR:-/data/la-pipelines/dwca-import}"
PIPELINES_UID="${PIPELINES_UID:-1000}"   # la_pipelines runs as this uid (pipelines.yml.j2)
SKIP_STAGES="${SKIP_STAGES:-sds}"        # -> pipelines_skip_stages in the DAG run conf
EXPECTED_MIN="${EXPECTED_MIN:-1}"        # min indexed records to call it a success
TIMEOUT="${TIMEOUT:-1800}"               # seconds to wait for the DAG run
POLL_INTERVAL="${POLL_INTERVAL:-15}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_DIR="${FIXTURE_DIR:-$SCRIPT_DIR/../e2e/fixtures/dr-test}"

BLOCKING=false
SEED_MINIO=false
SEED_COLLECTORY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --blocking)        BLOCKING=true; shift ;;
    --report-only)     BLOCKING=false; shift ;;
    --seed-minio)      SEED_MINIO=true; shift ;;
    --seed-collectory) SEED_COLLECTORY=true; shift ;;
    --timeout)         TIMEOUT="$2"; shift 2 ;;
    -h|--help)         sed -n '2,33p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 64 ;;
  esac
done

log()  { printf '%s %s\n' "[ingest-e2e]" "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
err()  { printf 'ERROR: %s\n' "$*" >&2; }

finish() {   # honest exit under --blocking; report-only otherwise
  local code="$1"
  if [[ "$BLOCKING" == true ]]; then exit "$code"; fi
  [[ "$code" -ne 0 ]] && warn "report-only mode: exiting 0 despite the failure above (pass --blocking to gate)"
  exit 0
}

# thin wrappers around `docker exec` into the airflow container (-i variant for stdin)
af()  { docker exec "$AIRFLOW_CONTAINER" "$@"; }
afi() { docker exec -i "$AIRFLOW_CONTAINER" "$@"; }

# Dump the Airflow task log(s) for the run's failed task(s). states-for-dag-run only
# reports state=failed, not *why*; without the actual log the overlay shims (e.g. the
# EMR add_steps shim) fail opaquely. Best-effort: never let this fail the harness.
# We only dump tasks whose OWN state is 'failed' (upstream_failed ones are just cascade
# noise — the real traceback lives in the first task that failed).
dump_failed_task_logs() {
  local base tasks t
  base=$(af airflow config get-value logging base_log_folder 2>/dev/null \
         | tr -d '\r' | grep -E '^/' | tail -1)
  base="${base:-${AIRFLOW_HOME:-/opt/airflow}/logs}"
  tasks=$(af airflow tasks states-for-dag-run "$DAG_ID" "$RUN_ID" -o json 2>/dev/null \
    | afi python3 -c 'import sys,json,re
s=sys.stdin.read(); m=re.search(r"\[\s*(?:\{|\])",s)
d=json.loads(s[m.start():]) if m else []
print(" ".join(t.get("task_id","") for t in d if t.get("state")=="failed"))' 2>/dev/null || true)
  if [[ -z "$tasks" ]]; then
    warn "no 'failed' task found to dump the log of (see the state table above)"
    return 0
  fi
  for t in $tasks; do
    log "----- log tail for failed task '$t' (run=$RUN_ID) -----"
    # newest matching *.log across new-style (run_id=…/task_id=…) and legacy
    # (<DAG>/<task>/<date>) log layouts. GNU find/xargs (present in the airflow image).
    af bash -lc "find '$base' -type f -name '*.log' \
        \( -path '*run_id=${RUN_ID}*task_id=${t}*' -o -path '*/${DAG_ID}/${t}/*' \) \
        -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2- \
        | xargs -r tail -n 120" 2>/dev/null \
      || warn "could not read a log file for task '$t' under $base"
  done
}

# --- 0. preconditions ------------------------------------------------------------
command -v docker >/dev/null || { err "docker not found on this host"; exit 2; }
for c in "$AIRFLOW_CONTAINER" "$PIPELINES_CONTAINER"; do
  docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null | grep -q true \
    || { err "container '$c' is not running — is the stack up on this host?"; exit 2; }
done
[[ -f "$FIXTURE_DIR/meta.xml" && -f "$FIXTURE_DIR/occurrence.txt" ]] \
  || { err "fixture not found at $FIXTURE_DIR"; exit 2; }

# --- 1. package the fixture DwCA -------------------------------------------------
ZIP="/tmp/${DR_UID}.zip"
log "packaging fixture -> $ZIP"
( cd "$FIXTURE_DIR" && rm -f "$ZIP" && zip -q "$ZIP" meta.xml eml.xml occurrence.txt )

# --- 2. seed the archive where dwca-avro reads it (la_pipelines volume) -----------
DEST_DIR="${DWCA_IMPORT_DIR}/${DR_UID}"
log "seeding archive into ${PIPELINES_CONTAINER}:${DEST_DIR}/${DR_UID}.zip"
# mkdir as root (the mount may be root- or 1000-owned), then hand the tree to the
# pipelines uid so dwca-avro can read the archive. docker cp writes as root.
docker exec -u 0 "$PIPELINES_CONTAINER" mkdir -p "$DEST_DIR"
docker cp "$ZIP" "${PIPELINES_CONTAINER}:${DEST_DIR}/${DR_UID}.zip"
docker exec -u 0 "$PIPELINES_CONTAINER" chown -R "${PIPELINES_UID}:${PIPELINES_UID}" "$DEST_DIR"

# --- 2b. (optional) also push to MinIO — the production Load_dataset path ---------
if [[ "$SEED_MINIO" == true ]]; then
  log "uploading archive to MinIO (dwca-imports/${DR_UID}/${DR_UID}.zip)"
  docker cp "$ZIP" "${AIRFLOW_CONTAINER}:${ZIP}"
  afi python3 - "$ZIP" "$DR_UID" <<'PY' || warn "MinIO upload failed (non-fatal for direct ingest)"
import sys, boto3
zip_path, dr = sys.argv[1], sys.argv[2]
boto3.client("s3").upload_file(zip_path, "dwca-imports", f"dwca-imports/{dr}/{dr}.zip")
print("uploaded to MinIO")
PY
fi

# --- 2c. (optional) register the data resource in collectory (attribution) --------
if [[ "$SEED_COLLECTORY" == true ]]; then
  [[ -n "${COLLECTORY_API_KEY:-}" ]] || { err "--seed-collectory needs COLLECTORY_API_KEY"; exit 2; }
  log "registering data resource '${DR_UID}' in collectory"
  afi env CW="$COLLECTORY_WS" KEY="$COLLECTORY_API_KEY" DR="$DR_UID" python3 - <<'PY' \
    || warn "collectory seed failed (non-fatal; ingest does not require it)"
import os, json, urllib.request
body = {"name": "Living Atlas E2E Test Dataset", "acronym": "LAE2E",
        "resourceType": "records", "licenseType": "CC0",
        "connectionParameters": {"protocol": "DwCA", "termsForUniqueKey": ["occurrenceID"]}}
req = urllib.request.Request(f"{os.environ['CW']}/dataResource/{os.environ['DR']}",
                            data=json.dumps(body).encode(), method="POST",
                            headers={"Authorization": os.environ["KEY"],
                                     "Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=60) as r:
    print("collectory:", r.status)
PY
fi

# --- 3. trigger Ingest_small_datasets directly (run_indexing=true → reaches Solr) --
RUN_ID="e2e__${DR_UID}__$(date +%s)"
CONF=$(printf '{"datasetIds":"%s","run_indexing":"true","skip_dwca_to_verbatim":"false","load_images":"false","override_uuid_percentage_check":"true","pipelines_skip_stages":"%s"}' "$DR_UID" "$SKIP_STAGES")
log "unpausing + triggering $DAG_ID (run_id=$RUN_ID, skip_stages=$SKIP_STAGES)"
af airflow dags unpause "$DAG_ID" >/dev/null 2>&1 || true
af airflow dags trigger -r "$RUN_ID" -c "$CONF" "$DAG_ID"

# --- 4. poll the run to a terminal state -----------------------------------------
log "waiting up to ${TIMEOUT}s for the run to finish"
state=""; elapsed=0
while (( elapsed < TIMEOUT )); do
  # NOTE: the overlay's sitecustomize prints a banner to stdout on every airflow
  # invocation, so the `-o json` output is prefixed with noise -> json.load(stdin)
  # would fail and leave state empty (poll never sees 'failed', waits the full
  # timeout). Extract the JSON array (starts with '[{' or '[]') before parsing.
  state=$(af airflow dags list-runs -d "$DAG_ID" -o json 2>/dev/null \
    | afi python3 -c 'import sys,json,re; rid=sys.argv[1]; s=sys.stdin.read(); m=re.search(r"\[\s*(?:\{|\])", s); d=json.loads(s[m.start():]) if m else []; print(next((r.get("state","") for r in d if rid in (r.get("run_id"),r.get("dag_run_id"))),""))' "$RUN_ID" 2>/dev/null || true)
  case "$state" in
    success)  log "run state: success"; break ;;
    failed)   err "run state: failed"; break ;;
    *)        printf '.'; sleep "$POLL_INTERVAL"; elapsed=$((elapsed+POLL_INTERVAL)) ;;
  esac
done
echo
if [[ "$state" != "success" ]]; then
  err "DAG run did not succeed (state='${state:-timeout}') after ${elapsed}s"
  log "task states for this run:"
  af airflow tasks states-for-dag-run "$DAG_ID" "$RUN_ID" 2>/dev/null || true
  dump_failed_task_logs
  finish 1
fi

# --- 5. verify records in Solr + biocache-service --------------------------------
count() {  # count(system, url) — numFound from Solr or totalRecords from biocache
  local kind="$1" url="$2"
  afi env U="$url" DR="$DR_UID" python3 - "$kind" <<'PY' 2>/dev/null || echo -1
import os, sys, json, urllib.parse, urllib.request
kind, dr = sys.argv[1], os.environ["DR"]
if kind == "solr":
    q = 'dataResourceUid:"%s"' % dr
    u = f"{os.environ['U']}/select?q={urllib.parse.quote(q)}&rows=0&wt=json"
    key = ("response", "numFound")
else:
    q = 'data_resource_uid:"%s"' % dr
    u = f"{os.environ['U']}/occurrences/search?q={urllib.parse.quote(q)}&pageSize=0"
    key = ("totalRecords",)
with urllib.request.urlopen(u, timeout=30) as r:
    d = json.load(r)
for k in key:
    d = d[k]
print(int(d))
PY
}

solr_n=$(count solr "${SOLR_URL}/${SOLR_COLLECTION}")
bio_n=$(count biocache "$BIOCACHE_WS")
log "indexed records — Solr(${SOLR_COLLECTION})=${solr_n}  biocache-service=${bio_n}  (expected ≥ ${EXPECTED_MIN})"

rc=0
[[ "$solr_n" =~ ^[0-9]+$ && "$solr_n" -ge "$EXPECTED_MIN" ]] || { err "Solr has too few records ($solr_n)"; rc=1; }
[[ "$bio_n"  =~ ^[0-9]+$ && "$bio_n"  -ge "$EXPECTED_MIN" ]] || { err "biocache-service has too few records ($bio_n)"; rc=1; }
[[ "$rc" -eq 0 ]] && log "PASS — ingestion e2e verified ($DR_UID)"
finish "$rc"

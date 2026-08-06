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
# SDS now runs as part of the ingest (sensitive-data-service is deployed). It can still
# be skipped without a redeploy via the overlay's runtime skip — export SKIP_STAGES=sds
# and it lands in pipelines_skip_stages in the DAG run conf, where sitecustomize no-ops
# that stage.
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
SOLR_URL="${SOLR_URL:-http://solr:8983/solr}"                 # reachable from la_airflow (extra_hosts)
# Left EMPTY on purpose — resolved after the container wrappers are defined, from the
# overlay's own `biocache_url` Airflow Variable. Hardcoding http://biocache-service:8080/ws
# only works when biocache-service is co-located; on multihost the alias is NXDOMAIN and
# the verification silently reported -1 while the ingest had actually worked. Ansible
# already renders that Variable from biocache_service_base_url, so reuse it.
BIOCACHE_WS="${BIOCACHE_WS:-}"
COLLECTORY_WS="${COLLECTORY_WS:-http://collectory:8080/ws}"
# Where la-pipelines' dwca-avro reads the archive: {{dwca_import_dir}}/{dr}/{dr}.zip.
# In container mode the generator sets dwca_import_dir=/data/la-pipelines/dwca-import
# (matches the bind mount in pipelines.yml.j2), NOT the VM-style /dwca-exports the
# inventory carries. Override if your deployment differs.
DWCA_IMPORT_DIR="${DWCA_IMPORT_DIR:-/data/la-pipelines/dwca-import}"
PIPELINES_UID="${PIPELINES_UID:-1000}"   # la_pipelines runs as this uid (pipelines.yml.j2)
# -> pipelines_skip_stages in the DAG run conf. Empty = run every stage, SDS included.
# Note the `-` (not `:-`): an explicitly empty SKIP_STAGES="" must stay empty, otherwise
# there is no way to ask for "skip nothing" from the environment.
SKIP_STAGES="${SKIP_STAGES-}"
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

# Task logs are written by whoever RUNS the task, which is the scheduler (LocalExecutor),
# NOT $AIRFLOW_CONTAINER — they share the metadata DB but not the logs volume, so
# /opt/airflow/logs in la_airflow holds only scheduler/, no task logs at all. Discover the
# scheduler by name; fall back to $AIRFLOW_CONTAINER for single-container deployments.
# Public, cross-host-safe biocache WS. `airflow variables get` prints the sitecustomize
# banner and deprecation warnings first, so take the last line.
resolve_biocache_ws() {
  local v
  v=$(af airflow variables get biocache_url 2>/dev/null | tr -d '\r' | grep -E '^https?://' | tail -1)
  printf '%s\n' "${v:-http://biocache-service:8080/ws}"
}

tasklog_container() {
  if [[ -n "${AIRFLOW_TASKLOG_CONTAINER:-}" ]]; then printf '%s\n' "$AIRFLOW_TASKLOG_CONTAINER"; return; fi
  docker ps --format '{{.Names}}' 2>/dev/null | grep -m1 -E 'airflow-scheduler' \
    || printf '%s\n' "$AIRFLOW_CONTAINER"
}

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
  local logc
  logc=$(tasklog_container)
  for t in $tasks; do
    log "----- log tail for failed task '$t' (run=$RUN_ID, container=$logc) -----"
    # newest matching *.log across new-style (run_id=…/task_id=…) and legacy
    # (<DAG>/<task>/<date>) log layouts. GNU find/xargs (present in the airflow image).
    local found
    found=$(docker exec "$logc" bash -lc "find '$base' -type f -name '*.log' \
        \( -path '*run_id=${RUN_ID}*task_id=${t}*' -o -path '*/${DAG_ID}/${t}/*' \) \
        -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2- \
        | xargs -r tail -n 120" 2>/dev/null || true)
    if [[ -n "$found" ]]; then
      printf '%s\n' "$found"
    else
      warn "no log file for task '$t' under $base in '$logc'."
      warn "task logs are written by whichever container RUNS the task; set"
      warn "AIRFLOW_TASKLOG_CONTAINER=<name> if auto-detection picked the wrong one."
    fi
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

# The dataset MUST be registered in collectory before the run: interpret asks collectory
# for the dataResource metadata and, when the lookup fails, logs "Collectory metadata no
# available for <dr>. Will not run interpretation" and STILL EXITS 0. The whole chain then
# runs on empty input and the first hard failure lands six stages later in `solr` ("No
# files matched spec: /pipelines-all-datasets/index-record/<dr>/*.avro"), which points at
# entirely the wrong thing. Check it up front so the diagnosis is one line, not one hour.
# Uses the URL la-pipelines itself is configured with, so a wrong/unreachable collectory
# URL is caught here too.
collectory_ws=$(docker exec "$PIPELINES_CONTAINER" bash -lc \
  "sed -nE '/^collectory:/,/^[a-zA-Z]/s#^[[:space:]]+wsUrl:[[:space:]]*(.+)[[:space:]]*\$#\1#p' \
   /data/la-pipelines/config/la-pipelines-local.yaml | head -1" 2>/dev/null | tr -d '\r')
collectory_ws="${collectory_ws:-$COLLECTORY_WS}"
# Send the SAME Authorization header la-pipelines sends (read from its config), because
# even a plain GET of one dataResource goes through CollectoryAuthService: unauthenticated
# it reaches checkJWT(), which in collectory 6.0.0 calls pac4j's FindBest — a class removed
# in the pac4j 6.0.6 the image ships — and 500s. With a VALID key the check returns before
# that call. So a 500 here almost always means the key is not registered in the apikey DB,
# not that collectory is down.
collectory_key=$(docker exec "$PIPELINES_CONTAINER" bash -lc \
  "sed -nE '/^collectory:/,/^[a-zA-Z]/s#^[[:space:]]+Authorization:[[:space:]]*(.+)[[:space:]]*\$#\1#p' \
   /data/la-pipelines/config/la-pipelines-local.yaml | head -1" 2>/dev/null | tr -d '\r')
# `|| true` INSIDE the container shell: curl exits non-zero when the host does not
# resolve, and an outer `|| echo 000` would append to curl's own "000" -> "000000",
# which then misses the 000 case and reports the wrong reason.
dr_http=$(docker exec "$PIPELINES_CONTAINER" bash -lc \
  "curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
   -H 'Authorization: ${collectory_key}' '${collectory_ws%/}/dataResource/${DR_UID}' || true" 2>/dev/null | tail -c 3)
dr_http="${dr_http:-000}"
case "$dr_http" in
  200) log "collectory: dataResource '$DR_UID' registered (${collectory_ws})" ;;
  000) err "collectory unreachable from ${PIPELINES_CONTAINER} at ${collectory_ws}."
       err "interpret would silently skip (exit 0) and the run would fail later in 'solr'."
       err "On multihost the internal alias does not resolve — la-pipelines needs the public URL."
       exit 2 ;;
  500) err "collectory returned 500 for '$DR_UID' at ${collectory_ws}."
       err "Most likely la-pipelines' API key is not registered in the apikey DB, so the"
       err "request falls through to collectory's checkJWT() and dies on pac4j FindBest."
       err "Check: curl '<apikey-service>/ws/check?apikey=<key>' should report valid:true."
       exit 2 ;;
  *)   err "collectory has no dataResource '$DR_UID' (HTTP $dr_http at ${collectory_ws})."
       err "interpret would silently skip (exit 0) and the run would fail later in 'solr'."
       err "Register it first (see --seed-collectory), then re-run."
       exit 2 ;;
esac

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
    || warn "collectory seed failed — the run WILL fail; interpret needs this metadata"
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

# IndexRecordToSolrPipeline does NOT commit, and the collection has no aggressive
# autoCommit, so a count taken right after the DAG succeeds reads the PRE-ingest index
# and reports 0 — the ingest looks broken when it worked. Commit explicitly (idempotent,
# and the harness already deletes this dataResource before the solr stage anyway).
log "committing the ${SOLR_COLLECTION} collection before counting"
af curl -s -o /dev/null --max-time 60 \
  "${SOLR_URL}/${SOLR_COLLECTION}/update?commit=true" \
  -H 'Content-Type: text/xml' --data-binary '<commit/>' \
  || warn "solr commit failed; counts below may lag behind the ingest"

BIOCACHE_WS="${BIOCACHE_WS:-$(resolve_biocache_ws)}"
log "verifying against Solr ${SOLR_URL}/${SOLR_COLLECTION} and biocache ${BIOCACHE_WS}"
solr_n=$(count solr "${SOLR_URL}/${SOLR_COLLECTION}")
bio_n=$(count biocache "$BIOCACHE_WS")
log "indexed records — Solr(${SOLR_COLLECTION})=${solr_n}  biocache-service=${bio_n}  (expected ≥ ${EXPECTED_MIN})"

rc=0
[[ "$solr_n" =~ ^[0-9]+$ && "$solr_n" -ge "$EXPECTED_MIN" ]] || { err "Solr has too few records ($solr_n)"; rc=1; }
[[ "$bio_n"  =~ ^[0-9]+$ && "$bio_n"  -ge "$EXPECTED_MIN" ]] || { err "biocache-service has too few records ($bio_n)"; rc=1; }
[[ "$rc" -eq 0 ]] && log "PASS — ingestion e2e verified ($DR_UID)"
finish "$rc"

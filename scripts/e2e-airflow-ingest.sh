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
#
# To ingest a real medium dataset instead of the 8-record fixture:
#   DWCA_ZIP=$(scripts/fetch-medium-dwca.sh) EXPECTED_MIN=2000 \
#     scripts/e2e-airflow-ingest.sh --blocking
set -euo pipefail

# --- config (env-overridable; defaults match the la-docker-compose stack) --------
AIRFLOW_CONTAINER="${AIRFLOW_CONTAINER:-la_airflow}"
PIPELINES_CONTAINER="${PIPELINES_CONTAINER:-la_pipelines}"
# Must be a uid collectory ACTUALLY holds — interpret asks it for the dataResource
# metadata and silently skips the whole run when the lookup fails (see the precondition
# below). collectory assigns uids itself: POST /ws/dataResource/<uid> is an UPDATE and
# 404s when absent, creation is POST /ws/dataResource with no uid. So this cannot be an
# arbitrary label like "dr-e2e-test" — it is the uid of the resource registered on the
# target deployment (dr0 on a freshly seeded one, being the first dataResource created).
DR_UID="${DR_UID:-dr0}"
# Identifies OUR dataResource across runs. The precondition looks it up by name before
# creating anything, so repeated runs reuse one resource instead of leaving dr0, dr1, dr2…
DR_NAME="${DR_NAME:-Living Atlas E2E Test Dataset}"
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

# Shared plumbing (logging, docker-exec wrappers, DAG trigger/poll, task-log dumping,
# record counting) lives in the library so the reindex harness reuses exactly the same
# code paths. This script keeps its CLI contract: the Jenkins stage invokes it verbatim.
LOG_TAG="ingest-e2e"
# shellcheck source=scripts/e2e-airflow-lib.sh
. "$SCRIPT_DIR/e2e-airflow-lib.sh"

# --- 0. preconditions ------------------------------------------------------------
command -v docker >/dev/null || { err "docker not found on this host"; exit 2; }
for c in "$AIRFLOW_CONTAINER" "$PIPELINES_CONTAINER"; do
  docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null | grep -q true \
    || { err "container '$c' is not running — is the stack up on this host?"; exit 2; }
done
# Only the committed fixture needs a FIXTURE_DIR; DWCA_ZIP supplies the archive itself.
if [[ -z "${DWCA_ZIP:-}" ]]; then
  [[ -f "$FIXTURE_DIR/meta.xml" && -f "$FIXTURE_DIR/occurrence.txt" ]] \
    || { err "fixture not found at $FIXTURE_DIR"; exit 2; }
fi

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

# Self-seeding, so a CLEAN deployment can be tested without a manual step: collectory
# starts empty, and DR_UID's default (dr0) only exists once something created it. Reuse a
# resource with our name if one is there — otherwise every run would leave behind dr0,
# dr1, dr2... Creation is POST with NO uid (the /<uid> route is an UPDATE and 404s when
# absent); collectory assigns the uid and returns it in the Location header.
# The container has curl but no python3, hence the sed/grep JSON handling.
if [[ "$dr_http" == 404 || "$SEED_COLLECTORY" == true ]]; then
  if [[ "$SEED_COLLECTORY" != true ]]; then
    log "collectory has no '$DR_UID' — looking for '${DR_NAME}' before creating one"
    # Trailing `|| true`: under `set -euo pipefail` the grep exits 1 when the name is
    # absent — exactly the case we are handling — and would kill the script silently
    # right before the branch that creates the resource.
    found=$(docker exec "$PIPELINES_CONTAINER" bash -lc \
      "curl -s --max-time 20 '${collectory_ws%/}/dataResource' || true" 2>/dev/null \
      | sed 's/},{/}\n{/g' | grep -F "\"name\":\"${DR_NAME}\"" \
      | sed -nE 's/.*"uid":"([^"]+)".*/\1/p' | head -1 || true)
    if [[ -n "$found" ]]; then
      log "collectory: reusing existing dataResource '$found' (${DR_NAME})"
      DR_UID="$found"
      dr_http=200
    fi
  fi
  if [[ "$dr_http" != 200 ]]; then
    [[ -n "$collectory_key" ]] || { err "no collectory API key in la-pipelines config; cannot create the dataResource"; exit 2; }
    log "creating dataResource '${DR_NAME}' in collectory"
    created=$(docker exec "$PIPELINES_CONTAINER" bash -lc \
      "curl -s -D - -o /dev/null --max-time 60 -X POST '${collectory_ws%/}/dataResource' \
       -H 'Authorization: ${collectory_key}' -H 'Content-Type: application/json' \
       -d '{\"name\":\"${DR_NAME}\",\"acronym\":\"LAE2E\",\"resourceType\":\"records\",\"licenseType\":\"CC0\",\"connectionParameters\":{\"protocol\":\"DwCA\",\"termsForUniqueKey\":[\"occurrenceID\"]}}' \
       || true" 2>/dev/null | tr -d '\r')
    new_uid=$(printf '%s\n' "$created" | sed -nE 's#^[Ll]ocation:.*/dataResource/([^/[:space:]]+).*#\1#p' | head -1)
    if [[ -z "$new_uid" ]]; then
      err "could not create a dataResource in collectory. Response headers:"
      printf '%s\n' "$created" | head -5 >&2
      err "A 500 here means la-pipelines' API key is not registered in the apikey DB"
      err "(collectory then falls through to checkJWT() and dies on pac4j FindBest)."
      exit 2
    fi
    log "collectory: created dataResource '$new_uid'"
    DR_UID="$new_uid"
    dr_http=200
  fi
fi

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

# --- 1. get the DwCA (committed fixture, or a prebuilt archive) ------------------
# DWCA_ZIP lets a caller ingest a real archive instead of the 8-record fixture --
# scripts/fetch-medium-dwca.sh prints a path suitable for it. The 8 records prove a
# stage RAN; a few thousand real ones prove it PROCESSED something.
ZIP="/tmp/${DR_UID}.zip"
if [[ -n "${DWCA_ZIP:-}" ]]; then
  [[ -f "$DWCA_ZIP" ]] || { err "DWCA_ZIP=$DWCA_ZIP does not exist"; exit 2; }
  log "using prebuilt archive $DWCA_ZIP"
  cp -f "$DWCA_ZIP" "$ZIP"
else
  log "packaging fixture -> $ZIP"
  ( cd "$FIXTURE_DIR" && rm -f "$ZIP" && zip -q "$ZIP" meta.xml eml.xml occurrence.txt )
fi

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

# (collectory registration happens in the preconditions above, which already resolve the
# WS URL and the API key from la-pipelines' own config — a second copy here would just
# drift. --seed-collectory forces creating a fresh dataResource instead of reusing ours.)

# --- 3. trigger Ingest_small_datasets directly (run_indexing=true → reaches Solr) --
RUN_ID="e2e__${DR_UID}__$(date +%s)"
CONF=$(printf '{"datasetIds":"%s","run_indexing":"true","skip_dwca_to_verbatim":"false","load_images":"false","override_uuid_percentage_check":"true","pipelines_skip_stages":"%s"}' "$DR_UID" "$SKIP_STAGES")
log "skip_stages=$SKIP_STAGES"
trigger_dag "$DAG_ID" "$RUN_ID" "$CONF" || { err "could not trigger $DAG_ID"; finish 1; }

# --- 4. poll the run to a terminal state -----------------------------------------
state=$(poll_dag_run "$DAG_ID" "$RUN_ID" "$TIMEOUT" "$POLL_INTERVAL") || true
if [[ "$state" != "success" ]]; then
  err "DAG run did not succeed (state='${state}')"
  log "task states for this run:"
  af airflow tasks states-for-dag-run "$DAG_ID" "$RUN_ID" 2>/dev/null || true
  dump_failed_task_logs "$DAG_ID" "$RUN_ID"
  finish 1
fi

# --- 5. verify records in Solr + biocache-service --------------------------------
# IndexRecordToSolrPipeline does NOT commit, and the collection has no aggressive
# autoCommit, so a count taken right after the DAG succeeds reads the PRE-ingest index
# and reports 0 — the ingest looks broken when it worked. Commit explicitly (idempotent,
# and the harness already deletes this dataResource before the solr stage anyway).
log "committing the ${SOLR_COLLECTION} collection before counting"
solr_commit "$SOLR_URL" "$SOLR_COLLECTION"

BIOCACHE_WS="${BIOCACHE_WS:-$(resolve_biocache_ws)}"
log "verifying against Solr ${SOLR_URL}/${SOLR_COLLECTION} and biocache ${BIOCACHE_WS}"
solr_n=$(count_records solr "${SOLR_URL}/${SOLR_COLLECTION}" "$DR_UID")
bio_n=$(count_records biocache "$BIOCACHE_WS" "$DR_UID")
log "indexed records — Solr(${SOLR_COLLECTION})=${solr_n}  biocache-service=${bio_n}  (expected ≥ ${EXPECTED_MIN})"

rc=0
[[ "$solr_n" =~ ^[0-9]+$ && "$solr_n" -ge "$EXPECTED_MIN" ]] || { err "Solr has too few records ($solr_n)"; rc=1; }
[[ "$bio_n"  =~ ^[0-9]+$ && "$bio_n"  -ge "$EXPECTED_MIN" ]] || { err "biocache-service has too few records ($bio_n)"; rc=1; }
[[ "$rc" -eq 0 ]] && log "PASS — ingestion e2e verified ($DR_UID)"
finish "$rc"

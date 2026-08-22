#!/usr/bin/env bash
#
# e2e-airflow-lib.sh — shared plumbing for the Airflow e2e harnesses.
#
# Sourced, never executed. Everything here talks to the stack through `docker exec`
# into the Airflow container, so the harnesses run ON the host where the stack's Docker
# daemon lives and need neither the REST API nor public DNS.
#
# Callers set: AIRFLOW_CONTAINER, LOG_TAG, BLOCKING. Consumers so far:
#   scripts/e2e-airflow-ingest.sh      — single-dataset ingest -> Solr
#   scripts/e2e-airflow-full-index.sh  — full reindex -> dated collection + alias swap

AIRFLOW_CONTAINER="${AIRFLOW_CONTAINER:-la_airflow}"
LOG_TAG="${LOG_TAG:-airflow-e2e}"

log()  { printf '%s %s\n' "[$LOG_TAG]" "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
err()  { printf 'ERROR: %s\n' "$*" >&2; }

# Honest exit under --blocking; report-only otherwise. A report-only stage that exits 0
# with the pipeline dead is how #338 shipped green for months, so the exit code always
# reflects reality and only this wrapper decides whether that gates the build.
finish() {
  local code="$1"
  if [[ "${BLOCKING:-false}" == true ]]; then exit "$code"; fi
  [[ "$code" -ne 0 ]] && warn "report-only mode: exiting 0 despite the failure above (pass --blocking to gate)"
  exit 0
}

# thin wrappers around `docker exec` into the airflow container (-i variant for stdin)
af()  { docker exec "$AIRFLOW_CONTAINER" "$@"; }
afi() { docker exec -i "$AIRFLOW_CONTAINER" "$@"; }

# Every python run in the container prints the overlay's sitecustomize banner and
# Airflow's deprecation warnings before the payload, so anything parsing command output
# has to skip that noise rather than assume the first line is data.
json_tail() {  # json_tail <python-expr-script> [args...] — stdin is a noisy JSON blob
  afi python3 -c "$@"
}

# Public, cross-host-safe biocache WS, taken from the overlay's own Airflow Variable
# (Ansible renders it from biocache_service_base_url). Hardcoding the internal alias only
# works when biocache-service is co-located; on multihost it is NXDOMAIN and the
# verification silently reports -1 while the ingest actually worked.
resolve_biocache_ws() {
  local v
  v=$(af airflow variables get biocache_url 2>/dev/null | tr -d '\r' | grep -E '^https?://' | tail -1)
  printf '%s\n' "${v:-http://biocache-service:8080/ws}"
}

# Task logs are written by whoever RUNS the task, which is the scheduler (LocalExecutor),
# NOT $AIRFLOW_CONTAINER — they share the metadata DB but not the logs volume, so
# /opt/airflow/logs in la_airflow holds only scheduler/, no task logs at all.
tasklog_container() {
  if [[ -n "${AIRFLOW_TASKLOG_CONTAINER:-}" ]]; then printf '%s\n' "$AIRFLOW_TASKLOG_CONTAINER"; return; fi
  docker ps --format '{{.Names}}' 2>/dev/null | grep -m1 -E 'airflow-scheduler' \
    || printf '%s\n' "$AIRFLOW_CONTAINER"
}

# Dump the Airflow task log(s) for the run's failed task(s). states-for-dag-run only
# reports state=failed, not *why*; without the actual log the overlay shims fail
# opaquely. Best-effort: never let this fail the harness. Only tasks whose OWN state is
# 'failed' are dumped — upstream_failed ones are cascade noise.
dump_failed_task_logs() {  # dump_failed_task_logs <dag_id> <run_id>
  local dag_id="$1" run_id="$2" base tasks t logc found
  base=$(af airflow config get-value logging base_log_folder 2>/dev/null \
         | tr -d '\r' | grep -E '^/' | tail -1)
  base="${base:-${AIRFLOW_HOME:-/opt/airflow}/logs}"
  tasks=$(af airflow tasks states-for-dag-run "$dag_id" "$run_id" -o json 2>/dev/null \
    | afi python3 -c 'import sys,json,re
s=sys.stdin.read(); m=re.search(r"\[\s*(?:\{|\])",s)
d=json.loads(s[m.start():]) if m else []
print(" ".join(t.get("task_id","") for t in d if t.get("state")=="failed"))' 2>/dev/null || true)
  if [[ -z "$tasks" ]]; then
    warn "no 'failed' task found to dump the log of (see the state table above)"
    return 0
  fi
  logc=$(tasklog_container)
  for t in $tasks; do
    log "----- log tail for failed task '$t' (run=$run_id, container=$logc) -----"
    # newest matching *.log across new-style (run_id=…/task_id=…) and legacy
    # (<DAG>/<task>/<date>) log layouts. GNU find/xargs (present in the airflow image).
    found=$(docker exec "$logc" bash -lc "find '$base' -type f -name '*.log' \
        \( -path '*run_id=${run_id}*task_id=${t}*' -o -path '*/${dag_id}/${t}/*' \) \
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

# Returns non-zero instead of dying, so the caller can route the failure through
# finish() and --report-only keeps its promise of exiting 0. Under `set -e` a bare
# `airflow dags trigger` failure killed the script outright, bypassing that.
trigger_dag() {  # trigger_dag <dag_id> <run_id> <conf-json>
  local dag_id="$1" run_id="$2" conf="$3"
  log "unpausing + triggering $dag_id (run_id=$run_id)"
  af airflow dags unpause "$dag_id" >/dev/null 2>&1 || true
  af airflow dags trigger -r "$run_id" -c "$conf" "$dag_id" || return 1
}

# Poll a run to a terminal state. Echoes the final state; returns 0 only on success.
poll_dag_run() {  # poll_dag_run <dag_id> <run_id> <timeout> <interval>
  local dag_id="$1" run_id="$2" timeout="$3" interval="$4" state="" elapsed=0
  log "waiting up to ${timeout}s for the run to finish" >&2
  while (( elapsed < timeout )); do
    state=$(af airflow dags list-runs -d "$dag_id" -o json 2>/dev/null \
      | afi python3 -c 'import sys,json,re; rid=sys.argv[1]; s=sys.stdin.read(); m=re.search(r"\[\s*(?:\{|\])", s); d=json.loads(s[m.start():]) if m else []; print(next((r.get("state","") for r in d if rid in (r.get("run_id"),r.get("dag_run_id"))),""))' "$run_id" 2>/dev/null || true)
    case "$state" in
      success) printf '\n' >&2; log "run state: success" >&2; printf 'success\n'; return 0 ;;
      failed)  printf '\n' >&2; err  "run state: failed";     printf 'failed\n';  return 1 ;;
      *)       printf '.' >&2; sleep "$interval"; elapsed=$((elapsed+interval)) ;;
    esac
  done
  printf '\n' >&2
  err "DAG run did not reach a terminal state after ${elapsed}s"
  printf '%s\n' "${state:-timeout}"
  return 1
}

# IndexRecordToSolrPipeline does NOT commit and the collection has no aggressive
# autoCommit, so a count taken right after the DAG succeeds reads the PRE-ingest index
# and reports 0 — the ingest looks broken when it worked.
solr_commit() {  # solr_commit <solr_url> <collection>
  af curl -s -o /dev/null --max-time 60 "$1/$2/update?commit=true" \
    -H 'Content-Type: text/xml' --data-binary '<commit/>' \
    || warn "solr commit failed; counts may lag behind the ingest"
}

# numFound from Solr, or totalRecords from biocache-service, for one dataResource.
# Note the quoting: the '-' in a uid is NOT in the Solr query parser, so it must be
# quoted or the query silently means something else.
count_records() {  # count_records <solr|biocache> <base-url> <dr-uid>
  afi env U="$2" DR="$3" python3 - "$1" <<'PY' 2>/dev/null || echo -1
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

# Solr admin helpers, used by the reindex harness to assert the alias actually moved.
solr_admin_json() {  # solr_admin_json <query-string> — echoes raw JSON
  af curl -s --max-time 60 "${SOLR_URL:-http://solr:8983/solr}/admin/collections?$1&wt=json"
}

solr_collections() {
  solr_admin_json "action=LIST" | afi python3 -c \
    'import sys,json,re;s=sys.stdin.read();m=re.search(r"\{",s);print(" ".join(json.loads(s[m.start():]).get("collections",[])))' 2>/dev/null
}

solr_alias_target() {  # solr_alias_target <alias>
  solr_admin_json "action=LISTALIASES" | afi python3 -c \
    'import sys,json,re;s=sys.stdin.read();m=re.search(r"\{",s);print(json.loads(s[m.start():]).get("aliases",{}).get(sys.argv[1],""))' "$1" 2>/dev/null
}

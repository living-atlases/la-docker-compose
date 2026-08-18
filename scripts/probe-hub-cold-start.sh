#!/usr/bin/env bash
#
# probe-hub-cold-start.sh — settle whether biocache-hub's cold-start 500 needs DATA.
#
# THIS IS AN EXPERIMENT, NOT A GATE. It always exits 0 and never fails a build.
#
# The open question, left over from #356 (see gh-8). biocache-hub serves HTTP 500 on
# /occurrences/search:
#
#   GrailsTagException: [views/occurrence/list.gsp:22] Error executing tag <alatag:message>:
#   Cannot invoke "java.util.Map.size()" because "<parameter1>" is null
#   -> MessageSourceCacheService.getMessagesMap -> listMessageCodes -> getMergedProperties
#
# Restarting the hub clears it. What nobody has established is WHY, and the answer decides
# the fix. Ruled out already, so do not re-test these: the i18n volume (populated before
# the hub booted, gate satisfied), an upstream fix (the class is unchanged since 2021, so
# ala-hub 8.3.0 == 8.1.0 here), and biocache-service's empty field list reaching the hub
# over HTTP (the hub makes no /facets/i18n call at all - nginx logged 0 of them against 30
# to /index/fields in the same window).
#
# What remains is a single fork, and one restart on a data-less stack decides it:
#
#   A. 200 after restarting the hub on an EMPTY index
#      -> the 500 does not need data. It is a boot-order/initialisation defect, and the fix
#         belongs in the deploy: gate or restart the hub once the stack has settled, and
#         every portal benefits, ingest or no ingest.
#
#   B. still 500 after restarting the hub on an EMPTY index
#      -> the 500 IS data-dependent. A restart only helps once records exist, so a
#         data-less portal cannot be fixed at deploy time at all, and the honest move is to
#         say so in the docs and leave the checks in "Data checks" where they are.
#
# Run it on a CLEAN, DATA-LESS deployment, BEFORE any ingest - that is the only state where
# the question can be asked. It refuses to run otherwise rather than produce a result that
# looks like an answer and is not.
#
# Usage: scripts/probe-hub-cold-start.sh [--targets-file PATH] [--records URL] [--records-ws URL]
set -euo pipefail

TARGETS_FILE="${TARGETS_FILE:-/data/docker-compose/e2e-targets.json}"
RECORDS="${RECORDS:-}"
RECORDS_WS="${RECORDS_WS:-}"
HUB_CONTAINER="${HUB_CONTAINER:-la_biocache-hub}"
COMPOSE_DIR="${COMPOSE_DIR:-/data/docker-compose}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --targets-file) TARGETS_FILE="$2"; shift 2 ;;
    --records)      RECORDS="$2"; shift 2 ;;
    --records-ws)   RECORDS_WS="$2"; shift 2 ;;
    -h|--help)      sed -n '2,36p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 64 ;;
  esac
done

log()     { printf '%s %s\n' "[hub-probe]" "$*"; }
verdict() { printf '\n========== HUB COLD-START PROBE: %s ==========\n%s\n===============================================\n\n' "$1" "$2"; }

status_of()  { curl -sk -o /dev/null -w '%{http_code}' --max-time 30 "$1" 2>/dev/null || echo 000; }
field_count(){ curl -sk --max-time 30 "${RECORDS_WS}/index/fields" 2>/dev/null | grep -o '"name"' | wc -l | tr -d ' '; }
record_count(){
  curl -sk --max-time 30 "${RECORDS_WS}/occurrences/search?q=*:*&pageSize=0" 2>/dev/null \
    | sed -n 's/.*"totalRecords":[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1
}
npe_count()  { docker logs --since "${1:-10m}" "$HUB_CONTAINER" 2>&1 | grep -c 'because "<parameter1>" is null' || true; }

# --- preconditions ----------------------------------------------------------------
if ! docker inspect -f '{{.State.Running}}' "$HUB_CONTAINER" 2>/dev/null | grep -q true; then
  log "no $HUB_CONTAINER on this host — nothing to probe here"; exit 0
fi

if [[ -z "$RECORDS" || -z "$RECORDS_WS" ]] && [[ -f "$TARGETS_FILE" ]]; then
  RECORDS="${RECORDS:-$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["services"].get("records",""))' "$TARGETS_FILE" 2>/dev/null || true)}"
  RECORDS_WS="${RECORDS_WS:-$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["services"].get("recordsWs",""))' "$TARGETS_FILE" 2>/dev/null || true)}"
fi
if [[ -z "$RECORDS" || -z "$RECORDS_WS" ]]; then
  verdict "CANNOT RUN" "Could not resolve the records/records-ws URLs (targets file: $TARGETS_FILE)."
  exit 0
fi
log "records=$RECORDS  records-ws=$RECORDS_WS"

docs="$(record_count)"; docs="${docs:-unknown}"
if [[ "$docs" != "0" ]]; then
  verdict "SKIPPED — NOT A COLD START" \
"The index already holds ${docs} record(s), so this deployment cannot answer the question.
Re-run with RUN_AIRFLOW_INGEST=false on a CLEAN_MACHINE build to probe a data-less stack."
  exit 0
fi

# --- before -----------------------------------------------------------------------
before_fields="$(field_count)"
before_status="$(status_of "${RECORDS}/occurrences/search?q=*:*")"
before_npe="$(npe_count 60m)"
log "BEFORE: index records=0  /index/fields=${before_fields}  hub search=${before_status}  NPEs(60m)=${before_npe}"

if [[ "$before_status" == "200" ]]; then
  verdict "NO COLD-START 500 REPRODUCED" \
"With an empty index the hub search page already returns 200, so the 500 seen on #356 is
NOT an inevitable consequence of deploying without data. Something else triggered it there
(ordering, a slow dependency at boot, or the converge restart). Next step is to catch it in
the act rather than to reproduce it on demand: keep this probe on, and when a build does go
red on 'records search page', compare that build's hub boot log against this one's."
  exit 0
fi

log "cold-start 500 reproduced on an empty index — restarting the hub to see if that is enough"

# --- the one mutation: restart the hub --------------------------------------------
(cd "$COMPOSE_DIR" && docker compose restart biocache-hub) >/dev/null 2>&1 || docker restart "$HUB_CONTAINER" >/dev/null

waited=0
while [[ "$waited" -lt "$BOOT_TIMEOUT" ]]; do
  st="$(status_of "${RECORDS}/occurrences/search?q=*:*")"
  # 000/502/503 = still booting behind nginx; keep waiting for a real verdict.
  [[ "$st" != "000" && "$st" != "502" && "$st" != "503" ]] && break
  sleep 10; waited=$((waited + 10)); printf '.'
done
echo

after_status="$(status_of "${RECORDS}/occurrences/search?q=*:*")"
after_fields="$(field_count)"
after_npe="$(npe_count 5m)"
log "AFTER:  /index/fields=${after_fields}  hub search=${after_status}  NPEs(5m)=${after_npe}"

# --- verdict ----------------------------------------------------------------------
if [[ "$after_status" == "200" ]]; then
  verdict "A — RESTART IS ENOUGH, DATA NOT REQUIRED" \
"Empty index (0 records, /index/fields=${after_fields}) and the hub search page returns 200
after nothing but a restart.

The 500 is therefore an initialisation defect in the hub, independent of the data, and it
is fixable at deploy time for EVERY portal: restart or gate biocache-hub once the stack has
settled, instead of only after an ingest.

ACTION: move the hub half of scripts/refresh-biocache-fields.sh out from behind the
'records-ws serves fields' guard, and run it on every deploy."
else
  verdict "B — THE 500 SURVIVES A RESTART ON AN EMPTY INDEX (${after_status})" \
"Empty index and the hub search page still does not return 200 after a restart
(NPEs since the restart: ${after_npe}).

The 500 is therefore data-dependent: a restart only helps once records exist. A portal with
no data cannot be fixed at deploy time, so nothing should pretend otherwise.

ACTION: keep the hub half gated behind data as it is now, keep both checks in Gatus'
'Data checks' group, and document that a portal serves a 500 on /occurrences/search until
its first ingest."
fi
exit 0

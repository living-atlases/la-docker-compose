#!/usr/bin/env bash
#
# refresh-biocache-fields.sh — close the empty-field-list state left by a first ingest.
#
# biocache-service reads its index field list ONCE at boot, from /admin/luke, and caches
# it for the life of the process. luke only reports fields that are actually present in
# the index segments, so ANY boot against an index with zero documents caches an empty
# list — whether the collection was missing or merely empty. From then on /index/fields
# answers `[]` with HTTP 200 and nothing recovers on its own.
#
# The wait-for-solr-collection gate covers the case where the data is already there at
# deploy time. It cannot cover a first install: documents arrive with the first ingest,
# long after the gate has given up. This script is that second half, and belongs right
# after the ingest.
#
# biocache-hub needs refreshing too, for a SEPARATE reason. On #356 its search page had
# been 500ing for 2.5 h on:
#
#   GrailsTagException: [views/occurrence/list.gsp:22] Error executing tag <alatag:message>:
#   Cannot invoke "java.util.Map.size()" because "<parameter1>" is null
#
# Restarting the hub clears it. The mechanism is NOT established, and two tempting
# explanations were ruled out on #356: the i18n volume (populated before the hub booted)
# and biocache-service's empty field list (the hub makes no /facets/i18n call - nginx
# logged 0 of them against 30 to /index/fields in the same window). So treat the hub half
# below as a known-good remedy, not as a consequence of the field list.
#
# It is still ordered after the field list, deliberately: restarting the hub is only worth
# doing once records-ws is healthy, and on an install with no data at all it is skipped
# rather than retried into a loop.
#
# Diagnosed on build #356 (2026-08-17): both endpoints red for hours with every container
# healthy and the build green.
#
# Runs ON a docker host and only touches the containers that live there, so it is safe to
# run on every target host: the biocache-service half and the biocache-hub half are
# independent, and the hub half waits on the PUBLIC records-ws URL, so it converges even
# when the two services sit on different hosts.
#
# Exit codes: 0 = fields served (or nothing to do) | 1 = still empty after a restart | 2 = preconditions unmet
# Blocking by default; --report-only exits 0 while still printing what it found.
#
# Usage:
#   scripts/refresh-biocache-fields.sh [--report-only] [--targets-file PATH]
#                                      [--records-ws URL] [--records URL] [--timeout SEC]
set -euo pipefail

TARGETS_FILE="${TARGETS_FILE:-/data/docker-compose/e2e-targets.json}"
RECORDS_WS="${RECORDS_WS:-}"
RECORDS="${RECORDS:-}"
SERVICE_CONTAINER="${SERVICE_CONTAINER:-la_biocache-service}"
HUB_CONTAINER="${HUB_CONTAINER:-la_biocache-hub}"
COMPOSE_DIR="${COMPOSE_DIR:-/data/docker-compose}"
TIMEOUT="${TIMEOUT:-300}"          # seconds to wait for each service to come back serving
POLL_INTERVAL="${POLL_INTERVAL:-10}"
BLOCKING=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --report-only)  BLOCKING=false; shift ;;
    --blocking)     BLOCKING=true; shift ;;
    --targets-file) TARGETS_FILE="$2"; shift 2 ;;
    --records-ws)   RECORDS_WS="$2"; shift 2 ;;
    --records)      RECORDS="$2"; shift 2 ;;
    --timeout)      TIMEOUT="$2"; shift 2 ;;
    -h|--help)      sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 64 ;;
  esac
done

log()  { printf '%s %s\n' "[refresh-fields]" "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
err()  { printf 'ERROR: %s\n' "$*" >&2; }

finish() {
  local code="$1"
  if [[ "$BLOCKING" == true ]]; then exit "$code"; fi
  [[ "$code" -ne 0 ]] && warn "report-only mode: exiting 0 despite the failure above (drop --report-only to gate)"
  exit 0
}

have_container() { docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q true; }

# Resolve the public URLs from the generated e2e targets, so this needs no inventory.
resolve_urls() {
  [[ -n "$RECORDS_WS" && -n "$RECORDS" ]] && return 0
  [[ -f "$TARGETS_FILE" ]] || return 1
  local ws rec
  ws=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["services"].get("recordsWs",""))' "$TARGETS_FILE" 2>/dev/null || true)
  rec=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["services"].get("records",""))' "$TARGETS_FILE" 2>/dev/null || true)
  RECORDS_WS="${RECORDS_WS:-$ws}"
  RECORDS="${RECORDS:-$rec}"
  [[ -n "$RECORDS_WS" ]]
}

# Number of entries in /index/fields. `[]` is a 200 with zero names, which is the whole
# point: counting the payload, not the status, is what makes this check honest.
field_count() {
  local n
  n=$(curl -sk --max-time 30 "${RECORDS_WS}/index/fields" 2>/dev/null | grep -o '"name"' | wc -l | tr -d ' ')
  printf '%s\n' "${n:-0}"
}

# Records visible to biocache-service. Distinguishes "the refresh failed" from "there is
# genuinely nothing indexed yet", which is not a failure and must not fail a build.
record_count() {
  curl -sk --max-time 30 "${RECORDS_WS}/occurrences/search?q=*:*&pageSize=0" 2>/dev/null \
    | sed -n 's/.*"totalRecords":[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1
}

wait_until() {  # wait_until <description> <command...>
  local what="$1"; shift
  local waited=0
  while [[ "$waited" -lt "$TIMEOUT" ]]; do
    if "$@"; then return 0; fi
    sleep "$POLL_INTERVAL"; waited=$((waited + POLL_INTERVAL))
    printf '.'
  done
  echo
  err "timed out after ${TIMEOUT}s waiting for ${what}"
  return 1
}

fields_served()      { [[ "$(field_count)" -gt 0 ]]; }
hub_search_ok()      { [[ "$(curl -sk -o /dev/null -w '%{http_code}' --max-time 30 "${RECORDS}/occurrences/search?q=*:*" 2>/dev/null)" == "200" ]]; }

restart_container() {
  local name="$1" svc="$2"
  log "restarting ${name}"
  # Via compose, so the container keeps the generated definition; plain `docker restart`
  # would work too but this stays inside the artefact Ansible produced.
  (cd "$COMPOSE_DIR" && docker compose restart "$svc") >/dev/null 2>&1 \
    || docker restart "$name" >/dev/null
}

# --- preconditions ---------------------------------------------------------------
if ! resolve_urls; then
  err "cannot resolve the records-ws URL (no --records-ws and no usable $TARGETS_FILE)"
  exit 2
fi
log "records-ws=${RECORDS_WS}  records=${RECORDS:-<unset>}"

rc=0

# --- 1. biocache-service: the field list ------------------------------------------
if have_container "$SERVICE_CONTAINER"; then
  n=$(field_count)
  if [[ "$n" -gt 0 ]]; then
    log "biocache-service already serves ${n} index fields — nothing to do"
  else
    docs=$(record_count)
    if [[ -z "$docs" || "$docs" -eq 0 ]]; then
      # No ingest has landed. Restarting now would just re-cache an empty list.
      log "index has no documents yet; nothing to refresh (this is the expected state before the first ingest)"
    else
      log "/index/fields is empty while the index holds ${docs} record(s) — stale boot cache, refreshing"
      restart_container "$SERVICE_CONTAINER" biocache-service
      if wait_until "biocache-service to serve a non-empty field list" fields_served; then
        echo; log "biocache-service now serves $(field_count) index fields"
      else
        err "/index/fields is STILL empty after a restart, with ${docs} record(s) indexed."
        err "this is no longer the known boot-cache race — check biocache-service's Solr connectivity"
        err "and that the collection it queries (solr.collection) is the one holding the data."
        rc=1
      fi
    fi
  fi
else
  log "no ${SERVICE_CONTAINER} on this host — skipping the field-list half"
fi

# --- 2. biocache-hub: the <alatag:message> NPE ------------------------------------
# Gated on records-ws serving fields, which may be another host, so wait on the public URL
# rather than on step 1 having run here. That gate is caution, not causation: it keeps a
# portal with no data from being restarted on every run for a condition a restart may not
# fix there. See the header for what has been ruled out as the mechanism.
if have_container "$HUB_CONTAINER"; then
  if [[ -z "$RECORDS" ]]; then
    warn "no records URL resolved; skipping the hub half"
  elif ! fields_served; then
    log "records-ws is not serving fields (yet); leaving ${HUB_CONTAINER} alone rather than"
    log "restarting it blind on a deployment that has no data"
  elif hub_search_ok; then
    log "hub search page already returns 200 — nothing to do"
  else
    log "records-ws serves fields but the hub search page does not return 200 — restarting the hub (known-good remedy; see header)"
    restart_container "$HUB_CONTAINER" biocache-hub
    if wait_until "the hub search page to return 200" hub_search_ok; then
      echo; log "hub search page returns 200"
    else
      err "the hub search page still does not return 200 after a restart."
      err "check the hub log: a recurring <alatag:message> NPE means the restart remedy no"
      err "longer works and the underlying hub bug needs the reproduction it still lacks;"
      err "anything else is a different hub failure."
      rc=1
    fi
  fi
else
  log "no ${HUB_CONTAINER} on this host — skipping the hub half"
fi

[[ "$rc" -eq 0 ]] && log "PASS — records search is served by a warm field list"
finish "$rc"

#!/usr/bin/env bash
#
# verify-deployment.sh — Layer 1 deployment-correctness gate.
#
# Asserts the deployment's Gatus "Deep checks" group (inventory-generated functional API
# checks) is healthy. These checks are data-independent (q=*:*, q=Acacia, geoserver/web...),
# so this works against any inventory. Complements the Ansible container-health gate
# (wait-for-health.sh) and the Cypress smoke suite (Layer 2).
#
# DATA-DEPENDENT CHECKS ARE DELIBERATELY OUT OF SCOPE. Gatus also carries a "Data checks"
# group (records-ws index fields, records search page) which is red on any portal that has
# no records yet. That is a legitimate install — a docker-compose portal has no
# dataResources, runs no e2e suite, and may not deploy Airflow at all — so an empty index
# must never be reported here as a failed deployment. What asserts those, and only after
# an ingest has actually run, is scripts/refresh-biocache-fields.sh.
#
# Endpoints and their URLs are NOT hardcoded here: they come from Gatus (which is itself
# generated from the inventory). The --direct fallback reads the inventory-generated
# e2e-targets.json manifest instead. With --target, that manifest is read FROM THE TARGET
# over ssh: it is written by the deploy onto the deployed host, not onto the machine
# running this script.
#
# Exit codes:  0 = all critical healthy   1 = critical endpoint(s) unhealthy   2 = Gatus/targets unreachable
# Report-only by default (always exits 0, prints WARN); pass --blocking for honest exit codes.
#
# Because report-only flattens every outcome to 0, the last line is the verdict, not the
# exit status. It is always exactly one of GATE-PASSED / GATE-FAILED / GATE-NOT-RUN, and
# a caller that gates on this script MUST require GATE-PASSED rather than assume it.
#
# Usage:
#   scripts/verify-deployment.sh [--target HOST] [--blocking] [--direct]
#                                [--gatus-host FQDN] [--targets-file PATH] [--timeout SEC]
#                                [--connect-timeout SEC]
set -euo pipefail

TARGET="localhost"
BLOCKING=false
DIRECT=false
GATUS_HOST=""
TARGETS_FILE="${CYPRESS_TARGETS_FILE:-/data/docker-compose/e2e-targets.json}"
TARGETS_FILE_EXPLICIT=false
TIMEOUT=300
# How long to keep trying before concluding this target simply has no route to Gatus.
# Distinct from TIMEOUT on purpose: once Gatus answers, the remaining wait is for its
# checks to evaluate (~1m interval) and deserves the full budget. Never answering at all
# is a routing fact, not a warm-up -- verified on the live cluster, where gatus runs on
# host 3 and hosts 1 and 2 never resolve the vhost no matter how long they are given.
# Spending 300s per such host is how a caller that tries several of them runs out of day.
CONNECT_TIMEOUT=45
GROUP="Deep checks"

[[ "${GATUS_GATE_BLOCKING:-}" == "true" ]] && BLOCKING=true

usage() { sed -n '2,32p' "$0"; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)       TARGET="$2"; shift 2 ;;
    --blocking)     BLOCKING=true; shift ;;
    --report-only)  BLOCKING=false; shift ;;
    --direct)       DIRECT=true; shift ;;
    --gatus-host)   GATUS_HOST="$2"; shift 2 ;;
    --targets-file) TARGETS_FILE="$2"; TARGETS_FILE_EXPLICIT=true; shift 2 ;;
    --timeout)      TIMEOUT="$2"; shift 2 ;;
    --connect-timeout) CONNECT_TIMEOUT="$2"; shift 2 ;;
    -h|--help)      usage ;;
    *) echo "Unknown arg: $1" >&2; exit 64 ;;
  esac
done

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
err()  { printf 'ERROR: %s\n' "$*" >&2; }

# Every exit goes through here, and every exit prints exactly one marker line. The bug
# this closes (#385..#389) was not that the gate failed -- it was that a gate which never
# ran and a gate which passed produced logs a reader could not tell apart, so a build
# stayed green on a check that had exited at argument resolution. Callers assert on the
# marker, never on the exit status: report-only mode turns every failure into a 0.
#   GATE-PASSED   the checks ran and were healthy
#   GATE-FAILED   the checks ran and something is unhealthy  (a real deployment problem)
#   GATE-NOT-RUN  the checks never ran                       (a problem with the gate)
finish() {
  local code="$1" detail="${2:-}"
  case "$code" in
    0) log "GATE-PASSED: ${detail:-all critical endpoints healthy}" ;;
    1) log "GATE-FAILED: ${detail:-critical endpoint(s) unhealthy}" ;;
    *) log "GATE-NOT-RUN: ${detail:-gate could not be evaluated}" ;;
  esac
  if [[ "$BLOCKING" == true ]]; then
    exit "$code"
  fi
  [[ "$code" -ne 0 ]] && warn "report-only mode: exiting 0 despite issues above (pass --blocking to gate)"
  exit 0
}

is_remote() { [[ "$TARGET" != "localhost" && "$TARGET" != "127.0.0.1" ]]; }

command -v jq >/dev/null || finish 2 "jq is not installed on this machine"

# The manifest lives on the DEPLOYED host, not on whoever runs this script. --target
# already routes every probe through ssh, so resolution has to travel the same way:
# reading a local /data/docker-compose while probing a remote host is how this gate
# spent four builds dying at argument resolution on a Jenkins agent that has no
# /data/docker-compose at all. An explicit --targets-file always wins, and so does a
# manifest that is already on this disk: `--target <own inventory name>` from ON the
# deployed host is a legitimate way to call this, and ssh-ing to self to fetch a file
# lying right there would just re-hollow the gate wherever root-to-self ssh is not set up.
if is_remote && [[ "$TARGETS_FILE_EXPLICIT" == false ]] && [[ ! -f "$TARGETS_FILE" ]]; then
  REMOTE_TARGETS="$(mktemp)"
  trap 'rm -f "$REMOTE_TARGETS"' EXIT
  if ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$TARGET" \
        "cat $TARGETS_FILE" > "$REMOTE_TARGETS" 2>/dev/null && [[ -s "$REMOTE_TARGETS" ]]; then
    log "targets manifest read from ${TARGET}:${TARGETS_FILE}"
    TARGETS_FILE="$REMOTE_TARGETS"
  else
    err "could not read $TARGETS_FILE from $TARGET over ssh"
  fi
fi

# Resolve the Gatus FQDN (for the Host header / public URL). Prefer the generated manifest.
if [[ -z "$GATUS_HOST" ]]; then
  if [[ -f "$TARGETS_FILE" ]]; then
    GATUS_HOST="$(jq -r '.services.gatus // ""' "$TARGETS_FILE" 2>/dev/null | sed -E 's#^https?://##; s#/.*$##')"
  fi
  # No hardcoded fallback: guessing a domain here silently verifies someone else's
  # deployment. Fail and let the caller say which host to check.
  if [[ -z "$GATUS_HOST" ]]; then
    err "Cannot resolve GATUS_HOST: $TARGETS_FILE is missing or has no .services.gatus."
    err "Pass --gatus-host <fqdn> explicitly, or run the deploy so the targets manifest is generated."
    finish 2 "cannot resolve GATUS_HOST from $TARGETS_FILE"
  fi
fi

# Fetch a URL path from Gatus. On a host we hit https://localhost with a Host header (works
# before public DNS/proxy is warm); locally we do the same; remotely we go over ssh.
gatus_fetch() {
  local path="$1"
  if [[ "$TARGET" == "localhost" || "$TARGET" == "127.0.0.1" ]]; then
    curl -fsSk --max-time 15 -H "Host: ${GATUS_HOST}" "https://localhost${path}"
  else
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$TARGET" \
      "curl -fsSk --max-time 15 -H 'Host: ${GATUS_HOST}' 'https://localhost${path}'"
  fi
}

# Generic HTTP status of an absolute URL, fetched from the target's network namespace.
http_status() {
  local url="$1" host path
  host="$(printf '%s' "$url" | sed -E 's#^https?://([^/]+).*#\1#')"
  path="/$(printf '%s' "$url" | sed -E 's#^https?://[^/]+/?##')"
  if [[ "$TARGET" == "localhost" || "$TARGET" == "127.0.0.1" ]]; then
    curl -o /dev/null -sk --max-time 15 -H "Host: ${host}" -w '%{http_code}' "https://localhost${path}"
  else
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$TARGET" \
      "curl -o /dev/null -sk --max-time 15 -H 'Host: ${host}' -w '%{http_code}' 'https://localhost${path}'"
  fi
}

# ---------------------------------------------------------------------------
# --direct: curl representative functional paths per service from the manifest
# (deterministic, immediate, independent of Gatus). Mirrors the Deep checks.
# ---------------------------------------------------------------------------
if [[ "$DIRECT" == true ]]; then
  [[ -f "$TARGETS_FILE" ]] || { err "targets file not found: $TARGETS_FILE"; finish 2 "targets file not found: $TARGETS_FILE"; }
  log "Direct mode: probing functional endpoints from $TARGETS_FILE (target=$TARGET)"
  declare -A PATHS=(
    [recordsWs]="/occurrences/search?q=*:*&pageSize=0"
    [species]="/search?q=Acacia"
    [collections]="/ws"
    [spatial]="/ws/fields"
    [lists]="/ws/speciesList"
    [logger]="/service/logger/reasons"
  )
  fails=0; checked=0
  for svc in "${!PATHS[@]}"; do
    base="$(jq -r --arg s "$svc" '.services[$s] // ""' "$TARGETS_FILE")"
    [[ -z "$base" ]] && continue
    checked=$((checked+1))
    st="$(http_status "${base}${PATHS[$svc]}" || echo 000)"
    if [[ "$st" =~ ^[23] ]]; then
      log "  [OK]   $svc -> $st"
    else
      err "  [FAIL] $svc -> $st  (${base}${PATHS[$svc]})"
      fails=$((fails+1))
    fi
  done
  [[ "$checked" -eq 0 ]] && { err "no services found in manifest"; finish 2 "no services found in manifest"; }
  if [[ "$fails" -gt 0 ]]; then err "$fails/$checked functional endpoint(s) unhealthy"; finish 1 "$fails/$checked functional endpoint(s) unhealthy"; fi
  finish 0 "all $checked functional endpoint(s) healthy"
fi

# ---------------------------------------------------------------------------
# Default: read Gatus verdicts for the "Deep checks" group, polling for freshness
# (deep checks run on a ~1m interval; right after deploy Gatus may not have run yet).
# ---------------------------------------------------------------------------
log "Verifying Gatus '$GROUP' via ${GATUS_HOST} (target=$TARGET, timeout=${TIMEOUT}s)"

# Normalize the API to a bare array (older Gatus returns [...], newer may wrap in .endpoints).
JQ_NORM='if type=="array" then . else (.endpoints // []) end'

deadline=$(( SECONDS + TIMEOUT ))
connect_deadline=$(( SECONDS + CONNECT_TIMEOUT ))
raw=""
ever_reachable=false
while :; do
  if raw="$(gatus_fetch "/api/v1/endpoints/statuses" 2>/dev/null)"; then
    ever_reachable=true
    # Count Deep-checks endpoints and how many have at least one result yet.
    counts="$(printf '%s' "$raw" | jq -r "[ ($JQ_NORM)[] | select(.group==\"$GROUP\") ] | \"\(length) \([.[]|select((.results|length)>0)]|length)\"" 2>/dev/null || echo "0 0")"
    total="${counts%% *}"; fresh="${counts##* }"
    if [[ "$total" -gt 0 && "$fresh" -eq "$total" ]]; then
      break
    fi
    log "  waiting for Gatus to evaluate '$GROUP' ($fresh/$total ready)..."
  else
    log "  Gatus not reachable yet, retrying..."
  fi
  if [[ "$ever_reachable" == false && "$SECONDS" -ge "$connect_deadline" ]]; then
    err "Gatus never answered via $TARGET in ${CONNECT_TIMEOUT}s -- this target has no route to ${GATUS_HOST}."
    err "Gatus runs on one machine of the cluster; ask that one, or a host whose nginx serves its vhost."
    finish 2 "no route to Gatus (${GATUS_HOST}) from $TARGET"
  fi
  if [[ "$SECONDS" -ge "$deadline" ]]; then
    err "timed out waiting for Gatus '$GROUP' (reachable=$([[ -n "$raw" ]] && echo yes || echo no))"
    finish 2 "timed out after ${TIMEOUT}s waiting for Gatus '$GROUP' on $GATUS_HOST"
  fi
  sleep 10
done

# Evaluate: latest result per endpoint must be success.
unhealthy="$(printf '%s' "$raw" | jq -r "($JQ_NORM)[] | select(.group==\"$GROUP\") | select((.results[-1].success)==false) | .name")"
total="$(printf '%s' "$raw" | jq -r "[ ($JQ_NORM)[] | select(.group==\"$GROUP\") ] | length")"

if [[ -n "$unhealthy" ]]; then
  n="$(printf '%s\n' "$unhealthy" | grep -c .)"
  err "$n/$total '$GROUP' endpoint(s) unhealthy:"
  printf '%s\n' "$unhealthy" | sed 's/^/  [FAIL] /' >&2
  finish 1 "$n/$total '$GROUP' endpoint(s) unhealthy"
fi

finish 0 "all $total '$GROUP' endpoint(s) healthy"

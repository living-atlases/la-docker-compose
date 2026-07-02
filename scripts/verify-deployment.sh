#!/usr/bin/env bash
#
# verify-deployment.sh — Layer 1 deployment-correctness gate.
#
# Asserts the deployment's Gatus "Deep checks" group (inventory-generated functional API
# checks) is healthy. These checks are data-independent (q=*:*, q=Acacia, geoserver/web...),
# so this works against any inventory. Complements the Ansible container-health gate
# (wait-for-health.sh) and the Cypress smoke suite (Layer 2).
#
# Endpoints and their URLs are NOT hardcoded here: they come from Gatus (which is itself
# generated from the inventory). The --direct fallback reads the inventory-generated
# e2e-targets.json manifest instead.
#
# Exit codes:  0 = all critical healthy   1 = critical endpoint(s) unhealthy   2 = Gatus/targets unreachable
# Report-only by default (always exits 0, prints WARN); pass --blocking for honest exit codes.
#
# Usage:
#   scripts/verify-deployment.sh [--target HOST] [--blocking] [--direct]
#                                [--gatus-host FQDN] [--targets-file PATH] [--timeout SEC]
set -euo pipefail

TARGET="localhost"
BLOCKING=false
DIRECT=false
GATUS_HOST=""
TARGETS_FILE="${CYPRESS_TARGETS_FILE:-/data/docker-compose/e2e-targets.json}"
TIMEOUT=300
GROUP="Deep checks"

[[ "${GATUS_GATE_BLOCKING:-}" == "true" ]] && BLOCKING=true

usage() { sed -n '2,20p' "$0"; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)       TARGET="$2"; shift 2 ;;
    --blocking)     BLOCKING=true; shift ;;
    --report-only)  BLOCKING=false; shift ;;
    --direct)       DIRECT=true; shift ;;
    --gatus-host)   GATUS_HOST="$2"; shift 2 ;;
    --targets-file) TARGETS_FILE="$2"; shift 2 ;;
    --timeout)      TIMEOUT="$2"; shift 2 ;;
    -h|--help)      usage ;;
    *) echo "Unknown arg: $1" >&2; exit 64 ;;
  esac
done

command -v jq >/dev/null || { echo "ERROR: jq is required" >&2; exit 2; }

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
err()  { printf 'ERROR: %s\n' "$*" >&2; }

# Resolve the Gatus FQDN (for the Host header / public URL). Prefer the generated manifest.
if [[ -z "$GATUS_HOST" ]]; then
  if [[ -f "$TARGETS_FILE" ]]; then
    GATUS_HOST="$(jq -r '.services.gatus // ""' "$TARGETS_FILE" 2>/dev/null | sed -E 's#^https?://##; s#/.*$##')"
  fi
  GATUS_HOST="${GATUS_HOST:-gatus.l-a.site}"
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

finish() {
  local code="$1"
  if [[ "$BLOCKING" == true ]]; then
    exit "$code"
  fi
  [[ "$code" -ne 0 ]] && warn "report-only mode: exiting 0 despite issues above (pass --blocking to gate)"
  exit 0
}

# ---------------------------------------------------------------------------
# --direct: curl representative functional paths per service from the manifest
# (deterministic, immediate, independent of Gatus). Mirrors the Deep checks.
# ---------------------------------------------------------------------------
if [[ "$DIRECT" == true ]]; then
  [[ -f "$TARGETS_FILE" ]] || { err "targets file not found: $TARGETS_FILE"; finish 2; }
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
  [[ "$checked" -eq 0 ]] && { err "no services found in manifest"; finish 2; }
  if [[ "$fails" -gt 0 ]]; then err "$fails/$checked functional endpoint(s) unhealthy"; finish 1; fi
  log "All $checked functional endpoint(s) healthy."
  finish 0
fi

# ---------------------------------------------------------------------------
# Default: read Gatus verdicts for the "Deep checks" group, polling for freshness
# (deep checks run on a ~1m interval; right after deploy Gatus may not have run yet).
# ---------------------------------------------------------------------------
log "Verifying Gatus '$GROUP' via ${GATUS_HOST} (target=$TARGET, timeout=${TIMEOUT}s)"

# Normalize the API to a bare array (older Gatus returns [...], newer may wrap in .endpoints).
JQ_NORM='if type=="array" then . else (.endpoints // []) end'

deadline=$(( SECONDS + TIMEOUT ))
raw=""
while :; do
  if raw="$(gatus_fetch "/api/v1/endpoints/statuses" 2>/dev/null)"; then
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
  if [[ "$SECONDS" -ge "$deadline" ]]; then
    err "timed out waiting for Gatus '$GROUP' (reachable=$([[ -n "$raw" ]] && echo yes || echo no))"
    finish 2
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
  finish 1
fi

log "All $total '$GROUP' endpoint(s) healthy."
finish 0

#!/usr/bin/env bash
# Validate biocache-service runtime dependencies from INSIDE its network namespace.
#
# Why this exists
# ---------------
# biocache-service is the usual "last one standing" UNHEALTHY service in a
# multi-host docker-compose deployment. Its healthcheck (`curl /index/fields`)
# only goes green once the Spring `searchDao` bean initialises, which needs a
# live SolrCloud (ZooKeeper + Solr nodes). In a non-swarm multi-host setup the
# SolrCloud ensemble advertises *internal* container names (la_solrcloud_zoo_<n>,
# la_solrcloud_solr_<n>) that only resolve cross-host if injected into the
# container's /etc/hosts. When they aren't, biocache-service times out connecting
# to ZooKeeper and never starts — exactly the failure seen in Jenkins build #193:
#
#     Could not connect to ZooKeeper la_solrcloud_zoo_1:2181 within 15000 ms
#
# This script is a docker-compose-aware port of the ALA wiki troubleshooting
# steps (Troubleshooting-biocache-service) and the dependency checker gist
# (gist.github.com/vjrj/dc584ea7a203161f8e1737c3a8d744c4). The crucial difference
# vs. running the checks on the host: every probe runs via `docker exec` so it
# sees the exact DNS + connectivity biocache-service itself sees. Running on the
# host would resolve different names and hide the bug.
#
# It reads the *deployed* biocache-config.properties and checks:
#   1. ZooKeeper / Solr (SolrCloud) connect strings  -> zookeeper.address, solr.home
#   2. SolrCloud per-node container names resolve cross-host (the #193 root cause)
#   3. Cassandra hosts                                -> cassandra.hosts:9042
#   4. Dependent HTTP services (collectory, spatial, image, logger, ...) -> 2xx/3xx
#
# Usage:
#   scripts/validate-biocache-deps.sh [--container NAME] [--config PATH]
#                                     [--timeout SEC] [--output FILE] [--verbose]
#
#   --container  biocache-service container name      (default: la_biocache-service)
#   --config     config path inside the container     (default: /data/biocache/config/biocache-config.properties)
#   --timeout    per-probe timeout in seconds          (default: 5)
#   --output     also write a plain-text report here   (e.g. for the diagnostics bundle)
#   --verbose    print extra detail
#
# Exit codes: 0 all checks passed | 1 one or more failed | 2 bad args | 3 docker/container unavailable
set -euo pipefail

CONTAINER="la_biocache-service"
CONFIG_PATH="/data/biocache/config/biocache-config.properties"
TIMEOUT=5
OUTFILE=""
VERBOSE=false

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'

_plain() { [[ -n "$OUTFILE" ]] && printf '%s\n' "$*" >> "$OUTFILE" || true; }
pass()    { echo -e "${GREEN}✔ PASS${RESET} $*"; _plain "PASS  $*"; }
fail()    { echo -e "${RED}✗ FAIL${RESET} $*"; _plain "FAIL  $*"; FAILURES=$((FAILURES + 1)); }
warn()    { echo -e "${YELLOW}⚠ WARN${RESET} $*"; _plain "WARN  $*"; }
info()    { echo -e "  $*"; _plain "      $*"; }
section() { echo -e "\n${CYAN}${BOLD}=== $* ===${RESET}"; _plain ""; _plain "=== $* ==="; }

FAILURES=0

# ── Args ──────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --container) CONTAINER="$2"; shift 2;;
    --config)    CONFIG_PATH="$2"; shift 2;;
    --timeout)   TIMEOUT="$2"; shift 2;;
    --output)    OUTFILE="$2"; shift 2;;
    --verbose|-v) VERBOSE=true; shift;;
    -h|--help)   sed -n '2,30p' "$0"; exit 0;;
    *) echo "Unknown argument: $1" >&2; exit 2;;
  esac
done

if [[ -n "$OUTFILE" ]]; then
  mkdir -p "$(dirname "$OUTFILE")"
  : > "$OUTFILE"
  _plain "biocache-service dependency validation — container=$CONTAINER"
fi

# ── Preflight ─────────────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  echo -e "${RED}ERROR: docker not found on host${RESET}" >&2; exit 3
fi
if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)" != "true" ]]; then
  echo -e "${RED}ERROR: container '$CONTAINER' is not running — nothing to probe.${RESET}" >&2
  echo "  Check: docker ps -a | grep $CONTAINER ; docker logs $CONTAINER" >&2
  exit 3
fi

# Run a command inside the biocache-service network namespace.
cx() { docker exec "$CONTAINER" "$@"; }

# ── Load deployed config ──────────────────────────────────────────────────────
CFG="$(cx cat "$CONFIG_PATH" 2>/dev/null || true)"
if [[ -z "$CFG" ]]; then
  echo -e "${RED}ERROR: could not read $CONFIG_PATH inside $CONTAINER${RESET}" >&2
  exit 3
fi

# getprop KEY -> first value (regex-safe key, trims whitespace/CR)
getprop() {
  local key_re; key_re="$(printf '%s' "$1" | sed 's/[.[\*^$/]/\\&/g')"
  printf '%s\n' "$CFG" | sed -n -E "s/^[[:space:]]*${key_re}[[:space:]]*=[[:space:]]*(.*)$/\1/p" | head -n1 | tr -d '\r'
}

# probe HOST PORT LABEL — TCP reachability via curl, run in the container netns.
# curl http:// distinguishes the cases we care about by exit code:
#   0/18/52/55/56 = TCP connected (HTTP or a non-HTTP port that accepted the socket)
#   6  = DNS resolution failed  (THE cross-host alias bug)
#   7  = connection refused     (service down / wrong port)
#   28 = timed out              (firewall / host unreachable)
probe() {
  local host="$1" port="$2" label="$3" rc=0
  set +e
  cx curl -s -m "$TIMEOUT" -o /dev/null "http://${host}:${port}/" >/dev/null 2>&1
  rc=$?
  set -e
  case "$rc" in
    0|18|52|55|56) pass "$label — ${host}:${port} reachable (TCP open)";;
    6)  fail "$label — cannot resolve '${host}' inside container (missing cross-host /etc/hosts alias)";;
    7)  fail "$label — ${host}:${port} connection refused (service down or wrong port)";;
    28) fail "$label — ${host}:${port} timed out (firewall or host unreachable)";;
    *)  fail "$label — ${host}:${port} unreachable (curl rc=${rc})";;
  esac
}

# http_check URL — HTTP status of a dependent service (wiki step 5 / gist loop).
http_check() {
  local url="$1" code="000" rc=0
  set +e
  code=$(cx curl -s -m "$TIMEOUT" -o /dev/null -w '%{http_code}' "$url" 2>/dev/null); rc=$?
  set -e
  if [[ "$rc" -eq 6 ]]; then fail "$url — DNS resolution failed inside container"; return; fi
  case "$code" in
    200|301|302|303|307|308|401|403) pass "$url — HTTP $code";;
    404) warn "$url — HTTP 404 (check path)";;
    000) fail "$url — no response (curl rc=$rc)";;
    5*)  fail "$url — HTTP $code (server error)";;
    *)   warn "$url — HTTP $code";;
  esac
}

# Split a ZK/Solr connect string ("h1:2181,h2:2181/chroot") into host:port lines.
hostports() { printf '%s' "$1" | tr ', ' '\n' | sed 's#/.*##' | grep -v '^$' || true; }

echo -e "${BOLD}biocache-service dependency validation${RESET}  (container: ${CONTAINER})"
$VERBOSE && info "config: $CONFIG_PATH"

# ── 1. ZooKeeper / Solr (SolrCloud) ───────────────────────────────────────────
section "1. SolrCloud connectivity (zookeeper.address / solr.home)"
ZK_ADDR="$(getprop 'zookeeper.address')"
SOLR_HOME="$(getprop 'solr.home')"
$VERBOSE && { info "zookeeper.address = ${ZK_ADDR:-<empty>}"; info "solr.home        = ${SOLR_HOME:-<empty>}"; }

zoo_names=""
if [[ -z "$ZK_ADDR$SOLR_HOME" ]]; then
  warn "Neither zookeeper.address nor solr.home set — biocache cannot reach SolrCloud"
else
  for hp in $(hostports "${ZK_ADDR},${SOLR_HOME}" | sort -u); do
    host="${hp%:*}"; port="${hp##*:}"; [[ "$host" == "$port" ]] && port=2181
    probe "$host" "$port" "ZK"
    [[ "$host" == la_solrcloud_zoo_* ]] && zoo_names="$zoo_names $host"
  done
fi

# ── 2. SolrCloud per-node names resolve cross-host (the #193 root cause) ───────
section "2. SolrCloud node-name resolution (cross-host /etc/hosts)"
# Even when biocache reaches ZooKeeper, ZK returns Solr live-nodes registered as
# la_solrcloud_solr_<n>:8983 — these must ALSO resolve. Probe the zoo names found
# above plus their solr siblings.
if [[ -z "$zoo_names" ]]; then
  info "No 'la_solrcloud_zoo_*' names in config (single-host or normalised) — skipping."
else
  for zk in $zoo_names; do
    n="${zk##*_}"
    probe "$zk" 2181 "ZK node $zk"
    probe "la_solrcloud_solr_${n}" 8983 "Solr node la_solrcloud_solr_${n}"
  done
fi

# ── 3. Cassandra ──────────────────────────────────────────────────────────────
section "3. Cassandra (cassandra.hosts:9042)"
CASS="$(getprop 'cassandra.hosts')"
CASS_PORT="$(getprop 'cassandra.port')"; CASS_PORT="${CASS_PORT:-9042}"
if [[ -z "$CASS" ]]; then
  warn "cassandra.hosts not set"
else
  for h in $(printf '%s' "$CASS" | tr ', ' '\n' | grep -v '^$'); do
    probe "$h" "$CASS_PORT" "Cassandra"
  done
fi

# ── 4. Dependent HTTP services (wiki step 5 / gist) ───────────────────────────
section "4. Dependent HTTP services"
urls="$(printf '%s\n' "$CFG" \
  | grep -oE 'https?://[^[:space:]"'"'"',]+' \
  | sed 's#/$##' | sort -u \
  | grep -vE 'localhost|127\.0\.0\.1|biocache-media|irmng' || true)"
if [[ -z "$urls" ]]; then
  warn "No external http(s) URLs found in config"
else
  while IFS= read -r u; do [[ -n "$u" ]] && http_check "$u"; done <<< "$urls"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [[ $FAILURES -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}✔ ALL biocache-service DEPENDENCY CHECKS PASSED${RESET}"; _plain "RESULT: ALL PASSED"
  exit 0
else
  echo -e "${RED}${BOLD}✗ $FAILURES biocache-service DEPENDENCY CHECK(S) FAILED${RESET}"; _plain "RESULT: $FAILURES FAILED"
  echo -e "${YELLOW}Hint:${RESET} a 'cannot resolve' on la_solrcloud_zoo_*/la_solrcloud_solr_* means the"
  echo -e "      SolrCloud node names are not injected into this container's /etc/hosts"
  echo -e "      (cross-host alias gap in generate-compose.yml). See plan / build #193."
  exit 1
fi

#!/bin/bash
#
# test-java-opts-wiring.sh
#
# `<service>_max_memory` only reaches a JVM if the service's compose file reads the
# <PREFIX>_JAVA_OPTS line the .env emits for it, AND the image's command actually passes
# JAVA_OPTS to java. test-java-opts-env.sh covers the .env side; this covers the other.
#
# Found on gbif.es (2026-09-29): namematching-service and sensitive-data-service set a
# literal `JAVA_OPTS=-Xmx2g -Xms1g`, so their _max_memory did nothing. Worse, neither
# image reads JAVA_OPTS at all -- namematching freezes `java -Xmx2g ...` into its CMD,
# and the legacy SDS image runs a bare `java -jar`, i.e. Java 8's default max heap of
# 1/4 of the host RAM (5.6 GB on a 22 GB node), invisible to the heap budget.
#
# Two checks:
#   1. No service template hardcodes -Xmx in its environment. Memory comes from .env.
#   2. The two images that ignore JAVA_OPTS: render the template, run it through
#      `docker compose config` with a .env, and assert the heap from .env is in the
#      final command, and that JAVA_OPTS survives as a runtime variable rather than an
#      empty compose interpolation (`config` prints it re-escaped, as $$JAVA_OPTS).
#      Also with the variable absent: the default applies.
#
# Usage: bash scripts/test-java-opts-wiring.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICES="$REPO_ROOT/roles/la-compose/templates/docker-compose/services"
fail=0
pass() { echo "[PASS] $*"; }
bad() { echo "[FAIL] $*"; fail=1; }

# --- 1. no literal heap in any service environment -----------------------------------
hard=$(grep -nE '^[[:space:]]*-?[[:space:]]*[A-Z_]*JAVA_OPTS[=:][[:space:]]*"?-X' "$SERVICES"/*.yml.j2 || true)
if [ -z "$hard" ]; then
    pass "no service template hardcodes -Xmx in JAVA_OPTS"
else
    bad "hardcoded heap in a service template (use \${<PREFIX>_JAVA_OPTS}):"
    echo "$hard"
fi

# --- 2. the images that ignore JAVA_OPTS -----------------------------------------------
PYTHON=""
for candidate in "${VENV_MOLECULE:-/nonexistent}/bin/python" "$REPO_ROOT/.venv-molecule/bin/python" python3; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import jinja2' 2>/dev/null; then
        PYTHON="$candidate"; break
    fi
done
[ -n "$PYTHON" ] || { echo "no python with jinja2"; exit 1; }
if ! docker compose version >/dev/null 2>&1; then
    echo "[SKIP] docker compose not available: render checks skipped"
    exit "$fail"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

render() {  # $1 template -> $tmp/compose.yml
    "$PYTHON" - "$SERVICES/$1" "$tmp/compose.yml" <<'PYTHON'
import sys
from jinja2 import ChainableUndefined, Environment
src, dst = sys.argv[1], sys.argv[2]
env = Environment(undefined=ChainableUndefined)
out = env.from_string(open(src).read()).render(
    data_dir="/data", docker_network="internal", sds_nameindex_datestamp="20210811",
    namematching_service_port=9179, namematching_admin_port=9180,
    sensitive_data_service_port=9189, sensitive_data_admin_port=9190)
open(dst, "w").write(out + "\nnetworks:\n  internal: {}\n")
PYTHON
}

command_of() {  # $1 service, $2 env file (may be empty) -> final command, one line
    local args=(-f "$tmp/compose.yml" --profile full)
    if [ -n "$2" ]; then args+=(--env-file "$2"); else args+=(--env-file /dev/null); fi
    docker compose "${args[@]}" config --format json 2>/dev/null |
        "$PYTHON" -c 'import json,sys; s=json.load(sys.stdin)["services"][sys.argv[1]]; print(" ".join(s.get("command") or [])); print(" ".join(s["environment"]["JAVA_OPTS"].split()))' "$1"
}

check() {  # $1 template, $2 service, $3 .env var
    render "$1"
    printf '%s=-Djava.awt.headless=true -Xmx1536m -Xms1g -Dfoo=bar\n' "$3" > "$tmp/.env"
    out=$(command_of "$2" "$tmp/.env") || { bad "$2: docker compose config failed"; return; }
    cmd=$(echo "$out" | head -1); opts=$(echo "$out" | tail -1)
    [[ "$opts" == *"-Xmx1536m"* ]] && pass "$2: JAVA_OPTS comes from $3" || bad "$2: JAVA_OPTS='$opts'"
    [[ "$cmd" == *'exec java $$JAVA_OPTS '* ]] && pass "$2: command passes \$JAVA_OPTS to java" || bad "$2: command='$cmd'"
    [[ "$cmd" != *"-Xmx"* ]] && pass "$2: command has no frozen -Xmx" || bad "$2: command='$cmd'"
    out=$(command_of "$2" "") || { bad "$2: config without .env failed"; return; }
    opts=$(echo "$out" | tail -1)
    [[ "$opts" == "-Xmx2g -Xms1g" ]] && pass "$2: without $3 the default heap applies" || bad "$2: default JAVA_OPTS='$opts'"
}

check namematching-service.yml.j2 namematching-service NAMEMATCHINGSERVICE_JAVA_OPTS
check sensitive-data-service.yml.j2 sensitive-data-service SENSITIVEDATASERVICE_JAVA_OPTS

exit "$fail"

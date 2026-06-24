#!/usr/bin/env bash
# check-service-configs.sh — lint generated docker-compose service fragments for
# config-mount bugs that otherwise only surface at container start (crash-loop).
#
# Catches two recurring classes seen in la-docker-compose:
#   1) CONFIG NOT GENERATED/MOUNTED: a `:ro` mount whose host source dir is
#      missing or empty  => the container starts with no config and crash-loops
#      ("Config data location does not exist", "config.yml not found").
#      Root cause: asymmetric service_aliases gates skipping config generation.
#   2) SOURCE/TARGET PATH MISMATCH (heuristic, STRICT=1 only): for a `.../config`
#      mount, the path segment before `/config` differs between host source and
#      container target (e.g. ala-sensitive-data-SERVICE vs ...-SERVER). Only a
#      bug if the app reads from the host-source naming. Confirmed real for SDS
#      (app read -service, mount targeted -server -> crash). KNOWN-OK (app reads
#      the -server/target path, ran healthy): namematching-service, logger-service.
#      So this check is OFF by default to avoid false positives; the runtime
#      healthcheck catches genuine target mismatches anyway.
#
# Usage: scripts/check-service-configs.sh [COMPOSE_DIR]      (STRICT=1 for check 2)
#   COMPOSE_DIR defaults to /data/docker-compose
# Exit: 0 all good · 1 one or more FAILs · 2 bad args / no fragments

set -u
COMPOSE_DIR="${1:-/data/docker-compose}"
SERVICES_DIR="$COMPOSE_DIR/services"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
fails=0; warns=0; checked=0

if [ ! -d "$SERVICES_DIR" ]; then
    echo -e "${RED}Error:${NC} no services/ dir under $COMPOSE_DIR" >&2
    exit 2
fi

echo -e "${CYAN}${BOLD}Linting config mounts in $SERVICES_DIR${NC}"

for frag in "$SERVICES_DIR"/*.yml; do
    [ -e "$frag" ] || continue
    svc="$(basename "$frag" .yml)"
    # Volume lines look like:   - "HOST:CONTAINER[:ro|:rw]"
    while IFS= read -r line; do
        mount="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*"?//; s/"?[[:space:]]*$//')"
        case "$mount" in *:*) ;; *) continue ;; esac
        src="${mount%%:*}"; rest="${mount#*:}"; dst="${rest%%:*}"
        # Only care about config mounts
        case "$dst" in *dir*|*/config*|*/config) ;; *) continue ;; esac
        case "$dst" in */config|*/config/) ;; *) continue ;; esac
        checked=$((checked+1))

        # Check 1: host source exists and is non-empty
        if [ ! -d "$src" ]; then
            echo -e "  ${RED}FAIL${NC} [$svc] config source dir missing: ${BOLD}$src${NC}  (-> $dst)"
            fails=$((fails+1)); continue
        fi
        if [ -z "$(ls -A "$src" 2>/dev/null)" ]; then
            echo -e "  ${RED}FAIL${NC} [$svc] config source dir empty: ${BOLD}$src${NC}  (-> $dst)"
            fails=$((fails+1)); continue
        fi

        # Check 2 (STRICT only, heuristic): parent of .../config should match src vs target
        if [ "${STRICT:-0}" = "1" ]; then
            sparent="$(basename "$(dirname "$src")")"
            dparent="$(basename "$(dirname "$dst")")"
            if [ "$sparent" != "$dparent" ]; then
                echo -e "  ${YELLOW}WARN${NC} [$svc] config src/target parent differ: ${BOLD}$sparent${NC} (host) vs ${BOLD}$dparent${NC} (container) — verify app's config path (known-OK: namematching, logger)"
                warns=$((warns+1)); continue
            fi
        fi
        echo -e "  ${GREEN}ok${NC}   [$svc] $src -> $dst"
    done < <(grep -E '^[[:space:]]*-[[:space:]]*"?[^"]*:[^"]*"?[[:space:]]*$' "$frag")
done

echo
echo -e "${CYAN}Checked $checked config mount(s): ${GREEN}$((checked-fails-warns)) ok${NC}, ${YELLOW}$warns warn${NC}, ${RED}$fails fail${NC}"
[ "$fails" -gt 0 ] && exit 1
exit 0

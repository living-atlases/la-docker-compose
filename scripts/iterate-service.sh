#!/usr/bin/env bash
# iterate-service.sh — fast iteration loop for a single docker-compose service.
#
# Why this exists: the watch-and-test full path re-runs ~924 ansible tasks
# (config-gen + DB-init + full `up`) every cycle just to discover that one
# service (e.g. CAS) is still unhealthy. This script skips all of that:
# it assumes docker-compose.yml is already generated, brings up only the
# requested service with --no-deps --force-recreate, and tails its logs +
# health until it's green or you ctrl-C. Seconds per cycle, no ansible.
#
# Usage:
#   scripts/iterate-service.sh <service> [--dir DIR] [--profile PROFILE]
#                                        [--follow] [--no-recreate]
#                                        [--timeout SECS]
#
# Examples:
#   scripts/iterate-service.sh cas
#   scripts/iterate-service.sh cas --profile core-auth --follow
#   scripts/iterate-service.sh apikey --dir /data/docker-compose --timeout 60
#
# Exit codes:
#   0 — service reached healthy (or running, if no healthcheck) within timeout
#   1 — service unhealthy or timed out
#   2 — bad args / compose dir not found

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_DIR="${COMPOSE_DIR:-/data/docker-compose}"
SERVICE=""
PROFILE=""
FOLLOW=0
RECREATE=1
TIMEOUT=120

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --dir) COMPOSE_DIR="$2"; shift 2 ;;
        --profile) PROFILE="$2"; shift 2 ;;
        --follow) FOLLOW=1; shift ;;
        --no-recreate) RECREATE=0; shift ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo -e "${RED}Unknown flag: $1${NC}"; usage; exit 2 ;;
        *) SERVICE="$1"; shift ;;
    esac
done

if [ -z "$SERVICE" ]; then
    echo -e "${RED}Error:${NC} service name required"
    usage; exit 2
fi

# Auto-detect compose dir if the default doesn't exist
if [ ! -f "$COMPOSE_DIR/docker-compose.yml" ]; then
    for candidate in /tmp/docker-compose /home/vjrj/la-docker-run /data/docker-compose; do
        if [ -f "$candidate/docker-compose.yml" ]; then
            COMPOSE_DIR="$candidate"
            break
        fi
    done
fi

if [ ! -f "$COMPOSE_DIR/docker-compose.yml" ]; then
    echo -e "${RED}Error:${NC} no docker-compose.yml under $COMPOSE_DIR"
    echo "       Run the full watch/config-gen first, or pass --dir DIR."
    exit 2
fi

cd "$COMPOSE_DIR" || exit 2

[ -n "$PROFILE" ] && export COMPOSE_PROFILES="$PROFILE"

echo -e "${BLUE}${BOLD}━━ iterate-service.sh ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${CYAN}Service:${NC} $SERVICE"
echo -e "  ${CYAN}Dir:${NC}     $COMPOSE_DIR"
echo -e "  ${CYAN}Profile:${NC} ${PROFILE:-<inherited from compose>}"
echo -e "  ${CYAN}Timeout:${NC} ${TIMEOUT}s"
echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Recreate just this service. --no-deps assumes deps are already up.
if [ "$RECREATE" -eq 1 ]; then
    echo -e "${YELLOW}→ docker compose up -d --no-deps --force-recreate $SERVICE${NC}"
    if ! docker compose up -d --no-deps --force-recreate "$SERVICE"; then
        echo -e "${RED}✗ compose up failed for $SERVICE${NC}"
        exit 1
    fi
fi

# Poll health until terminal state or timeout
echo -e "${YELLOW}→ waiting for health (timeout ${TIMEOUT}s)...${NC}"
start=$(date +%s)
final_state=""
while :; do
    elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -ge "$TIMEOUT" ]; then
        final_state="timeout"
        break
    fi

    cid=$(docker compose ps -q "$SERVICE" 2>/dev/null | head -1)
    if [ -z "$cid" ]; then
        sleep 1; continue
    fi

    state=$(docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null || echo unknown)
    health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo none)
    exit_c=$(docker inspect --format '{{.State.ExitCode}}' "$cid" 2>/dev/null || echo "")

    case "$state:$health" in
        running:healthy) final_state="healthy"; break ;;
        running:none)    final_state="running-no-healthcheck"; break ;;
        running:unhealthy) final_state="unhealthy"; break ;;
        exited:*) final_state="exited(rc=$exit_c)"; break ;;
        dead:*|removing:*) final_state="$state"; break ;;
    esac

    printf "\r${CYAN}  [%3ds] state=%s health=%s${NC}      " "$elapsed" "$state" "$health"
    sleep 2
done
echo

# Binary GREEN/RED verdict
case "$final_state" in
    healthy|running-no-healthcheck)
        echo -e "${GREEN}${BOLD}✔ GREEN${NC} — $SERVICE: $final_state"
        verdict=0
        ;;
    *)
        echo -e "${RED}${BOLD}✗ RED${NC} — $SERVICE: $final_state"
        verdict=1
        ;;
esac

# On RED, surface the root-cause line from the container's logs
if [ "$verdict" -ne 0 ] && [ -n "${cid:-}" ]; then
    echo -e "${RED}━━ Root-cause candidates from $SERVICE logs ━━━━━━━━━━━━━━━${NC}"
    docker logs "$cid" 2>&1 \
        | grep -m5 -E 'Caused by:|FATAL|Public Key Retrieval|UnableToConnect|Connection refused|ERROR \[|panic:|level=fatal' \
        || echo "(no canonical error line found — see full logs below)"
    echo -e "${RED}━━ Last 40 log lines ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    docker logs --tail 40 "$cid" 2>&1
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
fi

# Optional: follow logs after verdict
if [ "$FOLLOW" -eq 1 ] && [ -n "${cid:-}" ]; then
    echo -e "${CYAN}→ following logs (ctrl-C to quit)${NC}"
    docker logs -f "$cid"
fi

exit "$verdict"

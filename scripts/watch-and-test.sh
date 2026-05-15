#!/usr/bin/env bash
# Watch la-docker-compose + ala-install for changes and run validate-config-gen.sh
#
# Usage: scripts/watch-and-test.sh
#   Press Enter or 'r' to trigger a manual run
#   Press 'q' to quit
#
# Logs: /tmp/la-docker-watch.log  (full output)
#       /tmp/la-docker-watch-last.log (last run only)

set -u

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Configuration ─────────────────────────────────────────────────────────────
DEBOUNCE_SECONDS=3
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_PATH="$ROOT_DIR/scripts/watch-and-test.sh"
LOG_FILE="/tmp/la-docker-watch.log"
LAST_LOG="/tmp/la-docker-watch-last.log"
CHANGES_FLAG="/tmp/la-docker-watcher-changes-pending"

WATCH_PATHS_RAW=(
    "$ROOT_DIR/roles"
    "$ROOT_DIR/playbooks"
    "$ROOT_DIR/scripts/validate-config-gen.sh"
    "$ROOT_DIR/molecule"
    "$ROOT_DIR/inventories/testing"
    "$ROOT_DIR/ala-install/ansible/roles"
    "$SCRIPT_PATH"
)

WATCH_PATHS=()
for p in "${WATCH_PATHS_RAW[@]}"; do
    if [ -e "$p" ]; then
        WATCH_PATHS+=("$p")
    else
        echo -e "${YELLOW}Warning:${NC} skipping missing path '$p'"
    fi
done

if [ ${#WATCH_PATHS[@]} -eq 0 ]; then
    echo -e "${RED}Error:${NC} no existing paths to watch."
    exit 1
fi

# ── State ─────────────────────────────────────────────────────────────────────
PENDING_RUN=0
COLLECTOR_PID=""

# ── Helpers ───────────────────────────────────────────────────────────────────
send_notification() {
    local title=$1 message=$2 urgency=${3:-normal} icon=${4:-dialog-information}
    if command -v notify-send >/dev/null 2>&1; then
        notify-send --urgency="$urgency" --icon="$icon" --app-name="LA Docker Watcher" "$title" "$message"
    fi
}

spinner() {
    local pid=$1 delay=0.1 i=0
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i+1) % 10 ))
        printf "\r${BLUE}${spinstr:$i:1} Running: %s...${NC}" "${2:-validate-config-gen.sh}"
        sleep "$delay"
    done
    printf "\r"
}

start_change_collector() {
    rm -f "$CHANGES_FLAG" "${CHANGES_FLAG}.paths"
    inotifywait \
        --recursive \
        --format '%w%f' \
        --exclude '(\.git|\.venv|node_modules|\.pyc|__pycache__|\.swp|\.swo|~|\.retry)' \
        --event modify,close_write,create,delete,moved_to,moved_from,attrib \
        "${WATCH_PATHS[@]}" 2>/dev/null \
    | while IFS= read -r changed_path; do
        touch "$CHANGES_FLAG"
        echo "$changed_path" >> "${CHANGES_FLAG}.paths"
    done &
    COLLECTOR_PID=$!
}

stop_change_collector() {
    if [ -n "$COLLECTOR_PID" ] && kill -0 "$COLLECTOR_PID" 2>/dev/null; then
        kill "$COLLECTOR_PID" 2>/dev/null
        wait "$COLLECTOR_PID" 2>/dev/null
    fi
    COLLECTOR_PID=""
}

# ── Main run ──────────────────────────────────────────────────────────────────
run_tests() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo ""
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}[${timestamp}] Triggered — validate + ansiblew deploy${NC}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    start_change_collector

    > "$LAST_LOG"

    echo -e "${CYAN}── Step 1: validate-config-gen.sh ───────────────────────────${NC}"
    echo -e "  ${CYAN}Log:${NC} $LAST_LOG"

    "$ROOT_DIR/scripts/validate-config-gen.sh" >> "$LAST_LOG" 2>&1
    local exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        echo ""
        echo -e "${RED}Last lines of log:${NC}"
        tail -20 "$LAST_LOG"
        echo ""
        echo -e "${RED}${BOLD}✗ VALIDATION FAILED (exit $exit_code) — skipping ansiblew${NC}"
        send_notification "✗ LA Docker — FAILED" "Validation failed (exit $exit_code)" "critical" "dialog-error"
    else
        echo -e "${GREEN}✔ validation passed${NC}"
        echo ""
        echo -e "${CYAN}── Step 2: ansiblew → /data/docker-compose ──────────────────${NC}"
        echo -e "  ${CYAN}Log:${NC} $LAST_LOG"

        (
            cd "$ROOT_DIR/inventories/testing/lademo-inventories" || exit 1
            ANSIBLE_CONFIG="$ROOT_DIR/playbooks/ansible.cfg" \
            ./ansiblew \
                --alainstall=/dev/null \
                --ladocker="$ROOT_DIR" \
                --nodryrun \
                --docker-local \
                --skip=docker \
                --extra="auto_deploy=true${ANSIBLE_LOCAL_EXTRA_VARS:+ $ANSIBLE_LOCAL_EXTRA_VARS}" \
                all
        ) >> "$LAST_LOG" 2>&1
        exit_code=$?

        cat "$LAST_LOG" >> "$LOG_FILE"

        echo ""
        if [ "$exit_code" -eq 0 ]; then
            echo -e "${GREEN}${BOLD}✔ ALL CHECKS PASSED${NC}"
            send_notification "✔ LA Docker — OK" "All checks passed ($timestamp)" "low" "dialog-information"
        else
            echo -e "${RED}Last lines of log:${NC}"
            tail -20 "$LAST_LOG"
            echo ""
            echo -e "${RED}${BOLD}✗ ANSIBLEW FAILED (exit $exit_code)${NC}"
            send_notification "✗ LA Docker — FAILED" "ansiblew failed (exit $exit_code)" "critical" "dialog-error"
        fi
    fi

    stop_change_collector

    if [ -f "$CHANGES_FLAG" ]; then
        local changed_files
        changed_files=$(sort -u "${CHANGES_FLAG}.paths" 2>/dev/null | head -5)
        echo ""
        echo -e "${YELLOW}Changes detected during run — scheduling rerun:${NC}"
        echo "$changed_files" | while IFS= read -r f; do echo "  $f"; done
        rm -f "$CHANGES_FLAG" "${CHANGES_FLAG}.paths"
        PENDING_RUN=1
    fi

    echo ""
    echo -e "${GREEN}Waiting for changes...${NC}  ${CYAN}(r=rerun  q=quit  Enter=rerun)${NC}"
    echo ""
}

run_pending() {
    if [ $PENDING_RUN -eq 1 ]; then
        PENDING_RUN=0
        run_tests
    fi
}

process_event() {
    local path=$1
    if [[ "$path" == *"watch-and-test.sh"* ]]; then
        echo -e "${YELLOW}Script updated!${NC} Restarting..."
        stty sane
        exec "$SCRIPT_PATH"
    fi
    PENDING_RUN=1
}

# ── Watch loop ─────────────────────────────────────────────────────────────────
watch_loop() {
    if ! command -v inotifywait >/dev/null 2>&1; then
        echo -e "${RED}Error:${NC} inotifywait not found — install inotify-tools"
        echo "  Ubuntu/Debian: sudo apt install inotify-tools"
        exit 1
    fi

    local stty_backup
    stty_backup=$(stty -g)
    trap "stty $stty_backup; stop_change_collector; rm -f '$CHANGES_FLAG' '${CHANGES_FLAG}.paths'; exit" EXIT INT TERM
    stty -echo -icanon time 0 min 0

    while true; do
        local first
        first=$(inotifywait \
            --recursive \
            --format '%w%f' \
            --exclude '(\.git|\.venv|node_modules|\.pyc|__pycache__|\.swp|\.swo|~|\.retry)' \
            --event modify,close_write,create,delete,moved_to,moved_from,attrib \
            --timeout 1 \
            "${WATCH_PATHS[@]}" 2>/dev/null)

        local user_input=""
        read -t 0.1 -n 1 user_input 2>/dev/null || true
        if [ -n "$user_input" ]; then
            case "$user_input" in
                r|R|$'\n')
                    echo -e "${YELLOW}Manual trigger:${NC} running..."
                    PENDING_RUN=1
                    run_pending
                    ;;
                q|Q)
                    echo -e "${YELLOW}Quitting.${NC}"
                    stty "$stty_backup"
                    exit 0
                    ;;
            esac
            continue
        fi

        if [ -n "$first" ]; then
            process_event "$first"
            # Debounce
            while true; do
                local more
                more=$(inotifywait \
                    --recursive \
                    --format '%w%f' \
                    --exclude '(\.git|\.venv|node_modules|\.pyc|__pycache__|\.swp|\.swo|~|\.retry)' \
                    --event modify,close_write,create,delete,moved_to,moved_from,attrib \
                    --timeout "$DEBOUNCE_SECONDS" \
                    "${WATCH_PATHS[@]}" 2>/dev/null)
                [ $? -ne 0 ] && break
                process_event "$more"
            done
            run_pending
        fi
    done
}

# ── Banner ────────────────────────────────────────────────────────────────────
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}${BOLD}  LA Docker Compose — Watcher & Test Runner${NC}"
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}Watching:${NC}"
for p in "${WATCH_PATHS[@]}"; do echo "  $p"; done
echo ""
echo -e "${YELLOW}Debounce:${NC} ${DEBOUNCE_SECONDS}s"
echo -e "${YELLOW}Logs:${NC}     $LAST_LOG  (last run)   $LOG_FILE  (rolling)"
echo -e "${YELLOW}Controls:${NC} Enter / r = run now   q = quit"
echo ""
echo -e "${GREEN}Waiting for changes...${NC}"
echo ""

watch_loop

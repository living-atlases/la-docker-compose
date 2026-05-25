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
COLLECTOR_INOTIFY_PID=""
COLLECTOR_WRITER_PID=""
COLLECTOR_FIFO="${CHANGES_FLAG}.fifo"

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
    # Track inotifywait's real PID (not a pipeline subshell) so stop can kill it
    # cleanly. Otherwise the inotifywait child survives each run, accumulates as
    # zombies, eats max_user_instances/watches, and the main loop's inotifywait
    # silently fails (2>/dev/null) — watch appears stuck.
    rm -f "$CHANGES_FLAG" "${CHANGES_FLAG}.paths" "$COLLECTOR_FIFO"
    mkfifo "$COLLECTOR_FIFO"
    inotifywait \
        --quiet \
        --recursive \
        --format '%w%f' \
        --exclude '(\.git|\.venv|node_modules|\.pyc|__pycache__|\.swp|\.swo|~|\.retry)' \
        --event modify,close_write,create,delete,moved_to,moved_from,attrib \
        --outfile "$COLLECTOR_FIFO" \
        "${WATCH_PATHS[@]}" 2>/dev/null &
    COLLECTOR_INOTIFY_PID=$!
    ( while IFS= read -r changed_path; do
        touch "$CHANGES_FLAG"
        echo "$changed_path" >> "${CHANGES_FLAG}.paths"
      done < "$COLLECTOR_FIFO" ) &
    COLLECTOR_WRITER_PID=$!
}

stop_change_collector() {
    if [ -n "$COLLECTOR_INOTIFY_PID" ] && kill -0 "$COLLECTOR_INOTIFY_PID" 2>/dev/null; then
        kill "$COLLECTOR_INOTIFY_PID" 2>/dev/null
        wait "$COLLECTOR_INOTIFY_PID" 2>/dev/null
    fi
    if [ -n "$COLLECTOR_WRITER_PID" ] && kill -0 "$COLLECTOR_WRITER_PID" 2>/dev/null; then
        kill "$COLLECTOR_WRITER_PID" 2>/dev/null
        wait "$COLLECTOR_WRITER_PID" 2>/dev/null
    fi
    rm -f "$COLLECTOR_FIFO"
    COLLECTOR_INOTIFY_PID=""
    COLLECTOR_WRITER_PID=""
}

# ── Main run ──────────────────────────────────────────────────────────────────
run_tests() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Fast-iteration mode: when SERVICE=<name> is set in the env, skip the
    # full validate+ansiblew (~924 tasks, ~1 min) and only recreate that one
    # service via iterate-service.sh. Use this when debugging a single
    # service (e.g. SERVICE=cas) — full pipeline still kicks in if SERVICE
    # is unset.
    if [ -n "${SERVICE:-}" ]; then
        echo ""
        echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}[${timestamp}] Triggered — fast iterate (SERVICE=$SERVICE)${NC}"
        echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        start_change_collector
        > "$LAST_LOG"
        "$ROOT_DIR/scripts/iterate-service.sh" "$SERVICE" 2>&1 | tee -a "$LAST_LOG"
        local exit_code=${PIPESTATUS[0]}
        cat "$LAST_LOG" >> "$LOG_FILE"
        if [ "$exit_code" -eq 0 ]; then
            send_notification "✔ LA Docker — $SERVICE OK" "iterate $SERVICE green ($timestamp)" "low" "dialog-information"
        else
            send_notification "✗ LA Docker — $SERVICE FAILED" "iterate $SERVICE red (exit $exit_code)" "critical" "dialog-error"
        fi
        stop_change_collector
        if [ -f "$CHANGES_FLAG" ]; then
            rm -f "$CHANGES_FLAG" "${CHANGES_FLAG}.paths"
            PENDING_RUN=1
        fi
        echo ""
        echo -e "${GREEN}Waiting for changes...${NC}  ${CYAN}(SERVICE=$SERVICE mode  |  r=rerun  q=quit)${NC}"
        echo ""
        return
    fi

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
            # Surface root-cause from the deploy failure dump (written by the
            # block/rescue in roles/la-compose/tasks/main.yml). Stops blind
            # guessing — the actual error appears on screen, not "exit 1".
            local root_log="/tmp/la-docker-deploy-failure.root.log"
            local full_log="/tmp/la-docker-deploy-failure.log"
            local notif_msg="ansiblew failed (exit $exit_code)"
            if [ -s "$root_log" ]; then
                echo -e "${RED}${BOLD}━━ Root-cause candidates ━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                cat "$root_log"
                echo -e "${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo -e "${CYAN}Full diagnostic:${NC} $full_log"
                # First non-empty match for the notification body
                local first_line
                first_line=$(grep -m1 -E '^\[la_' "$root_log" 2>/dev/null || true)
                [ -n "$first_line" ] && notif_msg="$first_line"
            else
                echo -e "${YELLOW}(no /tmp/la-docker-deploy-failure.root.log — failure was before deploy)${NC}"
            fi
            echo ""
            echo -e "${RED}Last lines of ansiblew log:${NC}"
            tail -20 "$LAST_LOG"
            echo ""
            echo -e "${RED}${BOLD}✗ ANSIBLEW FAILED (exit $exit_code)${NC}"
            send_notification "✗ LA Docker — FAILED" "$notif_msg" "critical" "dialog-error"
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
    trap "stty $stty_backup; stop_change_collector; rm -f '$CHANGES_FLAG' '${CHANGES_FLAG}.paths' '$COLLECTOR_FIFO'; exit" EXIT INT TERM
    stty -echo -icanon time 0 min 0

    while true; do
        # Drain any PENDING_RUN left from a previous iteration before blocking
        # on inotifywait — otherwise a pending rerun would wait for the *next*
        # file change to fire.
        if [ $PENDING_RUN -eq 1 ]; then
            run_pending
            continue
        fi

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

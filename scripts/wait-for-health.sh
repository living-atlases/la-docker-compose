#!/bin/bash
#
# wait-for-health.sh
#
# Waits for docker-compose services to reach "healthy" status
# Supports both explicit HEALTHCHECK and service:started conditions
#
# Usage:
#   wait-for-health.sh [OPTIONS]
#
# Options:
#   --timeout SECONDS      Maximum time to wait (default: 300)
#   --check-interval SECS  How often to check (default: 5)
#   --service SERVICE      Only wait for specific service (default: all)
#   --verbose              Show detailed output
#   --no-exit-code         Don't exit with error code on timeout
#   --compose-dir DIR      Path to docker-compose directory (default: current)
#
# Exits with:
#   0 = All services healthy within timeout
#   1 = Timeout reached before all services healthy
#   2 = Invalid arguments
#   3 = Docker or docker-compose not available

set -euo pipefail

# Configuration
TIMEOUT=300
CHECK_INTERVAL=5
SPECIFIC_SERVICE=""
VERBOSE=false
NO_EXIT_CODE=false
COMPOSE_DIR="."
START_TIME=$(date +%s)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_verbose() {
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $*"
    fi
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout)
                TIMEOUT="$2"
                shift 2
                ;;
            --check-interval)
                CHECK_INTERVAL="$2"
                shift 2
                ;;
            --service)
                SPECIFIC_SERVICE="$2"
                shift 2
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --no-exit-code)
                NO_EXIT_CODE=true
                shift
                ;;
            --compose-dir)
                COMPOSE_DIR="$2"
                shift 2
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 2
                ;;
        esac
    done
}

show_help() {
    cat <<EOF
Usage: wait-for-health.sh [OPTIONS]

Wait for docker-compose services to reach healthy status.

Options:
  --timeout SECONDS         Maximum time to wait (default: 300)
  --check-interval SECS     How often to check (default: 5)
  --service SERVICE         Only wait for specific service (default: all)
  --verbose                 Show detailed output
  --no-exit-code            Don't exit with error code on timeout
  --compose-dir DIR         Path to docker-compose directory (default: current)
  --help                    Show this help message

Examples:
  # Wait for all services (5 minute timeout)
  ./wait-for-health.sh

  # Wait for CAS service only (2 minute timeout, check every 2 seconds)
  ./wait-for-health.sh --service cas --timeout 120 --check-interval 2

  # Verbose output, 10 minute timeout
  ./wait-for-health.sh --verbose --timeout 600

Exit Codes:
  0 = All services healthy within timeout
  1 = Timeout reached before all services healthy
  2 = Invalid arguments
  3 = Docker/docker-compose not available
EOF
}

# Check if docker and docker-compose are available
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        log_error "docker command not found"
        return 3
    fi

    if ! docker compose version &> /dev/null 2>&1; then
        log_error "docker compose not available"
        return 3
    fi

    # Verify directory exists
    if [[ ! -d "$COMPOSE_DIR" ]]; then
        log_error "Compose directory not found: $COMPOSE_DIR"
        return 2
    fi

    return 0
}

# Get list of services from docker-compose
get_services() {
    local services
    
    if [[ -n "$SPECIFIC_SERVICE" ]]; then
        services="$SPECIFIC_SERVICE"
    else
        # Extract service names from running containers
        services=$(docker compose -f "$COMPOSE_DIR/docker-compose.yml" ps --services 2>/dev/null || echo "")
    fi

    echo "$services"
}

# Check health status of a single service
check_service_health() {
    local service="$1"
    local container_name
    
    # Get container ID/name for the service
    container_name=$(docker compose -f "$COMPOSE_DIR/docker-compose.yml" ps -q "$service" 2>/dev/null || echo "")
    
    if [[ -z "$container_name" ]]; then
        log_verbose "Service '$service' container not found or not running"
        return 2  # Not yet running
    fi

    # Get health status
    local health_status
    health_status=$(docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null || echo "none")

    case "$health_status" in
        "healthy")
            return 0  # Healthy
            ;;
        "starting")
            return 2  # Still starting
            ;;
        "unhealthy")
            log_error "Service '$service' reported unhealthy"
            return 1  # Unhealthy
            ;;
        "none")
            # No HEALTHCHECK defined, check if running
            local state
            state=$(docker inspect --format='{{.State.Running}}' "$container_name" 2>/dev/null || echo "false")
            if [[ "$state" == "true" ]]; then
                return 0  # Running (no healthcheck)
            else
                return 2  # Not running
            fi
            ;;
        *)
            return 2  # Unknown state
            ;;
    esac
}

# Display current health status
display_status() {
    local services="$1"
    local elapsed=$(($(date +%s) - START_TIME))
    
    echo -e "\n${BLUE}=== Health Status (Elapsed: ${elapsed}s / Timeout: ${TIMEOUT}s) ===${NC}"
    
    local healthy_count=0
    local unhealthy_count=0
    local starting_count=0
    local unknown_count=0

    while read -r service; do
        if [[ -z "$service" ]]; then continue; fi
        
        local status_code=0
        check_service_health "$service" || status_code=$?

        case $status_code in
            0)
                log_success "$service - HEALTHY"
                ((healthy_count++))
                ;;
            1)
                log_error "$service - UNHEALTHY"
                ((unhealthy_count++))
                ;;
            2)
                log_warn "$service - STARTING/INITIALIZING"
                ((starting_count++))
                ;;
            *)
                log_warn "$service - UNKNOWN STATUS"
                ((unknown_count++))
                ;;
        esac
    done <<< "$services"

    echo -e "\n${BLUE}Summary:${NC} Healthy: ${healthy_count} | Starting: ${starting_count} | Unhealthy: ${unhealthy_count} | Unknown: ${unknown_count}\n"
}

# Main wait loop
wait_for_all_healthy() {
    local services
    local all_healthy=false
    local elapsed

    log_info "Starting health check for services in: $COMPOSE_DIR"
    log_info "Timeout: ${TIMEOUT}s | Check interval: ${CHECK_INTERVAL}s"

    services=$(get_services)
    
    if [[ -z "$services" ]]; then
        log_warn "No services found or docker-compose not initialized"
        return 2
    fi

    if [[ -n "$SPECIFIC_SERVICE" ]]; then
        log_info "Waiting for service: $SPECIFIC_SERVICE"
    else
        log_info "Waiting for services: $(echo "$services" | tr '\n' ', ' | sed 's/,$//')"
    fi

    # Wait loop
    while true; do
        elapsed=$(($(date +%s) - START_TIME))

        if [[ $elapsed -ge $TIMEOUT ]]; then
            log_error "Timeout reached after ${elapsed}s"
            display_status "$services"
            return 1
        fi

        all_healthy=true
        while read -r service; do
            if [[ -z "$service" ]]; then continue; fi
            
            if ! check_service_health "$service" >/dev/null 2>&1; then
                all_healthy=false
                break
            fi
        done <<< "$services"

        if [[ "$all_healthy" == true ]]; then
            log_success "All services are healthy!"
            display_status "$services"
            return 0
        fi

        log_verbose "Waiting... (${elapsed}/${TIMEOUT}s)"
        sleep "$CHECK_INTERVAL"
    done
}

# Collect diagnostic information on failure
collect_diagnostics() {
    local compose_dir="$1"
    
    log_warn "Collecting diagnostic information..."
    
    echo ""
    log_info "=== Docker Compose Status ==="
    docker compose -f "$compose_dir/docker-compose.yml" ps 2>/dev/null || log_error "Could not get compose status"
    
    echo ""
    log_info "=== Container Health Details ==="
    docker ps --format "table {{.Names}}\t{{.Status}}" 2>/dev/null || log_error "Could not list containers"
    
    # Config-mount visibility probe. Several Grails/Spring apps crash-loop with
    # "Config data location '/data/<svc>/config/' does not exist" even though the
    # role generates and uid-1000-owns that dir on the host before compose up.
    # That points at a RUNTIME mount-visibility gap (seen only multi-host). This
    # probe prints, per container, the host-side dir (owner/mode/contents) AND the
    # container-side view (id + ls of the mounted target) so the failing build log
    # shows exactly whether the container sees its config — host perms vs mount vs
    # nothing — instead of an opaque 480s timeout. Read-only; never fails the run.
    echo ""
    log_info "=== Config-mount visibility (host vs container) ==="
    local cnames
    cnames=$(docker compose -f "$compose_dir/docker-compose.yml" ps -a --format '{{.Name}}' 2>/dev/null || echo "")
    while read -r cname; do
        if [[ -z "$cname" ]]; then continue; fi
        # config mount targets for this container: "<hostSrc> <containerDest>"
        local mounts
        mounts=$(docker inspect -f '{{range .Mounts}}{{.Source}} {{.Destination}}{{"\n"}}{{end}}' "$cname" 2>/dev/null \
                 | grep -E '/config(/)?$|/data/' || true)
        if [[ -z "$mounts" ]]; then continue; fi
        local cstatus
        cstatus=$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || echo "?")
        echo ""
        echo "--- $cname (state=$cstatus) ---"
        while read -r src dest; do
            if [[ -z "$src" ]]; then continue; fi
            echo "  mount: host:$src -> container:$dest"
            echo "  [host] $(stat -c '%U:%G %a' "$src" 2>/dev/null || echo 'MISSING') $src"
            ls -la "$src" 2>/dev/null | sed 's/^/    /' | head -8 || true
            if [[ -d "$src/config" ]]; then
                echo "  [host] $(stat -c '%U:%G %a' "$src/config" 2>/dev/null) $src/config"
            fi
            # container side only if it is actually running (restarting can't exec)
            if [[ "$cstatus" == "running" ]]; then
                echo "  [container] id: $(docker exec "$cname" id 2>/dev/null || echo 'exec failed')"
                docker exec "$cname" ls -la "$dest" 2>&1 | sed 's/^/    /' | head -8 || true
            fi
        done <<< "$mounts"
    done <<< "$cnames"

    echo ""
    log_info "=== Recent Container Logs (last 50 lines per service) ==="
    local services
    services=$(docker compose -f "$compose_dir/docker-compose.yml" ps --services 2>/dev/null || echo "")
    
    while read -r service; do
        if [[ -z "$service" ]]; then continue; fi
        echo ""
        echo "--- Logs for $service ---"
        docker compose -f "$compose_dir/docker-compose.yml" logs --tail 50 "$service" 2>/dev/null || true
    done <<< "$services"
}

# Converge-by-retry for cross-host startup races. Some apps (e.g. biocache-service
# -> Cassandra on another node) initialise their datastore connection ONCE at
# startup and do NOT retry; if the cross-host datastore was not ready yet they stay
# "Up (unhealthy)" forever even after it converges. Confirmed on the cluster:
# cassandra Up(healthy) + la_cassandra:9042 reachable from biocache-service, yet
# biocache-service Up(unhealthy) for 16 min. So: restart the still-UNHEALTHY
# services (their deps are healthy now) and re-wait, a few bounded rounds, letting
# the chain cassandra -> biocache-service -> biocache-hub converge. Only restarts
# containers reporting 'unhealthy' (not 'starting'), so a genuinely-broken service
# (e.g. SDS data error) just exhausts the rounds and the gate still fails — no masking.
CONVERGE_ROUNDS="${CONVERGE_ROUNDS:-3}"
CONVERGE_TIMEOUT="${CONVERGE_TIMEOUT:-180}"

converge_unhealthy() {
    local services="$1"
    local round=0 to_restart svc
    while [[ $round -lt $CONVERGE_ROUNDS ]]; do
        round=$((round + 1))
        to_restart=""
        while read -r svc; do
            [[ -z "$svc" ]] && continue
            check_service_health "$svc" >/dev/null 2>&1
            [[ $? -eq 1 ]] && to_restart="$to_restart $svc"
        done <<< "$services"
        if [[ -z "$to_restart" ]]; then
            return 1   # nothing 'unhealthy' to restart (remaining are 'starting'/absent)
        fi
        log_warn "Converge round ${round}/${CONVERGE_ROUNDS}: restarting unhealthy ->${to_restart}"
        # shellcheck disable=SC2086
        docker compose -f "$COMPOSE_DIR/docker-compose.yml" restart $to_restart 2>&1 | sed 's/^/    /' || true
        START_TIME=$(date +%s)
        TIMEOUT=$CONVERGE_TIMEOUT
        if wait_for_all_healthy; then
            log_success "Converged after restart round ${round}"
            return 0
        fi
    done
    return 1
}

# Main execution
main() {
    parse_args "$@"

    if ! check_dependencies; then
        exit 3
    fi

    if wait_for_all_healthy; then
        exit 0
    fi

    # Initial wait failed: try converge-by-retry (restart cross-host apps whose
    # datastores are healthy now) before declaring failure.
    if converge_unhealthy "$(get_services)"; then
        exit 0
    fi

    collect_diagnostics "$COMPOSE_DIR"
    if [[ "$NO_EXIT_CODE" == false ]]; then
        exit 1
    fi
}

# Run main function
main "$@"

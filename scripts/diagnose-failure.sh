#!/bin/bash
#
# diagnose-failure.sh
#
# Collects diagnostic information about failed service deployment
# Useful for debugging startup failures and health check issues
#
# Usage:
#   diagnose-failure.sh [--service SERVICE] [--output-dir DIR] [--verbose]

set -euo pipefail

# Configuration
SERVICES=""
OUTPUT_DIR="/tmp/la-diagnose"
VERBOSE=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[✓]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_verbose() { if [[ "$VERBOSE" == true ]]; then echo -e "${BLUE}[DEBUG]${NC} $*"; fi; }

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --service) SERVICES="$2"; shift 2 ;;
            --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
            --verbose) VERBOSE=true; shift ;;
            --help) show_help; exit 0 ;;
            *) log_error "Unknown option: $1"; show_help; exit 2 ;;
        esac
    done
}

show_help() {
    cat <<EOF
Usage: diagnose-failure.sh [OPTIONS]

Collect diagnostic information about failed docker-compose services.

Options:
  --service SERVICE      Diagnose specific service (default: all)
  --output-dir DIR       Output directory (default: /tmp/la-diagnose)
  --verbose              Show detailed output
  --help                 Show this help message

Examples:
  # Diagnose all services
  ./diagnose-failure.sh

  # Diagnose specific service
  ./diagnose-failure.sh --service cas

  # Save to specific directory
  ./diagnose-failure.sh --output-dir /var/tmp/diagnostics
EOF
}

create_output_dir() {
    if [[ ! -d "$OUTPUT_DIR" ]]; then
        mkdir -p "$OUTPUT_DIR"
        log_info "Created output directory: $OUTPUT_DIR"
    fi
}

write_report() {
    local service="$1"
    local section="$2"
    local output_file="$OUTPUT_DIR/${service}-report.txt"

    if [[ ! -f "$output_file" ]]; then
        cat > "$output_file" <<EOF
# Diagnostic Report for Service: $service
# Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# Hostname: $(hostname)
# User: $(whoami)

EOF
    fi
}

collect_container_info() {
    local service="$1"
    local output_file="$OUTPUT_DIR/${service}-report.txt"

    log_info "Collecting container information for: $service"
    
    local container_id
    container_id=$(docker ps -aqf "label=com.docker.compose.service=$service" 2>/dev/null || echo "")

    if [[ -z "$container_id" ]]; then
        log_error "Container not found for service: $service"
        {
            echo ""
            echo "## Container Status"
            echo "ERROR: No running container found for service '$service'"
        } >> "$output_file"
        return 1
    fi

    log_verbose "Container ID: $container_id"

    # Collect docker inspect output
    {
        echo ""
        echo "## Docker Inspect Output"
        echo "\`\`\`json"
        docker inspect "$container_id" 2>/dev/null || echo "ERROR: Could not inspect container"
        echo "\`\`\`"
    } >> "$output_file"

    # Collect health status
    {
        echo ""
        echo "## Health Status"
        local health
        health=$(docker inspect --format='{{json .State.Health}}' "$container_id" 2>/dev/null || echo "{}")
        echo "\`\`\`json"
        echo "$health"
        echo "\`\`\`"
    } >> "$output_file"

    # Collect environment variables
    {
        echo ""
        echo "## Environment Variables"
        echo "\`\`\`"
        docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container_id" 2>/dev/null || echo "ERROR: Could not get environment"
        echo "\`\`\`"
    } >> "$output_file"

    # Collect mounted volumes
    {
        echo ""
        echo "## Mounted Volumes"
        echo "\`\`\`"
        docker inspect --format='{{range .Mounts}}{{.Source}} -> {{.Destination}} ({{.Mode}}){{println}}{{end}}' "$container_id" 2>/dev/null || echo "ERROR: Could not get mounts"
        echo "\`\`\`"
    } >> "$output_file"

    # Collect port mappings
    {
        echo ""
        echo "## Port Mappings"
        echo "\`\`\`"
        docker inspect --format='{{range $p, $conf := .NetworkSettings.Ports}}{{$p}} -> {{range $conf}}{{.HostIp}}:{{.HostPort}}{{end}}{{println}}{{end}}' "$container_id" 2>/dev/null || echo "ERROR: Could not get ports"
        echo "\`\`\`"
    } >> "$output_file"
}

collect_logs() {
    local service="$1"
    local output_file="$OUTPUT_DIR/${service}-report.txt"

    log_info "Collecting logs for: $service"

    {
        echo ""
        echo "## Service Logs (Last 200 lines)"
        echo "\`\`\`"
        docker compose logs --tail 200 "$service" 2>/dev/null || echo "ERROR: Could not retrieve logs"
        echo "\`\`\`"
    } >> "$output_file"

    # Also write logs to separate file for easier review
    local log_file="$OUTPUT_DIR/${service}-logs.txt"
    docker compose logs "$service" > "$log_file" 2>/dev/null || echo "ERROR: Could not write logs" > "$log_file"
    log_verbose "Logs saved to: $log_file"
}

collect_network_info() {
    local service="$1"
    local output_file="$OUTPUT_DIR/${service}-report.txt"

    log_info "Collecting network information for: $service"

    local container_id
    container_id=$(docker ps -aqf "label=com.docker.compose.service=$service" 2>/dev/null || echo "")

    if [[ -z "$container_id" ]]; then
        return 1
    fi

    {
        echo ""
        echo "## Network Configuration"
        echo "\`\`\`"
        docker inspect --format='{{range .NetworkSettings.Networks}}Network: {{.NetworkID}}{{println}}  IP: {{.IPAddress}}{{println}}  Gateway: {{.Gateway}}{{println}}{{end}}' "$container_id" 2>/dev/null || echo "ERROR: Could not get network info"
        echo "\`\`\`"
    } >> "$output_file"

    # Try network connectivity tests
    {
        echo ""
        echo "## Network Connectivity Tests"
        echo "\`\`\`"
        docker exec "$container_id" sh -c 'echo "DNS Lookup (localhost):" && getent hosts localhost && echo "" && echo "Gateway connectivity:" && ping -c 1 -W 2 8.8.8.8 && echo "Success" || echo "Failed"' 2>/dev/null || echo "ERROR: Could not run connectivity tests"
        echo "\`\`\`"
    } >> "$output_file"
}

collect_system_info() {
    local output_file="$OUTPUT_DIR/system-info.txt"

    log_info "Collecting system information"

    cat > "$output_file" <<EOF
# System Information
Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

## Host Information
Hostname: $(hostname)
Kernel: $(uname -r)
Uptime: $(uptime)

## Docker Information
$(docker version 2>/dev/null || echo "ERROR: Could not get docker version")

## Docker Compose Information
$(docker compose version 2>/dev/null || echo "ERROR: Could not get docker compose version")

## Disk Usage
$(df -h 2>/dev/null || echo "ERROR: Could not get disk usage")

## Memory Usage
$(free -h 2>/dev/null || echo "ERROR: Could not get memory usage")

## Docker System Prune Stats
$(docker system df 2>/dev/null || echo "ERROR: Could not get docker system stats")

## All Containers Status
$(docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "ERROR: Could not list containers")

## Docker Networks
$(docker network ls 2>/dev/null || echo "ERROR: Could not list networks")

## Docker Volumes
$(docker volume ls 2>/dev/null || echo "ERROR: Could not list volumes")

## Recent Docker Events (last 50)
$(docker events --until=1m --format '{{.Time}} {{.Type}} {{.Action}} {{.Actor.Attributes.name}}' 2>/dev/null || echo "ERROR: Could not get events")

EOF

    log_verbose "System info saved to: $output_file"
}

collect_compose_config() {
    local output_file="$OUTPUT_DIR/docker-compose-config.txt"

    log_info "Collecting docker-compose configuration"

    {
        echo "# Docker Compose Configuration"
        echo "Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
        echo ""
        echo "## docker-compose.yml (rendered)"
        echo "\`\`\`yaml"
        docker compose config 2>/dev/null || echo "ERROR: Could not get compose config"
        echo "\`\`\`"
    } > "$output_file"

    log_verbose "Compose config saved to: $output_file"
}

generate_summary() {
    local summary_file="$OUTPUT_DIR/SUMMARY.md"

    log_info "Generating summary report"

    cat > "$summary_file" <<EOF
# Diagnostic Report Summary

**Generated:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")  
**Hostname:** $(hostname)

## Contents

- **system-info.txt** - System and Docker status
- **docker-compose-config.txt** - Rendered docker-compose configuration
- **{service}-report.txt** - Detailed report per service
- **{service}-logs.txt** - Full logs per service

## Quick Diagnostics

### System Resources
$(df -h / 2>/dev/null | tail -1 || echo "ERROR")

### Docker Status
$(docker ps -q | wc -l) running containers  
$(docker ps -aq | wc -l) total containers

### Failed Services
EOF

    # List services with issues
    local services
    services=$(docker ps -aq --format "{{.Label \"com.docker.compose.service\"}}" 2>/dev/null | sort -u)

    while read -r service; do
        if [[ -z "$service" ]]; then continue; fi
        
        local container_id
        container_id=$(docker ps -aqf "label=com.docker.compose.service=$service" 2>/dev/null | head -1)
        
        if [[ -n "$container_id" ]]; then
            local health
            health=$(docker inspect --format='{{.State.Health.Status}}' "$container_id" 2>/dev/null || echo "none")
            
            if [[ "$health" == "unhealthy" ]]; then
                echo "- **$service**: UNHEALTHY" >> "$summary_file"
            fi
        fi
    done <<< "$services"

    echo "" >> "$summary_file"
    echo "## How to Debug" >> "$summary_file"
    echo "" >> "$summary_file"
    echo "1. Start with **system-info.txt** for overall health" >> "$summary_file"
    echo "2. Check **docker-compose-config.txt** for configuration issues" >> "$summary_file"
    echo "3. Review **{service}-report.txt** for specific service details" >> "$summary_file"
    echo "4. Examine **{service}-logs.txt** for error messages" >> "$summary_file"
    echo "" >> "$summary_file"
    echo "### Common Issues" >> "$summary_file"
    echo "- **Port already in use**: Check \`netstat -tlnp\`" >> "$summary_file"
    echo "- **Disk full**: Check with \`df -h\`" >> "$summary_file"
    echo "- **Permission denied**: Check Docker daemon and socket permissions" >> "$summary_file"
    echo "- **Health check failing**: Review container logs and healthcheck configuration" >> "$summary_file"

    log_success "Summary report created: $summary_file"
}

main() {
    parse_args "$@"

    log_info "Starting diagnostic collection..."
    create_output_dir

    # Always collect system info and compose config
    collect_system_info
    collect_compose_config

    # Collect per-service diagnostics
    if [[ -n "$SERVICES" ]]; then
        # Specific service(s) requested
        for service in $SERVICES; do
            write_report "$service" "header"
            collect_container_info "$service" || true
            collect_logs "$service" || true
            collect_network_info "$service" || true
        done
    else
        # All services
        local services
        services=$(docker ps -aq --format "{{.Label \"com.docker.compose.service\"}}" 2>/dev/null | sort -u)
        
        while read -r service; do
            if [[ -z "$service" ]]; then continue; fi
            write_report "$service" "header"
            collect_container_info "$service" || true
            collect_logs "$service" || true
            collect_network_info "$service" || true
        done <<< "$services"
    fi

    generate_summary
    
    log_success "Diagnostic collection complete!"
    log_info "All reports saved to: $OUTPUT_DIR"
    log_info "Start with: $OUTPUT_DIR/SUMMARY.md"
}

main "$@"

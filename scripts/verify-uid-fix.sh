#!/bin/bash
# Verification script for UID/GID 1000 fix
# Run this on Jenkins or target machines to verify the fix worked

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "========================================="
echo "UID/GID 1000 Fix Verification"
echo "========================================="
echo ""

# Check if running on correct host
if [ ! -d "/data/la-docker-compose" ]; then
    echo -e "${RED}ERROR: /data/la-docker-compose not found${NC}"
    echo "This script should run on a Jenkins agent or deployment target"
    exit 1
fi

COMPOSE_DIR="/data/la-docker-compose"
CONFIG_DIR="${COMPOSE_DIR}/config"

echo "1. Checking commit SHA in repository..."
cd "${COMPOSE_DIR}" || exit 1
CURRENT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
echo "   Current commit: ${CURRENT_SHA}"
if [ "${CURRENT_SHA}" = "61e47c5" ]; then
    echo -e "   ${GREEN}✓ Correct commit (UID/GID fix)${NC}"
else
    echo -e "   ${YELLOW}⚠ Expected commit 61e47c5${NC}"
fi
echo ""

echo "2. Checking config directory ownership..."
if [ ! -d "${CONFIG_DIR}" ]; then
    echo -e "   ${RED}✗ Config directory not found${NC}"
    exit 1
fi

# Count files with wrong ownership
WRONG_DIRS=$(find "${CONFIG_DIR}" -type d ! -uid 1000 2>/dev/null | wc -l)
WRONG_FILES=$(find "${CONFIG_DIR}" -type f ! -uid 1000 2>/dev/null | wc -l)
TOTAL_DIRS=$(find "${CONFIG_DIR}" -type d 2>/dev/null | wc -l)
TOTAL_FILES=$(find "${CONFIG_DIR}" -type f 2>/dev/null | wc -l)

echo "   Directories: ${TOTAL_DIRS} total, ${WRONG_DIRS} with wrong UID"
echo "   Files: ${TOTAL_FILES} total, ${WRONG_FILES} with wrong UID"

if [ "${WRONG_DIRS}" -eq 0 ] && [ "${WRONG_FILES}" -eq 0 ]; then
    echo -e "   ${GREEN}✓ All files have UID 1000${NC}"
else
    echo -e "   ${RED}✗ Found ${WRONG_DIRS} dirs and ${WRONG_FILES} files with wrong UID${NC}"
    echo ""
    echo "   Sample files with wrong ownership:"
    find "${CONFIG_DIR}" -type f ! -uid 1000 2>/dev/null | head -5 | while read -r file; do
        LS_OUTPUT=$(ls -ln "$file")
        echo "   - $file"
        echo "     ${LS_OUTPUT}"
    done
fi
echo ""

echo "3. Checking critical service configs..."
CRITICAL_SERVICES=("cas" "collectory" "userdetails" "apikey")
ALL_OK=true

for service in "${CRITICAL_SERVICES[@]}"; do
    SERVICE_DIR="${CONFIG_DIR}/${service}"
    if [ -d "${SERVICE_DIR}" ]; then
        WRONG_IN_SERVICE=$(find "${SERVICE_DIR}" -type f ! -uid 1000 2>/dev/null | wc -l)
        if [ "${WRONG_IN_SERVICE}" -eq 0 ]; then
            echo -e "   ${GREEN}✓ ${service}${NC} - all files UID 1000"
        else
            echo -e "   ${RED}✗ ${service}${NC} - ${WRONG_IN_SERVICE} files with wrong UID"
            ALL_OK=false
        fi
    else
        echo -e "   ${YELLOW}⚠ ${service}${NC} - directory not found"
    fi
done
echo ""

echo "4. Checking Docker containers status..."
if command -v docker &> /dev/null; then
    # Check if containers are running
    CAS_STATUS=$(docker ps --filter "name=la_cas" --format "{{.Status}}" 2>/dev/null | head -1)
    if [ -n "${CAS_STATUS}" ]; then
        if echo "${CAS_STATUS}" | grep -q "healthy"; then
            echo -e "   ${GREEN}✓ CAS container is healthy${NC}"
        elif echo "${CAS_STATUS}" | grep -q "unhealthy"; then
            echo -e "   ${RED}✗ CAS container is unhealthy${NC}"
            ALL_OK=false
        else
            echo -e "   ${YELLOW}⚠ CAS container status: ${CAS_STATUS}${NC}"
        fi
    else
        echo "   ℹ CAS container not running"
    fi
    
    # Count healthy services
    HEALTHY_COUNT=$(docker ps --filter "health=healthy" --format "{{.Names}}" 2>/dev/null | grep "^la_" | wc -l)
    UNHEALTHY_COUNT=$(docker ps --filter "health=unhealthy" --format "{{.Names}}" 2>/dev/null | grep "^la_" | wc -l)
    TOTAL_COUNT=$(docker ps --format "{{.Names}}" 2>/dev/null | grep "^la_" | wc -l)
    
    echo "   Healthy services: ${HEALTHY_COUNT}/${TOTAL_COUNT}"
    if [ "${UNHEALTHY_COUNT}" -gt 0 ]; then
        echo -e "   ${RED}✗ Unhealthy services: ${UNHEALTHY_COUNT}${NC}"
        docker ps --filter "health=unhealthy" --format "   - {{.Names}}: {{.Status}}" 2>/dev/null | grep "^   - la_"
        ALL_OK=false
    fi
else
    echo "   ℹ Docker not available"
fi
echo ""

echo "5. Checking for permission errors in logs..."
if command -v docker &> /dev/null; then
    PERMISSION_ERRORS=$(docker logs la_cas_1 2>&1 | grep -i "permission denied" | wc -l || echo 0)
    if [ "${PERMISSION_ERRORS}" -eq 0 ]; then
        echo -e "   ${GREEN}✓ No permission errors in CAS logs${NC}"
    else
        echo -e "   ${RED}✗ Found ${PERMISSION_ERRORS} permission errors in CAS logs${NC}"
        echo "   Recent permission errors:"
        docker logs la_cas_1 2>&1 | grep -i "permission denied" | tail -3 | sed 's/^/   /'
        ALL_OK=false
    fi
else
    echo "   ℹ Docker not available"
fi
echo ""

echo "========================================="
echo "Summary"
echo "========================================="
if [ "${ALL_OK}" = true ]; then
    echo -e "${GREEN}✓ All checks passed - UID/GID fix successful${NC}"
    exit 0
else
    echo -e "${RED}✗ Some checks failed - see details above${NC}"
    echo ""
    echo "Recommended actions:"
    echo "1. Review /data/la-docker-compose/config ownership"
    echo "2. Check Docker container logs: docker logs la_cas_1"
    echo "3. Consider re-running playbooks/config-gen.yml"
    exit 1
fi

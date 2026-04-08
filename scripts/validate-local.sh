#!/bin/bash
# validate-local.sh - Local validation pipeline (fail fast before remote)
#
# Runs 3 layers of validation to ensure Ansible code + inventories work
# correctly before commits or remote testing.
#
# Usage:
#   ./scripts/validate-local.sh           # Full validation (all 3 layers)
#   ./scripts/validate-local.sh quick     # Layer 1 only: lint + syntax (~5s)
#   ./scripts/validate-local.sh vars      # Layers 1+2: variables (~15s)
#   ./scripts/validate-local.sh config    # Layers 1+2+3: config generation (~60s)
#   ./scripts/validate-local.sh --help    # Show this help
#
# Requirements:
#   - ansible (required for layers 2 and 3)
#   - yamllint (optional, for layer 1 - skipped if missing)
#   - ansible-lint (optional, for layer 1 - skipped if missing)
#
# Environment:
#   LA_SKIP_ANSIBLE_LINT=1  Skip ansible-lint (e.g. Ansible CLI vs python module version mismatch on the host).
#   - docker (optional, for layer 3 docker compose config validation)
#
# The ala-install submodule must be initialized:
#   git submodule update --init --recursive

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Populated by run_layer3: unique mktemp dir per run (avoids rm -rf of root-owned paths under /tmp/la-test-data)
LAYER3_TEST_DIR=""

# Inventory to use for local testing
LOCAL_INVENTORY="${REPO_ROOT}/inventories/local"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Counters
LAYER1_FAILED=0
LAYER2_FAILED=0
LAYER3_FAILED=0
TOTAL_CHECKS=0
TOTAL_PASSED=0
TOTAL_SKIPPED=0

START_TIME=$(date +%s)

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

log_header() {
    echo -e "\n${BLUE}${BOLD}▶ $1${NC}"
}

log_pass() {
    echo -e "  ${GREEN}✓${NC} $1"
    ((TOTAL_PASSED++)) || true
    ((TOTAL_CHECKS++)) || true
}

log_fail() {
    echo -e "  ${RED}✗${NC} $1"
    ((TOTAL_CHECKS++)) || true
}

log_skip() {
    echo -e "  ${YELLOW}⊘${NC} $1 ${YELLOW}(skipped)${NC}"
    ((TOTAL_SKIPPED++)) || true
    ((TOTAL_CHECKS++)) || true
}

log_info() {
    echo -e "  ${CYAN}ℹ${NC} $1"
}

command_available() {
    command -v "$1" >/dev/null 2>&1
}

elapsed_time() {
    local end_time
    end_time=$(date +%s)
    echo $((end_time - START_TIME))
}

usage() {
    sed -n '/^# Usage:/,/^# Requirements:/{ /^# Requirements:/d; s/^# //; p }' "$0"
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Prerequisite Checks
# ─────────────────────────────────────────────────────────────────────────────

check_prerequisites() {
    log_header "Prerequisite Checks"

    # Check we're in the right directory
    if [[ ! -f "${REPO_ROOT}/Jenkinsfile" ]] || [[ ! -d "${REPO_ROOT}/roles/la-compose" ]]; then
        log_fail "Not in la-docker-compose root. Run from: ${REPO_ROOT}"
        exit 1
    fi
    log_pass "Running from la-docker-compose root"

    # Check ala-install submodule
    if [[ ! -d "${REPO_ROOT}/ala-install/ansible" ]]; then
        log_fail "ala-install submodule not initialized"
        echo -e "  ${YELLOW}Run: git submodule update --init --recursive${NC}"
        exit 1
    fi
    log_pass "ala-install submodule available"

    # Check ansible
    if ! command_available ansible-playbook; then
        log_fail "ansible-playbook not found"
        echo -e "  ${YELLOW}Install: pip install ansible${NC}"
        exit 1
    fi
    ANSIBLE_VERSION=$(ansible-playbook --version | head -1 | awk '{print $NF}')
    log_pass "ansible-playbook available (${ANSIBLE_VERSION})"

    # Check inventory
    if [[ ! -f "${LOCAL_INVENTORY}/hosts" ]] && [[ ! -f "${LOCAL_INVENTORY}/hosts.ini" ]]; then
        log_fail "Local inventory not found at ${LOCAL_INVENTORY}/hosts or hosts.ini"
        exit 1
    fi
    log_pass "Local inventory available"
}

# ─────────────────────────────────────────────────────────────────────────────
# Layer 1: Lint & Syntax
# ─────────────────────────────────────────────────────────────────────────────

run_layer1() {
    log_header "LAYER 1: Lint & Syntax Check"

    # yamllint
    if command_available yamllint; then
        if yamllint -c "${REPO_ROOT}/.yamllint" "${REPO_ROOT}/roles/" "${REPO_ROOT}/playbooks/" >/dev/null 2>&1; then
            log_pass "yamllint (roles + playbooks)"
        else
            log_fail "yamllint failed"
            yamllint -c "${REPO_ROOT}/.yamllint" "${REPO_ROOT}/roles/" "${REPO_ROOT}/playbooks/" 2>&1 | head -20 | sed 's/^/    /'
            ((LAYER1_FAILED++)) || true
        fi
    else
        log_skip "yamllint (not installed: sudo apt install yamllint)"
    fi

    # ansible-lint
    if [[ "${LA_SKIP_ANSIBLE_LINT:-}" == "1" ]]; then
        log_skip "ansible-lint (LA_SKIP_ANSIBLE_LINT=1)"
    elif command_available ansible-lint; then
        if ansible-lint "${REPO_ROOT}/roles/" -f brief >/dev/null 2>&1; then
            log_pass "ansible-lint (local roles)"
        else
            log_fail "ansible-lint failed"
            ansible-lint "${REPO_ROOT}/roles/" -f brief 2>&1 | head -20 | sed 's/^/    /'
            ((LAYER1_FAILED++)) || true
        fi
    else
        log_skip "ansible-lint (not installed: sudo apt install ansible-lint)"
    fi

    # Syntax check: config-gen playbook
    log_info "Checking syntax of config-gen.yml..."
    ANSIBLE_ROLES_PATH="${REPO_ROOT}/ala-install/ansible/roles:${REPO_ROOT}/roles" \
    ansible-playbook \
        -i "${LOCAL_INVENTORY}" \
        "${REPO_ROOT}/playbooks/config-gen.yml" \
        --syntax-check \
        -e "auto_deploy=false" \
        >/dev/null 2>&1 && \
        log_pass "playbooks/config-gen.yml syntax check" || {
        log_fail "playbooks/config-gen.yml syntax check"
        ANSIBLE_ROLES_PATH="${REPO_ROOT}/ala-install/ansible/roles:${REPO_ROOT}/roles" \
        ansible-playbook \
            -i "${LOCAL_INVENTORY}" \
            "${REPO_ROOT}/playbooks/config-gen.yml" \
            --syntax-check \
            -e "auto_deploy=false" 2>&1 | head -20 | sed 's/^/    /'
        ((LAYER1_FAILED++)) || true
    }

    # Syntax check: test-config-gen playbook
    if [[ -f "${REPO_ROOT}/playbooks/test-config-gen.yml" ]]; then
        ANSIBLE_ROLES_PATH="${REPO_ROOT}/ala-install/ansible/roles:${REPO_ROOT}/roles" \
        ansible-playbook \
            -i "${LOCAL_INVENTORY}" \
            "${REPO_ROOT}/playbooks/test-config-gen.yml" \
            --syntax-check \
            >/dev/null 2>&1 && \
            log_pass "playbooks/test-config-gen.yml syntax check" || {
            log_fail "playbooks/test-config-gen.yml syntax check"
            ANSIBLE_ROLES_PATH="${REPO_ROOT}/ala-install/ansible/roles:${REPO_ROOT}/roles" \
            ansible-playbook \
                -i "${LOCAL_INVENTORY}" \
                "${REPO_ROOT}/playbooks/test-config-gen.yml" \
                --syntax-check 2>&1 | head -20 | sed 's/^/    /'
            ((LAYER1_FAILED++)) || true
        }
    fi

    # Syntax check: verify-inventory playbook
    ANSIBLE_ROLES_PATH="${REPO_ROOT}/ala-install/ansible/roles:${REPO_ROOT}/roles" \
    ansible-playbook \
        -i "${LOCAL_INVENTORY}" \
        "${REPO_ROOT}/playbooks/verify-inventory.yml" \
        --syntax-check \
        >/dev/null 2>&1 && \
        log_pass "playbooks/verify-inventory.yml syntax check" || {
        log_fail "playbooks/verify-inventory.yml syntax check"
        ((LAYER1_FAILED++)) || true
    }

    if [[ ${LAYER1_FAILED} -eq 0 ]]; then
        echo -e "\n  ${GREEN}Layer 1 PASSED${NC}"
    else
        echo -e "\n  ${RED}Layer 1 FAILED (${LAYER1_FAILED} errors)${NC}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Layer 2: Inventory & Variables
# ─────────────────────────────────────────────────────────────────────────────

run_layer2() {
    log_header "LAYER 2: Inventory & Variable Validation"

    local tmp_out
    tmp_out=$(mktemp)

    # Run verify-inventory playbook
    log_info "Loading inventory and checking variables..."

    ANSIBLE_ROLES_PATH="${REPO_ROOT}/ala-install/ansible/roles:${REPO_ROOT}/roles" \
    ansible-playbook \
        -i "${LOCAL_INVENTORY}" \
        "${REPO_ROOT}/playbooks/verify-inventory.yml" \
        -e "deployment_type=container" \
        2>&1 | tee "${tmp_out}" | grep -E "^(PLAY|TASK|ok:|failed:|fatal:)" | head -40 | sed 's/^/    /' || true

    ANSIBLE_EXIT=${PIPESTATUS[0]}
    FAILED_COUNT=0
    if grep -q "failed=[1-9]" "${tmp_out}" 2>/dev/null; then
        FAILED_COUNT=$(grep "failed=[1-9]" "${tmp_out}" | wc -l | tr -d ' ')
    fi

    if [[ "${ANSIBLE_EXIT}" -eq 0 ]] && [[ "${FAILED_COUNT}" -eq 0 ]] && ! grep -q "FAILED!" "${tmp_out}" 2>/dev/null; then
        log_pass "Inventory loads correctly"
        log_pass "Critical variables defined (org_short_name, deployment_type, etc.)"
        log_pass "deployment_type=container validated"
        log_pass "Database hostname mappings configured"
    else
        log_fail "verify-inventory.yml execution failed (exit=${ANSIBLE_EXIT}, failed_tasks=${FAILED_COUNT})"
        grep -A 3 "FAILED!" "${tmp_out}" 2>/dev/null | head -20 | sed 's/^/    /'
        ((LAYER2_FAILED++)) || true
    fi

    # Check ansible inventory parses correctly
    log_info "Checking ansible inventory list..."
    if ANSIBLE_ROLES_PATH="${REPO_ROOT}/ala-install/ansible/roles:${REPO_ROOT}/roles" \
       ansible-inventory -i "${LOCAL_INVENTORY}" --list >/dev/null 2>&1; then
        HOSTS=$(ANSIBLE_ROLES_PATH="${REPO_ROOT}/ala-install/ansible/roles:${REPO_ROOT}/roles" \
                ansible-inventory -i "${LOCAL_INVENTORY}" --list 2>/dev/null | \
                python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('_meta',{}).get('hostvars',{})))" 2>/dev/null || echo "?")
        log_pass "Inventory list parsed (${HOSTS} hosts)"
    else
        log_fail "ansible-inventory --list failed"
        ((LAYER2_FAILED++)) || true
    fi

    rm -f "${tmp_out}"

    if [[ ${LAYER2_FAILED} -eq 0 ]]; then
        echo -e "\n  ${GREEN}Layer 2 PASSED${NC}"
    else
        echo -e "\n  ${RED}Layer 2 FAILED (${LAYER2_FAILED} errors)${NC}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Layer 3: Config Generation
# ─────────────────────────────────────────────────────────────────────────────

run_layer3() {
    log_header "LAYER 3: Configuration Generation"

    local tmp_out
    tmp_out=$(mktemp)

    # Fresh directory each run (do not rm -rf a fixed /tmp path: Docker may leave root-owned files)
    LAYER3_TEST_DIR=$(mktemp -d /tmp/la-compose-validation-XXXXXX)
    log_info "Preparing test directory: ${LAYER3_TEST_DIR}"
    mkdir -p "${LAYER3_TEST_DIR}/docker-compose"

    log_info "Running test-config-gen.yml (this takes ~30-120s)..."

    ANSIBLE_ROLES_PATH="${REPO_ROOT}/ala-install/ansible/roles:${REPO_ROOT}/roles" \
    ANSIBLE_STDOUT_CALLBACK=yaml \
    ansible-playbook \
        -i "${LOCAL_INVENTORY}" \
        "${REPO_ROOT}/playbooks/test-config-gen.yml" \
        -e "data_dir=${LAYER3_TEST_DIR} docker_compose_data_dir=${LAYER3_TEST_DIR}/docker-compose auto_deploy=false" \
        2>&1 | tee "${tmp_out}" | grep -E "(PLAY RECAP|ok=|failed=|TASK \[|fatal:)" | sed 's/^/    /' || true

    ANSIBLE_EXIT_L3=${PIPESTATUS[0]}
    FAILED_TASKS=0
    UNREACHABLE=0
    if grep -q "failed=[1-9]" "${tmp_out}" 2>/dev/null; then
        FAILED_TASKS=$(grep "failed=[1-9]" "${tmp_out}" | wc -l | tr -d ' ')
    fi
    if grep -q "unreachable=[1-9]" "${tmp_out}" 2>/dev/null; then
        UNREACHABLE=$(grep "unreachable=[1-9]" "${tmp_out}" | wc -l | tr -d ' ')
    fi

    if [[ "${ANSIBLE_EXIT_L3}" -eq 0 ]] && [[ "${FAILED_TASKS}" -eq 0 ]] && [[ "${UNREACHABLE}" -eq 0 ]] && ! grep -q "FAILED!" "${tmp_out}" 2>/dev/null; then
        log_pass "config generation playbook completed"
    else
        log_fail "config generation had errors (exit=${ANSIBLE_EXIT_L3}, failed=${FAILED_TASKS}, unreachable=${UNREACHABLE})"
        grep -E "(FAILED!|fatal:)" "${tmp_out}" 2>/dev/null | head -20 | sed 's/^/    /'
        ((LAYER3_FAILED++)) || true
    fi

    # Check generated files
    log_info "Checking generated files..."

    if [[ -f "${LAYER3_TEST_DIR}/docker-compose/docker-compose.yml" ]]; then
        SIZE=$(wc -c < "${LAYER3_TEST_DIR}/docker-compose/docker-compose.yml")
        log_pass "docker-compose.yml generated (${SIZE} bytes)"

        # Validate YAML syntax with python
        if python3 -c "import yaml; yaml.safe_load(open('${LAYER3_TEST_DIR}/docker-compose/docker-compose.yml'))" 2>/dev/null; then
            log_pass "docker-compose.yml is valid YAML"
        else
            log_fail "docker-compose.yml is invalid YAML"
            python3 -c "import yaml; yaml.safe_load(open('${LAYER3_TEST_DIR}/docker-compose/docker-compose.yml'))" 2>&1 | sed 's/^/    /'
            ((LAYER3_FAILED++)) || true
        fi

        # Count services
        SERVICES=$(python3 -c "
import yaml
with open('${LAYER3_TEST_DIR}/docker-compose/docker-compose.yml') as f:
    d = yaml.safe_load(f)
services = list(d.get('services', {}).keys())
print(len(services))
" 2>/dev/null || echo "?")
        log_info "Services defined: ${SERVICES}"

        # Validate with docker compose config (if available)
        if command_available docker; then
            log_info "Validating with docker compose config..."
            if docker compose -f "${LAYER3_TEST_DIR}/docker-compose/docker-compose.yml" config >/dev/null 2>&1; then
                log_pass "docker compose config validation"
            else
                log_fail "docker compose config validation failed"
                docker compose -f "${LAYER3_TEST_DIR}/docker-compose/docker-compose.yml" config 2>&1 | head -20 | sed 's/^/    /'
                ((LAYER3_FAILED++)) || true
            fi
        else
            log_skip "docker compose config (docker not available)"
        fi
    else
        log_fail "docker-compose.yml not generated at ${LAYER3_TEST_DIR}/docker-compose/"
        log_info "Contents of test dir:"
        ls -la "${LAYER3_TEST_DIR}/docker-compose/" 2>/dev/null | sed 's/^/    /' || echo "    (empty or missing)"
        ((LAYER3_FAILED++)) || true
    fi

    # Check for .env file
    if [[ -f "${LAYER3_TEST_DIR}/docker-compose/.env" ]]; then
        ENV_LINES=$(wc -l < "${LAYER3_TEST_DIR}/docker-compose/.env")
        log_pass ".env file generated (${ENV_LINES} lines)"
    else
        log_info ".env file not present (may be optional depending on services)"
    fi

    # Check for infrastructure configs
    INFRA_COUNT=$(find "${LAYER3_TEST_DIR}/docker-compose" -name "*.yml" -not -name "docker-compose.yml" 2>/dev/null | wc -l || echo 0)
    if [[ "${INFRA_COUNT}" -gt 0 ]]; then
        log_pass "Service/infrastructure configs generated (${INFRA_COUNT} files)"
    fi

    rm -f "${tmp_out}"

    if [[ ${LAYER3_FAILED} -eq 0 ]]; then
        echo -e "\n  ${GREEN}Layer 3 PASSED${NC}"
        echo -e "\n  ${CYAN}Generated files at: ${LAYER3_TEST_DIR}/docker-compose/${NC}"
        echo -e "  ${CYAN}Inspect with: ls -la ${LAYER3_TEST_DIR}/docker-compose/${NC}"
    else
        echo -e "\n  ${RED}Layer 3 FAILED (${LAYER3_FAILED} errors)${NC}"
        echo -e "\n  ${CYAN}Partial output at: ${LAYER3_TEST_DIR}/docker-compose/${NC}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

print_summary() {
    local total_failed=$((LAYER1_FAILED + LAYER2_FAILED + LAYER3_FAILED))
    local elapsed
    elapsed=$(elapsed_time)

    echo ""
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}Validation Summary${NC} (${elapsed}s)"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  Passed:  ${GREEN}${TOTAL_PASSED}${NC}"
    echo -e "  Skipped: ${YELLOW}${TOTAL_SKIPPED}${NC}"
    echo -e "  Checks:  ${TOTAL_CHECKS}"

    if [[ ${total_failed} -eq 0 ]]; then
        echo ""
        echo -e "${GREEN}${BOLD}✅ ALL VALIDATIONS PASSED${NC}"
        echo -e "${GREEN}   Ready to commit and push!${NC}"
    else
        echo ""
        echo -e "${RED}${BOLD}❌ VALIDATION FAILED${NC}"
        echo -e "${RED}   Layer 1 (lint):   ${LAYER1_FAILED} failure(s)${NC}"
        echo -e "${RED}   Layer 2 (vars):   ${LAYER2_FAILED} failure(s)${NC}"
        echo -e "${RED}   Layer 3 (config): ${LAYER3_FAILED} failure(s)${NC}"
        echo ""
        echo -e "${YELLOW}   Fix errors before committing or pushing to remote.${NC}"
        echo -e "${YELLOW}   Run with no args for full output, or check tmp: ${LAYER3_TEST_DIR:-<layer 3 not run>}${NC}"
    fi
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

MODE="${1:-full}"

case "${MODE}" in
    --help|-h)
        usage
        ;;
    quick)
        echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BLUE}${BOLD}LA-Docker-Compose Local Validation [QUICK]${NC}"
        echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        cd "${REPO_ROOT}"
        check_prerequisites
        run_layer1
        print_summary
        exit $((LAYER1_FAILED > 0 ? 1 : 0))
        ;;
    vars)
        echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BLUE}${BOLD}LA-Docker-Compose Local Validation [VARS]${NC}"
        echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        cd "${REPO_ROOT}"
        check_prerequisites
        run_layer1
        [[ ${LAYER1_FAILED} -eq 0 ]] && run_layer2
        print_summary
        exit $(( (LAYER1_FAILED + LAYER2_FAILED) > 0 ? 1 : 0 ))
        ;;
    config|full)
        echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BLUE}${BOLD}LA-Docker-Compose Local Validation [${MODE^^}]${NC}"
        echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        cd "${REPO_ROOT}"
        check_prerequisites
        run_layer1
        [[ ${LAYER1_FAILED} -eq 0 ]] && run_layer2
        [[ ${LAYER1_FAILED} -eq 0 ]] && [[ ${LAYER2_FAILED} -eq 0 ]] && run_layer3
        print_summary
        exit $(( (LAYER1_FAILED + LAYER2_FAILED + LAYER3_FAILED) > 0 ? 1 : 0 ))
        ;;
    *)
        echo "Unknown mode: ${MODE}"
        echo "Use: quick | vars | config | full | --help"
        exit 1
        ;;
esac

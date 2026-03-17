#!/bin/bash
# Ansible Validation Script
# Validates YAML syntax and lint for ansible playbooks and roles
# Used by pre-commit hooks and CI/CD pipelines
#
# Requirements (optional, script gracefully handles missing tools):
#   - yamllint: for YAML structure validation
#   - ansible-lint: for ansible best practices
#
# Install with:
#   sudo apt install yamllint ansible-lint
# Or via pip in a venv:
#   python3 -m venv .venv && source .venv/bin/activate && pip install yamllint ansible-lint

# Don't use set -e because we handle errors manually and want to run all checks

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
FAILED=0
PASSED=0
SKIPPED=0

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Ansible Validation Suite${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Function to check if command exists and works
command_works() {
    local cmd=$1
    if command -v "$cmd" >/dev/null 2>&1; then
        # Try to run it with --version to see if it actually works
        "$cmd" --version >/dev/null 2>&1 && return 0
        return 1
    fi
    return 1
}

# Function to run validation check
run_check() {
    local check_name=$1
    local command=$2
    local tool=$3
    
    echo -e "\n${BLUE}▶ ${check_name}${NC}"
    
    # Check if tool is available and works
    if [ -n "$tool" ] && ! command_works "$tool"; then
        echo -e "${YELLOW}⊘ ${check_name} skipped (${tool} not available)${NC}"
        echo -e "${YELLOW}  Install with: sudo apt install ${tool}${NC}"
        ((SKIPPED++))
        return 0
    fi
    
    if eval "$command" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ ${check_name} passed${NC}"
        ((PASSED++))
    else
        local exit_code=$?
        echo -e "${RED}✗ ${check_name} failed (exit code: $exit_code)${NC}"
        # Show actual error (limit to 10 lines)
        if [ $exit_code -eq 127 ] || [ $exit_code -eq 126 ]; then
            echo -e "${YELLOW}  Tool not found or not executable${NC}"
        else
            eval "$command" 2>&1 | head -10
        fi
        ((FAILED++))
    fi
}

# 1. YAML Lint Check (validates YAML structure)
run_check "YAML Lint (roles & playbooks)" \
    "yamllint -c .yamllint roles/ playbooks/" \
    "yamllint"

# 2. Ansible Lint Check
run_check "Ansible Lint (local roles)" \
    "ansible-lint roles/ -f parseable" \
    "ansible-lint"

# Summary
echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Validation Summary${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "Passed:  ${GREEN}${PASSED}${NC}"
echo -e "Failed:  ${RED}${FAILED}${NC}"
echo -e "Skipped: ${YELLOW}${SKIPPED}${NC}"

if [ $FAILED -gt 0 ]; then
    echo -e "\n${RED}✗ Validation FAILED${NC}"
    exit 1
elif [ $PASSED -gt 0 ]; then
    echo -e "\n${GREEN}✓ All active validations passed${NC}"
    exit 0
else
    echo -e "\n${YELLOW}⊘ No validation tools available${NC}"
    echo -e "Install tools to enable validation:"
    echo -e "  sudo apt install yamllint ansible-lint"
    exit 0
fi


#!/bin/bash
#
# test-ansible-version-pin.sh
#
# The tests must run the Ansible that deploys, and that Ansible must be the one
# ala-install upstream supports.
#
# Build #432: the test venv had ansible-core 2.20.5 (unpinned `pip install
# ansible-core`) and the deploy venv 2.17.3. `lookup('ansible.builtin.template',
# 'heap-budget.j2') | from_json` gets a string on 2.20 and an already-parsed dict
# on 2.17, so every test passed and the deploy failed on all three hosts.
#
# Two checks:
#   1. ansible-constraints.txt pins the pair ala-install's README declares
#      ("The current supported version is: **X** (core) and **Y** (community)").
#      Run it after the submodule sync: the deployed ala-install is the one that
#      counts, not the previous build's checkout.
#   2. Every venv given on the command line has exactly that pair installed.
#
# Fails closed: a README line it cannot parse is a failure, not a skip, so an
# upstream rewording is noticed instead of silently disabling the check.
#
# Usage: bash scripts/test-ansible-version-pin.sh [--skip-readme] [VENV_DIR...]
#
# Exits 0 when the pins agree, 1 otherwise.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONSTRAINTS="$REPO_DIR/ansible-constraints.txt"
README="$REPO_DIR/ala-install/README.md"

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }

check_readme=1
venvs=()
for arg in "$@"; do
    case "$arg" in
        --skip-readme) check_readme=0 ;;
        *) venvs+=("$arg") ;;
    esac
done

pinned() { sed -n "s/^$1==\([0-9.]*\)[[:space:]]*$/\1/p" "$CONSTRAINTS"; }

[[ -f "$CONSTRAINTS" ]] || { fail "$CONSTRAINTS not found"; exit 1; }
pin_core="$(pinned ansible-core)"
pin_community="$(pinned ansible)"
if [[ -z "$pin_core" || -z "$pin_community" ]]; then
    fail "ansible-constraints.txt must pin both ansible==X and ansible-core==Y"
    exit 1
fi
info "pinned: ansible $pin_community / ansible-core $pin_core"

errors=0

if (( check_readme )); then
    [[ -f "$README" ]] || { fail "$README not found (ala-install submodule not initialised?)"; exit 1; }
    line="$(grep -m1 'current supported version is' "$README" || true)"
    up_core="$(sed -n 's/.*\*\*\([0-9.]*\)\*\* *(core).*/\1/p' <<<"$line")"
    up_community="$(sed -n 's/.*\*\*\([0-9.]*\)\*\* *(community).*/\1/p' <<<"$line")"
    if [[ -z "$up_core" || -z "$up_community" ]]; then
        fail "could not read the supported Ansible version from ala-install/README.md"
        echo "       line: ${line:-<none matching 'current supported version is'>}"
        exit 1
    fi
    if [[ "$up_core" == "$pin_core" && "$up_community" == "$pin_community" ]]; then
        pass "ala-install supports ansible $up_community / ansible-core $up_core, as pinned"
    else
        fail "ala-install supports ansible $up_community / ansible-core $up_core," \
             "ansible-constraints.txt pins $pin_community / $pin_core"
        errors=$((errors + 1))
    fi
fi

for venv in "${venvs[@]}"; do
    py="$venv/bin/python"
    [[ -x "$py" ]] || { fail "$venv: no python in this venv"; errors=$((errors + 1)); continue; }
    got="$("$py" - <<'EOF'
from importlib.metadata import version, PackageNotFoundError
def v(name):
    try:
        return version(name)
    except PackageNotFoundError:
        return "missing"
print(v("ansible"), v("ansible-core"))
EOF
)"
    got_community="${got% *}"
    got_core="${got#* }"
    if [[ "$got_core" == "$pin_core" && "$got_community" == "$pin_community" ]]; then
        pass "$venv: ansible $got_community / ansible-core $got_core"
    else
        fail "$venv: ansible $got_community / ansible-core $got_core," \
             "expected $pin_community / $pin_core"
        errors=$((errors + 1))
    fi
done

exit $(( errors > 0 ))

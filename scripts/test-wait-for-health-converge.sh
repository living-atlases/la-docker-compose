#!/bin/bash
#
# test-wait-for-health-converge.sh
#
# Regression test for the post-deploy health gate's converge-by-retry.
#
# What broke (gbif-es production deploy, 2026-08-05): validate-post-deploy.yml wrapped
# wait-for-health.sh in `timeout -k 30 <health_check_timeout + 60>` = 780s, while the
# script's own worst case was health_check_timeout + CONVERGE_ROUNDS x CONVERGE_TIMEOUT
# = 4320s. timeout(1) killed the gate at exactly 13:00 with rc=124, every time, before
# converge round 2 could start — so the converge logic was in practice dead code and
# services that would have healed were reported as a failed deploy.
#
# The fix makes both budgets derive from the same three role variables and injects the
# two converge knobs into the script's environment. Four cases:
#   1. a service that only heals in converge round 2 is accepted by the gate
#   2. CONVERGE_ROUNDS=1 fails it -- proving the knobs come from the environment and
#      are not falling back to the script's own defaults
#   3a. wrapped in the OLD budget (blind to the converge rounds), the gate dies rc=124
#   3b. wrapped in the DERIVED budget, it returns 0
# 3a is the regression proper: it fails if someone re-decouples the two budgets.
# That the role renders the derived budget from role variables, rather than a
# transcribed literal, is asserted separately in molecule/unit/converge.yml.
#
# Runs against real Docker with a one-container fixture; ~90s. No inventory, no
# ansible, no deployed stack.
#
# Usage: bash scripts/test-wait-for-health-converge.sh [--verbose]
#
# Exits 0 if all cases pass, 1 otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_SRC="$SCRIPT_DIR/fixtures/wait-for-health-converge"
GATE="$SCRIPT_DIR/wait-for-health.sh"
VERBOSE=""
[[ "${1:-}" == "--verbose" ]] && VERBOSE="--verbose"

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }

WORK_DIR=""
cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        docker compose -f "$WORK_DIR/docker-compose.yml" down -v --remove-orphans >/dev/null 2>&1 || true
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

if ! docker compose version >/dev/null 2>&1; then
    fail "docker compose not available — cannot run this test"
    exit 1
fi

# Each case gets a pristine container: the fixture's boot counter lives on the
# container's writable layer, so a reused container would start already-healthy.
reset_fixture() {
    cleanup
    WORK_DIR="$(mktemp -d)"
    cp "$FIXTURE_SRC/docker-compose.yml" "$WORK_DIR/"
    docker compose -f "$WORK_DIR/docker-compose.yml" up -d >/dev/null 2>&1
}

failures=0

# --- Case 1: heals in converge round 2 -> the gate must accept it ------------------
# Before the fix this is the run that died at rc=124 without ever reaching round 2.
info "Case 1: service heals in converge round 2, CONVERGE_ROUNDS=2 -> expect rc=0"
reset_fixture
rc=0
CONVERGE_ROUNDS=2 CONVERGE_TIMEOUT=12 \
    bash "$GATE" --compose-dir "$WORK_DIR" --timeout 6 --check-interval 2 $VERBOSE || rc=$?
if [[ $rc -eq 0 ]]; then
    pass "gate converged and returned 0"
else
    fail "gate returned rc=$rc, expected 0 (converge round 2 did not complete)"
    failures=$((failures + 1))
fi

# --- Case 2: one round is not enough -> the knobs are really read from the env -----
# Guards against the fix regressing into hardcoded values: if CONVERGE_ROUNDS were
# ignored, the script would fall back to its default of 4 rounds and pass this too.
info "Case 2: same service, CONVERGE_ROUNDS=1 -> expect non-zero (env is honoured)"
reset_fixture
rc=0
CONVERGE_ROUNDS=1 CONVERGE_TIMEOUT=12 \
    bash "$GATE" --compose-dir "$WORK_DIR" --timeout 6 --check-interval 2 >/dev/null 2>&1 || rc=$?
if [[ $rc -ne 0 ]]; then
    pass "gate failed with rc=$rc, as expected with a single round"
else
    fail "gate returned 0 with CONVERGE_ROUNDS=1 — the environment is being ignored"
    failures=$((failures + 1))
fi

# --- Case 3: the wrapper budget itself ---------------------------------------------
# The two cases above exercise the script, which could always converge on its own. The
# actual production failure was the timeout(1) wrapper around it, so reproduce both
# budgets here with the same shape validate-post-deploy.yml uses.
#   old: health_check_timeout + 60             -- blind to the converge rounds
#   new: + health_converge_rounds x health_converge_timeout
# A slack of 5 stands in for the role's 60s; the ratio is what matters.
T=6; R=2; C=12
old_budget=$((T + 5))
new_budget=$((T + R * C + 10))

info "Case 3a: old-style wrapper (timeout ${old_budget}s, blind to converge) -> expect rc=124"
reset_fixture
rc=0
CONVERGE_ROUNDS=$R CONVERGE_TIMEOUT=$C \
    timeout -k 5 "$old_budget" bash "$GATE" --compose-dir "$WORK_DIR" \
    --timeout $T --check-interval 2 >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 124 ]]; then
    pass "old budget kills the gate mid-converge with rc=124 — the bug reproduces"
else
    fail "expected rc=124 from the old budget, got rc=$rc (fixture no longer reproduces the bug)"
    failures=$((failures + 1))
fi

info "Case 3b: derived wrapper (timeout ${new_budget}s) -> expect rc=0"
reset_fixture
rc=0
CONVERGE_ROUNDS=$R CONVERGE_TIMEOUT=$C \
    timeout -k 5 "$new_budget" bash "$GATE" --compose-dir "$WORK_DIR" \
    --timeout $T --check-interval 2 >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 0 ]]; then
    pass "derived budget outlives the converge rounds and the gate returns 0"
else
    fail "gate returned rc=$rc under the derived budget, expected 0"
    failures=$((failures + 1))
fi

echo
if [[ $failures -eq 0 ]]; then
    pass "health gate converge-by-retry: 4/4 cases OK"
    exit 0
fi
fail "health gate converge-by-retry: $failures case(s) failed"
exit 1

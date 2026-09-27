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
# Cases 5-6 (no healthcheck) run the gate on a crash-looping and a stable container.
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

# Start the fixture in $WORK_DIR, loudly. It used to be `up -d >/dev/null 2>&1` under
# set -e: when it failed (#414), the script died right after "Case 1" with no trace of why.
# The retry drops the fixture's images and pulls them again first: on the Jenkins node the
# containerd snapshotter lost a layer of alpine:3.20 ("failed to create snapshot: missing
# parent ... bucket: not found", #415), and only a fresh pull clears that. A second
# failure prints compose's own error.
fixture_up() {
    local out
    if out=$(docker compose -f "$WORK_DIR/docker-compose.yml" up -d 2>&1); then
        return 0
    fi
    info "fixture 'docker compose up' failed, retrying once: $(tail -3 <<<"$out")"
    docker compose -f "$WORK_DIR/docker-compose.yml" down -v --remove-orphans --rmi all >/dev/null 2>&1 || true
    docker compose -f "$WORK_DIR/docker-compose.yml" pull >/dev/null 2>&1 || true
    if out=$(docker compose -f "$WORK_DIR/docker-compose.yml" up -d 2>&1); then
        return 0
    fi
    fail "fixture 'docker compose up' failed in $WORK_DIR:"
    echo "$out" | tail -20
    exit 1
}

# Each case gets a pristine container: the fixture's boot counter lives on the
# container's writable layer, so a reused container would start already-healthy.
reset_fixture() {
    cleanup
    WORK_DIR="$(mktemp -d)"
    cp "$FIXTURE_SRC/docker-compose.yml" "$WORK_DIR/"
    fixture_up
}

failures=0

# --- Case 1: heals in converge round 2 -> the gate must accept it ------------------
# Before the fix this is the run that died at rc=124 without ever reaching round 2.
info "Case 1: service heals in converge round 2, CONVERGE_ROUNDS=2 -> expect rc=0"
reset_fixture
rc=0
# CONVERGE_SETTLE_WAITS is what makes this deterministic on a loaded agent. Build #347 ran
# on one where `docker compose restart` alone took 67s and a single check iteration 43s: the
# round-1 restart was still booting when the round ended, so the service read 'starting',
# round 2 found nothing 'unhealthy' to restart and the gate gave up one restart short.
CONVERGE_ROUNDS=2 CONVERGE_TIMEOUT=12 CONVERGE_SETTLE_WAITS=2 \
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
# Settle waits off: they only ever wait, never restart, so they cannot turn a one-round run
# green — but they would spend two more CONVERGE_TIMEOUTs proving it.
CONVERGE_ROUNDS=1 CONVERGE_TIMEOUT=12 CONVERGE_SETTLE_WAITS=0 \
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
#   new: + (health_converge_rounds + health_converge_settle_waits) x health_converge_timeout
# A slack of 5 stands in for the role's 60s; the ratio is what matters.
T=6; R=2; C=12; S=1
old_budget=$((T + 5))
new_budget=$((T + (R + S) * C + 10))

info "Case 3a: old-style wrapper (timeout ${old_budget}s, blind to converge) -> expect rc=124"
reset_fixture
rc=0
CONVERGE_ROUNDS=$R CONVERGE_TIMEOUT=$C CONVERGE_SETTLE_WAITS=$S \
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
CONVERGE_ROUNDS=$R CONVERGE_TIMEOUT=$C CONVERGE_SETTLE_WAITS=$S \
    timeout -k 5 "$new_budget" bash "$GATE" --compose-dir "$WORK_DIR" \
    --timeout $T --check-interval 2 >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 0 ]]; then
    pass "derived budget outlives the converge rounds and the gate returns 0"
else
    fail "gate returned rc=$rc under the derived budget, expected 0"
    failures=$((failures + 1))
fi

# --- Case 4: crash loop -------------------------------------------------------------
# gbif-es, 2026-08-06: species-list could not reach its MySQL user, died on boot, and
# `restart: unless-stopped` brought it back every few seconds. Each restart resets the
# health status to "starting", so the gate — classifying on health status alone — waited
# on it for 73 minutes and converge never touched it (it only restarts *unhealthy*).
# The gate must recognise the climbing .RestartCount and stop straight away instead.
info "Case 4: crash-looping service -> expect the gate to abort quickly, not burn the budget"
cleanup
WORK_DIR="$(mktemp -d)"
cp "$SCRIPT_DIR/fixtures/wait-for-health-crashloop/docker-compose.yml" "$WORK_DIR/"
fixture_up

# Budget deliberately generous: the point is that the gate returns long before it.
start=$(date +%s)
rc=0
CRASHLOOP_RESTARTS=2 CONVERGE_ROUNDS=2 CONVERGE_TIMEOUT=30 \
    bash "$GATE" --compose-dir "$WORK_DIR" \
    --timeout 60 --check-interval 2 >"$WORK_DIR/out.log" 2>&1 || rc=$?
elapsed=$(( $(date +%s) - start ))

if [[ $rc -eq 0 ]]; then
    fail "gate returned 0 for a container that never becomes healthy"
    failures=$((failures + 1))
elif ! grep -qi 'crash-looping' "$WORK_DIR/out.log"; then
    fail "gate failed (rc=$rc) but never identified the crash loop; it cannot tell it from a slow boot"
    sed -n '1,25p' "$WORK_DIR/out.log"
    failures=$((failures + 1))
elif [[ $elapsed -ge 60 ]]; then
    fail "gate detected the crash loop but only after ${elapsed}s — it waited out the full timeout anyway"
    failures=$((failures + 1))
else
    pass "crash loop detected in ${elapsed}s (rc=$rc) instead of burning the timeout and every converge round"
fi

# --- Case 5: crash loop WITHOUT a healthcheck -------------------------------------
# Build #403: gatus has no HEALTHCHECK, panicked on a duplicate endpoint at boot and was
# restarted forever. The gate accepted "running" on the first pass and returned before
# it could see RestartCount climb, so the build went on with gatus down.
info "Case 5: crash-looping service with no healthcheck -> expect the crash loop to be caught"
cleanup
WORK_DIR="$(mktemp -d)"
cp "$SCRIPT_DIR/fixtures/wait-for-health-nohealthcheck/docker-compose.yml" "$WORK_DIR/"
fixture_up

start=$(date +%s)
rc=0
CRASHLOOP_RESTARTS=2 NOHEALTHCHECK_MIN_UPTIME=10 CONVERGE_ROUNDS=1 CONVERGE_TIMEOUT=30 \
    bash "$GATE" --compose-dir "$WORK_DIR" --service crash-looper-nohc \
    --timeout 60 --check-interval 2 >"$WORK_DIR/out.log" 2>&1 || rc=$?
elapsed=$(( $(date +%s) - start ))

if [[ $rc -eq 0 ]]; then
    fail "gate returned 0 for a no-healthcheck container that keeps crashing"
    failures=$((failures + 1))
elif ! grep -qi 'crash-looping' "$WORK_DIR/out.log"; then
    fail "gate failed (rc=$rc) but never identified the crash loop"
    sed -n '1,25p' "$WORK_DIR/out.log"
    failures=$((failures + 1))
else
    pass "no-healthcheck crash loop detected in ${elapsed}s (rc=$rc)"
fi

# --- Case 6: a stable service without a healthcheck still passes -----------------
# The other side of case 5 (mailhog): waiting for it to prove it stays up must cost one
# NOHEALTHCHECK_MIN_UPTIME, not fail it.
info "Case 6: stable service with no healthcheck -> expect rc=0"
rc=0
NOHEALTHCHECK_MIN_UPTIME=10 CONVERGE_ROUNDS=1 CONVERGE_TIMEOUT=30 \
    bash "$GATE" --compose-dir "$WORK_DIR" --service steady-nohc \
    --timeout 60 --check-interval 2 >"$WORK_DIR/out6.log" 2>&1 || rc=$?
if [[ $rc -eq 0 ]]; then
    pass "stable no-healthcheck service accepted"
else
    fail "gate returned rc=$rc for a no-healthcheck service that stays up"
    sed -n '1,25p' "$WORK_DIR/out6.log"
    failures=$((failures + 1))
fi

echo
if [[ $failures -eq 0 ]]; then
    pass "health gate converge-by-retry: 7/7 cases OK"
    exit 0
fi
fail "health gate converge-by-retry: $failures case(s) failed"
exit 1

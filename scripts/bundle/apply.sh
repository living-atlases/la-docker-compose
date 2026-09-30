#!/usr/bin/env bash
# MEASUREMENT SPIKE (TASK-50, Jenkins stage 'Bundle spike'), NOT a deploy path: Ansible is
# still the only way to deploy (see CLAUDE.md). Times what a deploy costs once Ansible is
# out of the critical path: restore the bundle capture.sh took, pull, up, wait for health.
#
# Phases (run as root on the host):
#   live  restore over the running stack, pull --policy missing, up, health  (redeploy floor)
#   down  docker compose down, keeping volumes and /data                     (cold-start prep)
#   cold  restore, pull --policy missing, up, health on a stack that is down (new-portal floor,
#         minus the init steps an empty volume would still need: those are Ansible-only
#         until they become init containers, phase 2)
#
# Usage: apply.sh --phase live|down|cold [--bundle FILE] [--compose-dir DIR]
#                 [--health-script FILE] [--health-timeout S] [--health-budget S]
# Prints one "BUNDLE-TIMING host=<h> phase=<p> step=<s> seconds=<n>" line per step and a
# step=total line; exits non-zero when a step fails (health included).
set -euo pipefail

PHASE=""
BUNDLE=/var/cache/la-bundle/bundle.tgz
COMPOSE_DIR=/data/docker-compose
HEALTH_SCRIPT=""
HEALTH_TIMEOUT=300
HEALTH_BUDGET=1800
while [ $# -gt 0 ]; do
  case "$1" in
    --phase) PHASE="$2"; shift 2 ;;
    --bundle) BUNDLE="$2"; shift 2 ;;
    --compose-dir) COMPOSE_DIR="$2"; shift 2 ;;
    --health-script) HEALTH_SCRIPT="$2"; shift 2 ;;
    --health-timeout) HEALTH_TIMEOUT="$2"; shift 2 ;;
    --health-budget) HEALTH_BUDGET="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$PHASE" in live|down|cold) ;; *) echo "--phase must be live, down or cold" >&2; exit 2 ;; esac
[ -n "$HEALTH_SCRIPT" ] || HEALTH_SCRIPT="$(dirname "$0")/wait-for-health.sh"

host="$(hostname)"
t0=$(date +%s)
timing() { echo "BUNDLE-TIMING host=$host phase=$PHASE step=$1 seconds=$2"; }

step() {
  local name="$1"; shift
  local s rc=0
  s=$(date +%s)
  echo "==> [$host] $PHASE: $name"
  "$@" || rc=$?
  timing "$name" "$(( $(date +%s) - s ))"
  if [ "$rc" -ne 0 ]; then
    echo "BUNDLE-FAILED host=$host phase=$PHASE step=$name rc=$rc"
    timing total "$(( $(date +%s) - t0 ))"
    exit "$rc"
  fi
}

restore() {
  [ -f "$BUNDLE" ] || { echo "no bundle at $BUNDLE: run capture.sh first" >&2; return 1; }
  tar -xzf "$BUNDLE" -P
}
compose() { (cd "$COMPOSE_DIR" && docker compose "$@"); }
health() {
  # Same knobs validate-post-deploy.yml passes, and the same outer timeout(1) belt.
  CONVERGE_ROUNDS="${CONVERGE_ROUNDS:-2}" CONVERGE_TIMEOUT="${CONVERGE_TIMEOUT:-600}" \
  CONVERGE_SETTLE_WAITS="${CONVERGE_SETTLE_WAITS:-2}" \
    timeout -k 30 "$HEALTH_BUDGET" bash "$HEALTH_SCRIPT" \
      --compose-dir "$COMPOSE_DIR" --timeout "$HEALTH_TIMEOUT" --check-interval 5
}

case "$PHASE" in
  live|cold)
    step restore restore
    step pull compose pull --quiet --policy missing
    step up compose up -d --remove-orphans
    step health health
    ;;
  down)
    # No service sets stop_grace_period, so the default 10s would SIGKILL the datastores
    # and the cold start would time their crash recovery, which a new portal never does.
    step down compose down --remove-orphans --timeout 120
    ;;
esac
timing total "$(( $(date +%s) - t0 ))"

#!/usr/bin/env bash
# Regression test: a biocollect that booted before CAS is restarted until its hub loads, and a
# working one keeps its container. The script is extracted from the role at run time, and docker
# and sleep are stubbed, so this drives the real logic without a stack.
#
# Run: scripts/test-biocollect-hub-recovery.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d -t la-biocollect-hub-XXXXXX)"
cleanup() { [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]] && rm -rf -- "$WORK_DIR"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

python3 - "$REPO_ROOT/roles/la-compose/tasks/recover-biocollect-hub.yml" > "$WORK_DIR/recover.sh" <<'PY'
import re, sys, yaml
script = yaml.safe_load(open(sys.argv[1]))[0]["ansible.builtin.shell"]
print(re.sub(r"\{\{\s*(\w+)\s*\|\s*default\('([^']*)'\)\s*\}\}", r"\2", script))
PY

mkdir "$WORK_DIR/bin"
printf '#!/bin/sh\n' > "$WORK_DIR/bin/sleep"
cat > "$WORK_DIR/bin/docker" <<'STUB'
#!/usr/bin/env bash
# $HEALTHY_AFTER: how many restarts it takes for the hub to answer 200.
restarts="$(wc -l < "$STATE")"
if [[ "$1" == restart ]]; then echo x >> "$STATE"; exit 0; fi
if (( restarts >= HEALTHY_AFTER )); then printf 200; else printf 404; fi
STUB
chmod +x "$WORK_DIR/bin/sleep" "$WORK_DIR/bin/docker"

# Runs the script; sets OUT, RC and RESTARTS.
run() {
  export STATE="$WORK_DIR/state" HEALTHY_AFTER="$1"
  : > "$STATE"
  RC=0
  OUT="$(PATH="$WORK_DIR/bin:$PATH" bash "$WORK_DIR/recover.sh" 2>&1)" || RC=$?
  RESTARTS="$(wc -l < "$STATE")"
}

run 0
[[ "$RC" == 0 && "$RESTARTS" == 0 && "$OUT" == "already loaded" ]] \
  || fail "a working biocollect must keep its container (rc=$RC restarts=$RESTARTS: $OUT)"
echo "[PASS] a loaded hub is left alone"

run 1
[[ "$RC" == 0 && "$RESTARTS" == 1 && "$OUT" == "restarted" ]] \
  || fail "one restart should be enough (rc=$RC restarts=$RESTARTS: $OUT)"
echo "[PASS] a missing hub gets a restart"

run 3
[[ "$RC" == 0 && "$RESTARTS" == 3 ]] || fail "an early restart must be retried (rc=$RC restarts=$RESTARTS)"
echo "[PASS] a restart that came too early is retried"

run 99
[[ "$RC" == 1 && "$RESTARTS" == 3 && "$OUT" == *"never loaded"* ]] \
  || fail "a hub that never loads must fail the deploy (rc=$RC restarts=$RESTARTS: $OUT)"
echo "[PASS] a hub that never loads fails the deploy"

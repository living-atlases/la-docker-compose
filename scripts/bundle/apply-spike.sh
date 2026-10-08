#!/usr/bin/env bash
# CI only (Jenkins stage 'Apply spike'): apply the bundles render.sh --export
# wrote to the stack Ansible just deployed, and check the applier keeps the redeploy contract.
#   1. converge: apply on every host. It must pass; it may restart what really changed since
#      the last Ansible deploy (CI renders ala-install's branch tip, which can be newer than
#      what the stack runs: #446 restarted regions for ala-install e2c71b97), reported only;
#   1b. no change: the same bundles again. Nothing may restart on config grounds and every
#      running container must stay in place (same name, same ID);
#   2. controlled config change on the first host (add-marker.py: one harmless file in one
#      watched config dir): that service, and only that one, is restarted;
#   3. the original bundle again on that host: the marker is deleted (dropped by the render)
#      and the service restarted once more, so the host ends as Ansible left it.
# Prints BUNDLE-TIMING host=all phase=apply<n> lines and one APPLY-SPIKE-PROBLEM line per
# broken expectation; exits non-zero if there was any.
#
# Usage: apply-spike.sh --out DIR   (DIR from render.sh --out DIR --export)
set -euo pipefail

OUT=""
SSH_OPTS="${LA_BUNDLE_SSH_OPTS:--o BatchMode=yes -o StrictHostKeyChecking=no}"
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -d "$OUT/export" ] && [ -f "$OUT/hosts" ] || { echo "--out must be a render.sh --export dir" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
APPLY="${LA_BUNDLE_APPLY:-$HERE/la-bundle-apply.sh}"

problems=0
problem() { echo "APPLY-SPIKE-PROBLEM: $*"; problems=$((problems + 1)); }
apply() { # $1 hosts file, $2 log, $3 phase
  local s rc=0
  s=$(date +%s)
  LA_BUNDLE_SSH_OPTS="$SSH_OPTS" bash "$APPLY" --export-dir "$OUT/export" --hosts "$1" >"$2" 2>&1 || rc=$?
  cat "$2"
  echo "BUNDLE-TIMING host=all phase=$3 seconds=$(( $(date +%s) - s )) rc=$rc"
  return "$rc"
}
ids() {
  local ah
  # shellcheck disable=SC2086
  while read -r _ ah; do
    ssh $SSH_OPTS "$ah" "sudo docker ps --format '{{.Names}} {{.ID}}'" </dev/null | sed "s|^|$ah |"
  done <"$OUT/hosts" | sort
}

# 1. converge
apply "$OUT/hosts" "$OUT/apply1.log" apply1 || problem "the converge apply failed"
echo "converge restarts (config changed since the last deploy): $(grep -c ': RESTARTED' "$OUT/apply1.log" || true)"

# 1b. no change
ids >"$OUT/ids.before"
apply "$OUT/hosts" "$OUT/apply1b.log" apply1b || problem "the no-change apply failed"
ids >"$OUT/ids.after"
if grep -q ': RESTARTED' "$OUT/apply1b.log"; then
  problem "the no-change apply restarted: $(grep ': RESTARTED' "$OUT/apply1b.log" | tr '\n' ';')"
fi
gone=$(comm -23 "$OUT/ids.before" "$OUT/ids.after")
[ -z "$gone" ] || problem "the no-change apply replaced or stopped running containers: $(echo "$gone" | tr '\n' ';')"

# 2. a controlled config change on the first host
read -r ih ah <"$OUT/hosts"
e="$OUT/export/$ih"
echo "$ih $ah" >"$OUT/hosts.first"
mv "$e/bundle.tgz" "$e/bundle.orig.tgz"
read -r svc marker < <(python3 "$HERE/add-marker.py" "$e/bundle.orig.tgz" "$e/bundle.tgz")
echo "controlled change: $marker (service $svc) on $ih"
apply "$OUT/hosts.first" "$OUT/apply2.log" apply2 || problem "the config-change apply failed"
grep -q "^\[$ih\] $svc: RESTARTED" "$OUT/apply2.log" || problem "$svc was not restarted for its config change"
n=$(grep -c ': RESTARTED' "$OUT/apply2.log" || true)
[ "$n" = 1 ] || problem "the config change restarted $n services, not only $svc"

# 3. back to the original bundle
mv -f "$e/bundle.orig.tgz" "$e/bundle.tgz"
apply "$OUT/hosts.first" "$OUT/apply3.log" apply3 || problem "the revert apply failed"
grep -q "removed (dropped by the render) $marker" "$OUT/apply3.log" || problem "the marker was not deleted on revert"
grep -q "^\[$ih\] $svc: RESTARTED" "$OUT/apply3.log" || problem "$svc was not restarted on revert"

echo "APPLY-SPIKE problems=$problems"
[ "$problems" -eq 0 ]

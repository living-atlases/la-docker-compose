#!/usr/bin/env bash
# TASK-50 phase 5: apply the bundles scripts/bundle/render.sh --export wrote to every host of
# a portal, in parallel, without Ansible. Per host: stream its export dir plus host-apply.sh
# over ssh into a root-only temp dir, run host-apply.sh with sudo, delete the dir (a trap on
# the host side, so a failed apply does not leave secrets behind).
#
# v1 scope: redeploy of a portal Ansible deployed before (see host-apply.sh for what is still
# Ansible's). All hosts go at once: on a redeploy every datastore is already up.
#
# Usage: la-bundle-apply.sh --export-dir DIR/export --hosts DIR/hosts [--ssh-opts "..."] [--ssh-user U]
#          --hosts: "<inventory_hostname> <ssh target>" per line (render.sh writes DIR/hosts)
# Prints each host's output prefixed with "[<inventory_hostname>]", then one
# "BUNDLE-APPLY host=<h> rc=<n>" line per host; exits non-zero if any host failed.
set -euo pipefail

EXPORT_DIR=""
HOSTS=""
SSH_OPTS="${LA_BUNDLE_SSH_OPTS:--o BatchMode=yes}"
while [ $# -gt 0 ]; do
  case "$1" in
    --export-dir) EXPORT_DIR="$2"; shift 2 ;;
    --hosts) HOSTS="$2"; shift 2 ;;
    --ssh-opts) SSH_OPTS="$2"; shift 2 ;;
    --ssh-user) SSH_OPTS="$SSH_OPTS -l $2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -d "$EXPORT_DIR" ] && [ -f "$HOSTS" ] || { echo "--export-dir and --hosts are required" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"

logs="$(mktemp -d)"
trap 'rm -rf "$logs"' EXIT

apply_one() {
  local ih="$1" target="$2" d="$EXPORT_DIR/$1"
  [ -f "$d/bundle.tgz" ] || { echo "no bundle exported for $ih"; return 1; }
  # shellcheck disable=SC2086,SC2029
  tar -cf - -C "$d" . -C "$HERE" host-apply.sh |
    ssh $SSH_OPTS "$target" "set -e; umask 077; d=\$(mktemp -d /tmp/la-bundle.XXXXXX)
      trap 'rm -rf \"\$d\"' EXIT
      tar -xf - -C \"\$d\"
      sudo bash \"\$d/host-apply.sh\" --dir \"\$d\" --host '$ih'"
}

pids=()
names=()
while read -r ih target; do
  [ -n "$ih" ] || continue
  ( apply_one "$ih" "$target" 2>&1 | sed -u "s/^/[$ih] /"; exit "${PIPESTATUS[0]}" ) &
  pids+=("$!")
  names+=("$ih")
done <"$HOSTS"
[ "${#pids[@]}" -gt 0 ] || { echo "no hosts in $HOSTS" >&2; exit 2; }

failed=0
for i in "${!pids[@]}"; do
  rc=0
  wait "${pids[$i]}" || rc=$?
  echo "BUNDLE-APPLY host=${names[$i]} rc=$rc"
  [ "$rc" -eq 0 ] || failed=$((failed + 1))
done
[ "$failed" -eq 0 ] || { echo "BUNDLE-APPLY FAILED on $failed host(s)"; exit 1; }

#!/usr/bin/env bash
# MEASUREMENT SPIKE (TASK-50, Jenkins stage 'Bundle spike'), NOT a deploy path: Ansible is
# still the only way to deploy (see CLAUDE.md). This captures what a future "bundle" would
# carry so apply.sh can time "pull + up" without Ansible in front of it.
#
# Captures, on a host Ansible already deployed, the rendered compose dir plus the SOURCES of
# every bind mount the compose config declares. Data stays out: logs, caches, downloads,
# backups, anything under the system dirs (BUNDLE_SYSTEM_DIRS: /var /etc /tmp /run /proc
# /sys /dev) and any source bigger than --max-mb.
#
# The bundle holds secrets (.env and rendered configs): it is written root-only (0600) and
# never leaves the host. Only paths and sizes are printed, never file contents.
#
# Usage: capture.sh [--compose-dir DIR] [--out DIR] [--max-mb N]
# Prints: BUNDLE-TIMING host=<h> step=capture seconds=<s> size_kb=<k> paths=<n> excluded=<m>
set -euo pipefail

COMPOSE_DIR=/data/docker-compose
OUT=/var/cache/la-bundle
MAX_MB=100
SYSTEM_DIRS="${BUNDLE_SYSTEM_DIRS:-/var /etc /tmp /run /proc /sys /dev}"
while [ $# -gt 0 ]; do
  case "$1" in
    --compose-dir) COMPOSE_DIR="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --max-mb) MAX_MB="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

start=$(date +%s)
umask 077
mkdir -p "$OUT"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

(cd "$COMPOSE_DIR" && docker compose config --format json) | python3 -c '
import json, sys
d = json.load(sys.stdin)
s = set()
for svc in d.get("services", {}).values():
    for m in svc.get("volumes", []) or []:
        if m.get("type") == "bind" and m.get("source"):
            s.add(m["source"])
print("\n".join(sorted(s)))' >"$work/binds"

echo "$COMPOSE_DIR" >"$work/include"
: >"$work/excluded"
while IFS= read -r src; do
  [ -n "$src" ] || continue
  case "$src" in "$COMPOSE_DIR"|"$COMPOSE_DIR"/*) continue ;; esac
  if [ ! -e "$src" ]; then echo "missing $src" >>"$work/excluded"; continue; fi
  case "$src" in
    */logs|*/logs/*|*/log|*/log/*|*/cache|*/cache/*|*download*|*backup*)
      echo "data $src" >>"$work/excluded"; continue ;;
  esac
  sys=""
  for d in $SYSTEM_DIRS; do case "$src" in "$d"/*) sys=1 ;; esac; done
  if [ -n "$sys" ]; then echo "system $src" >>"$work/excluded"; continue; fi
  mb=$(du -sm "$src" | cut -f1)
  if [ "$mb" -gt "$MAX_MB" ]; then echo "big(${mb}MB) $src" >>"$work/excluded"; continue; fi
  echo "$src" >>"$work/include"
done <"$work/binds"

tar --exclude="$COMPOSE_DIR/db-backups" -czf "$OUT/bundle.tgz.new" -P -T "$work/include"
mv -f "$OUT/bundle.tgz.new" "$OUT/bundle.tgz"
chmod 0600 "$OUT/bundle.tgz"
cp "$work/include" "$OUT/include.txt"
cp "$work/excluded" "$OUT/excluded.txt"

echo "Excluded from the bundle:"
sed 's/^/  /' "$work/excluded"
size_kb=$(du -k "$OUT/bundle.tgz" | cut -f1)
echo "BUNDLE-TIMING host=$(hostname) step=capture seconds=$(( $(date +%s) - start )) size_kb=$size_kb paths=$(wc -l <"$work/include") excluded=$(wc -l <"$work/excluded")"

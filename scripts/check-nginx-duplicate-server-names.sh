#!/usr/bin/env bash
# Fail when two enabled nginx vhost files declare the same server_name.
#
# nginx keeps the first server{} for a name+port and drops the rest with only a
# "conflicting server name ... ignored" warning, so every location in the losing
# file silently 404s. That is how hub.l-a.site lost /records (TASK-44): the hub
# apps and the cross-host stub each wrote their own server{} for the shared
# hostname instead of fragments of one file.
#
# Usage: scripts/check-nginx-duplicate-server-names.sh [SITES_ENABLED_DIR]
#   default: /data/docker-compose/nginx/sites-enabled
set -eu

DIR="${1:-/data/docker-compose/nginx/sites-enabled}"
[ -d "$DIR" ] || { echo "[SKIP] $DIR not found"; exit 0; }

# One "<name>\t<file>" line per server_name word, per file (deduplicated within a file:
# the http and https server{} of one vhost legitimately repeat the name).
dups="$(
  for f in "$DIR"/*.conf; do
    [ -e "$f" ] || continue
    sed -n 's/^[[:space:]]*server_name[[:space:]]\+\([^;]*\);.*/\1/p' "$f" |
      tr -s ' \t' '\n' | grep -v '^_\?$' | sort -u |
      sed "s|\$|	$(basename "$f")|"
  done | sort | awk -F'\t' '
    { files[$1] = files[$1] (files[$1] ? ", " : "") $2; n[$1]++ }
    END { for (k in n) if (n[k] > 1) print k ": " files[k] }' | sort
)"

if [ -n "$dups" ]; then
  echo "[FAIL] server_name declared in more than one file in $DIR:" >&2
  echo "$dups" | sed 's/^/    /' >&2
  exit 1
fi
echo "[PASS] no server_name declared in more than one file in $DIR"

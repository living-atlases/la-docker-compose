#!/usr/bin/env bash
# roles/la-compose/files/remove-file-mount-artifacts.py against fixtures. A missing file
# bind-mount source becomes a Docker-created DIRECTORY, and the template then writes into
# it forever (nginx.conf, a data hub's -config.properties on docker-1, #417-#419).
# The script must remove those, and must leave alone real directory mounts, real files,
# and any directory with real content in it. ~1s, no Docker.
set -eu
cd "$(dirname "$0")/.."
SCRIPT=roles/la-compose/files/remove-file-mount-artifacts.py

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
c="$tmp/compose"; d="$tmp/data"
mkdir -p "$c/services" "$c/infrastructure" "$d/hub/config" "$d/solr" "$d/nginx"

# artifacts: a dir at a file path, empty or holding the misplaced template output
mkdir -p "$d/hub/config/hub-config.properties" "$d/nginx/nginx.conf"
touch "$d/hub/config/hub-config.properties/config.properties"
# must survive: a real file, a real directory mount, a "file-like" dir with real content
echo "a=b" >"$d/hub/config/logback.xml"
mkdir -p "$d/keep.conf/sub"; touch "$d/keep.conf/sub/x"

cat >"$c/services/hub.yml" <<YML
services:
  hub:
    volumes:
      - $d/hub:/data/ala-hub
      - $d/hub/config/hub-config.properties:/data/ala-hub/config/ala-hub-config.properties:ro
      - "$d/hub/config/logback.xml:/data/ala-hub/config/logback.xml:ro"
      - $d/keep.conf:/etc/keep.conf
YML
cat >"$c/infrastructure/nginx.yml" <<YML
services:
  nginx:
    volumes:
      - $d/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - $d/solr:/var/solr
YML
echo "include: []" >"$c/docker-compose.yml"

out="$(python3 "$SCRIPT" "$c")" || fail "script failed: $out"
# replaced by an empty FILE, so a restarting container cannot recreate the directory
[ -f "$d/hub/config/hub-config.properties" ] && [ ! -s "$d/hub/config/hub-config.properties" ] || fail "hub config artifact not replaced by an empty file"
[ -f "$d/nginx/nginx.conf" ] && [ ! -s "$d/nginx/nginx.conf" ] || fail "nginx.conf artifact not replaced by an empty file"
echo "$out" | tail -1 | grep -qx "removed 2" || fail "expected 'removed 2', got: $out"
pass "directories Docker left at file mount paths are replaced by empty files"

[ -f "$d/hub/config/logback.xml" ] || fail "a real file mount source was touched"
[ -d "$d/hub" ] && [ -d "$d/solr" ] || fail "a real directory mount was removed"
[ -f "$d/keep.conf/sub/x" ] || fail "a file-like directory with real content was removed"
pass "real files, directory mounts and directories with content are left alone"

out="$(python3 "$SCRIPT" "$c")"
echo "$out" | tail -1 | grep -qx "removed 0" || fail "second run not idempotent: $out"
pass "a second run removes nothing"

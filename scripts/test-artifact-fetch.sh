#!/usr/bin/env bash
# roles/la-compose/tasks/artifact-fetch-{start,finish}.yml: large data artifacts only an
# ingest needs (geocode shapefiles: 29 min from S3 in #426/#427; SDS layers: 30 min from
# ALA's archive) are fetched from upstream in the background, into a host-local cache
# outside data_dir, and unpacked before `docker compose up`. Against a local HTTP server
# that answers after a delay:
#   1. the start returns before the download has finished; the finish unpacks it and the
#      file sits in the cache, not in data_dir;
#   2. with its marker in place, nothing is requested at all;
#   3. after data_dir is wiped (CI CLEAN_MACHINE), a pinned artifact unpacks from the
#      cache with no request;
#   4. without a background job (a --tags run that skipped the start) the finish still
#      downloads and unpacks in the foreground;
#   5. an upstream that fails falls back to artifact_fallback_url;
#   6. an unpinned artifact (SDS layers) is cached by URL and only revalidated.
# ~40s, no Docker, no root.
set -eu
cd "$(dirname "$0")/.."
TASKS="$PWD/roles/la-compose/tasks"
ANSIBLE_PLAYBOOK="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}ansible-playbook"
command -v "$ANSIBLE_PLAYBOOK" >/dev/null || ANSIBLE_PLAYBOOK=ansible-playbook
# Modules run under the python that runs ansible-playbook (the venv's), not the target's
# /usr/bin/python3: on the Jenkins agent that one dies importing an unreadable root-owned
# _cffi_backend .so from /usr/local (#429).
PYARG='ansible_python_interpreter={{ ansible_playbook_python }}'
DELAY=4

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
server_pid=""
cleanup() { [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null; [ -n "${KEEP_TMP:-}" ] || rm -rf "$tmp"; }
trap cleanup EXIT

mkdir -p "$tmp/www" "$tmp/src"
echo dbf >"$tmp/src/cw_state_poly.dbf"
python3 -c 'import sys, zipfile; z = zipfile.ZipFile(sys.argv[1], "w"); z.write(sys.argv[2], "cw_state_poly.dbf"); z.close()' \
  "$tmp/www/shp.zip" "$tmp/src/cw_state_poly.dbf"
sha1="sha1:$(sha1sum "$tmp/www/shp.zip" | cut -d' ' -f1)"
echo layers >"$tmp/src/layer.txt"
tar -czf "$tmp/www/layers.tgz" -C "$tmp/src" layer.txt

# /bad/* answers 500; everything else is served after DELAY seconds. GETs are logged
# with their If-Modified-Since, so a revalidation is told apart from a download.
python3 - "$tmp/www" "$tmp/port" "$tmp/requests" "$DELAY" <<'PY' &
import functools, http.server, sys, time
root, port_file, req_log, delay = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
class H(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        ims = "ims" if self.headers.get("If-Modified-Since") else "full"
        open(req_log, "a").write(f"{self.path} {ims}\n")
        if self.path.startswith("/bad/"):
            self.send_error(500)
            return
        time.sleep(delay)
        super().do_GET()
    def log_message(self, *a): pass
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(H, directory=root))
open(port_file, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
server_pid=$!
for _ in $(seq 50); do [ -s "$tmp/port" ] && break; sleep 0.1; done
[ -s "$tmp/port" ] || fail "local HTTP server did not start"
base="http://127.0.0.1:$(cat "$tmp/port")"
cache="$tmp/cache"

# $1 case, $2 "start"|"nostart", then extra -e args. The play records whether the
# cached file existed right after the start returned.
run() {
  local name=$1 mode=$2; shift 2
  cat >"$tmp/play-$name.yml" <<YML
- hosts: localhost
  connection: local
  gather_facts: false
  tasks:
$( [ "$mode" = start ] && printf '    - ansible.builtin.include_tasks: %s/artifact-fetch-start.yml\n' "$TASKS" )
    - ansible.builtin.copy:
        dest: "$tmp/$name.after-start"
        content: "{{ (la_artifact_jobs | default({})).get(artifact_name, {}).get('cache_file', '') is file }}"
    - ansible.builtin.include_tasks: $TASKS/artifact-fetch-finish.yml
YML
  : >"$tmp/requests"
  ANSIBLE_LOCALHOST_WARNING=false "$ANSIBLE_PLAYBOOK" -i localhost, -e "$PYARG" "$tmp/play-$name.yml" \
    -e ansible_become=false -e "la_artifact_cache_dir=$cache" "$@" >"$tmp/$name.log" 2>&1 ||
    { cat "$tmp/$name.log" >&2; fail "$name: playbook failed"; }
}
nreq() { grep -c "$1" "$tmp/requests" || true; }
SHP=(-e artifact_name=shp -e "artifact_url=$base/shp.zip" -e "artifact_checksum=$sha1"
     -e "artifact_dest=$tmp/data/pipelines-shp" -e "artifact_creates=$tmp/data/pipelines-shp/cw_state_poly.dbf"
     -e "artifact_skip_if_exists=$tmp/data/pipelines-shp/cw_state_poly.dbf")

# 1. Fresh host.
run fresh start "${SHP[@]}"
[ "$(cat "$tmp/fresh.after-start")" = False ] ||
  fail "fresh: the file was already cached when the start returned, so it did not run in the background"
[ -f "$tmp/data/pipelines-shp/cw_state_poly.dbf" ] || fail "fresh: not unpacked"
[ "$(nreq ' full')" = 1 ] || fail "fresh: expected 1 download, got $(nreq ' full')"
[ -f "$cache/${sha1#sha1:}/shp.zip" ] || fail "fresh: the file is not in the cache"
[ -z "$(find "$tmp/data" -name '*.zip')" ] || fail "fresh: a copy of the zip was left in data_dir"
pass "the start returns before the download ends; the finish unpacks from the cache (1 download)"

# 2. Marker present: no request.
run unpacked start "${SHP[@]}"
[ ! -s "$tmp/requests" ] || fail "unpacked: $(grep -c . "$tmp/requests") request(s) with the marker in place"
pass "with the marker in place nothing is requested"

# 3. data_dir wiped, cache kept: no request.
rm -rf "$tmp/data"
run wiped start "${SHP[@]}"
[ -f "$tmp/data/pipelines-shp/cw_state_poly.dbf" ] || fail "wiped: not unpacked from the cache"
[ ! -s "$tmp/requests" ] || fail "wiped: $(grep -c . "$tmp/requests") request(s) for a pinned file already cached"
pass "after a wipe of data_dir a pinned artifact unpacks from the cache with no request"

# 4. No background job, empty cache: foreground download.
rm -rf "$tmp/data" "$cache"
run foreground nostart "${SHP[@]}"
[ -f "$tmp/data/pipelines-shp/cw_state_poly.dbf" ] || fail "foreground: nothing unpacked without the start"
pass "without a background job the finish downloads and unpacks in the foreground"

# 5. Upstream fails: fallback URL.
rm -rf "$tmp/data" "$cache"
run fallback start -e artifact_name=shp -e "artifact_url=$base/bad/shp.zip" -e "artifact_checksum=$sha1" \
  -e "artifact_fallback_url=$base/shp.zip" -e "artifact_dest=$tmp/data/pipelines-shp"
[ -f "$tmp/data/pipelines-shp/cw_state_poly.dbf" ] || fail "fallback: not unpacked from the fallback URL"
grep -q "WARNING: background download of shp failed" "$tmp/fallback.log" || fail "fallback: no WARNING for the failed background job"
pass "a failing upstream falls back to artifact_fallback_url, with a WARNING"

# 6. Unpinned (SDS layers): cached by URL, then only revalidated.
LAY=(-e artifact_name=sds-layers -e "artifact_url=$base/layers.tgz" -e "artifact_dest=$tmp/data/biocache/layers")
run unpinned-1 start "${LAY[@]}"
[ -f "$tmp/data/biocache/layers/layer.txt" ] || fail "unpinned: not unpacked"
rm -rf "$tmp/data"
run unpinned-2 start "${LAY[@]}"
[ -f "$tmp/data/biocache/layers/layer.txt" ] || fail "unpinned: not unpacked from the cache after a wipe"
[ "$(nreq ' full')" = 0 ] || fail "unpinned: downloaded again ($(nreq ' full')) although the cached copy is current"
pass "an unpinned artifact is cached by URL and only revalidated (If-Modified-Since)"
echo "All checks passed."

#!/usr/bin/env bash
# roles/la-compose/tasks/pipelines-shapefiles-{start,finish}.yml: the geocode shapefiles
# (29 min from S3 in CI, #426/#427, every host idle meanwhile) download in the background
# while the play goes on, and are unpacked before `docker compose up`. Against a local
# HTTP server that answers the zip after a delay:
#   1. the start returns before the download has finished, and the finish unpacks it;
#   2. a host that already has them unpacked sends no request at all;
#   3. without a background job (a --tags run that skipped the start) the finish still
#      downloads and unpacks in the foreground.
# ~20s, no Docker, no root.
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
cleanup() { [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT

mkdir -p "$tmp/www" "$tmp/src"
echo dbf >"$tmp/src/cw_state_poly.dbf"
python3 -c 'import sys, zipfile; z = zipfile.ZipFile(sys.argv[1], "w"); z.write(sys.argv[2], "cw_state_poly.dbf"); z.close()' \
  "$tmp/www/shp.zip" "$tmp/src/cw_state_poly.dbf"
sha1="sha1:$(sha1sum "$tmp/www/shp.zip" | cut -d' ' -f1)"

python3 - "$tmp/www" "$tmp/port" "$tmp/requests" "$DELAY" <<'EOF' &
import functools, http.server, sys, time
root, port_file, req_log, delay = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
class H(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        open(req_log, "a").write(self.path + "\n")
        time.sleep(delay)
        super().do_GET()
    def log_message(self, *a): pass
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(H, directory=root))
open(port_file, "w").write(str(srv.server_address[1]))
srv.serve_forever()
EOF
server_pid=$!
for _ in $(seq 50); do [ -s "$tmp/port" ] && break; sleep 0.1; done
[ -s "$tmp/port" ] || fail "local HTTP server did not start"
url="http://127.0.0.1:$(cat "$tmp/port")/shp.zip"

# $1 case, $2 "start" to include the start file. The play records when the start
# returned and whether the zip was complete by then.
run() {
  cat >"$tmp/play-$1.yml" <<YML
- hosts: localhost
  connection: local
  gather_facts: false
  tasks:
$( [ "$2" = start ] && printf '    - ansible.builtin.include_tasks: %s/pipelines-shapefiles-start.yml\n' "$TASKS" )
    - ansible.builtin.stat: {path: "{{ data_dir }}/pipelines-shp/pipelines-shapefiles.zip"}
      register: zip_after_start
    - ansible.builtin.copy:
        dest: "$tmp/$1.zip-after-start"
        content: "{{ zip_after_start.stat.exists }}"
    - ansible.builtin.include_tasks: $TASKS/pipelines-shapefiles-finish.yml
YML
  : >"$tmp/requests"
  ANSIBLE_LOCALHOST_WARNING=false "$ANSIBLE_PLAYBOOK" -i localhost, -e "$PYARG" "$tmp/play-$1.yml" \
    -e "data_dir=$tmp/data" -e "pipelines_shapefiles_url=$url" \
    -e "pipelines_shapefiles_checksum=$sha1" -e ansible_become=false \
    -e "docker_container_uid=$(id -u)" -e "docker_container_gid=$(id -g)" >"$tmp/$1.log" 2>&1 ||
    { cat "$tmp/$1.log" >&2; fail "$1: playbook failed"; }
}

# 1. Fresh host: background download, unpacked by the finish.
run fresh start
[ "$(cat "$tmp/fresh.zip-after-start")" = False ] ||
  fail "fresh: the zip was already there when the start returned, so it did not run in the background"
[ -f "$tmp/data/pipelines-shp/cw_state_poly.dbf" ] || fail "fresh: the finish did not unpack the shapefiles"
[ "$(grep -c . "$tmp/requests")" = 1 ] || fail "fresh: expected 1 request, got $(grep -c . "$tmp/requests")"
pass "the start returns before the download ends; the finish waits and unpacks (1 request)"

# 2. Already unpacked: no request.
run unpacked start
[ ! -s "$tmp/requests" ] || fail "unpacked: $(grep -c . "$tmp/requests") request(s) for shapefiles that were already unpacked"
pass "a host that already has them unpacked downloads nothing"

# 3. No background job: the finish downloads in the foreground.
rm -rf "$tmp/data"
run foreground nostart
[ -f "$tmp/data/pipelines-shp/cw_state_poly.dbf" ] || fail "foreground: nothing unpacked without the start"
pass "without a background job the finish downloads and unpacks in the foreground"
echo "All checks passed."

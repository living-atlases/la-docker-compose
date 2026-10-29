#!/usr/bin/env bash
# The name index download (ala-install namematching-service/tasks/download-nameindex.yml, also
# imported by sensitive-data-service). #505: one download on 2023-3 arrived corrupt (sha1
# mismatch after 11 s), the host dropped out of the play at minute 10 and the other two
# failed the health gate waiting for its services. Runs the real get_url task under Ansible
# against a local server:
#   1. the first answer corrupt, then the good file: the task retries and the host goes on;
#   2. always corrupt: it fails after its retries, and dest is never the corrupt file;
#   3. the task as it was before the retry fails on case 1 (the test sees the difference).
# ~10s, no Docker, no root, no network.
set -u
cd "$(dirname "$0")/.."
ANSIBLE_PLAYBOOK="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}ansible-playbook"
command -v "$ANSIBLE_PLAYBOOK" >/dev/null || ANSIBLE_PLAYBOOK=ansible-playbook
PY="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}python3"
command -v "$PY" >/dev/null || PY=python3
TASKS=ala-install/ansible/roles/namematching-service/tasks/download-nameindex.yml
T=$(mktemp -d)
srv=""
trap '[ -n "$srv" ] && kill "$srv" 2>/dev/null; rm -rf "$T"' EXIT
fail=0
ok()  { echo "[PASS] $1"; }
bad() { echo "[FAIL] $1" >&2; fail=1; }

head -c 200000 /dev/urandom > "$T/good.tgz"
head -c 120000 /dev/urandom > "$T/bad.tgz"
sha1=$(sha1sum "$T/good.tgz" | awk '{print $1}')

# Serves bad.tgz for the first $T/bad-count requests, then good.tgz; counts every GET.
cat > "$T/server.py" <<'PY'
import http.server, os, sys
d = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        n = int(open(f"{d}/hits").read() or 0) + 1 if os.path.exists(f"{d}/hits") else 1
        open(f"{d}/hits", "w").write(str(n))
        bad = int(open(f"{d}/bad-count").read())
        body = open(f"{d}/{'bad' if n <= bad else 'good'}.tgz", "rb").read()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(f"{d}/port", "w").write(str(s.server_port))
s.serve_forever()
PY
"$PY" "$T/server.py" "$T" & srv=$!
for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
[ -s "$T/port" ] || { bad "local server did not start"; exit 1; }
url="http://127.0.0.1:$(cat "$T/port")/nameindex.tgz"

# Only the download task of the file, as it is in $1 (the rest unpacks and rsyncs the index).
download_task() {
  "$PY" - "$1" "$2" <<'PY'
import sys, yaml
tasks = yaml.safe_load(open(sys.argv[1]))
t = [t for t in tasks if str(t.get("name", "")).startswith("Download nameindex")]
assert len(t) == 1, t
yaml.safe_dump(t, open(sys.argv[2], "w"))
PY
}
cat > "$T/play.yml" <<YML
- hosts: localhost
  gather_facts: false
  tasks:
    - ansible.builtin.import_tasks: $T/task.yml
YML
# run <how many bad answers first>: rc of the play; $T/hits the GETs it made.
run() {
  echo "$1" > "$T/bad-count"; rm -f "$T/hits" "$T/dest.tgz"
  ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_NOCOLOR=1 "$ANSIBLE_PLAYBOOK" -i localhost, -c local \
    -e "url=$url dest=$T/dest.tgz sha1=$sha1 nameindex_download_delay=0" \
    -e 'ansible_python_interpreter={{ ansible_playbook_python }}' "$T/play.yml" >"$T/run.log" 2>&1
}
hits() { cat "$T/hits" 2>/dev/null || echo 0; }

download_task "$TASKS" "$T/task.yml"
if run 1 && cmp -s "$T/dest.tgz" "$T/good.tgz" && [ "$(hits)" = 2 ]; then
  ok "a corrupt first download is retried and the good one lands in dest"
else
  cat "$T/run.log" >&2; bad "one corrupt answer: rc/dest/hits=$(hits) wrong"
fi
if ! run 99 && [ ! -e "$T/dest.tgz" ] && [ "$(hits)" = 4 ]; then
  ok "always corrupt: fails after 1 + 3 retries, without leaving the corrupt file in dest"
else
  cat "$T/run.log" >&2; bad "always corrupt: expected a failure after 4 GETs and no dest, got $(hits) GETs"
fi

# The task before the retry, from git: it must fail on the case the retry fixes.
added=$(git -C ala-install log --format=%H -S nameindex_download_retries -- "${TASKS#ala-install/}" | tail -1)
before="${added:+$added~1}"
if [ -z "$before" ] && ! git -C ala-install diff --quiet -- "${TASKS#ala-install/}"; then before=HEAD; fi
if [ -n "$before" ] && git -C ala-install show "$before:${TASKS#ala-install/}" > "$T/before.yml" 2>/dev/null; then
  download_task "$T/before.yml" "$T/task.yml"
  if ! run 1; then ok "without the retry, one corrupt download fails the host (as in #505)"
  else bad "the task without the retry passed one corrupt answer: the test does not see the retry"; fi
else
  echo "[INFO] no pre-retry version of the task here (shallow clone?): no before/after comparison"
fi

exit $fail

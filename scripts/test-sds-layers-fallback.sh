#!/usr/bin/env bash
# ala-install sensitive-data-service/tasks/docker-tasks.yml: the SDS XML configs (from
# sds_url) and the layers archive (from sds_layers_url) must fall back independently.
# They used to share one block/rescue, so a 500 on sensitive-species-data.xml (the CI
# stack's own SDS, which has no sensitive-species.xml) also swapped the layers for ALA's
# archive: a different file and ~30 min from archives.ala.org.au (#427 redeploy) instead
# of seconds from datos.gbif.es. The two blocks run here against a local HTTP server that
# stands in for sds_url, the mirror and ALA (the ALA URLs are rewritten to it), so the
# test is offline. ~15s, no Docker, no root.
#
# Usage: bash scripts/test-sds-layers-fallback.sh [path/to/docker-tasks.yml]
set -eu
cd "$(dirname "$0")/.."
SRC="${1:-$PWD/ala-install/ansible/roles/sensitive-data-service/tasks/docker-tasks.yml}"
ANSIBLE_PLAYBOOK="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}ansible-playbook"
command -v "$ANSIBLE_PLAYBOOK" >/dev/null || ANSIBLE_PLAYBOOK=ansible-playbook
# Modules run under the python that runs ansible-playbook (the venv's), not the target's
# /usr/bin/python3: on the Jenkins agent that one dies importing an unreadable root-owned
# _cffi_backend .so from /usr/local (#429).
PYARG='ansible_python_interpreter={{ ansible_playbook_python }}'
PY="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}python3"  # needs PyYAML
command -v "$PY" >/dev/null || PY=python3

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
server_pid=""
cleanup() { [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT

# /bad/* answers 500 (the CI SDS), /mirror/* and /ala/* serve files naming their origin.
mkdir -p "$tmp/www/mirror" "$tmp/www/ala/ws" "$tmp/www/good/ws"
for d in ala good; do
  for f in sensitive-species-data.xml sensitivity-zones.xml sensitivity-categories.xml; do
    echo "<?xml version=\"1.0\"?><from>$d</from>" >"$tmp/www/$d/$f"
  done
  echo '["cl1"]' >"$tmp/www/$d/ws/layers"
done
make_tgz() { mkdir -p "$tmp/src-$1" && echo "$1" >"$tmp/src-$1/origin.txt" && tar -czf "$2" -C "$tmp/src-$1" origin.txt; }
make_tgz mirror "$tmp/www/mirror/sds-layers.tgz"
make_tgz ala "$tmp/www/ala/sds-layers.tgz"

port_file="$tmp/port"
python3 - "$tmp/www" "$port_file" <<'EOF' &
import http.server, os, sys, functools
root, port_file = sys.argv[1], sys.argv[2]
class H(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/bad/"):
            self.send_error(500, "no sensitive-species.xml")
            return
        super().do_GET()
    def log_message(self, *a): pass
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(H, directory=root))
open(port_file, "w").write(str(srv.server_address[1]))
srv.serve_forever()
EOF
server_pid=$!
for _ in $(seq 50); do [ -s "$port_file" ] && break; sleep 0.1; done
[ -s "$port_file" ] || fail "local HTTP server did not start"
base="http://127.0.0.1:$(cat "$port_file")"

# Only the download blocks: the rest of the file needs Docker and the nameindex.
"$PY" - "$SRC" "$tmp/tasks.yml" "$base" <<'EOF'
import sys, yaml
src, out, base = sys.argv[1:4]
tasks = yaml.safe_load(open(src))
def names(t):
    return [x.get("name", "") for k in ("block", "rescue") for x in t.get(k, [])]
keep = [t for t in tasks if "block" in t and any(n.startswith("Downloading SDS") for n in names(t))]
if not keep:
    sys.exit("no SDS download blocks found in " + src)
text = yaml.safe_dump(keep, sort_keys=False)
text = text.replace("https://sds.ala.org.au", base + "/ala")
text = text.replace("https://archives.ala.org.au/archives/layers", base + "/ala")
open(out, "w").write(text)
EOF

cat >"$tmp/play.yml" <<EOF
- hosts: localhost
  gather_facts: false
  tasks:
    - ansible.builtin.file: {path: "{{ data_dir }}/sds", state: directory}
    - ansible.builtin.file: {path: "{{ data_dir }}/biocache/layers", state: directory}
    - ansible.builtin.include_tasks: $tmp/tasks.yml
EOF

run() { # $1 case name, $2 sds_url, $3 sds_layers_url
  rm -rf "$tmp/data-$1"
  ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_INVENTORY_UNPARSED_WARNING=false \
    "$ANSIBLE_PLAYBOOK" -i localhost, -e "$PYARG" -c local "$tmp/play.yml" \
    -e "data_dir=$tmp/data-$1" -e "sds_url=$2" -e "sds_layers_url=$3" >"$tmp/$1.log" 2>&1 ||
    { cat "$tmp/$1.log" >&2; fail "$1: playbook failed"; }
}
layers_origin() { tar -xzOf "$tmp/data-$1/biocache/layers/sds-layers.tgz" origin.txt; }
xml_origin() { sed -n 's/.*<from>\(.*\)<\/from>.*/\1/p' "$tmp/data-$1/sds/sensitive-species-data.xml"; }

# 1. The CI redeploy: sds_url answers 500, the layers mirror is fine.
run xml-500 "$base/bad" "$base/mirror/sds-layers.tgz"
[ "$(xml_origin xml-500)" = ala ] || fail "xml-500: XML configs did not fall back to ALA"
[ "$(layers_origin xml-500)" = mirror ] ||
  fail "xml-500: a failing sds_url swapped the layers for ALA's archive (got '$(layers_origin xml-500)')"
grep -q "WARNING: could not download the SDS configs" "$tmp/xml-500.log" ||
  fail "xml-500: the XML fallback printed no WARNING"
pass "a 500 on the SDS XML configs falls back for the XMLs only; layers still come from sds_layers_url"

# 2. The layers mirror fails: the layers alone fall back to ALA.
run layers-404 "$base/good" "$base/mirror/missing.tgz"
[ "$(xml_origin layers-404)" = good ] || fail "layers-404: XML configs did not come from sds_url"
[ "$(layers_origin layers-404)" = ala ] || fail "layers-404: layers did not fall back to ALA's archive"
pass "a failing sds_layers_url falls back to ALA's archive for the layers only"

# 3. Both fine: nothing comes from ALA.
run all-ok "$base/good" "$base/mirror/sds-layers.tgz"
[ "$(xml_origin all-ok)" = good ] && [ "$(layers_origin all-ok)" = mirror ] ||
  fail "all-ok: something came from the fallback"
pass "with both URLs answering, nothing comes from ALA"
echo "All checks passed."

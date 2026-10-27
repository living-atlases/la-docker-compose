#!/usr/bin/env bash
# The legacy sds (sds-webapp2) and its name index (TASK-95). Without one it served / and
# answered every /ws/<name> with 200 and "The SDS finder has not been initialised", and its
# healthcheck (/) stayed green.
#   1. services/sds.yml.j2 mounts sds_webapp_nameindex_dir read-only at /data/lucene/namematching,
#      the path its sds-config.properties reads;
#   2. its healthcheck, executed against a fake curl, is unhealthy on the "not been initialised"
#      status and on no answer, healthy on a lookup and on a 500 (no SDS list: data, not this);
#   3. tasks/sds-webapp-nameindex.yml, run by Ansible with the role defaults: by default it takes
#      the nextgen SDS's tarball (ala_sensitive_data_service_namematching_source), unpacks it
#      with its top directory stripped into lucene/sds-webapp-<tarball name>, does nothing the
#      second time, and fails clearly on a tarball that is not a name index.
# ~15s, no Docker, no root.
set -u
cd "$(dirname "$0")/.."
ROLES="$PWD/roles"
ANSIBLE_PLAYBOOK="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}ansible-playbook"
command -v "$ANSIBLE_PLAYBOOK" >/dev/null || ANSIBLE_PLAYBOOK=ansible-playbook
PY="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}python3"
command -v "$PY" >/dev/null || PY=python3
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "[PASS] $1"; }
bad() { echo "[FAIL] $1" >&2; fail=1; }

# --- 1 + 2: the compose fragment -------------------------------------------------------
mkdir -p "$T/bin"
# Fake curl: writes $FAKE_BODY to the -o file with HTTP $FAKE_CODE (--fail/-f honoured), or
# fails like curl with no connection.
cat >"$T/bin/curl" <<'EOF'
#!/bin/sh
echo "$*" >>"$FAKE_CALLS"
out=/dev/stdout; fail=0
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift ;; --fail|-f*) fail=1 ;; esac; shift; done
[ "$FAKE_BODY" = "<none>" ] && exit 7
printf '%s' "$FAKE_BODY" >"$out"
[ "$fail" = 1 ] && [ "$FAKE_CODE" -ge 400 ] && exit 22
exit 0
EOF
chmod +x "$T/bin/curl"

"$PY" - "$T" <<'PY' && ok "the index is mounted read-only at /data/lucene/namematching; the healthcheck sees the finder" || bad "compose fragment"
import re, subprocess, sys, urllib.parse, jinja2, yaml
tmp = sys.argv[1]
env = jinja2.Environment(loader=jinja2.FileSystemLoader("roles/la-compose/templates/docker-compose/services"),
                         undefined=jinja2.ChainableUndefined, trim_blocks=True)
env.filters["to_json"] = env.filters["tojson"]
env.filters["urlencode"] = lambda s: urllib.parse.quote(str(s))
doc = yaml.safe_load(env.get_template("sds.yml.j2").render(
    data_dir="/data", sds_webapp_nameindex_dir="/data/lucene/sds-webapp-nameindex-x-lucene-8",
    sds_webapp_probe_name="Acacia dealbata"))
svc = doc["services"]["sds"]
want = "/data/lucene/sds-webapp-nameindex-x-lucene-8:/data/lucene/namematching:ro"
assert want in svc["volumes"], svc["volumes"]
test = svc["healthcheck"]["test"]
assert test[0] == "CMD-SHELL", test
not_init = ('{"acceptedName":null,"instances":[],"scientificName":null,"status":"The SDS finder has '
            'not been initialised, please try again in 5 minutes."}')
found = '{"acceptedName":"Acacia dealbata","instances":[],"scientificName":"Acacia dealbata"}'
no_lists = "<!DOCTYPE html><html><head><title>Error</title></head><body>An error has occurred</body></html>"
calls = tmp + "/calls"
for body, code, healthy in ((not_init, "200", False), ("<none>", "000", False), (found, "200", True), (no_lists, "500", True)):
    open(calls, "w").close()
    rc = subprocess.run(["sh", "-c", test[1]], env={"PATH": tmp + "/bin:/usr/bin:/bin", "FAKE_BODY": body,
                        "FAKE_CODE": code, "FAKE_CALLS": calls}, capture_output=True, timeout=10).returncode
    assert "/ws/Acacia%20dealbata" in open(calls).read(), open(calls).read()
    assert (rc == 0) == healthy, (body[:40], rc)
PY

# --- 3: the index task under Ansible -----------------------------------------------------
b=nameindex-gbif-backbone-lucene-8-2026-07-23
mkdir -p "$T/src/namematching-gbif-backbone-lucene-8-2026-07-23/cb" "$T/other/whatever/notanindex" "$T/data"
echo segments > "$T/src/namematching-gbif-backbone-lucene-8-2026-07-23/cb/segments_1"
tar czf "$T/$b.tgz" -C "$T/src" namematching-gbif-backbone-lucene-8-2026-07-23
tar czf "$T/wrong.tgz" -C "$T/other" whatever

cat > "$T/play.yml" <<YML
- hosts: localhost
  gather_facts: false
  tasks:
    - ansible.builtin.include_role:
        name: la-compose
        tasks_from: sds-webapp-nameindex.yml
      vars:
        sds_webapp_nameindex_phase: start
    - ansible.builtin.include_role:
        name: la-compose
        tasks_from: sds-webapp-nameindex.yml
        public: true
      vars:
        sds_webapp_nameindex_phase: finish
YML

run() { ANSIBLE_ROLES_PATH="$ROLES" ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_NOCOLOR=1 \
  "$ANSIBLE_PLAYBOOK" -i localhost, -c local -e ansible_become=false \
  -e 'ansible_python_interpreter={{ ansible_playbook_python }}' \
  -e "data_dir=$T/data la_artifact_cache_dir=$T/cache docker_container_uid=$(id -u) docker_container_gid=$(id -g)" \
  "$@" "$T/play.yml"; }

# The inventory of a portal with the nextgen SDS's index, as gbif.es and the CI have it.
nextgen=(-e "ala_sensitive_data_service_namematching_source=file://$T/$b.tgz")
dir="$T/data/lucene/sds-webapp-$b"

run "${nextgen[@]}" >"$T/run1.log" 2>&1 || { cat "$T/run1.log" >&2; bad "first run failed"; }
[ -f "$dir/cb/segments_1" ] && [ "$(stat -c %u "$dir/cb")" = "$(id -u)" ] &&
  ok "by default it unpacks the nextgen SDS's index, top directory stripped, into lucene/sds-webapp-<tarball>" ||
  bad "not unpacked: $(find "$T/data" -maxdepth 4 | head)"

run "${nextgen[@]}" >"$T/run2.log" 2>&1
grep -Eq '^localhost .*changed=0 ' "$T/run2.log" && ok "a second run changes nothing" || bad "second run: $(grep -E '^localhost' "$T/run2.log")"

if run -e "sds_webapp_nameindex_url=file://$T/wrong.tgz" >"$T/run3.log" 2>&1; then
  bad "a tarball that is not a name index was accepted"
else
  grep -q "with no cb/ inside" "$T/run3.log" && ok "a tarball that is not a name index fails clearly" ||
    bad "wrong tarball: $(grep -E 'fatal|msg' "$T/run3.log" | head -3)"
fi

if run -e "sds_webapp_nameindex_url=" >"$T/run4.log" 2>&1; then bad "no index configured was accepted"; else
  grep -q "needs a Lucene 8 name index" "$T/run4.log" && ok "no index configured fails clearly" ||
    bad "no index: $(grep -E 'fatal|msg' "$T/run4.log" | head -3)"
fi

exit $fail

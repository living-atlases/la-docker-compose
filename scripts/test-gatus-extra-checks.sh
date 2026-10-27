#!/usr/bin/env bash
# roles/la-compose/templates/docker-compose/gatus/extra-checks.yaml.j2 rendered by Ansible
# against a small inventory, as a deploy renders it:
#   1. every `html: true` check sends Accept-Language, as a browser does (TASK-94: collectory
#      answered 500 to every browser and 200 to a request without the header, so gatus stayed
#      green for over an hour in build #495);
#   2. default_locale sets that header, and an endpoint's `headers` add to or override it;
#   3. checks that are not pages send no header;
#   4. with GATUS_VALIDATE=1 and Docker, the gatus image the role pins loads the result.
# ~5s (+~5s with GATUS_VALIDATE=1).
set -u
cd "$(dirname "$0")/.."
ANSIBLE_PLAYBOOK="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}ansible-playbook"
command -v "$ANSIBLE_PLAYBOOK" >/dev/null || ANSIBLE_PLAYBOOK=ansible-playbook
PY="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}python3"
command -v "$PY" >/dev/null || PY=python3
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "[PASS] $1"; }
bad() { echo "[FAIL] $1" >&2; fail=1; }

cat > "$T/hosts.ini" <<'INI'
[portal]
portal ansible_connection=local collectory_hostname=collections.example.org biocache_hub_hostname=records.example.org biocache_service_hostname=records-ws.example.org

[collectory]
portal
[biocache-hub]
portal
[biocache-service-clusterdb]
portal
[docker_compose]
INI

cat > "$T/play.yml" <<YML
- hosts: portal
  gather_facts: false
  vars_files:
    - $PWD/roles/la-compose/vars/gatus-extra-endpoints.yml
  tasks:
    - ansible.builtin.template:
        src: $PWD/roles/la-compose/templates/docker-compose/gatus/extra-checks.yaml.j2
        dest: "{{ out }}"
        mode: "0644"
YML

render() { # <out> [extra -e]
  local out=$1; shift
  ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_NOCOLOR=1 "$ANSIBLE_PLAYBOOK" -i "$T/hosts.ini" \
    -e 'ansible_python_interpreter={{ ansible_playbook_python }}' -e "out=$out" "$@" "$T/play.yml" >"$out.log" 2>&1 ||
    { cat "$out.log" >&2; bad "render failed ($*)"; return 1; }
}

# name -> headers, for the checks this inventory resolves
headers() { "$PY" -c '
import sys, json, yaml
eps = yaml.safe_load(open(sys.argv[1]))["endpoints"]
print(json.dumps({e["name"]: e.get("headers") for e in eps}))' "$1"; }

render "$T/default.yaml" || exit 1
d=$(headers "$T/default.yaml")
"$PY" - "$d" "$PWD/roles/la-compose/vars/gatus-extra-endpoints.yml" <<'PY' && ok "every page check sends Accept-Language: en, the others send no header" || bad "default headers: $d"
import sys, json, yaml
got = json.loads(sys.argv[1])
spec = {e["name"]: e for e in yaml.safe_load(open(sys.argv[2]))["gatus_extra_endpoints"]}
pages = [n for n in got if spec.get(n, {}).get("html")]
assert "collections ws" in pages, pages
for n, h in got.items():
    if n in pages:
        assert h == {"Accept-Language": "en"}, (n, h)
    elif n in spec:
        assert h is None, (n, h)
PY

render "$T/es.yaml" -e default_locale=es || exit 1
[ "$(headers "$T/es.yaml" | "$PY" -c 'import sys, json; print(json.load(sys.stdin)["collections ws"])')" = "{'Accept-Language': 'es'}" ] &&
  ok "default_locale=es sets the header" || bad "default_locale=es: $(headers "$T/es.yaml")"

# An endpoint's own headers add to and override the default.
"$PY" - "$PWD/roles/la-compose/vars/gatus-extra-endpoints.yml" "$T/override.yml" <<'PY'
import sys, yaml
v = yaml.safe_load(open(sys.argv[1]))
for e in v["gatus_extra_endpoints"]:
    if e["name"] == "collections ws":
        e["headers"] = {"Accept-Language": "fr", "X-Probe": "gatus"}
yaml.safe_dump({"gatus_extra_endpoints": v["gatus_extra_endpoints"]}, open(sys.argv[2], "w"))
PY
render "$T/override.yaml" -e "@$T/override.yml" || exit 1
[ "$(headers "$T/override.yaml" | "$PY" -c 'import sys, json; print(json.load(sys.stdin)["collections ws"])')" = "{'Accept-Language': 'fr', 'X-Probe': 'gatus'}" ] &&
  ok "an endpoint's headers add to and override the default" || bad "override: $(headers "$T/override.yaml")"

if [ "${GATUS_VALIDATE:-0}" = 1 ] && command -v docker >/dev/null; then
  img="twinproduction/gatus:$(sed -n "s/.*gatus_version | default('\([^']*\)').*/\1/p" roles/la-compose/templates/docker-compose/infrastructure/gatus.yml.j2)"
  mkdir -p "$T/cfg"; cp "$T/default.yaml" "$T/cfg/config.yaml"
  # gatus exits on an invalid config; a valid one keeps serving until the timeout stops it.
  # It ignores unknown keys, so this proves the YAML loads, not that `headers` is spelled right.
  timeout 8 docker run --rm --name "gatus-extra-checks-test-$$" -v "$T/cfg:/config:ro" "$img" >"$T/gatus.log" 2>&1; rc=$?
  docker rm -f "gatus-extra-checks-test-$$" >/dev/null 2>&1
  [ "$rc" = 124 ] && grep -qE "Validated [1-9][0-9]* endpoints" "$T/gatus.log" && ok "$img loads the rendered config" ||
    bad "$img rejected the config (rc=$rc): $(tail -5 "$T/gatus.log")"
fi

exit $fail

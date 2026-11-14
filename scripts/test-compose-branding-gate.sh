#!/usr/bin/env bash
# The branding readiness gate must be included wherever a service depends on it.
#
# `wait-for-branding` is defined by a fragment that base.yml.j2 includes only for certain
# services. A service template that emits `depends_on: wait-for-branding` on a host where
# that guard is false produces a project referencing a service nobody defines, and docker
# compose refuses it at PARSE time: not one broken container, every compose command on the
# host, the #284/#285 failure class.
#
# gbif.es hit it moving auth to a node that carried only alerts and doi. cas.yml.j2 emits
# the dependency unconditionally, the guard named collectory and ala_bie but not cas, and
# the deploy died at:
#
#     TASK [la-compose : List the services whose image tag is mutable]
#     service "cas" depends on undefined service "wait-for-branding": invalid compose project
#
# 568 ok, 1 failed, and the host's project left unusable. The CI never saw it because its
# topologies always put cas on a host that also runs collectory or bie-hub.
#
# Two things are asserted:
#   - base.yml.j2, RENDERED, includes the gate for a cas-only host and leaves it out for a
#     host with neither cas nor a commonui hub (or the fix would be "include it always",
#     which makes every branding-less deploy pay the poll timeout);
#   - every template that emits the dependency WITHOUT a Jinja guard has its service key
#     named in base.yml.j2's guard. That is the invariant the failure broke, and it also
#     reports a latent case instead of hiding it.
#
# Runs ansible-playbook twice, no Docker, ~10s.
set -u
cd "$(dirname "$0")/.."
ANSIBLE="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}ansible-playbook"
command -v "$ANSIBLE" >/dev/null || ANSIBLE=ansible-playbook
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
pass() { printf '[PASS] %s\n' "$*"; }
bad()  { printf '[FAIL] %s\n' "$*" >&2; fail=1; }

BASE=roles/la-compose/templates/docker-compose/base.yml.j2
SERVICES_DIR=roles/la-compose/templates/docker-compose/services
GATE=wait-for-branding

[ -f "$BASE" ] || { bad "not found: $BASE"; exit 1; }

# ---------------------------------------------------------------- rendered behaviour
cat > "$T/render.yml" <<'EOF'
- hosts: localhost
  gather_facts: false
  connection: local
  vars:
    i18n: {enabled: false, strategy: none, volume: {source: none}}
    # base.yml.j2 reads these without a default; the gate's guard does not depend on them.
    deployment_type: docker
    hub_instances: []
    physical_server_groups: "{{ pgroups }}"
    services_enabled: "{{ senabled }}"
    spatial_skin_active: false
    docker_mail_development_mode: false
    enable_mysql: false
    enable_postgres: false
    enable_mongo: false
  tasks:
    - ansible.builtin.template:
        src: "{{ tpl }}"
        dest: "{{ out }}"
        mode: "0644"
EOF

render() {  # label, services_enabled (json), physical groups (json), expected (yes|no)
  local label="$1" senabled="$2" pgroups="$3" want="$4" out="$T/base.yml"
  rm -f "$out"
  if ! "$ANSIBLE" -i localhost, "$T/render.yml" \
       -e "tpl=$PWD/$BASE" -e "out=$out" \
       -e "senabled=$senabled" -e "pgroups=$pgroups" >"$T/log" 2>&1; then
    bad "$label: the render failed: $(tail -3 "$T/log")"
    return
  fi
  local got=no
  grep -qE "^[[:space:]]+- \./infrastructure/$GATE\.yml[[:space:]]*$" "$out" && got=yes
  # A render that produced nothing at all would also show "no gate", so check the file
  # is a real project file either way.
  if ! grep -q '^include:' "$out"; then
    bad "$label: the rendered file has no include block, so this proves nothing"
    return
  fi
  if [ "$got" = "$want" ]; then
    pass "$label -> gate included: $got"
  else
    bad "$label: gate included $got, expected $want"
  fi
}

render "a host with cas only (auth + alerts + doi)" \
       '["cas","alerts","doi"]' '["cas-servers","alerts-service","doi-service"]' yes
render "a host with neither cas nor a commonui hub" \
       '["alerts","doi"]' '["alerts-service","doi-service"]' no
render "a host with collectory (the pre-existing case)" \
       '["collectory"]' '["collectory"]' yes

# ------------------------------------------------------------- static invariant
# The guard line of the gate's include, and the service keys it names.
guard=$(grep -B1 -E "^[[:space:]]+- \./infrastructure/$GATE\.yml" "$BASE" | grep -o "{%-\? if .*" | head -1)
if [ -z "$guard" ]; then
  # The include may sit several comment lines below its {% if %}: take the last {% if %}
  # before it instead.
  n=$(grep -nE "^[[:space:]]+- \./infrastructure/$GATE\.yml" "$BASE" | head -1 | cut -d: -f1)
  guard=$(head -n "$n" "$BASE" | grep -E '^\{%-? if ' | tail -1)
fi
if [ -z "$guard" ]; then
  bad "cannot find the Jinja guard of the $GATE include in $BASE: the test is broken"
else
  pass "guard found: $(printf '%s' "$guard" | cut -c1-60)..."
fi

# Which templates emit the dependency with nothing switching it off? "Unguarded" means the
# line sits at Jinja block depth 0: no enclosing {% if %}. A template that wraps it (alerts,
# regions) keeps its own condition in step with base's by hand and has its own test; one that
# does not will always emit the dependency, so base's guard has to name its service.
python3 - "$BASE" "$SERVICES_DIR" "$GATE" <<'PY' || fail=1
import re, sys, pathlib
base, services_dir, gate = sys.argv[1], pathlib.Path(sys.argv[2]), sys.argv[3]
guard = ""
lines = pathlib.Path(base).read_text().splitlines()
for i, ln in enumerate(lines):
    if re.match(r"^\s+- \./infrastructure/%s\.yml\s*$" % re.escape(gate), ln):
        for prev in reversed(lines[:i]):
            if prev.lstrip().startswith("{%") and " if " in prev:
                guard = prev
                break
        break
# collectory.yml.j2 -> collectory, biocache-hub.yml.j2 -> ala_hub: the include guard speaks
# the catalog's keys, the file names do not.
KEY = {"cas": "cas", "collectory": "collectory", "biocache-hub": "ala_hub",
       "bie-hub": "ala_bie", "spatial-hub": "spatial", "alerts": "alerts"}
rc = 0
checked = 0
for f in sorted(services_dir.glob("*.j2")):
    depth, hit = 0, None
    for ln in f.read_text().splitlines():
        s = ln.lstrip()
        if re.match(r"^\{%-?\s*(if|for)\b", s):
            depth += 1
        elif re.match(r"^\{%-?\s*(endif|endfor)\b", s):
            depth -= 1
        elif re.match(r"^\s+%s:\s*$" % re.escape(gate), ln) and depth == 0:
            hit = ln
            break
    if hit is None:
        continue
    checked += 1
    stem = f.name[:-len(".yml.j2")]
    key = KEY.get(stem, stem.replace("-", "_"))
    if "'%s' in services_enabled" % key in guard:
        print("[PASS] %s depends on %s unguarded, and the guard names '%s'" % (f.name, gate, key))
    else:
        print("[FAIL] %s emits 'depends_on: %s' at Jinja depth 0, but base.yml.j2's guard does"
              " not name '%s': a host running only that service gets 'depends on undefined"
              " service \"%s\"' and every compose command there fails at parse time"
              % (f.name, gate, key, gate), file=sys.stderr)
        rc = 1
if checked == 0:
    print("[FAIL] no template emits an unguarded '%s' dependency: the check is broken,"
          " not the templates" % gate, file=sys.stderr)
    rc = 1
sys.exit(rc)
PY

exit "$fail"

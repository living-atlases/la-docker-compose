#!/usr/bin/env bash
# roles/la-compose/tasks/branding-bs5-url.yml: an ala-bootstrap5 app gets the Bootstrap 5
# branding, and nothing else does.
#
# A Bootstrap 5 app pointed at a Bootstrap 3 branding renders with no CSS and logs
# "$ is not defined": the {assets,banner,footer}.mustache it asks for answer 404. Nothing
# fails, gatus stays green and the build passes, which is exactly how alerts 5.3.1 and
# logger 4.7.0 ran unstyled on the CI portal without anyone noticing. So the decision gets
# a test of its own rather than relying on a deploy to show it:
#   - which services switch, and when, comes from docker-services-desc's bootstrap5_from,
#     and those thresholds are compared here with the toolkit's nextgen-compat.yaml, which
#     is where that fact is maintained;
#   - the comparison is strictly greater, like nextgen-compat's `from: '> X'`, so the last
#     Bootstrap 3 release stays on Bootstrap 3;
#   - a service with no threshold, and a non-numeric pin, keep the inventory value;
#   - header_and_footer_baseurl_bs5 (one variable for the whole portal) wins over the
#     derived URL. There is no per-service variable to test, because there is none;
#   - a URL already ending in /bs5 does not grow a second one, which is what keeps a
#     portal that set the Bootstrap 5 build host-wide working;
#   - the branding image actually builds what the URL points at.
# Runs the real task file, no Docker, ~15s.
set -u
cd "$(dirname "$0")/.."
ANSIBLE="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}ansible-playbook"
command -v "$ANSIBLE" >/dev/null || ANSIBLE=ansible-playbook
PY="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}python3"
command -v "$PY" >/dev/null || PY=python3
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
pass() { printf '[PASS] %s\n' "$*"; }
bad()  { printf '[FAIL] %s\n' "$*" >&2; fail=1; }

# One ansible-playbook run per case: the task file set_facts, and facts do not survive
# between runs, so each case starts from a clean scope instead of the previous answer.
# The playbook lives in a temp dir, so the include and the vars file need absolute paths:
# relative ones would resolve against the temp dir and find nothing.
cat > "$T/play.yml" <<EOF
- hosts: localhost
  gather_facts: false
  connection: local
  vars_files:
    - $PWD/roles/la-compose/vars/docker-services-desc.yaml
  tasks:
    - ansible.builtin.include_tasks: $PWD/roles/la-compose/tasks/branding-bs5-url.yml
      vars:
        bs5_service: "{{ case_service }}"
    - ansible.builtin.debug:
        msg: "RESULT[{{ la_service_branding_baseurl }}]"
EOF

run_case() {  # label, service, version_var=value, bs3 url, portal bs5 url, want
  local label="$1" svc="$2" ver="$3" base="$4" bs5var="$5" want="$6" out got
  out=$("$ANSIBLE" -i localhost, "$T/play.yml" \
        -e "case_service=$svc" -e "$ver" \
        -e "header_and_footer_baseurl=$base" \
        -e "header_and_footer_baseurl_bs5=$bs5var" 2>&1)
  got=$(printf '%s\n' "$out" | grep -o 'RESULT\[[^]]*\]' | head -1 | sed 's/^RESULT\[//; s/\]$//')
  if [ -z "$got" ]; then
    bad "$label: the play did not answer: $(printf '%s\n' "$out" | tail -3)"
  elif [ "$got" = "$want" ]; then
    pass "$label -> $got"
  else
    bad "$label: got '$got', expected '$want'"
  fi
}

B3=https://branding.l-a.site/brand-2023
B5=$B3/bs5
GBIF5=https://datos.gbif.es/brand-2025-vite-bs5/bs5
ALA3=https://www.ala.org.au/commonui-bs3-2019
ALA5=https://www.ala.org.au/commonui-bs5-2019

run_case "alerts 5.3.1 is bootstrap5"             alerts     alerts_version=5.3.1      "$B3"    ""       "$B5"
run_case "alerts 5.2.4 is the last bootstrap3"    alerts     alerts_version=5.2.4      "$B3"    ""       "$B3"
run_case "logger 4.5.0 is the last bootstrap3"    logger     logger_version=4.5.0      "$B3"    ""       "$B3"
run_case "logger 4.5.1 is already bootstrap5"     logger     logger_version=4.5.1      "$B3"    ""       "$B5"
run_case "logger 4.7.0 is bootstrap5"             logger     logger_version=4.7.0      "$B3"    ""       "$B5"
run_case "collectory 6.0.0 is bootstrap3"         collectory collectory_version=6.0.0  "$B3"    ""       "$B3"
run_case "collectory 6.3.0 is bootstrap5"         collectory collectory_version=6.3.0  "$B3"    ""       "$B5"
run_case "doi has no threshold, so bootstrap3"    doi        doi_service_version=4.1.0 "$B3"    ""       "$B3"
run_case "a non-numeric pin stays on bootstrap3"  alerts     alerts_version=latest     "$B3"    ""       "$B3"
run_case "the portal bootstrap5 URL wins"         alerts     alerts_version=5.3.1      "$B3"    "$GBIF5" "$GBIF5"
run_case "and does not win for a bootstrap3 one"  alerts     alerts_version=5.2.4      "$B3"    "$GBIF5" "$B3"
run_case "a URL already on /bs5 is not doubled"   alerts     alerts_version=5.3.1      "$GBIF5" ""       "$GBIF5"
run_case "a trailing slash does not give //bs5"   alerts     alerts_version=5.3.1      "$B3/"   ""       "$B5"
run_case "the ALA bs3 default maps to bs5-2019"   alerts     alerts_version=5.3.1      "$ALA3"  ""       "$ALA5"
run_case "no branding URL gives no bare /bs5"     alerts     alerts_version=5.3.1      ""       ""       "$ALA5"

# The thresholds are a copy of the toolkit's, so they are compared with it rather than
# restated here. That checkout is a sibling of this repo; without it the comparison is
# skipped rather than failed, since the network is deliberately not a dependency.
NEXTGEN=../la_toolkit_backend/assets/nextgen-compat.yaml
if [ -f "$NEXTGEN" ]; then
  "$PY" - "$NEXTGEN" <<'PYEOF'
import sys, yaml
desc = yaml.safe_load(open("roles/la-compose/vars/docker-services-desc.yaml"))
desc = desc.get("docker_services_desc", desc)
up = yaml.safe_load(open(sys.argv[1]))["nextgen-compat"]
bad = 0
for svc, row in up.items():
    if row.get("reason") != "bootstrap5-branding":
        continue
    want = row["from"].replace(">", "").strip()
    got = (desc.get(svc) or {}).get("bootstrap5_from")
    if got is None:
        print("[FAIL] %s needs a Bootstrap 5 branding from %s and docker-services-desc "
              "has no bootstrap5_from for it" % (svc, row["from"]), file=sys.stderr)
        bad = 1
    elif str(got) != want:
        print("[FAIL] %s: docker-services-desc says %s, nextgen-compat says %s"
              % (svc, got, row["from"]), file=sys.stderr)
        bad = 1
    else:
        print("[PASS] %s bootstrap5_from %s matches nextgen-compat" % (svc, got))
sys.exit(bad)
PYEOF
  [ $? -eq 0 ] || fail=1
else
  echo "[SKIP] $NEXTGEN is not checked out: the thresholds were not compared with the toolkit's"
fi

# The branding image has to actually produce what the URL above points at.
d=roles/la-compose/files/docker/branding/Dockerfile
grep -q "npm run build:bs5" "$d" \
  && pass "the branding image builds the Bootstrap 5 assets" \
  || bad "$d no longer runs build:bs5: /bs5 would be a 404"

# ...and must not take the portal down when it cannot. build:bs5 needs a commonui-bs5-2019
# build that this image has no way to produce on its own, so it fails on sources that never
# had one. In #534 that was a hard error: the branding image did not build, and host 1 came
# up with nothing at all. An unstyled app is a bad day; a portal with no services is a worse
# one, so the step warns and carries on.
awk '/^RUN .*build:bs5/{f=1} f{print; if (!/\\$/) exit}' "$d" | grep -q "exit 1" \
  && bad "$d fails the image when build:bs5 does not produce dist/bs5 (see #534)" \
  || pass "a missing Bootstrap 5 build does not fail the branding image"

# ...and it has to be ABLE to build them. commonui-bs5-2019's gulpfile reads
# source/vendor/bootstrap/dist/js/bootstrap.bundle.js, and that vendor directory is
# Bootstrap's own repository, which does not commit dist/. Without the bundle the gulp
# build dies in 30 ms, build:bs5 dies with it and the image ships with no /bs5: that is
# builds 534 to 538 on the CI portal, green all the way. The step has to come BEFORE the
# build, since base-branding's `build` script already chains build:bs5 at the end.
if grep -q 'bootstrap.bundle.js' "$d"; then
  pass "the branding image vendors the bootstrap bundle commonui-bs5-2019 needs"
else
  bad "$d does not provide source/vendor/bootstrap/dist/js/bootstrap.bundle.js: the gulp build of commonui-bs5-2019 cannot run and /bs5 is never produced"
fi
if [ "$(grep -n 'bootstrap.bundle.js' "$d" | head -1 | cut -d: -f1)" -lt \
     "$(grep -n 'Building for production' "$d" | head -1 | cut -d: -f1)" ]; then
  pass "it is vendored before the production build, which is what runs build:bs5"
else
  bad "$d vendors the bootstrap bundle after the build: build:bs5 has already failed by then"
fi

# A failed build script must not be reported as a success. `npm run build && echo ok ||
# ls dist/` swallows it whenever an earlier step left dist/ behind, which is exactly how
# a build:bs5 that died went out as "Build completed".
if awk '/Building for production/{f=1} f && /No build output found/{print; exit}' "$d" | grep -q '||'; then
  if grep -q 'the build script exited' "$d"; then
    pass "a failing build script is reported instead of being masked by the output listing"
  else
    bad "$d chains the build to the output listing with ||: a failing build script is reported as success"
  fi
fi

exit "$fail"

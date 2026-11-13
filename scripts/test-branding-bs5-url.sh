#!/usr/bin/env bash
# roles/la-compose/tasks/branding-bs5-url.yml: an ala-bootstrap5 app gets the Bootstrap 5
# branding, and nothing else does.
#
# A Bootstrap 5 app pointed at a Bootstrap 3 branding renders with no CSS and logs
# "$ is not defined": the {assets,banner,footer}.mustache it asks for answer 404. Nothing
# fails, gatus stays green and the build passes, which is exactly how alerts 5.3.1 and
# logger 4.7.0 ran unstyled on the CI portal without anyone noticing. So the derivation
# gets a test of its own rather than relying on a deploy to show it:
#   - a Bootstrap 5 version appends /bs5 to the portal's branding URL;
#   - a Bootstrap 3 version is left exactly as the inventory had it;
#   - a URL that already ends in /bs5 does not grow a second one (a portal that set the
#     Bootstrap 5 build host-wide would otherwise break on its next deploy);
#   - an explicit <service>_header_and_footer_baseurl wins over both;
#   - the ALA commonui defaults map to commonui-bs5-2019, which exists, instead of
#     growing a /bs5 path that does not;
#   - the result is one line, with no newline folded into it.
# Runs the real task file, no Docker, ~5s.
set -u
cd "$(dirname "$0")/.."
ANSIBLE="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}ansible-playbook"
command -v "$ANSIBLE" >/dev/null || ANSIBLE=ansible-playbook
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
pass() { printf '[PASS] %s\n' "$*"; }
bad()  { printf '[FAIL] %s\n' "$*" >&2; fail=1; }

# One ansible-playbook run per case: the task file set_facts, and facts do not survive
# between runs, so each case starts from a clean scope instead of the previous answer.
# The playbook lives in a temp dir, so the include needs the absolute path of the real
# task file: a relative one would resolve against the temp dir and include nothing.
cat > "$T/play.yml" <<EOF
- hosts: localhost
  gather_facts: false
  connection: local
  tasks:
    - ansible.builtin.include_tasks: $PWD/roles/la-compose/tasks/branding-bs5-url.yml
      vars:
        bs5_service: "{{ case_name }}"
        bs5_needed: "{{ case_needed }}"
        bs5_explicit: "{{ case_explicit }}"
        header_and_footer_baseurl: "{{ case_base }}"
    - ansible.builtin.debug:
        msg: "RESULT[{{ la_service_branding_baseurl }}]"
EOF

run_case() {  # name, base, needed, explicit, want
  local name="$1" base="$2" needed="$3" explicit="$4" want="$5" out got
  out=$("$ANSIBLE" -i localhost, "$T/play.yml" \
        -e "case_name=probe" -e "case_base=$base" -e "case_needed=$needed" \
        -e "case_explicit=$explicit" 2>&1)
  got=$(printf '%s\n' "$out" | grep -o 'RESULT\[[^]]*\]' | head -1 | sed 's/^RESULT\[//; s/\]$//')
  if [ -z "$got" ]; then
    bad "$name: the play did not answer: $(printf '%s\n' "$out" | tail -3)"
  elif [ "$got" = "$want" ]; then
    pass "$name -> $got"
  else
    bad "$name: got '$got', expected '$want'"
  fi
}

run_case "a bootstrap5 version appends /bs5" \
  "https://branding.l-a.site/brand-2023" true "" "https://branding.l-a.site/brand-2023/bs5"
run_case "a bootstrap3 version keeps the inventory value" \
  "https://branding.l-a.site/brand-2023" false "" "https://branding.l-a.site/brand-2023"
run_case "a URL already on /bs5 is not doubled" \
  "https://datos.gbif.es/brand-2025-vite-bs5/bs5" true "" "https://datos.gbif.es/brand-2025-vite-bs5/bs5"
run_case "a trailing slash does not become //bs5" \
  "https://branding.l-a.site/brand-2023/" true "" "https://branding.l-a.site/brand-2023/bs5"
run_case "an explicit per-service URL wins" \
  "https://branding.l-a.site/brand-2023" true "https://datos.gbif.es/brand-2025-vite-bs5/bs5" \
  "https://datos.gbif.es/brand-2025-vite-bs5/bs5"
run_case "an explicit URL wins for a bootstrap3 version too" \
  "https://branding.l-a.site/brand-2023" false "https://elsewhere/bs5" "https://elsewhere/bs5"
run_case "the ALA bootstrap3 default maps to commonui-bs5-2019" \
  "https://www.ala.org.au/commonui-bs3-2019" true "" "https://www.ala.org.au/commonui-bs5-2019"
run_case "the ALA bootstrap2 default maps to commonui-bs5-2019" \
  "https://www.ala.org.au/commonui-bs2" true "" "https://www.ala.org.au/commonui-bs5-2019"
run_case "no branding URL at all does not give a bare /bs5" \
  "" true "" "https://www.ala.org.au/commonui-bs5-2019"

# The thresholds the callers use, read from the file that uses them rather than repeated
# here: a change to either one has to be deliberate.
g=roles/la-compose/tasks/generate-compose.yml
grep -q "alerts_version | string) is version('5.2.5', '>=')" "$g" \
  && pass "alerts crosses to bootstrap5 at 5.2.5" \
  || bad "the alerts bootstrap5 threshold is no longer 5.2.5 in $g"
grep -q "logger_version | string) is version('4.6.0', '>=')" "$g" \
  && pass "logger crosses to bootstrap5 at 4.6.0" \
  || bad "the logger bootstrap5 threshold is no longer 4.6.0 in $g"

# The branding image has to actually produce what the URL above points at.
d=roles/la-compose/files/docker/branding/Dockerfile
grep -q "npm run build:bs5" "$d" \
  && pass "the branding image builds the Bootstrap 5 assets" \
  || bad "$d no longer runs build:bs5: /bs5 would be a 404"

exit "$fail"

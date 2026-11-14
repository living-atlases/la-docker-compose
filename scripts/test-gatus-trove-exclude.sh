#!/usr/bin/env bash
# The /trove gatus check only exists for a portal that configured Trove.
#
# species.l-a.site/trove is not served by this stack: it is an nginx rewrite to
# https://api.trove.nla.gov.au, the National Library of Australia's API, which only an ALA
# deployment uses. Without an api key the integration is dead, and the check then measures
# a third party: when that API stopped answering, the location hung for 25 s, gatus timed
# out and the total-green gate failed build 539 over a portal that was entirely healthy.
#
# Two things are asserted, and the second is the one that matters:
#   - both callers of the bie-hub role (the portal's and each data hub's) build their
#     nginx_paths_gatus_exclude with the condition, not a fixed list;
#   - the real template, ala-install's gatus/templates/http.j2, renders the endpoint only
#     when a key is set. That is the output the gate reads, so a grep of the task file
#     alone would prove nothing.
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

TPL=ala-install/ansible/roles/gatus/templates/http.j2
if [ ! -f "$TPL" ]; then
  echo "[SKIP] $TPL is not checked out: the ala-install submodule is not initialised"
  exit 0
fi

# The condition, lifted verbatim from the two callers. If a caller changes and this does
# not, the grep below stops matching it.
COND="if ((trove_api_key | default('') | string | trim) in ['', 'get-an-api-key'])"
for f in roles/la-compose/tasks/generate-compose.yml roles/la-compose/tasks/generate-hub-instance.yml; do
  if grep -qF "$COND" "$f"; then
    pass "$(basename "$f") excludes /trove only while Trove is unconfigured"
  else
    bad "$f does not condition the /trove exclusion on trove_api_key: an unconfigured portal gets a gatus check on api.trove.nla.gov.au"
  fi
done

# The template is rendered with the same nginx_paths the bie-hub role builds for the two
# paths that matter here, and with the exclusion computed exactly as the callers compute it.
cat > "$T/render.yml" <<'EOF'
- hosts: localhost
  gather_facts: false
  connection: local
  vars:
    ssl: true
    hostname: species.example.org
    bie_hub_context_path: ""
    nginx_paths:
      - path: "{{ bie_hub_context_path }}/search"
        is_proxy: true
      - path: "{{ bie_hub_context_path }}/trove"
        is_proxy: false
        is_proxy_rewrite: true
    nginx_paths_gatus_exclude: >-
      {{ [bie_hub_context_path ~ '/species', bie_hub_context_path ~ '/externalSite']
         + ([bie_hub_context_path ~ '/trove']
            if ((trove_api_key | default('') | string | trim) in ['', 'get-an-api-key'])
            else []) }}
  tasks:
    - ansible.builtin.template:
        src: "{{ tpl }}"
        dest: "{{ out }}"
        mode: "0644"
EOF

render() {  # label, -e trove_api_key=..., expected (yes|no)
  local label="$1" keyarg="$2" want="$3" out="$T/out.yaml"
  rm -f "$out"
  if ! "$ANSIBLE" -i localhost, "$T/render.yml" \
       -e "tpl=$PWD/$TPL" -e "out=$out" $keyarg >"$T/log" 2>&1; then
    bad "$label: the render failed: $(tail -3 "$T/log")"
    return
  fi
  if grep -q '/trove' "$out"; then got=yes; else got=no; fi
  # The rest of the vhost has to survive either way, or "no trove check" would also be
  # true of a template that rendered nothing at all.
  if ! grep -q '/search' "$out"; then
    bad "$label: the other endpoints are gone too, so this proves nothing"
    return
  fi
  if [ "$got" = "$want" ]; then
    pass "$label -> trove endpoint: $got"
  else
    bad "$label: trove endpoint $got, expected $want"
  fi
}

render "no key at all"                 ""                                  no
render "the generator's placeholder"   "-e trove_api_key=get-an-api-key"   no
render "an empty key"                  "-e trove_api_key="                 no
render "a configured key"              "-e trove_api_key=a-real-key"       yes

exit "$fail"

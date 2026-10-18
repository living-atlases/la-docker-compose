#!/usr/bin/env bash
# roles/docker-housekeeping/templates/trivy-scan.sh.j2: the weekly CVE scan reports privately
# and mails the admin once per change. Renders the real template and runs it with shimmed
# `docker` (ps / trivy run / curl-container run) and `curl` (KEV catalog download):
#   1. fresh deploy marker -> nothing runs; --force -> scans anyway;
#   2. counts: CRITICAL-with-fix and CISA KEV, after the id / package ignores;
#   3. first KEV -> exactly one mail; same findings again -> no mail;
#   4. a mail that cannot be sent is not recorded, so the next run sends it;
#   5. every scan failing -> status error, last good findings kept, exit 1, one mail;
#   6. no recipient -> no mail, a warning;
#   7. KEV catalog download failing -> the cached catalog is used;
#   8. scripts/trivy-ci-collect.sh (the Jenkins stage's host side) returns rc, log, report
#      and, when it mailed mailhog, the mailhog search -- and nothing else on stdout.
# ~10s, no Docker, no root, no network.
set -eu
cd "$(dirname "$0")/.."
ANSIBLE_PLAYBOOK="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}ansible-playbook"
command -v "$ANSIBLE_PLAYBOOK" >/dev/null || ANSIBLE_PLAYBOOK=ansible-playbook
PYARG='ansible_python_interpreter={{ ansible_playbook_python }}'
command -v jq >/dev/null || { echo "[SKIP] jq not installed"; exit 0; }

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
marker="$tmp/la-compose-deploy.marker"
cache="$tmp/cache"

render() { # $1 = output script, $2 = recipient, $3 = development mode (mail to mailhog)
  cat >"$tmp/play.yml" <<YML
- hosts: localhost
  connection: local
  gather_facts: false
  vars_files:
    - $PWD/roles/docker-housekeeping/defaults/main.yml
  tasks:
    - ansible.builtin.template:
        src: $PWD/roles/docker-housekeeping/templates/trivy-scan.sh.j2
        dest: $1
        mode: '0755'
YML
  ANSIBLE_LOCALHOST_WARNING=false "$ANSIBLE_PLAYBOOK" -i localhost, -e "$PYARG" "$tmp/play.yml" \
    -e "docker_housekeeping_deploy_marker=$marker" \
    -e "docker_housekeeping_trivy_cache_dir=$cache" \
    -e "docker_housekeeping_trivy_mail_to=$2" \
    -e "docker_housekeeping_trivy_mail_from=trivy@example.org" \
    -e "docker_mail_development_mode=${3:-false}" >"$tmp/render.log" 2>&1 ||
    { cat "$tmp/render.log" >&2; fail "template did not render"; }
}
render "$tmp/trivy-scan.sh" "admin@example.org"

# --- fixtures ---------------------------------------------------------------------------
mkdir -p "$tmp/bin" "$tmp/fx" "$tmp/mails"
printf 'geonetwork:3.4.4-postgres\nsolr:9.7.0\ngeonetwork:3.4.4-postgres\n' >"$tmp/ps-images"
cat >"$tmp/fx/kev.json" <<'JSON'
{"vulnerabilities":[{"cveID":"CVE-2021-44228"},{"cveID":"CVE-2021-45046"},{"cveID":"CVE-2026-31431"}]}
JSON
vuln() { printf '{"VulnerabilityID":"%s","PkgName":"%s","InstalledVersion":"1","FixedVersion":"2","Severity":"%s","Title":"t-%s"}' "$1" "$2" "$3" "$1"; }
cat >"$tmp/fx/geonetwork_3.4.4-postgres.json" <<JSON
{"ArtifactName":"geonetwork:3.4.4-postgres","Results":[{"Target":"x","Vulnerabilities":[
 $(vuln CVE-2021-44228 log4j-core CRITICAL),
 $(vuln CVE-2021-44228 log4j-core CRITICAL),
 $(vuln CVE-2025-24813 tomcat-embed-core CRITICAL),
 $(vuln CVE-2026-31431 linux-libc-dev HIGH),
 $(vuln CVE-2099-0001 libfoo CRITICAL),
 $(vuln CVE-2099-0002 libbar HIGH)]}]}
JSON
echo '{"ArtifactName":"solr:9.7.0","Results":[{"Target":"y"}]}' >"$tmp/fx/solr_9.7.0.json"

cat >"$tmp/bin/docker" <<EOF
#!/bin/bash
echo "\$*" >>"$tmp/docker-calls"
case "\$1" in
  ps) cat "$tmp/ps-images"; exit 0 ;;
esac
if [[ "\$*" == *aquasec/trivy* ]]; then
  [ -e "$tmp/trivy-fail" ] && exit 1
  img="\${@: -1}"
  cat "$tmp/fx/\$(printf '%s' "\$img" | tr -c 'A-Za-z0-9._-' '_').json"
  exit 0
fi
if [[ "\$*" == *curlimages/curl* ]]; then
  [[ "\$*" == *api/v2/search* ]] && { echo '{"total":1}'; exit 0; }
  [ -e "$tmp/mail-fail" ] && exit 7
  for a in "\$@"; do
    case "\$a" in *:/mail.txt:ro) cp "\${a%%:/mail.txt:ro}" "$tmp/mails/\$(ls "$tmp/mails" | wc -l).txt" ;; esac
  done
  exit 0
fi
exit 1
EOF
cat >"$tmp/bin/sudo" <<'EOF'
#!/bin/bash
exec "$@"
EOF
cat >"$tmp/bin/curl" <<EOF
#!/bin/bash
[ -e "$tmp/kev-fail" ] && exit 22
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && { cp "$tmp/fx/kev.json" "\$2"; exit 0; }; shift; done
exit 2
EOF
chmod +x "$tmp/bin/docker" "$tmp/bin/curl" "$tmp/bin/sudo"

# run <label> <expected exit> [script] [args...]
run() {
  local label="$1" want="$2" script="${3:-$tmp/trivy-scan.sh}" rc=0
  shift 3 2>/dev/null || shift $#
  : >"$tmp/docker-calls"
  PATH="$tmp/bin:$PATH" bash "$script" "$@" >"$tmp/out" 2>&1 || rc=$?
  [ "$rc" = "$want" ] || { cat "$tmp/out" >&2; fail "$label: exit $rc, expected $want"; }
}
mails() { ls "$tmp/mails" | wc -l; }
summary() { jq -r "$1" "$cache/summary.json"; }

# --- 1. deploy marker ------------------------------------------------------------------
touch "$marker"
run fresh 0
[ ! -s "$tmp/docker-calls" ] || fail "fresh marker: still ran docker: $(tr '\n' ';' <"$tmp/docker-calls")"
grep -q "deploy is in progress" "$tmp/out" || fail "fresh marker: no skip message"
pass "a deploy in progress (fresh marker) skips the scan"

run force 0 "$tmp/trivy-scan.sh" --force
grep -q "aquasec/trivy" "$tmp/docker-calls" || fail "--force: no scan"
[ "$(grep -c aquasec/trivy "$tmp/docker-calls")" = 2 ] || fail "--force: duplicate images not collapsed"
pass "--force scans despite the marker, each running image once"
rm -f "$marker"

# --- 2. counts --------------------------------------------------------------------------
[ "$(summary .status)" = ok ] || fail "status $(summary .status), expected ok"
[ "$(summary .critical_fixable)" = 2 ] || fail "critical_fixable $(summary .critical_fixable), expected 2 (log4j + libfoo; tomcat ignored, duplicate collapsed)"
[ "$(summary .kev)" = 1 ] || fail "kev $(summary .kev), expected 1 (linux-libc-dev KEV is ignored)"
[ "$(stat -c %a "$cache")" = 700 ] || fail "cache dir is $(stat -c %a "$cache"), expected 700"
pass "CRITICAL-with-fix and KEV counted after the id/package ignores; report dir is private"

# --- 3. one mail per change -------------------------------------------------------------
[ "$(mails)" = 1 ] || fail "first KEV: $(mails) mails, expected 1"
m="$tmp/mails/0.txt"
grep -q "^Subject: \[trivy\] localhost: 1 new known-exploited" "$m" || fail "mail subject: $(grep Subject "$m")"
grep -q "To: admin@example.org" "$m" || fail "mail recipient missing"
grep -q "CVE-2021-44228" "$m" || fail "mail does not name the KEV"
grep -q "geonetwork:3.4.4-postgres" "$m" || fail "mail does not name the image"
! grep -q "CVE-2025-24813" "$m" || fail "mail names an ignored CVE"
grep -q -- "--mail-rcpt admin@example.org" "$tmp/docker-calls" || fail "curl container not given the recipient"
grep -q -- "--network la_internal" "$tmp/docker-calls" || fail "mail not sent from the compose network"
pass "the first KEV finding is mailed once, naming image and CVE"

run again 0
[ "$(mails)" = 1 ] || fail "same findings: mailed again ($(mails))"
pass "the same findings next week send no mail"

# --- 4. failed send retried -------------------------------------------------------------
cat >"$tmp/fx/solr_9.7.0.json" <<JSON
{"ArtifactName":"solr:9.7.0","Results":[{"Target":"y","Vulnerabilities":[$(vuln CVE-2021-45046 log4j-core CRITICAL)]}]}
JSON
before="$(cat "$cache/notified.json")"
touch "$tmp/mail-fail"
run mailfail 0
[ "$(mails)" = 1 ] || fail "mail failure: a mail was recorded"
[ "$(cat "$cache/notified.json")" = "$before" ] || fail "mail failure: the finding was recorded as notified"
grep -q "will retry" "$tmp/out" || fail "mail failure: not logged"
rm -f "$tmp/mail-fail"
run retry 0
[ "$(mails)" = 2 ] || fail "retry: $(mails) mails, expected 2"
grep -q "CVE-2021-45046" "$tmp/mails/1.txt" || fail "retry: new KEV not in the mail"
grep -q "1 new known-exploited" "$tmp/mails/1.txt" || fail "retry: the old KEV counted as new"
pass "a mail that cannot be sent is retried on the next run"

# --- 5. scanner broken ------------------------------------------------------------------
touch "$tmp/trivy-fail"
run broken 1
[ "$(summary .status)" = error ] || fail "all scans failed: status $(summary .status)"
[ "$(summary .stale)" = true ] || fail "all scans failed: not marked stale"
[ "$(summary .kev)" = 2 ] || fail "all scans failed: last good findings lost (kev $(summary .kev))"
[ "$(mails)" = 3 ] || fail "scan failing: $(mails) mails, expected 3"
grep -q "scan is failing" "$tmp/mails/2.txt" || fail "scan failing: wrong subject"
run broken-again 1
[ "$(mails)" = 3 ] || fail "still failing: mailed again"
rm -f "$tmp/trivy-fail"
pass "a broken scanner is reported once, without wiping the last good report"

# --- 6. no recipient --------------------------------------------------------------------
render "$tmp/trivy-scan-norcpt.sh" ""
rm -f "$cache/notified.json"
run norcpt 0 "$tmp/trivy-scan-norcpt.sh"
grep -q "curlimages/curl" "$tmp/docker-calls" && fail "no recipient: still tried to mail"
grep -q "no recipient" "$tmp/out" || fail "no recipient: no warning"
pass "with no recipient nothing is mailed and the journal says why"

# --- 7. KEV catalog unreachable ---------------------------------------------------------
touch "$tmp/kev-fail"
run kevfail 0
grep -q "using the cached one" "$tmp/out" || fail "KEV download failure: cached catalog not used"
[ "$(summary .kev)" = 2 ] || fail "KEV download failure: kev $(summary .kev), expected 2"
pass "an unreachable KEV catalog falls back to the cached copy"
rm -f "$tmp/kev-fail"

# --- 8. CI collector --------------------------------------------------------------------
collect() { # $1 = installed scan script, $2 = destination
  rm -rf "$2"; mkdir -p "$2"
  PATH="$tmp/bin:$PATH" TRIVY_SCAN_SCRIPT="$1" bash scripts/trivy-ci-collect.sh >"$tmp/collect.tar" 2>"$tmp/collect.err" ||
    { cat "$tmp/collect.err" >&2; fail "collector exited non-zero"; }
  tar -C "$2" -xf "$tmp/collect.tar" || fail "collector stdout is not a clean tar"
}
collect "$tmp/trivy-scan.sh" "$tmp/c1"
[ "$(cat "$tmp/c1/rc")" = 0 ] || fail "collector: rc $(cat "$tmp/c1/rc")"
jq -e '.kev == 2' "$tmp/c1/summary.json" >/dev/null || fail "collector: summary missing or wrong"
ls "$tmp/c1/out/"*.json >/dev/null 2>&1 || fail "collector: per-image reports missing"
[ ! -e "$tmp/c1/mailhog.json" ] || fail "collector: queried mailhog on a postfix host"
render "$tmp/trivy-scan-dev.sh" "admin@example.org" true
rm -f "$cache/notified.json"
: >"$tmp/docker-calls"
collect "$tmp/trivy-scan-dev.sh" "$tmp/c2"
grep -q "trivy-scan: mailed" "$tmp/c2/scan.log" || fail "collector (dev): the scan did not mail"
grep -q -- "smtp://mailhog:1025" "$tmp/docker-calls" || fail "dev mode does not mail mailhog:1025"
jq -e '.total == 1' "$tmp/c2/mailhog.json" >/dev/null || fail "collector (dev): no mailhog search result"
collect "$tmp/missing-script" "$tmp/c3"
[ "$(cat "$tmp/c3/rc")" = 127 ] || fail "collector: a host without the scanner is not reported"
pass "the CI collector returns rc, log, report and the mailhog check as a clean tar"
echo "All checks passed."

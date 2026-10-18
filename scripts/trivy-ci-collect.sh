#!/usr/bin/env bash
# Run on a deployed host by the Jenkins `Trivy scan` stage:
#   ssh <host> bash -s < scripts/trivy-ci-collect.sh | tar -C trivy-reports/<host> -xf -
#
# Runs the SAME scanner the docker-housekeeping role installs for the weekly timer
# (/usr/local/bin/trivy-scan.sh --force), so CI and portals share one implementation, and
# writes a tar to stdout with:
#   rc            the scanner's exit status
#   scan.log      its output
#   summary.json  + out/*.json   the report (root-only on the host)
#   mailhog.json  only when the scan mailed and the host mails to mailhog: the mailhog
#                 search for "[trivy]", so CI checks the mail actually arrived.
# Nothing else on stdout: diagnostics go to stderr.
#
# TRIVY_SCAN_SCRIPT / TRIVY_CACHE_DIR override the installed paths (tests only).
set -u

SCAN="${TRIVY_SCAN_SCRIPT:-/usr/local/bin/trivy-scan.sh}"
w="$(mktemp -d)"
trap 'rm -rf "$w"' EXIT

if [ ! -x "$SCAN" ]; then
  echo "trivy-ci-collect: $SCAN not installed (docker_housekeeping_trivy_enabled=false?)" >"$w/scan.log"
  echo 127 >"$w/rc"
  tar -C "$w" -cf - .
  exit 0
fi

var() { sed -n "s/^$1=\"\(.*\)\"\$/\1/p" "$SCAN"; }
cache="${TRIVY_CACHE_DIR:-$(var CACHE)}"

rc=0
sudo "$SCAN" --force >"$w/scan.log" 2>&1 || rc=$?
echo "$rc" >"$w/rc"
sudo tar -C "$cache" -cf - summary.json out 2>/dev/null | tar -C "$w" -xf - 2>/dev/null || true

if grep -q 'trivy-scan: mailed' "$w/scan.log" && [ "$(var SMTP_HOST)" = mailhog ]; then
  # Same trick as the scanner's mail: mailhog may live on another host of the cluster.
  add_host=()
  if [ -z "$(sudo docker ps -q --filter label=com.docker.compose.service=mailhog)" ]; then
    mapping=$(sudo docker ps -q | xargs -r sudo docker inspect --format '{{range .HostConfig.ExtraHosts}}{{println .}}{{end}}' 2>/dev/null |
      grep -m1 -E '^mailhog[:=]' | sed 's/=/:/' || true)
    [ -n "$mapping" ] && add_host=(--add-host "$mapping")
  fi
  sudo docker run --rm --network "$(var MAIL_NETWORK)" "${add_host[@]}" "$(var CURL_IMAGE)" -s --max-time 30 \
    'http://mailhog:8025/api/v2/search?kind=containing&query=%5Btrivy%5D' >"$w/mailhog.json" 2>/dev/null ||
    echo '{"total":0,"error":"mailhog unreachable"}' >"$w/mailhog.json"
fi

tar -C "$w" -cf - .

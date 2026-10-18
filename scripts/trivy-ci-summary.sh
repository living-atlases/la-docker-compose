#!/usr/bin/env bash
# Verdict of the Jenkins `Trivy scan` stage over what scripts/trivy-ci-collect.sh brought
# back from each host: trivy-reports/<host>/{rc,scan.log,summary.json,out/,mailhog.json}.
#
# Prints one line per host (status, images, CRITICAL with a fix, KEV) and every KEV, and
# exits 1 -- the stage turns that into UNSTABLE, never FAILURE -- when a host has a KEV,
# no report, a failing or skipped (low disk) scan, or a mail that did not go out: not
# sent ("could not mail"), nobody to send it to, or sent to mailhog but not there.
#
# Usage: trivy-ci-summary.sh [reports-dir]   (default: trivy-reports)
set -u
dir="${1:-trivy-reports}"
bad=0
printf '%-28s %-8s %6s %5s %4s\n' HOST STATUS IMAGES CRIT KEV
for d in "$dir"/*/; do
  [ -d "$d" ] || continue
  d="${d%/}"
  h="$(basename "$d")"
  rc="$(cat "$d/rc" 2>/dev/null || echo missing)"
  if [ ! -s "$d/summary.json" ]; then
    printf '%-28s scanner rc=%s, no report\n' "$h" "$rc"
    sed 's/^/    /' "$d/scan.log" 2>/dev/null || true
    bad=1
    continue
  fi
  jq -r --arg h "$h" '[$h, .status, .images, .critical_fixable, .kev] | @tsv' "$d/summary.json" |
    awk -F'\t' '{printf "%-28s %-8s %6s %5s %4s\n", $1, $2, $3, $4, $5}'
  jq -r '.per_image[] | .image as $i | .kev[] | "    KEV \(.id)  \($i)  \(.pkg) \(.installed) -> \(.fixed)"' "$d/summary.json"
  # error = scanner broken, skipped = host too short of disk to scan: neither is "clean".
  jq -e '.kev == 0 and (.status == "ok" or .status == "partial")' "$d/summary.json" >/dev/null || bad=1
  if grep -q -e 'could not mail' -e 'no recipient' "$d/scan.log" 2>/dev/null; then
    grep -e 'could not mail' -e 'no recipient' "$d/scan.log" | sed 's/^/    /'
    bad=1
  fi
  if [ -e "$d/mailhog.json" ] && ! jq -e '.total > 0' "$d/mailhog.json" >/dev/null 2>&1; then
    echo "    the scan mailed, but no [trivy] mail is in mailhog"
    bad=1
  fi
done
if [ "$bad" != 0 ]; then
  echo "TRIVY: known-exploited CVEs, scanner or mail failures - see above and the trivy-reports artifacts."
  exit 1
fi
echo "TRIVY: no known-exploited CVEs in the running images."

#!/bin/bash
#
# test-nginx-h2-cve.sh
#
# nginx HTTP/2 and HTTP/3 RCEs of 2026-11-19 (CVE-2026-123633, CVE-2026-123007,
# CVE-2026-121810): fixed in nginx 1.30.7 and 1.31.9. la_nginx serves HTTP/2 by default.
#
# docker_nginx_version must be an exact X.Y.Z tag at or above the fixed release of its branch.
# A floating tag ("1.30") is not enough: the nginx service uses the default pull policy
# (missing), so a host that already has nginx:1.30 keeps the vulnerable build forever. Measured
# 2026-11-19: eight hosts ran 1.30.6 under the 1.30 tag while Docker Hub already served 1.30.7.
#
# NGINX_VERSION_UNDER_TEST overrides the value read from the defaults (to see the test fail).
set -euo pipefail
cd "$(dirname "$0")/.."

FIXED="1.30=1.30.7 1.31=1.31.9"

v=${NGINX_VERSION_UNDER_TEST:-$(sed -n 's/^docker_nginx_version: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' roles/la-compose/defaults/main.yml)}
[ -n "$v" ] || { echo "FAIL: docker_nginx_version not found in roles/la-compose/defaults/main.yml"; exit 1; }
grep -q 'image: nginx:{{ docker_nginx_version' roles/la-compose/templates/docker-compose/infrastructure/nginx.yml.j2 \
  || { echo "FAIL: nginx.yml.j2 no longer takes its tag from docker_nginx_version"; exit 1; }

[[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "FAIL: docker_nginx_version=$v is not an exact X.Y.Z tag (pull policy missing keeps the old build)"; exit 1; }

br=${v%.*}
newer=1
for pair in $FIXED; do
  if [ "${pair%%=*}" = "$br" ]; then
    dpkg --compare-versions "$v" ge "${pair#*=}" || { echo "FAIL: nginx $v < ${pair#*=} (CVE-2026-123633/123007)"; exit 1; }
    echo "OK: nginx $v (fixed in ${pair#*=})"; exit 0
  fi
  dpkg --compare-versions "$v" gt "${pair#*=}" || newer=0
done
[ "$newer" = 1 ] || { echo "FAIL: nginx branch $br has no fixed release (CVE-2026-123633/123007)"; exit 1; }
echo "OK: nginx $v (newer than every fixed branch)"

#!/usr/bin/env bash
# The boky/postfix tag postfix.yml.j2 defaults to, as a deploy meets it:
#   1. Debian with `nc`, which the compose healthcheck runs;
#   2. libbrotli1 at or above the fixed build for its release (CVE-2026-111497);
#   3. healthy on a first start, after a restart, and after a recreate that keeps the
#      image's anonymous volumes (compose does that; 5.2.0 added /var/run/ and others,
#      where a stale pid file would stop a daemon from coming back).
# Needs Docker and the image (pulled if missing); ~1 min. Its containers are removed on exit.
set -u
cd "$(dirname "$0")/.."
docker info >/dev/null 2>&1 || { echo "[SKIP] no Docker here"; exit 0; }
IMG="boky/postfix:$(sed -n "s/.*postfix_version | default('\([^']*\)').*/\1/p" roles/la-compose/templates/docker-compose/infrastructure/postfix.yml.j2)"
C=pfximagetest$$
trap 'docker rm -f -v "$C" "$C-2" >/dev/null 2>&1' EXIT
fail=0
ok()  { echo "[PASS] $1"; }
bad() { echo "[FAIL] $1" >&2; fail=1; }

docker image inspect "$IMG" >/dev/null 2>&1 || docker pull -q "$IMG" >/dev/null || { bad "cannot pull $IMG"; exit 1; }

# 1-2. Packages.
info=$(docker run --rm --entrypoint sh "$IMG" -c '. /etc/os-release; echo "$ID $VERSION_CODENAME";
  command -v nc >/dev/null && echo nc || echo no-nc; dpkg-query -W -f="\${Version}\n" libbrotli1 2>/dev/null || echo none')
read -r os codename <<<"$(sed -n 1p <<<"$info")"
[ "$os" = debian ] && [ "$(sed -n 2p <<<"$info")" = nc ] && ok "$IMG is Debian $codename with nc" ||
  bad "$IMG: $os $codename, $(sed -n 2p <<<"$info") (the healthcheck needs nc)"
brotli=$(sed -n 3p <<<"$info")
case "$codename" in
  bookworm) min=1.0.9-2+deb12u1 ;;
  trixie) min=1.1.0-2+deb13u1 ;;
  *) min="" ;;
esac
if [ "$brotli" = none ]; then
  ok "$IMG has no libbrotli1"
elif [ -z "$min" ]; then
  bad "$IMG: libbrotli1 $brotli on $codename, a release with no known fixed build"
elif docker run --rm --entrypoint dpkg "$IMG" --compare-versions "$brotli" ge "$min"; then
  ok "$IMG has libbrotli1 $brotli (>= $min)"
else
  bad "$IMG has libbrotli1 $brotli, below the fixed $min"
fi

# 3. Starts, restarts, recreates.
healthy() { local i; for i in $(seq 45); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null)" = healthy ] && return 0; sleep 2; done
  docker logs "$1" 2>&1 | tail -15 >&2; return 1; }
hc=(--health-cmd "nc -w 3 127.0.0.1 25 </dev/null | grep -q '^220'" --health-interval 3s --health-start-period 5s)
docker run -d --name "$C" -e ALLOWED_SENDER_DOMAINS=example.org "${hc[@]}" "$IMG" >/dev/null
healthy "$C" && ok "healthy on a first start" || bad "not healthy on a first start"
docker restart "$C" >/dev/null
healthy "$C" && ok "healthy after a restart" || bad "not healthy after a restart"
docker stop "$C" >/dev/null
docker run -d --name "$C-2" --volumes-from "$C" -e ALLOWED_SENDER_DOMAINS=example.org "${hc[@]}" "$IMG" >/dev/null
healthy "$C-2" && ok "healthy after a recreate that keeps the anonymous volumes" ||
  bad "not healthy after a recreate that keeps the anonymous volumes"

exit $fail

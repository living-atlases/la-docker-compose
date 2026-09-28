#!/bin/bash
# Recreate the containers whose compose definition changed.
#
# The deploy runs `docker compose up --no-recreate` so live services are never torn
# down. That also leaves every existing container on its OLD definition:
#  - exited one-shots (branding-init, certs-init...): compose re-runs the same container
#    with the old command, build after build. #422: branding-init gained a
#    `chmod -R a+rX /output`, the rendered compose had it, and the hub's branding volume
#    stayed 0640 (nginx 403). These are always safe to recreate: nothing is running.
#  - running services, with --running only: a changed image, env or mount never
#    applies, and `docker compose restart` does not re-read env either (a Java 17
#    --add-opens in BIOCACHE_HUB_JAVA_OPTS never reached la_biocache-hub). Recreating
#    one takes that service down for its own restart; the caller decides whether that
#    is acceptable (it is not in production, where only the drift warning is given).
#
# Only containers whose config-hash label differs from the current definition are
# touched, one-shots only when exited with no restart policy, and --no-deps keeps
# everything else as it is.
#
# Usage (from the compose project directory): recreate-drifted-services.sh [--running]
# Prints "recreated <svc>" per service, then "recreated N".
set -u

running=false
[ "${1:-}" = --running ] && running=true

n=0
while read -r svc want; do
  [ -n "$svc" ] || continue
  cid=$(docker compose ps -a -q "$svc" 2>/dev/null | head -1)
  [ -n "$cid" ] || continue
  read -r status policy have < <(docker inspect -f \
    '{{.State.Status}} {{.HostConfig.RestartPolicy.Name}} {{index .Config.Labels "com.docker.compose.config-hash"}}' \
    "$cid" 2>/dev/null)
  [ -n "$have" ] && [ "$have" != "$want" ] || continue
  case "$status" in
    exited)
      case "$policy" in ""|no) ;; *) $running || continue ;; esac ;;
    running|restarting)
      $running || continue ;;
    *) continue ;;
  esac
  if docker compose up -d --no-deps --force-recreate "$svc" >/dev/null; then
    echo "recreated $svc"
    n=$((n + 1))
  else
    echo "FAILED to recreate $svc" >&2
  fi
done < <(docker compose config --hash '*' 2>/dev/null)
echo "recreated $n"

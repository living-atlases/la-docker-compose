#!/bin/bash
# Recreate the run-once init containers whose compose definition changed.
#
# The deploy runs `docker compose up --no-recreate` so live services are never torn
# down. But that also leaves every EXITED one-shot (branding-init, certs-init...) on its
# old definition: compose re-runs the same container, with the old command, build after
# build. #422: branding-init gained a `chmod -R a+rX /output`, the rendered compose had
# it, and the hub's branding volume stayed 0640 (nginx 403) because the container was
# the one created days before.
#
# A one-shot is safe to recreate: it is not running, so nothing goes down. Only
# containers that are exited, have no restart policy, and whose config-hash label
# differs from the current definition are touched; --no-deps keeps their dependents
# (and everything else) as they are.
#
# Run from the compose project directory. Prints "recreated <svc>" per service, then
# "recreated N".
set -u

n=0
while read -r svc want; do
  [ -n "$svc" ] || continue
  cid=$(docker compose ps -a -q "$svc" 2>/dev/null | head -1)
  [ -n "$cid" ] || continue
  read -r status policy have < <(docker inspect -f \
    '{{.State.Status}} {{.HostConfig.RestartPolicy.Name}} {{index .Config.Labels "com.docker.compose.config-hash"}}' \
    "$cid" 2>/dev/null)
  [ "$status" = exited ] || continue
  case "$policy" in ""|no) ;; *) continue ;; esac
  [ -n "$have" ] && [ "$have" != "$want" ] || continue
  if docker compose up -d --no-deps --force-recreate "$svc" >/dev/null; then
    echo "recreated $svc"
    n=$((n + 1))
  else
    echo "FAILED to recreate $svc" >&2
  fi
done < <(docker compose config --hash '*' 2>/dev/null)
echo "recreated $n"

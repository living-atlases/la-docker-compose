#!/usr/bin/env bash
# MEASUREMENT SPIKE (TASK-50 phase 4), NOT a deploy path: Ansible renders, nothing is deployed.
#
# Renders the la-compose deploy tree of every docker_compose host of an inventory into a
# throwaway container per host (playbooks/bundle-render.yml), then captures each container's
# bundle with capture.sh and writes its manifest (manifest.py: paths, hashes, modes, owners).
# The real hosts are only read: bundle-render.yml's first play runs a read-only `setup` on them
# for the facts the render needs (IP, memory, CPUs).
#
# Containers are named after each host's ansible_host (the synchronize module finds the
# container by it) and resolve the other hosts' names to their real IPs (--add-host).
#
# Usage: render.sh --out DIR --inventory-args "-i a.ini -i b.ini" [--extra-vars JSON]
#                  [--image TAG] [--keep]
# Needs: docker, ansible-playbook + ansible-inventory on PATH (with community.docker), run from
# the repo root with ANSIBLE_ROLES_PATH set like the deploy.
# Prints: BUNDLE-TIMING host=all step=render seconds=<s>, one step=capture line per host, and
# writes DIR/<ansible_host>.render.manifest. The bundles stay inside the containers.
set -euo pipefail

OUT=""
INV_ARGS=""
EXTRA_VARS="{}"
IMAGE=la-render-spike:local
KEEP=false
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --inventory-args) INV_ARGS="$2"; shift 2 ;;
    --extra-vars) EXTRA_VARS="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --keep) KEEP=true; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$OUT" ] && [ -n "$INV_ARGS" ] || { echo "--out and --inventory-args are required" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
mkdir -p "$OUT"

docker build -q -t "$IMAGE" -f "$HERE/render.Dockerfile" "$HERE" >/dev/null

# docker_compose hosts: "<inventory_hostname> <ansible_host>" per line.
# shellcheck disable=SC2086
ansible-inventory $INV_ARGS --list 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
hv = d.get("_meta", {}).get("hostvars", {})
seen, todo = set(), ["docker_compose"]
hosts = []
while todo:
    g = todo.pop()
    if g in seen: continue
    seen.add(g)
    hosts += d.get(g, {}).get("hosts", [])
    todo += d.get(g, {}).get("children", [])
for h in sorted(set(hosts)):
    print(h, hv.get(h, {}).get("ansible_host", h))' >"$OUT/hosts"
[ -s "$OUT/hosts" ] || { echo "no docker_compose hosts in the inventory" >&2; exit 1; }

addhosts=()
while read -r _ ah; do
  # CI hosts are often ssh_config aliases: resolve through ssh -G first, as the Jenkinsfile does.
  real=$(ssh -G "$ah" 2>/dev/null | awk '/^hostname /{print $2; exit}')
  ip=$(getent hosts "${real:-$ah}" | awk '{print $1; exit}' || true)
  [ -n "$ip" ] && addhosts+=(--add-host "$ah:$ip")
done <"$OUT/hosts"

overlay="$OUT/render-overlay.ini"
echo "[docker_compose]" >"$overlay"
while read -r ih ah; do
  docker rm -f "$ah" >/dev/null 2>&1 || true
  docker run -d --name "$ah" --hostname "$ah" --label la-render-spike=1 "${addhosts[@]}" "$IMAGE" >/dev/null
  echo "$ih ansible_connection=community.docker.docker ansible_docker_user=root ansible_python_interpreter=/usr/local/bin/python-render" >>"$overlay"
done <"$OUT/hosts"

cleanup() {
  $KEEP && return 0
  while read -r _ ah; do docker rm -f "$ah" >/dev/null 2>&1 || true; done <"$OUT/hosts"
}
trap cleanup EXIT

start=$(date +%s)
rc=0
# shellcheck disable=SC2086
(cd "$REPO" && ansible-playbook playbooks/bundle-render.yml $INV_ARGS -i "$overlay" --limit docker_compose \
   --skip-tags docker-volumes,nameindex --extra-vars "$EXTRA_VARS") || rc=$?
echo "BUNDLE-TIMING host=all step=render seconds=$(( $(date +%s) - start )) rc=$rc"
[ "$rc" -eq 0 ] || { echo "BUNDLE-FAILED host=all step=render rc=$rc"; exit "$rc"; }

while read -r _ ah; do
  docker cp "$HERE/capture.sh" "$ah:/tmp/capture.sh"
  docker cp "$HERE/manifest.py" "$ah:/tmp/manifest.py"
  docker exec "$ah" bash /tmp/capture.sh | grep '^BUNDLE-TIMING' | sed "s/host=[^ ]*/host=$ah(render)/"
  docker exec "$ah" python3 /tmp/manifest.py /var/cache/la-bundle/bundle.tgz >"$OUT/$ah.render.manifest"
done <"$OUT/hosts"

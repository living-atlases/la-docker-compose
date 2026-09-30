#!/usr/bin/env bash
# MEASUREMENT SPIKE (TASK-50 phase 4), NOT a deploy path: Ansible renders, nothing is deployed.
#
# Renders the la-compose deploy tree of every docker_compose host of an inventory into a
# throwaway container per host (playbooks/bundle-render.yml), then captures each container's
# bundle with capture.sh and writes its manifest (manifest.py: paths, hashes, modes, owners).
# The real hosts are only read: a read-only `ansible -m setup` for the facts the render needs
# (IP, memory, CPUs), passed to the render as render_host_facts.
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

# "<inventory_hostname> <ansible_host>" for the docker_compose hosts ($OUT/hosts) and for every
# host of the inventory ($OUT/all-hosts).
# shellcheck disable=SC2086
ansible-inventory $INV_ARGS --list 2>/dev/null >"$OUT/inventory.json"
python3 - "$OUT" <<'PY'
import json, sys
out = sys.argv[1]
d = json.load(open(f"{out}/inventory.json"))
hv = d.get("_meta", {}).get("hostvars", {})
def members(root):
    seen, todo, hosts = set(), [root], set()
    while todo:
        g = todo.pop()
        if g in seen: continue
        seen.add(g)
        hosts |= set(d.get(g, {}).get("hosts", []))
        todo += d.get(g, {}).get("children", [])
    return sorted(hosts)
for name, root in (("hosts", "docker_compose"), ("all-hosts", "all")):
    with open(f"{out}/{name}", "w") as f:
        for h in members(root):
            f.write(f"{h} {hv.get(h, {}).get('ansible_host', h)}\n")
PY
rm -f "$OUT/inventory.json"
[ -s "$OUT/hosts" ] || { echo "no docker_compose hosts in the inventory" >&2; exit 1; }

addhosts=()
while read -r _ ah; do
  # CI hosts are often ssh_config aliases: resolve through ssh -G first, as the Jenkinsfile does.
  real=$(ssh -G "$ah" 2>/dev/null | awk '/^hostname /{print $2; exit}')
  ip=$(getent hosts "${real:-$ah}" | awk '{print $1; exit}' || true)
  [ -n "$ip" ] && addhosts+=(--add-host "$ah:$ip")
done <"$OUT/hosts"

while read -r _ ah; do
  docker rm -f "$ah" >/dev/null 2>&1 || true
  docker run -d --name "$ah" --hostname "$ah" --label la-render-spike=1 "${addhosts[@]}" "$IMAGE" >/dev/null
done <"$OUT/hosts"

# The facts the render reads from the real machines (IP, memory, CPUs): a read-only `setup`,
# its own run, so nothing it discovers (the host's python) leaks into the render.
# shellcheck disable=SC2086
ANSIBLE_CACHE_PLUGIN=memory ansible docker_compose $INV_ARGS -m ansible.builtin.setup \
  -a 'gather_subset=hardware,network' --tree "$OUT/facts" >/dev/null ||
  { echo "BUNDLE-FAILED host=all step=facts: could not read the real hosts' facts" >&2; exit 1; }
python3 - "$OUT" <<'PY' >"$OUT/host-facts"
import json, os, sys
out = sys.argv[1]
for line in open(f"{out}/hosts"):
    ih = line.split()[0]
    f = json.load(open(os.path.join(out, "facts", ih)))["ansible_facts"]
    rf = {"default_ipv4": {"address": f.get("ansible_default_ipv4", {}).get("address", "")},
          "memtotal_mb": f["ansible_memtotal_mb"], "processor_vcpus": f["ansible_processor_vcpus"],
          "processor_count": f["ansible_processor_count"]}
    print(ih, "render_host_facts='" + json.dumps(rf) + "'")
PY

# EVERY inventory host gets a docker connection, never ssh. Roles delegate to other aliases of
# the same machine (nginx_vhost writes each vhost's Gatus monitor to the '<host>.gatus' alias):
# a host that shares a docker_compose host's ansible_host goes to that host's container, and any
# other host to a container that does not exist, so a delegation nobody expected fails loudly
# instead of writing to a real machine. (The first local runs of this spike, without this, wrote
# those monitors to the real CI gatus host through ~/.ssh/config.)
overlay="$OUT/render-overlay.ini"
echo "[render_overlay]" >"$overlay"
cut -d' ' -f2 "$OUT/hosts" | sort -u >"$OUT/containers"
while read -r ih ah; do
  if grep -qxF "$ah" "$OUT/containers"; then
    echo "$ih ansible_connection=community.docker.docker ansible_docker_host=$ah ansible_docker_user=root ansible_python_interpreter=/usr/local/bin/python-render $(awk -v h="$ih" '$1==h {sub(/^[^ ]+ /, ""); print}' "$OUT/host-facts")"
  else
    echo "$ih ansible_connection=community.docker.docker ansible_docker_host=la-render-blocked-no-such-container"
  fi
done <"$OUT/all-hosts" >>"$overlay"

cleanup() {
  $KEEP && return 0
  while read -r _ ah; do docker rm -f "$ah" >/dev/null 2>&1 || true; done <"$OUT/hosts"
}
trap cleanup EXIT

# The render gathers the CONTAINERS' facts under the real inventory hostnames. A shared fact
# cache (playbooks/ansible.cfg: jsonfile in /tmp/ansible_facts, 1 h) would hand them to the next
# real deploy (wrong IP, heap budget, worker_processes), or the other way round. Memory only.
export ANSIBLE_CACHE_PLUGIN=memory

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

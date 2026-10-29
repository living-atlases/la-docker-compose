#!/usr/bin/env bash
#
# test-nginx-srv-mountpoints.sh
#
# On a host that does not carry the portal's branding, infrastructure/nginx.yml.j2
# bind-mounts ../srv read-only at /srv, and each data hub's branding volume goes INSIDE
# it, at /srv/<hub branding_url>/www. runc cannot create a mountpoint inside a read-only
# mount, so unless that directory already exists in ../srv, la_nginx fails to start:
#
#   error mounting ".../la_branding-assets-marinas/_data" to rootfs at
#   "/srv/colecciones-marinas.gbif.es/www": ... mkdirat ...: read-only file system
#
# and every vhost on the host is down with it (gbif-es node 1, 2026-10-29, the first hub
# branding placed on a compose host without the portal's).
#
# What this pins down: for every mount nested in the read-only ../srv, the role creates
# the host directory beforehand (generate-hub-instance.yml, "create its branding
# mountpoint under srv"). With docker available, it also shows the failure itself.
#
# Cheap: renders the template with Jinja; the docker part only runs a busybox `true`.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PYTHON=""
for candidate in "${VENV_MOLECULE:-/nonexistent}/bin/python" "$REPO_ROOT/.venv-molecule/bin/python" python3; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import jinja2, yaml' 2>/dev/null; then
        PYTHON="$candidate"; break
    fi
done
[ -n "$PYTHON" ] || { echo "no python with jinja2 and yaml"; exit 1; }

"$PYTHON" - "$REPO_ROOT" <<'PYTHON'
import re, sys
from pathlib import Path
import jinja2, yaml

root = Path(sys.argv[1])
src = (root / "roles/la-compose/templates/docker-compose/infrastructure/nginx.yml.j2").read_text()
# Only the volumes list: the rest of the service needs the whole role's scope.
block = src[src.index("    volumes:\n      - \"{{ nginx_conf_dir }}/nginx.conf"):]
block = block[:block.index("{# ---- Static `alias` locations")]
env = jinja2.Environment(trim_blocks=True, undefined=jinja2.ChainableUndefined)

HUB = {"is_portal": False, "use_branding": True, "suffix": "-marinas", "pkg": "marinas",
       "aliases": {"branding": "dc1.branding_marinas"}}
PORTAL = {"is_portal": True, "use_branding": True, "suffix": "", "pkg": "", "aliases": {}}

def volumes(portal_branding_here):
    out = env.from_string("services:\n  nginx:\n" + block).render(
        nginx_conf_dir="/data/docker-compose/nginx",
        group_names=["branding"] if portal_branding_here else [],
        branding_url="datos.example.org",
        hub_instances=[PORTAL, HUB],
        hostvars={"dc1.branding_marinas": {"branding_url": "colecciones-marinas.example.org"}},
    )
    return yaml.safe_load(out)["services"]["nginx"]["volumes"]

task = next(t for t in yaml.safe_load((root / "roles/la-compose/tasks/generate-hub-instance.yml").read_text())
            if "create its branding mountpoint under srv" in str(t.get("name", "")))
data_dir = "/data/docker-compose"
created = env.from_string(task["ansible.builtin.file"]["path"]).render(
    docker_compose_data_dir=data_dir, branding_url="colecciones-marinas.example.org")

failures = []
def check(cond, what):
    print(("[PASS] " if cond else "[FAIL] ") + what)
    if not cond:
        failures.append(what)

vols = volumes(portal_branding_here=False)
ro_srv = "../srv:/srv:ro" in vols
check(ro_srv, "without the portal's branding nginx bind-mounts ../srv read-only")
nested = [v.split(":")[1] for v in vols if not v.startswith("../srv:") and v.split(":")[1].startswith("/srv/")]
check(nested == ["/srv/colecciones-marinas.example.org/www"], f"the hub's branding volume nests in it ({nested})")
for dest in nested:
    host = data_dir + "/" + dest.lstrip("/")
    check(created == host, f"the role creates its mountpoint {host} (task path: {created})")

vols = volumes(portal_branding_here=True)
check("../srv:/srv:ro" not in vols, "with the portal's branding there is no read-only ../srv to nest in")
check(task.get("when") and "inst.render_config" not in task["when"],
      "the mountpoint is created on every pass, not only when the hub's config is rendered")

sys.exit(1 if failures else 0)
PYTHON

# The failure itself, when docker can run a container here: the same two mounts, without
# and with the directory.
if docker info >/dev/null 2>&1 && docker image inspect busybox >/dev/null 2>&1; then
    tmp="$(mktemp -d)"; vol="srv-mountpoint-test-$$"
    trap 'rm -rf "$tmp"; docker volume rm -f "$vol" >/dev/null 2>&1 || true' EXIT
    docker volume create "$vol" >/dev/null
    mounts=(-v "$tmp:/srv:ro" -v "$vol:/srv/hub.example.org/www:ro")
    if docker run --rm "${mounts[@]}" busybox true >/dev/null 2>&1; then
        echo "[INFO] docker created the nested mountpoint itself here: this runtime does not reproduce it"
    else
        echo "[PASS] docker: a volume nested in a read-only bind without its directory fails to start"
    fi
    mkdir -p "$tmp/hub.example.org/www"
    if docker run --rm "${mounts[@]}" busybox true >/dev/null 2>&1; then
        echo "[PASS] docker: with the directory created beforehand it starts"
    else
        echo "[FAIL] docker: it still fails with the directory there"; exit 1
    fi
else
    echo "[SKIP] docker part: no docker daemon or busybox image"
fi

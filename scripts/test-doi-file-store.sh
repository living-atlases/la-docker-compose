#!/usr/bin/env bash
# services/doi-service.yml.j2: the files behind the minted DOIs live on the host, not in the
# container's writable layer.
#
# doi-service writes one file per minted DOI under doi_file_store, which the doi-service role
# defaults to /data/doi-service/files. Only `config` and `logs` were bound, so on docker-compose
# those files went into the container: a `docker compose up` that recreates it drops them, and no
# backup ever saw them. Nothing on a running host says this is wrong, hence this check:
#   - the compose template binds the host dir onto the container path;
#   - that container path is the role's own doi_file_store default, so the two cannot drift;
#   - generate-compose creates the host dir as the compose user, like it does for the log dirs
#     (docker would otherwise create it root-owned and every mint would fail).
# Static, ~1s, no Docker.
set -u
cd "$(dirname "$0")/.."
PY="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}python3"
command -v "$PY" >/dev/null || PY=python3

"$PY" <<'PY'
import re, sys, jinja2, yaml
from ansible.plugins.filter.core import FilterModule as Core

fail = []
def pass_(m): print(f"[PASS] {m}")
def bad(m): fail.append(m); print(f"[FAIL] {m}", file=sys.stderr)

ROLE_CONF = "ala-install/ansible/roles/doi-service/templates/doi-service-config.yml"
try:
    conf = open(ROLE_CONF, encoding="utf-8").read()
except OSError as e:
    print(f"[SKIP] {ROLE_CONF} is not checked out ({e.strerror}): the store path was not compared")
    conf = None

store = None
if conf:
    m = re.search(r"store:\s*\{\{\s*doi_file_store\s*\|\s*default\('([^']+)'\)", conf)
    if not m:
        bad(f"no doi_file_store default found in {ROLE_CONF}: the role may have renamed it")
    else:
        store = m.group(1)
        pass_(f"the role's doi_file_store default is {store}")

e = jinja2.Environment(
    loader=jinja2.FileSystemLoader("roles/la-compose/templates/docker-compose/services"),
    trim_blocks=True)
e.filters["to_json"] = Core().filters()["to_json"]
data_dir = "/data/docker-compose"
svc = yaml.safe_load(e.get_template("doi-service.yml.j2").render(
    data_dir=data_dir, docker_extra_hosts_dict={}, datastore_endpoints={},
    docker_network="internal"))["services"]["doi-service"]

binds = dict(v.split(":")[:2] for v in svc["volumes"])
host = f"{data_dir}/doi-service/files"
if binds.get(host) is None:
    bad(f"doi-service.yml.j2 does not bind {host}: minted DOIs would stay in the container")
else:
    pass_(f"doi-service.yml.j2 binds {host} onto {binds[host]}")
    if store and binds[host] != store:
        bad(f"the bind lands on {binds[host]} but the role writes to {store}")
    elif store:
        pass_("the bind lands exactly where the role writes")

tasks = open("roles/la-compose/tasks/generate-compose.yml", encoding="utf-8").read()
# The dir has to exist and belong to the compose user before the container starts. Split on the
# task headers rather than matching across them: one block is one task.
blocks = [b for b in re.split(r"(?m)^- name: ", tasks)
          if '{{ data_dir }}/doi-service/files' in b]
if not blocks:
    bad("generate-compose.yml creates no {{ data_dir }}/doi-service/files: docker would own it as root")
else:
    body = blocks[0]
    missing = [f"{k}: {w}" for k, w in (("state", "directory"),
                                        ("owner", "{{ docker_compose_userid }}"),
                                        ("group", "{{ docker_compose_usergid }}"))
               if f"{k}: {w}" not in body and f'{k}: "{w}"' not in body]
    if missing:
        bad("the doi-service/files task does not set " + ", ".join(missing))
    else:
        pass_("generate-compose.yml creates the file store as the compose user")

sys.exit(1 if fail else 0)
PY

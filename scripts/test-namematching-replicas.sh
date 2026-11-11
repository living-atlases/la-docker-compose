#!/usr/bin/env bash
# services/namematching-service.yml.j2 + the nginx replica drop-in: a stateless service can run
# more than one replica WITHOUT changing what a portal that does not replicate renders.
#
# Why these three things travel together (TASK-112):
#   - docker compose REFUSES to scale a service declaring a container_name, and says so as a
#     WARNING, not an error: the service stays at one replica in silence;
#   - two replicas cannot bind the same published host port;
#   - nginx has no upstream block anywhere (nginx_load_balancing is false), only ~91 locations
#     with dynamic resolution, so retrying another replica comes from the conf.d drop-in and
#     nowhere else. Measured: 3 replicas with one wedged and nginx as it is today fail 34.6% of
#     requests; with the drop-in, 0 of 2076 (scripts/experiments/measure-replica-failover.sh).
# So replicas > 1 without the drop-in must not deploy at all, and generate-compose asserts it.
# Static, ~1s, no Docker.
set -u
cd "$(dirname "$0")/.."
PY="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}python3"
command -v "$PY" >/dev/null || PY=python3

"$PY" <<'PY'
import re, sys, jinja2, yaml

fail = []
def pass_(m): print(f"[PASS] {m}")
def bad(m): fail.append(m); print(f"[FAIL] {m}", file=sys.stderr)

e = jinja2.Environment(
    loader=jinja2.FileSystemLoader("roles/la-compose/templates/docker-compose/services"),
    trim_blocks=True)
VARS = dict(data_dir="/data", host_private_ip="10.0.0.7", namematching_service_port=9179,
            docker_network="internal", namematching_docker_tag="latest")

def render(n):
    return e.get_template("namematching-service.yml.j2").render(
        namematching_service_replicas=n, **VARS)

one = render(1)
svc = yaml.safe_load(one)["services"]["namematching-service"]
if svc.get("container_name") != "la_namematching_service":
    bad(f"replicas=1 does not keep container_name: {svc.get('container_name')}")
elif svc.get("ports") != ["10.0.0.7:9179:9179"]:
    bad(f"replicas=1 does not keep the published port: {svc.get('ports')}")
elif "deploy" in svc:
    bad("replicas=1 declares deploy: a portal that does not replicate must render as before")
else:
    pass_("replicas=1 (the default) renders exactly as before: container_name, port, no deploy")

# The default has to BE 1, or every portal starts replicating on the next deploy.
defaults = open("roles/la-compose/defaults/main.yml", encoding="utf-8").read()
if not re.search(r"(?m)^namematching_service_replicas:\s*1\s*$", defaults):
    bad("namematching_service_replicas does not default to 1 in the role defaults")
else:
    pass_("the role default is 1: replicating is opt-in, per portal")

two = yaml.safe_load(render(2))["services"]["namematching-service"]
problems = []
if "container_name" in two:
    problems.append("still declares container_name (compose would silently stay at one replica)")
if "ports" in two:
    problems.append("still publishes a host port (two replicas cannot bind it)")
if (two.get("deploy") or {}).get("replicas") != 2:
    problems.append(f"does not declare deploy.replicas: 2 ({two.get('deploy')})")
if problems:
    bad("replicas=2: " + "; ".join(problems))
else:
    pass_("replicas=2 drops container_name and the host port and declares deploy.replicas: 2")

# Everything else about the service must be the same with and without replicas: the volumes are
# all :ro (that is WHY this one is a candidate), and the healthcheck is what autoheal acts on.
for k in ("volumes", "healthcheck", "image", "command", "environment", "networks", "restart"):
    if svc.get(k) != two.get(k):
        bad(f"replicas changes {k}, which it must not: {svc.get(k)} != {two.get(k)}")
if all(v.endswith(":ro") for v in svc["volumes"]):
    pass_("every volume is read-only, which is what makes this service replicable")
else:
    bad(f"a volume is writable, so two replicas would share it: {svc['volumes']}")

# The nginx drop-in: the two directives, and NOT proxy_read_timeout (each location sets 10m on
# purpose for the long downloads; lowering it globally would cut them).
drop = jinja2.Environment(loader=jinja2.FileSystemLoader("roles/la-compose/templates"),
                          trim_blocks=True).get_template("nginx-replicas.conf.j2").render(
                              docker_nginx_replica_connect_timeout="1s")
body = [l for l in drop.splitlines() if l.strip() and not l.startswith("#")]
if body != ["proxy_connect_timeout 1s;",
            "proxy_next_upstream error timeout http_502 http_503 http_504;"]:
    bad(f"the drop-in does not render the two directives and only those: {body}")
else:
    pass_("the drop-in renders proxy_connect_timeout and proxy_next_upstream, nothing else")
if not re.search(r"(?m)^docker_nginx_replica_failover:\s*false\s*$", defaults):
    bad("docker_nginx_replica_failover does not default to false: it would change every portal")
else:
    pass_("the drop-in is off by default: it changes every proxied location on the host")

# Replicas without the drop-in must not deploy.
tasks = open("roles/la-compose/tasks/generate-compose.yml", encoding="utf-8").read()
blocks = [b for b in re.split(r"(?m)^- name: ", tasks)
          if "namematching_service_replicas" in b and "docker_nginx_replica_failover" in b]
if not blocks or "assert" not in blocks[0]:
    bad("generate-compose.yml does not assert that replicas > 1 needs the nginx drop-in")
elif "groups['docker_compose']" not in blocks[0]:
    bad("the assert does not gate replicas on a single compose host: replicating drops the "
        "published port an off-host consumer needs")
else:
    pass_("generate-compose.yml refuses replicas > 1 without the drop-in or on multi-host")

# The drop-in ALONE, with nothing replicated, must not deploy on multi-host either: it is
# http-level, so it also changes the locations that proxy to another host, where a 1s connect
# timeout is a 502 for the whole portal and there is no second address to retry anyway.
alone = [b for b in re.split(r"(?m)^- name: ", tasks)
         if "docker_nginx_replica_failover" in b and "namematching_service_replicas" not in b
         and "assert" in b]
if not alone:
    bad("generate-compose.yml does not assert the drop-in alone needs a single compose host")
elif "groups['docker_compose']" not in alone[0]:
    bad("the drop-in assert does not gate it on a single compose host: its two directives are "
        "http-level and reach the locations that proxy to another host")
else:
    pass_("generate-compose.yml refuses the drop-in alone on a multi-host inventory")

# The drop-in is written AND removed again, or turning it off would leave it behind forever.
if 'conf.d/replica-failover.conf' not in tasks or 'state: absent' not in tasks:
    bad("generate-compose.yml does not remove the drop-in when it is off")
else:
    pass_("generate-compose.yml writes the drop-in and removes it when it is off")

sys.exit(1 if fail else 0)
PY

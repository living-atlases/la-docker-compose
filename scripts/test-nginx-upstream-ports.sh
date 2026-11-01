#!/usr/bin/env bash
# la_nginx talks to its containers without upstream keepalive. Under sustained load it ran
# out of ephemeral ports towards one upstream and answered 502 ("connect() failed (99: Cannot
# assign requested address)"), while keepalive_requests 100 kept resetting the HTTP/2
# connections of services calling each other through it.
#
# Checks the compose file sets the sysctls, in the nginx service and not another one, and
# that the rendered nginx.conf gets a keepalive_requests above the ala-install default.
# ~5s, no cluster.
set -eu
cd "$(dirname "$0")/.."

PY=.venv-molecule/bin/python3
[ -x "$PY" ] || PY=python3

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

"$PY" - "$TMP" <<'PY'
import os
import re
import subprocess
import sys
import yaml

def fail(msg):
    print(f"[FAIL] {msg}", file=sys.stderr)
    sys.exit(1)

compose = open("roles/la-compose/templates/docker-compose/infrastructure/nginx.yml.j2").read()
service = compose.split("\n  nginx:\n", 1)
if len(service) != 2:
    fail("nginx service not found in nginx.yml.j2")
block = re.split(r"\n  \S", service[1], maxsplit=1)[0]
if not re.search(r'net\.ipv4\.tcp_tw_reuse: "1"', block):
    fail("nginx service does not set net.ipv4.tcp_tw_reuse")
ports = re.search(r'net\.ipv4\.ip_local_port_range: "(\d+) (\d+)"', block)
if not ports:
    fail("nginx service does not set net.ipv4.ip_local_port_range")
if int(ports[2]) - int(ports[1]) <= 28232:
    fail("ip_local_port_range is not wider than the kernel default")
print("[PASS] nginx service widens its ephemeral ports and reuses TIME_WAIT")

tasks = yaml.safe_load(open("roles/la-compose/tasks/generate-compose.yml"))
wanted = ("Load nginx role defaults (namespaced)",
          "Apply nginx defaults only where inventory did not provide a value",
          "Generate nginx.conf")
found = [t for t in tasks if t.get("name") in wanted]
if [t["name"] for t in found] != list(wanted):
    fail("the tasks that render nginx.conf are not there, in that order")
ala = os.path.abspath("ala-install")
if not os.path.exists(f"{ala}/ansible/roles/nginx/defaults/main.yml"):
    fail("ala-install is not checked out")
tmp = sys.argv[1]
for t in found:
    t.pop("tags", None)
    module = next(v for k, v in t.items() if k.startswith("ansible.builtin"))
    for key in ("file", "src"):
        if key in module:
            module[key] = module[key].replace("{{ playbook_dir }}/../ala-install", ala)
    if "dest" in module:
        module.update(dest=f"{tmp}/nginx.conf")
        module.pop("owner")
        module.pop("group")
defaults = yaml.safe_load(open("roles/la-compose/defaults/main.yml"))
play = [{"hosts": "all", "connection": "local", "gather_facts": False,
         "vars": {"services_enabled": ["nginx"], "nginx_other_log_formats": [], "ansible_processor_count": 2,
                  **yaml.safe_load(open(f"{ala}/ansible/roles/nginx/vars/debian.yml")),
                  **{k: v for k, v in defaults.items() if "nginx_" in k},
                  "ansible_python_interpreter": sys.executable},
         "tasks": found}]
yaml.safe_dump(play, open(f"{tmp}/play.yml", "w"))

def rendered(extra):
    # The real tasks through ansible: a set_fact outranks a task's vars, which reading the
    # YAML does not show.
    inventory = f"{tmp}/inventory"
    open(inventory, "w").write(f"localhost {extra}\n")
    out = subprocess.run([os.path.join(os.path.dirname(sys.executable), "ansible-playbook"),
                          "-i", inventory, f"{tmp}/play.yml"], capture_output=True, text=True)
    if out.returncode:
        fail(f"render failed: {out.stdout[-900:]}")
    return re.search(r"keepalive_requests (\S+);", open(f"{tmp}/nginx.conf").read())[1]

if int(defaults["docker_nginx_keepalive_requests"]) <= 100:
    fail("docker_nginx_keepalive_requests must stay above the ala-install default of 100")
got = rendered("")
if got != str(defaults["docker_nginx_keepalive_requests"]):
    fail(f"rendered nginx.conf has keepalive_requests {got}")
print("[PASS] nginx.conf gets keepalive_requests above the ala-install default")
if rendered("nginx_keepalive_requests=500") != "500":
    fail("the inventory no longer wins over docker_nginx_keepalive_requests")
print("[PASS] the inventory can still set keepalive_requests")
PY

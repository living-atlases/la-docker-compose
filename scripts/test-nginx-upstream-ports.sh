#!/usr/bin/env bash
# la_nginx talks to its containers without upstream keepalive. Under sustained load it ran
# out of ephemeral ports towards one upstream and answered 502 ("connect() failed (99: Cannot
# assign requested address)"), while keepalive_requests 100 kept resetting the HTTP/2
# connections of services calling each other through it.
#
# Checks the compose file sets the sysctls, in the nginx service and not another one, and
# that the rendered nginx.conf gets a keepalive_requests above the ala-install default.
# ~1s, no cluster.
set -eu
cd "$(dirname "$0")/.."

PY=.venv-molecule/bin/python3
[ -x "$PY" ] || PY=python3

"$PY" - <<'PY'
import re
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
gen = next((t for t in tasks if t.get("name") == "Generate nginx.conf"), None)
if gen is None:
    fail("task 'Generate nginx.conf' not found")
if gen.get("vars", {}).get("nginx_keepalive_requests") != "{{ docker_nginx_keepalive_requests }}":
    fail("'Generate nginx.conf' does not pass docker_nginx_keepalive_requests")
defaults = yaml.safe_load(open("roles/la-compose/defaults/main.yml"))
if int(defaults.get("docker_nginx_keepalive_requests", 0)) <= 100:
    fail("docker_nginx_keepalive_requests must stay above the ala-install default of 100")
print("[PASS] nginx.conf gets keepalive_requests above the ala-install default")
PY

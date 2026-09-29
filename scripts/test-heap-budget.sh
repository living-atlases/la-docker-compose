#!/bin/bash
#
# test-heap-budget.sh
#
# roles/la-compose/templates/heap-budget.j2 sums the -Xmx of the JVMs one host runs and
# compares it with the host's RAM. Every Java service defaults to -Xmx2g and VM tuning
# never carries over (on VMs several apps shared one tomcat heap), so on gbif-es node 1
# eight JVMs asked for 16 GB of heap on a 22 GB host and nothing said so.
#
# What this pins down: only the JVMs this host runs count (services_enabled, minus
# skip_services); g/m sizes both parse; per-JVM overhead and the host reserve are
# added; `over` flips exactly when the need passes the RAM, and never without RAM facts.
#
# Cheap on purpose: renders the template with Jinja, no Ansible run, no Docker.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PYTHON=""
for candidate in "${VENV_MOLECULE:-/nonexistent}/bin/python" "$REPO_ROOT/.venv-molecule/bin/python" python3; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import jinja2' 2>/dev/null; then
        PYTHON="$candidate"; break
    fi
done
[ -n "$PYTHON" ] || { echo "no python with jinja2"; exit 1; }

"$PYTHON" - "$REPO_ROOT" <<'PYTHON'
import json, sys
from pathlib import Path
from jinja2 import Environment, FileSystemLoader

root = Path(sys.argv[1])
env = Environment(loader=FileSystemLoader(str(root / "roles/la-compose/templates")))
tpl = env.get_template("heap-budget.j2")

def opts(xmx):
    return f"-Djava.awt.headless=true -Xmx{xmx} -Xms1g -Dlog4j2.formatMsgNoLookups=true"

OPTS = {"biocache_service": opts("4g"), "ala_hub": opts("1536m"), "regions": opts("2g"),
        "logger": opts("1g"), "images": opts("1g")}

def render(**kw):
    base = dict(service_java_opts_dict=OPTS, docker_heap_reserve_mb=3072,
                docker_jvm_overhead_mb=512)
    base.update(kw)
    return json.loads(tpl.render(**base))

failures = []
def check(cond, what):
    print(("[PASS] " if cond else "[FAIL] ") + what)
    if not cond: failures.append(what)

# gatus is enabled but not a JVM (no JAVA_OPTS); images is a JVM but not on this host.
r = render(services_enabled=["biocache_service", "ala_hub", "regions", "logger", "gatus"],
           ansible_memtotal_mb=22000)
check(r["jvms"] == 4, "only this host's JVMs count (not images, not gatus)")
check(r["heap_mb"] == 4096 + 1536 + 2048 + 1024, f"g and m sizes sum right ({r['heap_mb']})")
check(r["need_mb"] == r["heap_mb"] + 4 * 512 + 3072, "per-JVM overhead and reserve are added")
check(r["over"] is False, "fits in 22000 MB")

r = render(services_enabled=["biocache_service", "ala_hub", "regions", "logger"],
           ansible_memtotal_mb=r["need_mb"] - 1)
check(r["over"] is True, "one MB short is over")

r = render(services_enabled=["biocache_service", "ala_hub", "regions", "logger"],
           skip_services=["biocache_service"], ansible_memtotal_mb=22000)
check(r["jvms"] == 3 and r["heap_mb"] == 1536 + 2048 + 1024, "skip_services are not counted")

r = render(services_enabled=["biocache_service"])
check(r["over"] is False, "without RAM facts it never claims over")

sys.exit(1 if failures else 0)
PYTHON

# The same three tasks generate-compose.yml runs, extracted from it (not copied), through
# a real ansible-playbook: the lookup, from_json and the warning's filters only exist there.
ANSIBLE_PLAYBOOK="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}ansible-playbook"
command -v "$ANSIBLE_PLAYBOOK" >/dev/null || ANSIBLE_PLAYBOOK=ansible-playbook
ANSIBLE_PLAYBOOK="$(realpath -e "$(command -v "$ANSIBLE_PLAYBOOK")")"  # absolute: the runs below cd away
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
"$PYTHON" - "$REPO_ROOT" "$tmp/tasks.yml" <<'PYTHON'
import sys, yaml
from pathlib import Path
tasks = yaml.safe_load((Path(sys.argv[1]) / "roles/la-compose/tasks/generate-compose.yml").read_text())
mine = [t for t in tasks if str(t.get("name", "")).startswith("Heap budget:")]
assert len(mine) == 4, f"expected 4 'Heap budget:' tasks, found {len(mine)}"
Path(sys.argv[2]).write_text(yaml.safe_dump(mine))
PYTHON
mkdir -p "$tmp/templates"; cp "$REPO_ROOT/roles/la-compose/templates/heap-budget.j2" "$tmp/templates/"
cat >"$tmp/play.yml" <<YML
- hosts: localhost
  connection: local
  gather_facts: false
  vars:
    ansible_memtotal_mb: 22000
    services_enabled: [biocache_service, ala_hub, regions, logger, collectory, species_lists, ala_bie, bie_index]
    service_java_opts_dict:
      biocache_service: "-Xmx2g -Xms1g"
      ala_hub: "-Xmx2g -Xms1g"
      regions: "-Xmx2g -Xms1g"
      logger: "-Xmx1g -Xms1g"
      collectory: "-Xmx2g -Xms1g"
      species_lists: "-Xmx2g -Xms1g"
      ala_bie: "-Xmx2g -Xms1g"
      bie_index: "-Xmx2g -Xms1g"
  tasks:
    - ansible.builtin.include_tasks: $tmp/tasks.yml
YML
out="$(cd "$tmp" && "$ANSIBLE_PLAYBOOK" -i localhost, play.yml 2>&1)" || { echo "[FAIL] warn-only run failed: $out"; exit 1; }
echo "$out" | grep -q "WARN: the JVMs on this host may need 22528 MB and it has 22000 MB" \
  || { echo "[FAIL] no warning for gbif-es node 1 at defaults: $out"; exit 1; }
echo "$out" | grep -q "biocache_service=2048" || { echo "[FAIL] warning lacks the per-service heaps"; exit 1; }
echo "[PASS] ansible: gbif-es node 1 at defaults (8 JVMs, 15 GB of -Xmx on 22 GB) warns, lists the heaps, does not fail"
if (cd "$tmp" && "$ANSIBLE_PLAYBOOK" -i localhost, play.yml -e docker_heap_budget_strict=true >/dev/null 2>&1); then
  echo "[FAIL] strict mode did not fail"; exit 1
fi
echo "[PASS] ansible: docker_heap_budget_strict=true fails"

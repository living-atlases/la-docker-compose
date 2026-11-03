#!/usr/bin/env bash
#
# test-gatus-stage.sh
#
# nginx_vhost writes each gatus check on groups['gatus'][0] with delegate_to, and delegate_to
# ignores --limit: a deploy limited to a staging host writes into production's gatus.
#
# What this pins down: use_gatus is true only on the stage of the host that runs gatus, a
# gatus outside the compose hosts counts as production, and the two tasks that delegate to
# the gatus host stay behind that fact, which no include_role overrides.
#
# Cheap: renders the two set_fact expressions with jinja2, no Ansible run.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PYTHON=""
for candidate in "${VENV_MOLECULE:-/nonexistent}/bin/python" "$REPO_ROOT/.venv-molecule/bin/python" python3; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import yaml, jinja2' 2>/dev/null; then
        PYTHON="$candidate"; break
    fi
done
[ -n "$PYTHON" ] || { echo "no python with yaml and jinja2"; exit 1; }

"$PYTHON" - "$REPO_ROOT" <<'PYTHON'
import sys
from pathlib import Path
import jinja2
import yaml

root = Path(sys.argv[1])
tasks = yaml.safe_load((root / "roles/la-compose/tasks/generate-compose.yml").read_text())
by_name = {t.get("name"): t for t in tasks}
stage_expr = by_name["Find the stage of the host that runs gatus"]["ansible.builtin.set_fact"]["gatus_host_stage"]
gatus_expr = by_name["Set use_gatus fact"]["ansible.builtin.set_fact"]["use_gatus"]
env = jinja2.Environment(undefined=jinja2.ChainableUndefined)

def use_gatus(gatus_ip, compose, mine=None):
    groups = {"gatus": ["g.gatus"], "docker_compose": list(compose)}
    hostvars = {"g.gatus": {"ansible_host": gatus_ip}, **compose}
    context = {"groups": groups, "hostvars": hostvars}
    if mine:
        context["docker_stage"] = mine
    stage = env.from_string(stage_expr).render(**context).strip()
    return env.from_string(gatus_expr).render(gatus_host_stage=stage, **context) == "True"

prod = {"a": {"ansible_host": "10.0.0.1", "docker_stage": "production"}}
both = {**prod, "b": {"ansible_host": "10.0.0.2", "docker_stage": "staging"}}
unstaged = {"a": {"ansible_host": "10.0.0.1"}}
cases = [
    ("production host, gatus on production", use_gatus("10.0.0.1", both, "production"), True),
    ("staging host, gatus on production", use_gatus("10.0.0.1", both, "staging"), False),
    ("staging host, gatus on staging", use_gatus("10.0.0.2", both, "staging"), True),
    ("production host, gatus on staging", use_gatus("10.0.0.2", both, "production"), False),
    ("no stages at all", use_gatus("10.0.0.1", unstaged), True),
    ("production host, gatus outside compose", use_gatus("10.0.0.9", prod, "production"), True),
    ("staging host, gatus outside compose", use_gatus("10.0.0.9", both, "staging"), False),
]
failed = [name for name, got, want in cases if got != want]

# `vars:` on an include_role beat a set_fact: passing use_gatus would skip the stage check.
# Only `use_gatus: false` is safe, the stub vhosts in register-shared-vhost-stubs.yml.
passed = []
for path in (root / "roles/la-compose/tasks").glob("*.yml"):
    for t in yaml.safe_load(path.read_text()) or []:
        if ((t.get("vars") or {}).get("use_gatus", False) is not False
                and (t.get("ansible.builtin.include_role") or t.get("include_role"))):
            passed.append(f"{path.name}: {t.get('name')}")
if passed:
    failed.append(f"include_role passes use_gatus: {passed}")

# The disk checks: a production gatus says nothing about a staging host.
template = (root / "roles/la-compose/templates/docker-compose/gatus/extra-checks.yaml.j2").read_text()
disk = template[template.index("{% set disk = namespace"):template.index("{% set disk_hosts = disk.hosts %}")]
disk_env = jinja2.Environment(undefined=jinja2.ChainableUndefined, trim_blocks=True, lstrip_blocks=True)
rendered = disk_env.from_string(disk + "{{ disk.hosts | join(',') }}").render(
    groups={"docker_compose": list(both)}, hostvars=both, docker_stage="production").strip()
if rendered != "a":
    failed.append(f"disk checks on a production gatus: {rendered!r}")

stubs = yaml.safe_load((root / "roles/la-compose/tasks/register-shared-vhost-stubs.yml").read_text())
delegated = [t for t in stubs if "groups['gatus'][0]" in str(t.get("delegate_to", ""))]
if not delegated or any("use_gatus" not in str(t.get("when")) for t in delegated):
    failed.append("register-shared-vhost-stubs.yml delegates to the gatus host without use_gatus")

if failed:
    print("[FAIL] " + "; ".join(failed))
    sys.exit(1)
print(f"[PASS] use_gatus follows the stage of the gatus host ({len(cases)} cases)")
PYTHON

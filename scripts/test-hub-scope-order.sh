#!/usr/bin/env bash
#
# test-hub-scope-order.sh
#
# Every data hub render (generate-hub-instance.yml) bulk-loads the hub's inventory
# variables as facts, and hub-scope-restore.yml can only put back the names the portal
# had: a name only a hub defines (regions_appname, query_context, hub_filter,
# enable_hub_data, clientId...) stays behind, because Ansible cannot unset a fact. Any
# portal service rendered AFTER the hub loop reads it. On gbif-es node 1 (2026-10-29)
# the portal's regions came out with the hub's data_hub_uid filter and wrote its gatus
# check as <hub>-regions-http.yaml, a duplicate that crashed gatus.
#
# What this pins down: in generate-compose.yml no service configuration is rendered after
# the hub loop: no "Run ... configuration generation" task, and no include_role of an
# ala-install service role, below "Hubs: render each data hub".
#
# Cheap: reads the task file, no Ansible run.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PYTHON=""
for candidate in "${VENV_MOLECULE:-/nonexistent}/bin/python" "$REPO_ROOT/.venv-molecule/bin/python" python3; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import yaml' 2>/dev/null; then
        PYTHON="$candidate"; break
    fi
done
[ -n "$PYTHON" ] || { echo "no python with yaml"; exit 1; }

"$PYTHON" - "$REPO_ROOT" <<'PYTHON'
import sys
from pathlib import Path
import yaml

root = Path(sys.argv[1])
tasks = yaml.safe_load((root / "roles/la-compose/tasks/generate-compose.yml").read_text())
names = [str(t.get("name", "")) for t in tasks]
loop = next((i for i, n in enumerate(names) if n.startswith("Hubs: render each data hub")), None)
if loop is None:
    print("[FAIL] no 'Hubs: render each data hub' task in generate-compose.yml")
    sys.exit(1)

# Roles that render the portal's service configuration (ala-install's). nginx_vhost only
# registers a vhost from the variables it is handed, and it runs after the loop on purpose
# (the portal's branding vhost, gatus).
not_services = {"nginx_vhost"}
late = []
for t, n in zip(tasks[loop + 1:], names[loop + 1:]):
    role = (t.get("ansible.builtin.include_role") or t.get("include_role") or {}).get("name")
    if n.startswith("Run ") and "configuration generation" in n:
        late.append(n)
    elif role and role not in not_services:
        late.append(f"{n} (include_role {role})")

if late:
    print("[FAIL] portal service renders after the hub loop, where they read the hubs' leftover facts:")
    for n in late:
        print(f"   - {n}")
    sys.exit(1)
first_render = min(i for i, n in enumerate(names) if n.startswith("Run ") and "configuration generation" in n)
print(f"[PASS] every portal service render ({sum(1 for n in names[:loop] if n.startswith('Run ') and 'configuration generation' in n)}) "
      f"comes before the hub loop (task {loop}; first render at task {first_render})")
PYTHON

#!/usr/bin/env bash
#
# test-bie-hub-server-url.sh
#
# A data hub's bie_base_url already ends with its context path (the generator writes
# https://<hub>/especies next to bie_hub_context_path = /especies). ala-install's bie-hub
# template appended the context path again, so grails.serverURL came out as
# https://<hub>/especies/especies and the OIDC login sent CAS the callback
# /especies/especies/callback (gbif-es colecciones-marinas, 2026-10-29). The hub's VM had
# fixed it by hand.
#
# What this pins down, on the ala-install the submodule pins: serverURL is the hub's
# bie_base_url, and a portal at the root or under its own path renders as before.
#
# Cheap: renders one template line with Jinja, no Ansible run.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="${1:-$REPO_ROOT/ala-install/ansible/roles/bie-hub/templates/bie-hub-config.yml.j2}"

PYTHON=""
for candidate in "${VENV_MOLECULE:-/nonexistent}/bin/python" "$REPO_ROOT/.venv-molecule/bin/python" python3; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import jinja2' 2>/dev/null; then
        PYTHON="$candidate"; break
    fi
done
[ -n "$PYTHON" ] || { echo "no python with jinja2"; exit 1; }

"$PYTHON" - "$TEMPLATE" <<'PYTHON'
import sys
import jinja2

line = next(l for l in open(sys.argv[1]).read().splitlines() if l.strip().startswith("serverURL:"))
env = jinja2.Environment(trim_blocks=True, undefined=jinja2.StrictUndefined)

CASES = [
    # (what, bie_base_url, bie_hub_context_path, expected serverURL)
    ("data hub, path in bie_base_url", "https://colecciones-marinas.example.org/especies", "/especies",
     "https://colecciones-marinas.example.org/especies"),
    ("portal at the root", "https://especies.example.org", "", "https://especies.example.org"),
    ("portal under its own path", "https://bie.example.org", "/ala-bie", "https://bie.example.org/ala-bie"),
]
failures = 0
for what, base, ctx, expected in CASES:
    got = env.from_string(line).render(bie_base_url=base, bie_hub_context_path=ctx).split("serverURL:", 1)[1].strip()
    ok = got == expected
    failures += not ok
    print(("[PASS] " if ok else "[FAIL] ") + f"{what}: serverURL {got}" + ("" if ok else f" (expected {expected})"))
sys.exit(1 if failures else 0)
PYTHON

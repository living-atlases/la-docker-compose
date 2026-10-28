#!/usr/bin/env bash
# The pre-deploy ALA-host guard (scripts/config-baseline.py ala-hosts) classifies what it must,
# and the offline renderer still feeds it the services it exists for. ~1s, no inventory needed.
#
#   1. the self-test: planted ALA service and test hosts are findings; a declared fallback, a
#      docs link, a third party and a Grails environments.* block are not.
#   2. the host table it reads parses and carries the keys both guards rely on.
#   3. render-properties-offline.sh still renders spatial-hub (whose lists.urlUi this guard was
#      written for) through its per-portal template.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PY="${PYTHON:-python3}"

fail() { echo "FAIL: $*" >&2; exit 1; }

"$PY" scripts/config-baseline.py ala-hosts --self-test || fail "ala-hosts self-test"

"$PY" - <<'EOF' || fail "e2e/cypress/support/ala-hosts.json"
import json, re
t = json.load(open("e2e/cypress/support/ala-hosts.json"))
for k in ("serviceHosts", "familyPattern", "nonProdPattern", "inertKeyPrefixes"):
    assert k in t, f"missing {k}"
re.compile(t["familyPattern"]); re.compile(t["nonProdPattern"])
assert t["serviceHosts"].get("lists.ala.org.au"), "lists.ala.org.au must stay a service host"
EOF

bash -n scripts/render-properties-offline.sh || fail "render-properties-offline.sh syntax"
grep -q '^  "spatial-hub|spatial-hub|templates/@PORTAL@/spatial-hub-config.yml|' \
  scripts/render-properties-offline.sh || fail "renderer no longer renders spatial-hub"
grep -q 'tpl="${tpl//@PORTAL@/$PORTAL_EXPR}"' scripts/render-properties-offline.sh \
  || fail "renderer no longer resolves the spatial-hub portal template"

echo "PASS: config-baseline ala-hosts"

#!/usr/bin/env bash
# The CI must hand the data-hub inventories to ansible-playbook, or la-compose finds
# every hub group empty and drops the hub (build #397: green, hubs: [], no containers).
# Pure shell, ~1s, no cluster.
set -eu
cd "$(dirname "$0")/.."

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mk() { mkdir -p "$(dirname "$T/$1")"; : > "$T/$1"; }

# 1. one hub: only its inventory, never the portal's or the localhost-mode twin
mk lademo-inventories/lademo-inventory.ini
mk lademo-inventories/lademo-dev-docker-inventory.ini
mk testhub-inventories/testhub-inventory.ini
mk testhub-inventories/testhub-dev-docker-inventory.ini
out=$(bash scripts/hub-inventory-args.sh "$T" "$T/lademo-inventories")
[ "$out" = "-i $T/testhub-inventories/testhub-inventory.ini" ] \
    || fail "one hub: expected only testhub-inventory.ini, got: $out"
pass "one hub: only <pkg>-inventory.ini is passed"

# 2. trailing slash on the portal dir must not let the portal through
out=$(bash scripts/hub-inventory-args.sh "$T" "$T/lademo-inventories/")
echo "$out" | grep -q 'lademo-inventory.ini' && fail "portal inventory leaked with a trailing slash"
pass "portal inventory excluded even with a trailing slash"

# 3. two hubs, both passed
mk otherhub-inventories/otherhub-inventory.ini
out=$(bash scripts/hub-inventory-args.sh "$T" "$T/lademo-inventories")
for h in testhub otherhub; do
    echo "$out" | grep -q -- "-i $T/$h-inventories/$h-inventory.ini" || fail "two hubs: $h missing in: $out"
done
pass "several hubs are all passed"

# 4. no hubs: prints nothing, so a portal without hubs runs unchanged
N=$(mktemp -d); trap 'rm -rf "$T" "$N"' EXIT
mkdir -p "$N/lademo-inventories"; : > "$N/lademo-inventories/lademo-inventory.ini"
out=$(bash scripts/hub-inventory-args.sh "$N" "$N/lademo-inventories")
[ -z "$out" ] || fail "no hubs: expected nothing, got: $out"
pass "no hubs: nothing is added"

# 5. every ansible-playbook invocation in the Jenkinsfile that builds inventoryArg loads
#    them; a third copy of the block added later without the helper would drop the hubs.
blocks=$(grep -c "def inventoryArg = " Jenkinsfile || true)
calls=$(grep -c 'def hubInventoryArg = sh(' Jenkinsfile || true)
[ "$blocks" -ge 1 ] && [ "$calls" -eq "$blocks" ] \
    || fail "Jenkinsfile builds inventoryArg $blocks time(s) but loads the hub inventories $calls time(s)"
pass "Jenkinsfile: all $blocks inventoryArg blocks load the hub inventories"

echo "ALL PASS: hub inventory args"

#!/usr/bin/env bash
# bie-hub's own container config bakes in file:// paths the APPLICATION reads at
# startup: languageCodesUrl and external.blacklist. The role hardcoded them as
# file://{{ data_dir }}/{{ bie_hub }}/config/... -- a HOST path. For the portal that
# happens to equal the container mount (bie_hub=ala-bie-hub by construction), but a
# data hub's bie_hub is <pkg>-bie-hub while the container always mounts
# /data/ala-bie-hub (bie-hub.yml.j2), so the hub's config pointed languageCodesUrl at
# a path that does not exist INSIDE the container: FileNotFoundException on
# languages.json, crash-loop on every host (la-docker-compose build #402).
#
# This evaluates the REAL expressions from the role against both scenarios, so it
# cannot drift from the code it guards. ~1s, no cluster.
set -eu
cd "$(dirname "$0")/.."

ROLE=ala-install/ansible/roles/bie-hub/templates/bie-hub-config.yml.j2
[ -f "$ROLE" ] || { echo "SKIP: $ROLE not found (submodule not initialised?)"; exit 0; }
ANSIBLE=.venv-molecule/bin/ansible
[ -x "$ANSIBLE" ] || ANSIBLE=$(command -v ansible) || { echo "[FAIL] ansible not found" >&2; exit 1; }

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

# the two expressions the role now uses, taken from the role itself
lang_expr=$(python3 - "$ROLE" <<'EOF'
import sys, re
t = open(sys.argv[1]).read()
m = re.search(r"languageCodesUrl: \{\{ (.*) \}\}", t)
print(m.group(1) if m else "")
EOF
)
blacklist_expr=$(python3 - "$ROLE" <<'EOF'
import sys, re
t = open(sys.argv[1]).read()
m = re.search(r"  blacklist: \{\{ (.*) \}\}", t)
print(m.group(1) if m else "")
EOF
)
[ -n "$lang_expr" ] || fail "could not find languageCodesUrl in $ROLE"
[ -n "$blacklist_expr" ] || fail "could not find external.blacklist in $ROLE"

run() {  # run <expr> <extra -e vars...> -> the evaluated string, or "ERROR: <msg>"
    local expr="$1"; shift
    ANSIBLE_LOCALHOST_WARNING=False ANSIBLE_INVENTORY_UNPARSED_WARNING=False \
    "$ANSIBLE" localhost -i localhost, -c local -m debug -a "msg={{ $expr }}" \
        -e "data_dir=/data" -e "bie_hub=testhub-bie-hub" "$@" 2>&1 | python3 -c '
import sys, json
out = sys.stdin.read()
i = out.find("=> ")
if i < 0:
    print("ERROR: " + out.strip()[-200:]); sys.exit(0)
d = json.loads(out[i + 3:])
print("ERROR: " + str(d.get("msg"))[:200] if d.get("failed") else d["msg"])'
}

# 1. no override (VM / portal, where bie_hub already equals ala-bie-hub in practice):
#    falls back to the old host-path expression, unchanged.
got=$(run "$lang_expr")
[ "$got" = "file:///data/testhub-bie-hub/config/languages.json" ] \
    || fail "languageCodesUrl without override: expected the host-path fallback, got: $got"
pass "languageCodesUrl without override keeps the previous host-path behaviour"

got=$(run "$blacklist_expr")
[ "$got" = "file:///data/testhub-bie-hub/config/blacklist.json" ] \
    || fail "external.blacklist without override: expected the host-path fallback, got: $got"
pass "external.blacklist without override keeps the previous host-path behaviour"

# 2. a hub's generated inventory sets the override to the fixed container mount
#    (/data/ala-bie-hub) regardless of the host-side bie_hub name.
got=$(run "$lang_expr" -e "bie_hub_language_codes_url=file:///data/ala-bie-hub/config/languages.json")
[ "$got" = "file:///data/ala-bie-hub/config/languages.json" ] \
    || fail "languageCodesUrl with override: expected the container path, got: $got"
pass "languageCodesUrl with override points inside the container, not the host dir"

got=$(run "$blacklist_expr" -e "bie_hub_blacklist_url=file:///data/ala-bie-hub/config/blacklist.json")
[ "$got" = "file:///data/ala-bie-hub/config/blacklist.json" ] \
    || fail "external.blacklist with override: expected the container path, got: $got"
pass "external.blacklist with override points inside the container, not the host dir"

echo "ALL PASS: bie-hub container paths"

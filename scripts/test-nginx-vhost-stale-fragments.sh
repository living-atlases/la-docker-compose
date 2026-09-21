#!/usr/bin/env bash
# nginx_vhost removes the location fragments it is about to re-render: it `find`s them
# per nginx_paths item, then loops over the registered results. When every item is
# skipped (the cross-host stub paths of a shared vhost such as hub.l-a.site), each
# result is `{skipped: true, ...}` with no `files`, and `map(attribute='files')` dies
# with "'dict object' has no attribute 'files'" -- BEFORE the task's `when` is looked
# at, because Ansible templates the loop first. Build #398 hit this on all 3 hosts.
#
# This evaluates the REAL loop expression from the role against fixtures, so it cannot
# drift from the code it guards. ~2s, no cluster.
set -eu
cd "$(dirname "$0")/.."

ROLE=ala-install/ansible/roles/nginx_vhost/tasks/main.yml
ANSIBLE=.venv-molecule/bin/ansible
[ -x "$ANSIBLE" ] || ANSIBLE=$(command -v ansible) || { echo "[FAIL] ansible not found" >&2; exit 1; }

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

# the loop of the task that removes the stale fragments, taken from the role itself
expr=$(python3 - "$ROLE" <<'EOF'
import sys, re
t = open(sys.argv[1]).read()
m = re.search(r"- name: remove the location fragments this vhost is about to re-render\n(?:  .*\n)*?  loop: \"\{\{ (.*?) \}\}\"", t)
print(m.group(1) if m else "")
EOF
)
[ -n "$expr" ] || fail "could not find the removal loop in $ROLE"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
run() {  # run <fixture-json> -> the evaluated list as compact JSON, or "ERROR: <msg>"
    ANSIBLE_LOCALHOST_WARNING=False ANSIBLE_INVENTORY_UNPARSED_WARNING=False \
    "$ANSIBLE" localhost -i localhost, -c local -m debug -a "msg={{ $expr }}" -e "@$1" 2>&1 | python3 -c '
import sys, json
out = sys.stdin.read()
i = out.find("=> ")
if i < 0:
    print("ERROR: " + out.strip()[-200:]); sys.exit(0)
d = json.loads(out[i + 3:])
print("ERROR: " + str(d.get("msg"))[:200] if d.get("failed") else json.dumps(d["msg"], separators=(",", ":")))'
}

# 1. every item skipped (stub-only vhost): must yield an empty list, not an error
cat > "$T/skipped.json" <<'EOF'
{"nginx_stale_location_fragments": {"results": [
  {"skipped": true, "skip_reason": "Conditional result was False", "item": {"path": "/species"}},
  {"skipped": true, "skip_reason": "Conditional result was False", "item": {"path": "/regions"}}],
  "skipped": true, "msg": "All items skipped"}}
EOF
[ "$(run "$T/skipped.json")" = "[]" ] || fail "all items skipped: expected [], got: $(run "$T/skipped.json")"
pass "all items skipped -> nothing to remove, no error"

# 2. mixed: the skipped ones are ignored, the found fragments are all returned
cat > "$T/mixed.json" <<'EOF'
{"nginx_stale_location_fragments": {"results": [
  {"skipped": true, "item": {"path": "/species"}},
  {"files": [{"path": "/a/http_location_records_1.conf"}, {"path": "/a/https_location_records_1.conf"}], "item": {"path": "/records"}},
  {"files": [], "item": {"path": "/other"}}]}}
EOF
got=$(run "$T/mixed.json")
echo "$got" | grep -q 'http_location_records_1.conf' && echo "$got" | grep -q 'https_location_records_1.conf' \
    || fail "mixed: fragments not returned: $got"
pass "mixed results -> the found fragments come back, skipped items are ignored"

# 3. nothing registered at all (task never ran): empty, as before
echo '{}' > "$T/none.json"
[ "$(run "$T/none.json")" = "[]" ] || fail "no register: expected [], got: $(run "$T/none.json")"
pass "no registered results -> nothing to remove"

echo "ALL PASS: nginx_vhost stale fragments"

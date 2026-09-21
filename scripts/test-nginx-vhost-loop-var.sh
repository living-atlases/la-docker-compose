#!/usr/bin/env bash
# An include_role of nginx_vhost inside a loop must not use the default `item` in its
# `vars:`. Those vars are templated lazily, and nginx_vhost's own `with_items` tasks
# rebind `item` to a path dict, so `hostname: "{{ item.key }}"` dies there with
# "'dict object' has no attribute 'key'". Build #400 hit this on all 3 hosts
# (register-shared-vhost-stubs.yml). The fix is `loop_var:` -- this keeps it that way.
set -eu
cd "$(dirname "$0")/.."

python3 - <<'PY'
import glob, sys, yaml

def tasks(node):
    if isinstance(node, list):
        for t in node:
            yield from tasks(t)
    elif isinstance(node, dict):
        yield node
        for k in ("block", "rescue", "always"):
            yield from tasks(node.get(k))

bad = []
for f in sorted(glob.glob("roles/la-compose/tasks/*.yml")):
    for t in tasks(yaml.safe_load(open(f)) or []):
        inc = t.get("ansible.builtin.include_role") or t.get("include_role")
        if not (isinstance(inc, dict) and inc.get("name") == "nginx_vhost"):
            continue
        looped = "loop" in t or any(k.startswith("with_") for k in t)
        uses_item = "item" in repr(t.get("vars", {}))
        var = (t.get("loop_control") or {}).get("loop_var")
        if looped and uses_item and var in (None, "item"):
            bad.append("%s: %s" % (f, t.get("name")))
if bad:
    print("[FAIL] nginx_vhost include_role loops on `item`; set loop_control.loop_var:", *bad, sep="\n  ", file=sys.stderr)
    sys.exit(1)
print("[PASS] no nginx_vhost include_role loop templates vars from `item`")
PY

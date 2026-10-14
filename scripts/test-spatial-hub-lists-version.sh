#!/usr/bin/env bash
# spatial-hub compares lists.version with the integers 1 and 2 (PortalController, views); in
# Groovy "1" == 1 is false, so a quoted version sent a lists v1 portal to the /v2 API and the
# species list picker came back empty. Renders the lists block of the ala-install template and
# checks version is an int, also when lists_version comes from an INI inventory (a string).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TPL="$ROOT/ala-install/ansible/roles/spatial-hub/templates/ala/spatial-hub-config.yml"
python3 - "$TPL" <<'PY'
import sys, yaml, jinja2
src = open(sys.argv[1]).read().splitlines(keepends=True)
start = src.index("lists:\n")
end = next(i for i in range(start + 1, len(src)) if src[i][:1] not in (" ", "{", "\n"))
tpl = jinja2.Environment().from_string("".join(src[start:end]))
cases = [("default", {}, 1), ("INI string 1", {"lists_version": "1"}, 1),
         ("INI string 2", {"lists_version": "2"}, 2), ("int 2", {"lists_version": 2}, 2)]
fail = 0
for label, env, want in cases:
    lists = yaml.safe_load(tpl.render(**env))["lists"]
    ok = lists["version"] == want and type(lists["version"]) is int \
        and ("listTypes" in lists) == (want == 2)
    print(("PASS" if ok else "FAIL"), f"{label}: version={lists['version']!r} listTypes={'listTypes' in lists}")
    fail += not ok
print(f"== {len(cases) - fail} passed, {fail} failed")
sys.exit(1 if fail else 0)
PY

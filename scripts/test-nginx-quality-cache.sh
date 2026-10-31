#!/usr/bin/env bash
# The hub asks data-quality for its filters three times per page without caching them, so
# nginx caches those two endpoints. Under load that was most of what exhausted its ports.
#
# Checks the data-quality vhost keeps its catch-all, adds the cached location, that the
# location includes a file the role generates, and that the file uses the zone the conf
# defines. ~1s, no cluster.
set -eu
cd "$(dirname "$0")/.."

PY=.venv-molecule/bin/python3
[ -x "$PY" ] || PY=python3

"$PY" - <<'PY'
import re
import sys
import yaml

def fail(msg):
    print(f"[FAIL] {msg}", file=sys.stderr)
    sys.exit(1)

tasks = yaml.safe_load(open("roles/la-compose/tasks/generate-compose.yml"))
role = next((t for t in tasks
             if t.get("name") == "Run data-quality-filter-service configuration generation"), None)
if role is None:
    fail("data-quality role task not found")
paths = role.get("vars", {}).get("nginx_paths") or []
if len(paths) != 2:
    fail("the data-quality vhost needs the cached location and the catch-all")
cached, catch_all = paths
if cached["path"] != "{{ data_quality_filter_cached_path }}":
    fail("the first location must be the cached one")
for endpoint in ("getGroupedEnabledFilters", "getEnabledFiltersByLabel"):
    if endpoint not in role["vars"]["data_quality_filter_cached_path"]:
        fail(f"{endpoint} is not cached")
if "default('/', true)" not in catch_all["path"]:
    fail("the catch-all location must stay")
if cached["proxy_pass"] != catch_all["proxy_pass"]:
    fail("both locations must proxy to the same container")
print("[PASS] data-quality vhost has the cached location and keeps its catch-all")

include = cached["location_includes"]
if include != ["/etc/nginx/conf.d/data-quality-cache.inc"]:
    fail(f"unexpected include: {include}")
gen = next((t for t in tasks if t.get("name") == "Ensure nginx has the quality filter cache"), None)
if gen is None or gen.get("loop") != ["conf", "inc"]:
    fail("the role must generate data-quality-cache.conf and .inc")
conf = open("roles/la-compose/templates/data-quality-cache.conf.j2").read()
inc = open("roles/la-compose/templates/data-quality-cache.inc.j2").read()
zone = re.search(r"keys_zone=(\w+):", conf)
if not zone or f"proxy_cache {zone[1]};" not in inc:
    fail("the .inc must use the zone the .conf defines")
for directive in ("proxy_cache_valid 200", "proxy_cache_use_stale", "proxy_ignore_headers Vary"):
    if directive not in inc:
        fail(f"missing {directive}")
print("[PASS] the cache zone and the include fit together")
PY

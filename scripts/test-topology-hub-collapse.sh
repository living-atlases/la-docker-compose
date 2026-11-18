#!/usr/bin/env bash
# A data hub as la-toolkit really writes it, against every topology variant.
#
# The committed fixture base (topologies/base.lademo.yo-rc.json) carries MINIMAL
# hubs: lademohub has a hostname for its four front-ends and nothing else. A hub
# the toolkit writes is a CLONE of the portal instead — a hostname for every
# service, its own copies of the cluster-wide keys (LA_hostnames, LA_etc_hosts,
# the per-host alias and extra_hosts maps), and its four front-ends pointed at
# ONE vhost split by path. Because the fixtures do not have that shape, the
# topology matrix is blind to two failures that only the real .yo-rc triggers,
# and both of them killed a build 35 minutes in:
#
#   1. A variant with fewer hosts than the base drops a host that the hub's
#      extra keys still name -> "dropped host ... still referenced by: LA_hubs".
#   2. The path-split vhost is claimed by several hosts -> "vhost 'hub.l-a.site'
#      is claimed by more than one host", unless the placement declares it under
#      shared_vhost_splits.
#
# So this builds a toolkit-shaped hub on top of the sanitized base and applies
# every placement to it. No node, no yo, no hosts: seconds.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

GREEN='\033[0;32m'; RED='\033[0;31m'; RESET='\033[0m'
FAILURES=0
pass() { echo -e "${GREEN}[PASS]${RESET} $*"; }
fail() { echo -e "${RED}[FAIL]${RESET} $*"; FAILURES=$((FAILURES + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BASE="${TMP}/base-toolkit-hub.yo-rc.json"
python3 - "$BASE" <<'PY'
import json, sys
from collections import OrderedDict

doc = json.load(open("topologies/base.lademo.yo-rc.json"), object_pairs_hook=OrderedDict)
pv = doc["generator-living-atlas"]["promptValues"]
hubs = pv["LA_hubs"]

# Shape the first hub like the toolkit writes one: the portal's whole placement
# copied in, and the four front-ends on one vhost split by path across hosts.
hub = hubs[0]
for key, value in pv.items():
    if key.endswith("_hostname") and isinstance(value, str) and value.strip():
        hub.setdefault(key, value)
for key in ("LA_hostnames", "LA_server_ips", "LA_etc_hosts",
            "LA_nginx_docker_internal_aliases_by_host",
            "LA_docker_extra_hosts_by_host"):
    if key in pv:
        hub[key] = pv[key]
for fe, path, host in (("ala_hub", "/records", "la-mh-1"),
                       ("branding", "/", "la-mh-1"),
                       ("ala_bie", "/species", "la-mh-2"),
                       ("regions", "/regions", "la-mh-3")):
    hub["LA_%s_url" % fe] = "toolkithub.l-a.site"
    hub["LA_%s_path" % fe] = path
    hub["LA_%s_hostname" % fe] = host
hub["LA_pkg_name"] = "lademohub"

json.dump(doc, open(sys.argv[1], "w"), indent=2)
PY
[ -s "$BASE" ] || { echo "ERROR: could not build the toolkit-shaped base" >&2; exit 1; }

# The split vhost is this hub's, not the portal's, so every placement must be
# told the split is intentional for it, exactly as it is for hub.l-a.site.
for p in topologies/*.placement.json; do
  variant="$(basename "$p" .placement.json)"
  placement="${TMP}/${variant}.placement.json"
  python3 - "$p" "$placement" <<'PY'
import json, sys
from collections import OrderedDict
d = json.load(open(sys.argv[1]), object_pairs_hook=OrderedDict)
splits = list(d.get("shared_vhost_splits") or [])
if "toolkithub.l-a.site" not in splits:
    splits.append("toolkithub.l-a.site")
d["shared_vhost_splits"] = splits
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
  out="${TMP}/${variant}.yo-rc.json"
  log="$(python3 scripts/apply-topology.py apply --base "$BASE" \
           --placement "$placement" --out "$out" \
           --extra-host extra-host-1:10.77.0.9 2>&1)"
  if [ $? -ne 0 ]; then
    fail "${variant}: a toolkit-shaped hub does not apply — ${log}"
    continue
  fi
  # The variant must name no host it dropped, inside the hub or anywhere else.
  # cmd_apply has its own safety net for this; checking it here as well is what
  # makes the test fail loudly if that net is ever narrowed.
  left="$(python3 - "$BASE" "$out" <<'PY'
import json, sys


def hostnames(path):
    pv = json.load(open(path))["generator-living-atlas"]["promptValues"]
    return [h.strip() for h in pv["LA_hostnames"].split(",") if h.strip()]


kept = hostnames(sys.argv[2])
blob = json.dumps(json.load(open(sys.argv[2])))
print(" ".join(h for h in hostnames(sys.argv[1]) if h not in kept and h in blob))
PY
)"
  if [ -z "$left" ]; then
    pass "${variant}: toolkit-shaped hub applies and names no dropped host"
  else
    fail "${variant}: dropped host(s) survive in the variant: ${left}"
  fi
done

# And the split must still be REFUSED when the placement does not declare it:
# that check is what tells a real misplacement from a deliberate path split.
undeclared="${TMP}/undeclared.placement.json"
python3 - topologies/default-3host.placement.json "$undeclared" <<'PY'
import json, sys
from collections import OrderedDict
d = json.load(open(sys.argv[1]), object_pairs_hook=OrderedDict)
d.pop("shared_vhost_splits", None)
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
log="$(python3 scripts/apply-topology.py apply --base "$BASE" \
         --placement "$undeclared" --out "${TMP}/undeclared.yo-rc.json" 2>&1)"
status=$?
if [ "$status" -ne 0 ] && echo "$log" | grep -q "claimed by more than one host"; then
  pass "an undeclared cross-host split vhost is still refused"
else
  fail "an undeclared cross-host split vhost was accepted — ${log}"
fi

echo
if [ "$FAILURES" -gt 0 ]; then
  echo -e "${RED}${FAILURES} check(s) failed${RESET}"
  exit 1
fi
echo -e "${GREEN}All checks passed.${RESET}"

#!/usr/bin/env python3
"""Derive a .yo-rc.json for an alternative service->host layout (topology).

The generator (generator-living-atlas) treats the placement-derived dicts
(LA_docker_extra_hosts_by_host, LA_nginx_docker_internal_aliases_by_host,
LA_etc_hosts) as opaque la-toolkit variables: on --replay it re-uses them
verbatim and never recomputes them from the LA_<service>_hostname keys.
So moving a service between hosts requires rewriting ALL of these keys
coherently — that is exactly what this script does, from a small declarative
placement overlay (topologies/<name>.placement.json).

Subcommands:
  sanitize   Strip secrets from a real .yo-rc.json and rename hosts/IPs to
             the la-mh-* fixture convention, producing a committable base.
  apply      Apply a placement overlay to a base .yo-rc.json.
  proxy-map  Print the public vhost -> host/IP map a front proxy (Apache)
             needs for the given placement.

Placement overlay format (topologies/*.placement.json):
  {
    "description": "...",
    "hosts": ["host1", "host2"],          # logical slots, mapped by ORDER to
                                          # the base .yo-rc host list; fewer
                                          # slots than base hosts drops the
                                          # trailing base hosts
    "services": {"collectory": "host1", ...},
    "skip_services": ["spatial", ...]     # runtime SKIP_SERVICES for reduced
                                          # variants (consumed by Jenkinsfile,
                                          # not by this script)
  }

Sub-services (userdetails/apikey/cas_management -> cas; spatial_service/
geoserver/geonetwork -> spatial) default to their parent's slot and may not
be placed on a different host. Services sharing a public vhost (e.g.
auth.l-a.site) must land on the same host.
"""

import argparse
import json
import re
import sys
from collections import OrderedDict

GENERATOR_KEY = "generator-living-atlas"

# Sub-services must be co-located with their parent (mirrors
# roles/la-compose/vars/docker-services-desc.yaml).
SUBSERVICE_PARENT = {
    "userdetails": "cas",
    "apikey": "cas",
    "cas_management": "cas",
    "spatial_service": "spatial",
    "geoserver": "spatial",
    "geonetwork": "spatial",
}

# Placement bookkeeping keys that look like LA_<service>_hostname but are not
# individually placeable services.
NON_SERVICE_HOSTNAME_KEYS = {"docker_compose", "docker_common"}

# Secret-bearing .yo-rc keys (values replaced on sanitize).
SECRET_KEY_RE = re.compile(
    r"(password|_signing_key|_encryption_key|license_key|google_api_key|"
    r"maxmind_account_id|_ssh_key)",
    re.IGNORECASE,
)


def die(msg):
    sys.stderr.write("ERROR: %s\n" % msg)
    sys.exit(1)


def load_yorc(path):
    with open(path) as f:
        doc = json.load(f, object_pairs_hook=OrderedDict)
    if GENERATOR_KEY not in doc:
        die("%s: no '%s' section" % (path, GENERATOR_KEY))
    section = doc[GENERATOR_KEY]
    pv = section.get("promptValues", section)
    return doc, pv


def save_yorc(doc, path):
    with open(path, "w") as f:
        json.dump(doc, f, indent=2, ensure_ascii=False)
        f.write("\n")


def base_hosts(pv):
    """Ordered [(name, ip)] from LA_hostnames / LA_server_ips."""
    names = [h.strip() for h in str(pv.get("LA_hostnames", "")).split(",") if h.strip()]
    ips = [i.strip() for i in str(pv.get("LA_server_ips", "")).split(",") if i.strip()]
    if len(names) != len(ips):
        die("LA_hostnames (%d) and LA_server_ips (%d) length mismatch" % (len(names), len(ips)))
    return list(zip(names, ips))


def service_hostname_keys(pv):
    """{service: yo-rc key} for every LA_<service>_hostname key."""
    out = {}
    for k in pv:
        m = re.fullmatch(r"LA_(.+)_hostname", k)
        if m and m.group(1) not in NON_SERVICE_HOSTNAME_KEYS:
            out[m.group(1)] = k
    return out


def alias_union(pv):
    """All public vhost aliases across hosts, from the base aliases dict."""
    aliases = []
    for host_aliases in (pv.get("LA_nginx_docker_internal_aliases_by_host") or {}).values():
        for a in host_aliases:
            if a not in aliases:
                aliases.append(a)
    return aliases


def alias_owners(pv, services):
    """alias -> [services] via LA_<svc>_url == alias."""
    owners = {}
    for alias in alias_union(pv):
        svcs = [s for s in services if str(pv.get("LA_%s_url" % s, "")).strip() == alias]
        owners[alias] = svcs
    return owners


def resolve_placement(pv, placement):
    """Return (hosts, svc_slot) where hosts is [(name, ip)] for the variant
    (slot order) and svc_slot maps every enabled service -> slot index."""
    slots = placement.get("hosts")
    if not slots or not isinstance(slots, list):
        die("placement: 'hosts' must be a non-empty list of slot names")
    bhosts = base_hosts(pv)
    if len(slots) > len(bhosts):
        die("placement needs %d hosts but base .yo-rc only has %d" % (len(slots), len(bhosts)))
    hosts = bhosts[: len(slots)]
    slot_index = {slot: i for i, slot in enumerate(slots)}

    svc_keys = service_hostname_keys(pv)
    enabled = {s for s, k in svc_keys.items() if str(pv.get(k, "")).strip()}

    svc_slot = {}
    for svc, slot in (placement.get("services") or {}).items():
        if svc not in svc_keys:
            die("placement places unknown service '%s' (no LA_%s_hostname in base)" % (svc, svc))
        if svc not in enabled:
            die("placement places '%s' but it is disabled (empty hostname) in the base .yo-rc" % svc)
        if slot not in slot_index:
            die("service '%s' placed on unknown slot '%s'" % (svc, slot))
        svc_slot[svc] = slot_index[slot]

    # Sub-services default to (and must match) their parent's slot.
    for sub, parent in SUBSERVICE_PARENT.items():
        if sub not in enabled:
            continue
        if parent in svc_slot:
            if sub in svc_slot and svc_slot[sub] != svc_slot[parent]:
                die("sub-service '%s' must be co-located with its parent '%s'" % (sub, parent))
            svc_slot.setdefault(sub, svc_slot[parent])

    missing = sorted(enabled - set(svc_slot))
    if missing:
        die("placement does not cover enabled services: %s" % ", ".join(missing))
    return hosts, svc_slot


def compute_variant(pv, placement):
    """Return the dict of .yo-rc keys to overwrite for this placement."""
    hosts, svc_slot = resolve_placement(pv, placement)
    names = [n for n, _ in hosts]
    ip_of = dict(hosts)

    svc_keys = service_hostname_keys(pv)
    owners = alias_owners(pv, list(svc_slot))

    # Public vhost alias -> owning host name.
    alias_host = {}
    for alias, svcs in owners.items():
        if not svcs:
            die("cannot determine owning service of vhost '%s' (no LA_<svc>_url matches)" % alias)
        slots = {svc_slot[s] for s in svcs}
        if len(slots) > 1:
            die(
                "services sharing vhost '%s' (%s) are placed on different hosts — "
                "shared-domain services must be co-located" % (alias, ", ".join(svcs))
            )
        alias_host[alias] = names[slots.pop()]

    aliases_by_host = OrderedDict((n, []) for n in names)
    for alias in alias_union(pv):
        aliases_by_host[alias_host[alias]].append(alias)
    for n in names:
        aliases_by_host[n] = sorted(aliases_by_host[n])

    # External extra_hosts entries (name is neither a cluster host nor a
    # managed vhost alias, e.g. datos.gbif.es) are preserved on every host.
    bnames = {n for n, _ in base_hosts(pv)}
    managed = set(alias_union(pv))
    external = []
    for entries in (pv.get("LA_docker_extra_hosts_by_host") or {}).values():
        for e in entries:
            name = e.split(":", 1)[0]
            if name not in bnames and name not in managed and e not in external:
                external.append(e)

    extra_by_host = OrderedDict()
    for n in names:
        entries = ["%s:%s" % (alias, ip_of[alias_host[alias]]) for alias in alias_host if alias_host[alias] != n]
        entries += ["%s:%s" % (peer, ip_of[peer]) for peer in names if peer != n]
        entries += external
        extra_by_host[n] = sorted(set(entries))

    out = OrderedDict()
    out["LA_hostnames"] = ", ".join(names)
    out["LA_server_ips"] = ",".join(ip_of[n] for n in names)
    out["LA_docker_compose_hostname"] = ", ".join(names)
    for svc, slot in svc_slot.items():
        out[svc_keys[svc]] = names[slot]
    if "solrcloud" in svc_slot:
        out["LA_docker_solr_hosts"] = [names[svc_slot["solrcloud"]]]
    out["LA_nginx_docker_internal_aliases_by_host"] = aliases_by_host
    out["LA_docker_extra_hosts_by_host"] = extra_by_host
    if "LA_etc_hosts" in pv:
        out["LA_etc_hosts"] = "\n".join("      %s %s " % (ip_of[n], n) for n in names)
    return out, hosts, svc_slot, alias_host


def cmd_apply(args):
    doc, pv = load_yorc(args.base)
    with open(args.placement) as f:
        placement = json.load(f)
    dropped = [n for n, _ in base_hosts(pv)][len(placement["hosts"]):]
    overrides, _, _, _ = compute_variant(pv, placement)
    pv.update(overrides)

    # Safety net: a dropped base host must not survive anywhere in the result.
    blob = json.dumps(pv)
    for name in dropped:
        if name in blob:
            offenders = [k for k, v in pv.items() if name in json.dumps(v)]
            die("dropped host '%s' still referenced by: %s" % (name, ", ".join(offenders)))

    save_yorc(doc, args.out)
    print("wrote %s (%d hosts, %d keys overridden)" % (args.out, len(placement["hosts"]), len(overrides)))


def cmd_proxy_map(args):
    _, pv = load_yorc(args.base)
    with open(args.placement) as f:
        placement = json.load(f)
    _, hosts, svc_slot, alias_host = compute_variant(pv, placement)
    ip_of = dict(hosts)
    print("# public vhost -> VM (for the external front proxy)")
    for alias in sorted(alias_host):
        h = alias_host[alias]
        print("%-40s %s (%s)" % (alias, h, ip_of[h]))
    if "branding" in svc_slot:
        n = hosts[svc_slot["branding"]][0]
        print("%-40s %s (%s)  # root domain (branding/home)" % ("<root domain>", n, ip_of[n]))


def cmd_sanitize(args):
    doc, pv = load_yorc(args.base)
    hosts = base_hosts(pv)
    host_map = {name: "la-mh-%d" % (i + 1) for i, (name, _) in enumerate(hosts)}
    ip_map = {ip: "10.77.0.%d" % (i + 1) for i, (_, ip) in enumerate(hosts)}

    def rewrite(value):
        if isinstance(value, str):
            for old, new in list(host_map.items()) + list(ip_map.items()):
                value = value.replace(old, new)
            return value
        if isinstance(value, list):
            return [rewrite(v) for v in value]
        if isinstance(value, dict):
            return OrderedDict((rewrite(k), rewrite(v)) for k, v in value.items())
        return value

    for k in list(pv):
        if SECRET_KEY_RE.search(k) and isinstance(pv[k], str) and pv[k].strip():
            pv[k] = "fixture-%s" % k.lower().replace("la_variable_", "").replace("_", "-")
        else:
            pv[k] = rewrite(pv[k])

    save_yorc(doc, args.out)
    print("wrote %s (%d hosts renamed to la-mh-*, secrets replaced)" % (args.out, len(hosts)))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    ap = sub.add_parser("apply", help="apply a placement overlay to a base .yo-rc.json")
    ap.add_argument("--base", required=True)
    ap.add_argument("--placement", required=True)
    ap.add_argument("--out", required=True)
    ap.set_defaults(func=cmd_apply)

    pm = sub.add_parser("proxy-map", help="print public vhost -> VM map for a placement")
    pm.add_argument("--base", required=True)
    pm.add_argument("--placement", required=True)
    pm.set_defaults(func=cmd_proxy_map)

    sa = sub.add_parser("sanitize", help="strip secrets + rename hosts to la-mh-* fixture names")
    sa.add_argument("--base", required=True)
    sa.add_argument("--out", required=True)
    sa.set_defaults(func=cmd_sanitize)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()

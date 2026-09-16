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
    "hubs": {"lademohub": {"ala_bie": "host2"}},  # OPTIONAL per-data-hub override;
                                          # any front-end left out follows the
                                          # PORTAL's slot for the same service
    "skip_services": ["spatial", ...]     # runtime SKIP_SERVICES for reduced
                                          # variants (consumed by Jenkinsfile,
                                          # not by this script)
  }

Data hubs (LA_hubs) are placed per front-end, exactly like the portal's services:
a hub may be SPREAD across hosts (records on one, species and regions on another).
Their public vhosts join LA_nginx_docker_internal_aliases_by_host and the cross-host
extra_hosts map, so a hub is visible to nginx and to validate-topology's duplicate
vhost check.

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

# A data hub's front-ends, named after the portal service each one mirrors. Each is
# optional per hub: a records-only hub carries LA_ala_hub_hostname and nothing else.
HUB_FRONTENDS = ("ala_hub", "ala_bie", "regions", "branding")

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


def alias_union(pv, rename=None):
    """The PORTAL's public vhost aliases across hosts, from the base aliases dict.

    From the base .yo-rc's LA_nginx_docker_internal_aliases_by_host snapshot, NOT
    recomputed from every enabled service's LA_<svc>_url: that snapshot is the
    curated set of names that actually get an nginx vhost (it deliberately excludes
    datastores and other internal-only hostnames that also happen to carry a
    LA_<svc>_url). rename ({old_alias: new_alias}, from a placement's
    "shared_hostname" override) substitutes an alias that a service was moved
    away from with the one it now shares, so the alias SET stays in step with the
    LOCAL, already-patched copy of pv compute_variant builds — without it, a
    renamed service's old alias would be orphaned (alias_owners would find no
    owner and die).

    Data hub vhosts are excluded and resolved separately (hub_vhosts): they are owned
    by an LA_hubs entry, not by a top-level LA_<svc>_url, so alias_owners could never
    find their owner and would die.
    """
    hubs = set(hub_vhosts(pv))
    rename = rename or {}
    aliases = []
    for host_aliases in (pv.get("LA_nginx_docker_internal_aliases_by_host") or {}).values():
        for a in host_aliases:
            a = rename.get(a, a)
            if a not in aliases and a not in hubs:
                aliases.append(a)
    return aliases


def alias_owners(pv, services, rename=None):
    """alias -> [services] via LA_<svc>_url == alias."""
    owners = {}
    for alias in alias_union(pv, rename):
        svcs = [s for s in services if str(pv.get("LA_%s_url" % s, "")).strip() == alias]
        owners[alias] = svcs
    return owners


def hub_entries(pv):
    """[(index, pkg, {frontend: hostname})] for every declared data hub."""
    out = []
    for i, hub in enumerate(pv.get("LA_hubs") or []):
        placed = {}
        for fe in HUB_FRONTENDS:
            host = str(hub.get("LA_%s_hostname" % fe, "") or "").strip()
            if host:
                placed[fe] = host
        out.append((i, str(hub.get("LA_pkg_name", "") or "hub%d" % i), placed))
    return out


def hub_vhosts(pv):
    """{alias: [(hub index, frontend), ...]} for every data hub public vhost.

    A list, not a single tuple: a hub may point MORE THAN ONE front-end at the
    same alias (e.g. LA_ala_hub_url == LA_ala_bie_url == LA_regions_url ==
    "hub.l-a.site", a hostname split by PATH across hosts). A plain dict
    assignment here would silently keep only the last front-end processed and
    drop the others from every alias-derived computation below — the exact bug
    a hub with this shape hit (issue: cross-host path-split vhost support).
    """
    out = {}
    for i, _pkg, placed in hub_entries(pv):
        hub = pv["LA_hubs"][i]
        for fe in placed:
            alias = str(hub.get("LA_%s_url" % fe, "") or "").strip()
            if alias:
                out.setdefault(alias, []).append((i, fe))
    return out


def resolve_hub_placement(pv, placement, slot_index, svc_slot):
    """{hub index: {frontend: slot}}.

    Default: a hub front-end follows the PORTAL's slot for the same service. That
    reproduces the base layout on a full-size variant (the toolkit places a hub
    alongside the portal's copy) and collapses safely on a reduced one, where the
    hub's own base host may no longer exist. A placement can override any single
    front-end through its optional "hubs" key.
    """
    overrides = placement.get("hubs") or {}
    out = {}
    for i, pkg, placed in hub_entries(pv):
        fe_slot = {}
        for fe in placed:
            slot = (overrides.get(pkg) or {}).get(fe)
            if slot is not None:
                if slot not in slot_index:
                    die("hub '%s' places '%s' on unknown slot '%s'" % (pkg, fe, slot))
                fe_slot[fe] = slot_index[slot]
            elif fe in svc_slot:
                fe_slot[fe] = svc_slot[fe]
            else:
                die(
                    "hub '%s' declares '%s' but the portal does not run it, so there is "
                    "no slot to follow — place it explicitly under the placement's "
                    '"hubs" key' % (pkg, fe)
                )
        out[i] = fe_slot
    return out


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

    # Optional cross-host PATH split: placement["shared_hostname"] =
    # {"<hostname>": {"<service>": "<path>", ...}} points the listed portal
    # services' public vhost at one shared hostname (each on its own path)
    # instead of each service's own individual one. Applied to a LOCAL copy of
    # pv, and BEFORE any alias-derived computation below, so alias_owners /
    # alias_union / alias_host all see the shared hostname from the start —
    # the base .yo-rc itself (shared by every topology variant) is never
    # touched, so this is opt-in per placement only.
    shared_hostname = placement.get("shared_hostname") or {}
    url_path_overrides = OrderedDict()
    rename = {}
    if shared_hostname:
        pv = dict(pv)
        for hostname, svc_paths in shared_hostname.items():
            for svc, path in svc_paths.items():
                old_alias = str(pv.get("LA_%s_url" % svc, "") or "").strip()
                if old_alias and old_alias != hostname:
                    rename[old_alias] = hostname
                for key, value in (
                    ("LA_%s_url" % svc, hostname),
                    ("LA_%s_path" % svc, path),
                ):
                    pv[key] = value
                    url_path_overrides[key] = value
                subdomain_key = "LA_%s_uses_subdomain" % svc
                if subdomain_key in pv:
                    pv[subdomain_key] = False
                    url_path_overrides[subdomain_key] = False

    # Aliases explicitly opted into a cross-host PATH split (one hostname served
    # by more than one physical host, each owning different paths under it —
    # see roles/la-compose's nginx_shared_vhost_topology / cross-host stub
    # proxying, which is what actually serves the paths a given host does not
    # own). Anything NOT listed here stays a hard error below: an UNDECLARED
    # duplicate is almost always a real placement bug (services that are
    # supposed to share a domain must be co-located), and this predicate is the
    # only thing standing between that and the external proxy silently routing
    # a whole hostname's traffic to just one of its owners.
    splits = set(placement.get("shared_vhost_splits") or []) | set(shared_hostname)

    svc_keys = service_hostname_keys(pv)
    owners = alias_owners(pv, list(svc_slot), rename)

    # Public vhost alias -> owning host name(s). Normally exactly one; a
    # declared split may legitimately resolve to more than one.
    alias_host = {}
    for alias, svcs in owners.items():
        if not svcs:
            die("cannot determine owning service of vhost '%s' (no LA_<svc>_url matches)" % alias)
        slots = {svc_slot[s] for s in svcs}
        if len(slots) > 1 and alias not in splits:
            die(
                "services sharing vhost '%s' (%s) are placed on different hosts — "
                "shared-domain services must be co-located (or declare '%s' under "
                "placement.shared_vhost_splits if the split is intentional)" % (alias, ", ".join(svcs), alias)
            )
        alias_host[alias] = sorted({names[s] for s in slots})

    # Data hubs: each front-end gets its own slot, so a hub may be SPREAD across
    # hosts. Its vhosts then join alias_host like any other, which is what puts them
    # in the per-host alias list and in every OTHER host's extra_hosts. Several
    # front-ends of the SAME hub (or a hub and the portal) may target the same
    # alias too — same split rule applies.
    slot_index = {slot: i for i, slot in enumerate(placement.get("hosts") or [])}
    hub_slots = resolve_hub_placement(pv, placement, slot_index, svc_slot)
    for alias, members in hub_vhosts(pv).items():
        owner_hosts = {names[hub_slots[i][fe]] for i, fe in members}
        combined = set(alias_host.get(alias, [])) | owner_hosts
        if len(combined) > 1 and alias not in splits:
            die(
                "vhost '%s' is claimed by more than one host (%s) — an external proxy "
                "can only route a subdomain to one VM unless it is deliberately split "
                "(declare '%s' under placement.shared_vhost_splits if so)"
                % (alias, ", ".join(sorted(combined)), alias)
            )
        alias_host[alias] = sorted(combined)

    aliases_by_host = OrderedDict((n, []) for n in names)
    for alias in list(alias_union(pv, rename)) + list(hub_vhosts(pv)):
        for h in alias_host[alias]:
            if alias not in aliases_by_host[h]:
                aliases_by_host[h].append(alias)
    for n in names:
        aliases_by_host[n] = sorted(aliases_by_host[n])

    # External extra_hosts entries (name is neither a cluster host nor a
    # managed vhost alias, e.g. datos.gbif.es) are preserved on every host.
    bnames = {n for n, _ in base_hosts(pv)}
    managed = set(alias_union(pv, rename)) | set(hub_vhosts(pv))
    external = []
    for entries in (pv.get("LA_docker_extra_hosts_by_host") or {}).values():
        for e in entries:
            name = e.split(":", 1)[0]
            if name not in bnames and name not in managed and e not in external:
                external.append(e)

    extra_by_host = OrderedDict()
    for n in names:
        # A split alias has no single owning IP, so no per-alias entry is added for
        # it — the peer cluster-hostname entries below already give every host a
        # way to reach every sibling; that is what the cross-host stub proxy
        # (la-compose) actually resolves through, not a hostname:IP entry keyed by
        # the public vhost alias itself.
        entries = [
            "%s:%s" % (alias, ip_of[owners_[0]])
            for alias, owners_ in alias_host.items()
            if len(owners_) == 1 and owners_[0] != n
        ]
        entries += ["%s:%s" % (peer, ip_of[peer]) for peer in names if peer != n]
        entries += external
        extra_by_host[n] = sorted(set(entries))

    out = OrderedDict()
    out["LA_hostnames"] = ", ".join(names)
    out["LA_server_ips"] = ",".join(ip_of[n] for n in names)
    out["LA_docker_compose_hostname"] = ", ".join(names)
    out.update(url_path_overrides)
    for svc, slot in svc_slot.items():
        out[svc_keys[svc]] = names[slot]
    if "solrcloud" in svc_slot:
        out["LA_docker_solr_hosts"] = [names[svc_slot["solrcloud"]]]
    if hub_slots:
        rehomed = []
        for i, hub in enumerate(pv.get("LA_hubs") or []):
            entry = OrderedDict(hub)
            for fe, slot in (hub_slots.get(i) or {}).items():
                entry["LA_%s_hostname" % fe] = names[slot]
            rehomed.append(entry)
        out["LA_hubs"] = rehomed
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
        hs = alias_host[alias]
        if len(hs) == 1:
            print("%-40s %s (%s)" % (alias, hs[0], ip_of[hs[0]]))
        else:
            where = ", ".join("%s (%s)" % (h, ip_of[h]) for h in hs)
            print("%-40s SPLIT across: %s — front proxy must route this hostname to "
                  "ANY one of them; each hairpin-proxies the paths it does not own"
                  % (alias, where))
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

#!/usr/bin/env python3
"""Freeze the URLs our config renders to, and fail when they drift.

The problem
-----------
`validate-config-gen.sh` proves config generation RUNS. Nothing proved it still points where
it should, and that gap produced the same class of incident repeatedly: four services proxying
to 127.0.0.1, biocache aimed at a ZooKeeper left over from the swarm era, data-quality's
userDetails.url still on an upstream auth server. Every one of them was a URL that changed, or
failed to change, and nobody saw it.

Checking it by hand works and decays the moment a template changes. So: do it once, freeze the
answer, and diff against the frozen answer from then on.

What is frozen
--------------
`file -> key -> URL`, for URL-valued keys only. That is deliberate and does two things at
once: it captures exactly the values that have historically gone wrong, and it means the
committed file cannot contain a secret, because a password is not a URL. Secret-shaped keys
are dropped on top of that, and credentials and query strings are stripped from every URL
that is kept, so the guarantee does not depend on anyone reviewing the diff.

Usage
    scripts/config-baseline.py extract   --from <rendered-dir> [--out config-baseline.json]
    scripts/config-baseline.py check     --from <rendered-dir> [--baseline config-baseline.json]
    scripts/config-baseline.py ala-hosts --from <rendered-dir>
    scripts/config-baseline.py ala-hosts --self-test

`ala-hosts` is the other question. The baseline answers "did anything change"; a URL that was
already wrong when the baseline was frozen passes it forever. spatial-hub rendered
lists.urlUi = https://lists.ala.org.au, ALA's own lists UI, for exactly that reason. So this
rejects any ALA service or test host in the rendered config that ala_upstream_fallbacks does
not declare, using the same host table as the live /alaAdmin/viewConfig audit
(e2e/cypress/support/ala-hosts.json).

<rendered-dir> comes from scripts/render-properties-offline.sh. Deliberately NOT a live
/data: that tree accumulates hand-kept variants (.last, .es, .tests) beside the real files,
and freezing one of those would pin somebody's old experiment as the expected state.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_BASELINE = HERE.parent / "config-baseline.json"
ALA_HOSTS = HERE.parent / "e2e" / "cypress" / "support" / "ala-hosts.json"
FALLBACKS = HERE.parent / "roles" / "la-compose" / "defaults" / "main.yml"


def _load_compare_module():
    """Reuse the parsing and redaction from compare-rendered-config.py.

    Imported rather than reimplemented on purpose: two copies of "what counts as a secret"
    is one copy too many, and the copy that drifts is the one that leaks.
    """
    path = HERE / "compare-rendered-config.py"
    spec = importlib.util.spec_from_file_location("compare_rendered_config", path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"cannot load {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


C = _load_compare_module()


def extract(rendered: Path) -> dict:
    files: dict[str, dict[str, str]] = {}
    for path in sorted(rendered.iterdir()):
        if not path.is_file() or path.suffix not in (".properties", ".yml", ".yaml"):
            continue
        urls: dict[str, str] = {}
        for key, value in C.load(path).items():
            if C.SECRET_SHAPED.search(key):
                continue
            if C.url_host(value):
                urls[key] = C.safe_url(value)
        if urls:
            files[path.name] = dict(sorted(urls.items()))
    return {
        "_comment": (
            "Frozen URLs the config renders to. Regenerate deliberately with "
            "scripts/config-baseline.py extract when a change is intended; an unexplained "
            "diff here is drift. URL-valued non-secret keys only, credentials and query "
            "strings stripped -- see the script for why."
        ),
        "files": files,
    }


def compare(baseline: dict, current: dict) -> list[str]:
    problems: list[str] = []
    b_files, c_files = baseline.get("files", {}), current.get("files", {})

    for name in sorted(set(b_files) - set(c_files)):
        problems.append(f"{name}: file is in the baseline but was not rendered")
    for name in sorted(set(c_files) - set(b_files)):
        problems.append(f"{name}: rendered but absent from the baseline")

    for name in sorted(set(b_files) & set(c_files)):
        b, c = b_files[name], c_files[name]
        for key in sorted(set(b) - set(c)):
            problems.append(f"{name}: {key} no longer rendered (was {b[key]})")
        for key in sorted(set(c) - set(b)):
            problems.append(f"{name}: {key} is new = {c[key]}")
        for key in sorted(set(b) & set(c)):
            if b[key] != c[key]:
                problems.append(f"{name}: {key}\n    was {b[key]}\n    now {c[key]}")
    return problems


def load_fallbacks(path: Path = FALLBACKS) -> list[dict]:
    """ala_upstream_fallbacks from the la-compose role defaults: the declared ALA dependencies."""
    import yaml

    return (yaml.safe_load(path.read_text()) or {}).get("ala_upstream_fallbacks") or []


def audit_ala_hosts(rendered: Path, table: dict, fallbacks: list[dict]
                    ) -> tuple[list[str], list[str]]:
    """(findings, informational) for every ALA-family URL in a rendered tree.

    Same classification as auditEffectiveConfig() in e2e/cypress/support/config-audit.ts:
    a declared fallback (host, optionally scoped to one key) is informational; an undeclared
    ALA test/staging host or ALA service host is a finding; any other ALA-family host is a
    documentation/content link and informational. Secret-shaped keys are audited too -- the
    gbif.es apikey defect was on one -- and every reported URL goes through safe_url.
    """
    family = re.compile(table["familyPattern"], re.I)
    nonprod = re.compile(table["nonProdPattern"], re.I)
    services = table["serviceHosts"]
    inert = tuple(table.get("inertKeyPrefixes", []))
    findings: list[str] = []
    info: list[str] = []
    for path in sorted(rendered.iterdir()):
        if not path.is_file() or path.suffix not in (".properties", ".yml", ".yaml"):
            continue
        for key, value in sorted(C.load(path).items()):
            if key.startswith(inert):  # environments.test.*: inert per-environment defaults
                continue
            host = C.url_host(value)
            if not host or not family.search(host):
                continue
            line = f"{path.name}: {key} = {C.safe_url(value)}"
            fb = next((f for f in fallbacks
                       if str(f.get("host", "")).lower() == host
                       and (not f.get("property") or f["property"] == key)), None)
            if fb:
                info.append(f"{line}   [declared fallback]")
            elif nonprod.search(host):
                findings.append(f"{line}   [ALA non-production infrastructure]")
            elif host in services:
                findings.append(f"{line}   [ALA's {services[host]}, which we deploy ourselves]")
            else:
                info.append(f"{line}   [ALA documentation/content link]")
    return findings, info


def ala_hosts_self_test() -> int:
    """Plant the known-bad and known-acceptable rows and check each lands where it should."""
    table = json.loads(ALA_HOSTS.read_text())
    fallbacks = [{"host": "spatial.ala.org.au", "property": "openstreetmap.tileUrl"}]
    with tempfile.TemporaryDirectory() as d:
        Path(d, "spatial-hub-config.yml").write_text(
            "lists:\n"
            "  url: https://lists.example.org\n"
            "  urlUi: https://lists.ala.org.au\n"           # the spatial-hub defect
            "openstreetmap:\n"
            "  tileUrl: https://spatial.ala.org.au/osm/{z}/{x}/{y}.png\n"  # declared
            "spatial:\n"
            "  url: https://spatial.ala.org.au\n"            # same host, undeclared key
            "environments:\n"
            "  test:\n"
            "    grails:\n"
            "      serverURL: https://lists-test.ala.org.au\n"  # inert per-environment block
        )
        Path(d, "collectory-config.properties").write_text(
            "security.apikey.auth.serviceUrl=https://auth-test.ala.org.au/apikey/\n"
            "skin.helpUrl=https://support.ala.org.au/help\n"
            "gbif.api=https://api.gbif.org/v1\n"
        )
        findings, info = audit_ala_hosts(Path(d), table, fallbacks)
    expect_findings = ["lists.urlUi", "spatial.url", "security.apikey.auth.serviceUrl"]
    expect_info = ["openstreetmap.tileUrl", "skin.helpUrl"]
    errors = []
    for key in expect_findings:
        if not any(f": {key} = " in f for f in findings):
            errors.append(f"{key} should be a finding")
    for key in expect_info:
        if not any(f": {key} = " in f for f in info):
            errors.append(f"{key} should be informational")
    if any("environments." in x for x in findings + info):
        errors.append("environments.* blocks are inert and should be ignored")
    if any("gbif.api" in x for x in findings + info):
        errors.append("gbif.api is a third party and should be ignored")
    if len(findings) != len(expect_findings):
        errors.append(f"expected {len(expect_findings)} findings, got {len(findings)}")
    for e in errors:
        print(f"SELF-TEST FAIL: {e}", file=sys.stderr)
    if not errors:
        print(f"ala-hosts self-test OK: {len(findings)} findings, {len(info)} informational")
    return 1 if errors else 0


def run_ala_hosts(src: Path) -> int:
    findings, info = audit_ala_hosts(src, json.loads(ALA_HOSTS.read_text()), load_fallbacks())
    if info:
        print(f"{len(info)} accepted ALA reference(s):")
        for i in info:
            print(f"  {i}")
    if not findings:
        print("ala-hosts OK: no undeclared ALA service or test hosts in the rendered config")
        return 0
    print(f"\nala-hosts: {len(findings)} undeclared ALA reference(s) in the rendered config\n",
          file=sys.stderr)
    for f in findings:
        print(f"  {f}", file=sys.stderr)
    print(
        "\nEach is either a bug to fix in the ala-install role / la-compose template (usually a\n"
        "`| default('https://...ala.org.au')` for a variable the inventory never sets), or a\n"
        "deliberate dependency to declare in ala_upstream_fallbacks with a reason\n"
        "(roles/la-compose/defaults/main.yml).",
        file=sys.stderr,
    )
    return 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    e = sub.add_parser("extract", help="write the baseline from a rendered tree")
    e.add_argument("--from", dest="src", required=True, type=Path)
    e.add_argument("--out", type=Path, default=DEFAULT_BASELINE)

    c = sub.add_parser("check", help="fail if a rendered tree has drifted from the baseline")
    c.add_argument("--from", dest="src", required=True, type=Path)
    c.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE)

    a = sub.add_parser("ala-hosts",
                       help="fail on undeclared ALA service/test hosts in a rendered tree")
    src_or_test = a.add_mutually_exclusive_group(required=True)
    src_or_test.add_argument("--from", dest="src", type=Path)
    src_or_test.add_argument("--self-test", action="store_true")

    args = ap.parse_args()
    if args.cmd == "ala-hosts" and args.self_test:
        return ala_hosts_self_test()
    if not args.src.is_dir():
        print(f"ERROR: not a directory: {args.src}", file=sys.stderr)
        return 1

    if args.cmd == "ala-hosts":
        return run_ala_hosts(args.src)

    current = extract(args.src)
    n_keys = sum(len(v) for v in current["files"].values())

    if args.cmd == "extract":
        args.out.write_text(json.dumps(current, indent=2, sort_keys=False) + "\n")
        print(f"baseline written to {args.out}: "
              f"{len(current['files'])} files, {n_keys} URL keys")
        return 0

    if not args.baseline.is_file():
        print(f"ERROR: no baseline at {args.baseline}. Create one with:\n"
              f"  scripts/config-baseline.py extract --from {args.src}", file=sys.stderr)
        return 1

    problems = compare(json.loads(args.baseline.read_text()), current)
    if not problems:
        print(f"config baseline OK: {len(current['files'])} files, {n_keys} URL keys unchanged")
        return 0

    print(f"config baseline DRIFT: {len(problems)} difference(s)\n", file=sys.stderr)
    for p in problems:
        print(f"  {p}", file=sys.stderr)
    print(
        "\nIf every difference above is intended, refresh the baseline in the same commit:\n"
        f"  scripts/config-baseline.py extract --from {args.src}",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())

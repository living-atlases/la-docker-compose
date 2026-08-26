#!/usr/bin/env python3
"""Compare two rendered config trees and emit a report that is safe to read.

Both trees come from scripts/render-properties-offline.sh, so the same machinery produced
both sides and any difference is a difference in the inputs.

Why this is not a diff
---------------------
A rendered config holds passwords, API keys and internal host names. Diffing two trees and
reading the output would put all of that on screen, in a terminal transcript and possibly in
a CI log. So there is no raw-output mode here, not even behind a flag: every value passes
through classify() before it can be printed, and the reference side is redacted more
aggressively than ours.

Classification, applied to every value:
  * key looks secret-shaped (pass|secret|key|token|credential|salt|private) -> <redacted>,
    unconditionally, no exceptions, on either side;
  * our side, otherwise -> printed (it is our own deployment);
  * reference side -> printed only when the value is a URL on a public, well-known domain;
    everything else becomes a type token (<bool>, <int>, <empty>, <url:private>, <string>).

What it reports, per file:
  1. keys the reference has that we do not, and the reverse
  2. keys on both sides whose value TYPE differs
  3. URL-valued keys on our side, and whether they point outside our own deployment
  4. case-variant duplicate keys whose values disagree

(4) is information, not a defect list. Duplicate keys differing only in case are endemic to
upstream's config and are not in scope to fix; they are surfaced because when the two values
disagree, one of them is what the application actually reads, and that has bitten before.

Usage:
    scripts/compare-rendered-config.py --ours <dir> --reference <dir> [--out <file>]
    scripts/compare-rendered-config.py --ours <dir>          # our side alone (no comparison)
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

SECRET_SHAPED = re.compile(r"pass|secret|key|token|credential|salt|private", re.I)

# Domains whose URLs may be printed raw from the reference side: public, documented service
# endpoints. Anything else -- internal names, IPs, private hosts -- becomes <url:private>.
PUBLIC_DOMAINS = re.compile(
    r"(^|\.)(ala\.org\.au|csiro\.au|gbif\.org|gbif\.es|doi\.org|orcid\.org|"
    r"github\.com|openstreetmap\.org|inaturalist\.org)$",
    re.I,
)

URL_RE = re.compile(r"^https?://", re.I)


def value_type(value: str) -> str:
    v = (value or "").strip()
    if v == "":
        return "<empty>"
    if v.lower() in ("true", "false", "yes", "no", "on", "off"):
        return "<bool>"
    if re.fullmatch(r"-?\d+", v):
        return "<int>"
    if URL_RE.match(v):
        return "<url>"
    return "<string>"


def url_host(value: str) -> str | None:
    v = (value or "").strip()
    if not URL_RE.match(v):
        return None
    from urllib.parse import urlparse

    try:
        return (urlparse(v).hostname or "").lower() or None
    except ValueError:
        return None


def safe_url(value: str) -> str:
    """scheme + host + path. Credentials and query strings are dropped, always."""
    from urllib.parse import urlparse, urlunparse

    try:
        u = urlparse(value.strip())
        netloc = u.hostname or ""
        if u.port:
            netloc += f":{u.port}"
        return urlunparse((u.scheme, netloc, u.path, "", "", ""))
    except ValueError:
        return "<unparseable-url>"


def classify(key: str, value: str, ours: bool) -> str:
    if SECRET_SHAPED.search(key):
        return "<redacted>"
    host = url_host(value)
    if ours:
        return safe_url(value) if host else (value.strip() or "<empty>")
    # Reference side: URLs on public domains only, everything else reduced to its type.
    if host and PUBLIC_DOMAINS.search(host):
        return safe_url(value)
    if host:
        return "<url:private>"
    return value_type(value)


def parse_properties(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith("!"):
            continue
        if "=" not in line:
            continue
        k, _, v = line.partition("=")
        k = k.strip()
        if k:
            out[k] = v.strip()
    return out


def flatten_yaml(node, prefix: str, out: dict[str, str]) -> None:
    if isinstance(node, dict):
        for k, v in node.items():
            flatten_yaml(v, f"{prefix}.{k}" if prefix else str(k), out)
    elif isinstance(node, list):
        # Index the entries so a reordering is visible rather than silently collapsing.
        for i, v in enumerate(node):
            flatten_yaml(v, f"{prefix}[{i}]", out)
    else:
        out[prefix] = "" if node is None else str(node)


def parse_yaml(text: str) -> dict[str, str]:
    try:
        import yaml
    except ImportError:  # pragma: no cover
        return {}
    out: dict[str, str] = {}
    try:
        # A rendered config can hold several documents; keep them all.
        for doc in yaml.safe_load_all(text):
            if doc is not None:
                flatten_yaml(doc, "", out)
    except yaml.YAMLError:
        return {}
    return out


def load(path: Path) -> dict[str, str]:
    text = path.read_text(errors="replace")
    if path.suffix in (".yml", ".yaml"):
        parsed = parse_yaml(text)
        # Some ala-install "yml" configs are really properties files. If YAML gives nothing
        # useful, fall back rather than reporting an empty file as "no keys".
        return parsed if parsed else parse_properties(text)
    return parse_properties(text)


def config_files(root: Path) -> dict[str, Path]:
    return {
        p.name: p
        for p in sorted(root.iterdir())
        if p.is_file() and p.suffix in (".properties", ".yml", ".yaml")
    }


def case_variant_conflicts(props: dict[str, str]) -> list[tuple[list[str], list[str]]]:
    groups: dict[str, list[str]] = {}
    for k in props:
        groups.setdefault(k.lower(), []).append(k)
    conflicts = []
    for _, keys in sorted(groups.items()):
        if len(keys) < 2:
            continue
        values = {props[k].strip() for k in keys}
        if len(values) > 1:
            conflicts.append((sorted(keys), [props[k].strip() for k in sorted(keys)]))
    return conflicts


def report(ours_dir: Path, ref_dir: Path | None, own_hosts: set[str]) -> list[str]:
    lines: list[str] = []
    ours_files = config_files(ours_dir)
    ref_files = config_files(ref_dir) if ref_dir else {}

    if ref_dir:
        only_ours = sorted(set(ours_files) - set(ref_files))
        only_ref = sorted(set(ref_files) - set(ours_files))
        if only_ours or only_ref:
            lines.append("## Files")
            for f in only_ours:
                lines.append(f"  only ours:     {f}")
            for f in only_ref:
                lines.append(f"  only reference: {f}")
            lines.append("")

    for name in sorted(ours_files):
        ours = load(ours_files[name])
        ref = load(ref_files[name]) if name in ref_files else None
        lines.append(f"## {name}  ({len(ours)} keys ours"
                     + (f", {len(ref)} reference)" if ref is not None else ", no reference)"))

        if ref is not None:
            missing = sorted(set(ref) - set(ours))
            extra = sorted(set(ours) - set(ref))
            if missing:
                lines.append(f"  keys the reference sets and we do not ({len(missing)}):")
                for k in missing:
                    lines.append(f"    {k} = {classify(k, ref[k], ours=False)}")
            if extra:
                lines.append(f"  keys we set and the reference does not ({len(extra)}):")
                for k in extra:
                    lines.append(f"    {k} = {classify(k, ours[k], ours=True)}")

            type_diffs = [
                k for k in sorted(set(ours) & set(ref))
                if value_type(ours[k]) != value_type(ref[k])
            ]
            if type_diffs:
                lines.append(f"  keys whose value TYPE differs ({len(type_diffs)}):")
                for k in type_diffs:
                    lines.append(
                        f"    {k}: ours {value_type(ours[k])} = "
                        f"{classify(k, ours[k], ours=True)} | "
                        f"reference {value_type(ref[k])}"
                    )

        foreign = []
        for k in sorted(ours):
            h = url_host(ours[k])
            if h and h not in own_hosts:
                foreign.append((k, h, classify(k, ours[k], ours=True)))
        if foreign:
            lines.append(f"  our URL-valued keys pointing outside this deployment ({len(foreign)}):")
            for k, h, v in foreign:
                lines.append(f"    {k} = {v}")

        conflicts = case_variant_conflicts(ours)
        if conflicts:
            lines.append(f"  case-variant keys whose values disagree ({len(conflicts)}) [information only]:")
            for keys, values in conflicts:
                for k, v in zip(keys, values):
                    lines.append(f"    {k} = {classify(k, v, ours=True)}")
        lines.append("")

    return lines


def self_test() -> int:
    """Prove the redaction gate holds, by running the report over planted secrets.

    This is the only part of the pipeline whose failure is silent and expensive: a leak does
    not raise, it just prints. So the check cannot be a one-off run by whoever wrote it -- it
    lives here, takes no fixtures, and can be re-run whenever the classifier is touched.
    """
    import tempfile

    reference = """\
db.password=SuperSecret123
security.apiKey=AKIAZZZLEAKME
jwt.signing.secret=shhh-do-not-print
internal.db.url=https://mysql-prod-01.internal.example.net:3306/db
admin.contact=someone@internal.example.net
biocache.baseUrl=https://biocache.ala.org.au/ws
url.with.creds=https://bob:hunter2@lists.ala.org.au/ws?apiKey=LEAKTHISTOO
some.flag=true
some.count=42
some.name=InternalCodeName
empty.thing=
"""
    ours = """\
db.password=our-own-password
security.apiKey=our-own-key
biocache.baseUrl=https://records-ws.example.test/ws
foreign.thing=https://pdfgen.ala.org.au/
some.flag=false
some.count=notanumber
Some.Count=41
extra.only.ours=https://collections.example.test
"""
    must_not_appear = [
        "SuperSecret123", "AKIAZZZLEAKME", "shhh-do-not-print",   # secret-shaped keys
        "mysql-prod-01", "internal.example.net",                  # private hosts
        "hunter2", "LEAKTHISTOO",                                 # creds inside a public URL
        "InternalCodeName",                                       # opaque reference string
        "our-own-password", "our-own-key",                        # our secrets too
    ]
    must_appear = [
        "<redacted>", "<url:private>", "<string>", "<empty>", "<int>",
        "https://lists.ala.org.au/ws",       # public URL, credentials and query stripped
        "pdfgen.ala.org.au",                 # flagged as pointing outside the deployment
        "Some.Count",                        # case-variant conflict surfaced
    ]

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "ours").mkdir()
        (root / "ref").mkdir()
        (root / "ours" / "demo.properties").write_text(ours)
        (root / "ref" / "demo.properties").write_text(reference)
        text = "\n".join(
            report(root / "ours", root / "ref",
                   {"records-ws.example.test", "collections.example.test"})
        )

    failures = [f"LEAKED: {s}" for s in must_not_appear if s in text]
    failures += [f"MISSING: {s}" for s in must_appear if s not in text]
    for f in failures:
        print(f, file=sys.stderr)
    if failures:
        print("\n--- report under test ---\n" + text, file=sys.stderr)
        return 1
    print(f"self-test OK: {len(must_not_appear)} secrets withheld, "
          f"{len(must_appear)} expected markers present")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--self-test", action="store_true",
                    help="run the redaction-gate self-test and exit")
    ap.add_argument("--ours", type=Path)
    ap.add_argument("--reference", type=Path)
    ap.add_argument("--out", type=Path, help="write the report here instead of stdout")
    ap.add_argument(
        "--own-host",
        action="append",
        default=[],
        help="hostname belonging to this deployment; repeatable. Used to decide which of our "
             "URLs point somewhere else.",
    )
    ap.add_argument(
        "--own-hosts-from",
        type=Path,
        help="e2e-targets.json to read this deployment's hostnames from (root, auth and every "
             "service), so the host list comes from the inventory rather than being retyped.",
    )
    args = ap.parse_args()

    if args.self_test:
        return self_test()
    if args.ours is None:
        ap.error("--ours is required (or use --self-test)")
    if not args.ours.is_dir():
        print(f"ERROR: not a directory: {args.ours}", file=sys.stderr)
        return 1
    if args.reference and not args.reference.is_dir():
        print(f"ERROR: not a directory: {args.reference}", file=sys.stderr)
        return 1

    own = {h.lower() for h in args.own_host}
    if args.own_hosts_from:
        from urllib.parse import urlparse

        manifest = json.loads(args.own_hosts_from.read_text())
        urls = [manifest.get("root", ""), manifest.get("auth", "")]
        urls += list((manifest.get("services") or {}).values())
        for u in urls:
            host = urlparse(u).hostname if u else None
            if host:
                own.add(host.lower())
    lines = report(args.ours, args.reference, own)
    text = "\n".join(lines) + "\n"
    if args.out:
        args.out.write_text(text)
        print(f"report written to {args.out} ({len(lines)} lines)")
    else:
        print(text, end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())

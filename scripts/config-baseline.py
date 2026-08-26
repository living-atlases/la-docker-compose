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
    scripts/config-baseline.py extract --from <rendered-dir> [--out config-baseline.json]
    scripts/config-baseline.py check   --from <rendered-dir> [--baseline config-baseline.json]

<rendered-dir> comes from scripts/render-properties-offline.sh. Deliberately NOT a live
/data: that tree accumulates hand-kept variants (.last, .es, .tests) beside the real files,
and freezing one of those would pin somebody's old experiment as the expected state.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_BASELINE = HERE.parent / "config-baseline.json"


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


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    e = sub.add_parser("extract", help="write the baseline from a rendered tree")
    e.add_argument("--from", dest="src", required=True, type=Path)
    e.add_argument("--out", type=Path, default=DEFAULT_BASELINE)

    c = sub.add_parser("check", help="fail if a rendered tree has drifted from the baseline")
    c.add_argument("--from", dest="src", required=True, type=Path)
    c.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE)

    args = ap.parse_args()
    if not args.src.is_dir():
        print(f"ERROR: not a directory: {args.src}", file=sys.stderr)
        return 1

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

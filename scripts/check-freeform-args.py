#!/usr/bin/env python3
"""Fail on free-form `shell:`/`command:` bodies Ansible cannot split into arguments.

`shell:` and `command:` are free-form modules: Ansible runs split_args() over the WHOLE
body, comments included, before the task runs. An odd number of quotes anywhere in it —
an apostrophe in a comment is enough — aborts the play with

    ERROR! failed at splitting arguments, either an unbalanced jinja2 block or quotes

pointing at the first line of the block, which reads like a YAML problem and is not one.
`ansible-playbook --syntax-check` does NOT catch this, and neither does yamllint: a
deploy died on `# nginx's own log ...` after both passed.

Usage: scripts/check-freeform-args.py [paths...]   (default: roles/**/tasks/*.yml)
"""
import glob
import sys

import yaml
from ansible.parsing.splitter import split_args

FREE_FORM = ("shell", "command", "raw", "script")


def tasks(node):
    """Yield every task dict, descending into block/rescue/always."""
    if isinstance(node, list):
        for item in node:
            yield from tasks(item)
    elif isinstance(node, dict):
        yield node
        for key in ("block", "rescue", "always"):
            if key in node:
                yield from tasks(node[key])


def main(paths):
    failures = []
    for path in paths:
        try:
            doc = yaml.safe_load(open(path))
        except yaml.YAMLError as err:
            failures.append((path, None, None, str(err).splitlines()[0]))
            continue
        for task in tasks(doc):
            for module in FREE_FORM:
                body = task.get(module)
                if not isinstance(body, str):
                    continue
                try:
                    split_args(body)
                except Exception as err:  # noqa: BLE001 - report whatever Ansible raises
                    failures.append(
                        (path, task.get("name", "<unnamed>"), module, str(err).splitlines()[0])
                    )

    for path, name, module, err in failures:
        where = f"{path}: {module}: {name}" if name else path
        print(f"FAIL {where}\n     {err}", file=sys.stderr)
    if failures:
        print(f"\n{len(failures)} unsplittable free-form task(s).", file=sys.stderr)
        print("Usually an apostrophe in a comment; balance the quotes.", file=sys.stderr)
        return 1
    print(f"OK: {len(paths)} file(s), every free-form shell/command splits cleanly.")
    return 0


if __name__ == "__main__":
    args = sys.argv[1:] or sorted(glob.glob("roles/**/tasks/*.yml", recursive=True))
    sys.exit(main(args))

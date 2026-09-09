#!/usr/bin/env python3
"""Parse every Jinja expression in our Ansible files, so template syntax errors
surface here instead of mid-deploy.

Ansible only compiles a template when it renders it, which for a `set_fact` means
halfway through a play, on every host at once. Nothing before that looks: the file
is valid YAML (the expression is just a string), yamllint and ansible-lint are
happy, and `ansible-playbook --syntax-check` does not evaluate templates. Build
#384 died that way -- a `#` comment inside a `{{ [...] }}`, which Jinja has no
syntax for -- after 40 minutes of deploying.

This is a PARSE, not a render: it needs no variables, no inventory and no Ansible,
so it cannot produce undefined-variable false positives. It catches unbalanced
braces, `#` comments inside expressions, bad filter syntax and the like.

YAML files are checked one scalar at a time -- the unit Ansible actually templates
-- rather than as one blob, so a `{% if %}` in one value and its `{% endif %}` in
another (or a comment full of Jinja) is not mistaken for an unclosed block. `.j2`
files are templates in their own right and are parsed whole.

Usage: scripts/check-jinja-syntax.py [path ...]     (default: roles/ and config-gen.yml)
"""
import sys
from pathlib import Path

try:
    import yaml
    from jinja2 import Environment
    from jinja2.exceptions import TemplateSyntaxError
except ImportError as e:
    print(f"SKIP: {e.name} not installed (pip install jinja2 pyyaml)")
    sys.exit(0)

DEFAULT_PATHS = ["roles", "config-gen.yml"]
env = Environment()


def scalars(node):
    """Every string in a parsed YAML document."""
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for k, v in node.items():
            yield from scalars(k)
            yield from scalars(v)
    elif isinstance(node, list):
        for item in node:
            yield from scalars(item)


def check(path: Path) -> list[str]:
    try:
        source = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return []
    if "{{" not in source and "{%" not in source:
        return []

    if path.suffix == ".j2":
        try:
            env.parse(source)
        except TemplateSyntaxError as e:
            return [f"{path}:{e.lineno}: {e.message}"]
        return []

    try:
        docs = list(yaml.safe_load_all(source))
    except yaml.YAMLError:
        # Not our job: yamllint reports malformed YAML.
        return []

    failures = []
    for doc in docs:
        for value in scalars(doc):
            if "{{" not in value and "{%" not in value:
                continue
            try:
                env.parse(value)
            except TemplateSyntaxError as e:
                snippet = " ".join(value.split())[:90]
                failures.append(f"{path}: {e.message}\n     in: {snippet}")
    return failures


def main(argv: list[str]) -> int:
    roots = [Path(p) for p in (argv or DEFAULT_PATHS)]
    files: list[Path] = []
    for root in roots:
        if root.is_file():
            files.append(root)
        elif root.is_dir():
            for pattern in ("**/*.yml", "**/*.yaml", "**/*.j2"):
                files.extend(root.glob(pattern))
    failures = [msg for f in sorted(set(files)) for msg in check(f)]
    for msg in failures:
        print(f"FAIL {msg}")
    print(f"{len(files)} file(s) parsed, {len(failures)} Jinja syntax error(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

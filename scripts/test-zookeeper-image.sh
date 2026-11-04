#!/usr/bin/env bash
# infrastructure/zookeeper.yml.j2: the image is zookeeper:<zookeeper_version> unless an
# inventory sets zookeeper_image, the whole reference of a derived image. Upstream tags
# up to 3.9.5 ship libbrotli1 1.0.9-2build6 (CVE-2026-111497), so a portal that cannot wait
# for upstream pins livingatlases/zookeeper:3.9.3-brotli. The role forces zookeeper_version
# with set_fact, so a tag cannot ride on it: the override has to be the full reference.
set -eu
cd "$(dirname "$0")/.."
PY="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}python3"
command -v "$PY" >/dev/null || PY=python3
"$PY" - <<'PY'
import jinja2, yaml
from ansible.plugins.filter.core import FilterModule as Core
e = jinja2.Environment(loader=jinja2.FileSystemLoader("roles/la-compose/templates/docker-compose/infrastructure"),
                       trim_blocks=True)
for f in ("to_json", "bool"):
    e.filters[f] = Core().filters()[f]

def image(**v):
    return yaml.safe_load(e.get_template("zookeeper.yml.j2").render(zookeeper_version="3.9.3", **v))["services"]["zookeeper"]["image"]

fail = 0
for label, got, want in [
    ("default follows zookeeper_version", image(), "zookeeper:3.9.3"),
    ("zookeeper_image overrides the reference", image(zookeeper_image="livingatlases/zookeeper:3.9.3-brotli"),
     "livingatlases/zookeeper:3.9.3-brotli"),
]:
    ok = got == want
    print(f"[{'PASS' if ok else 'FAIL'}] {label} -> {got}")
    fail |= not ok
raise SystemExit(fail)
PY

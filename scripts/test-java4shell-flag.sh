#!/bin/bash
#
# test-java4shell-flag.sh
#
# Java4Shell (CVE-2026-114938): the JVM 17 builds in the stack (17.0.6 to 17.0.27, and the
# 21.x ones in the census) have a pre-auth RCE on CPUs with AVX-512 VBMI. Until upstream
# ships corrected images, the mitigation is `-XX:-UseBASE64Intrinsics`.
#
# The flag goes in JAVA_TOOL_OPTIONS, not in <SERVICE>_JAVA_OPTS: the JVM reads it whatever
# the image's CMD does with JAVA_OPTS (spatial-service and sensitive-data-service run their own
# java command, cassandra and zookeeper never read JAVA_OPTS at all, geoserver sets it inline).
#
# This test renders the real service templates and checks two things:
#
#   1. every service with a JVM 17+ in the census carries JAVA_TOOL_OPTIONS with the flag,
#      exactly once;
#   2. no service on JDK 8/11, or without a JDK known to this repo, carries it. JDK 8 aborts
#      with "Unrecognized VM option" on that flag, so it must never be added there.
#
# It also checks that java4shell_mitigation=false removes the flag everywhere (the escape
# hatch for an operator who must run an image that cannot take it).
#
# Cheap on purpose: renders the templates with jinja2, no Docker, no inventory. It does not
# prove the flag reaches a running container; see the deploy notes in TASK-121.
#
# Usage: bash scripts/test-java4shell-flag.sh
# Exits 0 when every check passes, 1 otherwise.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PYTHON=""
for candidate in \
    "${VENV_MOLECULE:-/nonexistent}/bin/python" \
    "${WORKSPACE:-$REPO_ROOT}/.venv-molecule/bin/python" \
    "$REPO_ROOT/.venv-molecule/bin/python" \
    python3
do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import jinja2' 2>/dev/null; then
        PYTHON="$candidate"
        break
    fi
done

if [ -z "$PYTHON" ]; then
    echo "❌ no python with jinja2 available (tried VENV_MOLECULE, .venv-molecule, python3)"
    exit 1
fi

"$PYTHON" - "$REPO_ROOT" <<'PYTHON'
import json
import re
import sys
from pathlib import Path

from jinja2 import ChainableUndefined, Environment, FileSystemLoader

repo_root = Path(sys.argv[1])
templates = repo_root / "roles" / "la-compose" / "templates" / "docker-compose"
FLAG = "-XX:-UseBASE64Intrinsics"

# JVM 17+ in the census: must carry the flag. template (relative to docker-compose/) -> service.
MUST_HAVE = {
    "services/alerts.yml.j2": "alerts",
    "services/biocache-hub.yml.j2": "biocache-hub",
    "services/biocache-service.yml.j2": "biocache-service",
    "services/biocollect.yml.j2": "biocollect",
    "services/collectory.yml.j2": "collectory",
    "services/data-quality-filter-service.yml.j2": "data-quality-filter-service",
    "services/doi-service.yml.j2": "doi-service",
    "services/ecodata.yml.j2": "ecodata",
    "services/geoserver.yml.j2": "geoserver",
    "services/image-service.yml.j2": "image-service",
    "services/logger-service.yml.j2": "logger-service",
    "services/pipelines.yml.j2": "pipelines",
    "services/spatial-hub.yml.j2": "spatial-hub",
    "services/spatial-service.yml.j2": "spatial-service",
    "infrastructure/cassandra.yml.j2": "cassandra",
    "infrastructure/zookeeper.yml.j2": "zookeeper",
}

# JDK 8/11 in the census, or no JDK known here: must NOT carry the flag. JDK 8 would abort.
MUST_NOT_HAVE = {
    "services/bie-hub.yml.j2": "bie-hub (JDK 8/11)",
    "services/bie-index.yml.j2": "bie-index (JDK 8/11)",
    "services/regions.yml.j2": "regions (JDK 8/11)",
    "services/cas.yml.j2": "cas (JDK 8/11)",
    "services/userdetails.yml.j2": "userdetails (JDK 8/11)",
    "services/namematching-service.yml.j2": "namematching (JDK 8/11)",
    "services/sds.yml.j2": "sds (JDK 8/11)",
    "services/sensitive-data-service.yml.j2": "sensitive-data-service (JDK 8/11)",
    "infrastructure/solr.yml.j2": "solr (JDK 11)",
    "services/geonetwork.yml.j2": "geonetwork (JDK 8)",
    "services/pdfgen.yml.j2": "pdfgen (JDK 8)",
    "services/apikey.yml.j2": "apikey (JDK not in census)",
    "services/cas-management.yml.j2": "cas-management (JDK not in census)",
    "services/species-list.yml.j2": "species-list (JDK not in census)",
    "services/dashboard.yml.j2": "dashboard (JDK not in census)",
}

env = Environment(
    # Ansible resolves `include` against every directory the template lives in: services/ holds
    # the _i18n_volumes partial that the service templates include by bare name.
    loader=FileSystemLoader([str(templates / "services"), str(templates / "infrastructure"), str(templates)]),
    undefined=ChainableUndefined,
    trim_blocks=True,  # Ansible renders templates with trim_blocks on
)
# Ansible filters the service templates use; plain Jinja2 has neither.
env.filters["bool"] = lambda value: str(value).strip().lower() in ("true", "yes", "on", "1")
env.filters["to_json"] = lambda value: json.dumps(value)
env.filters["regex_replace"] = lambda value, pattern, repl="": re.sub(pattern, repl, str(value))

LINE = re.compile(r"^\s*(?:- )?JAVA_TOOL_OPTIONS[:=]", re.MULTILINE)


def render(rel, mitigation, **extra):
    rel = Path(rel).name
    ctx = {
        "java4shell_mitigation": mitigation,
        "java4shell_tool_options": FLAG,
        "data_dir": "/data",
        "docker_compose_data_dir": "/data/docker-compose",
        "datastore_endpoints": {},
        "services_enabled": [],
        "hub_java_heaps": [],
        "server_tz": "UTC",
    }
    ctx.update(extra)
    return env.get_template(rel).render(**ctx)


failures = []
for rel, name in MUST_HAVE.items():
    text = render(rel, True)
    lines = [l for l in text.splitlines() if LINE.match(l)]
    if len(lines) != 1:
        failures.append(f"{name}: want exactly one JAVA_TOOL_OPTIONS line, got {len(lines)}")
    elif FLAG not in lines[0]:
        failures.append(f"{name}: JAVA_TOOL_OPTIONS without {FLAG}: {lines[0].strip()}")
    off = render(rel, False)
    if LINE.search(off):
        failures.append(f"{name}: java4shell_mitigation=false still emits JAVA_TOOL_OPTIONS")

# Cassandra 3.x runs on Java 8, and the "Picked up JAVA_TOOL_OPTIONS" line breaks the Java version
# check of cassandra-env.sh ("Cassandra 3.0 and later require Java 8u40 or later"): la_cassandra of
# prod (3.11.19) went into a restart loop on 2026-11-19. Only 4.x and later get the flag.
for ver, want in (("3.11.19", False), ("4.1.7", True), ("5.0.6", True)):
    text = render("infrastructure/cassandra.yml.j2", True, cassandra_version=ver)
    if bool(LINE.search(text)) != want:
        failures.append(f"cassandra {ver}: JAVA_TOOL_OPTIONS {'missing' if want else 'present, breaks Java 8'}")

# Elasticsearch bundles its own JDK (la_doi-elasticsearch: 22.0.2, a line with no fix) and its
# bin/elasticsearch-env unsets JAVA_TOOL_OPTIONS, so the flag has to go in ES_JAVA_OPTS.
ES_MUST_HAVE = {
    "infrastructure/doi-elasticsearch.yml.j2": "doi-elasticsearch",
    "infrastructure/elasticsearch.yml.j2": "elasticsearch",
    "infrastructure/ecodata-elasticsearch.yml.j2": "ecodata-elasticsearch",
}
# ES 8 starts the server from a small launcher JVM (bin/elasticsearch-cli, "-Dcli.name=server")
# that stays alive as its parent and reads CLI_JAVA_OPTS, not ES_JAVA_OPTS: without it the
# launcher runs the bundled JDK unmitigated and check_java4shell goes CRITICAL.
ES_LINE = re.compile(r"^\s*ES_JAVA_OPTS:.*$", re.MULTILINE)
CLI_LINE = re.compile(r"^\s*CLI_JAVA_OPTS:.*$", re.MULTILINE)
for rel, name in ES_MUST_HAVE.items():
    text = render(rel, True)
    for var, rx in (("ES_JAVA_OPTS", ES_LINE), ("CLI_JAVA_OPTS", CLI_LINE)):
        lines = rx.findall(text)
        if len(lines) != 1 or FLAG not in lines[0]:
            failures.append(f"{name}: want one {var} line with {FLAG}, got {lines}")
    if LINE.search(text):
        failures.append(f"{name}: JAVA_TOOL_OPTIONS is unset by elasticsearch-env, use ES_JAVA_OPTS")
    if FLAG in render(rel, False):
        failures.append(f"{name}: java4shell_mitigation=false still emits {FLAG}")

# Source check, not a render: these templates need a dozen role variables to render, and the
# only way the flag can reach them is an include of the partial or a literal JAVA_TOOL_OPTIONS.
for rel, name in MUST_NOT_HAVE.items():
    src = (templates / rel).read_text()
    if "_java4shell.yml.j2" in src or "JAVA_TOOL_OPTIONS" in src:
        failures.append(f"{name}: wires the Java4Shell flag, JDK 8/11 or unknown must not get it")

if failures:
    print("❌ Java4Shell mitigation is incomplete:\n")
    for f in failures:
        print("  - " + f)
    sys.exit(1)

print(f"✅ Java4Shell flag on {len(MUST_HAVE)} JVM 17+ service(s) and {len(ES_MUST_HAVE)} Elasticsearch, absent on {len(MUST_NOT_HAVE)} other(s).")
PYTHON

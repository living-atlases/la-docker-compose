#!/bin/bash
#
# test-java-opts-env.sh
#
# `<SERVICE>_JAVA_OPTS` must carry every -D the image would otherwise supply itself.
#
# A service sets `JAVA_OPTS: ${<SERVICE>_JAVA_OPTS}`, and that REPLACES the image's own
# ENV JAVA_OPTS rather than adding to it. So whatever this file forgets is simply not
# passed to the JVM.
#
# That was harmless until la-docker-images#3. The Java image templates expanded
# JAVA_OPTS at Dockerfile generation time, so every flag ended up frozen into the image
# CMD:
#
#     [/bin/sh -c java -Xmx2g -Xms2g -Xss512k -Djava.awt.headless=true
#      -Dspring.config.additional-location=/data/userdetails/config/
#      -Dspring.config.name=application,application-local-config -jar .../app.war]
#
# The spring.config settings survived whatever this file emitted -- and so did the
# memory, which is why `<service>_max_memory` did nothing. With the fixed images the
# CMD is `java ${JAVA_OPTS} -jar ...`: the memory settings finally work, and anything
# missing here disappears. Dropping spring.config would start a service without its
# /data/<artifact>/config overrides, which fails late and looks like a config bug
# rather than a packaging one. Verified against a rebuilt userdetails image before
# this test was written.
#
# Several services also re-add these in a `command:` override, written when that was
# the only way to honour JAVA_OPTS at all. Those are redundant once this is right, but
# harmless: a later -D on the command line wins, so a service that appends its own
# spring.config.name (alerts, ecodata) still gets it.
#
# Cheap on purpose: renders the template, no Docker, no inventory, no deployed stack.
#
# Scope, so nobody asks it for more than it gives:
#
#   - Two services, not 23. They are picked to cover the three shapes this breaks in
#     (see the fixture below), not for coverage. A regression in a service shaped
#     unlike either would slip through; adding a third is a couple of lines.
#   - It checks that the template PROPAGATES what it is handed, not that the values
#     are computed correctly. The -Xmx/-Xms here are fed in through
#     service_java_opts_dict; <service>_max_memory is resolved elsewhere, by
#     java-opts-builder.j2 and the role that calls it.
#
# Usage: bash scripts/test-java-opts-env.sh
#
# Exits 0 if every rendered service line is complete, 1 otherwise.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ansible-core brings Jinja2, so the molecule venv the unit stage builds will do.
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
import sys
from pathlib import Path

from jinja2 import ChainableUndefined, Environment, FileSystemLoader

repo_root = Path(sys.argv[1])
templates = repo_root / "roles" / "la-compose" / "templates"

env = Environment(loader=FileSystemLoader(str(templates)), undefined=ChainableUndefined)

# `bool` is an Ansible filter, not a Jinja2 one, and the template uses it to gate the
# airflow block. Nothing else in this file needs Ansible's filter set.
env.filters["bool"] = lambda value: str(value).strip().lower() in ("true", "yes", "on", "1")

# Two services worth distinguishing: userdetails has a logging config and its env
# prefix is just the upper-cased name, while ala_hub has neither -- its artifact is
# `ala-hub` (so the data dir is /data/ala-hub, not /data/ala_hub) and its env prefix
# is remapped to BIOCACHE_HUB.
rendered = env.get_template("docker-compose.env.j2").render(
    service_java_opts_dict={
        "userdetails": "-Djava.awt.headless=true -Xmx512m -Xms256m -Dlog4j2.formatMsgNoLookups=true",
        "ala_hub": "-Djava.awt.headless=true -Xmx4g -Xms2g -Dlog4j2.formatMsgNoLookups=true",
    },
    docker_services_desc={
        "userdetails": {"artifacts": "userdetails", "log_config_filename": "logback.xml"},
        "ala_hub": {"artifacts": "ala-hub"},
    },
    service_extra_params={},
    vars={"userdetails_version": "3.2.1", "ala_hub_version": "8.3.0"},
)

lines = {
    line.split("=", 1)[0]: line.split("=", 1)[1]
    for line in rendered.splitlines()
    if "_JAVA_OPTS=" in line and not line.startswith("#")
}

failures = []


def require(prefix, fragment, why):
    value = lines.get(prefix)
    if value is None:
        failures.append(f"{prefix} was not emitted at all")
    elif fragment not in value:
        failures.append(f"{prefix} is missing {fragment} ({why})\n      got: {value}")


for prefix, artifact in (("USERDETAILS_JAVA_OPTS", "userdetails"), ("BIOCACHE_HUB_JAVA_OPTS", "ala-hub")):
    # Without these a service starts with none of its /data/<artifact>/config
    # overrides. The image puts them in ENV JAVA_OPTS, which the service replaces.
    require(prefix, f"-Dspring.config.additional-location=/data/{artifact}/config/",
            "config overrides would not be read")
    require(prefix, "-Dspring.config.name=application,application-local-config",
            "application-local-config would not be read")

# Memory has to survive the trip through the template: with the fixed images this is
# the only route to the JVM. Whether the value itself is right is java-opts-builder's
# job -- these two are handed in above, so this only proves nothing drops them.
require("USERDETAILS_JAVA_OPTS", "-Xmx512m", "<service>_max_memory would not reach the JVM")
require("BIOCACHE_HUB_JAVA_OPTS", "-Xmx4g", "<service>_max_memory would not reach the JVM")

# Only when the service declares one, matching what build.py does.
require("USERDETAILS_JAVA_OPTS", "-Dlogging.config=/data/userdetails/config/logback.xml",
        "logging config path")
if "-Dlogging.config" in lines.get("BIOCACHE_HUB_JAVA_OPTS", ""):
    failures.append("BIOCACHE_HUB_JAVA_OPTS has -Dlogging.config but declares no log_config_filename")

# The data dir is the artifact, not the docker_services_desc key: ala_hub -> ala-hub.
if "/data/ala_hub/" in lines.get("BIOCACHE_HUB_JAVA_OPTS", ""):
    failures.append("BIOCACHE_HUB_JAVA_OPTS points at /data/ala_hub, but the artifact is ala-hub")

if failures:
    print("❌ JAVA_OPTS env generation is incomplete:\n")
    for failure in failures:
        print(f"   - {failure}")
    sys.exit(1)

print(f"✅ JAVA_OPTS env generation complete for {len(lines)} service(s).")
PYTHON

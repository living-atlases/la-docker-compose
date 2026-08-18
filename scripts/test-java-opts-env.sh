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
# missing here disappears.
#
# Dropping spring.config would start a service without its /data/<artifact>/config
# overrides, which fails late and looks like a config bug rather than a packaging one.
# Verified against a rebuilt userdetails image before this test was written.
#
# Several services also re-add these in a `command:` override, written when that was
# the only way to honour JAVA_OPTS at all. Those are redundant once this is right, but
# harmless: a later -D on the command line wins, so a service that appends its own
# spring.config.name (alerts, ecodata) still gets it.
#
# Cheap on purpose: renders the template, no Docker, no inventory, no deployed stack.
#
# SCOPE, so nobody asks it for more than it gives:
#
#   - The http.agent assertion proves the template emits `<key>/<version>`, NOT that
#     the version resolves on a real inventory. The template looks up
#     `<key>_version`, and CASES supplies exactly that, so it cannot fail here.
#     Live deployments disagree: docker_services_desc keys and inventory version
#     variables are named independently, so `ala_hub` looks up `ala_hub_version`
#     while the inventory declares `biocache_hub_version`, and the rendered .env
#     carries `-Dhttp.agent=ala_hub/develop`. Same for userdetails, species_lists,
#     spatial, images, doi, namematchingService and sensitiveDataService; regions,
#     logger, ecodata, sds and spatial_service do resolve. It only reaches an
#     outgoing User-Agent, which is why nobody noticed -- but do not read a green
#     run here as "the versions are right".
#   - Five services, not 23. They are picked to cover the shapes this breaks in (see
#     the CASES table below), not for coverage. A regression in a service shaped
#     unlike any of them would slip through; adding one is a row.
#
#   - It proves the template PROPAGATES what it is handed, not that the values are
#     right. The -Xmx/-Xms arrive already assembled through service_java_opts_dict;
#     `<service>_max_memory` is resolved in Ansible, in generate-compose.yml ("Build
#     JAVA_OPTS strings for each service"). NOT in java-opts-builder.j2, which despite
#     its name is referenced by nothing and has been dead since b1a7855.
#
#   - It cannot see the sharpest failure of all. Membership of service_java_opts_dict
#     is decided by that same Ansible loop, which selects on `log_config_filename`
#     being defined. A Java service that declares none never enters the dict, so no
#     <PREFIX>_JAVA_OPTS line is emitted, `JAVA_OPTS: ${<PREFIX>_JAVA_OPTS}` in its
#     compose file expands to EMPTY, and with the fixed images that is a JVM with no
#     memory settings and no spring.config at all. Feeding the dict by hand here
#     bypasses that gate by construction, so guard it where it lives, not from here.
#     Checked at the time of writing: all 18 services that consume a
#     <PREFIX>_JAVA_OPTS have an emitter, and the ones without log_config_filename
#     are infrastructure (cassandra, solr, zookeeper, gatus...) that consumes none.
#     The trap is set for the next Java service added without one.
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

# One row per SHAPE the template has to get right, so covering a new one is a line
# here rather than a new block below. Two hardcoded services used to leave the
# hyphenated-key and extra_params paths unexercised.
#
#   userdetails  the plain case: prefix is the upper-cased key, artifact == key,
#                and it declares a logging config
#   ala_hub      prefix remapped (BIOCACHE_HUB) AND artifact differs from the key
#                (ala-hub), so /data/ala_hub/ would be wrong. It does declare a
#                logging config -- the real inventory gives it logback.xml
#   ala_bie      the other remap (BIE_HUB), guarding the map rather than one entry
#   data-quality hyphenated key: the prefix must become DATA_QUALITY, and the
#                <key>_version lookup must survive the same substitution
#   alerts       declares NO logging config, so -Dlogging.config must not appear,
#                and carries extra_params, which must be emitted as -Dkey=value
CASES = {
    "userdetails": {
        "desc": {"artifacts": "userdetails", "log_config_filename": "logback.xml"},
        "prefix": "USERDETAILS", "artifact": "userdetails",
        "java_opts": "-Djava.awt.headless=true -Xmx512m -Xms256m -Dlog4j2.formatMsgNoLookups=true",
        "memory": "-Xmx512m", "log_config": "logback.xml", "version": "3.2.1",
    },
    "ala_hub": {
        "desc": {"artifacts": "ala-hub", "log_config_filename": "logback.xml"},
        "prefix": "BIOCACHE_HUB", "artifact": "ala-hub",
        "java_opts": "-Djava.awt.headless=true -Xmx4g -Xms2g -Dlog4j2.formatMsgNoLookups=true",
        "memory": "-Xmx4g", "log_config": "logback.xml", "version": "8.3.0",
    },
    "ala_bie": {
        "desc": {"artifacts": "ala-bie", "log_config_filename": "logback.xml"},
        "prefix": "BIE_HUB", "artifact": "ala-bie",
        "java_opts": "-Djava.awt.headless=true -Xmx2g -Xms1g",
        "memory": "-Xmx2g", "log_config": "logback.xml", "version": "3.0.1",
    },
    "data-quality": {
        "desc": {"artifacts": "data-quality", "log_config_filename": "logback.xml"},
        "prefix": "DATA_QUALITY", "artifact": "data-quality",
        "java_opts": "-Djava.awt.headless=true -Xmx1g -Xms512m",
        "memory": "-Xmx1g", "log_config": "logback.xml", "version": "1.2.3",
    },
    "alerts": {
        "desc": {"artifacts": "alerts"},
        "prefix": "ALERTS", "artifact": "alerts",
        "java_opts": "-Djava.awt.headless=true -Xmx1g -Xms512m",
        "memory": "-Xmx1g", "log_config": None, "version": "5.2.0",
        "extra_params": [{"key": "spring.profiles.active", "value": "prod"}],
    },
}

rendered = env.get_template("docker-compose.env.j2").render(
    service_java_opts_dict={k: c["java_opts"] for k, c in CASES.items()},
    docker_services_desc={k: c["desc"] for k, c in CASES.items()},
    service_extra_params={k: c.get("extra_params", []) for k, c in CASES.items()},
    vars={f"{k.replace('-', '_')}_version": c["version"] for k, c in CASES.items()},
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


def reject(prefix, fragment, why):
    value = lines.get(prefix, "")
    if fragment in value:
        failures.append(f"{prefix} carries {fragment} but {why}\n      got: {value}")


for key, case in CASES.items():
    prefix, artifact = case["prefix"] + "_JAVA_OPTS", case["artifact"]

    # Every service in the dict must produce a line. The template dropping one silently
    # is the same outcome as Ansible never adding it: JAVA_OPTS expands to empty.
    if prefix not in lines:
        failures.append(f"{prefix} was not emitted at all (service {key})")
        continue

    # Without these a service starts with none of its /data/<artifact>/config
    # overrides. The image puts them in ENV JAVA_OPTS, which the service replaces.
    require(prefix, f"-Dspring.config.additional-location=/data/{artifact}/config/",
            "config overrides would not be read")
    require(prefix, "-Dspring.config.name=application,application-local-config",
            "application-local-config would not be read")

    # Propagated from Ansible, not computed here -- see SCOPE in the header.
    require(prefix, case["memory"], "the assembled JAVA_OPTS was not passed through")

    # The data dir is the artifact, not the docker_services_desc key: ala_hub -> ala-hub.
    if artifact != key:
        reject(prefix, f"/data/{key}/", f"the artifact is {artifact}, not the key {key}")

    require(prefix, f"-Dhttp.agent={key}/{case['version']}", "user agent identifies the service")

    # Only when the service declares one, matching what build.py does.
    if case["log_config"]:
        require(prefix, f"-Dlogging.config=/data/{artifact}/config/{case['log_config']}",
                "logging config path")
    else:
        reject(prefix, "-Dlogging.config", "it declares no log_config_filename")

    for param in case.get("extra_params", []):
        require(prefix, f"-D{param['key']}={param['value']}", "extra_params must reach the JVM")

# A prefix collision would silently overwrite one service's options with another's.
if len(lines) != len(CASES):
    failures.append(f"expected {len(CASES)} *_JAVA_OPTS lines, got {len(lines)}: {sorted(lines)}")

if failures:
    print("❌ JAVA_OPTS env generation is incomplete:\n")
    for failure in failures:
        print(f"   - {failure}")
    sys.exit(1)

print(f"✅ JAVA_OPTS env generation complete for {len(lines)} service(s).")
PYTHON

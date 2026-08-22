#!/usr/bin/env bash
#
# test-pipelines-config-render.sh — render ala-install's la-pipelines-local.yaml the way
# ANSIBLE renders it, and assert the result is valid YAML for every deployment type.
#
# Why this exists: a whitespace-control change ({%- ... %}) rendered fine under a stock
# Jinja2 environment and produced GLUED LINES under Ansible's, which sets trim_blocks=True.
# The result was `sampling:  inputPath: ...` on one line -- invalid YAML. la-pipelines
# refused the config, and EVERY pipeline stage failed at startup:
#
#   Error: bad file '-': yaml: line 80: mapping values are not allowed in this context
#   Config /data/la-pipelines/config/la-pipelines-local.yaml is not valid
#
# It shipped because the change was verified with the wrong renderer. This test uses
# Ansible's actual template settings, so the same mistake fails here instead of in a deploy.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TPL="${REPO_ROOT}/ala-install/ansible/roles/pipelines/templates/la-pipelines-local.yaml"

[[ -f "$TPL" ]] || { echo "SKIP: $TPL not found (submodule not initialised?)"; exit 0; }

python3 - "$TPL" <<'PY'
import sys, yaml
try:
    from jinja2 import Environment
except ImportError:
    print("SKIP: jinja2 not available"); sys.exit(0)

tpl = open(sys.argv[1], encoding="utf-8").read()
fail = 0

def render(deployment_type):
    # These are Ansible's template settings, NOT Jinja2's defaults. trim_blocks is the
    # one that matters: with it, a block tag on its own line eats its trailing newline.
    env = Environment(trim_blocks=True, lstrip_blocks=False, keep_trailing_newline=True)
    env.filters["bool"] = lambda v: str(v).lower() in ("true", "yes", "1", "on")
    return env.from_string(tpl).render(
        deployment_type=deployment_type,
        pipelines_data_dir="/data/la-pipelines/data", spark_tmp="/tmp",
        hadoop_master="nn", hadoop_port=8020, hadoop_install_dir="/opt/hadoop",
        layers_service_url="https://spatial.example.org/ws",
        image_service_url="https://images.example.org",
    )

for dt in ("vm", "container"):
    out = render(dt)
    try:
        doc = yaml.safe_load(out)
    except Exception as exc:
        print(f"FAIL - {dt}: rendered config is not valid YAML -> {str(exc).splitlines()[0]}")
        for n, line in enumerate(out.splitlines(), 1):
            if line.startswith(("sampling:", "samplingService:")):
                print(f"       line {n}: {line!r}")
        fail += 1
        continue
    if not isinstance(doc, dict):
        print(f"FAIL - {dt}: rendered config is not a mapping"); fail += 1; continue
    # Glued lines still parse sometimes; assert the keys land where they belong.
    for key in ("sampling", "index", "solr"):
        if key in doc and not isinstance(doc[key], dict):
            print(f"FAIL - {dt}: '{key}' is {type(doc[key]).__name__}, expected a mapping")
            fail += 1
    print(f"PASS - {dt}: renders to valid YAML ({len(doc)} top-level keys)")

# The jar reads samplingService.wsUrl; `sampling.baseUrl` is not a SamplingPipelineOptions
# property and makes it abort at option parsing. Containers must not carry it.
try:
    c = yaml.safe_load(render("container")) or {}
except Exception:
    # Already reported above as invalid YAML; report cleanly rather than tracebacking.
    print("SKIP - container key checks: config did not parse")
    sys.exit(1)
if "baseUrl" in (c.get("sampling") or {}):
    print("FAIL - container: sampling.baseUrl present; the jar rejects it"); fail += 1
else:
    print("PASS - container: no sampling.baseUrl")
if not (c.get("samplingService") or {}).get("wsUrl"):
    print("FAIL - container: samplingService.wsUrl unset -> falls back to ALA's public service"); fail += 1
else:
    print("PASS - container: samplingService.wsUrl set")

sys.exit(1 if fail else 0)
PY
echo "pipelines config render OK"

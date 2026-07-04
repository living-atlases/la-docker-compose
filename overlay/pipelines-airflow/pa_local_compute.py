"""
Pure, Airflow-free core of the NO-AWS overlay: translate the EMR step dicts the
DAGs build into local actions, and run them. Kept separate from sitecustomize.py
so it can be unit-tested without an Airflow runtime (see tests/).
"""
import os
import re
import shlex
import subprocess

LOG_PREFIX = "[no-aws-overlay]"


def translate_step(step: dict) -> dict:
    """EMR step dict -> local action: {'name', 'kind': noop-copy|exec|unknown, ...}."""
    hjs = step.get("HadoopJarStep", {})
    jar = hjs.get("Jar", "")
    args = hjs.get("Args", [])
    name = step.get("Name", "")

    if jar.endswith("s3-dist-cp.jar"):
        # S3<->HDFS shuffle: unnecessary locally (data on the shared /data volume)
        return {"name": name, "kind": "noop-copy", "args": args}

    if jar == "command-runner.jar":
        if len(args) >= 3 and args[0] == "bash" and args[1] == "-c":
            cmd = args[2]
        else:
            cmd = " ".join(args)
        cmd = cmd.replace(" 1>&2", "").strip()
        # Bootstrap helper scripts (S3<->local copies, frictionless packaging) are
        # EMR-cluster plumbing baked into the bootstrap image; they are absent in
        # la_pipelines and unnecessary locally (data on the shared /data volume +
        # MinIO). No-op them. Override the list via PIPELINES_LOCAL_NOOP_SCRIPTS.
        noop_markers = [m.strip() for m in os.environ.get(
            "PIPELINES_LOCAL_NOOP_SCRIPTS",
            "download-datasets.sh,upload-datasets.sh,upload-export.sh,frictionless.sh",
        ).split(",") if m.strip()]
        if any(m in cmd for m in noop_markers):
            return {"name": name, "kind": "noop-script", "cmd": cmd}
        # Optionally no-op whole pipeline stages (e.g. `sds` when the
        # sensitive-data-service is not deployed). PIPELINES_SKIP_STAGES is a
        # comma-separated list of la-pipelines subcommands; a step whose command
        # invokes `la-pipelines <stage>` is skipped. Keeps pipelines-airflow
        # untouched — the DAG still builds the step, the overlay drops it.
        skip_stages = [s.strip() for s in os.environ.get(
            "PIPELINES_SKIP_STAGES", "").split(",") if s.strip()]
        for stage in skip_stages:
            if re.search(r"\bla-pipelines\s+" + re.escape(stage) + r"\b", cmd):
                return {"name": name, "kind": "noop-stage", "cmd": cmd, "stage": stage}
        # DAG steps build `--cluster`; locally we run single-node Spark. Use
        # --embedded, NOT --local: every la-pipelines stage accepts --embedded,
        # but uuid/image-sync/image-load/sample/solr/dwca-export reject --local
        # (only interpret/sds/index/do-all accept it). Verified against the CLI.
        cmd = cmd.replace("--cluster", "--embedded")
        return {"name": name, "kind": "exec", "cmd": cmd}

    # Anything else is unexpected -> surface it loudly rather than silently skip.
    return {"name": name, "kind": "unknown", "jar": jar, "args": args}


def build_argv(action: dict):
    """Return the argv to run for an 'exec' action (no side effects)."""
    if os.environ.get("PIPELINES_LOCAL_BIN"):
        return ["bash", "-lc", action["cmd"]]
    container = os.environ.get("PIPELINES_CONTAINER", "la_pipelines")
    return ["docker", "exec", container, "bash", "-lc", action["cmd"]]


def run_local_step(action: dict):
    """Execute one translated action against the local la_pipelines stack."""
    if action["kind"] in ("noop-copy", "noop-script", "noop-stage"):
        print(f"{LOG_PREFIX} skip {action['kind']}: {action['name']}")
        return f"noop:{action['name']}"
    if action["kind"] == "exec":
        argv = build_argv(action)
        print(f"{LOG_PREFIX} exec: " + " ".join(shlex.quote(a) for a in argv))
        subprocess.run(argv, check=True)
        return f"ran:{action['name']}"
    raise RuntimeError(f"{LOG_PREFIX} unhandled EMR step (overlay out of date?): {action}")

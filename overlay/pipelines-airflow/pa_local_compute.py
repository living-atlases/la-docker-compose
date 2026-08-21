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
# How much of a failed step's output to echo into the Airflow task log. la-pipelines
# is very chatty at DEBUG, so a tail keeps the log readable while still carrying the
# stacktrace, which is always at the end.
LOG_TAIL_LINES = int(os.environ.get("PIPELINES_LOCAL_LOG_TAIL", "120"))


# Where the pipelines-airflow `dags/` tree is mounted read-only inside the containers
# that run steps. Ansible bind-mounts the tree it already stages on the host
# ({{ docker_compose_data_dir }}/pipelines-airflow/dags) into BOTH la_airflow and
# la_pipelines at this path. Read per call, like every other knob here, so a test can
# point it at a real checkout.
PA_DAGS_DIR_DEFAULT = "/opt/pa-dags"

# `sudo -u hadoop` (and bare `sudo`) come from the EMR world: on a real cluster the
# steps run as root and drop to the `hadoop` service user. Neither the user nor sudo
# itself exists in our containers, and the step is already running as the right uid,
# so the prefix is pure noise that turns every affected step into "command not found".
_SUDO_RE = re.compile(r"\bsudo\s+(?:-u\s+\S+\s+)?")

# EMR stages helper scripts and CLIs into /tmp via the cluster's BootstrapActions
# (dags/sh/bootstrap-*.sh). Our LocalCreateJobFlowOperator has no cluster to bootstrap,
# so nothing ever lands there. The files themselves are just part of the dags/ tree,
# which we mount — so rewrite /tmp/<name> to point at the mounted copy.
_TMP_REF_RE = re.compile(r"/tmp/([A-Za-z0-9._-]+)")


def _staged_path(name: str):
    """Return the mounted path for a bootstrap-staged file, or None if we don't have it."""
    dags_dir = os.environ.get("PA_DAGS_DIR", PA_DAGS_DIR_DEFAULT)
    for candidate in (os.path.join(dags_dir, name),
                      os.path.join(dags_dir, "sh", name)):
        if os.path.exists(candidate):
            return candidate
    return None


def rewrite_staged_paths(cmd: str) -> str:
    """Point /tmp/<file> references at the mounted dags/ tree, when we have that file.

    Only rewrites names we can actually resolve: a /tmp path the DAG genuinely means
    as scratch space (or a file we do not ship) is left alone rather than silently
    redirected somewhere it does not exist.
    """
    def sub(m):
        return _staged_path(m.group(1)) or m.group(0)
    return _TMP_REF_RE.sub(sub, cmd)


def translate_step(step: dict) -> dict:
    """EMR step dict -> local action: {'name', 'kind': noop-copy|exec|unknown, ...}."""
    hjs = step.get("HadoopJarStep", {})
    jar = hjs.get("Jar", "")
    args = hjs.get("Args", [])
    name = step.get("Name", "")
    # EMR steps declare what a failure means. The DAGs mark genuinely optional steps
    # CONTINUE (copying outliers that may not exist, deleting s3-dist-cp scratch dirs);
    # ignoring that turned every one of them into a hard stop.
    on_failure = step.get("ActionOnFailure", "TERMINATE_CLUSTER")

    if jar.endswith("s3-dist-cp.jar"):
        # S3<->HDFS shuffle: unnecessary locally (data on the shared /data volume)
        return {"name": name, "kind": "noop-copy", "args": args, "on_failure": on_failure}

    if jar == "command-runner.jar":
        if len(args) >= 3 and args[0] == "bash" and args[1] == "-c":
            cmd = args[2]
        else:
            cmd = " ".join(args)
        cmd = cmd.replace(" 1>&2", "").strip()
        # Strip sudo BEFORE the no-op/skip matching below, so those markers keep
        # matching commands that arrive wrapped in `sudo -u hadoop ...`.
        cmd = _SUDO_RE.sub("", cmd).strip()
        # Bootstrap helper scripts (S3<->local copies, frictionless packaging) are
        # EMR-cluster plumbing baked into the bootstrap image; they are absent in
        # la_pipelines and unnecessary locally (data on the shared /data volume +
        # MinIO). No-op them. Override the list via PIPELINES_LOCAL_NOOP_SCRIPTS.
        noop_markers = [m.strip() for m in os.environ.get(
            "PIPELINES_LOCAL_NOOP_SCRIPTS",
            "download-datasets.sh,upload-datasets.sh,upload-export.sh,frictionless.sh",
        ).split(",") if m.strip()]
        if any(m in cmd for m in noop_markers):
            return {"name": name, "kind": "noop-script", "cmd": cmd, "on_failure": on_failure}
        # Optionally no-op whole pipeline stages (e.g. `sds` when the
        # sensitive-data-service is not deployed). PIPELINES_SKIP_STAGES is a
        # comma-separated list of la-pipelines subcommands; a step whose command
        # invokes `la-pipelines <stage>` is skipped. Keeps pipelines-airflow
        # untouched — the DAG still builds the step, the overlay drops it.
        skip_stages = [s.strip() for s in os.environ.get(
            "PIPELINES_SKIP_STAGES", "").split(",") if s.strip()]
        for stage in skip_stages:
            if re.search(r"\bla-pipelines\s+" + re.escape(stage) + r"\b", cmd):
                return {"name": name, "kind": "noop-stage", "cmd": cmd, "stage": stage, "on_failure": on_failure}
        # DAG steps build `--cluster`; locally we run single-node Spark. Use
        # --embedded, NOT --local: every la-pipelines stage accepts --embedded,
        # but uuid/image-sync/image-load/sample/solr/dwca-export reject --local
        # (only interpret/sds/index/do-all accept it). Verified against the CLI.
        cmd = cmd.replace("--cluster", "--embedded")
        cmd = rewrite_staged_paths(cmd)
        action = {"name": name, "kind": "exec", "cmd": cmd, "on_failure": on_failure}
        # `ala_helper.emr_python_step` is the only producer of python3 steps, and
        # la_pipelines has no python3 at all. la_airflow does, and reaches Solr on the
        # same network, so run those there instead.
        if re.search(r"\bpython3\b", cmd):
            action["container"] = os.environ.get("AIRFLOW_CONTAINER", "la_airflow")
        return action

    # Anything else is unexpected -> surface it loudly rather than silently skip.
    return {"name": name, "kind": "unknown", "jar": jar, "args": args, "on_failure": on_failure}


def build_argv(action: dict):
    """Return the argv to run for an 'exec' action (no side effects)."""
    if os.environ.get("PIPELINES_LOCAL_BIN"):
        return ["bash", "-lc", action["cmd"]]
    container = action.get("container") or os.environ.get("PIPELINES_CONTAINER", "la_pipelines")
    return ["docker", "exec", container, "bash", "-lc", action["cmd"]]


def run_local_step(action: dict):
    """Execute one translated action against the local la_pipelines stack."""
    if action["kind"] in ("noop-copy", "noop-script", "noop-stage"):
        print(f"{LOG_PREFIX} skip {action['kind']}: {action['name']}")
        return f"noop:{action['name']}"
    if action["kind"] == "exec":
        argv = build_argv(action)
        print(f"{LOG_PREFIX} exec: " + " ".join(shlex.quote(a) for a in argv))
        # Capture instead of inheriting the fds: the task runner forks, so anything
        # la-pipelines writes to its own stdout/stderr never reaches the Airflow task
        # log. Without this, a failing step shows only CalledProcessError and the real
        # cause (stacktrace, missing input, OOM) is invisible. Echo a bounded tail on
        # failure, then let check_returncode() raise exactly as before.
        proc = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if proc.returncode != 0:
            out = (proc.stdout or b"").decode("utf-8", "replace").splitlines()
            print(f"{LOG_PREFIX} step failed (rc={proc.returncode}); last {LOG_TAIL_LINES} lines:")
            for line in out[-LOG_TAIL_LINES:]:
                print(f"{LOG_PREFIX} | {line}")
            if action.get("on_failure") == "CONTINUE":
                # The DAG itself says this step is allowed to fail; respect that rather
                # than turning an optional copy/cleanup into a dead run.
                print(f"{LOG_PREFIX} continuing: {action['name']} is ActionOnFailure=CONTINUE")
                return f"failed-continue:{action['name']}"
        proc.check_returncode()
        return f"ran:{action['name']}"
    raise RuntimeError(f"{LOG_PREFIX} unhandled EMR step (overlay out of date?): {action}")

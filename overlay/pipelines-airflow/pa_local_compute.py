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
# /opt/pa-dags is what Ansible mounts in both containers. /opt/airflow/dags is where the
# Airflow image already has the same tree, so a step routed to la_airflow resolves even on
# an overlay deployed before that mount existed.
PA_DAGS_DIRS_DEFAULT = ("/opt/pa-dags", "/opt/airflow/dags")

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
    configured = os.environ.get("PA_DAGS_DIR")
    roots = (configured,) if configured else PA_DAGS_DIRS_DEFAULT
    for root in roots:
        for candidate in (os.path.join(root, name), os.path.join(root, "sh", name)):
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


# --- the dataset download step -------------------------------------------------
# `/tmp/download-datasets.sh <dwca_bucket> <avro_bucket> <ids...>` is how an ingest DAG
# gets the archive onto the machine that runs dwca-avro. Upstream it is `aws s3 cp` +
# unzip as the hadoop user, which nothing in our containers can do: no aws CLI, no sudo,
# no hadoop. It was therefore no-op'd -- fine for the e2e harness, which seeds the archive
# into the volume itself, but it means Load_dataset and Ingest_all_datasets upload to
# MinIO and then ingest nothing.
#
# So translate it by INTENT rather than line by line: fetch s3://<dwca_bucket>/dwca-imports/<id>
# into the directory our dwca-avro actually reads (dwca_import_dir). The upstream unzip is
# deliberately not reproduced -- our dwca-avro reads the .zip directly, which is exactly
# what the ingest e2e has been exercising all along.
_DOWNLOAD_DATASETS_RE = re.compile(r"(?:^|/)download-datasets\.sh\s+(?P<args>.+)$")


def plan_dataset_download(cmd: str):
    """-> {'bucket', 'datasets': [...], 'dest_root'} for a download-datasets.sh call."""
    m = _DOWNLOAD_DATASETS_RE.search(cmd.strip())
    if not m:
        return None
    parts = m.group("args").split()
    if len(parts) < 3:
        return None
    dwca_bucket, _avro_bucket, datasets = parts[0], parts[1], parts[2:]
    return {
        "bucket": dwca_bucket,
        "datasets": datasets,
        "dest_root": os.environ.get("DWCA_IMPORT_DIR", "/data/la-pipelines/dwca-import"),
    }


# --- s3-dist-cp: the bridge between MinIO and the shared volume -----------------
# On EMR these steps shuttle data between S3 and the cluster's HDFS. Locally the
# DAGs still use S3 (MinIO) as the registry they discover work in -- Ingest_all_datasets
# lists datasets from the bucket, Load_dataset uploads the archive it fetched from
# collectory -- while every la-pipelines stage reads the shared volume. So the copy is
# NOT redundant here: no-op'ing it severs discovery from execution, and the DAGs look on
# disk for files that were only ever put in the bucket.
#
# The single-dataset e2e never noticed because the harness seeds the archive straight
# into the volume and skips S3 altogether.
#
# Paths resolve identically in la_airflow and la_pipelines (Ansible mounts the same
# absolute paths in both), so there is no host/container path map to get wrong.
_HDFS_RE = re.compile(r"^hdfs://[^/]*")


def parse_copy_args(args) -> tuple:
    """Pull (src, dest) out of an s3-dist-cp step's argv."""
    src = dest = None
    for a in args or []:
        if a.startswith("--src="):
            src = a[len("--src="):]
        elif a.startswith("--dest="):
            dest = a[len("--dest="):]
    return src, dest


def _split_s3(uri: str) -> tuple:
    rest = uri[len("s3://"):]
    bucket, _, key = rest.partition("/")
    return bucket, key


def local_path(uri: str) -> str:
    """hdfs:///pipelines-outlier -> /pipelines-outlier ; /x -> /x."""
    return _HDFS_RE.sub("", uri) or "/"


def plan_copy(src: str, dest: str) -> dict:
    """Describe the copy without doing it, so it can be unit-tested.

    -> {'op': 'download'|'upload'|'local'|'unsupported', ...}
    """
    src_s3, dest_s3 = src.startswith("s3://"), dest.startswith("s3://")
    if src_s3 and not dest_s3:
        bucket, key = _split_s3(src)
        return {"op": "download", "bucket": bucket, "key": key, "path": local_path(dest)}
    if dest_s3 and not src_s3:
        bucket, key = _split_s3(dest)
        return {"op": "upload", "bucket": bucket, "key": key, "path": local_path(src)}
    if not src_s3 and not dest_s3:
        return {"op": "local", "src": local_path(src), "dest": local_path(dest)}
    return {"op": "unsupported", "src": src, "dest": dest}


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
        src, dest = parse_copy_args(args)
        # Escape hatch: PIPELINES_LOCAL_NOOP_COPIES restores the old blanket no-op.
        if os.environ.get("PIPELINES_LOCAL_NOOP_COPIES") or not (src and dest):
            return {"name": name, "kind": "noop-copy", "args": args, "on_failure": on_failure}
        return {"name": name, "kind": "copy", "args": args, "on_failure": on_failure,
                "src": src, "dest": dest, "plan": plan_copy(src, dest)}

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
        fetch = plan_dataset_download(cmd)
        if fetch and not os.environ.get("PIPELINES_LOCAL_NOOP_COPIES"):
            return {"name": name, "kind": "fetch-datasets", "cmd": cmd,
                    "on_failure": on_failure, "fetch": fetch}
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


def _hand_over_to_pipelines(path: str):
    """Give files we just wrote to the uid la_pipelines runs as.

    The Airflow containers run as uid 50000 and la_pipelines as 1000, on the same bind
    mount. Anything Airflow downloads therefore lands owned by 50000, and the very next
    pipeline stage cannot read or overwrite it -- a failure that surfaces several stages
    later as "no files matched spec", pointing at the wrong place entirely.

    Best-effort: we already hold the docker socket, so fix it from inside the pipelines
    container as root. A failure here is logged, not fatal -- on a single-uid deployment
    there is nothing to fix.
    """
    if os.environ.get("PIPELINES_SKIP_CHOWN"):
        return
    uid = os.environ.get("PIPELINES_UID", "1000")
    container = os.environ.get("PIPELINES_CONTAINER", "la_pipelines")
    argv = ["docker", "exec", "-u", "0", container, "chown", "-R", f"{uid}:{uid}", path]
    try:
        proc = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if proc.returncode != 0:
            out = (proc.stdout or b"").decode("utf-8", "replace").strip()
            print(f"{LOG_PREFIX} could not chown {path} to {uid} (rc={proc.returncode}): {out}")
    except Exception as exc:
        print(f"{LOG_PREFIX} could not chown {path} to {uid}: {exc!r}")


def run_copy(action: dict):
    """Perform an s3-dist-cp step for real, against MinIO and the shared volume.

    Runs in-process with boto3 rather than shelling out: the Airflow image ships boto3
    (and AWS_ENDPOINT_URL_S3 already points at MinIO) but has no `aws` CLI, so a shell
    copy would just fail with "command not found".
    """
    plan = action["plan"]
    op = plan["op"]
    if op == "unsupported":
        raise RuntimeError(f"{LOG_PREFIX} cannot translate copy {plan['src']} -> {plan['dest']}")

    def _s3():
        # Lazy, and only on the paths that actually touch S3: a local->local copy must
        # not need boto3, and this module has to stay importable for the unit tests.
        import boto3
        return boto3.client("s3")

    moved = 0

    if op == "download":
        s3 = _s3()
        # s3-dist-cp copies a prefix; mirror the key layout under the destination dir.
        prefix = plan["key"].rstrip("/")
        paginator = s3.get_paginator("list_objects_v2")
        for page in paginator.paginate(Bucket=plan["bucket"], Prefix=prefix):
            for obj in page.get("Contents", []):
                key = obj["Key"]
                if key.endswith("/"):
                    continue
                rel = key[len(prefix):].lstrip("/") if prefix else key
                target = os.path.join(plan["path"], rel) if rel else plan["path"]
                os.makedirs(os.path.dirname(target), exist_ok=True)
                s3.download_file(plan["bucket"], key, target)
                moved += 1

    elif op == "upload":
        s3 = _s3()
        base = plan["path"]
        prefix = plan["key"].strip("/")
        if os.path.isdir(base):
            for root, _, files in os.walk(base):
                for f in files:
                    full = os.path.join(root, f)
                    rel = os.path.relpath(full, base)
                    key = f"{prefix}/{rel}" if prefix else rel
                    s3.upload_file(full, plan["bucket"], key)
                    moved += 1
        elif os.path.exists(base):
            key = prefix or os.path.basename(base)
            s3.upload_file(base, plan["bucket"], key)
            moved = 1

    else:  # local -> local
        import shutil
        src, dest = plan["src"], plan["dest"]
        if os.path.isdir(src):
            shutil.copytree(src, dest, dirs_exist_ok=True)
            moved = sum(len(f) for _, _, f in os.walk(dest))
        elif os.path.exists(src):
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            shutil.copy2(src, dest)
            moved = 1

    if op in ("download", "local") and moved:
        _hand_over_to_pipelines(plan["path"] if op == "download" else plan["dest"])

    print(f"{LOG_PREFIX} copy {op}: {action['src']} -> {action['dest']} ({moved} object(s))")
    return f"copied:{action['name']}"


def run_fetch_datasets(action: dict):
    """Bring each dataset's DwCA from MinIO into the directory dwca-avro reads."""
    plan = action["fetch"]
    total = 0
    for ds in plan["datasets"]:
        dest = os.path.join(plan["dest_root"], ds)
        moved = run_copy({
            "name": f"{action['name']} [{ds}]",
            "src": f"s3://{plan['bucket']}/dwca-imports/{ds}",
            "dest": dest,
            "on_failure": action.get("on_failure"),
            "plan": plan_copy(f"s3://{plan['bucket']}/dwca-imports/{ds}", dest),
        })
        total += 1 if moved else 0
    print(f"{LOG_PREFIX} fetched {len(plan['datasets'])} dataset(s) into {plan['dest_root']}")
    return f"fetched:{action['name']}"


def run_local_step(action: dict):
    """Execute one translated action against the local la_pipelines stack."""
    if action["kind"] == "fetch-datasets":
        try:
            return run_fetch_datasets(action)
        except Exception as exc:
            print(f"{LOG_PREFIX} dataset fetch failed: {action['name']}: {exc!r}")
            if action.get("on_failure") == "CONTINUE":
                return f"failed-continue:{action['name']}"
            raise
    if action["kind"] == "copy":
        try:
            return run_copy(action)
        except Exception as exc:
            print(f"{LOG_PREFIX} copy failed: {action['name']}: {exc!r}")
            if action.get("on_failure") == "CONTINUE":
                print(f"{LOG_PREFIX} continuing: {action['name']} is ActionOnFailure=CONTINUE")
                return f"failed-continue:{action['name']}"
            raise
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

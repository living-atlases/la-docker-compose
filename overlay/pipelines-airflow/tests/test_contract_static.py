"""
Contract test (static, no Airflow runtime) for the NO-AWS overlay.

Turns SILENT overlay drift into a LOUD failure. Run on every bump of the pinned
pipelines-airflow checkout:  python3 tests/test_contract_static.py

Checks:
  A. Variable fixture is in sync with the repo (no missing/extra Variable.get keys).
  B. Step translation rules hold (s3-dist-cp -> no-op; command-runner --cluster ->
     local; unknown jar -> raises, never silently skipped).
  C. sitecustomize actually swaps the 4 EMR classes when backend=local.
"""
import importlib.util
import json
import os
import re
import sys
import types

HERE = os.path.dirname(os.path.abspath(__file__))
OVERLAY = os.path.dirname(HERE)
# Default: the pipelines-airflow submodule at the la-docker-compose repo root
# (<repo>/pipelines-airflow). Override with PIPELINES_AIRFLOW_REPO to point at any
# other checkout.
REPO = os.environ.get(
    "PIPELINES_AIRFLOW_REPO",
    os.path.abspath(os.path.join(OVERLAY, "..", "..", "pipelines-airflow")),
)
sys.path.insert(0, OVERLAY)

failures = []


def check(name, cond, detail=""):
    print(("PASS" if cond else "FAIL"), "-", name, ("" if cond else f":: {detail}"))
    if not cond:
        failures.append(name)


# ---- A. Variable fixture in sync with the repo ------------------------------
needed = set()
for root, _, files in os.walk(os.path.join(REPO, "dags")):
    for f in files:
        if f.endswith(".py"):
            txt = open(os.path.join(root, f), encoding="utf-8").read()
            needed |= set(re.findall(r'Variable\.get\(\s*"([^"]+)"', txt))

fixture = json.load(open(os.path.join(OVERLAY, "variables", "airflow-variables.local.json")))
have = {k for k in fixture if not k.startswith("_")}
check("A. no Variables missing from fixture", not (needed - have), sorted(needed - have))
check("A. no stale Variables in fixture", not (have - needed), sorted(have - needed))

# ---- B. translation rules ---------------------------------------------------
from pa_local_compute import translate_step  # noqa: E402

s3_step = {"Name": "copy", "HadoopJarStep":
           {"Jar": "/usr/share/aws/emr/s3-dist-cp/lib/s3-dist-cp.jar",
            "Args": ["--src=s3://b/x", "--dest=hdfs:///x"]}}
cmd_step = {"Name": "sample", "HadoopJarStep":
            {"Jar": "command-runner.jar",
             "Args": ["bash", "-c", "la-pipelines sample all --cluster 1>&2"]}}
bad_step = {"Name": "weird", "HadoopJarStep": {"Jar": "mystery.jar", "Args": []}}
helper_step = {"Name": "Download data", "HadoopJarStep":
               {"Jar": "command-runner.jar",
                "Args": ["bash", "-c", "/tmp/download-datasets.sh dwca-imports pipelines-data dr-test"]}}

# s3-dist-cp is the bridge between MinIO (where the DAGs discover work) and the shared
# volume (where la-pipelines reads). No-op'ing it severs the two.
t_cp = translate_step(s3_step)
check("B. s3-dist-cp -> real copy", t_cp["kind"] == "copy", t_cp)
check("B. s3-dist-cp src/dest parsed",
      (t_cp["src"], t_cp["dest"]) == ("s3://b/x", "hdfs:///x"), t_cp)
check("B. s3->local is a download to the bare path",
      t_cp["plan"] == {"op": "download", "bucket": "b", "key": "x", "path": "/x"}, t_cp["plan"])
os.environ["PIPELINES_LOCAL_NOOP_COPIES"] = "1"
try:
    check("B. copies can still be forced back to no-op",
          translate_step(s3_step)["kind"] == "noop-copy")
finally:
    del os.environ["PIPELINES_LOCAL_NOOP_COPIES"]
t = translate_step(cmd_step)
check("B. command-runner -> local exec", t["kind"] == "exec")
# --embedded, not --local: `sample` (and uuid/image-sync/...) reject --local per the CLI.
check("B. --cluster rewritten to --embedded", t.get("cmd") == "la-pipelines sample all --embedded", t)
check("B. unknown jar flagged (not silently skipped)", translate_step(bad_step)["kind"] == "unknown")
check("B. bootstrap helper script -> no-op", translate_step(helper_step)["kind"] == "noop-script")

# Optional stage skipping: PIPELINES_SKIP_STAGES no-ops whole stages (e.g. `sds`
# when sensitive-data-service is not deployed) without touching pipelines-airflow.
sds_step = {"Name": "sds", "HadoopJarStep":
            {"Jar": "command-runner.jar",
             "Args": ["bash", "-c", "la-pipelines sds dr-test --cluster 1>&2"]}}
check("B. stage runs by default (no skip list)", translate_step(sds_step)["kind"] == "exec")
os.environ["PIPELINES_SKIP_STAGES"] = "sds"
try:
    check("B. PIPELINES_SKIP_STAGES no-ops the listed stage",
          translate_step(sds_step)["kind"] == "noop-stage")
    check("B. non-listed stage still runs under a skip list",
          translate_step(cmd_step)["kind"] == "exec")
finally:
    del os.environ["PIPELINES_SKIP_STAGES"]

# EMR steps arrive wrapped in `sudo -u hadoop`, and `emr_python_step` always does.
# Neither sudo nor the hadoop user exists in our containers, so the prefix has to go
# or every affected step dies with "command not found".
from pa_local_compute import build_argv, rewrite_staged_paths  # noqa: E402

sudo_step = {"Name": "commit", "HadoopJarStep":
             {"Jar": "command-runner.jar",
              "Args": ["bash", "-c", 'sudo -u hadoop curl -X POST "http://solr:8983/solr/x/update" 1>&2']}}
t_sudo = translate_step(sudo_step)
check("B. `sudo -u hadoop` stripped from the command",
      t_sudo["cmd"].startswith("curl -X POST"), t_sudo)

# la_pipelines has no python3; la_airflow does and reaches Solr on the same network.
py_step = {"Name": "create collection", "HadoopJarStep":
           {"Jar": "command-runner.jar",
            "Args": ["bash", "-c",
                     " sudo -u hadoop python3 /tmp/create_solr_collection_cli.py -s http://solr:8983/solr"
                     " -a create_solr_collection biocache-x 1>&2"]}}
t_py = translate_step(py_step)
check("B. python3 step routed to the Airflow container",
      t_py.get("container") == "la_airflow", t_py)
check("B. python3 step's argv targets that container",
      build_argv(t_py)[:3] == ["docker", "exec", "la_airflow"], build_argv(t_py))
# A non-python step must NOT be rerouted - it belongs in la_pipelines.
check("B. non-python step stays on the pipelines container",
      "container" not in translate_step(cmd_step)
      and build_argv(translate_step(cmd_step))[:3] == ["docker", "exec", "la_pipelines"])

# EMR stages these CLIs into /tmp via BootstrapActions, which our local shim has no
# cluster to run. We mount the dags/ tree instead and repoint the reference.
os.environ["PA_DAGS_DIR"] = os.path.join(REPO, "dags")
try:
    check("B. /tmp CLI reference repointed at the mounted dags tree",
          rewrite_staged_paths("python3 /tmp/create_solr_collection_cli.py -a create")
          == f"python3 {os.path.join(REPO, 'dags', 'create_solr_collection_cli.py')} -a create")
    check("B. /tmp reference to a dags/sh/ helper repointed too",
          rewrite_staged_paths("bash /tmp/download-datasets-for-indexing.sh")
          == f"bash {os.path.join(REPO, 'dags', 'sh', 'download-datasets-for-indexing.sh')}")
    # Anything we do not ship must be left alone rather than silently redirected.
    check("B. unknown /tmp path left untouched",
          rewrite_staged_paths("cat /tmp/scratch-file.txt") == "cat /tmp/scratch-file.txt")
finally:
    del os.environ["PA_DAGS_DIR"]

# EMR steps declare what a failure means; the DAGs mark optional copies/cleanups
# CONTINUE. Ignoring that made every optional step a hard stop.
from pa_local_compute import run_local_step  # noqa: E402

fail_cmd = "exit 3"
continue_step = {"Name": "optional cleanup", "ActionOnFailure": "CONTINUE",
                 "HadoopJarStep": {"Jar": "command-runner.jar",
                                   "Args": ["bash", "-c", fail_cmd]}}
abort_step = {"Name": "required", "ActionOnFailure": "TERMINATE_CLUSTER",
              "HadoopJarStep": {"Jar": "command-runner.jar",
                                "Args": ["bash", "-c", fail_cmd]}}
check("B. ActionOnFailure carried onto the action",
      translate_step(continue_step).get("on_failure") == "CONTINUE")
os.environ["PIPELINES_LOCAL_BIN"] = "1"   # run in-process, no docker needed
try:
    try:
        res = run_local_step(translate_step(continue_step))
    except Exception as exc:            # regression: CONTINUE ignored -> hard stop
        res = f"raised {exc!r}"
    check("B. CONTINUE step does not abort the run",
          isinstance(res, str) and res.startswith("failed-continue:"), res)
    raised = False
    try:
        run_local_step(translate_step(abort_step))
    except Exception:
        raised = True
    check("B. non-CONTINUE step still raises on failure", raised)
finally:
    del os.environ["PIPELINES_LOCAL_BIN"]

from pa_local_compute import plan_copy, local_path, run_local_step as _rls  # noqa: E402

check("B. hdfs:// authority stripped", local_path("hdfs://nn:8020/pipelines-outlier") == "/pipelines-outlier")
check("B. hdfs:/// stripped", local_path("hdfs:///pipelines-all-datasets") == "/pipelines-all-datasets")
check("B. bare local path untouched", local_path("/data/la-pipelines") == "/data/la-pipelines")
check("B. local->s3 is an upload",
      plan_copy("hdfs:///pipelines-outlier", "s3://avro/pipelines-outlier")
      == {"op": "upload", "bucket": "avro", "key": "pipelines-outlier", "path": "/pipelines-outlier"})
check("B. local->local copy recognised",
      plan_copy("hdfs:///a", "/b") == {"op": "local", "src": "/a", "dest": "/b"})
check("B. s3->s3 flagged unsupported", plan_copy("s3://a/x", "s3://b/y")["op"] == "unsupported")

# A real local->local copy, end to end (no boto3, no MinIO needed).
import shutil as _sh, tempfile as _tf  # noqa: E402
_tmp = _tf.mkdtemp()
# The copy hands ownership to the pipelines uid via `docker exec`; irrelevant here and
# there is no docker in the unit-test environment.
os.environ["PIPELINES_SKIP_CHOWN"] = "1"
try:
    os.makedirs(os.path.join(_tmp, "src", "nested"))
    open(os.path.join(_tmp, "src", "nested", "a.avro"), "w").write("x")
    cp_step = {"Name": "copy avro", "HadoopJarStep":
               {"Jar": "/usr/share/aws/emr/s3-dist-cp/lib/s3-dist-cp.jar",
                "Args": [f"--src=hdfs://{_tmp}/src", f"--dest={_tmp}/dst"]}}
    _rls(translate_step(cp_step))
    check("B. copy actually moves the files",
          os.path.exists(os.path.join(_tmp, "dst", "nested", "a.avro")))
finally:
    _sh.rmtree(_tmp, ignore_errors=True)
    del os.environ["PIPELINES_SKIP_CHOWN"]

# ---- C. sitecustomize swaps the 4 EMR classes -------------------------------
def _mod(name):
    m = types.ModuleType(name); sys.modules[name] = m; return m

class _FakeBaseOperator:
    def __init__(self, task_id=None, dag=None, **kwargs):
        self.task_id = task_id

_mod("airflow"); _mod("airflow.models")
_mod("airflow.models.baseoperator").BaseOperator = _FakeBaseOperator
_mod("airflow.providers"); _mod("airflow.providers.amazon")
_mod("airflow.providers.amazon.aws"); _mod("airflow.providers.amazon.aws.operators")
_mod("airflow.providers.amazon.aws.sensors")
ops = _mod("airflow.providers.amazon.aws.operators.emr")
sen = _mod("airflow.providers.amazon.aws.sensors.emr")
ops.EmrCreateJobFlowOperator = type("EmrCreateJobFlowOperator", (), {})
ops.EmrAddStepsOperator = type("EmrAddStepsOperator", (), {})
sen.EmrStepSensor = type("EmrStepSensor", (), {})
sen.EmrJobFlowSensor = type("EmrJobFlowSensor", (), {})

os.environ["PIPELINES_COMPUTE_BACKEND"] = "local"
_spec = importlib.util.spec_from_file_location("overlay_sitecustomize",
                                               os.path.join(OVERLAY, "sitecustomize.py"))
_sc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_sc)

check("C. EmrCreateJobFlowOperator swapped", ops.EmrCreateJobFlowOperator.__name__ == "LocalCreateJobFlowOperator")
check("C. EmrAddStepsOperator swapped", ops.EmrAddStepsOperator.__name__ == "LocalAddStepsOperator")
check("C. EmrStepSensor swapped", sen.EmrStepSensor.__name__ == "LocalStepSensor")
check("C. EmrJobFlowSensor swapped", sen.EmrJobFlowSensor.__name__ == "LocalJobFlowSensor")

# These three assert the SHIM wiring (class swap + how `steps` is parsed), not what a
# step does. Force copies back to no-op so the subject stays the wiring and the check
# needs neither boto3 nor a MinIO.
os.environ["PIPELINES_LOCAL_NOOP_COPIES"] = "1"

add = ops.EmrAddStepsOperator(task_id="add_steps", job_flow_id="x",
                              aws_conn_id="aws_default", steps=[s3_step])
check("C. shim runs a no-op step end to end", add.execute(context={}) == ["noop:copy"])

# steps can arrive as a JSON string (templated XCom rendered to str) — must be parsed,
# not iterated char by char ('str' object has no attribute 'get'). Regression guard.
add_str = ops.EmrAddStepsOperator(task_id="add_steps2", job_flow_id="x",
                                  aws_conn_id="aws_default", steps=json.dumps([s3_step]))
check("C. steps-as-JSON-string is parsed (not iterated)", add_str.execute(context={}) == ["noop:copy"])

# Airflow's non-native templating renders `steps` to a PYTHON repr (single-quoted
# dicts), which is NOT valid JSON — must still parse. Regression guard for #278.
add_repr = ops.EmrAddStepsOperator(task_id="add_steps3", job_flow_id="x",
                                   aws_conn_id="aws_default", steps=str([s3_step]))
check("C. steps-as-python-repr is parsed", add_repr.execute(context={}) == ["noop:copy"])
del os.environ["PIPELINES_LOCAL_NOOP_COPIES"]

# ---- D. notifications cluster policy (opt-in, no-op by default) -------------
import airflow_local_settings as _notify  # noqa: E402

class _Dummy:
    on_failure_callback = None
    on_success_callback = None

for _k in ("NOTIFICATIONS_ENABLED", "TELEGRAM_BOT_TOKEN", "SLACK_WEBHOOK_URL"):
    os.environ.pop(_k, None)
_t, _d = _Dummy(), _Dummy()
_notify.task_policy(_t); _notify.dag_policy(_d)
check("D. no-op without creds/flag", _t.on_failure_callback is None and _d.on_success_callback is None)

os.environ["NOTIFICATIONS_ENABLED"] = "true"
try:
    _t2, _d2 = _Dummy(), _Dummy()
    _notify.task_policy(_t2); _notify.dag_policy(_d2)
    check("D. attaches callbacks when enabled",
          callable(_t2.on_failure_callback) and callable(_d2.on_success_callback))
finally:
    del os.environ["NOTIFICATIONS_ENABLED"]

print()
if failures:
    print(f"CONTRACT FAILED: {len(failures)} check(s) -> {failures}")
    sys.exit(1)
print("CONTRACT OK — overlay in sync with pinned pipelines-airflow")

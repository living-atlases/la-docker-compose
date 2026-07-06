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

check("B. s3-dist-cp -> no-op", translate_step(s3_step)["kind"] == "noop-copy")
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

"""
pipelines-airflow NO-AWS overlay — bootstrap  (drop-in, zero DAG edits)
======================================================================

CPython auto-runs this at interpreter startup if it is on PYTHONPATH. When
PIPELINES_COMPUTE_BACKEND=local it swaps the four AWS EMR operator/sensor classes
for local shims BEFORE Airflow parses any DAG, so the DAGs' `from ...emr import X`
transparently binds the shims. Translation logic lives in pa_local_compute.py
(Airflow-free, unit-tested). See README.md / SPIKE_RESULTS.md.
"""
import json
import os
import sys

if os.environ.get("PIPELINES_COMPUTE_BACKEND", "").lower() == "local":
    try:
        import inspect
        from airflow.models.baseoperator import BaseOperator
        from pa_local_compute import translate_step, run_local_step, LOG_PREFIX

        class _ShimBase(BaseOperator):
            """Accept any EMR-operator kwargs; forward only valid BaseOperator ones."""
            def __init__(self, *args, **kwargs):
                # Keep `steps` under its real attribute name so template_fields can
                # render it: the DAG passes steps as a Jinja/XCom expression
                # ("{{ ti.xcom_pull('construct_steps') }}") that the real
                # EmrAddStepsOperator renders via template_fields. Our swap must keep
                # that, or execute() iterates the raw string -> 'str' has no .get.
                self.steps = kwargs.get("steps", [])
                valid = set(inspect.signature(BaseOperator.__init__).parameters)
                super().__init__(**{k: v for k, v in kwargs.items() if k in valid})

        class LocalCreateJobFlowOperator(_ShimBase):
            def execute(self, context):
                print(f"{LOG_PREFIX} (no EMR cluster created)")
                return "local-cluster"

        def _apply_runtime_skip(context):
            """Let a run choose which stages to no-op WITHOUT redeploying: the
            `Ingest_small_datasets` sds stage, say, when sensitive-data-service is
            absent. Precedence: DAG run conf `pipelines_skip_stages` > Airflow
            Variable `pipelines_skip_stages` > whatever PIPELINES_SKIP_STAGES the
            container was started with. Read lazily so the Airflow-free unit test
            (fake airflow.models) never trips over the Variable import."""
            try:
                dr = context.get("dag_run") if context else None
                conf = (getattr(dr, "conf", None) or {})
                val = conf.get("pipelines_skip_stages")
                if val is None:
                    from airflow.models import Variable
                    val = Variable.get("pipelines_skip_stages", default_var="")
                if val:
                    os.environ["PIPELINES_SKIP_STAGES"] = val
            except Exception as exc:
                print(f"{LOG_PREFIX} skip-stage override unavailable: {exc!r}")

        class LocalAddStepsOperator(_ShimBase):
            # Render the templated `steps` (Jinja/XCom) before execute, like the real
            # operator — without this the swap drops templating and steps stays a string.
            template_fields = ("steps",)

            def execute(self, context):
                _apply_runtime_skip(context)
                steps = self.steps
                if isinstance(steps, str):
                    # Airflow renders the templated `steps` to a string. Without native
                    # templating that is a PYTHON repr of the list (single-quoted dicts),
                    # not JSON. Parse Python literals safely (literals only, never code),
                    # falling back to JSON.
                    import ast
                    _parse = ast.literal_eval  # safe: literals only, not arbitrary code
                    try:
                        steps = _parse(steps)
                    except (ValueError, SyntaxError):
                        steps = json.loads(steps)
                return [run_local_step(translate_step(s)) for s in steps] or ["local-step-0"]

        class LocalStepSensor(_ShimBase):
            def execute(self, context):
                return True

        class LocalJobFlowSensor(_ShimBase):
            def execute(self, context):
                return True

        import airflow.providers.amazon.aws.operators.emr as _ops
        import airflow.providers.amazon.aws.sensors.emr as _sen
        _ops.EmrCreateJobFlowOperator = LocalCreateJobFlowOperator
        _ops.EmrAddStepsOperator = LocalAddStepsOperator
        _sen.EmrStepSensor = LocalStepSensor
        _sen.EmrJobFlowSensor = LocalJobFlowSensor
        # Startup banner MUST go to stderr: it fires on every python invocation in the
        # container (sitecustomize runs at interpreter start), so on stdout it pollutes
        # anything that captures a command's output — e.g. `airflow dags list-runs -o json`
        # or the e2e harness's Solr/biocache count queries.
        print(f"{LOG_PREFIX} EMR operators swapped for local shims", file=sys.stderr)
    except Exception as exc:  # never break interpreter startup
        print(f"[no-aws-overlay] NOT activated: {exc!r}", file=sys.stderr)

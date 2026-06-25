"""
pipelines-airflow NO-AWS overlay — bootstrap  (drop-in, zero DAG edits)
======================================================================

CPython auto-runs this at interpreter startup if it is on PYTHONPATH. When
PIPELINES_COMPUTE_BACKEND=local it swaps the four AWS EMR operator/sensor classes
for local shims BEFORE Airflow parses any DAG, so the DAGs' `from ...emr import X`
transparently binds the shims. Translation logic lives in pa_local_compute.py
(Airflow-free, unit-tested). See README.md / SPIKE_RESULTS.md.
"""
import os

if os.environ.get("PIPELINES_COMPUTE_BACKEND", "").lower() == "local":
    try:
        import inspect
        from airflow.models.baseoperator import BaseOperator
        from pa_local_compute import translate_step, run_local_step, LOG_PREFIX

        class _ShimBase(BaseOperator):
            """Accept any EMR-operator kwargs; forward only valid BaseOperator ones."""
            def __init__(self, *args, **kwargs):
                self._steps = kwargs.get("steps", [])
                valid = set(inspect.signature(BaseOperator.__init__).parameters)
                super().__init__(**{k: v for k, v in kwargs.items() if k in valid})

        class LocalCreateJobFlowOperator(_ShimBase):
            def execute(self, context):
                print(f"{LOG_PREFIX} (no EMR cluster created)")
                return "local-cluster"

        class LocalAddStepsOperator(_ShimBase):
            def execute(self, context):
                return [run_local_step(translate_step(s)) for s in self._steps] or ["local-step-0"]

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
        print(f"{LOG_PREFIX} EMR operators swapped for local shims")
    except Exception as exc:  # never break interpreter startup
        print(f"[no-aws-overlay] NOT activated: {exc!r}")

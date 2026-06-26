"""
Contract test (DAG-level) — run INSIDE the Airflow container (deps + Variables present):

    docker compose ... exec airflow-scheduler python /opt/overlay/tests/test_dags_no_emr.py

Asserts, with the overlay active (PIPELINES_COMPUTE_BACKEND=local):
  1. Every DAG imports cleanly (Variables seeded, overlay didn't break parsing).
  2. NO real AWS EMR operator/sensor survives in any task — they were all swapped
     for Local* shims. A surviving Emr* class means the overlay drifted and would
     try to hit AWS at runtime.
"""
import sys
from airflow.models import DagBag

db = DagBag(dag_folder="/opt/airflow/dags", include_examples=False)

ok = True

if db.import_errors:
    ok = False
    print(f"FAIL - {len(db.import_errors)} DAG import error(s):")
    for path, err in db.import_errors.items():
        print("  ", path, "->", str(err).splitlines()[-1])
else:
    print(f"PASS - {len(db.dags)} DAGs imported, no errors")

surviving = []
shims = 0
for dag_id, dag in db.dags.items():
    for t in dag.tasks:
        cls = type(t).__name__
        if cls.startswith("Local") and cls.endswith(("Operator", "Sensor")):
            shims += 1
        if cls.startswith("Emr"):  # real provider class still present
            surviving.append((dag_id, t.task_id, cls))

if surviving:
    ok = False
    print(f"FAIL - {len(surviving)} real EMR task(s) survived the swap:")
    for d, tid, cls in surviving[:20]:
        print(f"   {d}.{tid} -> {cls}")
else:
    print(f"PASS - no real EMR operator survived (overlay shims in use: {shims} tasks)")

print()
print("CONTRACT OK" if ok else "CONTRACT FAILED")
sys.exit(0 if ok else 1)

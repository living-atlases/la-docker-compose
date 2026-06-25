#!/usr/bin/env bash
# Run the DAG-level contract test inside the running Airflow scheduler container.
# Usage:  ./run-in-airflow.sh [compose-project-or-service]
set -euo pipefail
SERVICE="${1:-airflow-scheduler}"
docker compose -f ../compose/docker-compose.airflow.yml exec -T "$SERVICE" \
  python /opt/overlay/tests/test_dags_no_emr.py

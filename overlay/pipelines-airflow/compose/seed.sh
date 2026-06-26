#!/usr/bin/env bash
# One-shot init for the NO-AWS overlay: Airflow DB + Variables + Connections + MinIO buckets.
set -euo pipefail

echo "==> airflow db migrate"
airflow db migrate

echo "==> create admin user (admin/admin)"
airflow users create --username admin --password admin \
  --firstname a --lastname a --role Admin --email admin@example.org || true

echo "==> import Airflow Variables"
airflow variables import /opt/overlay/variables/airflow-variables.local.json

# Dummy AWS/EMR connections so operators that still construct them don't fail at
# import/build time. The overlay shims ignore them at execute time.
echo "==> create dummy aws_default / emr_default connections"
airflow connections delete aws_default >/dev/null 2>&1 || true
airflow connections add aws_default --conn-type aws \
  --conn-login minioadmin --conn-password minioadmin \
  --conn-extra '{"endpoint_url":"http://minio:9000","region_name":"us-east-1"}' || true
airflow connections add emr_default --conn-type emr --conn-extra '{}' || true

# Create the MinIO buckets the DAGs expect (names from airflow-variables.local.json).
echo "==> create MinIO buckets"
python3 - <<'PY'
import os, boto3
from botocore.exceptions import ClientError
s3 = boto3.client("s3")
for b in ["pipelines-config","pipelines-data","dwca-imports","dwca-exports",
          "ala-uploaded","pipelines-backup","sds"]:
    try:
        s3.create_bucket(Bucket=b); print("  created", b)
    except ClientError as e:
        print("  skip", b, e.response["Error"]["Code"])
PY

echo "==> overlay init done"

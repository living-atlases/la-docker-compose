"""
NO-AWS overlay — generic, provider-agnostic task/DAG notifications.

Airflow auto-imports `airflow_local_settings` from PYTHONPATH (the overlay puts
/opt/overlay on it, same as sitecustomize.py). We attach notifications to EVERY
DAG/task via cluster policies, WITHOUT touching the unmodified pipelines-airflow
DAGs (their Slack path stays off via SLACK_NOTIFICATION=false):
  - task_policy -> on_failure_callback  (per failed task, like ALA's slack_alert)
  - dag_policy  -> on_success_callback  (per successful DAG run, like ALA's
                   get_success_notification_operator)

Provider is auto-detected from env (drop creds in .env-custom -> the overlay
compose passes them through):
  - TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID -> Telegram sendMessage
  - SLACK_WEBHOOK_URL                     -> Slack incoming webhook
  - neither (or NOTIFICATIONS_ENABLED not truthy) -> no-op

Dependency-free (urllib) and failure-tolerant: a notifier error must never fail
the task/DAG or Airflow startup.
"""
import json
import os
import urllib.request

LOG_PREFIX = "[no-aws-overlay:notify]"

_TRUTHY = ("1", "true", "yes", "on")


def _enabled():
    v = os.environ.get("NOTIFICATIONS_ENABLED", "").strip().lower()
    if v in _TRUTHY:
        return True
    if v in ("0", "false", "no", "off"):
        return False
    # unset -> auto-enable when any provider credential is present
    return bool(os.environ.get("TELEGRAM_BOT_TOKEN") or os.environ.get("SLACK_WEBHOOK_URL"))


def _post(url, payload):
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(), method="POST",
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return r.status


def _send(text):
    tok = os.environ.get("TELEGRAM_BOT_TOKEN")
    chat = os.environ.get("TELEGRAM_CHAT_ID")
    hook = os.environ.get("SLACK_WEBHOOK_URL")
    try:
        if tok and chat:
            _post("https://api.telegram.org/bot{}/sendMessage".format(tok),
                  {"chat_id": chat, "text": text, "disable_web_page_preview": True})
        elif hook:
            _post(hook, {"text": text})
    except Exception as exc:  # never propagate a notification failure
        print("{} send failed: {!r}".format(LOG_PREFIX, exc))


def _msg(context, status):
    ti = context.get("task_instance") or context.get("ti")
    dag_id = getattr(context.get("dag"), "dag_id", "?")
    run_id = getattr(context.get("dag_run"), "run_id", "?")
    task_id = getattr(ti, "task_id", "-")
    label = os.environ.get("PIPELINES_ENV_LABEL", "").strip()
    head = "{} {}".format(status, label).strip()
    return "{}\nDAG: {}\nrun: {}\ntask: {}".format(head, dag_id, run_id, task_id)


def _on_failure(context):
    if _enabled():
        _send("❌ " + _msg(context, "FAILED"))


def _on_success(context):
    if _enabled():
        _send("✅ " + _msg(context, "SUCCESS"))


def task_policy(task):
    """Per-task failure notice (mirrors ALA's on_failure_callback in get_default_args)."""
    if _enabled():
        task.on_failure_callback = _on_failure


def dag_policy(dag):
    """Per-DAG-run success notice (mirrors ALA's get_success_notification_operator)."""
    if _enabled():
        dag.on_success_callback = _on_success

#!/usr/bin/env bash
# pg_dump must never be told to write into the dump directory of the ssh user.
#
# portal-migrate-fetch.yml runs as the ssh user and creates /tmp/la-migration-<ts>
# with mode 0700. The PostgreSQL block, and only that block, runs as the postgres
# OS user (peer auth on the unix socket), so it cannot write there:
#
#     TASK [Migration fetch: dump each PostgreSQL database]
#     pg_dump: error: could not open output file
#              "/tmp/la-migration-20261116T184651Z/postgres-doi.dump": Permission denied
#
# gbif.es hit it on 2026-11-16 moving doi off its VM: the MySQL half had already
# dumped, the play died before the fetch, and the dump set came back empty. The fix
# is NOT to widen that directory — the same set can carry a CAS user store with
# password hashes — but to let postgres dump into a directory of its own, which root
# then empties into the shared one.
#
# Asserted here:
#   - no task running as the postgres user names the shared directory;
#   - the staged files are handed over with an explicit owner, and the staging
#     directory is removed.
#
# Pure parsing: no ansible, no Docker, no inventory. Runs in the unit stage.
set -u
cd "$(dirname "$0")/.."
PB=playbooks/portal-migrate-fetch.yml
[[ -f $PB ]] || { printf '[FAIL] not found: %s\n' "$PB" >&2; exit 1; }

python3 - "$PB" <<'PY'
import sys, re
try:
    import yaml
except ImportError:
    print("[SKIP] PyYAML not available"); sys.exit(0)

path = sys.argv[1]
plays = yaml.safe_load(open(path))
rc = 0
shared = "migration_tmp"
staging = "migration_pg_tmp"

def walk(task, inherited):
    """Yield (task, become_user in effect) over blocks."""
    bu = task.get("become_user", inherited)
    if "block" in task:
        for t in task["block"]:
            yield from walk(t, bu)
    else:
        yield task, bu

def refs(task):
    return re.findall(r"\{\{\s*(migration_(?:pg_)?tmp)\s*\}\}", yaml.safe_dump(task))

pg_tasks = handover = cleanup = staged_from = 0
for play in plays:
    for top in play.get("tasks", []):
        for task, bu in walk(top, None):
            name = task.get("name", "")
            used = refs(task)
            if bu and "postgres_os_user" in str(bu):
                pg_tasks += 1
                if shared in used:
                    print("[FAIL] %r runs as the postgres user and writes into {{ %s }}:"
                          " pg_dump cannot write there (0700, owned by the ssh user)"
                          % (name, shared), file=sys.stderr)
                    rc = 1
            else:
                copy = task.get("ansible.builtin.copy", {})
                if copy.get("remote_src") and shared in used:
                    handover += 1
                    if not copy.get("owner"):
                        print("[FAIL] %r moves the staged dumps without an explicit owner:"
                              " root-owned files are unreadable for the fetch that follows"
                              % name, file=sys.stderr)
                        rc = 1
                if staging in used and "ansible.builtin.find" in task:
                    staged_from += 1
            if staging in used and task.get("ansible.builtin.file", {}).get("state") == "absent":
                cleanup += 1

if pg_tasks == 0:
    print("[FAIL] no task runs as the postgres user: the check is broken, not the playbook",
          file=sys.stderr); rc = 1
if handover == 0 or staged_from == 0:
    print("[FAIL] nothing collects the staged PostgreSQL dumps into {{ %s }}: the set would"
          " reach the controller without them" % shared, file=sys.stderr); rc = 1
if cleanup == 0:
    print("[FAIL] the PostgreSQL staging directory is never removed: dumps left behind on"
          " a production VM", file=sys.stderr); rc = 1
if rc == 0:
    print("[PASS] pg_dump writes to its own staging directory (%d postgres tasks),"
          " handed over with an owner and cleaned up" % pg_tasks)
sys.exit(rc)
PY

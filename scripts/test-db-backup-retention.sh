#!/usr/bin/env bash
# infrastructure/db-backup.yml.j2: la_db-backup deletes old dumps, on the image it really runs.
# nfrastack/db-backup 5.0.2 never reads DEFAULT_CLEANUP_TIME, so a portal's dumps piled up for
# as long as the container lived, while the template said six days. Only the image can tell,
# so this renders the real template and runs its environment on it:
#   - every DBnn job has its own DBnn_CLEANUP_TIME (db_cleanup_time reaches all of them);
#   - on the pinned tag and on 5.0.7, each job in the generated config has a retention;
#   - with a real postgres, a successful job deletes the dumps past the window, keeps those
#     inside it and leaves other files alone, and one new dump holds every database.
# The mongo and mysql jobs fail here, as on a host that lacks those databases: pruning by the
# one job that works must still happen. ~1 min with Docker (pulls once), the render alone without.
set -u
cd "$(dirname "$0")/.."
PY="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}python3"
command -v "$PY" >/dev/null || PY=python3
T=$(mktemp -d)
N="la-test-dbb-$$"
cleanup() {
  docker rm -f "$N-pg" "$N-bk" >/dev/null 2>&1
  docker volume rm "$N" >/dev/null 2>&1
  docker network rm "$N" >/dev/null 2>&1
  rm -rf "$T"
}
trap cleanup EXIT
fail=0
pass() { printf '[PASS] %s\n' "$*"; }
bad()  { printf '[FAIL] %s\n' "$*" >&2; fail=1; }
EXTRA_TAG=5.0.7     # what a portal may override db_backup_version to
PG_IMAGE=postgres:17-alpine

"$PY" - "$T" <<'PY' || { echo "[FAIL] the rendered db-backup.yml does not ask each job to clean up" >&2; exit 1; }
import re, sys, jinja2, yaml
from ansible.plugins.filter.core import FilterModule as Core
out = sys.argv[1]
e = jinja2.Environment(loader=jinja2.FileSystemLoader("roles/la-compose/templates/docker-compose/infrastructure"),
                       trim_blocks=True)
e.filters["to_json"] = Core().filters()["to_json"]
need = {"collectory_db_host_address": "mysql", "mongodb_root_username": "root", "docker_extra_hosts_dict": {}}

def render(**v):
    service = yaml.safe_load(e.get_template("db-backup.yml.j2").render(need, **v))["services"]["db-backup"]
    return service["image"], dict(x.split("=", 1) for x in service["environment"])

image, env = render()
jobs = sorted(k[:4] for k in env if re.fullmatch(r"DB\d\d_TYPE", k))
assert len(jobs) == 3, jobs
for job in jobs:
    assert env.get(f"{job}_CLEANUP_TIME") == "8640", f"{job} has no cleanup time of its own"
assert "DEFAULT_CLEANUP_TIME" not in env, "DEFAULT_CLEANUP_TIME is back: the pinned image ignores it"
for job in ("DB02", "DB03"):
    assert env.get(f"{job}_SPLIT_DB") == "FALSE", f"{job} would split into one file per database"
_, env = render(db_cleanup_time="2880")
assert {env[f"{job}_CLEANUP_TIME"] for job in jobs} == {"2880"}, "db_cleanup_time does not reach every job"

# Start now, not at the next midnight (5.0.7 honours the begin time).
_, env = render(db_backup_begin="+0", postgres_user="postgres")
with open(f"{out}/env", "w") as f:
    for k, v in env.items():
        f.write(f"{k}={re.sub(r'[$][{][A-Z_]+[}]', 'secret', v)}\n")
open(f"{out}/tag", "w").write(image.rsplit(":", 1)[1])
PY
pass "every job has a cleanup time, and db_cleanup_time reaches all of them"

if ! docker info >/dev/null 2>&1; then
  echo "[SKIP] no Docker: the image was not asked"
  exit "$fail"
fi

# The name the image gives a dump this many days old.
dump_at() { echo "$1-full-$(date -u -d "$2 days ago" +%Y%m%d-%H%M%S).$3.zst"; }

# A registry hiccup must not look like a broken seed: pull on its own, retry, and keep the reason.
PULL_ERR=
pull_retry() {
  local i
  for i in 1 2 3; do
    PULL_ERR=$(docker pull -q "$1" 2>&1 >/dev/null) && return 0
    sleep $((i * 10))
  done
  return 1
}

try_tag() {
  local tag=$1 i
  local too_old_mysql too_old_mongo too_old_pg recent
  too_old_mysql=$(dump_at mysql-ALL-mysql 19 sql)
  too_old_mongo=$(dump_at mongo-admin-mongodb 7 mongo)
  too_old_pg=$(dump_at postgres-ALL-postgres 46 sql)
  recent=$(dump_at mysql-ALL-mysql 5 sql)
  docker rm -f "$N-pg" "$N-bk" >/dev/null 2>&1
  docker volume rm "$N" >/dev/null 2>&1
  docker volume create "$N" >/dev/null
  pull_retry "nfrastack/db-backup:$tag" || { bad "$tag: could not pull nfrastack/db-backup:$tag (3 tries): $PULL_ERR"; return; }
  pull_retry "$PG_IMAGE" || { bad "$tag: could not pull $PG_IMAGE (3 tries): $PULL_ERR"; return; }
  local err
  err=$(docker run --rm -v "$N:/backup" --entrypoint /bin/sh "nfrastack/db-backup:$tag" -c "
    cd /backup && touch $too_old_mysql $too_old_mongo $too_old_pg $recent not-a-dump.tgz
    chown 10000:10000 . * && chmod 700 ." 2>&1 >/dev/null) || { bad "$tag: could not seed /backup: $err"; return; }

  docker run -d --name "$N-pg" --network "$N" --network-alias postgres \
    -e POSTGRES_PASSWORD=secret "$PG_IMAGE" >/dev/null
  for i in $(seq 1 60); do
    docker exec "$N-pg" psql -U postgres -h 127.0.0.1 -qc "SELECT 1" >/dev/null 2>&1 && break
    sleep 1
  done
  docker exec "$N-pg" psql -U postgres -h 127.0.0.1 -qc "CREATE DATABASE demo" >/dev/null
  docker exec "$N-pg" psql -U postgres -h 127.0.0.1 -d demo \
    -qc "CREATE TABLE marker AS SELECT 'dump-marker-row'::text AS v" >/dev/null

  docker run -d --name "$N-bk" --network "$N" -v "$N:/backup" --env-file "$T/env" \
    "nfrastack/db-backup:$tag" >/dev/null
  local cfg
  for i in $(seq 1 60); do
    docker exec "$N-bk" cat /logs/dbbackup.log 2>/dev/null \
      | grep -q 'action=backup job=db03.*status=finished' && break
    sleep 1
  done
  cfg=$(docker exec "$N-bk" cat /config/db-backup.yml 2>/dev/null)
  local count
  count=$(printf '%s\n' "$cfg" | grep -c 'within: 8640m')
  [ "$count" = 3 ] && pass "$tag: all 3 jobs have a retention" \
    || bad "$tag: $count of 3 jobs have a retention"

  local files
  files=$(docker exec "$N-bk" ls -1 /backup 2>/dev/null)
  for f in "$too_old_mysql" "$too_old_mongo" "$too_old_pg"; do
    printf '%s\n' "$files" | grep -qxF "$f" && bad "$tag: $f outlived the window" \
      || pass "$tag: $f was deleted"
  done
  printf '%s\n' "$files" | grep -qxF "$recent" && pass "$tag: the dump inside the window stays" \
    || bad "$tag: the dump inside the window was deleted"
  printf '%s\n' "$files" | grep -qxF not-a-dump.tgz && pass "$tag: other files stay" \
    || bad "$tag: not-a-dump.tgz was deleted"

  # The seeds are empty, so what has content is what this run wrote.
  local new
  new=$(docker exec "$N-bk" sh -c 'for f in /backup/postgres-*; do [ -s "$f" ] && basename "$f"; done' 2>/dev/null)
  case "$new" in
    '' | *$'\n'*) bad "$tag: expected one new dump, got: ${new:-none}" ;;
    *) pass "$tag: one dump for the whole server: $new" ;;
  esac
  docker exec "$N-bk" sh -c 'for f in /backup/postgres-*; do zstd -dc "$f"; done' 2>/dev/null \
    | grep -q dump-marker-row && pass "$tag: the new dump holds the user database" \
    || bad "$tag: no dump holds the user database"
}

pinned=$(cat "$T/tag")
docker network create "$N" >/dev/null
try_tag "$pinned"
[ "$pinned" = "$EXTRA_TAG" ] || try_tag "$EXTRA_TAG"
exit "$fail"

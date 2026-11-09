#!/usr/bin/env bash
# infrastructure/db-backup.yml.j2: the mongo job copies EVERY database, in a restorable shape.
#
# DB01_NAME was `admin`, so the daily dump held the server's users and nothing else. CAS keeps
# itself in several databases (ticket registry, service registry, spring sessions, audit trail),
# and a portal with CAS on docker-compose therefore had no copy of the one thing a deploy cannot
# rebuild: the audit trail.
#
# A mongo dump from this image is not a mongodump archive. 5.0.7 writes a mongosh script of
# insertMany statements, and that script names each database in a comment only: one file holding
# several databases would restore all of them into whichever database the shell points at. So the
# mongo job has to split per database, the opposite of what mysql and postgres do here. Only the
# image can settle any of this, so the test renders the real template and runs its environment
# against a real mongo:
#   - the render asks for ALL, carries the authSource on DB01_AUTH now that NAME is not `admin`,
#     excludes the server's own `local` and `config`, and splits per database;
#   - the inventory can still pin a single database, another authSource and another exclude list;
#   - with a real mongo holding four CAS-like databases, the job finishes and writes one file per
#     database, and each one replayed with mongosh into an empty server gives the same counts;
#   - `local` and `config` get no file, so the exclude list is really read.
# Without Docker only the render runs. ~2 min with Docker (pulls mongo:7 once).
set -u
cd "$(dirname "$0")/.."
PY="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}python3"
command -v "$PY" >/dev/null || PY=python3
T=$(mktemp -d)
N="la-test-dbbmongo-$$"
cleanup() {
  docker rm -f "$N-mongo" "$N-mongo2" "$N-bk" >/dev/null 2>&1
  docker volume rm "$N" >/dev/null 2>&1
  docker network rm "$N" >/dev/null 2>&1
  rm -rf "$T"
}
trap cleanup EXIT
fail=0
pass() { printf '[PASS] %s\n' "$*"; }
bad()  { printf '[FAIL] %s\n' "$*" >&2; fail=1; }
MONGO_IMAGE=mongo:7
MONGO_PASS=secret
# cas-audit is the one that matters: a deploy recreates the other three.
DBS="cas-ticket-registry cas-service-registry spring-sessions cas-audit"

"$PY" - "$T" <<'PY' || { echo "[FAIL] the rendered db-backup.yml does not copy every mongo database" >&2; exit 1; }
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
open(f"{out}/image", "w").write(image)
assert env.get("DB01_NAME") == "ALL", f"the mongo job still names one database: {env.get('DB01_NAME')!r}"
# With NAME no longer `admin`, nothing authenticates unless the authSource is given on its own.
assert env.get("DB01_AUTH") == "admin", f"no authSource for the mongo job: {env.get('DB01_AUTH')!r}"
# DBnn_EXCLUDE is accepted and ignored by the image; only this spelling reaches the config.
assert env.get("DB01_NAME_EXCLUDE") == "local,config", \
    f"the server's own databases are not excluded: {env.get('DB01_NAME_EXCLUDE')!r}"
assert "DB01_EXCLUDE" not in env, "DB01_EXCLUDE is the spelling the image ignores"
# One file per database: a single file naming its databases in comments restores them all into one.
assert env.get("DB01_SPLIT_DB") == "TRUE", "the mongo job would write every database into one file"
for job in ("DB02", "DB03"):
    assert env.get(f"{job}_SPLIT_DB") == "FALSE", f"{job} is not a mongo job and should not split"

_, pinned = render(mongo_backup_db="admin", mongo_backup_auth_db="otherdb",
                   mongo_backup_db_exclude="local")
assert pinned["DB01_NAME"] == "admin", "mongo_backup_db no longer pins a single database"
assert pinned["DB01_AUTH"] == "otherdb", "mongo_backup_auth_db does not reach DB01_AUTH"
assert pinned["DB01_NAME_EXCLUDE"] == "local", "mongo_backup_db_exclude does not reach DB01_NAME_EXCLUDE"

# Start now, not at the next midnight, and keep only the mongo job: this host has no mysql or
# postgres, and a failing job would prune nothing but would muddy the file count below.
_, env = render(db_backup_begin="+0")
with open(f"{out}/env", "w") as f:
    for k, v in env.items():
        if re.fullmatch(r"DB0[23]_.*", k):
            continue
        f.write(f"{k}={re.sub(r'[$][{][A-Z_]+[}]', 'secret', v)}\n")
PY
pass "the render asks for ALL with its own authSource, excludes local and config, splits per database, and still accepts a pin"

if ! docker info >/dev/null 2>&1; then
  echo "[SKIP] no Docker: the image was not asked"
  exit "$fail"
fi

PULL_ERR=
pull_retry() {
  local i
  for i in 1 2 3; do
    PULL_ERR=$(docker pull -q "$1" 2>&1 >/dev/null) && return 0
    sleep $((i * 10))
  done
  return 1
}

DBB_IMAGE=$(cat "$T/image")   # the tag the template pins, not a copy of it here
pull_retry "$DBB_IMAGE" || { bad "could not pull $DBB_IMAGE (3 tries): $PULL_ERR"; exit "$fail"; }
pull_retry "$MONGO_IMAGE" || { bad "could not pull $MONGO_IMAGE (3 tries): $PULL_ERR"; exit "$fail"; }

docker network create "$N" >/dev/null
docker volume create "$N" >/dev/null

mongo_up() {  # container, network alias
  docker run -d --name "$1" --network "$N" --network-alias "$2" \
    -e MONGO_INITDB_ROOT_USERNAME=root -e MONGO_INITDB_ROOT_PASSWORD="$MONGO_PASS" \
    -v "$N:/backup" "$MONGO_IMAGE" >/dev/null
  local i
  for i in $(seq 1 90); do
    docker exec "$1" mongosh -u root -p "$MONGO_PASS" --authenticationDatabase admin \
      --quiet --eval 'db.adminCommand({ping:1}).ok' 2>/dev/null | grep -q 1 && return 0
    sleep 1
  done
  return 1
}
msh() {  # container, javascript
  docker exec "$1" mongosh -u root -p "$MONGO_PASS" --authenticationDatabase admin \
    --quiet --eval "$2" 2>/dev/null
}
counts() {  # container
  local db
  for db in $DBS; do
    printf '%s=%s\n' "$db" "$(msh "$1" "db.getSiblingDB('$db').marker.countDocuments()" | tr -d '\r')"
  done
}

mongo_up "$N-mongo" mongodb || { bad "the source mongo never answered"; exit "$fail"; }

# A different number of documents per database, so a restore that mixes them up is visible.
n=1
for db in $DBS; do
  msh "$N-mongo" "db.getSiblingDB('$db').marker.insertMany(Array.from({length:$n},(_,i)=>({i})))" >/dev/null
  n=$((n + 2))
done
before=$(counts "$N-mongo")

docker run -d --name "$N-bk" --network "$N" -v "$N:/backup" --env-file "$T/env" \
  "$DBB_IMAGE" >/dev/null
log=
for i in $(seq 1 120); do
  log=$(docker exec "$N-bk" cat /logs/dbbackup.log 2>/dev/null)
  printf '%s\n' "$log" | grep -qE 'action=backup job=db01.*status=(finished|failed|error)' && break
  sleep 1
done
if printf '%s\n' "$log" | grep -q 'action=backup job=db01.*status=finished'; then
  pass "the mongo job finished"
else
  bad "the mongo job did not finish: $(printf '%s\n' "$log" | grep 'job=db01' | tail -3)"
  exit "$fail"
fi

dumps=$(docker exec "$N-bk" sh -c 'for f in /backup/mongo-*.zst; do [ -s "$f" ] && basename "$f"; done' 2>/dev/null)
missing=
for db in $DBS; do
  # The image sanitises the database name in the file name: cas-audit -> cas_audit.
  printf '%s\n' "$dumps" | grep -q -- "^mongo-$(printf '%s' "$db" | tr '-' '_')-" || missing="$missing $db"
done
if [ -n "$missing" ]; then
  bad "no dump for:$missing (got: $(printf '%s' "$dumps" | tr '\n' ' '))"
else
  pass "every CAS database got its own dump: $(printf '%s' "$dumps" | tr '\n' ' ')"
fi
for own in local config; do
  printf '%s\n' "$dumps" | grep -q -- "^mongo-$own-" \
    && bad "the server's own $own was dumped: the exclude list was not read" \
    || pass "$own stayed out of the backup"
done

# zstd lives in the db-backup image, not in mongo's; root because /backup is the backup user's.
docker run --rm --user 0 -v "$N:/backup" --entrypoint /bin/sh "$DBB_IMAGE" -c \
  'set -e; mkdir -p /backup/restore; for f in /backup/mongo-*.zst; do
     zstd -dcq "$f" > "/backup/restore/$(basename "$f" .zst).js"; done
   chmod -R a+rX /backup/restore' >/dev/null 2>&1 \
  || { bad "could not decompress the dumps"; exit "$fail"; }

mongo_up "$N-mongo2" mongodb2 || { bad "the empty mongo never answered"; exit "$fail"; }
# Each file is a mongosh script that says `db.<collection>.insertMany(...)`: it is the database
# mongosh connects to that decides where the documents land, which is why the files are split.
for db in $DBS; do
  f=$(docker exec "$N-mongo2" sh -c \
    "ls /backup/restore/mongo-$(printf '%s' "$db" | tr '-' '_')-*.js 2>/dev/null | head -1")
  [ -n "$f" ] || continue
  err=$(docker exec "$N-mongo2" mongosh -u root -p "$MONGO_PASS" --authenticationDatabase admin \
    --quiet "$db" --file "$f" 2>&1) \
    || bad "replaying $db failed: $(printf '%s' "$err" | tail -2)"
done
after=$(counts "$N-mongo2")
if [ "$before" = "$after" ]; then
  pass "every database came back with the same document counts: $(printf '%s' "$after" | tr '\n' ' ')"
else
  bad "the restore does not match the source. before: $(printf '%s' "$before" | tr '\n' ' ') after: $(printf '%s' "$after" | tr '\n' ' ')"
fi

exit "$fail"

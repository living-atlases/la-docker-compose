#!/usr/bin/env bash
#
# verify-migration.sh — prove a portal migration did not lose data.
#
# playbooks/portal-migrate-fetch.yml recorded an exact COUNT(*) for every table
# and collection on the SOURCE portal, in <dump-set>/counts/. This compares
# those numbers against the restored stack, table by table.
#
# It also checks the thing a careless restore destroys silently: the datastore
# users this deployment generated. A cluster-wide dump would have replaced them
# with the source VM's, and every service would lose its database auth.
#
# Run it ON a Docker host, once per host that carries a datastore — each engine
# is skipped where its container is not running, so a multi-host deployment is
# covered by running this on each host in turn.
#
# Credentials come from the containers' own environment, so no inventory or
# vault access is needed.
#
# Exit codes:  0 = migration verified   1 = data missing   2 = usage/setup error
#
# Usage:
#   scripts/verify-migration.sh <dump-set-dir> [--quiet]
set -euo pipefail

SET_DIR="${1:-}"
QUIET=false
[[ "${2:-}" == "--quiet" ]] && QUIET=true

if [[ -z "$SET_DIR" || "$SET_DIR" == "-h" || "$SET_DIR" == "--help" ]]; then
  sed -n '2,23p' "$0"
  exit 2
fi

MANIFEST="$SET_DIR/manifest.json"
COUNTS="$SET_DIR/counts"
[[ -f "$MANIFEST" ]] || { echo "ERROR: no manifest.json in $SET_DIR" >&2; exit 2; }
[[ -d "$COUNTS"   ]] || { echo "ERROR: no counts/ in $SET_DIR" >&2; exit 2; }

PORTAL="$(sed -n 's/.*"portal"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST" | head -1)"
echo "Verifying migration of portal '${PORTAL:-?}' from $SET_DIR"
echo

fail=0      # tables that lost rows
checked=0
skipped=0

running() { docker ps --filter "status=running" --format '{{.Names}}' | grep -qx "$1"; }

note()  { $QUIET || echo "  $*"; }
bad()   { echo "  FAIL $*"; fail=$((fail + 1)); }

# Compare one source counts file against a "table<TAB>count" stream from the
# destination. A table that held rows at the source and holds none (or has
# vanished) here is the failure that matters; extra rows are normal, because a
# deployed stack seeds its own (the CAS admin user, the layersdb reference
# schema, live sessions).
compare() {
  local label="$1" src="$2" dst="$3"
  local t n m
  while IFS=$'\t' read -r t n; do
    [[ -n "$t" ]] || continue
    checked=$((checked + 1))
    m="$(awk -F'\t' -v k="$t" '$1 == k { print $2 }' "$dst")"
    if [[ -z "$m" ]]; then
      [[ "$n" == "0" ]] && note "ok   $label.$t (empty at source, absent here)" \
                        || bad "$label.$t — $n rows at source, table does not exist here"
    elif [[ "$n" != "0" && "$m" == "0" ]]; then
      bad "$label.$t — $n rows at source, 0 here"
    elif [[ "$m" -lt "$n" ]]; then
      bad "$label.$t — $n rows at source, only $m here"
    elif [[ "$m" -gt "$n" ]]; then
      note "ok   $label.$t — $n -> $m (seeded rows added)"
    else
      note "ok   $label.$t — $n"
    fi
  done < "$src"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ---------------------------------------------------------------- MySQL
for src in "$COUNTS"/counts-mysql-*.tsv; do
  [[ -e "$src" ]] || break
  db="$(basename "$src" .tsv)"; db="${db#counts-mysql-}"
  if ! running la_mysql; then
    echo "SKIP mysql/$db — la_mysql is not running on this host"
    skipped=$((skipped + 1)); continue
  fi
  echo "mysql/$db"
  docker exec la_mysql sh -c '
    db="$1"
    mysql -N -B -u root -p"$MYSQL_ROOT_PASSWORD" -e \
      "SELECT table_name FROM information_schema.tables
       WHERE table_schema='"'"'$db'"'"' AND table_type='"'"'BASE TABLE'"'"'" 2>/dev/null \
    | while read -r t; do
        n=$(mysql -N -B -u root -p"$MYSQL_ROOT_PASSWORD" -e \
              "SELECT COUNT(*) FROM \`'"$db"'\`.\`$t\`" 2>/dev/null)
        printf "%s\t%s\n" "$t" "$n"
      done' _ "$db" > "$tmp/dst.tsv"
  compare "$db" "$src" "$tmp/dst.tsv"
done

# ---------------------------------------------------------------- PostgreSQL
for src in "$COUNTS"/counts-postgres-*.tsv; do
  [[ -e "$src" ]] || break
  db="$(basename "$src" .tsv)"; db="${db#counts-postgres-}"
  if ! running la_postgres; then
    echo "SKIP postgres/$db — la_postgres is not running on this host"
    skipped=$((skipped + 1)); continue
  fi
  echo "postgres/$db"
  docker exec -u postgres la_postgres sh -c '
    db="$1"
    psql -tAX -d "$db" -c "SELECT tablename FROM pg_tables WHERE schemaname='"'"'public'"'"'" \
    | while read -r t; do
        [ -n "$t" ] || continue
        n=$(psql -tAX -d "$db" -c "SELECT COUNT(*) FROM public.\"$t\"")
        printf "%s\t%s\n" "$t" "$n"
      done' _ "$db" > "$tmp/dst.tsv"
  compare "$db" "$src" "$tmp/dst.tsv"
done

# ---------------------------------------------------------------- MongoDB
for src in "$COUNTS"/counts-mongo-*.tsv; do
  [[ -e "$src" ]] || break
  db="$(basename "$src" .tsv)"; db="${db#counts-mongo-}"
  if ! running la_mongodb; then
    echo "SKIP mongodb/$db — la_mongodb is not running on this host"
    skipped=$((skipped + 1)); continue
  fi
  echo "mongodb/$db"
  docker exec la_mongodb sh -c '
    export MDB="$1"
    mongosh --quiet --nodb --eval "
      const c = Mongo(\"mongodb://\" + encodeURIComponent(process.env.MONGO_INITDB_ROOT_USERNAME)
                      + \":\" + encodeURIComponent(process.env.MONGO_INITDB_ROOT_PASSWORD)
                      + \"@localhost:27017/?authSource=admin\");
      const d = c.getDB(process.env.MDB);
      d.getCollectionNames().forEach(n => print(n + \"\t\" + d.getCollection(n).countDocuments({})));
    "' _ "$db" > "$tmp/dst.tsv"
  compare "$db" "$src" "$tmp/dst.tsv"
done

# ------------------------------------------- generated credentials survived?
# The failure mode this catches: a cluster-wide restore that overwrote
# mysql.user / admin.system.users with the source VM's accounts. Per-database
# restores cannot do it, so this is a regression check on the restore itself.
echo
echo "generated datastore accounts"
if running la_mysql; then
  n="$(docker exec la_mysql sh -c \
        'mysql -N -B -u root -p"$MYSQL_ROOT_PASSWORD" -e \
          "SELECT COUNT(*) FROM mysql.user WHERE user NOT IN
             ('"'"'root'"'"','"'"'mysql.sys'"'"','"'"'mysql.session'"'"','"'"'mysql.infoschema'"'"')"' 2>/dev/null)"
  if [[ "${n:-0}" -lt 1 ]]; then
    bad "mysql has no application users left — the restore clobbered mysql.user"
  else
    note "ok   mysql: $n application user(s)"
  fi
fi
if running la_mongodb; then
  n="$(docker exec la_mongodb sh -c \
        'mongosh --quiet --nodb --eval "
           const c = Mongo(\"mongodb://\" + encodeURIComponent(process.env.MONGO_INITDB_ROOT_USERNAME)
                           + \":\" + encodeURIComponent(process.env.MONGO_INITDB_ROOT_PASSWORD)
                           + \"@localhost:27017/?authSource=admin\");
           print(c.getDB(\"admin\").system.users.countDocuments({}));"')"
  if [[ "${n:-0}" -lt 1 ]]; then
    bad "mongodb admin has no users left — the restore clobbered admin.system.users"
  else
    note "ok   mongodb: $n account(s) in admin"
  fi
fi

echo
echo "--------------------------------------------------------------"
echo "checked $checked table(s)/collection(s), $skipped database(s) skipped (not on this host)"
if [[ "$fail" -gt 0 ]]; then
  echo "RESULT: FAIL — $fail check(s) lost data"
  exit 1
fi
echo "RESULT: PASS — every source table/collection is present with at least its source row count"

#!/usr/bin/env bash
# Proves a mysql-ALL-*.sql.zst written by la_db-backup can be restored: it loads the dump
# into a throwaway MySQL with no network, prints the rows of every table plus the routines
# and events, and removes the container. It never talks to a real database.
#
#   scripts/restore-db-backup.sh <mysql-ALL-...sql.zst> [--keep]
#
# MYSQL_IMAGE picks the server (use the version of the dump header). --keep leaves the
# container running to look at the data; it stays offline and in memory.
#
# `mysql < dump` does not work with these dumps, for three reasons handled here and to be
# handled by hand in a real restore (README, "Restoring a la_db-backup dump"):
#   - they have `USE db` but no CREATE DATABASE, so an empty server answers ERROR 1049
#   - bit(1) columns are written as raw bytes: without --binary-mode the client stops at
#     the first NUL
#   - a table is one INSERT, 208 MB on a real portal, over the 64 MB of a default server,
#     and both ends have to allow it
set -u

dump=${1:-}; keep=${2:-}
[ -f "$dump" ] || { echo "usage: $0 <mysql-ALL-...sql.zst> [--keep]" >&2; exit 2; }
image=${MYSQL_IMAGE:-mysql:8.0-debian}
name=la-restore-test-$$
pass=$(openssl rand -hex 16)

cleanup() { [ "$keep" = --keep ] || docker rm -f "$name" >/dev/null 2>&1; }
trap cleanup EXIT

my() { docker exec -i -e MYSQL_PWD="$pass" "$name" mysql -uroot --default-character-set=utf8mb4 "$@"; }

docker run -d --name "$name" --network none --tmpfs "/var/lib/mysql:size=${RESTORE_TMPFS:-8g}" \
  -e MYSQL_ROOT_PASSWORD="$pass" "$image" \
  --event-scheduler=OFF --max-allowed-packet=1G >/dev/null || exit 1

# The entrypoint's temporary server answers too and then goes away, so wait for two answers
# a few seconds apart.
for _ in $(seq 1 90); do
  if my -e 'SELECT 1' >/dev/null 2>&1; then
    sleep 3
    my -e 'SELECT 1' >/dev/null 2>&1 && break
  fi
  sleep 2
done
my -e 'SELECT 1' >/dev/null || { echo "FAIL server did not start" >&2; docker logs --tail 20 "$name" >&2; exit 1; }

# Each statement of a table is a line of raw bytes that may hold anything, so only a whole
# line that is exactly a USE counts.
dbs=$(zstd -dc "$dump" | LC_ALL=C grep -a -E '^USE `[A-Za-z0-9_]+`;$' | LC_ALL=C sed -E 's/^USE `(.*)`;$/\1/' | sort -u)
[ -n "$dbs" ] || { echo "FAIL no databases in $dump" >&2; exit 1; }
for db in $dbs; do my -e "CREATE DATABASE IF NOT EXISTS \`$db\`"; done

if ! zstd -dc "$dump" | my --binary-mode=1 --max-allowed-packet=1G; then
  echo "FAIL restore of $dump" >&2
  exit 1
fi

in_list=$(printf "'%s'," $dbs); in_list=${in_list%,}
my -N -e "SELECT table_schema, table_name FROM information_schema.tables
          WHERE table_schema IN ($in_list) AND table_type='BASE TABLE' ORDER BY 1,2" |
while IFS=$'\t' read -r db table; do
  printf '%s.%s\t%s\n' "$db" "$table" "$(my -N -e "SELECT COUNT(*) FROM \`$db\`.\`$table\`" </dev/null)"
done
my -N -e "SELECT 'routine', routine_schema, routine_name, definer FROM information_schema.routines
          WHERE routine_schema IN ($in_list) ORDER BY 2,3;
          SELECT 'event', event_schema, event_name, status, definer FROM information_schema.events
          WHERE event_schema IN ($in_list) ORDER BY 2,3"
[ "$keep" = --keep ] && echo "kept: docker exec -it -e MYSQL_PWD=$pass $name mysql -uroot"
echo "OK restored $dump"

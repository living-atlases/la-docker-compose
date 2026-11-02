#!/usr/bin/env bash
# A la_db-backup dump of a real portal failed three times on an empty server before it
# restored: no CREATE DATABASE, raw NUL bytes in bit(1) columns, and one INSERT over the 64 MB
# of a default server. This builds a small dump with those three traits (plus a routine and
# an event whose definer does not exist there) and restores it with the real script, on a
# real MySQL, because the failures are the server's and a stand-in would prove nothing.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }

python3 - "$tmp/dump.sql" <<'PY'
import sys
with open(sys.argv[1], "wb") as f:
    f.write(b"-- dbbackup MySQL/MariaDB dump\nSET NAMES utf8mb4;\n-- Database: demo\nUSE `demo`;\n")
    f.write(b"CREATE TABLE `flags` (`id` int NOT NULL, `on` bit(1) NOT NULL, `name` varchar(50),"
            b" PRIMARY KEY (`id`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;\n")
    f.write(b"INSERT INTO `flags` VALUES\n(1, '\x00', 'Do\xc3\xb1ana'),\n(2, '\x01', 'USE `nope`;');\n")
    f.write(b"CREATE TABLE `big` (`id` int NOT NULL, `body` longtext, PRIMARY KEY (`id`))"
            b" ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;\n")
    f.write(b"INSERT INTO `big` VALUES\n(1, '" + b"x" * (70 * 1024 * 1024) + b"');\n")
    f.write(b"DELIMITER ;;\nCREATE DEFINER=`app_user`@`%` PROCEDURE `tick`()\nBEGIN\n  SELECT 1;\nEND;;\n")
    f.write(b"DELIMITER ;\n")
    f.write(b"CREATE DEFINER=`app_user`@`%` EVENT `tick_hourly` ON SCHEDULE EVERY 1 HOUR DO CALL tick();\n")
    f.write(b"-- Database: other\nUSE `other`;\n")
    f.write(b"CREATE TABLE `one` (`id` int NOT NULL, PRIMARY KEY (`id`)) ENGINE=InnoDB;\n")
    f.write(b"INSERT INTO `one` VALUES\n(7);\n-- Dump completed\n")
PY
zstd -q "$tmp/dump.sql" -o "$tmp/dump.sql.zst"

out="$tmp/out"
RESTORE_TMPFS=1g bash "$ROOT/scripts/restore-db-backup.sh" "$tmp/dump.sql.zst" --keep >"$out" 2>&1
rc=$?
name=$(sed -n 's/^kept: .* \(la-restore-test-[0-9]*\) mysql.*/\1/p' "$out")
pw=$(sed -n 's/^kept: .*MYSQL_PWD=\([0-9a-f]*\) .*/\1/p' "$out")
[ "$rc" = 0 ] && ok "restores with no CREATE DATABASE, raw NULs and a 70 MB INSERT" || { bad "restore (rc=$rc)"; tail -5 "$out"; }

grep -qP '^demo\.flags\t2$' "$out"  && ok "demo.flags has its rows"  || bad "demo.flags rows"
grep -qP '^other\.one\t1$' "$out"   && ok "second database restored" || bad "second database"
grep -qP '^routine\tdemo\ttick\t'  "$out" && ok "routine survives without its definer" || bad "routine"
grep -qP '^event\tdemo\ttick_hourly\tENABLED' "$out" && ok "event survives" || bad "event"
grep -q 'nope' "$out" && bad "a USE inside a value created a database" || ok "a USE inside a value is data"

if [ -n "$name" ]; then
  my() { docker exec -e MYSQL_PWD="$pw" "$name" mysql -uroot --default-character-set=utf8mb4 -N "$@"; }
  [ "$(my -e 'SELECT `on`+0 FROM demo.flags ORDER BY id' | tr -d '\n')" = 01 ] && ok "bit values intact" || bad "bit values"
  [ "$(my -e 'SELECT name FROM demo.flags WHERE id=1')" = "Doñana" ] && ok "utf8 intact" || bad "utf8"
  [ "$(my -e 'SELECT LENGTH(body) FROM demo.big')" = $((70*1024*1024)) ] && ok "large value intact" || bad "large value"
  [ "$(my -e "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='nope'")" = 0 ] && ok "no stray database" || bad "stray database"
  docker rm -f "$name" >/dev/null 2>&1
else
  bad "no kept container to inspect"
fi

# Without --keep nothing is left behind
before=$(docker ps -a --filter name=la-restore-test -q | wc -l)
RESTORE_TMPFS=1g bash "$ROOT/scripts/restore-db-backup.sh" "$tmp/dump.sql.zst" >/dev/null 2>&1
[ "$(docker ps -a --filter name=la-restore-test -q | wc -l)" = "$before" ] && ok "container removed" || bad "container left behind"

echo "PASS=$pass FAIL=$fail"
[ "$fail" = 0 ]

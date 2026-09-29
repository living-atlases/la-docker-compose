#!/usr/bin/env bash
# scripts/bundle/{capture,apply}.sh (TASK-50 bundle spike) against a shimmed `docker` and a
# shimmed wait-for-health.sh:
#   1. capture: bundles the compose dir and the small bind sources; leaves out logs, missing
#      and oversized sources; the bundle is 0600 and nothing of its content is printed;
#   2. apply --phase live: restores a changed file, pulls only missing images, runs up and
#      the health wait, and prints one BUNDLE-TIMING line per step plus the total;
#   3. apply --phase down: only `compose down`, volumes kept (no -v);
#   4. a failed health wait fails the phase and names the step;
#   5. no bundle: fails at restore, before touching docker;
#   6. an unknown phase is a usage error (rc 2).
# ~2s, no Docker, no root.
set -eu
cd "$(dirname "$0")/.."

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# The test tree lives under /tmp, which capture.sh treats as a system dir on a real host.
export BUNDLE_SYSTEM_DIRS=/nonexistent

cd_=$tmp/data/docker-compose
mkdir -p "$cd_" "$tmp/data/app/config" "$tmp/data/app/logs" "$tmp/data/big" "$tmp/out" "$tmp/bin"
echo 'SECRET_PASSWORD=do-not-print' >"$cd_/.env"
echo 'services: {}' >"$cd_/docker-compose.yml"
echo 'key=v1' >"$tmp/data/app/config/app.properties"
echo 'a log line' >"$tmp/data/app/logs/app.log"
head -c 2500000 /dev/zero >"$tmp/data/big/blob"

cat >"$tmp/config.json" <<EOF
{"services": {
  "app": {"volumes": [
    {"type": "bind", "source": "$tmp/data/app/config", "target": "/config"},
    {"type": "bind", "source": "$tmp/data/app/logs", "target": "/logs"},
    {"type": "bind", "source": "$cd_/nginx.conf", "target": "/etc/nginx.conf"},
    {"type": "volume", "source": "la_mysql-data", "target": "/var/lib/mysql"}]},
  "big": {"volumes": [
    {"type": "bind", "source": "$tmp/data/big", "target": "/big"},
    {"type": "bind", "source": "$tmp/data/missing", "target": "/missing"}]}
}}
EOF
cat >"$tmp/bin/docker" <<EOF
#!/bin/sh
echo "\$*" >>"$tmp/docker-calls"
[ "\$1 \$2" = "compose config" ] && cat "$tmp/config.json"
exit 0
EOF
cat >"$tmp/health.sh" <<EOF
#!/bin/sh
echo "health \$* rounds=\$CONVERGE_ROUNDS" >>"$tmp/docker-calls"
exit \${HEALTH_RC:-0}
EOF
chmod +x "$tmp/bin/docker" "$tmp/health.sh"
export PATH="$tmp/bin:$PATH"

# 1. capture
bash scripts/bundle/capture.sh --compose-dir "$cd_" --out "$tmp/out" --max-mb 1 >"$tmp/cap.out" 2>&1 ||
  { cat "$tmp/cap.out" >&2; fail "capture failed"; }
list="$(tar -tzPf "$tmp/out/bundle.tgz")"
echo "$list" | grep -qx "$cd_/.env" || fail "capture: the compose dir's .env is not in the bundle"
echo "$list" | grep -qx "$tmp/data/app/config/app.properties" || fail "capture: a small bind source is missing"
echo "$list" | grep -q "/logs/" && fail "capture: a logs bind source was bundled"
echo "$list" | grep -q "/big/" && fail "capture: an oversized bind source was bundled"
grep -q "^missing $tmp/data/missing" "$tmp/out/excluded.txt" || fail "capture: a missing source is not reported"
grep -q "^big(" "$tmp/out/excluded.txt" || fail "capture: the oversized source is not reported"
[ "$(stat -c %a "$tmp/out/bundle.tgz")" = 600 ] || fail "capture: the bundle is not 0600"
grep -q do-not-print "$tmp/cap.out" && fail "capture: printed a secret"
grep -q "^BUNDLE-TIMING .*step=capture .*paths=2 excluded=3" "$tmp/cap.out" ||
  { cat "$tmp/cap.out" >&2; fail "capture: no or wrong BUNDLE-TIMING line"; }
pass "capture bundles config, leaves out logs, missing and big sources, 0600, no secret printed"

apply() { bash scripts/bundle/apply.sh --bundle "$tmp/out/bundle.tgz" --compose-dir "$cd_" \
  --health-script "$tmp/health.sh" --health-budget 30 "$@" >"$tmp/apply.out" 2>&1; }

# 2. live
echo 'key=CHANGED' >"$tmp/data/app/config/app.properties"
: >"$tmp/docker-calls"
apply --phase live || { cat "$tmp/apply.out" >&2; fail "live: failed"; }
grep -qx 'key=v1' "$tmp/data/app/config/app.properties" || fail "live: the bundle was not restored"
grep -qx 'compose pull --quiet --policy missing' "$tmp/docker-calls" || fail "live: no pull --policy missing"
grep -qx 'compose up -d --remove-orphans' "$tmp/docker-calls" || fail "live: no up"
grep -q "^health --compose-dir $cd_ .* rounds=2" "$tmp/docker-calls" || fail "live: no health wait with the role's converge knobs"
for s in restore pull up health total; do
  grep -q "^BUNDLE-TIMING host=.* phase=live step=$s seconds=[0-9]" "$tmp/apply.out" || fail "live: no timing for $s"
done
pass "live restores, pulls only missing images, runs up and the health wait, times each step"

# 3. down
: >"$tmp/docker-calls"
apply --phase down || { cat "$tmp/apply.out" >&2; fail "down: failed"; }
[ "$(cat "$tmp/docker-calls")" = 'compose down --remove-orphans' ] ||
  fail "down: unexpected docker calls: $(tr '\n' ';' <"$tmp/docker-calls")"
pass "down only stops the stack and keeps the volumes"

# 4. health fails
: >"$tmp/docker-calls"
rc=0; HEALTH_RC=1 apply --phase cold || rc=$?
[ "$rc" -ne 0 ] || fail "cold: a failed health wait did not fail the phase"
grep -q "^BUNDLE-FAILED .*phase=cold step=health rc=1" "$tmp/apply.out" || fail "cold: the failed step is not named"
grep -q "phase=cold step=total" "$tmp/apply.out" || fail "cold: no total on failure"
pass "a failed health wait fails the phase and names the step"

# 5. no bundle
: >"$tmp/docker-calls"
rc=0; bash scripts/bundle/apply.sh --phase live --bundle "$tmp/nope.tgz" --health-script "$tmp/health.sh" \
  >"$tmp/apply.out" 2>&1 || rc=$?
[ "$rc" -ne 0 ] && grep -q "step=restore" "$tmp/apply.out" || fail "no bundle: did not fail at restore"
[ ! -s "$tmp/docker-calls" ] || fail "no bundle: docker was still called"
pass "without a bundle the phase fails at restore, before any docker call"

# 6. usage
rc=0; bash scripts/bundle/apply.sh --phase nope >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "unknown phase: rc $rc, want 2"
pass "an unknown phase is a usage error"
echo "All checks passed."

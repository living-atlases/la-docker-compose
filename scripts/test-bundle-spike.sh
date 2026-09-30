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
#   6. an unknown phase is a usage error (rc 2);
#   7. manifest.py lists every member with a hash and never the content;
#   8. compare-manifests.py classifies identical, content, mode and one-sided paths;
#   9. render.sh: one container per docker_compose host, named after its ansible_host, an
#      overlay that points the host and its other aliases at it and blocks every other host
#      (never ssh), the render with the data/volume tags skipped, a
#      manifest per host, and the containers removed afterwards.
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
[ "$(cat "$tmp/docker-calls")" = 'compose down --remove-orphans --timeout 120' ] ||
  fail "down: unexpected docker calls: $(tr '\n' ';' <"$tmp/docker-calls")"
pass "down only stops the stack, gracefully, and keeps the volumes"

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

# 7. manifest
python3 scripts/bundle/manifest.py "$tmp/out/bundle.tgz" >"$tmp/m1" || fail "manifest: failed"
grep -qP "^\Q$cd_\E/\.env\t[0-9a-f]{16}\t0o" "$tmp/m1" || fail "manifest: no hashed .env row"
grep -q do-not-print "$tmp/m1" && fail "manifest: printed a secret"
pass "manifest lists members by hash, never by content"

# 8. compare
printf '/a\th1\t0o644\tu:u\n/b\th2\t0o644\tu:u\n/c\th3\t0o644\tu:u\n/r\th4\t0o644\tu:u\n' >"$tmp/r.m"
printf '/a\th1\t0o644\tu:u\n/b\tXX\t0o644\tu:u\n/c\th3\t0o640\tu:u\n/h\th5\t0o644\tu:u\n' >"$tmp/h.m"
out=$(python3 scripts/bundle/compare-manifests.py "$tmp/r.m" "$tmp/h.m" --label t)
echo "$out" | grep -q "BUNDLE-COMPARE t render=4 host=4 identical=1 content-diff=1 perm-diff=1 only-host=1 only-render=1" ||
  fail "compare: wrong counts: $(echo "$out" | head -1)"
{ echo "$out" | grep -q "content-diff /b" && echo "$out" | grep -q "perm-diff /c render=0o644/u:u host=0o640/u:u"; } ||
  fail "compare: paths not listed"
pass "compare-manifests classifies identical, content, mode and one-sided paths"

# 9. render.sh
: >"$tmp/docker-calls"
cat >"$tmp/bin/ansible-inventory" <<'INV'
#!/bin/sh
cat <<'JSON'
{"_meta": {"hostvars": {"h1.docker_compose": {"ansible_host": "vm-1"}, "h2.docker_compose": {"ansible_host": "vm-2"},
                        "h1.gatus": {"ansible_host": "vm-1"}, "prod-x": {"ansible_host": "prod.example"}}},
 "all": {"children": ["docker_compose", "gatus", "ungrouped"]},
 "docker_compose": {"children": ["docker_compose_hosts"], "hosts": ["h1.docker_compose"]},
 "docker_compose_hosts": {"hosts": ["h2.docker_compose"]},
 "gatus": {"hosts": ["h1.gatus"]}, "ungrouped": {"hosts": ["prod-x"]}}
JSON
INV
cat >"$tmp/bin/ansible-playbook" <<PB
#!/bin/sh
echo "playbook \$*" >>"$tmp/docker-calls"
echo "cache=\$ANSIBLE_CACHE_PLUGIN" >>"$tmp/docker-calls"
for a in "\$@"; do case "\$a" in *render-overlay.ini) cp "\$a" "$tmp/overlay.seen" ;; esac; done
PB
cat >"$tmp/bin/docker" <<DK
#!/bin/sh
echo "\$*" >>"$tmp/docker-calls"
case "\$*" in exec*manifest.py*) echo "/data/x	abc	0o644	u:u" ;; exec*capture.sh*) echo "BUNDLE-TIMING host=c step=capture seconds=0" ;; esac
exit 0
DK
cat >"$tmp/bin/ansible" <<AN
#!/bin/sh
echo "ansible \$*" >>"$tmp/docker-calls"
while [ \$# -gt 0 ]; do [ "\$1" = --tree ] && tree=\$2; shift; done
mkdir -p "\$tree"
for h in h1.docker_compose h2.docker_compose; do
  echo '{"ansible_facts": {"ansible_default_ipv4": {"address": "10.0.0.9"}, "ansible_memtotal_mb": 2048, "ansible_processor_vcpus": 4, "ansible_processor_count": 4}}' >"\$tree/\$h"
done
AN
chmod +x "$tmp/bin/ansible-inventory" "$tmp/bin/ansible-playbook" "$tmp/bin/docker" "$tmp/bin/ansible"
bash scripts/bundle/render.sh --out "$tmp/render" --inventory-args "-i inv.ini" >"$tmp/render.out" 2>&1 ||
  { cat "$tmp/render.out" >&2; fail "render: failed"; }
{ grep -q -- "^run -d --name vm-1 --hostname vm-1 " "$tmp/docker-calls" && grep -q -- "^run -d --name vm-2 " "$tmp/docker-calls"; } ||
  fail "render: containers not named after ansible_host"
grep -q "^h2.docker_compose ansible_connection=community.docker.docker ansible_docker_host=vm-2 " "$tmp/overlay.seen" ||
  fail "render: the overlay does not point the host at its container"
grep -q "^ansible docker_compose -i inv.ini -m ansible.builtin.setup" "$tmp/docker-calls" ||
  fail "render: the real hosts' facts are not read with a separate setup"
grep -q "^h2.docker_compose .*render_host_facts='{\"default_ipv4\": {\"address\": \"10.0.0.9\"}, \"memtotal_mb\": 2048" "$tmp/overlay.seen" ||
  fail "render: the real host's facts do not reach the render"
grep -q "^h1.gatus ansible_connection=community.docker.docker ansible_docker_host=vm-1 " "$tmp/overlay.seen" ||
  fail "render: another alias of a rendered machine would reach the real one"
grep -q "^prod-x ansible_connection=community.docker.docker ansible_docker_host=la-render-blocked" "$tmp/overlay.seen" ||
  fail "render: a host outside the render is not blocked"
! grep -q "^run -d --name prod.example" "$tmp/docker-calls" || fail "render: a container was started for a non docker_compose host"
grep -q "^playbook playbooks/bundle-render.yml -i inv.ini -i .*render-overlay.ini --limit docker_compose --skip-tags docker-volumes,nameindex" "$tmp/docker-calls" ||
  fail "render: wrong playbook invocation: $(grep ^playbook "$tmp/docker-calls")"
grep -qx "cache=memory" "$tmp/docker-calls" || fail "render: the render may share the deploy's fact cache"
{ [ -s "$tmp/render/vm-1.render.manifest" ] && [ -s "$tmp/render/vm-2.render.manifest" ]; } || fail "render: no manifest per host"
grep -q "BUNDLE-TIMING host=all step=render seconds=[0-9]* rc=0" "$tmp/render.out" || fail "render: no timing"
{ grep -q "^rm -f vm-1" "$tmp/docker-calls" && grep -q "^rm -f vm-2" "$tmp/docker-calls"; } || fail "render: containers left behind"
pass "render.sh renders each docker_compose host in its own container and cleans up"
echo "All checks passed."

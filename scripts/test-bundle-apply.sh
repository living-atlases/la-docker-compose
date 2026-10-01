#!/usr/bin/env bash
# scripts/bundle/{host-apply,la-bundle-apply}.sh (TASK-50 phase 5) against a shimmed `docker`,
# groupadd/useradd/crontab/sysctl/ssh/sudo and a shimmed wait-for-health.sh:
#   1. a first apply restores the bundle, creates the missing external volume, bakes the
#      branding, pulls pinned tags only when missing and mutable ones always, runs
#      `up --no-recreate`, recreates drift, reloads nginx after `nginx -t`, waits for health
#      with the role's knobs, writes .config-hashes and times every step;
#   2. a second apply restarts only the service whose watched config changed, deletes the file
#      the previous bundle wrote and this one dropped, keeps a file under an excluded path,
#      merges root's crontab by its "#Ansible:" names and keeps the other lines, and does not
#      rebake a branding image whose content-hash tag is already there;
#   3. a bundle rendered for another host fails before anything on the host changes;
#   4. a `compose up` that fails fails the step (errexit inside a step), with no drift
#      recreation and no new .config-hashes;
#   5. the service-consistency gate stops a removal unless allow_service_removal;
#   6. `nginx -t` failing: no reload, the step fails;
#   7. la-bundle-apply.sh runs every host, prefixes their output and fails if one fails;
#   8. apply-spike.sh + add-marker.py end to end: a converge apply, a no-change apply, a controlled config
#      change that restarts only its service, and the revert that deletes the marker.
# ~3s, no Docker, no root.
set -eu
cd "$(dirname "$0")/.."

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap '[ -n "${KEEP_TMP:-}" ] || rm -rf "$tmp"' EXIT
cd_=$tmp/data/docker-compose
mkdir -p "$cd_" "$tmp/data/app/config" "$tmp/data/big" "$tmp/bin" "$tmp/sysctl.d" "$tmp/exp/h1/host-state/sysctl.d"
export LA_BUNDLE_SYSCTL_DIR=$tmp/sysctl.d RETRY_DELAY=0

cat >"$tmp/config.json" <<EOF
{"services": {
  "app": {"image": "registry/app:1.2.3"},
  "web": {"image": "registry/web:latest"},
  "branding": {"image": "branding-builder:HEAD"}},
 "volumes": {"data": {"name": "la_app-data", "external": true}, "tmp": {}}}
EOF
cat >"$tmp/bin/docker" <<EOF
#!/bin/bash
echo "\$*" >>"$tmp/docker-calls"
case "\$*" in
  "compose config --format json") cat "$tmp/config.json" ;;
  "compose config --services") printf 'app\nweb\nbranding\n' ;;
  "compose ps --services --status=running") printf '%s\n' \${RUNNING:-app web} ;;
  "compose up -d --remove-orphans"*) exit \${UP_RC:-0} ;;
  "volume inspect la_app-data") [ -f "$tmp/vol-exists" ]; exit ;;
  "volume create"*) touch "$tmp/vol-exists" ;;
  "image inspect branding-builder:abc123") [ -f "$tmp/img-exists" ]; exit ;;
  "buildx bake"*) touch "$tmp/img-exists" ;;
  "ps --filter name=^la_nginx\$ --filter status=running -q") echo abc123 ;;
  "exec la_nginx nginx -t") exit \${NGINX_T_RC:-0} ;;
  "inspect -f {{.State.StartedAt}} la_app") echo 2020-01-01T00:00:00Z ;;
  "inspect -f {{.State.StartedAt}} "*) exit 1 ;;
esac
exit 0
EOF
for c in groupadd useradd sysctl; do printf '#!/bin/sh\necho "%s $*" >>"%s/docker-calls"\n' "$c" "$tmp" >"$tmp/bin/$c"; done
cat >"$tmp/bin/crontab" <<EOF
#!/bin/sh
if [ "\$1" = -l ]; then cat "$tmp/crontab" 2>/dev/null; else cp "\$1" "$tmp/crontab"; fi
EOF
cat >"$tmp/exp/h1/wait-for-health.sh" <<EOF
#!/bin/sh
echo "health \$* rounds=\$CONVERGE_ROUNDS" >>"$tmp/docker-calls"
EOF
cp roles/la-compose/files/recreate-drifted-services.sh "$tmp/exp/h1/"
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"

meta() { # $1 = inventory_hostname, $2 = allow_service_removal
  cat >"$cd_/.bundle-meta.json" <<EOF
{"format": 1, "inventory_hostname": "$1", "compose_dir": "$cd_", "la_env": "ci",
 "force_recreate": false, "recreate_drifted_running": true, "allow_service_removal": ${2:-false},
 "pull": true, "pull_policy": "missing", "branding_bake_targets": ["branding"], "branding_images": ["branding-builder:abc123"],
 "health": {"timeout": 720, "interval": 5, "converge_rounds": 4, "converge_timeout": 900,
            "converge_settle_waits": 2, "budget": 60},
 "config_watch": [{"service": "app", "path": "$tmp/data/app/config"},
                  {"service": "gone", "path": "$tmp/data/nope/config"}]}
EOF
}
bundle() { # the bundle of whatever is on disk now, into export dir h1
  tar -czPf "$tmp/exp/h1/bundle.tgz" "$cd_" "$tmp/data/app/config" $([ -f "$tmp/data/big/blob" ] && echo "$tmp/data/big")
}
apply() { : >"$tmp/docker-calls"
  bash scripts/bundle/host-apply.sh --dir "$tmp/exp/h1" --host "${HOST:-h1}" --state-dir "$tmp/state" \
    --marker "$tmp/marker" >"$tmp/apply.out" 2>&1; }

# 1. first apply
echo 'services: {}' >"$cd_/docker-compose.yml"
echo 'key=v1' >"$tmp/data/app/config/app.properties"
echo 'old' >"$tmp/data/app/config/old.properties"
echo 'blob' >"$tmp/data/big/blob"
meta h1; bundle
printf '#Ansible: purge\n0 1 * * * old-purge\n' >"$tmp/exp/h1/host-state/crontab-root"
echo 'net.ipv4.tcp_keepalive_time=200' >"$tmp/exp/h1/host-state/sysctl.d/99-image.conf"
printf '# mine\n5 5 * * * my-own-job\n' >"$tmp/crontab"
rm -f "$tmp/data/app/config/app.properties"
apply || { cat "$tmp/apply.out" >&2; fail "first apply failed"; }
grep -qx 'key=v1' "$tmp/data/app/config/app.properties" || fail "1: the bundle was not restored"
grep -qx 'volume create --driver local la_app-data' "$tmp/docker-calls" || fail "1: the missing external volume was not created"
grep -q 'volume create.*tmp' "$tmp/docker-calls" && fail "1: a non-external volume was created"
grep -qx 'buildx bake -f docker-bake.hcl branding' "$tmp/docker-calls" || fail "1: no branding bake"
grep -qx 'compose pull --quiet --policy missing' "$tmp/docker-calls" || fail "1: no pull --policy missing"
grep -qx 'compose pull --quiet --policy always web' "$tmp/docker-calls" ||
  fail "1: mutable tags not pulled always: $(grep 'policy always' "$tmp/docker-calls")"
grep -qx 'compose up -d --remove-orphans --no-recreate' "$tmp/docker-calls" || fail "1: no up --no-recreate"
grep -qx "compose config --hash \*" "$tmp/docker-calls" || fail "1: drifted containers not checked"
grep -q 'exec la_nginx nginx -t' "$tmp/docker-calls" && grep -qx 'exec la_nginx nginx -s reload' "$tmp/docker-calls" ||
  fail "1: no nginx -t + reload"
grep -q '^compose restart' "$tmp/docker-calls" && fail "1: restarted a service on the first apply (no baseline)"
grep -q "^health --compose-dir $cd_ --timeout 720 --check-interval 5 rounds=4" "$tmp/docker-calls" ||
  fail "1: health wait without the meta knobs"
grep -q "^app [0-9a-f]\{64\}$" "$cd_/.config-hashes" || fail "1: .config-hashes not written"
grep -q '^gone ' "$cd_/.config-hashes" && fail "1: a missing watched dir was hashed"
[ -f "$tmp/sysctl.d/99-image.conf" ] && grep -q "^sysctl -p $tmp/sysctl.d/99-image.conf" "$tmp/docker-calls" ||
  fail "1: sysctl host-state not installed"
for s in prep restore volumes branding pull predeploy gate up restart health total; do
  grep -q "^BUNDLE-TIMING host=.* phase=apply step=$s seconds=[0-9]" "$tmp/apply.out" || fail "1: no timing for $s"
done
[ -f "$tmp/marker" ] && fail "1: the deploy marker was left behind"
pass "first apply: restore, volume, bake, pull split, up --no-recreate, drift, nginx reload, health, hashes"

# 2. second apply: a config change, a dropped file, an excluded path, a crontab merge
echo 'key=v2' >"$tmp/data/app/config/app.properties"
rm "$tmp/data/app/config/old.properties" "$tmp/data/big/blob"
bundle
echo "big(200MB) $tmp/data/big" >"$tmp/exp/h1/excluded.txt"
echo 'key=v1' >"$tmp/data/app/config/app.properties"
echo 'old' >"$tmp/data/app/config/old.properties"
echo 'blob' >"$tmp/data/big/blob"
printf '#Ansible: purge\n0 2 * * * new-purge\n' >"$tmp/exp/h1/host-state/crontab-root"
apply || { cat "$tmp/apply.out" >&2; fail "second apply failed"; }
grep -qx 'key=v2' "$tmp/data/app/config/app.properties" || fail "2: the changed config was not restored"
grep -qx 'compose restart app' "$tmp/docker-calls" || fail "2: the changed service was not restarted"
grep -q 'buildx bake' "$tmp/docker-calls" && fail "2: rebaked a branding image whose tag is already there"
grep -q '^branding images up to date' "$tmp/apply.out" || fail "2: the branding skip is not reported"
[ "$(grep -c '^compose restart' "$tmp/docker-calls")" = 1 ] || fail "2: restarted more than the changed service"
[ -f "$tmp/data/app/config/old.properties" ] && fail "2: the dropped file is still there"
[ -f "$tmp/data/big/blob" ] || fail "2: deleted a file under an excluded path"
grep -qx '5 5 \* \* \* my-own-job' "$tmp/crontab" || fail "2: lost a crontab line that is not ours"
grep -qx '0 2 \* \* \* new-purge' "$tmp/crontab" && ! grep -q old-purge "$tmp/crontab" ||
  fail "2: the #Ansible job was not replaced: $(cat "$tmp/crontab")"
pass "second apply: restarts only the changed service, drops removed files, keeps excluded ones, merges cron, no rebake"

# 3. wrong host
cp "$tmp/data/app/config/app.properties" "$tmp/before"
meta h2; echo 'key=v3' >"$tmp/data/app/config/app.properties"; bundle
cp "$tmp/before" "$tmp/data/app/config/app.properties"; meta h1
rc=0; apply || rc=$?
[ "$rc" -ne 0 ] || fail "3: a bundle for another host was applied"
grep -q 'rendered for h2, not h1' "$tmp/apply.out" && grep -q '^BUNDLE-FAILED .*step=check' "$tmp/apply.out" ||
  { cat "$tmp/apply.out" >&2; fail "3: wrong failure"; }
cmp -s "$tmp/before" "$tmp/data/app/config/app.properties" || fail "3: the host was written before the check"
[ -s "$tmp/docker-calls" ] && fail "3: docker was called before the check"
pass "a bundle rendered for another host fails before anything changes"

# 4. compose up fails in the middle of the step
meta h1; bundle
cp "$cd_/.config-hashes" "$tmp/hashes-before"
rc=0; UP_RC=1 apply || rc=$?
[ "$rc" -ne 0 ] || fail "4: a failed compose up passed"
grep -q '^BUNDLE-FAILED .*step=up rc=1' "$tmp/apply.out" || { cat "$tmp/apply.out" >&2; fail "4: step not named"; }
grep -q 'config --hash' "$tmp/docker-calls" && fail "4: drift recreation ran after a failed up"
cmp -s "$tmp/hashes-before" "$cd_/.config-hashes" || fail "4: .config-hashes changed after a failed up"
pass "a failed compose up fails the step, before drift recreation and the hash snapshot"

# 5. consistency gate
rc=0; RUNNING="app web solr" apply || rc=$?
[ "$rc" -ne 0 ] && grep -q '^BUNDLE-FAILED .*step=gate' "$tmp/apply.out" || fail "5: a removal passed the gate"
grep -q '^compose up' "$tmp/docker-calls" && fail "5: up ran after the gate"
meta h1 true; bundle
RUNNING="app web solr" apply || { cat "$tmp/apply.out" >&2; fail "5: allow_service_removal did not pass"; }
pass "the gate stops a service removal unless allow_service_removal"

# 6. nginx -t fails
meta h1; bundle
rc=0; NGINX_T_RC=1 apply || rc=$?
[ "$rc" -ne 0 ] && grep -q '^BUNDLE-FAILED .*step=restart' "$tmp/apply.out" || fail "6: a bad nginx config passed"
grep -q 'nginx -s reload' "$tmp/docker-calls" && fail "6: nginx reloaded a config nginx -t rejected"
pass "nginx -t failing: no reload, the step fails"

# 7. controller: two hosts, one with a bundle for another host
mkdir -p "$tmp/exp/h2"; cp -r "$tmp/exp/h1/." "$tmp/exp/h2/"
cat >"$tmp/bin/ssh" <<EOF
#!/bin/bash
while [ "\${1#-}" != "\$1" ]; do shift 2; done
echo "ssh \$1" >>"$tmp/ssh-calls"
shift
bash -c "\$*"
EOF
cat >"$tmp/bin/sudo" <<EOF
#!/bin/bash
[ "\$1" = bash ] && exec "\$@" --state-dir "$tmp/state" --marker "$tmp/marker"
exec "\$@"
EOF
chmod +x "$tmp/bin/ssh" "$tmp/bin/sudo"
printf 'h1 host-one\nh2 host-two\n' >"$tmp/hosts"
rc=0; bash scripts/bundle/la-bundle-apply.sh --export-dir "$tmp/exp" --hosts "$tmp/hosts" >"$tmp/ctl.out" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || { cat "$tmp/ctl.out" >&2; fail "7: a failed host did not fail the controller"; }
grep -q '^BUNDLE-APPLY host=h1 rc=0$' "$tmp/ctl.out" && grep -q '^BUNDLE-APPLY host=h2 rc=1$' "$tmp/ctl.out" ||
  { cat "$tmp/ctl.out" >&2; fail "7: wrong per-host results"; }
grep -q '^\[h1\] BUNDLE-TIMING .*step=total' "$tmp/ctl.out" || fail "7: host output not prefixed"
grep -qx 'ssh host-one' "$tmp/ssh-calls" && grep -qx 'ssh host-two' "$tmp/ssh-calls" || fail "7: not every host was reached"
ls /tmp/la-bundle.* >/dev/null 2>&1 && fail "7: a temp dir with the bundle was left behind in /tmp"
pass "the controller applies every host, prefixes their output and fails when one fails"

# 8. apply-spike.sh end to end (add-marker.py, then the revert), through the real controller
rm -rf "$tmp/exp/h2" "$tmp/state"; rm -f "$cd_/.config-hashes"
meta h1; echo 'key=v2' >"$tmp/data/app/config/app.properties"; bundle
printf 'h1 host-one\n' >"$tmp/hosts"; mkdir -p "$tmp/render"; cp -r "$tmp/exp" "$tmp/render/export"; cp "$tmp/hosts" "$tmp/render/hosts"
bash scripts/bundle/apply-spike.sh --out "$tmp/render" >"$tmp/spike.out" 2>&1 ||
  { cat "$tmp/spike.out" >&2; fail "8: the spike reported problems"; }
grep -q '^controlled change: .*/app/config/.la-bundle-apply-spike (service app) on h1$' "$tmp/spike.out" ||
  fail "8: no controlled change on the watched dir"
[ ! -e "$tmp/data/app/config/.la-bundle-apply-spike" ] || fail "8: the marker survived the revert"
grep -q '^APPLY-SPIKE problems=0$' "$tmp/spike.out" && grep -q 'phase=apply3 .* rc=0' "$tmp/spike.out" ||
  fail "8: no clean summary"
# a real change since the last deploy is converged by the first apply, not a problem
printf 'app deadbeef\n' >"$cd_/.config-hashes"
bash scripts/bundle/apply-spike.sh --out "$tmp/render" >"$tmp/spike.out" 2>&1 ||
  { cat "$tmp/spike.out" >&2; fail "8: a restart on the converge apply was taken for a problem"; }
grep -q '^converge restarts (config changed since the last deploy): 1$' "$tmp/spike.out" || fail "8: converge restart not reported"
# and a restart on the second, no-change apply is noticed (the watched dir changes under it)
cat >"$tmp/bin/docker-wrap" <<EOF
#!/bin/bash
case "\$*" in "compose up -d --remove-orphans --no-recreate") date +%N >"$tmp/data/app/config/runtime.tmp" ;; esac
exec "$tmp/bin/docker" "\$@"
EOF
chmod +x "$tmp/bin/docker-wrap"; mkdir -p "$tmp/bin2"; ln -sf "$tmp/bin/docker-wrap" "$tmp/bin2/docker"
rc=0; PATH="$tmp/bin2:$PATH" bash scripts/bundle/apply-spike.sh --out "$tmp/render" >"$tmp/spike.out" 2>&1 || rc=$?
[ "$rc" -ne 0 ] && grep -q '^APPLY-SPIKE-PROBLEM: the no-change apply restarted' "$tmp/spike.out" ||
  { cat "$tmp/spike.out" >&2; fail "8: a restart on the no-change apply went unnoticed"; }
pass "apply-spike: no-change apply, a controlled config change restarts only its service, the revert cleans up"

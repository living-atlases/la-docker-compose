#!/usr/bin/env bash
# TASK-50 phase 5: apply a rendered bundle to THIS host, as root, the way the Ansible deploy
# does (roles/la-compose/tasks/main.yml from the pre-deploy cleanup to config-restart-apply),
# without Ansible.
#
# v1 scope: REDEPLOY of a portal that already runs. Still Ansible's (phase 2): database
# users/grants/password sync and schema migrations (init-databases.yml), the post-up init
# (Solr collections, CAS admin/OIDC, API keys, GeoServer) and the data artifacts (nameindex,
# SDS layers, shapefiles). A new portal, a new service or a rotated password needs Ansible.
#
# Input: --dir DIR from scripts/bundle/render.sh --export: bundle.tgz, excluded.txt,
# host-state/ (root crontab entries and sysctl.d files the render wrote: an explicit
# allowlist), recreate-drifted-services.sh and wait-for-health.sh. The apply metadata travels
# inside the bundle (<compose dir>/.bundle-meta.json, from roles/la-compose/tasks/bundle-meta.yml)
# and is checked BEFORE anything on the host changes: format, and that the bundle was
# rendered for --host (the controller applies many hosts at once; a mix-up must not write
# one host's config over another's).
#
# Steps, each timed ("BUNDLE-TIMING host=<h> phase=apply step=<s> seconds=<n>"):
#   prep      the 'nginx' system user/group (tar restores owners by name), host-state
#   restore   delete the files the PREVIOUS bundle wrote that this one neither carries nor
#             excluded (never app data: only paths a bundle wrote), then untar without
#             touching existing dirs' owners/modes (--no-overwrite-dir: apps chown their own
#             dirs at runtime)
#   volumes   create the external volumes that are missing (la-volumes: driver local, no opts)
#   branding  docker buildx bake the branding targets when an image with the tag the render
#             computed (a hash of its sources and build inputs) is missing, as build-images.yml
#   pull      pinned tags only when missing, mutable tags always (as build-images.yml)
#   predeploy drop compose state metadata, `down` only with force_recreate, restart unhealthy la_*
#   gate      abort if `up --remove-orphans` would delete a running service (allow_service_removal)
#   up        --no-recreate (or --force-recreate), then recreate drifted containers
#   restart   nginx -t + reload; restart the services whose config hash changed and that up
#             did not already recreate; persist .config-hashes only after a good up
#   health    wait-for-health.sh with the deploy's knobs and the same outer timeout
#
# Usage: host-apply.sh --dir DIR --host INVENTORY_HOSTNAME [--state-dir /var/lib/la-bundle]
set -euo pipefail

DIR=""
EXPECT_HOST=""
STATE_DIR=/var/lib/la-bundle
MARKER=/run/la-compose-deploy.marker
SYSCTL_DIR="${LA_BUNDLE_SYSCTL_DIR:-/etc/sysctl.d}"
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --host) EXPECT_HOST="$2"; shift 2 ;;
    --state-dir) STATE_DIR="$2"; shift 2 ;;
    --marker) MARKER="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$DIR" ] && [ -f "$DIR/bundle.tgz" ] || { echo "--dir must hold bundle.tgz" >&2; exit 2; }
[ -n "$EXPECT_HOST" ] || { echo "--host is required" >&2; exit 2; }

host="$(hostname)"
t0=$(date +%s)
timing() { echo "BUNDLE-TIMING host=$host phase=apply step=$1 seconds=$2"; }
fail() {
  echo "BUNDLE-FAILED host=$host phase=apply step=$1 rc=$2"
  timing total "$(( $(date +%s) - t0 ))"
  exit "$2"
}
# Each step runs in a subshell with errexit ON: `f || rc=$?` would switch errexit off for the
# whole body of f, and a failed tar or `compose up` in the middle of a step would pass.
step() {
  local name="$1" s rc
  shift
  s=$(date +%s)
  echo "==> [$host] apply: $name"
  set +e
  ( set -e; "$@" )
  rc=$?
  set -e
  timing "$name" "$(( $(date +%s) - s ))"
  [ "$rc" -eq 0 ] || fail "$name" "$rc"
}

# The metadata, read from the tarball itself: nothing is written before it checks out.
meta_path=$(tar -tzPf "$DIR/bundle.tgz" | grep '/\.bundle-meta\.json$' || true)
[ "$(printf '%s' "$meta_path" | grep -c .)" -eq 1 ] ||
  { echo "the bundle must carry exactly one .bundle-meta.json (render it with playbooks/bundle-render.yml)"; fail check 1; }
mkdir -p "$STATE_DIR"
chmod 0700 "$STATE_DIR"
META="$STATE_DIR/bundle-meta.json"
tar -xzOPf "$DIR/bundle.tgz" "$meta_path" >"$META"
meta() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v=v[k]
print(json.dumps(v) if isinstance(v,(list,dict)) else ("true" if v is True else "false" if v is False else v))' "$META" "$1"; }
[ "$(meta format)" = 1 ] || { echo "unknown bundle format $(meta format)"; fail check 1; }
[ "$(meta inventory_hostname)" = "$EXPECT_HOST" ] ||
  { echo "this bundle was rendered for $(meta inventory_hostname), not $EXPECT_HOST"; fail check 1; }
COMPOSE_DIR=$(meta compose_dir)
[ "$meta_path" = "$COMPOSE_DIR/.bundle-meta.json" ] || { echo "meta at $meta_path, compose dir $COMPOSE_DIR"; fail check 1; }

compose() { (cd "$COMPOSE_DIR" && docker compose "$@"); }
retry() {
  # As the role's pulls: 3 retries, 30 s apart (Docker Hub's token endpoint 500s now and then).
  local i
  for i in 1 2 3 4; do
    "$@" && return 0
    [ "$i" -lt 4 ] && { echo "retrying in ${RETRY_DELAY:-30}s: $*"; sleep "${RETRY_DELAY:-30}"; }
  done
  return 1
}

# The image GC (docker-housekeeping, #428) skips while a deploy is in progress.
touch "$MARKER"
trap 'rm -f "$MARKER"' EXIT

prep() {
  getent group nginx >/dev/null || groupadd --system nginx
  id nginx >/dev/null 2>&1 || useradd --system --gid nginx --no-create-home --shell /usr/sbin/nologin nginx
  local hs="$DIR/host-state" f
  if [ -f "$hs/crontab-root" ]; then
    # Merge by the "#Ansible: <name>" markers the cron module writes: replace or add each job,
    # leave every other line of root's crontab alone.
    crontab -l 2>/dev/null >"$STATE_DIR/crontab.old" || : >"$STATE_DIR/crontab.old"
    python3 - "$STATE_DIR/crontab.old" "$hs/crontab-root" >"$STATE_DIR/crontab.new" <<'PY'
import sys
def jobs(lines):
    out, name = {}, None
    for l in lines:
        if l.startswith('#Ansible: '):
            name = l[len('#Ansible: '):].strip()
        elif name is not None:
            out[name] = l
            name = None
    return out
old = open(sys.argv[1]).read().splitlines()
new = jobs(open(sys.argv[2]).read().splitlines())
res, skip = [], False
for l in old:
    if skip:
        skip = False
    elif l.startswith('#Ansible: ') and l[len('#Ansible: '):].strip() in new:
        skip = True
    else:
        res.append(l)
for name, job in new.items():
    res += ['#Ansible: ' + name, job]
print('\n'.join(res))
PY
    cmp -s "$STATE_DIR/crontab.old" "$STATE_DIR/crontab.new" || crontab "$STATE_DIR/crontab.new"
  fi
  for f in "$hs"/sysctl.d/*.conf; do
    [ -f "$f" ] || continue
    cmp -s "$f" "$SYSCTL_DIR/$(basename "$f")" && continue
    install -m 0644 "$f" "$SYSCTL_DIR/$(basename "$f")"
    sysctl -p "$SYSCTL_DIR/$(basename "$f")" >/dev/null
  done
}

restore() {
  tar -tzPf "$DIR/bundle.tgz" | grep -v '/$' | sort >"$STATE_DIR/files.new"
  if [ -f "$STATE_DIR/files.applied" ]; then
    # Dropped = in the previous bundle, not in this one, and not under a path this capture
    # excluded (a config dir that grew past --max-mb is not a config dir that went away).
    python3 - "$STATE_DIR/files.applied" "$STATE_DIR/files.new" "$DIR/excluded.txt" <<'PY' >"$STATE_DIR/files.dropped"
import os, sys
prev = set(open(sys.argv[1]).read().splitlines())
new = set(open(sys.argv[2]).read().splitlines())
excl = []
if os.path.exists(sys.argv[3]):
    excl = [l.split(' ', 1)[1] for l in open(sys.argv[3]).read().splitlines() if ' ' in l]
for f in sorted(prev - new):
    if not any(f == e or f.startswith(e.rstrip('/') + '/') for e in excl):
        print(f)
PY
    while IFS= read -r f; do
      if [ -f "$f" ] || [ -L "$f" ]; then rm -f -- "$f"; echo "removed (dropped by the render) $f"; fi
    done <"$STATE_DIR/files.dropped"
  fi
  tar -xzf "$DIR/bundle.tgz" -P --no-overwrite-dir
  mv "$STATE_DIR/files.new" "$STATE_DIR/files.applied"
}

volumes() {
  local v
  compose config --format json | python3 -c '
import json, sys
for k, v in (json.load(sys.stdin).get("volumes") or {}).items():
    if v.get("external"):
        print(v.get("name") or k)' >"$STATE_DIR/volumes"
  while read -r v; do
    docker volume inspect "$v" >/dev/null 2>&1 && continue
    docker volume create --driver local "$v" >/dev/null
    echo "created volume $v"
  done <"$STATE_DIR/volumes"
}

branding() {
  local targets
  targets=$(meta branding_bake_targets | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)))')
  [ -n "$targets" ] || { echo "no branding to bake"; return 0; }
  # The tags hash everything the images are built from (stage-branding-source.yml): when they
  # are all here, a bake would rebuild the same images. As build-images.yml.
  local img missing=""
  for img in $(meta branding_images | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)))'); do
    docker image inspect "$img" >/dev/null 2>&1 || missing="$missing $img"
  done
  if [ -z "$missing" ] && [ "$(meta branding_images)" != "[]" ]; then
    echo "branding images up to date: $(meta branding_images)"; return 0
  fi
  echo "baking branding, missing:${missing:- (no tags in the meta)}"
  # A cache DB pointing at snapshots that are gone fails every build: drop it, build again.
  # shellcheck disable=SC2086
  (cd "$COMPOSE_DIR" && docker buildx bake -f docker-bake.hcl $targets) || {
    docker buildx prune -af
    (cd "$COMPOSE_DIR" && docker buildx bake -f docker-bake.hcl $targets)
  }
}

pull() {
  local policy mutable
  [ "$(meta pull)" = true ] || { echo "no docker_registry: nothing to pull"; return 0; }
  policy=$(meta pull_policy)
  retry compose pull --quiet --policy "$policy"
  [ "$policy" = always ] && return 0
  mutable=$(compose config --format json | python3 -c '
import json, re, sys
pat = re.compile(r"(:latest$)|(^[^:@]*$)|(/[^/:@]*$)")
for n, s in json.load(sys.stdin)["services"].items():
    if "image" in s and pat.search(s["image"]):
        print(n)')
  # shellcheck disable=SC2086
  [ -z "$mutable" ] || retry compose pull --quiet --policy always $mutable
}

predeploy() {
  local sick
  find "$COMPOSE_DIR" -maxdepth 1 -name '.docker-compose*.yml' -delete || true
  if [ "$(meta force_recreate)" = true ]; then compose down --remove-orphans; fi
  sick=$(docker ps -a --filter health=unhealthy --filter name=la_ --format '{{.Names}}')
  [ -n "$sick" ] || return 0
  echo "restarting unhealthy containers (health state reset, IDs kept):" $sick
  echo "$sick" | xargs -r docker restart >/dev/null || true
}

gate() {
  local gone
  gone=$(comm -23 <(compose ps --services --status=running | sort -u) <(compose config --services | sort -u))
  [ -n "$gone" ] || return 0
  echo "SAFETY GATE: \`up --remove-orphans\` would delete these running services, missing from the bundle:" $gone
  [ "$(meta allow_service_removal)" = true ] || return 1
  echo "allow_service_removal=true: proceeding"
}

hashes() {
  local svc path
  meta config_watch | python3 -c '
import json, sys
for e in json.load(sys.stdin): print(e["service"], e["path"])' | while read -r svc path; do
    [ -d "$path" ] || continue
    printf '%s %s\n' "$svc" "$(find "$path" -type f -print0 | sort -z | xargs -0 -r sha256sum | sha256sum | awk '{print $1}')"
  done
}

up() {
  hashes >"$STATE_DIR/config-hashes.now"
  date +%s >"$STATE_DIR/preup-epoch"
  if [ "$(meta force_recreate)" = true ]; then
    compose up -d --remove-orphans --force-recreate
    return 0
  fi
  compose up -d --remove-orphans --no-recreate
  if [ "$(meta recreate_drifted_running)" = true ]; then
    (cd "$COMPOSE_DIR" && bash "$DIR/recreate-drifted-services.sh" --running)
  else
    (cd "$COMPOSE_DIR" && bash "$DIR/recreate-drifted-services.sh")
  fi
}

restart() {
  local preup svc h old started
  if [ -n "$(docker ps --filter 'name=^la_nginx$' --filter status=running -q)" ]; then
    docker exec la_nginx nginx -t ||
      { echo "nginx -t rejected the new config: NOT reloading (the old one keeps serving)"; return 1; }
    docker exec la_nginx nginx -s reload
  fi
  preup=$(cat "$STATE_DIR/preup-epoch")
  if [ -f "$COMPOSE_DIR/.config-hashes" ]; then
    while read -r svc h; do
      # Last line wins, as the role's dict() of the snapshot.
      old=$(awk -v s="$svc" '$1==s {v=$2} END {print v}' "$COMPOSE_DIR/.config-hashes")
      [ -n "$old" ] && [ "$old" != "$h" ] || continue
      if ! started=$(docker inspect -f '{{.State.StartedAt}}' "la_$svc" 2>/dev/null); then
        echo "$svc: SKIP no-container"; continue
      fi
      if [ "$(date -d "$started" +%s)" -gt "$preup" ]; then echo "$svc: SKIP recreated-by-compose-up"; continue; fi
      compose restart "$svc"
      echo "$svc: RESTARTED (config changed)"
    done <"$STATE_DIR/config-hashes.now"
  fi
  install -m 0644 "$STATE_DIR/config-hashes.now" "$COMPOSE_DIR/.config-hashes"
}

health() {
  CONVERGE_ROUNDS=$(meta health.converge_rounds) CONVERGE_TIMEOUT=$(meta health.converge_timeout) \
  CONVERGE_SETTLE_WAITS=$(meta health.converge_settle_waits) \
    timeout -k 30 "$(meta health.budget)" bash "$DIR/wait-for-health.sh" \
      --compose-dir "$COMPOSE_DIR" --timeout "$(meta health.timeout)" --check-interval "$(meta health.interval)"
}

step prep prep
step restore restore
step volumes volumes
step branding branding
step pull pull
step predeploy predeploy
step gate gate
step up up
step restart restart
step health health
echo "NOTE: NOT run, Ansible still owns them (TASK-50 phase 2): database users/grants/password sync and"
echo "      schema migrations (init-databases.yml), and the post-up init (Solr collections, CAS admin/OIDC,"
echo "      API keys, GeoServer). A redeploy that adds a service or rotates a password needs Ansible."
timing total "$(( $(date +%s) - t0 ))"

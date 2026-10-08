#!/usr/bin/env bash
# The fast deploy of a docker-compose portal, for the la-toolkit
# (and anyone with a generated inventory dir): render the bundles once, cache them, apply them
# without Ansible (scripts/bundle/la-bundle-apply.sh).
#
# The inventories, the ssh user and the extra vars are the ones the normal deploy would use:
# this runs the generated `ansiblew` with the same arguments, but with an `ansible-playbook` on
# PATH that only records its argv and environment. So hubs, <pkg>-toolkit.ini, passwords and
# skip_services come from ansiblew itself, never from a second copy of its logic.
#
# Render cache: <cache-dir>/<key>/, key = sha256 of the recorded argv, the content of every
# inventory, the la-docker-compose and ala-install commits (plus any local change), and every
# branding source (git commit + local changes, or the remote ref of a git URL). A hit skips
# the render (~25 min for a 3-host portal); the apply always runs. The cache holds secrets:
# root-only dirs, the newest --keep entries kept.
#
# v1 scope (see host-apply.sh): the redeploy of a portal Ansible deployed before. Refused here:
# a data hub project (deploy from its portal), a hybrid deploy line with VM playbooks, and any
# --limit/--tags/--skip-tags/--check (a bundle is always the whole portal).
#
# Usage: fast-deploy.sh --inventory-dir DIR --cache-dir DIR [--force-render] [--keep N]
#                       -- <ansiblew arguments, as the toolkit's deploy passes them>
# Prints FAST-DEPLOY lines (key, cache hit or render, timings) and the applier's output.
set -euo pipefail

INV_DIR=""
CACHE_DIR=""
FORCE=false
KEEP=3
while [ $# -gt 0 ]; do
  case "$1" in
    --inventory-dir) INV_DIR="$2"; shift 2 ;;
    --cache-dir) CACHE_DIR="$2"; shift 2 ;;
    --force-render) FORCE=true; shift ;;
    --keep) KEEP="$2"; shift 2 ;;
    --) shift; break ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -d "$INV_DIR" ] && [ -x "$INV_DIR/ansiblew" ] || { echo "--inventory-dir must hold a generated ansiblew" >&2; exit 2; }
[ -n "$CACHE_DIR" ] || { echo "--cache-dir is required" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
INV_DIR="$(cd "$INV_DIR" && pwd)"
RENDER="${LA_BUNDLE_RENDER:-$HERE/render.sh}"
APPLY="${LA_BUNDLE_APPLY:-$HERE/la-bundle-apply.sh}"
t0=$(date +%s)

# The render needs a docker daemon (one throwaway container per server). In the la-toolkit
# that is the host's, through /var/run/docker.sock and the docker group's gid (DOCKER_GID),
# both opt-in in its docker-compose.yml.
if ! docker version >/dev/null 2>&1; then
  echo "FAST-DEPLOY-FAILED: no docker here: in the la-toolkit's docker-compose.yml uncomment the /var/run/docker.sock volume and restart it with DOCKER_GID=\$(getent group docker | cut -d: -f3) docker compose up -d"
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# 1. The deploy line, exactly as ansiblew would run it.
mkdir -p "$work/shim"
cat >"$work/shim/ansible-playbook" <<'SHIM'
#!/usr/bin/env python3
import json, os, sys
json.dump({"argv": sys.argv[1:], "env": {k: v for k, v in os.environ.items() if k.startswith("ANSIBLE_")}},
          open(os.environ["LA_FAST_DEPLOY_RECORD"], "w"))
SHIM
chmod +x "$work/shim/ansible-playbook"
# --nodryrun once: the toolkit's line already carries it, and docopt rejects a repeated flag.
aw_args=()
for a in "$@"; do [ "$a" = --nodryrun ] || aw_args+=("$a"); done
(cd "$INV_DIR" && LA_FAST_DEPLOY_RECORD="$work/line.json" PATH="$work/shim:$PATH" ./ansiblew --nodryrun "${aw_args[@]}" >/dev/null)
[ -s "$work/line.json" ] || { echo "FAST-DEPLOY-FAILED: ansiblew ran no ansible-playbook with: $*"; exit 1; }

# 2. Its parts, and what v1 refuses.
python3 - "$work/line.json" "$INV_DIR" "$work" <<'PY'
import json, os, shlex, sys
line, inv_dir, work = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(line))
argv, env = d["argv"], d["env"]
invs, extra, plays, user, refused = [], [], [], "", []
i = 0
while i < len(argv):
    a = argv[i]
    if a in ("-i", "--inventory"):
        invs.append(os.path.normpath(os.path.join(inv_dir, argv[i + 1]))); i += 2; continue
    if a in ("-u", "--user"):
        user = argv[i + 1]; i += 2; continue
    if a in ("-e", "--extra-vars"):
        extra.append(argv[i + 1]); i += 2; continue
    if a in ("-l", "--limit", "-t", "--tags", "--skip-tags"):
        refused.append(a); i += 2; continue
    if a in ("-C", "--check"):
        refused.append(a); i += 1; continue
    if a.endswith(".yml"):
        plays.append(a)
    i += 1
def fail(msg):
    print("FAST-DEPLOY-FAILED: " + msg); sys.exit(1)
if refused:
    fail("a bundle is always the whole portal; not with %s" % " ".join(refused))
if len(plays) != 1 or not plays[0].endswith("/playbooks/site.yml"):
    fail("only the docker-compose leg (playbooks/site.yml) has a fast deploy; this line runs %s" % plays)
if any("la_hub_only" in e for e in extra):
    fail("a data hub is fast-deployed from its portal's project, which renders the whole stack")
for f in invs:
    if not os.path.isfile(f):
        fail("inventory %s not found" % f)
open(os.path.join(work, "invs"), "w").write("\n".join(invs) + "\n")
open(os.path.join(work, "extra"), "w").write("\n".join(extra) + ("\n" if extra else ""))
open(os.path.join(work, "user"), "w").write(user)
open(os.path.join(work, "env"), "w").write("".join("export %s=%s\n" % (k, shlex.quote(v)) for k, v in sorted(env.items())))
PY
user=$(cat "$work/user")
# shellcheck disable=SC1091
. "$work/env"
inv_args=""
while read -r f; do inv_args="$inv_args -i $f"; done <"$work/invs"
extra_args=()
while IFS= read -r e; do [ -n "$e" ] && extra_args+=(--extra-vars "$e"); done <"$work/extra"

# 3. The cache key.
git_state() { # commit + a hash of any local change, so an edited checkout never hits
  git -C "$1" rev-parse HEAD 2>/dev/null || echo "no-git"
  { git -C "$1" status --porcelain 2>/dev/null; git -C "$1" diff 2>/dev/null; } | sha256sum
}
{
  # The argv only: the environment carries per-run values (the toolkit's log file names).
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["argv"])' "$work/line.json"
  while read -r f; do echo "$f"; sha256sum <"$f"; done <"$work/invs"
  git_state "$REPO"
  git_state "$REPO/ala-install"
  # shellcheck disable=SC2086
  ansible-inventory $inv_args --list 2>/dev/null | python3 -c '
import json, sys
hv = json.load(sys.stdin).get("_meta", {}).get("hostvars", {})
seen = set()
for v in hv.values():
    for k, s in v.items():
        if k.startswith("branding_source") and isinstance(s, str) and s and s not in seen:
            seen.add(s)
            print(s, v.get("branding_git_ref", "HEAD"))' | while read -r src ref; do
    case "$src" in
      http*://*|git@*) echo "$src $ref"; git ls-remote "$src" "$ref" 2>/dev/null | head -1 ;;
      /*) echo "$src"; git_state "$src" ;;
      *) echo "$src"; git_state "$INV_DIR/$src" ;;
    esac
  done
} >"$work/key-input"
key=$(sha256sum <"$work/key-input" | cut -c1-16)
out="$CACHE_DIR/$key"
mkdir -p "$CACHE_DIR"
chmod 0700 "$CACHE_DIR"

# Seconds for people too: "1826" reads better as "30 min 26 s".
human() { [ "$1" -ge 60 ] && echo "$(( $1 / 60 )) min $(( $1 % 60 )) s" || echo "$1 s"; }

# 4. Render, unless cached.
if ! $FORCE && [ -f "$out/.complete" ]; then
  echo "FAST-DEPLOY key=$key render=cached"
else
  echo "FAST-DEPLOY key=$key render=new"
  rm -rf "$out"
  s=$(date +%s)
  # shellcheck disable=SC2086
  (umask 077 && bash "$RENDER" --out "$out" --inventory-args "$inv_args" \
     ${user:+--user "$user"} "${extra_args[@]}" --export)
  touch "$out/.complete"
  d=$(( $(date +%s) - s ))
  echo "FAST-DEPLOY step=render seconds=$d ($(human "$d"))"
fi
touch "$out"   # the newest use sorts first when pruning
# Keep the newest --keep renders: each holds every host's secrets.
ls -1dt "$CACHE_DIR"/*/ 2>/dev/null | tail -n +"$((KEEP + 1))" | while read -r old; do rm -rf "$old"; done

# 5. Apply.
s=$(date +%s)
rc=0
bash "$APPLY" --export-dir "$out/export" --hosts "$out/hosts" ${user:+--ssh-user "$user"} || rc=$?
d=$(( $(date +%s) - s )); total=$(( $(date +%s) - t0 ))
echo "FAST-DEPLOY step=apply seconds=$d ($(human "$d")) rc=$rc"
echo "FAST-DEPLOY step=total seconds=$total ($(human "$total")) rc=$rc"
if [ "$rc" -eq 0 ]; then
  echo "Fast deploy finished in $(human "$total")."
else
  echo "Fast deploy FAILED (rc=$rc) after $(human "$total")."
fi
exit "$rc"

#!/usr/bin/env bash
# roles/la-compose/tasks/post-deploy-image-cleanup.yml: each branding build leaves one
# more branding-builder<suffix>:<hash> image and its buildx cache, and nothing removed
# them: 27 images plus 23.39 GB of cache took a prod disk to 93% (2026-11-05).
# Runs the real cleanup tasks against a shimmed `docker` that serves an image list and
# records the rmi calls:
#   1. only the tags of this render's repositories go, and only those it does not use;
#   2. the portal's empty suffix must not sweep the hubs (branding-builder* would);
#   3. a tag docker refuses (still used by a container) is reported, not forced;
#   4. the build cache is pruned with a window, never wholesale.
# ~10s, no Docker, no root.
set -eu
cd "$(dirname "$0")/.."
SRC="$PWD/roles/la-compose/tasks/post-deploy-image-cleanup.yml"
ANSIBLE_PLAYBOOK="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}ansible-playbook"
command -v "$ANSIBLE_PLAYBOOK" >/dev/null || ANSIBLE_PLAYBOOK=ansible-playbook
PY="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}python3"  # needs PyYAML
command -v "$PY" >/dev/null || PY=python3
PYARG='ansible_python_interpreter={{ ansible_playbook_python }}'

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# What the host has. The portal (empty suffix) and two hubs, one of them deployed by
# another toolkit project and so absent from this render.
cat >"$tmp/images" <<'LIST'
branding-builder|branding-builder:keep_portal
branding-builder|branding-builder:old_portal
branding-builder-botanicas|branding-builder-botanicas:keep_bot
branding-builder-botanicas|branding-builder-botanicas:old_bot
branding-builder-botanicas|branding-builder-botanicas:in_use_bot
branding-builder-botanicas|branding-builder-botanicas:<none>
branding-builder-ajena|branding-builder-ajena:otra1
branding-builder-ajena|branding-builder-ajena:otra2
LIST

mkdir -p "$tmp/bin"
cat >"$tmp/bin/docker" <<SH
#!/bin/sh
case "\$1 \$2" in
  "buildx prune") echo "\$*" >>"$tmp/calls"; echo "Total:	1.5GB"; exit 0 ;;
esac
if [ "\$1" = images ]; then
  # --filter reference=<repo> matches the repository exactly, no wildcard.
  repo=\$(printf '%s\n' "\$@" | sed -n 's/^reference=//p')
  # Like docker: a trailing * matches every repository with that prefix, which is
  # how branding-builder* would reach the hubs of another toolkit project.
  case "\$repo" in
    *\*) awk -F'|' -v r="\${repo%\*}" 'index(\$1, r) == 1 { print \$2 }' "$tmp/images" ;;
    *)   awk -F'|' -v r="\$repo" '\$1 == r { print \$2 }' "$tmp/images" ;;
  esac
  exit 0
fi
if [ "\$1" = rmi ]; then
  echo "rmi \$2" >>"$tmp/calls"
  case "\$2" in *in_use*) echo "image is being used by stopped container" >&2; exit 1 ;; esac
  exit 0
fi
echo "unexpected: \$*" >&2; exit 1
SH
chmod +x "$tmp/bin/docker"

"$PY" - "$SRC" "$tmp/tasks.yml" <<'PY'
import sys, yaml
src, out = sys.argv[1:3]
tasks = yaml.safe_load(open(src))
if not tasks or not any("rmi" in str(t) for t in tasks):
    sys.exit("no cleanup tasks in " + src)
open(out, "w").write(yaml.safe_dump(tasks, sort_keys=False))
PY

cat >"$tmp/play.yml" <<YML
- hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - ansible.builtin.include_tasks: $tmp/tasks.yml
YML

: >"$tmp/calls"
PATH="$tmp/bin:$PATH" ANSIBLE_LOCALHOST_WARNING=false "$ANSIBLE_PLAYBOOK" -i localhost, -e "$PYARG" \
  "$tmp/play.yml" -e ansible_become=false \
  -e '{"branding_render_list": [{"suffix": ""}, {"suffix": "-botanicas"}]}' \
  -e '{"branding_images": ["branding-builder:keep_portal", "branding-builder-botanicas:keep_bot"]}' \
  -e branding_build_cache_ttl=48h >"$tmp/run.log" 2>&1 ||
  { cat "$tmp/run.log" >&2; fail "playbook failed"; }

removed=$(sed -n 's/^rmi //p' "$tmp/calls" | sort | tr '\n' ' ')
expected="branding-builder-botanicas:in_use_bot branding-builder-botanicas:old_bot branding-builder:old_portal "
[ "$removed" = "$expected" ] || fail "expected to try: $expected
got: $removed"
pass "only the unused tags of this render's repositories are removed"

for keep in "branding-builder:keep_portal" "branding-builder-botanicas:keep_bot" \
            "branding-builder-ajena:otra1" "branding-builder-ajena:otra2" \
            "branding-builder-botanicas:<none>"; do
  grep -qF "rmi $keep" "$tmp/calls" && fail "removed a tag it had to keep: $keep"
done
pass "the render's own tags, another project's hub and the untagged ones are left alone"

grep -qE 'rmi (-f|--force)' "$tmp/calls" && fail "rmi is forced: a stopped container would lose its image"
grep -q "still in use, kept: branding-builder-botanicas:in_use_bot" "$tmp/run.log" ||
  fail "a tag docker refused is not reported"
pass "a refused rmi is reported and never forced"

grep -q "buildx prune -f --filter until=48h" "$tmp/calls" || fail "the build cache is not pruned with a window"
grep -qE 'buildx prune[^|]*-a' "$tmp/calls" && fail "the build cache is pruned wholesale: the CI rebuilds cold"
pass "build cache older than the window is discarded, the rest kept"

grep -q "failed=0" "$tmp/run.log" || fail "the cleanup failed the play"
pass "housekeeping never fails a deploy that worked"
echo "All checks passed."

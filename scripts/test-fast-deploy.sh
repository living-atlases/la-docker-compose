#!/usr/bin/env bash
# scripts/bundle/fast-deploy.sh (la-toolkit TASK-31) against a shimmed generated ansiblew,
# render.sh, la-bundle-apply.sh and ansible-inventory:
#   1. the deploy line comes from ansiblew itself: absolute inventories (hubs included), the
#      ssh user and the extra vars reach the render; the applier gets the ssh user; the render
#      dir and the cache are root-only;
#   2. the same line again is a cache hit: no render, the apply still runs;
#   3. an inventory change, or a local change in the branding checkout, renders again;
#   4. refused before any render: --limit/--tags, a VM playbook (hybrid line), a data hub;
#   5. only the newest --keep renders are kept;
#   6. a failed apply is the script's exit code.
# ~2s, no Docker, no Ansible.
set -eu
cd "$(dirname "$0")/.."

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
inv=$tmp/inv/lademo-inventories
mkdir -p "$inv" "$tmp/inv/hub1-inventories" "$tmp/bin" "$tmp/inv/lademo-branding" "$tmp/cache"
for f in lademo-inventory.ini lademo-local-extras.ini lademo-local-passwords.ini; do echo "[x]" >"$inv/$f"; done
echo "[h]" >"$tmp/inv/hub1-inventories/hub1-inventory.ini"
git -C "$tmp/inv/lademo-branding" init -q && echo a >"$tmp/inv/lademo-branding/a" &&
  git -C "$tmp/inv/lademo-branding" add a && git -C "$tmp/inv/lademo-branding" -c user.email=t@t -c user.name=t commit -qm a

# A generated ansiblew, reduced to what matters here: it builds the line and runs it via env.
cat >"$inv/ansiblew" <<'AW'
#!/bin/bash
extra=""; limit=""; play="/lad/playbooks/site.yml"
[ "$(printf '%s\n' "$@" | grep -c '^--nodryrun$')" = 1 ] || { echo "docopt: --nodryrun repeated" >&2; exit 1; }
for a in "$@"; do case "$a" in
  --extra=*) extra="${a#--extra=}" ;; --limit=*) limit="--limit ${a#--limit=}" ;;
  --vm) play="/lad/playbooks/site.yml /ai/ansible/collectory.yml" ;;
  --hub) extra="$extra la_hub_only=hub1" ;;
esac; done
exec env ANSIBLE_ROLES_PATH=/lad/roles ANSIBLE_LOG_PATH=/logs/run-$RANDOM.log sh -c "ansible-playbook -u ubuntu -i lademo-inventory.ini -i lademo-local-extras.ini -i ../hub1-inventories/hub1-inventory.ini -i lademo-local-passwords.ini $play $limit --extra-vars '$extra' --extra-vars 'target=all'"
AW
chmod +x "$inv/ansiblew"
cat >"$tmp/bin/ansible-inventory" <<'EOF'
#!/bin/sh
echo '{"_meta": {"hostvars": {"h1": {"branding_source": "../lademo-branding"}}}}'
EOF
cat >"$tmp/render.sh" <<EOF
#!/bin/bash
echo "render \$* roles=\$ANSIBLE_ROLES_PATH umask=\$(umask)" >>"$tmp/calls"
while [ \$# -gt 0 ]; do [ "\$1" = --out ] && out=\$2; shift; done
mkdir -p "\$out/export"; echo "h1 vm-1" >"\$out/hosts"
EOF
cat >"$tmp/apply.sh" <<EOF
#!/bin/bash
echo "apply \$*" >>"$tmp/calls"
exit \${APPLY_RC:-0}
EOF
chmod +x "$tmp/bin/"* "$tmp/render.sh" "$tmp/apply.sh"
export PATH="$tmp/bin:$PATH" LA_BUNDLE_RENDER=$tmp/render.sh LA_BUNDLE_APPLY=$tmp/apply.sh

fd() { : >"$tmp/calls"
  bash scripts/bundle/fast-deploy.sh --inventory-dir "$inv" --cache-dir "$tmp/cache" "$@" >"$tmp/out" 2>&1; }
std=(-- --alainstall=/ai --nodryrun --ladocker=/lad "--extra=auto_deploy=true skip_services=sds-static-home" --user ubuntu all)

# 1. first run
fd "${std[@]}" || { cat "$tmp/out" >&2; fail "1: failed"; }
grep -q "^render --out $tmp/cache/[0-9a-f]\{16\} --inventory-args  -i $inv/lademo-inventory.ini -i $inv/lademo-local-extras.ini -i $tmp/inv/hub1-inventories/hub1-inventory.ini -i $inv/lademo-local-passwords.ini --user ubuntu --extra-vars auto_deploy=true skip_services=sds-static-home --extra-vars target=all --export roles=/lad/roles umask=0077$" "$tmp/calls" ||
  { cat "$tmp/calls" >&2; fail "1: the render did not get ansiblew's line"; }
grep -q "^apply --export-dir $tmp/cache/[0-9a-f]*/export --hosts $tmp/cache/[0-9a-f]*/hosts --ssh-user ubuntu$" "$tmp/calls" ||
  { cat "$tmp/calls" >&2; fail "1: the apply did not get the ssh user"; }
grep -q '^FAST-DEPLOY key=[0-9a-f]* render=new$' "$tmp/out" && grep -q '^FAST-DEPLOY step=total .* rc=0$' "$tmp/out" || fail "1: no summary"
[ "$(stat -c %a "$tmp/cache")" = 700 ] || fail "1: the cache dir is not root-only"
pass "the deploy line comes from ansiblew; render and apply get its inventories, user and vars"

# 2. cache hit, although ansiblew's environment changes every run
fd "${std[@]}" || fail "2: failed"
grep -q '^render ' "$tmp/calls" && fail "2: rendered again with nothing changed"
grep -q '^apply ' "$tmp/calls" && grep -q 'render=cached' "$tmp/out" || fail "2: no apply or no cache report"
pass "the same line again reuses the render and still applies"

# 3. an inventory change, then a local branding change, render again
echo "[y]" >>"$inv/lademo-local-extras.ini"
fd "${std[@]}" && grep -q '^render ' "$tmp/calls" || fail "3: an inventory change hit the cache"
echo b >"$tmp/inv/lademo-branding/a"
fd "${std[@]}" && grep -q '^render ' "$tmp/calls" || fail "3: a branding change hit the cache"
pass "an inventory or branding change renders again"

# 4. refused before any render
for bad in "--limit=vm-1" "--vm" "--hub"; do
  rc=0; fd -- --alainstall=/ai --ladocker=/lad "$bad" --user ubuntu all || rc=$?
  [ "$rc" -ne 0 ] && grep -q '^FAST-DEPLOY-FAILED' "$tmp/out" || { cat "$tmp/out" >&2; fail "4: $bad was not refused"; }
  [ -s "$tmp/calls" ] && fail "4: $bad reached the render or the apply"
done
pass "--limit, a hybrid VM playbook and a data hub are refused before anything runs"

# 5. keep the newest renders only
echo "[z]" >>"$inv/lademo-local-extras.ini"
fd --keep 2 "${std[@]}" || fail "5: failed"
[ "$(find "$tmp/cache" -mindepth 1 -maxdepth 1 -type d | wc -l)" = 2 ] || fail "5: $(ls "$tmp/cache" | wc -l) renders kept, not 2"
pass "only the newest --keep renders are kept"

# 6. a failed apply
rc=0; APPLY_RC=3 fd "${std[@]}" || rc=$?
[ "$rc" = 3 ] && grep -q '^FAST-DEPLOY step=total .* rc=3$' "$tmp/out" || fail "6: rc=$rc"
pass "a failed apply is the exit code"

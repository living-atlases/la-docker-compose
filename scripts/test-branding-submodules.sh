#!/usr/bin/env bash
# Branding submodules (commonui-bs3-2019: bootstrap, jquery, ala-styles) must reach the
# branding build directory with content, or every page linking to them comes up
# unstyled. Data hubs shipped it empty (TASK-48): the .gitmodules stat and the
# `git submodule update` in stage-branding-source.yml ran on the compose hosts, where the
# controller-side branding_source_path does not exist, so they were skipped.
#
# 1. static: the tasks that read branding_source_path run on the controller, as its owner
#    (not root: #416 left the submodule root-owned and synchronize could not read it);
# 2. behaviour: the REAL guard tasks from the role, run against fixtures, fail on an
#    empty submodule and pass on a populated one, a branding without .gitmodules, and a
#    disabled branding (their loop is templated before `when`). ~5s, no cluster.
set -eu
cd "$(dirname "$0")/.."

TASKS=roles/la-compose/tasks/stage-branding-source.yml
PLAYBOOK=.venv-molecule/bin/ansible-playbook
[ -x "$PLAYBOOK" ] || PLAYBOOK=$(command -v ansible-playbook) || { echo "[FAIL] ansible-playbook not found" >&2; exit 1; }
PY=.venv-molecule/bin/python3
[ -x "$PY" ] || PY=python3

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ── 1. controller-side tasks are delegated ────────────────────────────────────
"$PY" - "$TASKS" "$tmp/guard.yml" <<'PY'
import sys, yaml
tasks = yaml.safe_load(open(sys.argv[1]))
by_name = {t.get("name"): t for t in tasks}
bad = []
for name in ("Stat branding .gitmodules (local source)",
             "Initialize branding git submodules (local source)"):
    t = by_name.get(name)
    if t is None:
        bad.append("missing task: " + name)
    elif t.get("delegate_to") != "localhost":
        bad.append("not delegated to localhost: " + name)
    # The inventory sets ansible_become=yes, and an inventory connection var beats the
    # `become:` keyword: only a task var keeps git from running as root (#416).
    elif (t.get("vars") or {}).get("ansible_become") is not False:
        bad.append("does not set vars.ansible_become: false (keyword is overridden): " + name)
repair = by_name.get("Give the branding checkout back to its owner (controller)")
if repair is None or repair.get("delegate_to") != "localhost":
    bad.append("missing controller-side ownership repair of the branding checkout")
if bad:
    print("[FAIL] " + "; ".join(bad), file=sys.stderr)
    sys.exit(1)
guard = [by_name[n] for n in ("Find the branding's submodules in the build directory",
                              "Fail if a branding submodule reached the build directory empty")]
yaml.safe_dump([{"hosts": "localhost", "gather_facts": False, "tasks": guard}],
               open(sys.argv[2], "w"), sort_keys=False)
PY
pass "the .gitmodules stat and the submodule init run on the controller, as the checkout owner"

# ── 2. the guard, against fixtures ────────────────────────────────────────────
src="$tmp/src"; out="$tmp/data"
mkdir -p "$src" "$out/dockerfiles/branding-hub/commonui-bs3-2019"
printf '[submodule "commonui-bs3-2019"]\n\tpath = commonui-bs3-2019\n\turl = https://example.org/commonui\n' >"$src/.gitmodules"

run() { # extra -e args...
  "$PLAYBOOK" -i localhost, -c local "$tmp/guard.yml" \
    -e docker_compose_data_dir="$out" -e '{"inst": {"suffix": "-hub"}}' "$@" >"$tmp/log" 2>&1
}
enabled=(-e branding_source_path="$src" -e inst_branding_enabled=true
         -e '{"branding_gitmodules": {"stat": {"exists": true}}}')

run "${enabled[@]}" && fail "empty submodule passed: $(tail -20 "$tmp/log")"
grep -q 'Branding submodule commonui-bs3-2019 is empty' "$tmp/log" || fail "empty submodule: wrong failure: $(tail -20 "$tmp/log")"
pass "an empty submodule in the build directory fails the deploy"

mkdir -p "$out/dockerfiles/branding-hub/commonui-bs3-2019/build/css"
touch "$out/dockerfiles/branding-hub/commonui-bs3-2019/build/css/ala-styles.css"
run "${enabled[@]}" || fail "populated submodule rejected: $(tail -20 "$tmp/log")"
pass "a populated submodule passes"

rm "$src/.gitmodules"
run -e branding_source_path="$src" -e inst_branding_enabled=true \
    -e '{"branding_gitmodules": {"stat": {"exists": false}}}' || fail "no .gitmodules rejected: $(tail -20 "$tmp/log")"
pass "a branding without submodules passes"

run -e inst_branding_enabled=false || fail "disabled branding rejected: $(tail -20 "$tmp/log")"
pass "a disabled branding (no branding_source_path) passes"

#!/usr/bin/env bash
# The deploy-in-progress marker (/run/la-compose-deploy.marker) goes away when the deploy
# fails too: autoheal, the image GC and the trivy scan stand down while it is fresh (up to
# 6 h), so a failed deploy that left it behind switched them off on the host that needed them.
#   1. structure: the task that removes it is in the `always` of the very block whose body
#      touches it, with the same path, tag `always` and become; the body no longer removes it;
#   2. behaviour: a play with that block shape, failing after the touch, leaves no marker
#      (and one that does not fail leaves none either).
# ~5s, no Docker, no root.
set -u
cd "$(dirname "$0")/.."
ANSIBLE_PLAYBOOK="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}ansible-playbook"
command -v "$ANSIBLE_PLAYBOOK" >/dev/null || ANSIBLE_PLAYBOOK=ansible-playbook
PY="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}python3"
command -v "$PY" >/dev/null || PY=python3
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0

"$PY" - "$T" <<'PY' && echo "[PASS] the marker is removed in the always of the block that touches it" || exit 1
import sys, yaml
tasks = yaml.safe_load(open("roles/la-compose/tasks/main.yml"))
def marker_tasks(ts, state):
    return [t for t in ts or [] if (t.get("ansible.builtin.file") or {}).get("state") == state
            and "deploy_marker" in str((t.get("ansible.builtin.file") or {}).get("path"))]
blocks = [b for b in tasks if marker_tasks(b.get("block"), "touch")]
assert len(blocks) == 1, f"{len(blocks)} blocks touch the marker"
b = blocks[0]
touch, = marker_tasks(b["block"], "touch")
assert not marker_tasks(b["block"], "absent"), "the block body still removes the marker (skipped on failure)"
rm = marker_tasks(b.get("always"), "absent")
assert len(rm) == 1, "no marker removal in the block's always"
rm = rm[0]
assert rm["ansible.builtin.file"]["path"] == touch["ansible.builtin.file"]["path"], "touch and removal paths differ"
assert "always" in rm.get("tags", []) and rm.get("become") is True, f"removal tags/become: {rm.get('tags')} {rm.get('become')}"
# The shape step 2 runs: the same block keywords, the role's tasks swapped for a touch,
# an optional failure and the real removal task.
play = [{"hosts": "localhost", "gather_facts": False, "tasks": [{
    "name": "shape", "block": [
        {"ansible.builtin.file": {"path": "{{ marker }}", "state": "touch"}},
        {"ansible.builtin.fail": {"msg": "deploy failed"}, "when": "fail_deploy | bool"},
    ],
    "always": [dict(rm, become=False, **{"ansible.builtin.file": {"path": "{{ marker }}", "state": "absent"}})],
}]}]
yaml.safe_dump(play, open(f"{sys.argv[1]}/play.yml", "w"))
PY

for f in true false; do
  ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_NOCOLOR=1 "$ANSIBLE_PLAYBOOK" -i localhost, -c local \
    -e "marker=$T/deploy.marker" -e "fail_deploy=$f" -e 'ansible_python_interpreter={{ ansible_playbook_python }}' \
    "$T/play.yml" >"$T/run-$f.log" 2>&1
  rc=$?
  if [ -e "$T/deploy.marker" ]; then echo "[FAIL] marker left behind (fail_deploy=$f, rc=$rc)" >&2; cat "$T/run-$f.log" >&2; fail=1
  elif { [ "$f" = true ] && [ "$rc" = 0 ]; } || { [ "$f" = false ] && [ "$rc" != 0 ]; }; then
    echo "[FAIL] unexpected exit $rc (fail_deploy=$f)" >&2; cat "$T/run-$f.log" >&2; fail=1
  else echo "[PASS] fail_deploy=$f: the play exits $rc and leaves no marker"; fi
done
exit $fail

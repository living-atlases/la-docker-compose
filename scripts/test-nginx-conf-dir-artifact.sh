#!/usr/bin/env bash
# nginx.conf is bind-mounted as a file. When a `docker compose up` runs while it is
# missing, Docker leaves a root-owned DIRECTORY there, and `template` then writes
# nginx.conf.j2 INSIDE it instead of replacing it: la_nginx cannot start again, build
# after build (docker-1, #417/#418).
#
# Runs the REAL guard tasks from generate-compose.yml against fixtures: a directory at
# the nginx.conf path is removed, a regular file is left alone. And the guard must come
# before "Generate nginx.conf". ~3s, no cluster.
set -eu
cd "$(dirname "$0")/.."

TASKS=roles/la-compose/tasks/generate-compose.yml
PLAYBOOK=.venv-molecule/bin/ansible-playbook
[ -x "$PLAYBOOK" ] || PLAYBOOK=$(command -v ansible-playbook) || { echo "[FAIL] ansible-playbook not found" >&2; exit 1; }
PY=.venv-molecule/bin/python3
[ -x "$PY" ] || PY=python3

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

"$PY" - "$TASKS" "$tmp/guard.yml" <<'PY'
import sys, yaml
tasks = yaml.safe_load(open(sys.argv[1]))
names = [t.get("name") for t in tasks]
stat, remove, gen = ("Stat nginx.conf (a directory there is a Docker bind-mount artifact)",
                     "Remove the directory Docker left where nginx.conf goes",
                     "Generate nginx.conf")
missing = [n for n in (stat, remove, gen) if n not in names]
if missing:
    print("[FAIL] missing task(s): " + ", ".join(missing), file=sys.stderr); sys.exit(1)
if not names.index(stat) < names.index(remove) < names.index(gen):
    print("[FAIL] the directory guard must run before 'Generate nginx.conf'", file=sys.stderr); sys.exit(1)
guard = [dict(t) for t in tasks if t.get("name") in (stat, remove)]
for t in guard:
    t.pop("become", None)  # fixtures live in a tmpdir we own
yaml.safe_dump([{"hosts": "localhost", "gather_facts": False, "tasks": guard}],
               open(sys.argv[2], "w"), sort_keys=False)
PY
pass "the nginx.conf directory guard runs before 'Generate nginx.conf'"

run() {
  "$PLAYBOOK" -i localhost, -c local "$tmp/guard.yml" \
    -e nginx_conf_dir="$tmp/nginx" -e '{"services_enabled": ["nginx"]}' >"$tmp/log" 2>&1
}

mkdir -p "$tmp/nginx/nginx.conf"
touch "$tmp/nginx/nginx.conf/nginx.conf.j2"
run || fail "guard run failed: $(tail -20 "$tmp/log")"
[ ! -e "$tmp/nginx/nginx.conf" ] || fail "a directory at nginx.conf survived the guard"
pass "a directory Docker left at nginx.conf is removed"

echo "user nginx;" >"$tmp/nginx/nginx.conf"
run || fail "guard run failed on a regular file: $(tail -20 "$tmp/log")"
[ -f "$tmp/nginx/nginx.conf" ] && grep -q "user nginx" "$tmp/nginx/nginx.conf" || fail "a regular nginx.conf was touched"
pass "a regular nginx.conf is left alone"

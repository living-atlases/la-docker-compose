#!/usr/bin/env bash
# The use_la_site_certs=false branch already recreates a drifted nginx before the
# main `up` (config-hash mismatch -> `docker compose rm -sf`, letting the main
# `up -d --no-recreate` recreate it). The use_la_site_certs=true branch (every
# l-a.site-hosted deployment, this CI included) skipped that: main.yml's post-up
# check only WARNS about drift, nothing applies it, so a stale nginx never picks up
# a newly added volume mount (a hub's branding, e.g.) on a --no-recreate hot
# redeploy -- 404s on files a fresh nginx would serve (build #403, TASK-41).
#
# This extracts the REAL shell script from the "nginx: recreate if its own
# definition drifted (use_la_site_certs branch)" task and runs it against a fake
# `docker` on PATH, so it cannot drift from the code it guards. ~1s, no cluster.
set -eu
cd "$(dirname "$0")/.."

ROLE=roles/la-compose/tasks/generate-compose.yml

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

# the task's shell script, taken from the role itself
script=$(python3 - "$ROLE" <<'EOF'
import sys, re
t = open(sys.argv[1]).read()
m = re.search(
    r"- name: \"nginx: recreate if its own definition drifted \(use_la_site_certs branch\)\"\n"
    r"  ansible\.builtin\.shell: \|\n((?:    .*\n)+)",
    t)
if not m:
    print(""); sys.exit(0)
lines = m.group(1).splitlines()
# de-indent the block scalar's fixed 4-space prefix
print("\n".join(l[4:] if l.startswith("    ") else l for l in lines))
EOF
)
[ -n "$script" ] || fail "could not find the nginx drift-recreate script in $ROLE"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# run <config-hash-of-nginx-wanted> <label-of-running-container> -> stdout, with a
# fake `docker` on PATH that reports a fixed "have" hash for a fake running nginx.
run() {
    local want="$1" have="$2"
    local bindir="$T/bin"; mkdir -p "$bindir"
    cat > "$bindir/docker" <<DOCKER
#!/usr/bin/env bash
if [ "\$1" = "compose" ] && [ "\$2" = "config" ] && [ "\$3" = "--hash" ]; then
    echo "nginx $want"
elif [ "\$1" = "compose" ] && [ "\$2" = "ps" ]; then
    echo "fake-nginx-container-id"
elif [ "\$1" = "inspect" ]; then
    echo "$have"
elif [ "\$1" = "compose" ] && [ "\$2" = "rm" ]; then
    echo "RM_CALLED: \$*"
else
    echo "unexpected docker call: \$*" >&2; exit 1
fi
DOCKER
    chmod +x "$bindir/docker"
    PATH="$bindir:$PATH" bash -c "$script" 2>&1
}

# 1. hashes match: no recreate, no rm
out=$(run "abc123" "abc123")
echo "$out" | grep -q 'RM_CALLED' && fail "no drift: rm was called anyway, got: $out"
pass "no drift -> nginx is left alone"

# 2. hashes differ: recreate, exactly one rm of nginx
out=$(run "abc123" "def456")
echo "$out" | grep -q 'Recreating services whose definition changed: *nginx' \
    || fail "drift: expected the recreate message, got: $out"
echo "$out" | grep -q 'RM_CALLED: compose rm -sf nginx' \
    || fail "drift: expected 'docker compose rm -sf nginx', got: $out"
pass "drift -> nginx is torn down for the main up to recreate"

echo "ALL PASS: nginx drift recreate (use_la_site_certs branch)"

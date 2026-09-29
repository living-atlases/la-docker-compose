#!/usr/bin/env bash
# scripts/validate-healthcheck-commands.sh --cache-dir: a (image ID, binary) that passed is
# not probed again. One container start per image cost 2.4-3.9 min of every playbook run
# (#430/#431). Runs the real script against a shimmed `docker` that serves a compose config
# and counts the probe containers:
#   1. first run probes every image and caches the passes;
#   2. second run with the same image IDs starts no container;
#   3. a failing probe is never cached (re-probed, and still fails the run);
#   4. a new image ID under the same tag is probed again;
#   5. without --cache-dir every run probes, as before.
# ~2s, no Docker, no root.
set -eu
cd "$(dirname "$0")/.."
SCRIPT="$PWD/scripts/validate-healthcheck-commands.sh"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/compose" "$tmp/bin"
: >"$tmp/compose/docker-compose.yml"
echo 1 >"$tmp/generation"   # bump to give every image a new ID

write_config() { # $1: "ok" or "broken" for the second service's binary
  cat >"$tmp/config.json" <<JSON
{"services": {
  "shell": {"image": "img/shell:1", "healthcheck": {"test": ["CMD-SHELL", "true"]}},
  "curl":  {"image": "img/curl:1",  "healthcheck": {"test": ["CMD", "$( [ "$1" = broken ] && echo nocurl || echo curl )", "-f", "x"]}},
  "none":  {"image": "img/none:1"}
}}
JSON
}
cat >"$tmp/bin/docker" <<SH
#!/bin/sh
case "\$1 \$2" in
  "version "*) exit 0 ;;
  "compose -f") cat "$tmp/config.json" ;;
  "image inspect")
    if [ "\$3" = "-f" ]; then echo "sha256:\$(printf '%s-%s' "\$5" "\$(cat $tmp/generation)" | sha1sum | cut -c1-40)"; fi ;;
  "run --rm")
    echo "\$*" >>"$tmp/probes"
    case "\$*" in *"--entrypoint nocurl"*) echo 'exec: "nocurl": executable file not found in \$PATH' >&2; exit 127 ;; esac
    echo "unknown option" >&2; exit 2 ;;
  *) echo "unexpected: \$*" >&2; exit 1 ;;
esac
SH
chmod +x "$tmp/bin/docker"

probe() { # extra args...; sets $out, $rc, $n (containers started)
  : >"$tmp/probes"
  set +e
  out=$(PATH="$tmp/bin:$PATH" bash "$SCRIPT" --compose-dir "$tmp/compose" "$@" 2>&1); rc=$?
  set -e
  n=$(grep -c . "$tmp/probes" || true)
}
cache="$tmp/cache"

write_config ok
probe --cache-dir "$cache"
[ "$rc" = 0 ] && [ "$n" = 2 ] || fail "first run: rc=$rc, $n probes (want 0, 2): $out"
[ "$(ls "$cache" | wc -l)" = 2 ] || fail "first run: $(ls "$cache" | wc -l) cache entries, want 2"
pass "the first run probes each image and caches the passes"

probe --cache-dir "$cache"
[ "$rc" = 0 ] && [ "$n" = 0 ] || fail "second run: rc=$rc, $n probes (want 0, 0): $out"
grep -q "(cached)" <<<"$out" || fail "second run: no (cached) in the report"
pass "unchanged images are not probed again"

write_config broken
probe --cache-dir "$cache"
[ "$rc" != 0 ] && [ "$n" = 1 ] || fail "broken: rc=$rc, $n probes (want non-zero, 1): $out"
probe --cache-dir "$cache"
[ "$rc" != 0 ] && [ "$n" = 1 ] || fail "broken again: rc=$rc, $n probes; a failure must never be cached"
pass "a failing probe is not cached: re-probed and still fails"

write_config ok
echo 2 >"$tmp/generation"
probe --cache-dir "$cache"
[ "$rc" = 0 ] && [ "$n" = 2 ] || fail "new image IDs: rc=$rc, $n probes (want 0, 2)"
pass "a new image ID under the same tag is probed again"

probe
probe
[ "$rc" = 0 ] && [ "$n" = 2 ] || fail "no cache dir: $n probes on a repeat run, want 2"
pass "without --cache-dir every run probes, as before"
echo "All checks passed."

#!/usr/bin/env bash
# Fixtures for check-nginx-duplicate-server-names.sh: the pre-45d2ec4 layout of a
# shared hub vhost (own file + "-remote" stub, same server_name) must fail; the
# merged layout, and a vhost whose http and https blocks repeat the name, must pass.
set -eu
cd "$(dirname "$0")/.."
CHECK=scripts/check-nginx-duplicate-server-names.sh

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

vhost() { # file, server_name, locations...
  f="$1"; name="$2"; shift 2
  for port in 80 "443 ssl"; do
    printf 'server {\n  listen %s;\n  server_name %s;\n' "$port" "$name"
    for loc in "$@"; do printf '  location %s { }\n' "$loc"; done
    printf '}\n'
  done >"$f"
}

mkdir "$tmp/split" "$tmp/merged"
vhost "$tmp/split/hub.example.org.conf" hub.example.org / /robots.txt
vhost "$tmp/split/hub.example.org-hub.example.org-remote.conf" hub.example.org /regions /species
vhost "$tmp/split/portal.example.org.conf" "portal.example.org www.example.org" /
vhost "$tmp/merged/hub.example.org.conf" hub.example.org / /robots.txt /records /regions /species
vhost "$tmp/merged/portal.example.org.conf" "portal.example.org www.example.org" /

out="$(bash "$CHECK" "$tmp/split" 2>&1)" && fail "split vhost passed: $out"
echo "$out" | grep '^ *hub.example.org:' | grep -q 'hub.example.org-hub.example.org-remote.conf' ||
  fail "split vhost: wrong report: $out"
echo "$out" | grep -q 'portal' && fail "split vhost: portal wrongly reported: $out"
pass "own file + remote stub with the same server_name is rejected"

bash "$CHECK" "$tmp/merged" >/dev/null || fail "merged vhost rejected"
pass "one file per server_name (http+https blocks) passes"

bash "$CHECK" "$tmp/missing" | grep -q SKIP || fail "missing dir not skipped"
pass "missing dir is skipped"

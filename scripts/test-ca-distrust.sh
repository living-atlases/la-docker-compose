#!/usr/bin/env bash
# scripts/ca-distrust-ci-collect.sh + ca-distrust-ci-summary.sh against a shimmed `docker`
# serving three containers:
#   fixed    bundle without the distrusted root, no Java, no Node    -> OK
#   stale    bundle, cacerts and Node roots with emSign ECC Root G3  -> TRUSTS x3
#   nobundle no CA bundle (distroless)                               -> ERR
# The kept emSign C1 root must not count: roots are matched by SHA-256, not by name.
# ~2s, no Docker, no root.
set -eu
cd "$(dirname "$0")/.."
FX="$PWD/scripts/fixtures/ca-distrust"
pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat "$FX/kept-emsign-c1.pem" >"$tmp/fixed.pem"
cat "$FX/kept-emsign-c1.pem" "$FX/distrusted-emsign-ecc-g3.pem" >"$tmp/stale.pem"
mkdir -p "$tmp/bin"
cat >"$tmp/bin/docker" <<SH
#!/bin/sh
[ "\$1" = ps ] && { printf 'fixed\tlivingatlases/apikey:1.7.0\nstale\tsolr:9.4\nnobundle\tgcr.io/distroless/static\n'; exit 0; }
[ "\$1" = exec ] || exit 1
name=\$2; shift 2
case "\$name:\$*" in
  fixed:cat\ /etc/ssl/certs/ca-certificates.crt) cat "$tmp/fixed.pem" ;;
  stale:cat\ /etc/ssl/certs/ca-certificates.crt) cat "$tmp/stale.pem" ;;
  stale:sh\ -c\ *keytool*) echo "Alias name: emsigneccrootcag3 [jdk]"
                           echo "	 SHA256: 86:A1:EC:BA:08:9C:4A:8D:3B:BE:27:34:C6:12:BA:34:1D:81:3E:04:3C:F9:E8:A8:62:CD:5C:57:A3:6B:BE:6B" ;;
  stale:sh\ -c\ command\ -v\ node) echo /usr/bin/node ;;
  stale:node\ -e\ *) cat "$tmp/stale.pem" ;;
  *:sh\ -c\ *keytool*) exit 3 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$tmp/bin/docker"

mkdir -p "$tmp/out"
DOCKER="$tmp/bin/docker" bash scripts/ca-distrust-ci-collect.sh >"$tmp/out/host1.tsv"
got() { awk -F'\t' -v c="$1" -v s="$2" '$1 == c && $3 == s {print $4}' "$tmp/out/host1.tsv"; }

[ "$(got fixed /etc/ssl/certs/ca-certificates.crt)" = OK ] || fail "fixed bundle: $(cat "$tmp/out/host1.tsv")"
pass "a bundle with only kept emSign roots is OK"
for s in /etc/ssl/certs/ca-certificates.crt jvm node; do
  [ "$(got stale "$s")" = TRUSTS ] || fail "stale $s: $(cat "$tmp/out/host1.tsv")"
done
grep -q 'roots: 86A1ECBA' "$tmp/out/host1.tsv" || fail "fingerprint missing from the detail"
pass "the distrusted root is found in the bundle, the JVM cacerts and Node's roots"
[ "$(got nobundle system)" = ERR ] || fail "nobundle: $(cat "$tmp/out/host1.tsv")"
[ "$(awk -F'\t' '$1 == "fixed" && $3 != "/etc/ssl/certs/ca-certificates.crt"' "$tmp/out/host1.tsv")" = "" ] \
  || fail "fixed has no Java or Node, but a line for them was printed"
pass "an image without bundle is ERR; absent JVM/Node print nothing"

if bash scripts/ca-distrust-ci-summary.sh "$tmp/out" >"$tmp/sum" 2>&1; then fail "summary passed with TRUSTS"; fi
grep -q 'host1: 3 trusting, 1 ok, 1 unreadable' "$tmp/sum" || fail "summary counts: $(cat "$tmp/sum")"
pass "the summary counts per host and exits 1 on TRUSTS"
awk -F'\t' '$1 != "stale"' "$tmp/out/host1.tsv" >"$tmp/out/host1.tsv.new" && mv "$tmp/out/host1.tsv.new" "$tmp/out/host1.tsv"
bash scripts/ca-distrust-ci-summary.sh "$tmp/out" >"$tmp/sum" 2>&1 || fail "summary failed on ERR only: $(cat "$tmp/sum")"
pass "ERR alone does not fail the summary"

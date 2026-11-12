#!/usr/bin/env bash
# scripts/ca-distrust-ci-collect.sh + ca-distrust-ci-summary.sh against a shimmed `docker`
# serving five containers:
#   fixed    bundle without the distrusted root, no Java, no Node    -> OK
#   stale    bundle, cacerts and Node roots with emSign ECC Root G3  -> TRUSTS x3
#   nobundle neither `cat` nor `docker cp` finds a bundle            -> ERR
#   nocat    no shell, but `docker cp` reads a stale bundle          -> TRUSTS
#   catcher  stale bundle in an image the shipped table exempts      -> TRUSTS, then EXEMPT
#   pyonly   CLEAN system bundle, stale certifi (the airflow case)    -> OK + TRUSTS
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
[ "\$1" = ps ] && { printf 'fixed\tlivingatlases/apikey:1.7.0\nstale\tsolr:9.4\nnobundle\tgcr.io/distroless/static\nnocat\ttwinproduction/gatus:v5.36.0\ncatcher\tmailhog/mailhog:v1.0.1\npyonly\tlivingatlases/ala-hub:4.2.0\n'; exit 0; }
# \`docker cp -L <ctr>:<path> -\` writes a tar: it needs nothing inside the container, so a
# distroless image with no shell is still readable.
if [ "\$1" = cp ]; then
  for a in "\$@"; do case "\$a" in *:*) ref=\$a ;; esac; done
  case "\${ref%%:*}" in
    nocat|catcher) tar -cf - -C "$tmp" stale.pem ;;
    *) exit 1 ;;
  esac
  exit 0
fi
[ "\$1" = exec ] || exit 1
name=\$2; shift 2
case "\$name:\$*" in
  fixed:cat\ /etc/ssl/certs/ca-certificates.crt) cat "$tmp/fixed.pem" ;;
  stale:cat\ /etc/ssl/certs/ca-certificates.crt) cat "$tmp/stale.pem" ;;
  stale:sh\ -c\ *keytool*) echo "Alias name: emsigneccrootcag3 [jdk]"
                           echo "	 SHA256: 86:A1:EC:BA:08:9C:4A:8D:3B:BE:27:34:C6:12:BA:34:1D:81:3E:04:3C:F9:E8:A8:62:CD:5C:57:A3:6B:BE:6B" ;;
  stale:sh\ -c\ command\ -v\ node) echo /usr/bin/node ;;
  stale:node\ -e\ *) cat "$tmp/stale.pem" ;;
  stale:sh\ -c\ command\ -v\ python) echo /usr/bin/python ;;
  stale:python\ -c\ *certifi*) cat "$tmp/stale.pem" ;;
  pyonly:cat\ /etc/ssl/certs/ca-certificates.crt) cat "$tmp/fixed.pem" ;;
  pyonly:sh\ -c\ command\ -v\ python) echo /usr/bin/python ;;
  pyonly:python\ -c\ *certifi*) cat "$tmp/stale.pem" ;;
  *:sh\ -c\ *keytool*) exit 3 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$tmp/bin/docker"

mkdir -p "$tmp/out"
DOCKER="$tmp/bin/docker" bash scripts/ca-distrust-ci-collect.sh >"$tmp/out/host1.tsv"
got() { awk -F'\t' -v c="$1" -v s="$2" '$1 == c && $3 == s {print $4}' "$tmp/out/host1.tsv"; }
sys=/etc/ssl/certs/ca-certificates.crt

[ "$(got fixed $sys)" = OK ] || fail "fixed bundle: $(cat "$tmp/out/host1.tsv")"
pass "a bundle with only kept emSign roots is OK"
for s in $sys jvm node certifi; do
  [ "$(got stale "$s")" = TRUSTS ] || fail "stale $s: $(cat "$tmp/out/host1.tsv")"
done
grep -q 'roots: 86A1ECBA' "$tmp/out/host1.tsv" || fail "fingerprint missing from the detail"
pass "the distrusted root is found in the bundle, the JVM cacerts, Node's roots and certifi"
[ "$(got nobundle system)" = ERR ] || fail "nobundle: $(cat "$tmp/out/host1.tsv")"
[ "$(awk -F'\t' '$1 == "fixed" && $3 != "/etc/ssl/certs/ca-certificates.crt"' "$tmp/out/host1.tsv")" = "" ] \
  || fail "fixed has no Java or Node, but a line for them was printed"
pass "an image without bundle is ERR; absent JVM/Node print nothing"

# The gatus case: a distroless image has the bundle but no shell, so `cat` fails and the
# store read as "unreadable" on the one container whose whole job is outbound HTTPS.
[ "$(got nocat $sys)" = TRUSTS ] || fail "nocat should be read via docker cp: $(cat "$tmp/out/host1.tsv")"
pass "a shell-less image's bundle is read with docker cp, not reported unreadable"

# requests and boto3 verify against certifi's own bundle, not /etc/ssl/certs, so a clean
# system bundle says nothing about the calls an image actually makes. This is the airflow
# case: ca-certificates upgraded, certifi 2024.08.30 still carrying both roots.
[ "$(got pyonly $sys)" = OK ] || fail "pyonly system should be OK: $(cat "$tmp/out/host1.tsv")"
[ "$(got pyonly certifi)" = TRUSTS ] || fail "pyonly certifi should be TRUSTS: $(cat "$tmp/out/host1.tsv")"
pass "a stale certifi is caught behind a clean system bundle"
[ "$(got fixed certifi)" = "" ] || fail "fixed has no certifi, but a line for it was printed"
pass "an image without certifi prints no certifi line"

# --- the summary's verdict ---
sum() { bash scripts/ca-distrust-ci-summary.sh "$tmp/out" >"$tmp/sum" 2>&1; }

if sum; then fail "summary passed with TRUSTS"; fi
grep -q 'host1: 6 trusting, 1 exempt, 2 ok, 1 unreadable' "$tmp/sum" \
  || fail "summary counts: $(cat "$tmp/sum")"
pass "the summary counts per host and exits 1 on TRUSTS"

# The shipped table must exempt the mail catcher, with its reason in the output.
grep -q 'EXEMPT .*catcher (mailhog/mailhog:v1.0.1)' "$tmp/sum" || fail "catcher not exempt: $(cat "$tmp/sum")"
grep -q 'never dials out' "$tmp/sum" || fail "the exemption printed no reason: $(cat "$tmp/sum")"
pass "a listed image is EXEMPT, with its reason, and does not count as trusting"

# Only the exempt lines left: the stage can go green, and says what it let through.
awk -F'\t' '$1 == "catcher" || $1 == "fixed"' "$tmp/out/host1.tsv" >"$tmp/out/host1.tsv.new"
mv "$tmp/out/host1.tsv.new" "$tmp/out/host1.tsv"
sum || fail "summary failed with only exempt images left: $(cat "$tmp/sum")"
grep -q 'OK (1 exempt' "$tmp/sum" || fail "green summary hides the exemption: $(cat "$tmp/sum")"
pass "with only exempt images the summary is OK and still reports the count"

# An exemption is a review date, not a waiver: past `until` it fails again.
CA_DISTRUST_TODAY=2099-01-01 sum && fail "an expired exemption still passed: $(cat "$tmp/sum")"
grep -q 'EXEMPTION EXPIRED 2027' "$tmp/sum" || fail "no expiry in the detail: $(cat "$tmp/sum")"
pass "past its review date an exemption fails again, saying so"

# An image that is not listed is never exempt, whatever else is.
CA_DISTRUST_EXEMPT="" sum && fail "empty table still exempted something: $(cat "$tmp/sum")"
pass "with no table nothing is exempt"

# ERR alone does not fail.
printf 'only\tgcr.io/distroless/static\tsystem\tERR\tno CA bundle at any known path\n' >"$tmp/out/host1.tsv"
sum || fail "summary failed on ERR only: $(cat "$tmp/sum")"
pass "ERR alone does not fail the summary"

#!/usr/bin/env bash
#
# fetch-medium-dwca.sh — fetch a real, medium-sized DwCA for the Airflow harness.
#
# The committed fixture is 8 records: enough to prove a stage RAN, useless for telling
# whether it actually PROCESSED anything. A few thousand real records exercise interpret/
# uuid/index/solr for real -- partitioning, heap, and the messiness of field values that
# a hand-written fixture never has.
#
# Not committed: it is ~75KB of someone else's data with its own licence, and it would rot.
#
# Prints the path of the archive on stdout. Everything else goes to stderr so the caller
# can do: ZIP=$(scripts/fetch-medium-dwca.sh)
set -euo pipefail

# EEZA (CSIC) bird collection, ~2,072 occurrences: small enough for CI, big enough to be
# real. Override to point at any DwCA. Resolved via the GBIF registry, so it tracks the
# publisher's current archive rather than a snapshot that goes stale.
DWCA_URL="${MEDIUM_DWCA_URL:-https://ipt.gbif.es/archive.do?r=eeza-aves}"
CACHE_DIR="${MEDIUM_DWCA_CACHE:-/tmp/la-e2e-fixtures}"
OUT="${CACHE_DIR}/medium-dwca.zip"
MIN_RECORDS="${MEDIUM_DWCA_MIN_RECORDS:-500}"

say() { printf '[fetch-dwca] %s\n' "$*" >&2; }

mkdir -p "$CACHE_DIR"

# A cached archive that still validates is reused: re-downloading on every run makes the
# harness hostage to someone else's uptime, and an optional download that drops the host
# has bitten this repo before (a 429 from raw.githubusercontent took a host out of the
# play mid-deploy, and the hosts depending on its Solr failed with it).
if [[ -f "$OUT" ]] && python3 - "$OUT" "$MIN_RECORDS" <<'PY' 2>/dev/null
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1]); names = z.namelist()
assert "meta.xml" in names
txt = [n for n in names if n.endswith(".txt")]
assert txt
with z.open(txt[0]) as f:
    n = sum(1 for _ in f) - 1
assert n >= int(sys.argv[2]), n
PY
then
  say "reusing cached $OUT"
  printf '%s\n' "$OUT"
  exit 0
fi

say "downloading $DWCA_URL"
tmp="${OUT}.part"
if ! curl -sL --fail --max-time "${MEDIUM_DWCA_TIMEOUT:-180}" -o "$tmp" "$DWCA_URL"; then
  rm -f "$tmp"
  say "download FAILED (network, or the publisher moved the archive)"
  exit 1
fi

# Validate before publishing it as the fixture: a captive-portal HTML page or a truncated
# body would otherwise sail through and surface much later as an unexplained empty ingest.
if ! python3 - "$tmp" "$MIN_RECORDS" <<'PY'
import sys, zipfile
try:
    z = zipfile.ZipFile(sys.argv[1])
except zipfile.BadZipFile:
    sys.exit("not a zip (a login page or an error body?)")
names = z.namelist()
if "meta.xml" not in names:
    sys.exit(f"no meta.xml -- not a DwCA. entries: {names[:5]}")
txt = [n for n in names if n.endswith(".txt")]
if not txt:
    sys.exit("no data file in the archive")
with z.open(txt[0]) as f:
    n = sum(1 for _ in f) - 1
if n < int(sys.argv[2]):
    sys.exit(f"only {n} records, expected >= {sys.argv[2]}")
print(f"{n} records in {txt[0]}", file=sys.stderr)
PY
then
  rm -f "$tmp"
  say "archive did not validate"
  exit 1
fi

mv "$tmp" "$OUT"
say "ready: $OUT"
printf '%s\n' "$OUT"

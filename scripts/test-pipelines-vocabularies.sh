#!/usr/bin/env bash
# roles/la-compose/tasks/generate-compose.yml must provide every vocabulary the
# la-pipelines interpret stage reads (la-pipelines.yaml gbifConfig.vocabularyConfig
# .vocabulariesNames, eight since AtlasOfLivingAustralia/pipelines#19): one missing file
# fails interpretation of every dataset, which surfaced as an empty index in #488.
#   1. fetched from the GBIF API + vendored files == the eight names;
#   2. every vendored file exists and is a GBIF vocabulary export with concepts.
# LA_PIPELINES_IMAGE=<image> also compares against the names that image's default config
# lists (needs docker). ~1s otherwise, no network.
set -eu
cd "$(dirname "$0")/.."
PY="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}python3"  # needs PyYAML
command -v "$PY" >/dev/null || PY=python3
pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

expected="DegreeOfEstablishment EstablishmentMeans EventType LifeStage OccurrenceStatus Pathway Sex TypeStatus"
if [ -n "${LA_PIPELINES_IMAGE:-}" ]; then
  expected=$(docker run --rm --entrypoint cat "$LA_PIPELINES_IMAGE" \
    /usr/share/la-pipelines/config-defaults/la-pipelines.yaml \
    | "$PY" -c 'import sys, yaml; c = yaml.safe_load(sys.stdin); print(" ".join(sorted(c["gbifConfig"]["vocabularyConfig"]["vocabulariesNames"].values())))')
  pass "names read from $LA_PIPELINES_IMAGE: $expected"
fi

got=$("$PY" - roles/la-compose/tasks/generate-compose.yml <<'PY'
import sys, yaml
def walk(tasks):
    for t in tasks or []:
        yield t
        yield from walk(t.get("block"))
names = set()
api = copy = None
for t in walk(yaml.safe_load(open(sys.argv[1]))):
    n = t.get("name", "")
    if n == "Resolve the current export URL for each GBIF vocabulary":
        api = t["loop"]
    elif n == "Install the vocabularies the GBIF API publishes no release of":
        copy = t["loop"]
if api is None or copy is None:
    sys.exit("vocabulary tasks not found")
print(" ".join(sorted(api)), "|", " ".join(sorted(copy)))
PY
)
api="${got%%|*}"; copy="${got##*|}"
all=$(printf '%s\n' $api $copy | sort | tr '\n' ' ' | sed 's/ $//')
want=$(printf '%s\n' $expected | sort | tr '\n' ' ' | sed 's/ $//')
[ "$all" = "$want" ] || fail "role provides [$all], interpret reads [$want]"
pass "the role provides exactly the vocabularies interpret reads"

for v in $copy; do
  f="roles/la-compose/files/pipelines-vocabularies/$v.json"
  [ -f "$f" ] || fail "$f missing"
  "$PY" -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d["vocabulary"]["name"].lower() == sys.argv[2].lower() and d["concepts"], sys.argv[1]' "$f" "$v" \
    || fail "$f is not a $v vocabulary export"
done
pass "vendored vocabularies are GBIF exports with concepts: $copy"

#!/usr/bin/env bash
# Validate a species-groups file against the name index a deployment actually runs.
#
# groups.json maps display groups ("Fishes", "Monocots") to concrete taxon names, and those
# names are resolved against the deployment's name index. Every backbone spells its ranks
# differently, so a groups.json is only valid for the backbone it was written against.
# ALA's file is written against ALA's taxonomy: on COL `Osteichthyes` resolves to an
# unranked clade whose lft/rgt range swallows Aves and Mammalia, so every bird and mammal
# comes back tagged "Fishes". Nothing in the deployment notices, because nobody asserts on
# species_group.
#
# Checks, per group and per included/excluded taxon:
#   1. resolves        - /api/search?q=<taxon> returns a name         (warning: an inert
#                        entry is normal for the backbone it wasn't written for)
#   2. name drift      - the name returned IS the one asked for       (FATAL)
#                        catches Magnoliidae -> Magnoliales
#   3. wrong subtree   - the taxon resolves inside its parent group   (FATAL)
#                        catches Polypodiidae -> an arthropod family under "Ferns"
#   4. sibling overlap - no sibling group's range contains another's  (FATAL)
#                        catches Osteichthyes containing Aves/Mammalia
#   5. empty group     - at least one included taxon resolves         (FATAL)
#   6. name-set drift  - group names match the reference file         (FATAL)
#                        the facet exposes i18nCode species_group.<Name>, so renaming a
#                        group silently breaks every translation hanging off it
#
# Both schemas are understood: name/rank (namematching-service) and
# speciesGroup/taxonRank (biocache-store).
#
# Usage:
#   scripts/validate-species-groups.sh [--groups FILE] [--namematching URL] [--reference FILE]
#
#   --groups        file to validate. Default: the namematching-service role's groups.json,
#                   or groups-<variant>.json when SPECIES_GROUPS_VARIANT is set.
#   --namematching  base URL of the namematching service. Default: NAMEMATCHING_URL, else
#                   the `namematching` entry of the deployment's e2e-targets.json.
#   --reference     file whose group names are the contract. Default: the plain groups.json
#                   next to --groups. Pass --reference '' to skip check 6.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROLE_FILES="$REPO_ROOT/ala-install/ansible/roles/namematching-service/files"
E2E_TARGETS="${E2E_TARGETS:-/data/docker-compose/e2e-targets.json}"

GROUPS_FILE=""
REFERENCE="__default__"
NM_URL="${NAMEMATCHING_URL:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --groups)       GROUPS_FILE="$2"; shift 2 ;;
    --namematching) NM_URL="$2"; shift 2 ;;
    --reference)    REFERENCE="$2"; shift 2 ;;
    -h|--help)      sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$GROUPS_FILE" ]]; then
  variant="${SPECIES_GROUPS_VARIANT:-}"
  if [[ -n "$variant" && -f "$ROLE_FILES/groups-$variant.json" ]]; then
    GROUPS_FILE="$ROLE_FILES/groups-$variant.json"
  else
    GROUPS_FILE="$ROLE_FILES/groups.json"
  fi
fi
[[ -f "$GROUPS_FILE" ]] || { echo "groups file not found: $GROUPS_FILE" >&2; exit 2; }

if [[ "$REFERENCE" == "__default__" ]]; then
  REFERENCE="$(dirname "$GROUPS_FILE")/groups.json"
  [[ -f "$REFERENCE" ]] || REFERENCE=""
fi

# The URL is not guessable: read it from the manifest the deployment already emits for the
# e2e suite, so this script honours the inventory like every spec does.
if [[ -z "$NM_URL" && -f "$E2E_TARGETS" ]]; then
  NM_URL="$(python3 -c "
import json,sys
try:
    print(json.load(open('$E2E_TARGETS')).get('services',{}).get('namematching',''))
except Exception:
    print('')
")"
fi
if [[ -z "$NM_URL" ]]; then
  echo "No namematching URL. Pass --namematching, set NAMEMATCHING_URL, or make sure" >&2
  echo "$E2E_TARGETS carries a 'namematching' service entry." >&2
  exit 2
fi

echo "groups file : $GROUPS_FILE"
echo "reference   : ${REFERENCE:-<none, check 6 skipped>}"
echo "namematching: $NM_URL"
echo

GROUPS_FILE="$GROUPS_FILE" REFERENCE="$REFERENCE" NM_URL="$NM_URL" python3 - <<'PY'
import json, os, sys, urllib.parse, urllib.request

GROUPS_FILE    = os.environ["GROUPS_FILE"]
REFERENCE = os.environ["REFERENCE"]
NM_URL    = os.environ["NM_URL"].rstrip("/")

fatals, warnings = [], []
def fatal(msg): fatals.append(msg);   print(f"  FAIL  {msg}")
def warn(msg):  warnings.append(msg); print(f"  warn  {msg}")

def load(path):
    """Normalise both schemas: name/rank and speciesGroup/taxonRank."""
    out = []
    for g in json.load(open(path)):
        out.append({
            "name":     g.get("name") or g.get("speciesGroup"),
            "rank":     g.get("rank") or g.get("taxonRank"),
            "included": g.get("included") or [],
            "excluded": g.get("excluded") or [],
            "parent":   g.get("parent"),
        })
    return out

_cache = {}
def resolve(taxon):
    """/api/search?q=<taxon> -> {scientificName, rank, lft, rgt} or None."""
    if taxon in _cache:
        return _cache[taxon]
    url = f"{NM_URL}/api/search?q={urllib.parse.quote(taxon)}"
    # A bare urllib User-Agent is rejected with 403 by the nginx in front of the service.
    req = urllib.request.Request(url, headers={"User-Agent": "validate-species-groups/1.0"})
    result = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                d = json.load(r)
            if d.get("scientificName"):
                result = {
                    "scientificName": d["scientificName"],
                    "rank": d.get("rank"),
                    "lft": d.get("lft"),
                    "rgt": d.get("rgt"),
                }
            break
        except Exception as e:
            if attempt == 2:
                print(f"  ERROR unreachable: {url} ({e})", file=sys.stderr)
                sys.exit(3)
    _cache[taxon] = result
    return result

def contains(a, b, strict=True):
    """True when a's [lft,rgt] contains b's. Strict for sibling overlap; non-strict for the
    parent check, where a child group may be exactly one of the parent's own anchors (e.g.
    Monocots = Liliopsida, one of the two anchors of Flowering plants)."""
    if not a or not b or a["lft"] is None or b["lft"] is None:
        return False
    if strict:
        return a["lft"] < b["lft"] and b["rgt"] < a["rgt"]
    return a["lft"] <= b["lft"] and b["rgt"] <= a["rgt"]

groups = load(GROUPS_FILE)
by_name = {g["name"]: g for g in groups}

# --- check 6: the group names are the i18n contract -------------------------------------
print("[6] group names vs reference")
if REFERENCE:
    ref = [g["name"] for g in load(REFERENCE)]
    got = [g["name"] for g in groups]
    if sorted(ref) != sorted(got):
        only_ref = sorted(set(ref) - set(got))
        only_got = sorted(set(got) - set(ref))
        fatal("group names differ from the reference; every species_group.<Name> "
              f"translation keyed on them breaks. missing={only_ref} added={only_got}")
    else:
        print("  ok    same group names as the reference")
else:
    print("  skip  no reference file")
print()

# --- checks 1, 2, 3, 5: taxon by taxon ---------------------------------------------------
print("[1-3,5] taxon resolution")
anchors, excluded_anchors = {}, {}
for g in groups:
    resolved_included = []
    for kind in ("included", "excluded"):
        for taxon in g[kind]:
            r = resolve(taxon)
            if r is None:
                warn(f"{g['name']}: '{taxon}' does not resolve — inert in this index")
                continue
            if r["scientificName"].lower() != taxon.lower():
                fatal(f"{g['name']}: '{taxon}' resolves to '{r['scientificName']}' "
                      f"(rank {r['rank']}) — wrong taxon")
                continue
            if kind == "included":
                resolved_included.append(r)
    anchors[g["name"]] = resolved_included
    excluded_anchors[g["name"]] = [r for r in (resolve(t) for t in g["excluded"]) if r]
    if g["included"] and not resolved_included:
        fatal(f"{g['name']}: no included taxon resolves — the group will always be empty")

# parent subtree check, once every anchor is known
for g in groups:
    parent = g["parent"]
    if not parent or parent not in by_name:
        if parent:
            fatal(f"{g['name']}: parent '{parent}' is not a group in this file")
        continue
    for r in anchors[g["name"]]:
        pa = anchors[parent]
        if pa and not any(contains(p, r, strict=False) for p in pa):
            fatal(f"{g['name']}: '{r['scientificName']}' resolves outside its parent "
                  f"'{parent}' — wrong subtree")
print("  ...done")
print()

# --- check 4: siblings must be disjoint --------------------------------------------------
# Only groups that declare the SAME parent are compared. Groups without a parent are
# top-level and legitimately overlap their own descendants, so those pairs only warn.
print("[4] sibling ranges must not overlap")
for a in groups:
    for b in groups:
        if a["name"] == b["name"]:
            continue
        same_parent = a["parent"] == b["parent"]
        if not same_parent:
            continue
        for ra in anchors[a["name"]]:
            for rb in anchors[b["name"]]:
                if not contains(ra, rb):
                    continue
                # An overlap the file already declares is intentional: Dicots is
                # Magnoliidae minus Lilianae, so Dicots containing Monocots is by design.
                if any(contains(rx, rb, strict=False) for rx in excluded_anchors[a["name"]]):
                    continue
                if True:
                    msg = (f"{a['name']}: '{ra['scientificName']}' "
                           f"({ra['lft']}-{ra['rgt']}) contains {b['name']}: "
                           f"'{rb['scientificName']}' ({rb['lft']}-{rb['rgt']}) — "
                           f"every {b['name']} record will also be tagged {a['name']}")
                    if a["parent"] is None:
                        warn(msg)
                    else:
                        fatal(msg)
print("  ...done")
print()

print(f"{len(fatals)} failure(s), {len(warnings)} warning(s)")
sys.exit(1 if fatals else 0)
PY

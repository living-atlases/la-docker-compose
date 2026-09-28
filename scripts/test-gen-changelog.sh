#!/bin/bash
#
# test-gen-changelog.sh
#
# scripts/gen-changelog.py rebuilds CHANGELOG.md from the release tags and the commits
# between them. What this pins down, against the real repository history:
#   1. every tag gets exactly one section, newest first, with an anchor;
#   2. every commit appears exactly once (tag ranges plus "Unreleased" cover the whole
#      history with no gap and no overlap);
#   3. a lightweight tag gets no release notes (its "notes" would be a commit message);
#   4. no em or en dash reaches the published file;
#   5. the committed CHANGELOG.md matches the generator for every tagged release
#      ("Unreleased" is left out: committing the file is itself a new commit).
#
# Usage: bash scripts/test-gen-changelog.sh      Exits 0 if every assertion holds.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR" || exit 1

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
FAILURES=0
pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; FAILURES=$((FAILURES + 1)); }

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT
if ! python3 scripts/gen-changelog.py > "$OUT"; then
    fail "gen-changelog.py exited non-zero"; exit 1
fi

tags="$(git tag --sort=-v:refname)"
n_tags="$(printf '%s\n' "$tags" | grep -c .)"
n_sections="$(grep -c '^## v' "$OUT")"
if [[ "$n_sections" -eq "$n_tags" ]]; then
    pass "one section per tag ($n_tags)"
else
    fail "$n_sections sections for $n_tags tags"
fi
if [[ "$(grep '^## v' "$OUT" | awk '{print $2}')" == "$tags" ]]; then
    pass "sections are in newest-first tag order"
else
    fail "section order does not match git tag --sort=-v:refname"
fi
missing_anchor=0
for t in $tags; do grep -q "^<a name=\"$t\"></a>$" "$OUT" || missing_anchor=$((missing_anchor + 1)); done
[[ "$missing_anchor" -eq 0 ]] && pass "every tag has an anchor" || fail "$missing_anchor tag(s) without an anchor"

n_commits="$(git rev-list --count --no-merges HEAD)"
n_links="$(grep -c '/commit/[0-9a-f]\{40\})' "$OUT")"
n_unique="$(grep -o '/commit/[0-9a-f]\{40\}' "$OUT" | sort -u | grep -c .)"
if [[ "$n_links" -eq "$n_commits" && "$n_unique" -eq "$n_commits" ]]; then
    pass "all $n_commits commits listed exactly once"
else
    fail "$n_links links ($n_unique unique) for $n_commits commits"
fi

light="$(for t in $tags; do [[ "$(git cat-file -t "$t")" == commit ]] && echo "$t"; done | head -1)"
if [[ -n "$light" ]]; then
    section="$(awk -v t="$light" '$0 == "## " t " - " substr($0, length("## " t " - ") + 1) {f=1; next} /^## /{f=0} f' "$OUT")"
    first="$(printf '%s\n' "$section" | grep -v '^$' | head -1)"
    if [[ "$first" == "### Commits"* ]]; then
        pass "lightweight tag $light has no release notes"
    else
        fail "lightweight tag $light shows notes: '$first'"
    fi
fi

if grep -q $'\u2014\|\u2013' "$OUT"; then
    fail "an em/en dash reached the generated changelog"
else
    pass "no em/en dashes"
fi

released() { sed -n '/^<a name="v/,$p' "$1"; }
if diff -q <(released "$OUT") <(released CHANGELOG.md) >/dev/null 2>&1; then
    pass "CHANGELOG.md is up to date with the generator"
else
    fail "CHANGELOG.md differs from scripts/gen-changelog.py output (regenerate it)"
fi

[[ "$FAILURES" -eq 0 ]] && { echo "All checks passed."; exit 0; }
echo "$FAILURES check(s) failed."; exit 1

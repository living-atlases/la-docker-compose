#!/bin/bash
#
# test-solr-collection-gate.sh
#
# The wait-for-solr-collection gate must never be able to block a converge, and
# when it does give up it must say what the operator is left with.
#
# The gate polls Solr until the `biocache` collection holds DOCUMENTS, which
# only the first ingest produces and never a deploy on its own. On a data-less
# first install it therefore always runs to its limit, exits 0, and lets
# biocache-service boot into the empty-field-list state the gate exists to
# prevent (gh-8). That path has to be loud: the pause is six minutes and the
# symptom afterwards is /index/fields answering [] with HTTP 200, which reads as
# healthy.
#
# Counting documents rather than collections is the fix for build #356: the
# collection existed and was empty when the converge restarted biocache-service,
# so a collection-exists gate would have passed and changed nothing. luke reports
# only fields present in the index segments, so an empty collection caches an
# empty field list exactly like a missing one — and logs no error at all.
#
# Cheap on purpose: pure text plus one run of the extracted shell loop against a
# stub. No Docker, no Solr, no ansible.
#
# Usage: bash scripts/test-solr-collection-gate.sh
#
# Exits 0 if the gate is bounded, exits 0 itself, and diagnoses; 1 otherwise.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Overridable so the checks can be mutation-tested against a deliberately broken copy
# without touching the shipped template.
GATE="${GATE:-$REPO_DIR/roles/la-compose/templates/docker-compose/infrastructure/wait-for-solr-collection.yml.j2}"

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }

if [[ ! -f "$GATE" ]]; then
    fail "not found: $GATE"
    exit 1
fi

failures=0

# 1. The loop is bounded. `while true` on its own is fine; what matters is that
#    some iteration cap exists, otherwise a data-less install hangs forever.
if grep -qE '^\s*LIMIT=[0-9]+' "$GATE" && grep -qE '^\s*EMPTY_LIMIT=[0-9]+' "$GATE"; then
    limit=$(grep -oE '^\s*LIMIT=[0-9]+' "$GATE" | head -1 | grep -oE '[0-9]+')
    empty_limit=$(grep -oE '^\s*EMPTY_LIMIT=[0-9]+' "$GATE" | head -1 | grep -oE '[0-9]+')
    pass "retry limits present (${limit} tries unqueryable, ${empty_limit} empty)"
    # The empty-collection path is walked by every install that has no data, so it has
    # to be the cheap one.
    if [[ "$empty_limit" -lt "$limit" ]]; then
        pass "the empty-collection path is cheaper than the unqueryable one"
    else
        fail "EMPTY_LIMIT (${empty_limit}) is not below LIMIT (${limit}): data-less installs pay full price"
        failures=$((failures + 1))
    fi
else
    fail "no retry limit: a data-less install would poll forever"
    failures=$((failures + 1))
fi

# 2. Both exits are 0. A non-zero exit turns depends_on into a hard stop and
#    takes the whole converge down over missing data.
if [[ $(grep -cE '^\s*exit 1\b' "$GATE") -eq 0 ]]; then
    pass "never exits non-zero, so it cannot deadlock a converge"
else
    fail "exits non-zero somewhere: that would block the converge"
    failures=$((failures + 1))
fi

# 3. The give-up path explains the state it leaves behind. Checked by running
#    the real loop with a curl that never matches, so this tests the shipped
#    text and not a copy of it.
info "running the gate's own loop against a never-matching stub"

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# Extract the shell body of `command:` (the `- |` block), undo the compose-level
# `$$` escaping, and shrink the retry caps so the test takes a second, not six minutes.
# Rewrite the cap ASSIGNMENTS, not the comparisons: a blanket `s/-ge N/-ge 3/` also
# rewrites the document-count comparison, which quietly repairs a mutant and makes the
# empty-collection check untestable (found by mutation-testing it).
sed -n '/^    command:/,/^    restart:/p' "$GATE" \
    | sed -e '1d' -e '$d' -e 's/^      - |$//' -e 's/^        //' \
    | sed -e 's/\$\$/$/g' -e 's/^LIMIT=[0-9]\+/LIMIT=3/' -e 's/^EMPTY_LIMIT=[0-9]\+/EMPTY_LIMIT=2/' \
    > "$workdir/gate.sh"

if [[ ! -s "$workdir/gate.sh" ]]; then
    fail "could not extract the command block - this test is broken, not the gate"
    exit 1
fi

# run_gate <stub-body> -> sets $output/$status by running the real extracted loop
run_gate() {
    printf '#!/bin/sh\n%s\n' "$1" > "$workdir/curl"
    chmod +x "$workdir/curl"
    set +e
    output=$(cd "$workdir" && PATH="$workdir:$PATH" \
        SOLR_BASE="http://solr:8983" SOLR_COLLECTION="biocache" \
        sh ./gate.sh 2>&1)
    status=$?
    set -e
}

# 3a. Collection absent: Solr answers an error with no numFound at all.
run_gate "echo '{\"responseHeader\":{\"status\":404},\"error\":{\"msg\":\"Collection not found: biocache\"}}'"
giveup_output="$output"

if [[ $status -eq 0 ]]; then
    pass "gate exits 0 after exhausting its retries (collection absent)"
else
    fail "gate exited $status after exhausting its retries (expected 0)"
    failures=$((failures + 1))
fi

# The operator has to learn three things: there are no documents, an ingest is
# what produces them, and biocache-service is starting into a degraded state.
for phrase in "does not exist" "ingest" "index/fields" "documents"; do
    if grep -qi -- "$phrase" <<<"$output"; then
        pass "give-up message mentions '$phrase'"
    else
        fail "give-up message never mentions '$phrase'"
        failures=$((failures + 1))
    fi
done

# 3b. The #356 regression: the collection EXISTS and is EMPTY. A gate that only
#     checks for the collection passes here and lets biocache-service cache an
#     empty field list with no error logged anywhere. It must give up instead.
info "running the gate against a collection that exists but holds no documents"
run_gate "echo '{\"responseHeader\":{\"status\":0},\"response\":{\"numFound\":0,\"start\":0,\"docs\":[]}}'"

if [[ $status -eq 0 ]] && grep -qi "no documents" <<<"$output"; then
    pass "an empty collection is not mistaken for a ready one"
else
    fail "gate accepted an EMPTY collection (status=$status) — this is the #356 regression"
    failures=$((failures + 1))
fi

# ...but it must bail FAST there. A deploy never creates documents, and init-solr
# already creates the collection, so an install with no data hits this path on every
# single deploy. Making it wait out the full retry budget would tax every data-less
# portal six minutes to be told something known after the first probe.
empty_tries=$(grep -c "exists but is empty, retry" <<<"$output" || true)
if [[ "$empty_tries" -gt 0 && "$empty_tries" -lt 20 ]]; then
    pass "empty collection gives up fast (${empty_tries} retries, not the full budget)"
else
    fail "empty collection retried ${empty_tries} times — a data-less install must not pay the full budget"
    failures=$((failures + 1))
fi

# 3c. Documents present: the gate must let the boot through, promptly.
info "running the gate against a collection that holds documents"
run_gate "echo '{\"responseHeader\":{\"status\":0},\"response\":{\"numFound\":8,\"start\":0,\"docs\":[]}}'"

if [[ $status -eq 0 ]] && grep -q "has 8 document" <<<"$output"; then
    pass "gate proceeds as soon as the index holds documents"
else
    fail "gate did not proceed on a populated index (status=$status)"
    failures=$((failures + 1))
fi

if [[ $failures -gt 0 ]]; then
    echo
    fail "$failures check(s) failed"
    echo "--- gate output on the give-up path ---"
    echo "$giveup_output"
    exit 1
fi

echo
pass "wait-for-solr-collection is bounded, non-blocking and self-explaining"

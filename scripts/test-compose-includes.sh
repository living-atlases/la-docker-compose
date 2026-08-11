#!/bin/bash
#
# test-compose-includes.sh
#
# Every `- ./<path>` in base.yml.j2 must be written by a task in generate-compose.yml.
#
# Docker Compose resolves `include:` at parse time, so an include pointing at a file
# nobody generates does not degrade — it takes out every compose command on that host.
# 72bc200 added infrastructure/wait-for-solr-collection.yml.j2 and the include, but not
# the `template:` task, and build #348 died like this:
#
#     TASK [la-compose : Pull Docker images]
#     fatal: [gbif-es-docker-cluster-2023-1.docker_compose]: FAILED!
#       stderr: 'open /data/docker-compose/infrastructure/wait-for-solr-collection.yml:
#                no such file or directory'
#
# The host dropped out of the play, so CAS/collectory/branding never came up, and the
# hubs on the other two hosts then burned the whole converge budget waiting for
# services that host was never going to start. Cost: ~2h of cluster time to surface a
# missing six-line task, on a mistake that is a grep away.
#
# Cheap on purpose: pure text, no Docker, no ansible, no inventory. Runs in the unit
# stage so a missing task fails in seconds instead of two hours into a deploy.
#
# Usage: bash scripts/test-compose-includes.sh
#
# Exits 0 if every include has a generating task, 1 otherwise.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="$REPO_DIR/roles/la-compose/templates/docker-compose/base.yml.j2"
GEN="$REPO_DIR/roles/la-compose/tasks/generate-compose.yml"

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }

for f in "$BASE" "$GEN"; do
    if [[ ! -f "$f" ]]; then
        fail "not found: $f"
        exit 1
    fi
done

# `  - ./services/foo.yml` -> `services/foo.yml`. Jinja conditionals around the include
# are irrelevant here: a file included on ANY host has to be generated on that host, and
# every generating task is unconditional for exactly that reason.
mapfile -t includes < <(grep -oE '^[[:space:]]+- \./\S+' "$BASE" | sed 's|^[[:space:]]*- \./||' | sort -u)

if [[ ${#includes[@]} -eq 0 ]]; then
    fail "parsed 0 includes out of $BASE — the test itself is broken, not the templates"
    exit 1
fi

missing=()
for inc in "${includes[@]}"; do
    # Matches the task's `dest: "{{ docker_compose_data_dir }}/<inc>"`.
    grep -qF "/$inc\"" "$GEN" || missing+=("$inc")
done

info "checked ${#includes[@]} include(s) in base.yml.j2 against generate-compose.yml"

if [[ ${#missing[@]} -eq 0 ]]; then
    pass "every compose include has a task that generates it"
    exit 0
fi

for inc in "${missing[@]}"; do
    fail "base.yml.j2 includes ./$inc but no task in generate-compose.yml writes it"
done
echo
fail "${#missing[@]} include(s) without a generating task — every compose command on the"
fail "affected host will fail with 'no such file or directory' at parse time."
exit 1

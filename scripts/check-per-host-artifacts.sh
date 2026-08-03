#!/bin/bash
# Offline guard: no task that installs a PER-HOST artifact may be run_once.
#
# Background. `run_once: true` executes a task on the first host of the play and reuses its
# *result* everywhere — which is right for "generate one shared file / call one API once" and
# catastrophic for "put a 2 GB Lucene index on this host's disk". gbif-es ran three docker
# hosts with namematching-service enabled on all three; the index landed on the first host
# only and the other two crash-looped for days on
#     java.io.FileNotFoundException: /data/lucene/namematching-nm/cb
#
# CI cannot catch that class of bug by deploying: every topology fixture in this repo places a
# service on exactly ONE host (topologies/*.placement.json maps service -> single slot), so
# run_once and "per host" are indistinguishable there while production runs namematching on
# three. Until the fixtures can express a service on several hosts, this static check is the
# regression test — it costs milliseconds and runs on every build.
#
# Usage: scripts/check-per-host-artifacts.sh [ala-install-root]
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)/ala-install}"

# Task files that install something onto the local disk of every host that uses it.
FILES=(
  "ansible/roles/namematching-service/tasks/download-nameindex.yml"
  "ansible/roles/namematching-service/tasks/docker-tasks.yml"
)

errors=0
for rel in "${FILES[@]}"; do
  f="$ROOT/$rel"
  if [[ ! -f "$f" ]]; then
    echo "FAIL: $rel not found under $ROOT (moved or renamed? update this guard)" >&2
    errors=$((errors + 1))
    continue
  fi
  if grep -nE '^\s*run_once\s*:\s*(true|yes)\b' "$f"; then
    echo "FAIL: $rel installs a per-host artifact and must not use run_once (lines above)." >&2
    errors=$((errors + 1))
  else
    echo "  ok  $rel has no run_once"
  fi
done

if [[ "$errors" -gt 0 ]]; then
  echo "$errors per-host-artifact violation(s)." >&2
  exit 1
fi
echo "Per-host artifact guard passed."

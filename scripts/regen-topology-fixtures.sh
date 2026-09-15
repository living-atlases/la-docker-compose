#!/usr/bin/env bash
# Regenerate the committed topology fixture inventories under
# inventories/testing/topologies/<variant>/ from the sanitized base .yo-rc
# (topologies/base.lademo.yo-rc.json) plus each placement overlay
# (topologies/<variant>.placement.json).
#
# Run whenever the base or a placement changes, then COMMIT the regenerated
# fixtures — CI's "Topology matrix" stage validates the committed inventories
# without needing node/yo.
#
# Requires yo + generator-living-atlas on PATH:
#   npm install -g yo generator-living-atlas
#
# Usage: scripts/regen-topology-fixtures.sh [variant ...]
#   (no args = every topologies/*.placement.json)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${REPO_ROOT}/topologies/base.lademo.yo-rc.json"
OUT_BASE="${REPO_ROOT}/inventories/testing/topologies"

command -v yo >/dev/null || { echo "ERROR: yo not found (npm install -g yo generator-living-atlas)" >&2; exit 1; }

if [ "$#" -gt 0 ]; then
  VARIANTS=("$@")
else
  VARIANTS=()
  for p in "${REPO_ROOT}"/topologies/*.placement.json; do
    VARIANTS+=("$(basename "$p" .placement.json)")
  done
fi

for variant in "${VARIANTS[@]}"; do
  placement="${REPO_ROOT}/topologies/${variant}.placement.json"
  [ -f "$placement" ] || { echo "ERROR: no such placement: $placement" >&2; exit 1; }
  dir="${OUT_BASE}/${variant}"
  echo "=== ${variant} ==="
  mkdir -p "$dir"
  python3 "${REPO_ROOT}/scripts/apply-topology.py" apply \
    --base "$BASE" --placement "$placement" --out "${dir}/.yo-rc.json"
  (cd "$dir" && yo living-atlas --replay-dont-ask --force >/dev/null)
  test -f "${dir}/lademo-inventories/lademo-inventory.ini" \
    || { echo "ERROR: ${variant}: inventory not generated" >&2; exit 1; }
  # Fixtures only need the inventories (+ the .yo-rc they came from). Drop the
  # branding clones and other deploy-time artifacts the generator provisions.
  #
  # Data hub inventories are kept: the PORTAL inventory declares the [hub-<pkg>]
  # groups EMPTY on purpose, so a hub's placement lives only in its own
  # <pkg>-inventories/<pkg>-inventory.ini. Without them no fixture would ever
  # exercise a hub, and a hub may be SPREAD across hosts. This mirrors what the
  # hub's own ansiblew does: -i ../<portal>-inventory.ini -i ./<hub>-inventory.ini.
  find "$dir" -mindepth 1 -maxdepth 1 \
    ! -name '.yo-rc.json' ! -name '*-inventories' -exec rm -rf {} +
  for invdir in "${dir}"/*-inventories; do
    pkg="$(basename "$invdir" -inventories)"
    find "$invdir" -mindepth 1 -maxdepth 1 \
      ! -name "${pkg}-inventory.ini" -exec rm -rf {} +
    rmdir "$invdir" 2>/dev/null || true
  done
  echo "    -> ${dir}/lademo-inventories/lademo-inventory.ini"
done
echo "Done. Review the diff and commit the regenerated fixtures."

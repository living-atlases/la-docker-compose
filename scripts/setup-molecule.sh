#!/usr/bin/env bash
# Create a Python venv with molecule and ansible for running unit tests locally.
# Run once after cloning or when molecule is not available.
#
# Usage: scripts/setup-molecule.sh [venv-dir]
#   venv-dir defaults to .venv-molecule in the project root.
set -euo pipefail

VENV_DIR="${1:-.venv-molecule}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$PROJECT_ROOT"

echo "Creating molecule venv at: $VENV_DIR"
python3 -m venv "$VENV_DIR"

echo "Installing molecule + ansible..."
"$VENV_DIR/bin/pip" install --quiet --upgrade pip
"$VENV_DIR/bin/pip" install --quiet \
  molecule \
  ansible-core \
  "molecule-plugins[docker]"

echo ""
echo "Done. To run unit tests:"
echo "  source $VENV_DIR/bin/activate"
echo "  molecule test -s unit"
echo ""
echo "Or without activating:"
echo "  $VENV_DIR/bin/molecule test -s unit"

#!/usr/bin/env bash
# Configure git to use the versioned .githooks directory and set up tooling.
# Run once after cloning: .githooks/setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

echo "Configuring git to use .githooks..."
git config core.hooksPath .githooks
chmod +x .githooks/pre-push

echo "Setting up molecule venv..."
if [[ -x "scripts/setup-molecule.sh" ]]; then
  scripts/setup-molecule.sh
else
  echo "WARNING: scripts/setup-molecule.sh not found - molecule unit tests won't run in pre-push hook" >&2
fi

echo ""
echo "Done. Git hooks are now active."
echo "  pre-push → scripts/validate-config-gen.sh"

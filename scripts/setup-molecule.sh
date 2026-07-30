#!/usr/bin/env bash
# Create a Python venv with molecule, ansible and the linters for local use.
# Run once after cloning, or when molecule/ansible-lint are not available.
#
# The venv is also where scripts/validate-local.sh looks for ansible-lint first.
# Distro-packaged ansible-lint bundles its own ansible-core, which does not have
# to match the system `ansible` CLI; when they diverge it refuses to run at all
# ("Ansible CLI (X) and python module (Y) versions do not match"). Installing
# both from the same venv keeps them coherent by construction.
#
# Usage: scripts/setup-molecule.sh [venv-dir]
#   venv-dir defaults to .venv-molecule in the project root.
set -euo pipefail

VENV_DIR="${1:-.venv-molecule}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$PROJECT_ROOT"

echo "Creating molecule venv at: $VENV_DIR"
python3 -m venv "$VENV_DIR"

echo "Installing molecule + ansible + linters..."
"$VENV_DIR/bin/pip" install --quiet --upgrade pip
"$VENV_DIR/bin/pip" install --quiet \
  molecule \
  ansible-core \
  "molecule-plugins[docker]" \
  ansible-lint \
  yamllint

# Prove the pair is coherent before anyone relies on it: ansible-lint prints the
# ansible-core it links against, which must be the venv's own `ansible`.
lint_core="$("$VENV_DIR/bin/ansible-lint" --version 2>/dev/null | sed -n 's/.*ansible-core:\([0-9.]*\).*/\1/p')"
ansible_core="$("$VENV_DIR/bin/ansible" --version 2>/dev/null | sed -n '1s/.*core \([0-9.]*\).*/\1/p')"

if [[ -z "$lint_core" || -z "$ansible_core" ]]; then
  echo "ERROR: could not determine ansible-lint / ansible-core versions in $VENV_DIR" >&2
  exit 1
fi

if [[ "$lint_core" != "$ansible_core" ]]; then
  echo "ERROR: version mismatch inside the venv:" >&2
  echo "  ansible-lint links ansible-core $lint_core" >&2
  echo "  ansible CLI is ansible-core $ansible_core" >&2
  echo "Delete $VENV_DIR and re-run this script." >&2
  exit 1
fi

echo "  ansible-lint OK (ansible-core $ansible_core)"

echo ""
echo "Done. To run unit tests:"
echo "  source $VENV_DIR/bin/activate"
echo "  molecule test -s unit"
echo ""
echo "Or without activating:"
echo "  $VENV_DIR/bin/molecule test -s unit"
echo ""
echo "The linters are picked up automatically by:"
echo "  scripts/validate-local.sh quick"

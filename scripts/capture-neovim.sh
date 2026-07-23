#!/usr/bin/env bash
# Refresh dotfiles/nvim from this machine after making intentional config edits.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE="${XDG_CONFIG_HOME:-${HOME}/.config}/nvim"
DESTINATION="${REPO_DIR}/dotfiles/nvim"

[ -d "$SOURCE" ] || {
  printf 'Neovim config not found: %s\n' "$SOURCE" >&2
  exit 1
}

mkdir -p "$DESTINATION"
rsync -a --delete --exclude='.box-bootstrap-managed' "${SOURCE}/" "${DESTINATION}/"
printf 'Captured %s into %s\n' "$SOURCE" "$DESTINATION"
printf 'Review the result with: git -C %q diff -- dotfiles/nvim\n' "$REPO_DIR"

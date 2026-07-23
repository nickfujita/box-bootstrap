#!/usr/bin/env bash
#
# Install the complete, reproducible Neovim/LazyVim environment captured in
# this repository. This script is intentionally standalone so the editor can be
# installed without running the core box-bootstrap components.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
NVIM_CONFIG_SOURCE="${REPO_DIR}/dotfiles/nvim"
NVIM_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/nvim"
NVIM_DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/nvim"
NVIM_MARKER="${NVIM_CONFIG_DIR}/.box-bootstrap-managed"

# Pin the tested toolchain. Override any value explicitly when testing an
# upgrade, then update these defaults and lazy-lock.json once it is known-good.
NEOVIM_VERSION="${NEOVIM_VERSION:-0.12.4}"
NODE_VERSION="${NODE_VERSION:-24.13.1}"
NODE_MIN_MAJOR="${NODE_MIN_MAJOR:-22}"
LAZYGIT_VERSION="${LAZYGIT_VERSION:-0.63.1}"
TREE_SITTER_CLI_VERSION="${TREE_SITTER_CLI_VERSION:-0.26.11}"
GO_VERSION="${GO_VERSION:-1.26.0}"
SWIFT_VERSION="${SWIFT_VERSION:-6.3.3}"

MASON_PACKAGES=(
  bash-language-server
  biome
  copilot-language-server
  css-lsp
  docker-compose-language-service
  dockerfile-language-server
  gofumpt
  goimports
  golangci-lint
  gopls
  hadolint
  html-lsp
  json-lsp
  kotlin-language-server
  ktlint
  lua-language-server
  markdown-toc
  markdownlint-cli2
  marksman
  pyright
  ruff
  shellcheck
  shfmt
  stylua
  tailwindcss-language-server
  taplo
  vtsls
  yaml-language-server
)

TREE_SITTER_PARSERS=(
  bash c css diff dockerfile go gomod gosum gowork html javascript json json5
  kotlin lua luadoc markdown markdown_inline python query regex sql swift toml
  tsx typescript vim vimdoc yaml
)

log()  { printf '\033[1;34m[nvim-bootstrap]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  [ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  [--]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then
  SUDO=()
elif command -v sudo >/dev/null 2>&1; then
  SUDO=(sudo)
else
  die "sudo is required when not running as root"
fi

export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"

append_once() {
  local file="$1" line="$2"
  touch "$file"
  if ! grep -qF -- "$line" "$file" 2>/dev/null; then
    # Some installers leave profile files without a trailing newline. Do not
    # concatenate our setting onto their final command.
    if [ -s "$file" ] && [ -n "$(tail -c 1 "$file")" ]; then
      printf '\n' >> "$file"
    fi
    printf '%s\n' "$line" >> "$file"
  fi
}

nvim_alias_present() {
  grep -qxF "alias n='nvim'" "${HOME}/.bash_aliases" 2>/dev/null \
    || grep -qxF "alias n='nvim'" "${HOME}/.bashrc" 2>/dev/null
}

version_ge() {
  dpkg --compare-versions "$1" ge "$2"
}

command_version() {
  local command_name="$1"
  case "$command_name" in
    git) git --version | awk '{print $3}' ;;
    fzf) fzf --version | awk '{print $1}' ;;
    lazygit) lazygit --version | sed -n 's/.*version=\([^,]*\), os=.*/\1/p' ;;
    tree-sitter) tree-sitter --version | awk '{print $2}' ;;
    *) return 1 ;;
  esac
}

source_swiftly() {
  local env_file="${SWIFTLY_HOME_DIR:-${HOME}/.local/share/swiftly}/env.sh"
  if [ -s "$env_file" ]; then
    # shellcheck disable=SC1090
    . "$env_file"
    hash -r
  fi
}

check_neovim_stack() {
  local status=0 version package

  if command -v nvim >/dev/null 2>&1; then
    version="$(nvim --version | sed -n '1s/^NVIM v//p')"
    if version_ge "$version" "0.11.2" && nvim --version | grep -q 'LuaJIT'; then
      ok "Neovim ${version} with LuaJIT"
    else
      warn "Neovim must be >= 0.11.2 and built with LuaJIT"; status=1
    fi
  else
    warn "Neovim missing"; status=1
  fi

  if command -v git >/dev/null 2>&1 && version_ge "$(command_version git)" "2.19.0"; then
    ok "Git $(command_version git)"
  else
    warn "Git >= 2.19.0 missing"; status=1
  fi

  if command -v fzf >/dev/null 2>&1 && version_ge "$(command_version fzf)" "0.25.1"; then
    ok "fzf $(command_version fzf)"
  else
    warn "fzf >= 0.25.1 missing"; status=1
  fi

  for package in curl cc rg fd lazygit tree-sitter node npm python3 java go swift sourcekit-lsp; do
    if command -v "$package" >/dev/null 2>&1; then
      ok "${package} present"
    else
      warn "${package} missing"; status=1
    fi
  done

  if nvim_alias_present; then
    ok "n=nvim Bash alias configured"
  else
    warn "n=nvim Bash alias missing"; status=1
  fi

  if [ -d "$NVIM_CONFIG_DIR" ] \
    && diff -qr --exclude='.box-bootstrap-managed' "$NVIM_CONFIG_SOURCE" "$NVIM_CONFIG_DIR" >/dev/null 2>&1; then
    ok "Neovim configuration matches the repository"
  else
    warn "Neovim configuration is absent or differs from dotfiles/nvim"; status=1
  fi

  if [ -d "${NVIM_DATA_DIR}/lazy/LazyVim" ]; then
    ok "LazyVim plugins installed"
  else
    warn "LazyVim plugins not installed"; status=1
  fi

  local missing_mason=0 missing_parsers=0
  for package in "${MASON_PACKAGES[@]}"; do
    if [ ! -d "${NVIM_DATA_DIR}/mason/packages/${package}" ]; then
      warn "Mason package missing: ${package}"; status=1; missing_mason=1
    fi
  done
  [ "$missing_mason" -ne 0 ] || ok "all ${#MASON_PACKAGES[@]} Mason tools installed"

  for package in "${TREE_SITTER_PARSERS[@]}"; do
    if [ ! -f "${NVIM_DATA_DIR}/site/parser/${package}.so" ]; then
      warn "Tree-sitter parser missing: ${package}"; status=1; missing_parsers=1
    fi
  done
  [ "$missing_parsers" -ne 0 ] || ok "all ${#TREE_SITTER_PARSERS[@]} Tree-sitter parsers installed"

  return "$status"
}

check_disk_space() {
  local needed_mb=1024 available_mb mason_count=0
  source_swiftly

  # Approximate first-install peak, including downloads/build caches. Existing
  # pieces do not need to be budgeted again on an idempotent rerun.
  if ! command -v swift >/dev/null 2>&1 || ! command -v sourcekit-lsp >/dev/null 2>&1; then
    needed_mb=$((needed_mb + 5000))
  fi
  if [ ! -d "${NVIM_DATA_DIR}/lazy/LazyVim" ]; then
    needed_mb=$((needed_mb + 750))
  fi
  if [ -d "${NVIM_DATA_DIR}/mason/packages" ]; then
    mason_count="$(find "${NVIM_DATA_DIR}/mason/packages" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  fi
  if [ "$mason_count" -lt "${#MASON_PACKAGES[@]}" ]; then
    needed_mb=$((needed_mb + 3000))
  fi
  if ! command -v go >/dev/null 2>&1; then needed_mb=$((needed_mb + 500)); fi
  if ! command -v node >/dev/null 2>&1; then needed_mb=$((needed_mb + 500)); fi

  available_mb="$(df -Pm "$HOME" | awk 'NR == 2 { print $4 }')"
  if [ "$available_mb" -lt "$needed_mb" ]; then
    die "about ${needed_mb} MB free is needed for this install; only ${available_mb} MB is available"
  fi
  ok "disk-space preflight passed (${available_mb} MB free; about ${needed_mb} MB needed)"
}

ensure_apt_packages() {
  local packages=(
    binutils
    build-essential
    ca-certificates
    clang
    curl
    fd-find
    fzf
    git
    gnupg2
    jq
    libcurl4-openssl-dev
    libedit2
    libsqlite3-0
    libxml2
    openjdk-21-jdk-headless
    pkg-config
    python3
    python3-pip
    python3-venv
    ripgrep
    rsync
    tzdata
    unzip
    xz-utils
    zlib1g-dev
  )
  local missing=() package
  for package in "${packages[@]}"; do
    dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' \
      || missing+=("$package")
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    ok "Ubuntu prerequisites already installed"
    return
  fi
  log "Installing Ubuntu prerequisites: ${missing[*]}"
  "${SUDO[@]}" apt-get update
  "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
}

install_neovim_binary() {
  local current="" arch asset checksum extracted target tmp
  if command -v nvim >/dev/null 2>&1; then
    current="$(nvim --version | sed -n '1s/^NVIM v//p')"
  fi
  if [ "$current" = "$NEOVIM_VERSION" ] && nvim --version | grep -q 'LuaJIT'; then
    ok "Neovim ${NEOVIM_VERSION} with LuaJIT already installed"
    return
  fi

  case "$(uname -m)" in
    x86_64) arch=x86_64 ;;
    aarch64) arch=arm64 ;;
    *) die "unsupported architecture $(uname -m) for Neovim" ;;
  esac
  asset="nvim-linux-${arch}.tar.gz"
  extracted="nvim-linux-${arch}"
  target="/opt/nvim-v${NEOVIM_VERSION}"
  tmp="$(mktemp -d)"

  log "Installing Neovim ${NEOVIM_VERSION} (${arch}, official prebuilt LuaJIT release)"
  curl -fsSL \
    "https://github.com/neovim/neovim/releases/download/v${NEOVIM_VERSION}/${asset}" \
    -o "${tmp}/${asset}"
  # Neovim release assets expose their SHA-256 digest through the GitHub API;
  # there is no separate <asset>.sha256sum download.
  checksum="$(
    curl -fsSL \
      -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/neovim/neovim/releases/tags/v${NEOVIM_VERSION}" \
      | jq -r --arg asset "$asset" \
        '.assets[] | select(.name == $asset) | .digest // empty' \
      | sed 's/^sha256://' \
      | head -n 1
  )"
  [ -n "$checksum" ] || die "could not find the official checksum for Neovim asset ${asset}"
  printf '%s  %s\n' "$checksum" "$asset" > "${tmp}/SHA256SUM"
  (cd "$tmp" && sha256sum -c SHA256SUM)
  tar -xzf "${tmp}/${asset}" -C "$tmp"
  "${SUDO[@]}" rm -rf "$target"
  "${SUDO[@]}" mv "${tmp}/${extracted}" "$target"
  "${SUDO[@]}" ln -sfn "${target}/bin/nvim" /usr/local/bin/nvim
  rm -rf "$tmp"
  hash -r
  ok "installed Neovim ${NEOVIM_VERSION} at ${target}"
}

install_node() {
  local current_major=0 arch asset extracted target tmp
  if command -v node >/dev/null 2>&1; then
    current_major="$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)"
  fi
  if [ "$current_major" -ge "$NODE_MIN_MAJOR" ] && command -v npm >/dev/null 2>&1; then
    ok "Node $(node --version) and npm already satisfy the editor toolchain"
    return
  fi

  case "$(uname -m)" in
    x86_64) arch=x64 ;;
    aarch64) arch=arm64 ;;
    *) die "unsupported architecture $(uname -m) for Node.js" ;;
  esac
  asset="node-v${NODE_VERSION}-linux-${arch}.tar.xz"
  extracted="${asset%.tar.xz}"
  target="/opt/${extracted}"
  tmp="$(mktemp -d)"

  log "Installing Node.js ${NODE_VERSION} for JS/TS tools and Mason packages"
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/${asset}" -o "${tmp}/${asset}"
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" -o "${tmp}/SHASUMS256.txt"
  grep " ${asset}\$" "${tmp}/SHASUMS256.txt" > "${tmp}/SHASUMS256.selected"
  (cd "$tmp" && sha256sum -c SHASUMS256.selected)
  tar -xJf "${tmp}/${asset}" -C "$tmp"
  "${SUDO[@]}" rm -rf "$target"
  "${SUDO[@]}" mv "${tmp}/${extracted}" "$target"
  for binary in node npm npx corepack; do
    "${SUDO[@]}" ln -sfn "${target}/bin/${binary}" "/usr/local/bin/${binary}"
  done
  rm -rf "$tmp"
  hash -r
  ok "installed Node.js v${NODE_VERSION}"
}

install_go_toolchain() {
  local current="" arch asset checksum tmp
  if command -v go >/dev/null 2>&1; then
    current="$(go env GOVERSION 2>/dev/null | sed 's/^go//')"
  fi
  if [ -n "$current" ] && version_ge "$current" "$GO_VERSION"; then
    ok "Go ${current} already satisfies the captured toolchain"
    return
  fi

  case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64) arch=arm64 ;;
    *) die "unsupported architecture $(uname -m) for Go" ;;
  esac
  asset="go${GO_VERSION}.linux-${arch}.tar.gz"
  tmp="$(mktemp -d)"
  log "Installing Go ${GO_VERSION}"
  curl -fsSL "https://go.dev/dl/${asset}" -o "${tmp}/${asset}"
  checksum="$(
    curl -fsSL 'https://go.dev/dl/?mode=json&include=all' \
      | jq -r --arg asset "$asset" \
        '.[] | .files[] | select(.filename == $asset) | .sha256' \
      | head -n 1
  )"
  [ -n "$checksum" ] || die "could not find the official checksum for ${asset}"
  printf '%s  %s\n' "$checksum" "$asset" > "${tmp}/SHA256SUM"
  (cd "$tmp" && sha256sum -c SHA256SUM)
  "${SUDO[@]}" rm -rf /usr/local/go
  "${SUDO[@]}" tar -C /usr/local -xzf "${tmp}/${asset}"
  rm -rf "$tmp"
  # Intentionally preserve the variables for expansion by future shells.
  # shellcheck disable=SC2016
  append_once "${HOME}/.profile" 'export PATH="$PATH:/usr/local/go/bin"'
  export PATH="${PATH}:/usr/local/go/bin"
  hash -r
  ok "installed Go ${GO_VERSION}"
}

install_lazygit() {
  local current="" arch asset tmp
  if command -v lazygit >/dev/null 2>&1; then current="$(command_version lazygit)"; fi
  if [ "$current" = "$LAZYGIT_VERSION" ]; then
    ok "lazygit ${LAZYGIT_VERSION} already installed"
    return
  fi
  case "$(uname -m)" in
    x86_64) arch=x86_64 ;;
    aarch64) arch=arm64 ;;
    *) die "unsupported architecture $(uname -m) for lazygit" ;;
  esac
  asset="lazygit_${LAZYGIT_VERSION}_Linux_${arch}.tar.gz"
  tmp="$(mktemp -d)"
  log "Installing lazygit ${LAZYGIT_VERSION}"
  curl -fsSL \
    "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/${asset}" \
    -o "${tmp}/${asset}"
  curl -fsSL \
    "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/checksums.txt" \
    -o "${tmp}/checksums.txt"
  grep " ${asset}\$" "${tmp}/checksums.txt" > "${tmp}/checksums.selected"
  (cd "$tmp" && sha256sum -c checksums.selected)
  tar -xzf "${tmp}/${asset}" -C "$tmp" lazygit
  "${SUDO[@]}" install -m 0755 "${tmp}/lazygit" /usr/local/bin/lazygit
  rm -rf "$tmp"
  ok "installed lazygit ${LAZYGIT_VERSION}"
}

install_tree_sitter_cli() {
  local current=""
  if command -v tree-sitter >/dev/null 2>&1; then current="$(command_version tree-sitter)"; fi
  if [ "$current" = "$TREE_SITTER_CLI_VERSION" ]; then
    ok "tree-sitter CLI ${TREE_SITTER_CLI_VERSION} already installed"
    return
  fi
  log "Installing tree-sitter CLI ${TREE_SITTER_CLI_VERSION}"
  npm install --global --prefix "${HOME}/.local" "tree-sitter-cli@${TREE_SITTER_CLI_VERSION}"
  hash -r
  ok "installed tree-sitter CLI ${TREE_SITTER_CLI_VERSION}"
}

install_swift_toolchain() {
  local current="" tmp
  source_swiftly
  if command -v swift >/dev/null 2>&1; then
    current="$(swift --version | sed -n '1s/^Swift version \([^ ]*\).*/\1/p')"
  fi
  if [ -n "$current" ] && version_ge "$current" "$SWIFT_VERSION" \
    && command -v sourcekit-lsp >/dev/null 2>&1; then
    ok "Swift ${current} and sourcekit-lsp already installed"
    return
  fi

  if ! command -v swiftly >/dev/null 2>&1; then
    tmp="$(mktemp -d)"
    log "Installing Swiftly from swift.org"
    curl -fsSL \
      "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz" \
      -o "${tmp}/swiftly.tar.gz"
    tar -xzf "${tmp}/swiftly.tar.gz" -C "$tmp"
    "${tmp}/swiftly" init --skip-install --quiet-shell-followup --assume-yes
    rm -rf "$tmp"
    source_swiftly
  fi

  log "Installing Swift ${SWIFT_VERSION} (includes sourcekit-lsp)"
  swiftly install "$SWIFT_VERSION" --use --assume-yes
  source_swiftly
  # shellcheck disable=SC2016
  append_once "${HOME}/.bashrc" \
    '[ -s "$HOME/.local/share/swiftly/env.sh" ] && . "$HOME/.local/share/swiftly/env.sh"'
  ok "installed Swift ${SWIFT_VERSION} and sourcekit-lsp"
}

install_fd_alias() {
  mkdir -p "${HOME}/.local/bin"
  if command -v fd >/dev/null 2>&1; then
    ok "fd command already present"
  else
    ln -sfn "$(command -v fdfind)" "${HOME}/.local/bin/fd"
    ok "created ~/.local/bin/fd -> $(command -v fdfind)"
  fi
}

install_shell_integration() {
  # Intentionally preserve the variables for expansion by future shells.
  # shellcheck disable=SC2016
  append_once "${HOME}/.profile" 'export PATH="$HOME/.local/bin:$PATH"'
  if ! nvim_alias_present; then
    # Ubuntu's stock ~/.bashrc already sources this file when it exists.
    append_once "${HOME}/.bash_aliases" 'alias n='\''nvim'\'''
  fi
  ok "shell integration present (~/.local/bin PATH and n=nvim alias)"
}

sync_neovim_config() {
  local backup
  [ -d "$NVIM_CONFIG_SOURCE" ] || die "captured config missing: ${NVIM_CONFIG_SOURCE}"
  if [ -e "$NVIM_CONFIG_DIR" ] && [ ! -f "$NVIM_MARKER" ] \
    && ! diff -qr "$NVIM_CONFIG_SOURCE" "$NVIM_CONFIG_DIR" >/dev/null 2>&1; then
    backup="${NVIM_CONFIG_DIR}.pre-box-bootstrap-$(date -u +%Y%m%dT%H%M%SZ)"
    mv "$NVIM_CONFIG_DIR" "$backup"
    warn "preserved existing unmanaged Neovim config at ${backup}"
  fi
  mkdir -p "$NVIM_CONFIG_DIR"
  rsync -a --delete --exclude='.box-bootstrap-managed' \
    "${NVIM_CONFIG_SOURCE}/" "${NVIM_CONFIG_DIR}/"
  printf 'Managed from %s\n' "$NVIM_CONFIG_SOURCE" > "$NVIM_MARKER"
  ok "synced repository config to ${NVIM_CONFIG_DIR}"
}

install_lazyvim_stack() {
  log "Synchronizing the pinned LazyVim plugin set"
  BOX_BOOTSTRAP_NVIM=1 nvim --headless "+Lazy! sync" +qa
  log "Installing Mason tools and Tree-sitter parsers"
  BOX_BOOTSTRAP_NVIM=1 nvim --headless "+luafile ${SCRIPT_DIR}/bootstrap-nvim.lua"
  ok "LazyVim plugins, LSPs, formatters, linters, and parsers installed"
}

usage() {
  cat <<EOF
Install the complete Neovim/LazyVim environment captured by box-bootstrap.

Usage:
  ./scripts/install-neovim.sh           Install or converge the full stack
  ./scripts/install-neovim.sh --check   Verify it without changing anything

Pinned defaults:
  Neovim ${NEOVIM_VERSION}, Node ${NODE_VERSION}, Go ${GO_VERSION},
  Swift ${SWIFT_VERSION}, lazygit ${LAZYGIT_VERSION},
  tree-sitter CLI ${TREE_SITTER_CLI_VERSION}

Version variables may be overridden in the environment for upgrade testing.
The repository config is the source of truth. An existing unmanaged
~/.config/nvim is timestamp-backed-up before the captured config is installed.
EOF
}

case "${1:-}" in
  --check)
    source_swiftly
    check_neovim_stack
    ;;
  -h|--help)
    usage
    ;;
  "")
    check_disk_space
    ensure_apt_packages
    install_neovim_binary
    install_shell_integration
    install_fd_alias
    install_node
    install_go_toolchain
    install_lazygit
    install_tree_sitter_cli
    install_swift_toolchain
    sync_neovim_config
    install_lazyvim_stack
    log "Neovim bootstrap complete. Open a new shell, then run: n"
    ;;
  *)
    die "unknown option: $1 (see --help)"
    ;;
esac

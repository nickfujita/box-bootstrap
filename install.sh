#!/usr/bin/env bash
#
# box-bootstrap — idempotent personalization of a fresh Spellguard-managed
# EC2 dev box (Ubuntu, systemd). Layers a personal tailnet, a go-grip preview
# service, and a Matrix bridge on top of the org-managed base WITHOUT touching
# anything Spellguard owns (its kernel tailscaled, its ~/.tmux.conf, etc.).
#
# Every component has a --check probe and every install step is a no-op when it
# is already in place, so re-running this script is safe.
#
# Usage:
#   ./install.sh                      # install all five core components
#   ./install.sh --check              # probe all five core components
#   ./install.sh --gogrip             # only the selected core component(s)
#   ./install.sh --neovim             # only the complete editor stack
#   ./install.sh --all                # core five + every --with-* extra
#   ./install.sh --with-go --with-uv   # core five PLUS optional extras
#   ./install.sh --matrix --check     # probe just one component
#
# Secrets are read from the environment (see examples/ccmatrix-config.env.example);
# nothing sensitive is ever written into this repo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNITS_DIR="${SCRIPT_DIR}/units"
EXAMPLES_DIR="${SCRIPT_DIR}/examples"
DOTFILES_DIR="${SCRIPT_DIR}/dotfiles"

# ── Constants ────────────────────────────────────────────────────────────────
GOGRIP_RELEASE_URL="https://github.com/nickfujita/go-grip/releases/latest/download/go-grip-linux-amd64"
GOGRIP_BIN="${HOME}/.local/bin/go-grip"
GOGRIP_UNIT="${HOME}/.config/systemd/user/gogrip.service"

TS_PERSONAL_UNIT="/etc/systemd/system/tailscaled-personal.service"
TS_PERSONAL_SOCK="/run/tailscale-personal/tailscaled.sock"
TS_TAG="tag:cloud-dev"

CCMATRIX_DIR="${HOME}/.ccmatrix"
CCMATRIX_CONFIG="${CCMATRIX_DIR}/config.json"
TMUX_LOCAL="${HOME}/.tmux.conf.local"

BASH_PERSONAL_SOURCE="${DOTFILES_DIR}/bash/bash_personal"
BASH_PERSONAL="${HOME}/.bash_personal"
BASH_ALIASES="${HOME}/.bash_aliases"
BASH_SECRETS="${HOME}/.bash_secrets"
# Per-box generated values (never tracked in this repo); sourced by bash_personal.
BASH_BOX_ENV="${HOME}/.bash_box_env"
# Intentionally single-quoted: the literal line, expanded when the shell reads it.
# shellcheck disable=SC2016
BASH_PERSONAL_HOOK='[ -f "$HOME/.bash_personal" ] && . "$HOME/.bash_personal"'

# Spellguard's managed ~/.profile `exec`s into tmux inside this block, so every
# line BELOW the marker is dead for an interactive login — and tmux panes are
# non-login shells that never read ~/.profile at all. box-bootstrap therefore
# writes shell settings to ~/.bash_personal / ~/.bash_box_env, never ~/.profile.
TMUX_EXEC_MARKER='# >>> spellguard tmux auto-attach >>>'

# The public repo that ships the Claude Code Matrix bridge plugin. Override via
# the PLUGINS_REPO_URL env var to install from a fork or a local marketplace.
PLUGINS_REPO_URL="${PLUGINS_REPO_URL:-nickfujita/matrix-bridge-plugin}"

# ── Logging ──────────────────────────────────────────────────────────────────
log()  { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  [ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  [--]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

# Run privileged commands via sudo only when we are not already root.
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# require_env VARNAME "hint" — fail with a clear message if the var is unset/empty.
require_env() {
  local name="$1" hint="${2:-}"
  if [ -z "${!name:-}" ]; then
    die "\$${name} is required but not set. ${hint}"
  fi
}

# append_once FILE LINE — append LINE to FILE unless it is already there.
# Kept byte-identical to scripts/install-neovim.sh's copy; that script stays
# standalone, so the definition is deliberately duplicated rather than shared.
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

# Talk to the PERSONAL tailscaled over its private socket (needs root).
ts_personal() { $SUDO tailscale --socket="$TS_PERSONAL_SOCK" "$@"; }

# ═════════════════════════════════════════════════════════════════════════════
# Component: personal shell config (~/.bash_personal)
# ═════════════════════════════════════════════════════════════════════════════

# Warn about box-bootstrap exports stranded below ~/.profile's tmux `exec`.
# Purely diagnostic — it never edits ~/.profile — and only fires on boxes
# provisioned before shell settings moved out of ~/.profile.
check_profile_dead_exports() {
  local profile="${HOME}/.profile" marker_line dead line
  if [ ! -f "$profile" ]; then
    ok "no ~/.profile; nothing can be stranded below a tmux exec"
    return 0
  fi
  marker_line="$(grep -nF -- "$TMUX_EXEC_MARKER" "$profile" 2>/dev/null | head -n1 | cut -d: -f1)" || true
  if [ -z "$marker_line" ]; then
    ok "~/.profile has no tmux auto-attach block"
    return 0
  fi
  dead="$(tail -n +"$marker_line" "$profile" \
    | grep -E '^[[:space:]]*export[[:space:]]+(CCMATRIX_VM_LETTER|PATH)=' || true)"
  if [ -n "$dead" ]; then
    warn "~/.profile exports below '${TMUX_EXEC_MARKER}' are DEAD (the block execs into tmux, and tmux panes skip ~/.profile entirely):"
    while IFS= read -r line; do
      [ -n "$line" ] && warn "    ${line}"
    done <<< "$dead"
    warn "    move them to ~/.bash_box_env (per-box) or dotfiles/bash/bash_personal (portable), then re-run './install.sh --shell --matrix'"
    return 1
  fi
  ok "no box-bootstrap exports stranded below the ~/.profile tmux exec"
  return 0
}

# The tracked dotfile is committed to a git repository, so a credential in it
# would be published. Fail loudly rather than ship one.
check_bash_personal_no_secrets() {
  local hits
  hits="$(grep -nE '^[^#]*(TOKEN|SECRET|API_KEY|PASSWORD)[[:space:]]*=' "$BASH_PERSONAL_SOURCE" 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    warn "dotfiles/bash/bash_personal assigns something credential-shaped — it is tracked in git and must never hold a secret:"
    printf '%s\n' "$hits" >&2
    warn "    move it to ~/.bash_secrets (mode 0600, untracked)"
    return 1
  fi
  ok "tracked bash_personal holds no credential-shaped assignment"
  return 0
}

check_shell() {
  local status=0
  if [ -f "${HOME}/.bashrc" ]; then
    ok "~/.bashrc present"
  else
    warn "~/.bashrc missing"; status=1
  fi

  if grep -q '\.bash_aliases' "${HOME}/.bashrc" 2>/dev/null; then
    ok "~/.bashrc sources ~/.bash_aliases"
  else
    warn "~/.bashrc does not source ~/.bash_aliases"; status=1
  fi

  if [ ! -f "$BASH_PERSONAL" ]; then
    warn "~/.bash_personal missing"; status=1
  elif cmp -s "$BASH_PERSONAL_SOURCE" "$BASH_PERSONAL"; then
    ok "~/.bash_personal matches dotfiles/bash/bash_personal"
  else
    warn "~/.bash_personal differs from dotfiles/bash/bash_personal (drift; re-run --shell)"; status=1
  fi

  if grep -qF -- "$BASH_PERSONAL_HOOK" "$BASH_ALIASES" 2>/dev/null; then
    ok "~/.bash_aliases sources ~/.bash_personal"
  else
    warn "~/.bash_aliases is missing the ~/.bash_personal hook line"; status=1
  fi

  # Behavioral: assert in the shell type that actually failed — a NON-LOGIN
  # interactive bash, which is what a tmux pane runs and what never reads
  # ~/.profile. A green structural check with a red arm here is the exact
  # failure this component exists to prevent.
  if env -i HOME="$HOME" TERM=dumb bash -ic 'type dps' >/dev/null 2>&1; then
    ok "a non-login interactive shell sees the personal config (type dps)"
  else
    warn "a non-login interactive shell does NOT see 'dps' — ~/.bash_personal is not reaching tmux panes"; status=1
  fi

  # Diagnostic only — deliberately does NOT set status. box-bootstrap refuses to
  # rewrite a pre-existing ~/.profile, so a legacy box could never make this arm
  # green, and a permanently-red --check trains people to ignore it. Once the
  # arms above pass, those stranded lines are dead cruft rather than a live
  # defect: ~/.bash_personal supersedes every one of them. A box that genuinely
  # is not getting its settings fails the four structural arms and the
  # behavioral arm anyway.
  check_profile_dead_exports || true
  check_bash_personal_no_secrets || status=1
  return $status
}

install_shell() {
  log "Component: personal shell config (~/.bash_personal)"

  [ -f "$BASH_PERSONAL_SOURCE" ] || die "tracked shell config missing: ${BASH_PERSONAL_SOURCE}"

  # 1. Seed ~/.bashrc from the distro skeleton ONLY when it is absent. An
  #    existing ~/.bashrc is the user's (or Spellguard's); never clobber it.
  if [ -f "${HOME}/.bashrc" ]; then
    ok "~/.bashrc already present; left untouched"
  elif [ -f /etc/skel/.bashrc ]; then
    install -m 0644 /etc/skel/.bashrc "${HOME}/.bashrc"
    ok "seeded ~/.bashrc from /etc/skel/.bashrc"
  else
    warn "~/.bashrc is missing and /etc/skel/.bashrc does not exist; create one or ~/.bash_personal will never be sourced"
  fi

  # 2. Install the tracked personal config. Whole-file replace (the repo copy is
  #    the source of truth, as with dotfiles/nvim), no-op when already identical.
  if cmp -s "$BASH_PERSONAL_SOURCE" "$BASH_PERSONAL"; then
    ok "~/.bash_personal already matches the repository copy"
  else
    install -m 0644 "$BASH_PERSONAL_SOURCE" "$BASH_PERSONAL"
    ok "installed ~/.bash_personal (mode 0644) from dotfiles/bash/bash_personal"
  fi

  # 3. Hook it in through ~/.bash_aliases, which the stock Ubuntu ~/.bashrc
  #    sources for every interactive shell — login and non-login alike.
  #    append_once, so the neovim component's "alias n='nvim'" line survives.
  append_once "$BASH_ALIASES" "$BASH_PERSONAL_HOOK"
  ok "~/.bash_aliases sources ~/.bash_personal"

  # 4. Create the secrets file at 0600 if absent. box-bootstrap NEVER writes
  #    into it — it exists so there is an obvious place for tokens that is not
  #    this repository.
  if [ -f "$BASH_SECRETS" ]; then
    chmod 600 "$BASH_SECRETS"
    ok "~/.bash_secrets present; left untouched (mode 0600 enforced)"
  else
    install -m 600 /dev/null "$BASH_SECRETS"
    ok "created empty ~/.bash_secrets (mode 0600) — put tokens there, never in the repo"
  fi

  # 5. Report, but do not fix, settings stranded in a pre-existing ~/.profile.
  check_profile_dead_exports || true
}

# ═════════════════════════════════════════════════════════════════════════════
# Component: personal tailscaled (userspace networking)
# ═════════════════════════════════════════════════════════════════════════════
check_tailscale() {
  local status=0
  if command -v tailscaled >/dev/null 2>&1 || [ -x /usr/sbin/tailscaled ]; then
    ok "tailscaled binary present"
  else
    warn "tailscaled binary missing"; status=1
  fi
  if [ -f "$TS_PERSONAL_UNIT" ]; then
    ok "tailscaled-personal.service installed"
  else
    warn "tailscaled-personal.service not installed"; status=1
  fi
  if systemctl is-active --quiet tailscaled-personal.service 2>/dev/null; then
    ok "tailscaled-personal.service active"
  else
    warn "tailscaled-personal.service not active"; status=1
  fi
  if ts_personal status >/dev/null 2>&1; then
    ok "personal tailnet is up"
  else
    warn "personal tailnet not up (or unreadable without sudo)"; status=1
  fi
  return $status
}

download_tailscaled_static() {
  local arch json tgz dir tmp
  case "$(uname -m)" in
    x86_64)  arch=amd64 ;;
    aarch64) arch=arm64 ;;
    *) die "unsupported architecture $(uname -m) for tailscale static download" ;;
  esac
  json="$(curl -fsSL 'https://pkgs.tailscale.com/stable/?mode=json')" \
    || die "could not query pkgs.tailscale.com for the latest version"
  if command -v jq >/dev/null 2>&1; then
    tgz="$(printf '%s' "$json" | jq -r --arg a "$arch" '.Tarballs[$a] // empty')"
  else
    tgz="$(printf '%s' "$json" | tr ',{}' '\n' \
      | sed -n "s/.*\"${arch}\" *: *\"\(tailscale_[^\"]*\.tgz\)\".*/\1/p" | head -n1)"
  fi
  [ -n "$tgz" ] || die "could not determine the tailscale ${arch} tarball name"
  dir="${tgz%.tgz}"

  tmp="$(mktemp -d)"
  log "Fetching https://pkgs.tailscale.com/stable/${tgz}"
  curl -fsSL "https://pkgs.tailscale.com/stable/${tgz}" -o "${tmp}/${tgz}"
  tar -xzf "${tmp}/${tgz}" -C "$tmp"
  $SUDO install -m 0755 "${tmp}/${dir}/tailscaled" /usr/sbin/tailscaled
  $SUDO install -m 0755 "${tmp}/${dir}/tailscale" /usr/bin/tailscale
  rm -rf "$tmp"
}

install_tailscale() {
  log "Component: personal tailscaled (userspace networking)"

  # 1. Ensure the tailscaled binary exists (managed boxes already ship it).
  if command -v tailscaled >/dev/null 2>&1 || [ -x /usr/sbin/tailscaled ]; then
    ok "tailscaled binary already present; skipping download"
  else
    download_tailscaled_static
  fi

  # 2. Install/refresh the SYSTEM unit for the second daemon.
  if [ -f "$TS_PERSONAL_UNIT" ] && cmp -s "${UNITS_DIR}/tailscaled-personal.service" "$TS_PERSONAL_UNIT"; then
    ok "tailscaled-personal.service already up to date"
  else
    $SUDO install -m 0644 "${UNITS_DIR}/tailscaled-personal.service" "$TS_PERSONAL_UNIT"
    $SUDO systemctl daemon-reload
    ok "installed $TS_PERSONAL_UNIT"
  fi
  $SUDO systemctl enable --now tailscaled-personal.service

  # 3. Bring the personal tailnet up — idempotent: skip if already up.
  if ts_personal status >/dev/null 2>&1; then
    ok "personal tailnet already up; skipping 'tailscale up'"
  else
    require_env TS_AUTHKEY "Mint a reusable key authorized for ${TS_TAG} in the PERSONAL tailnet admin console."
    require_env BOX_NAME "Set BOX_NAME to this node's hostname in the personal tailnet."
    log "Bringing up personal tailnet as '${BOX_NAME}'"
    # --shields-up: refuse ALL inbound connections from the personal tailnet.
    # This link is outbound-only by design (Matrix homeserver via the :1055
    # proxy); inbound access to the box belongs to the provider's managed
    # Tailscale setup, never this daemon.
    ts_personal up \
      --authkey="$TS_AUTHKEY" \
      --advertise-tags="$TS_TAG" \
      --hostname="$BOX_NAME" \
      --shields-up
    ok "personal tailnet up (shields-up: inbound refused)"
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
# Component: go-grip preview service (user unit)
# ═════════════════════════════════════════════════════════════════════════════
check_gogrip() {
  local status=0
  if [ -x "$GOGRIP_BIN" ]; then ok "go-grip binary present"; else warn "go-grip binary missing"; status=1; fi
  if [ -f "$GOGRIP_UNIT" ]; then ok "gogrip.service installed"; else warn "gogrip.service not installed"; status=1; fi
  if systemctl --user is-enabled --quiet gogrip.service 2>/dev/null; then
    ok "gogrip.service enabled"
  else
    warn "gogrip.service not enabled"; status=1
  fi
  return $status
}

install_gogrip() {
  log "Component: go-grip preview service"

  mkdir -p "$(dirname "$GOGRIP_BIN")"
  if [ -x "$GOGRIP_BIN" ]; then
    ok "go-grip already installed at ${GOGRIP_BIN}; skipping download"
  else
    log "Downloading go-grip release binary"
    curl -fsSL "$GOGRIP_RELEASE_URL" -o "$GOGRIP_BIN" \
      || die "download failed: ${GOGRIP_RELEASE_URL} — has a release been cut yet? (see README)"
    chmod +x "$GOGRIP_BIN"
    ok "installed ${GOGRIP_BIN}"
  fi

  mkdir -p "$(dirname "$GOGRIP_UNIT")"
  install -m 0644 "${UNITS_DIR}/gogrip.service" "$GOGRIP_UNIT"

  # Keep the user service running when no login session is active.
  $SUDO loginctl enable-linger "$USER" \
    || warn "could not enable-linger for ${USER}; the user service may stop at logout"

  systemctl --user daemon-reload
  systemctl --user enable --now gogrip.service
  ok "go-grip service enabled on port 6419"
}

# ═════════════════════════════════════════════════════════════════════════════
# Component: Matrix bridge plugin + ccmatrix config
# ═════════════════════════════════════════════════════════════════════════════
check_matrix() {
  local status=0 perm
  if [ -f "$CCMATRIX_CONFIG" ]; then
    ok "ccmatrix config present"
    perm="$(stat -c '%a' "$CCMATRIX_CONFIG" 2>/dev/null || echo '???')"
    [ "$perm" = "600" ] || { warn "ccmatrix config mode is ${perm}, expected 600"; status=1; }
  else
    warn "ccmatrix config missing"; status=1
  fi
  if grep -q '^export CCMATRIX_VM_LETTER=' "$BASH_BOX_ENV" 2>/dev/null; then
    ok "CCMATRIX_VM_LETTER exported in ~/.bash_box_env"
  elif grep -q '^export CCMATRIX_VM_LETTER=' "${HOME}/.profile" 2>/dev/null; then
    warn "CCMATRIX_VM_LETTER lives only in ~/.profile (legacy: dead below the tmux exec; ~/.bash_personal re-derives it). Re-run '--matrix' with CCMATRIX_VM_LETTER set to migrate it."; status=1
  else
    warn "CCMATRIX_VM_LETTER not exported in ~/.bash_box_env"; status=1
  fi
  if [ -f "$TMUX_LOCAL" ]; then ok "${TMUX_LOCAL} present"; else warn "${TMUX_LOCAL} missing"; status=1; fi
  if command -v codex-matrix >/dev/null 2>&1; then ok "codex-matrix CLI available"; else warn "codex-matrix CLI not found"; status=1; fi
  return $status
}

write_ccmatrix_config() {
  local proxy="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg homeserver    "$CCMATRIX_HOMESERVER" \
      --arg user_id       "$CCMATRIX_USER_ID" \
      --arg access_token  "$CCMATRIX_ACCESS_TOKEN" \
      --arg admin_user_id "$CCMATRIX_ADMIN_USER_ID" \
      --arg proxy_url     "$proxy" \
      '{homeserver:$homeserver, user_id:$user_id, access_token:$access_token, admin_user_id:$admin_user_id, proxy_url:$proxy_url}' \
      > "$CCMATRIX_CONFIG"
  else
    # Fallback writer (no jq). Values here are opaque tokens/ids without quotes.
    cat > "$CCMATRIX_CONFIG" <<EOF
{
  "homeserver": "${CCMATRIX_HOMESERVER}",
  "user_id": "${CCMATRIX_USER_ID}",
  "access_token": "${CCMATRIX_ACCESS_TOKEN}",
  "admin_user_id": "${CCMATRIX_ADMIN_USER_ID}",
  "proxy_url": "${proxy}"
}
EOF
  fi
}

install_matrix() {
  log "Component: Matrix bridge plugin"

  # 1. Register the Claude Code plugins marketplace.
  if ! command -v claude >/dev/null 2>&1; then
    warn "claude CLI not found; skipping marketplace add. Add it manually once available."
  elif claude plugin marketplace list 2>/dev/null | grep -qF -- "$PLUGINS_REPO_URL"; then
    ok "plugins marketplace already added"
  else
    log "Adding plugins marketplace: ${PLUGINS_REPO_URL}"
    claude plugin marketplace add "$PLUGINS_REPO_URL"
  fi

  # 2. Enable the Matrix bridge.
  if command -v codex-matrix >/dev/null 2>&1; then
    codex-matrix enable
    ok "codex-matrix enabled"
  else
    warn "codex-matrix CLI not found; run 'codex-matrix enable' after the plugin installs."
  fi

  # 3. Write ~/.ccmatrix/config.json (0600) — only if absent, so re-runs are no-ops.
  mkdir -p "$CCMATRIX_DIR"
  chmod 700 "$CCMATRIX_DIR"
  if [ -f "$CCMATRIX_CONFIG" ]; then
    chmod 600 "$CCMATRIX_CONFIG"
    ok "ccmatrix config already present; left untouched (mode 0600 enforced)"
  else
    require_env CCMATRIX_HOMESERVER "Matrix homeserver base URL."
    require_env CCMATRIX_USER_ID "The Matrix user this box logs in as."
    require_env CCMATRIX_ACCESS_TOKEN "Access token for CCMATRIX_USER_ID."
    require_env CCMATRIX_ADMIN_USER_ID "Your Matrix user id (the bridge admin)."
    local proxy="${CCMATRIX_PROXY_URL:-http://127.0.0.1:1055}"
    # Pre-create at mode 0600 so the token never touches a world-readable file.
    install -m 600 /dev/null "$CCMATRIX_CONFIG"
    write_ccmatrix_config "$proxy"
    ok "wrote ${CCMATRIX_CONFIG} (mode 0600, proxy ${proxy})"
  fi

  # 4. Export CCMATRIX_VM_LETTER into ~/.bash_box_env (append once).
  #    NOT ~/.profile: Spellguard's managed ~/.profile execs into tmux partway
  #    through, so anything appended after that block never runs, and tmux panes
  #    are non-login shells that skip ~/.profile entirely. ~/.bash_box_env is
  #    sourced by ~/.bash_personal, which every interactive shell reads.
  if grep -q '^export CCMATRIX_VM_LETTER=' "$BASH_BOX_ENV" 2>/dev/null; then
    ok "CCMATRIX_VM_LETTER already exported in ~/.bash_box_env"
  else
    require_env CCMATRIX_VM_LETTER "Single-letter id for this box (e.g. a)."
    append_once "$BASH_BOX_ENV" '# box-bootstrap: per-box values, sourced from ~/.bash_personal. Not tracked in git.'
    append_once "$BASH_BOX_ENV" "$(printf 'export CCMATRIX_VM_LETTER=%q' "$CCMATRIX_VM_LETTER")"
    chmod 0644 "$BASH_BOX_ENV"
    ok "appended CCMATRIX_VM_LETTER to ~/.bash_box_env"
  fi
  [ -f "$BASH_PERSONAL" ] \
    || warn "~/.bash_personal is not installed, so nothing sources ~/.bash_box_env yet; run './install.sh --shell'"

  # 5. Install personal tmux overrides — only if absent.
  #    Spellguard REWRITES ~/.tmux.conf on every bootstrap, but never touches
  #    ~/.tmux.conf.local (which the managed ~/.tmux.conf sources), so personal
  #    tmux settings must live here to survive re-bootstraps.
  if [ -f "$TMUX_LOCAL" ]; then
    ok "${TMUX_LOCAL} already present; left untouched"
  else
    install -m 0644 "${EXAMPLES_DIR}/tmux.conf.local.example" "$TMUX_LOCAL"
    ok "installed ~/.tmux.conf.local"
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
# Optional extras: --with-go / --with-docker / --with-uv
# ═════════════════════════════════════════════════════════════════════════════
check_go()     { if command -v go >/dev/null 2>&1;     then ok "go present";     return 0; else warn "go missing";     return 1; fi; }
check_docker() { if command -v docker >/dev/null 2>&1; then ok "docker present"; return 0; else warn "docker missing"; return 1; fi; }
check_uv()     { if command -v uv >/dev/null 2>&1 || [ -x "${HOME}/.local/bin/uv" ]; then ok "uv present"; return 0; else warn "uv missing"; return 1; fi; }
check_neovim() { "${SCRIPT_DIR}/scripts/install-neovim.sh" --check; }

install_go() {
  log "Component: Go toolchain"
  if command -v go >/dev/null 2>&1; then ok "go already installed ($(go version)); skipping"; return; fi
  local arch ver tgz tmp
  case "$(uname -m)" in
    x86_64)  arch=amd64 ;;
    aarch64) arch=arm64 ;;
    *) die "unsupported architecture $(uname -m) for Go install" ;;
  esac
  ver="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1)"
  [ -n "$ver" ] || die "could not resolve the latest Go version"
  tgz="${ver}.linux-${arch}.tar.gz"
  tmp="$(mktemp -d)"
  curl -fsSL "https://go.dev/dl/${tgz}" -o "${tmp}/${tgz}"
  $SUDO rm -rf /usr/local/go
  $SUDO tar -C /usr/local -xzf "${tmp}/${tgz}"
  rm -rf "$tmp"
  # No PATH line is written here. The tracked dotfiles/bash/bash_personal already
  # puts /usr/local/go/bin on PATH, guarded on the directory existing — and that
  # file is read by every interactive shell, including tmux panes. ~/.profile is
  # not (Spellguard's copy execs into tmux partway through).
  export PATH="${PATH}:/usr/local/go/bin"
  hash -r
  [ -f "$BASH_PERSONAL" ] \
    || warn "~/.bash_personal is not installed, so new shells will not see /usr/local/go/bin; run './install.sh --shell'"
  ok "Go ${ver} installed to /usr/local/go (open a new shell to pick it up)"
}

install_docker() {
  log "Component: Docker"
  if command -v docker >/dev/null 2>&1; then ok "docker already installed; skipping"; return; fi
  curl -fsSL https://get.docker.com | $SUDO sh
  $SUDO usermod -aG docker "$USER" || warn "could not add ${USER} to the docker group"
  ok "Docker installed (log out/in to pick up docker group membership)"
}

install_uv() {
  log "Component: uv"
  if command -v uv >/dev/null 2>&1 || [ -x "${HOME}/.local/bin/uv" ]; then ok "uv already installed; skipping"; return; fi
  curl -LsSf https://astral.sh/uv/install.sh | sh
  ok "uv installed to ~/.local/bin"
}

install_neovim() {
  log "Component: complete Neovim/LazyVim environment"
  "${SCRIPT_DIR}/scripts/install-neovim.sh"
}

# ═════════════════════════════════════════════════════════════════════════════
# CLI
# ═════════════════════════════════════════════════════════════════════════════
usage() {
  cat <<'EOF'
box-bootstrap — personalize a Spellguard-managed cloud dev box (idempotent).

Usage: ./install.sh [--check] [components] [extras]

Core components (default: all five run when none are named):
  --shell         Personal Bash config (~/.bash_personal + ~/.bash_secrets)
  --tailscale     Second, personal tailscaled (userspace networking)
  --gogrip        go-grip markdown preview user service
  --matrix        Matrix bridge plugin + ccmatrix config
  --neovim        Complete captured Neovim/LazyVim stack

Optional extras (off unless requested):
  --with-go       Install the Go toolchain (official tarball)
  --with-docker   Install Docker (get.docker.com)
  --with-uv       Install uv (astral.sh installer)

Modifiers:
  --all           Core five + every extra
  --check         Probe selected components and report; change nothing
  -h, --help      Show this help

Secrets come from the environment; see examples/ccmatrix-config.env.example.
EOF
}

DO_SHELL=0; DO_TAILSCALE=0; DO_GOGRIP=0; DO_MATRIX=0
DO_GO=0; DO_DOCKER=0; DO_UV=0; DO_NEOVIM=0
CHECK_ONLY=0; CORE_SELECTED=0

while [ $# -gt 0 ]; do
  case "$1" in
    --shell)       DO_SHELL=1; CORE_SELECTED=1 ;;
    --tailscale)   DO_TAILSCALE=1; CORE_SELECTED=1 ;;
    --gogrip)      DO_GOGRIP=1; CORE_SELECTED=1 ;;
    --matrix)      DO_MATRIX=1; CORE_SELECTED=1 ;;
    --neovim)      DO_NEOVIM=1; CORE_SELECTED=1 ;;
    --with-go)     DO_GO=1 ;;
    --with-docker) DO_DOCKER=1 ;;
    --with-uv)     DO_UV=1 ;;
    # Backward-compatible alias from when Neovim was an optional extra.
    --with-neovim) DO_NEOVIM=1 ;;
    --all)         DO_SHELL=1; DO_TAILSCALE=1; DO_GOGRIP=1; DO_MATRIX=1; DO_GO=1; DO_DOCKER=1; DO_UV=1; DO_NEOVIM=1; CORE_SELECTED=1 ;;
    --check)       CHECK_ONLY=1 ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

# Default to all five core components when none was specifically selected.
# --shell qualifies as core: it is pure personalization — no network, no
# privilege, no secrets.
if [ "$CORE_SELECTED" -eq 0 ]; then
  DO_SHELL=1; DO_TAILSCALE=1; DO_GOGRIP=1; DO_MATRIX=1; DO_NEOVIM=1
fi

main() {
  local rc=0
  if [ "$CHECK_ONLY" -eq 1 ]; then
    log "Probing selected components (no changes will be made)"
    [ "$DO_SHELL"     -eq 1 ] && { printf -- '── shell ──\n';      check_shell     || rc=1; }
    [ "$DO_TAILSCALE" -eq 1 ] && { printf -- '── tailscale ──\n'; check_tailscale || rc=1; }
    [ "$DO_GOGRIP"    -eq 1 ] && { printf -- '── go-grip ──\n';    check_gogrip    || rc=1; }
    [ "$DO_MATRIX"    -eq 1 ] && { printf -- '── matrix ──\n';     check_matrix    || rc=1; }
    [ "$DO_GO"        -eq 1 ] && { printf -- '── go ──\n';         check_go        || rc=1; }
    [ "$DO_DOCKER"    -eq 1 ] && { printf -- '── docker ──\n';     check_docker    || rc=1; }
    [ "$DO_UV"        -eq 1 ] && { printf -- '── uv ──\n';         check_uv        || rc=1; }
    [ "$DO_NEOVIM"    -eq 1 ] && { printf -- '── neovim ──\n';     check_neovim    || rc=1; }
    if [ "$rc" -eq 0 ]; then ok "all selected components satisfied"; else warn "some components need install (re-run without --check)"; fi
    return $rc
  fi

  [ "$DO_SHELL"     -eq 1 ] && install_shell
  [ "$DO_TAILSCALE" -eq 1 ] && install_tailscale
  [ "$DO_GOGRIP"    -eq 1 ] && install_gogrip
  [ "$DO_MATRIX"    -eq 1 ] && install_matrix
  [ "$DO_GO"        -eq 1 ] && install_go
  [ "$DO_DOCKER"    -eq 1 ] && install_docker
  [ "$DO_UV"        -eq 1 ] && install_uv
  [ "$DO_NEOVIM"    -eq 1 ] && install_neovim
  log "Bootstrap complete."
  return 0
}

main

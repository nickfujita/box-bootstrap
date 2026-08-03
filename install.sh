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
#   ./install.sh                      # install all four core components
#   ./install.sh --check              # probe all four core components
#   ./install.sh --gogrip             # only the selected core component(s)
#   ./install.sh --neovim             # only the complete editor stack
#   ./install.sh --agents             # the six agent-environment components
#   ./install.sh --all                # core four + agents six + every extra
#   ./install.sh --with-go --with-uv   # core four PLUS optional extras
#   ./install.sh --matrix --check     # probe just one component
#
# Secrets are read from the environment (see examples/bootstrap.env.example);
# nothing sensitive is ever written into this repo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNITS_DIR="${SCRIPT_DIR}/units"
EXAMPLES_DIR="${SCRIPT_DIR}/examples"
DOTFILES_DIR="${SCRIPT_DIR}/dotfiles"
NOTIFY_SRC_DIR="${SCRIPT_DIR}/scripts/notify"

# ── Constants ────────────────────────────────────────────────────────────────
GOGRIP_RELEASE_URL="https://github.com/nickfujita/go-grip/releases/latest/download/go-grip-linux-amd64"
GOGRIP_BIN="${HOME}/.local/bin/go-grip"
GOGRIP_UNIT="${HOME}/.config/systemd/user/gogrip.service"
GOGRIP_PORT=6419

TS_PERSONAL_UNIT="/etc/systemd/system/tailscaled-personal.service"
TS_PERSONAL_SOCK="/run/tailscale-personal/tailscaled.sock"
TS_TAG="tag:cloud-dev"

CCMATRIX_DIR="${HOME}/.ccmatrix"
CCMATRIX_CONFIG="${CCMATRIX_DIR}/config.json"
TMUX_LOCAL="${HOME}/.tmux.conf.local"

# The public repo that ships the Claude Code Matrix bridge plugin. Override via
# the PLUGINS_REPO_URL env var to install from a fork or a local marketplace.
PLUGINS_REPO_URL="${PLUGINS_REPO_URL:-nickfujita/matrix-bridge-plugin}"

# ── Claude Code (component: agent-config, global-instructions) ───────────────
CLAUDE_DIR="${HOME}/.claude"
CLAUDE_SETTINGS="${CLAUDE_DIR}/settings.json"
CLAUDE_MD="${CLAUDE_DIR}/CLAUDE.md"
CLAUDE_PLUGIN_STATE="${CLAUDE_DIR}/plugins/installed_plugins.json"
# Anthropic's first-party marketplace; auto-update only works for plugins the
# official CLI installed, so every plugin below goes through `claude plugin`.
CLAUDE_MARKETPLACE="${CLAUDE_MARKETPLACE:-anthropics/claude-plugins-official}"
CLAUDE_MARKETPLACE_NAME="claude-plugins-official"
CLAUDE_PLUGINS="superpowers context7 typescript-lsp pyright-lsp"
# Never installed here — the box provider's managed provisioning owns it. The
# --check probe reports on it; nothing in this script ever installs it.
CLAUDE_PROVIDER_PLUGIN="spellguard@spellguard"

# ── Codex (component: codex-config, global-instructions) ─────────────────────
CODEX_DIR="${HOME}/.codex"
CODEX_CONFIG="${CODEX_DIR}/config.toml"

# The `[agents]` SETTINGS keys (enabled / max_concurrent_threads_per_session /
# max_depth / default_subagent_*) only exist from codex 0.145.0, where
# multi_agent_v2 stabilised. On an older CLI `[agents]` is a map of agent ROLES,
# so those scalars make config.toml fail to parse and EVERY codex command dies
# with "invalid type: boolean `true`, expected struct AgentRoleToml". A managed
# box can ship an older pinned codex than a dev VM, so gate the baseline on the
# installed version rather than assuming. (Hit live on a managed box running
# codex 0.140.0, 2026-08-03.)
CODEX_AGENTS_SETTINGS_MIN="0.145.0"
codex_supports_agents_settings() {
  have_cmd codex || return 1
  local v
  v="$(codex --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  [ -n "$v" ] || return 1
  [ "$(printf '%s\n%s\n' "$CODEX_AGENTS_SETTINGS_MIN" "$v" | sort -V | head -1)" = "$CODEX_AGENTS_SETTINGS_MIN" ]
}

# Emit the baseline to use for the merge: the vendored file, minus the [agents]
# table when the installed codex is too old to understand it.
codex_baseline_file() {
  local src="${DOTFILES_DIR}/codex/config.portable.toml"
  if codex_supports_agents_settings; then
    printf '%s' "$src"
    return
  fi
  local trimmed="${TMPDIR:-/tmp}/box-bootstrap-codex-baseline.$$.toml"
  awk '
    /^\[agents\]$/ { skip = 1; next }
    /^\[/          { skip = 0 }
    !skip          { print }
  ' "$src" > "$trimmed"
  printf '%s' "$trimmed"
}
CODEX_AGENTS_DIR="${CODEX_DIR}/agents"
CODEX_SKILLS_DIR="${CODEX_DIR}/skills"
CODEX_AGENTS_MD="${CODEX_DIR}/AGENTS.md"
CODEX_AGENT_FILES="luna-max.toml terra-xhigh.toml sol-high.toml"
SUPERPOWERS_MARKETPLACE_URL="${SUPERPOWERS_MARKETPLACE_URL:-https://github.com/obra/superpowers.git}"
# The name comes from the marketplace's own manifest, not from the URL.
SUPERPOWERS_MARKETPLACE_NAME="superpowers-dev"
CODEX_PROVIDER_PLUGIN="spellguard@spellguard"

# ── Shell (component: shell) ─────────────────────────────────────────────────
BASHRC="${HOME}/.bashrc"
SHELL_MARKER_START='# >>> box-bootstrap shell block >>>'
SHELL_MARKER_END='# <<< box-bootstrap shell block <<<'
BOX_CONF_DIR="${HOME}/.config/box-bootstrap"
BOX_SHELL_ENV="${BOX_CONF_DIR}/shell.env"
# 12 GB fits a 16 GB dev box; the 4 GB Node default aborts long agent runs.
NODE_MAX_OLD_SPACE_MB="${NODE_MAX_OLD_SPACE_MB:-8192}"

# ── Notifications (component: notifications) ─────────────────────────────────
LOCAL_BIN="${HOME}/.local/bin"
NOTIFY_SCRIPTS="notify-moshi.sh notify-claude.sh notify-claude-attention.sh notify-codex.sh"
MOSHI_CONF_DIR="${HOME}/.config/moshi"
MOSHI_CONF="${MOSHI_CONF_DIR}/webhook.env"

# ── dark-factory (component: dark-factory) ───────────────────────────────────
DARK_FACTORY_REPO_URL="${DARK_FACTORY_REPO_URL:-https://github.com/nickfujita/dark-factory.git}"
DARK_FACTORY_DIR="${HOME}/dark-factory"
DARK_FACTORY_STAMP="${HOME}/.cache/box-bootstrap/agent-browser-installed"

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

# append_profile_once LINE — append LINE to ~/.profile unless it is already there.
append_profile_once() {
  local line="$1"
  grep -qF -- "$line" "${HOME}/.profile" 2>/dev/null || printf '%s\n' "$line" >> "${HOME}/.profile"
}

# backup_file PATH — copy PATH aside with a timestamp, echo the backup path.
# Nothing this script manages is ever replaced without one of these first.
backup_file() {
  local f="$1" bak
  bak="${f}.pre-box-bootstrap-$(date +%Y%m%d%H%M%S)"
  cp -a "$f" "$bak"
  printf '%s' "$bak"
}

# install_managed_file SRC DST [MODE] — converge DST to SRC. A pre-existing
# different DST is backed up first; an identical DST is a no-op.
install_managed_file() {
  local src="$1" dst="$2" mode="${3:-0644}" bak
  mkdir -p "$(dirname "$dst")"
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    ok "${dst} already up to date"
    return 0
  fi
  if [ -e "$dst" ]; then
    bak="$(backup_file "$dst")"
    warn "backed up existing ${dst} to ${bak}"
  fi
  install -m "$mode" "$src" "$dst"
  ok "installed ${dst}"
}

# have_cmd NAME — quiet command probe.
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# claude_cli / codex_cli — resolve the agent CLIs, which live in ~/.local/bin or
# an nvm-managed prefix that a non-login shell may not have on PATH yet.
agent_cli_path() {
  local name="$1"
  if have_cmd "$name"; then command -v "$name"; return 0; fi
  if [ -x "${LOCAL_BIN}/${name}" ]; then printf '%s' "${LOCAL_BIN}/${name}"; return 0; fi
  return 1
}

# Talk to the PERSONAL tailscaled over its private socket (needs root).
ts_personal() { $SUDO tailscale --socket="$TS_PERSONAL_SOCK" "$@"; }

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
  if grep -q '^export CCMATRIX_VM_LETTER=' "${HOME}/.profile" 2>/dev/null; then
    ok "CCMATRIX_VM_LETTER exported in ~/.profile"
  else
    warn "CCMATRIX_VM_LETTER not exported in ~/.profile"; status=1
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

  # 4. Export CCMATRIX_VM_LETTER into ~/.profile (append once).
  if grep -q '^export CCMATRIX_VM_LETTER=' "${HOME}/.profile" 2>/dev/null; then
    ok "CCMATRIX_VM_LETTER already exported in ~/.profile"
  else
    require_env CCMATRIX_VM_LETTER "Single-letter id for this box (e.g. a)."
    {
      printf '\n# box-bootstrap: identify this cloud dev box\n'
      printf 'export CCMATRIX_VM_LETTER=%q\n' "$CCMATRIX_VM_LETTER"
    } >> "${HOME}/.profile"
    ok "appended CCMATRIX_VM_LETTER to ~/.profile"
  fi

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
# Component: Claude Code settings + official plugins  (--agent-config)
# ═════════════════════════════════════════════════════════════════════════════
# The Stop/Notification hooks point at the scripts --notifications installs.
# They are only written when those scripts exist (or are about to).
claude_hooks_wanted() {
  [ "${DO_NOTIFICATIONS:-0}" -eq 1 ] || [ -x "${LOCAL_BIN}/notify-claude.sh" ]
}

# Render the vendored settings template into $1, dropping the notification
# hooks when the notifier scripts are not part of this box.
render_claude_settings() {
  local dst="$1" src="${DOTFILES_DIR}/claude/settings.template.json" tmp
  sed "s|{{HOME}}|${HOME}|g" "$src" > "$dst"
  if claude_hooks_wanted; then return 0; fi
  if have_cmd jq; then
    tmp="$(mktemp)"
    jq 'del(.hooks.Stop, .hooks.Notification)' "$dst" > "$tmp" && mv "$tmp" "$dst"
    ok "notification hooks omitted (--notifications not selected)"
  else
    warn "jq not found; leaving the notification hook entries in settings.json (they no-op until --notifications runs)"
  fi
}

check_agent_config() {
  local status=0 p
  if [ -f "$CLAUDE_SETTINGS" ]; then
    ok "~/.claude/settings.json present"
    grep -q '"model"'      "$CLAUDE_SETTINGS" || { warn "no model pin in settings.json"; status=1; }
    grep -q '"effortLevel"' "$CLAUDE_SETTINGS" || { warn "no effortLevel in settings.json"; status=1; }
    grep -q 'Co-Authored-By' "$CLAUDE_SETTINGS" || { warn "attribution-blocker PreToolUse hook missing"; status=1; }
    if claude_hooks_wanted; then
      grep -q 'notify-claude.sh' "$CLAUDE_SETTINGS" || { warn "Stop/Notification hooks not wired to ~/.local/bin"; status=1; }
    fi
  else
    warn "~/.claude/settings.json missing"; status=1
  fi
  for p in $CLAUDE_PLUGINS; do
    if grep -qF "\"${p}@${CLAUDE_MARKETPLACE_NAME}\"" "$CLAUDE_PLUGIN_STATE" 2>/dev/null; then
      ok "plugin ${p}@${CLAUDE_MARKETPLACE_NAME} installed"
    else
      warn "plugin ${p}@${CLAUDE_MARKETPLACE_NAME} not installed"; status=1
    fi
  done
  # Informational only: the provider's managed provisioning owns this one, so
  # its absence is never a box-bootstrap failure.
  if grep -qF "\"${CLAUDE_PROVIDER_PLUGIN}\"" "$CLAUDE_PLUGIN_STATE" 2>/dev/null; then
    ok "provider plugin ${CLAUDE_PROVIDER_PLUGIN} present (managed; not installed by this script)"
  else
    warn "provider plugin ${CLAUDE_PROVIDER_PLUGIN} absent (managed provisioning installs it; not a box-bootstrap failure)"
  fi
  return $status
}

install_agent_config() {
  log "Component: Claude Code settings + official plugins"

  local rendered merged claude p
  mkdir -p "$CLAUDE_DIR"

  # 1. ~/.claude/settings.json — never clobbered without a backup.
  rendered="$(mktemp)"
  render_claude_settings "$rendered"

  if [ ! -f "$CLAUDE_SETTINGS" ]; then
    install -m 0644 "$rendered" "$CLAUDE_SETTINGS"
    ok "wrote ${CLAUDE_SETTINGS}"
  elif have_cmd jq; then
    # Deep-merge: our keys win, everything else the file already holds
    # (enabledPlugins, extraKnownMarketplaces, provider-written keys) survives.
    merged="$(mktemp)"
    jq -s '.[0] * .[1]' "$CLAUDE_SETTINGS" "$rendered" > "$merged"
    if diff -q <(jq -S . "$CLAUDE_SETTINGS") <(jq -S . "$merged") >/dev/null 2>&1; then
      ok "settings.json already carries the box-bootstrap keys"
    else
      warn "backed up existing settings.json to $(backup_file "$CLAUDE_SETTINGS")"
      install -m 0644 "$merged" "$CLAUDE_SETTINGS"
      ok "merged box-bootstrap keys into ${CLAUDE_SETTINGS}"
    fi
    rm -f "$merged"
  elif cmp -s "$rendered" "$CLAUDE_SETTINGS"; then
    ok "settings.json already up to date"
  else
    warn "jq not found — replacing settings.json wholesale (any enabledPlugins state is re-created by the plugin installs below)"
    warn "backed up existing settings.json to $(backup_file "$CLAUDE_SETTINGS")"
    install -m 0644 "$rendered" "$CLAUDE_SETTINGS"
  fi
  rm -f "$rendered"

  # 2. Plugins, through the official CLI only — a hand-copied plugin never
  #    auto-updates.
  if ! claude="$(agent_cli_path claude)"; then
    warn "claude CLI not found; skipping plugin installs. Re-run --agent-config once it is on PATH."
    return 0
  fi

  if "$claude" plugin marketplace list 2>/dev/null | grep -qF -- "$CLAUDE_MARKETPLACE"; then
    ok "marketplace ${CLAUDE_MARKETPLACE} already added"
  else
    log "Adding Claude marketplace: ${CLAUDE_MARKETPLACE}"
    "$claude" plugin marketplace add "$CLAUDE_MARKETPLACE" \
      || warn "could not add ${CLAUDE_MARKETPLACE}"
  fi

  for p in $CLAUDE_PLUGINS; do
    if grep -qF "\"${p}@${CLAUDE_MARKETPLACE_NAME}\"" "$CLAUDE_PLUGIN_STATE" 2>/dev/null; then
      ok "plugin ${p} already installed"
    else
      log "Installing plugin ${p}@${CLAUDE_MARKETPLACE_NAME}"
      "$claude" plugin install "${p}@${CLAUDE_MARKETPLACE_NAME}" \
        || warn "could not install ${p}@${CLAUDE_MARKETPLACE_NAME}"
    fi
  done
}

# ═════════════════════════════════════════════════════════════════════════════
# Component: Codex config, custom agents, skills + plugins  (--codex-config)
# ═════════════════════════════════════════════════════════════════════════════
codex_config_satisfied() {
  "${SCRIPT_DIR}/scripts/merge-codex-config.sh" --check \
    --baseline "$(codex_baseline_file)" \
    --target "$CODEX_CONFIG" >/dev/null 2>&1
}

check_codex_config() {
  local status=0 f missing
  for f in $CODEX_AGENT_FILES; do
    if [ -f "${CODEX_AGENTS_DIR}/${f}" ] && cmp -s "${DOTFILES_DIR}/codex/agents/${f}" "${CODEX_AGENTS_DIR}/${f}"; then
      ok "agent ${f} in place"
    else
      warn "agent ${f} missing or drifted"; status=1
    fi
  done
  if codex_config_satisfied; then
    ok "portable config keys present in ~/.codex/config.toml"
  else
    missing="$("${SCRIPT_DIR}/scripts/merge-codex-config.sh" --check \
      --baseline "$(codex_baseline_file)" \
      --target "$CODEX_CONFIG" 2>/dev/null | tr '\n' ' ' || true)"
    warn "portable config keys missing from ~/.codex/config.toml: ${missing}"; status=1
  fi
  if grep -q "^\[marketplaces\.${SUPERPOWERS_MARKETPLACE_NAME}\]" "$CODEX_CONFIG" 2>/dev/null; then
    ok "marketplace ${SUPERPOWERS_MARKETPLACE_NAME} configured"
  else
    warn "marketplace ${SUPERPOWERS_MARKETPLACE_NAME} not configured"; status=1
  fi
  for f in "superpowers@${SUPERPOWERS_MARKETPLACE_NAME}" "github@openai-curated"; do
    if grep -qF "[plugins.\"${f}\"]" "$CODEX_CONFIG" 2>/dev/null; then
      ok "codex plugin ${f} installed"
    else
      warn "codex plugin ${f} not installed"; status=1
    fi
  done
  # Informational only, exactly as on the Claude side.
  if grep -qF "[plugins.\"${CODEX_PROVIDER_PLUGIN}\"]" "$CODEX_CONFIG" 2>/dev/null; then
    ok "provider plugin ${CODEX_PROVIDER_PLUGIN} present (managed; not installed by this script)"
  else
    warn "provider plugin ${CODEX_PROVIDER_PLUGIN} absent (managed provisioning installs it; not a box-bootstrap failure)"
  fi
  return $status
}

install_codex_config() {
  log "Component: Codex config, custom agents, skills + plugins"

  local f tmp codex

  # 1. Custom agents.
  mkdir -p "$CODEX_AGENTS_DIR"
  for f in $CODEX_AGENT_FILES; do
    install_managed_file "${DOTFILES_DIR}/codex/agents/${f}" "${CODEX_AGENTS_DIR}/${f}" 0644
  done

  # 2. Portable config keys — ADDITIVE ONLY. An existing key keeps its value,
  #    and the tables the provider writes (shell_environment_policy,
  #    hooks.state, projects, marketplaces) are never named, so never touched.
  if codex_config_satisfied; then
    ok "~/.codex/config.toml already carries every portable key"
  else
    tmp="$(mktemp)"
    "${SCRIPT_DIR}/scripts/merge-codex-config.sh" \
      --baseline "$(codex_baseline_file)" \
      --target "$CODEX_CONFIG" > "$tmp"
    if [ -f "$CODEX_CONFIG" ]; then
      warn "backed up existing config.toml to $(backup_file "$CODEX_CONFIG")"
      # Write through the existing inode so the file keeps its mode/owner.
      cat "$tmp" > "$CODEX_CONFIG"
    else
      mkdir -p "$CODEX_DIR"
      install -m 0600 "$tmp" "$CODEX_CONFIG"
    fi
    rm -f "$tmp"
    ok "merged the portable keys into ${CODEX_CONFIG}"
  fi

  # 4. Plugins, through the official CLI only.
  if ! codex="$(agent_cli_path codex)"; then
    warn "codex CLI not found; skipping plugin installs. Re-run --codex-config once it is on PATH."
    return 0
  fi

  if grep -q "^\[marketplaces\.${SUPERPOWERS_MARKETPLACE_NAME}\]" "$CODEX_CONFIG" 2>/dev/null; then
    ok "marketplace ${SUPERPOWERS_MARKETPLACE_NAME} already added"
  else
    log "Adding Codex marketplace: ${SUPERPOWERS_MARKETPLACE_URL}"
    "$codex" plugin marketplace add "$SUPERPOWERS_MARKETPLACE_URL" --ref main \
      || warn "could not add ${SUPERPOWERS_MARKETPLACE_URL}"
  fi

  # `openai-curated` ships with the CLI, so github@openai-curated needs no
  # marketplace add of its own.
  for f in "superpowers@${SUPERPOWERS_MARKETPLACE_NAME}" "github@openai-curated"; do
    if grep -qF "[plugins.\"${f}\"]" "$CODEX_CONFIG" 2>/dev/null; then
      ok "codex plugin ${f} already installed"
    else
      log "Installing codex plugin ${f}"
      "$codex" plugin add "$f" || warn "could not install ${f}"
    fi
  done
}

# ═════════════════════════════════════════════════════════════════════════════
# Component: ~/.bashrc block  (--shell)
# ═════════════════════════════════════════════════════════════════════════════
check_shell() {
  local status=0 perm attaches
  if grep -qF "$SHELL_MARKER_START" "$BASHRC" 2>/dev/null; then
    ok "box-bootstrap shell block present in ~/.bashrc"
  else
    warn "box-bootstrap shell block missing from ~/.bashrc"; status=1
  fi
  # An unmanaged tmux auto-attach is fine; a SECOND one double-attaches, which
  # is exactly why the vendored block leaves tmux alone.
  attaches="$(grep -c 'tmux attach-session' "$BASHRC" 2>/dev/null || true)"
  [ -n "$attaches" ] || attaches=0
  if [ "$attaches" -gt 1 ]; then
    warn "~/.bashrc has ${attaches} tmux auto-attach blocks — logins will double-attach"; status=1
  else
    ok "at most one tmux auto-attach block in ~/.bashrc"
  fi
  if [ -f "$BOX_SHELL_ENV" ]; then
    perm="$(stat -c '%a' "$BOX_SHELL_ENV" 2>/dev/null || echo '???')"
    if [ "$perm" = "600" ]; then ok "${BOX_SHELL_ENV} present (mode 600)"
    else warn "${BOX_SHELL_ENV} mode is ${perm}, expected 600"; status=1; fi
  else
    ok "${BOX_SHELL_ENV} absent (optional)"
  fi
  return $status
}

install_shell() {
  log "Component: ~/.bashrc block"

  local src rendered current tmp bak
  src="${DOTFILES_DIR}/shell/bashrc-block.sh"
  rendered="$(mktemp)"
  sed "s|{{NODE_MAX_OLD_SPACE_MB}}|${NODE_MAX_OLD_SPACE_MB}|g" "$src" > "$rendered"

  touch "$BASHRC"
  if grep -qF "$SHELL_MARKER_START" "$BASHRC"; then
    current="$(mktemp)"
    awk -v s="$SHELL_MARKER_START" -v e="$SHELL_MARKER_END" \
      '$0==s {inb=1; next} $0==e {inb=0; next} inb {print}' "$BASHRC" > "$current"
    if cmp -s "$current" "$rendered"; then
      ok "shell block already current"
    else
      bak="$(backup_file "$BASHRC")"
      warn "backed up ~/.bashrc to ${bak}"
      tmp="$(mktemp)"
      awk -v s="$SHELL_MARKER_START" -v e="$SHELL_MARKER_END" -v f="$rendered" '
        $0==s { print; while ((getline l < f) > 0) print l; close(f); inb=1; next }
        $0==e { print; inb=0; next }
        inb   { next }
        { print }' "$BASHRC" > "$tmp"
      cat "$tmp" > "$BASHRC"
      rm -f "$tmp"
      ok "refreshed the box-bootstrap block in ~/.bashrc"
    fi
    rm -f "$current"
  else
    {
      printf '\n%s\n' "$SHELL_MARKER_START"
      cat "$rendered"
      printf '%s\n' "$SHELL_MARKER_END"
    } >> "$BASHRC"
    ok "appended the box-bootstrap block to ~/.bashrc"
  fi
  rm -f "$rendered"

  # Optional shell secrets, kept out of the world-readable ~/.bashrc. The block
  # above sources this file when it exists; rotating a value is an edit here.
  if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
    mkdir -p "$BOX_CONF_DIR"
    chmod 700 "$BOX_CONF_DIR"
    if [ ! -f "$BOX_SHELL_ENV" ]; then
      install -m 600 /dev/null "$BOX_SHELL_ENV"
      printf '# box-bootstrap shell secrets — sourced by ~/.bashrc. Mode 0600.\n' > "$BOX_SHELL_ENV"
    fi
    chmod 600 "$BOX_SHELL_ENV"
    if grep -q '^export CLOUDFLARE_API_TOKEN=' "$BOX_SHELL_ENV"; then
      ok "CLOUDFLARE_API_TOKEN already in ${BOX_SHELL_ENV}; left untouched (edit it to rotate)"
    else
      printf 'export CLOUDFLARE_API_TOKEN=%q\n' "$CLOUDFLARE_API_TOKEN" >> "$BOX_SHELL_ENV"
      ok "wrote CLOUDFLARE_API_TOKEN to ${BOX_SHELL_ENV} (mode 0600)"
    fi
  else
    ok "CLOUDFLARE_API_TOKEN not set; skipping ${BOX_SHELL_ENV}"
  fi

  log "Open a new shell or run 'source ~/.bashrc' to pick the block up."
}

# ═════════════════════════════════════════════════════════════════════════════
# Component: dark-factory skills + agent-browser  (--dark-factory)
# ═════════════════════════════════════════════════════════════════════════════
check_dark_factory() {
  local status=0
  if have_cmd just; then ok "just present"; else warn "just missing"; status=1; fi
  if have_cmd node; then ok "node present"; else warn "node missing (agent-browser needs it)"; status=1; fi
  if have_cmd agent-browser; then ok "agent-browser present"; else warn "agent-browser missing"; status=1; fi
  if [ -f "$DARK_FACTORY_STAMP" ]; then
    ok "agent-browser browser binaries installed"
  else
    warn "agent-browser browser binaries not installed"; status=1
  fi
  if [ -d "${DARK_FACTORY_DIR}/.git" ]; then
    ok "${DARK_FACTORY_DIR} cloned"
  else
    warn "${DARK_FACTORY_DIR} not cloned"; status=1
  fi
  if [ -d "${CLAUDE_DIR}/skills/drk-01-prd-interview" ]; then
    ok "dark-factory skills synced into ~/.claude/skills"
  else
    warn "dark-factory skills not in ~/.claude/skills"; status=1
  fi
  if [ -d "${CODEX_SKILLS_DIR}/dark-factory-codex" ]; then
    ok "dark-factory skills synced into ~/.codex/skills"
  else
    warn "dark-factory skills not in ~/.codex/skills"; status=1
  fi
  return $status
}

install_dark_factory() {
  log "Component: dark-factory skills + agent-browser"

  # 1. just (apt).
  if have_cmd just; then
    ok "just already installed; skipping"
  else
    $SUDO apt-get update -qq || warn "apt-get update failed; trying the install anyway"
    $SUDO apt-get install -y just || warn "could not apt-install just"
  fi

  # 2. agent-browser (npm global) — needs node.
  if ! have_cmd node; then
    warn "node not found; skipping agent-browser (install Node, then re-run --dark-factory)"
  else
    if have_cmd agent-browser; then
      ok "agent-browser already installed; skipping"
    else
      # A NodeSource/apt Node puts the global prefix under /usr, which the box
      # user cannot write (managed boxes hit this); fall back to sudo.
      if ! npm install -g agent-browser 2>/dev/null; then
        if [ -n "$SUDO" ] || [ "$(id -u)" -eq 0 ]; then
          warn "npm global prefix is not user-writable; installing agent-browser with sudo"
          $SUDO npm install -g agent-browser || warn "could not npm-install agent-browser"
        else
          warn "could not npm-install agent-browser (npm global prefix not writable and no sudo)"
        fi
      fi
    fi
    if have_cmd agent-browser; then
      if [ -f "$DARK_FACTORY_STAMP" ]; then
        ok "agent-browser browser binaries already installed"
      else
        log "Installing the agent-browser Chromium build"
        if agent-browser install --with-deps || agent-browser install; then
          mkdir -p "$(dirname "$DARK_FACTORY_STAMP")"
          date -u +%Y-%m-%dT%H:%M:%SZ > "$DARK_FACTORY_STAMP"
          ok "browser binaries installed"
        else
          warn "agent-browser install failed; re-run --dark-factory once it can reach the network"
        fi
      fi
    fi
  fi

  # 3. The repo itself (public; cloned anonymously over HTTPS).
  if [ -d "${DARK_FACTORY_DIR}/.git" ]; then
    log "Updating ${DARK_FACTORY_DIR}"
    git -C "$DARK_FACTORY_DIR" pull --ff-only \
      || warn "could not fast-forward ${DARK_FACTORY_DIR}; leaving the working copy alone"
  elif [ -e "$DARK_FACTORY_DIR" ]; then
    warn "${DARK_FACTORY_DIR} exists but is not a git checkout; leaving it alone"
  else
    git clone "$DARK_FACTORY_REPO_URL" "$DARK_FACTORY_DIR" \
      || { warn "clone failed: ${DARK_FACTORY_REPO_URL}"; return 0; }
    ok "cloned ${DARK_FACTORY_REPO_URL}"
  fi

  # 4. Populate ~/.claude/skills and ~/.codex/skills from the checkout.
  if [ -x "${DARK_FACTORY_DIR}/scripts/sync-to-global.sh" ]; then
    "${DARK_FACTORY_DIR}/scripts/sync-to-global.sh" \
      || warn "dark-factory sync-to-global.sh failed"
    ok "synced dark-factory skills into ~/.claude/skills and ~/.codex/skills"
  else
    warn "${DARK_FACTORY_DIR}/scripts/sync-to-global.sh not found or not executable"
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
# Component: push notifications  (--notifications)
# ═════════════════════════════════════════════════════════════════════════════
check_notifications() {
  local status=0 s perm
  for s in $NOTIFY_SCRIPTS; do
    if [ -x "${LOCAL_BIN}/${s}" ]; then ok "${s} installed"; else warn "${s} missing"; status=1; fi
  done
  if [ -f "$MOSHI_CONF" ]; then
    ok "${MOSHI_CONF} present"
    perm="$(stat -c '%a' "$MOSHI_CONF" 2>/dev/null || echo '???')"
    [ "$perm" = "600" ] || { warn "${MOSHI_CONF} mode is ${perm}, expected 600"; status=1; }
    grep -q '^MOSHI_WEBHOOK_URL=' "$MOSHI_CONF" || { warn "MOSHI_WEBHOOK_URL not set in ${MOSHI_CONF}"; status=1; }
  else
    warn "${MOSHI_CONF} missing (notifications stay silent without it)"; status=1
  fi
  if have_cmd jq; then ok "jq present (the hook scripts parse their payload with it)"; else warn "jq missing"; status=1; fi
  if [ -f "${HOME}/.notifications-off" ]; then
    warn "~/.notifications-off exists — pushes are muted (run notify-on to unmute)"
  else
    ok "push notifications not muted"
  fi
  return $status
}

install_notifications() {
  log "Component: push notifications"

  local s
  mkdir -p "$LOCAL_BIN"
  for s in $NOTIFY_SCRIPTS; do
    install_managed_file "${NOTIFY_SRC_DIR}/${s}" "${LOCAL_BIN}/${s}" 0755
  done

  have_cmd jq || warn "jq not found; the Claude/Codex hook wrappers need it to read their payload"

  # The webhook endpoint and its token live here, NOT in the scripts, so
  # rotating the credential is an edit of this file rather than a reinstall.
  # On a Spellguard-managed box ~/.config is created by the provisioner as ROOT,
  # so a plain mkdir under it fails for the box user. Take ownership of the
  # parent (not its existing children) with sudo when that happens, then retry.
  if ! mkdir -p "$MOSHI_CONF_DIR" 2>/dev/null; then
    if have_cmd sudo && sudo -n true 2>/dev/null; then
      warn "$(dirname "$MOSHI_CONF_DIR") is not writable; taking ownership with sudo"
      sudo mkdir -p "$MOSHI_CONF_DIR"
      sudo chown "$(id -u):$(id -g)" "$(dirname "$MOSHI_CONF_DIR")" "$MOSHI_CONF_DIR"
    else
      die "cannot create ${MOSHI_CONF_DIR} and passwordless sudo is unavailable. Fix with: sudo chown $(id -un) $(dirname "$MOSHI_CONF_DIR")"
    fi
  fi
  chmod 700 "$MOSHI_CONF_DIR"
  if [ -f "$MOSHI_CONF" ]; then
    chmod 600 "$MOSHI_CONF"
    ok "${MOSHI_CONF} already present; left untouched (mode 0600 enforced)"
  else
    require_env MOSHI_WEBHOOK_URL "The push webhook endpoint the notify scripts POST to."
    install -m 600 /dev/null "$MOSHI_CONF"
    {
      printf '# box-bootstrap push webhook — sourced by ~/.local/bin/notify-moshi.sh.\n'
      printf '# Mode 0600. Rotate by editing this file; no reinstall needed.\n'
      printf 'MOSHI_WEBHOOK_URL=%q\n' "$MOSHI_WEBHOOK_URL"
      printf 'MOSHI_WEBHOOK_TOKEN=%q\n' "${MOSHI_WEBHOOK_TOKEN:-}"
    } > "$MOSHI_CONF"
    ok "wrote ${MOSHI_CONF} (mode 0600)"
  fi

  # notify-codex.sh is installed but ~/.codex/config.toml's `notify` key is
  # deliberately left alone: on a bridge-equipped box the Matrix bridge owns
  # that key and fans out to this script itself.
  ok "notify-codex.sh installed; ~/.codex/config.toml 'notify' left untouched (the bridge owns it)"
}

# ═════════════════════════════════════════════════════════════════════════════
# Component: global agent instructions  (--global-instructions)
# ═════════════════════════════════════════════════════════════════════════════
# Resolve the go-grip browsable base URL used by the File Links section.
resolve_gogrip_base_url() {
  if [ -n "${GOGRIP_BASE_URL:-}" ]; then
    printf '%s' "$GOGRIP_BASE_URL"
    return 0
  fi
  require_env BOX_NAME "This node's hostname in the personal tailnet."
  require_env PERSONAL_TAILNET "Your tailnet's MagicDNS domain, e.g. tailXXXXXX.ts.net. Or set GOGRIP_BASE_URL directly."
  printf 'http://%s.%s:%s' "$BOX_NAME" "$PERSONAL_TAILNET" "$GOGRIP_PORT"
}

check_global_instructions() {
  local status=0
  if [ -f "$CLAUDE_MD" ]; then
    ok "~/.claude/CLAUDE.md present"
    grep -q '@~/.codex/AGENTS.md' "$CLAUDE_MD" || { warn "CLAUDE.md does not import ~/.codex/AGENTS.md"; status=1; }
  else
    warn "~/.claude/CLAUDE.md missing"; status=1
  fi
  if [ -f "$CODEX_AGENTS_MD" ]; then
    ok "~/.codex/AGENTS.md present"
    if grep -q '{{GOGRIP_BASE_URL}}' "$CODEX_AGENTS_MD"; then
      warn "AGENTS.md still holds an unrendered {{GOGRIP_BASE_URL}} placeholder"; status=1
    fi
    if ! grep -q 'codex-orchestration:start' "$CODEX_AGENTS_MD"; then
      warn "AGENTS.md is missing the multi-agent workflow block"; status=1
    fi
  else
    warn "~/.codex/AGENTS.md missing"; status=1
  fi
  return $status
}

install_global_instructions() {
  log "Component: global agent instructions"

  local url shared tmp
  url="$(resolve_gogrip_base_url)"
  shared="${DOTFILES_DIR}/codex/instructions/shared.md"

  # ~/.codex/AGENTS.md — portable core only. Machine-specific context
  # (infrastructure, per-project runbooks, credential locations) stays out.
  tmp="$(mktemp)"
  sed -e "s|{{GOGRIP_BASE_URL}}|${url}|g" \
      -e "/{{CODEX_SHARED_INSTRUCTIONS}}/{
            r ${shared}
            d
          }" \
      "${DOTFILES_DIR}/codex/AGENTS.md.template" > "$tmp"
  install_managed_file "$tmp" "$CODEX_AGENTS_MD" 0644
  rm -f "$tmp"
  ok "File Links section points at ${url}"

  # ~/.claude/CLAUDE.md — harness notes plus the @import of AGENTS.md above.
  install_managed_file "${DOTFILES_DIR}/claude/CLAUDE.md.template" "$CLAUDE_MD" 0644
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
  # Intentionally single-quoted: write the literal line so $PATH expands when
  # ~/.profile is sourced, not now.
  # shellcheck disable=SC2016
  append_profile_once 'export PATH=$PATH:/usr/local/go/bin'
  ok "Go ${ver} installed to /usr/local/go (open a new shell or 'source ~/.profile')"
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

Core components (default: all four run when none are named):
  --tailscale     Second, personal tailscaled (userspace networking)
  --gogrip        go-grip markdown preview user service
  --matrix        Matrix bridge plugin + ccmatrix config
  --neovim        Complete captured Neovim/LazyVim stack

Agent-environment components (opt in individually, or with --agents):
  --agent-config        ~/.claude/settings.json + official Claude plugins
  --codex-config        ~/.codex portable config, agents, skills + plugins
  --shell               Marker-guarded ~/.bashrc block (aliases, PATH, nvm)
  --dark-factory        just, agent-browser, dark-factory skills
  --notifications       ~/.local/bin/notify-*.sh push hooks
  --global-instructions ~/.claude/CLAUDE.md + ~/.codex/AGENTS.md

Optional extras (off unless requested):
  --with-go       Install the Go toolchain (official tarball)
  --with-docker   Install Docker (get.docker.com)
  --with-uv       Install uv (astral.sh installer)

Modifiers:
  --agents        All six agent-environment components
  --all           Core four + agent-environment six + every extra
  --check         Probe selected components and report; change nothing
  -h, --help      Show this help

Secrets come from the environment; see examples/bootstrap.env.example.
EOF
}

DO_TAILSCALE=0; DO_GOGRIP=0; DO_MATRIX=0
DO_GO=0; DO_DOCKER=0; DO_UV=0; DO_NEOVIM=0
DO_AGENT_CONFIG=0; DO_CODEX_CONFIG=0; DO_SHELL=0
DO_DARK_FACTORY=0; DO_NOTIFICATIONS=0; DO_GLOBAL_INSTRUCTIONS=0
CHECK_ONLY=0; SELECTED=0

select_agent_components() {
  DO_AGENT_CONFIG=1; DO_CODEX_CONFIG=1; DO_SHELL=1
  DO_DARK_FACTORY=1; DO_NOTIFICATIONS=1; DO_GLOBAL_INSTRUCTIONS=1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tailscale)   DO_TAILSCALE=1; SELECTED=1 ;;
    --gogrip)      DO_GOGRIP=1; SELECTED=1 ;;
    --matrix)      DO_MATRIX=1; SELECTED=1 ;;
    --neovim)      DO_NEOVIM=1; SELECTED=1 ;;
    --agent-config)        DO_AGENT_CONFIG=1; SELECTED=1 ;;
    --codex-config)        DO_CODEX_CONFIG=1; SELECTED=1 ;;
    --shell)               DO_SHELL=1; SELECTED=1 ;;
    --dark-factory)        DO_DARK_FACTORY=1; SELECTED=1 ;;
    --notifications)       DO_NOTIFICATIONS=1; SELECTED=1 ;;
    --global-instructions) DO_GLOBAL_INSTRUCTIONS=1; SELECTED=1 ;;
    --agents)      select_agent_components; SELECTED=1 ;;
    --with-go)     DO_GO=1 ;;
    --with-docker) DO_DOCKER=1 ;;
    --with-uv)     DO_UV=1 ;;
    # Backward-compatible alias from when Neovim was an optional extra.
    --with-neovim) DO_NEOVIM=1 ;;
    --all)
      DO_TAILSCALE=1; DO_GOGRIP=1; DO_MATRIX=1; DO_NEOVIM=1
      select_agent_components
      DO_GO=1; DO_DOCKER=1; DO_UV=1
      SELECTED=1
      ;;
    --check)       CHECK_ONLY=1 ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

# Default to the four core components when nothing was specifically selected.
# The agent-environment components stay opt-in: they rewrite files a box may
# already have opinions about.
if [ "$SELECTED" -eq 0 ]; then
  DO_TAILSCALE=1; DO_GOGRIP=1; DO_MATRIX=1; DO_NEOVIM=1
fi

main() {
  local rc=0
  if [ "$CHECK_ONLY" -eq 1 ]; then
    log "Probing selected components (no changes will be made)"
    [ "$DO_TAILSCALE" -eq 1 ] && { printf -- '── tailscale ──\n'; check_tailscale || rc=1; }
    [ "$DO_GOGRIP"    -eq 1 ] && { printf -- '── go-grip ──\n';    check_gogrip    || rc=1; }
    [ "$DO_MATRIX"    -eq 1 ] && { printf -- '── matrix ──\n';     check_matrix    || rc=1; }
    [ "$DO_SHELL"     -eq 1 ] && { printf -- '── shell ──\n';      check_shell     || rc=1; }
    [ "$DO_NOTIFICATIONS"      -eq 1 ] && { printf -- '── notifications ──\n';       check_notifications      || rc=1; }
    [ "$DO_AGENT_CONFIG"       -eq 1 ] && { printf -- '── agent-config ──\n';        check_agent_config       || rc=1; }
    [ "$DO_CODEX_CONFIG"       -eq 1 ] && { printf -- '── codex-config ──\n';        check_codex_config       || rc=1; }
    [ "$DO_GLOBAL_INSTRUCTIONS" -eq 1 ] && { printf -- '── global-instructions ──\n'; check_global_instructions || rc=1; }
    [ "$DO_DARK_FACTORY"       -eq 1 ] && { printf -- '── dark-factory ──\n';        check_dark_factory       || rc=1; }
    [ "$DO_GO"        -eq 1 ] && { printf -- '── go ──\n';         check_go        || rc=1; }
    [ "$DO_DOCKER"    -eq 1 ] && { printf -- '── docker ──\n';     check_docker    || rc=1; }
    [ "$DO_UV"        -eq 1 ] && { printf -- '── uv ──\n';         check_uv        || rc=1; }
    [ "$DO_NEOVIM"    -eq 1 ] && { printf -- '── neovim ──\n';     check_neovim    || rc=1; }
    if [ "$rc" -eq 0 ]; then ok "all selected components satisfied"; else warn "some components need install (re-run without --check)"; fi
    return $rc
  fi

  [ "$DO_TAILSCALE" -eq 1 ] && install_tailscale
  [ "$DO_GOGRIP"    -eq 1 ] && install_gogrip
  [ "$DO_MATRIX"    -eq 1 ] && install_matrix
  # Shell first (it puts ~/.local/bin on PATH), then the notifier scripts the
  # Claude hooks point at, then the two agent harnesses.
  [ "$DO_SHELL"          -eq 1 ] && install_shell
  [ "$DO_NOTIFICATIONS"  -eq 1 ] && install_notifications
  [ "$DO_AGENT_CONFIG"   -eq 1 ] && install_agent_config
  [ "$DO_CODEX_CONFIG"   -eq 1 ] && install_codex_config
  [ "$DO_GLOBAL_INSTRUCTIONS" -eq 1 ] && install_global_instructions
  [ "$DO_DARK_FACTORY"   -eq 1 ] && install_dark_factory
  [ "$DO_GO"        -eq 1 ] && install_go
  [ "$DO_DOCKER"    -eq 1 ] && install_docker
  [ "$DO_UV"        -eq 1 ] && install_uv
  [ "$DO_NEOVIM"    -eq 1 ] && install_neovim
  log "Bootstrap complete."
  return 0
}

main

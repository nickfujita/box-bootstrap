# box-bootstrap shell block — vendored from the reference VM's ~/.bashrc.
#
# This file is spliced into ~/.bashrc between the box-bootstrap markers by
# `install.sh --shell`, which renders the double-brace placeholders first.
#
# Deliberately NOT included (both would collide with a managed box):
#   * the tmux auto-attach block — Spellguard-managed boxes append their own,
#     and a second one double-attaches on every SSH/Mosh login;
#   * the go-grip tmux preview line — the --gogrip component's systemd user
#     unit owns starting go-grip.

# ── PATH: user-local binaries (native Claude Code installer target) ──────────
export PATH="$HOME/.local/bin:$PATH"

# ── Coding agents: skip permission prompts (these boxes are already isolated) ─
alias claude='claude --dangerously-skip-permissions'
alias codex='codex --dangerously-bypass-approvals-and-sandbox'

# ── Optional per-box shell secrets (mode 0600, written by install.sh --shell) ─
# Rotating a value here is an edit of this file, not a reinstall.
[ -f "$HOME/.config/box-bootstrap/shell.env" ] && . "$HOME/.config/box-bootstrap/shell.env"

# ── General ──────────────────────────────────────────────────────────────────
mkcd () { mkdir "$1" && cd "$1"; }
r () { source ~/.bashrc; }

# ── Push notification toggle (honoured by ~/.local/bin/notify-*.sh) ──────────
notify-on () { rm -f ~/.notifications-off && echo "Push notifications: ON"; }
notify-off () { touch ~/.notifications-off && echo "Push notifications: OFF"; }
notify-status () { [ -f ~/.notifications-off ] && echo "Push notifications: OFF" || echo "Push notifications: ON"; }

# ── pnpm ─────────────────────────────────────────────────────────────────────
pp () { pnpm "$@"; }
pps () { pnpm start; }
ppd () { pnpm run dev; }
ppi () { pnpm install "$@"; }
ppr () { pnpm run "$@"; }
ppex () { pnpm exec "$@"; }
ppx () { pnpm dlx "$@"; }
npk () { ppx npkill -D -y; }
export COREPACK_ENABLE_AUTO_PIN=false
# Corepack downloads the packageManager-pinned pnpm/yarn on first use; without
# this it stops to ask, which hangs any non-interactive/agent-driven shell.
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0

# ── npm ──────────────────────────────────────────────────────────────────────
ni () { npm i; }
nr () { npm run "$1"; }
ns () { npm start; }
nt () { npm test; }

# ── Git ──────────────────────────────────────────────────────────────────────
gclean () { git clean -dfX; }
gcm () { git add . && git commit -m "$1"; }
gcmn () { git add . && git commit -m "$1" -n; }
gpb () { git push origin "$(git branch --show-current)"; }
gba () { git branch; }
gb () { git rev-parse --abbrev-ref HEAD; }
gbl () { git branch --sort=-committerdate; }
gcf () { git checkout "$1" && git fetch && git pull; }
gp () { git fetch && git pull origin "$(git branch --show-current)"; }
gco () { git checkout "$1"; }
gcob () { git checkout -b "$1"; }
gs () { git status; }
gstash () { git add --all && git stash; }
gmm () { git merge main; }
glog () { git log; }
gbclean () { git branch | grep -v "main" | xargs git branch -D; }

# ── Docker ───────────────────────────────────────────────────────────────────
alias dps="docker ps"
alias dpsa="docker ps -a"
drmfa () { docker rm -f $(docker ps -aq); }
alias dcb="docker-compose build"
alias dcu="docker-compose up"

# ── Node: larger heap for long-running agent CLIs ────────────────────────────
# The 4 GB default aborts the Claude/Codex CLIs in long multi-agent sessions.
# Sized for the box, via NODE_MAX_OLD_SPACE_MB in ~/bootstrap.env.
export NODE_OPTIONS="--max-old-space-size={{NODE_MAX_OLD_SPACE_MB}}"

# ── nvm auto-use: switch Node version on cd when a .nvmrc is present ─────────
cdnvm () {
  builtin cd "$@" || return
  if [ -f .nvmrc ] && command -v nvm >/dev/null 2>&1; then
    local nvm_ver
    local cur_ver
    nvm_ver=$(cat .nvmrc)
    cur_ver=$(nvm current 2>/dev/null)
    if [ "$cur_ver" != "$nvm_ver" ] && [ "$cur_ver" != "v$nvm_ver" ]; then
      nvm use "$nvm_ver" --silent 2>/dev/null || nvm install "$nvm_ver"
    fi
  fi
}
alias cd='cdnvm'

# ── pnpm global bin on PATH ──────────────────────────────────────────────────
export PNPM_HOME="$HOME/.local/share/pnpm"
case ":$PATH:" in
  *":$PNPM_HOME:"*) ;;
  *) export PATH="$PNPM_HOME:$PATH" ;;
esac
# pnpm end

# ── Go toolchain + go-installed binaries ─────────────────────────────────────
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin

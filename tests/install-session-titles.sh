#!/usr/bin/env bash
#
# --session-titles: converges the wrapper, unit, tmux block and Codex key into
# a throwaway HOME, replaces the plugin installer's legacy tmux block, is a
# no-op on a second run, passes its own --check, and installs everything but
# the service when the plugin is absent. systemd, tmux, uv and sudo are stubs.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/box-bootstrap-session-titles-test.XXXXXX)"
trap 'rm -r "$TEST_DIR"' EXIT

systemctl() { return 0; }
sudo() { return 0; }
loginctl() { return 0; }
uv() { printf '%s\n' "$*" >> "$SESSION_TITLES_TEST_UV"; }
# Without SESSION_TITLES_TEST_TMUX there is no tmux server, so the installer
# must neither reload nor adopt windows. With it, act as a server that has one
# manually named claude window, one already-automatic codex window and a shell,
# and log every set-option call to that file.
tmux() {
  [ -n "${SESSION_TITLES_TEST_TMUX:-}" ] || return 1
  case "$1" in
    list-windows) printf '%s\n' '@1 claude 0 my old name' '@2 bash 0 shell' '@3 codex 1 Already automatic' ;;
    set-option)   printf '%s\n' "$*" >> "$SESSION_TITLES_TEST_TMUX" ;;
  esac
  return 0
}
export -f systemctl sudo loginctl uv tmux

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

make_home() {
  local home="$1" plugin="$2"
  mkdir -p "$home/.codex" "$home/.claude/plugins"
  cp "$ROOT_DIR/examples/tmux.conf.local.example" "$home/.tmux.conf.local"
  cat >> "$home/.tmux.conf.local" <<'EOF'

# session-titles:start
set -gw automatic-rename on
set -g status-right 'stale legacy block'
# session-titles:end
EOF
  printf 'model = "gpt-5.6-sol"\n\n[tui]\ntheme = "dark"\n' > "$home/.codex/config.toml"
  chmod 600 "$home/.codex/config.toml"
  printf '## Session titles\n\nrun `session-title set "New title"`.\n' > "$home/.codex/AGENTS.md"
  if [ -n "$plugin" ]; then
    mkdir -p "$plugin"
    cat > "$home/.claude/plugins/installed_plugins.json" <<EOF
{"plugins": {"claude-code-matrix@claude-code-matrix": [{"installPath": "${plugin}", "version": "0.6.0"}]}}
EOF
  fi
}

run_install() {
  local home="$1"; shift
  HOME="$home" USER=dev SESSION_TITLES_TEST_UV="$home/uv.log" \
    bash "$ROOT_DIR/install.sh" --session-titles "$@" >"$home/install.log" 2>&1 \
    || { cat "$home/install.log" >&2; fail "install.sh --session-titles $* exited non-zero"; }
}

# ── Fresh install with the plugin present ───────────────────────────────────
home="$TEST_DIR/fresh/home"
plugin="$TEST_DIR/fresh/plugin/0.6.0"
make_home "$home" "$plugin"
run_install "$home"

[ -x "$home/.local/bin/session-title" ] || fail "wrapper not installed"
cmp -s "$ROOT_DIR/scripts/session-title" "$home/.local/bin/session-title" || fail "wrapper differs from the vendored copy"
cmp -s "$ROOT_DIR/units/session-titles.service" "$home/.config/systemd/user/session-titles.service" || fail "unit not installed"
grep -qF -- "sync --quiet --all-packages --project ${plugin}" "$home/uv.log" || fail "plugin environment was not built"

conf="$home/.tmux.conf.local"
grep -qF '# >>> box-bootstrap session-titles block >>>' "$conf" || fail "tmux block missing"
grep -qF 'stale legacy block' "$conf" && fail "legacy tmux block survived"
grep -qF '# session-titles:start' "$conf" && fail "legacy markers survived"
grep -qF 'set -g history-limit 50000' "$conf" || fail "content outside the markers was lost"
[ "$(grep -c 'automatic-rename-format' "$conf")" -eq 1 ] || fail "tmux block present more than once"

toml="$home/.codex/config.toml"
grep -qF 'terminal_title = ["thread"]' "$toml" || fail "Codex terminal_title not merged"
grep -qF 'theme = "dark"' "$toml" || fail "existing [tui] key was lost"
[ "$(grep -c '^\[tui\]' "$toml")" -eq 1 ] || fail "[tui] table duplicated"
[ "$(stat -c '%a' "$toml")" = "600" ] || fail "config.toml lost its 0600 mode"

# ── Second run: nothing changes, no new backups ─────────────────────────────
snapshot="$TEST_DIR/fresh/snapshot"
mkdir -p "$snapshot"
cp "$conf" "$snapshot/tmux.conf.local"
cp "$toml" "$snapshot/config.toml"
run_install "$home"
cmp -s "$conf" "$snapshot/tmux.conf.local" || fail "second run rewrote ~/.tmux.conf.local"
cmp -s "$toml" "$snapshot/config.toml" || fail "second run rewrote ~/.codex/config.toml"
# Removing the legacy block backs the file up; appending the new block is
# non-destructive and does not. The second run adds nothing.
[ "$(ls "$home"/.tmux.conf.local.pre-box-bootstrap-* 2>/dev/null | wc -l)" -eq 1 ] \
  || fail "expected exactly one tmux backup (legacy removal), got: $(ls "$home"/.tmux.conf.local.pre-box-bootstrap-* 2>/dev/null)"

# ── --check agrees ──────────────────────────────────────────────────────────
run_install "$home" --check

# ── Existing agent windows are adopted once ─────────────────────────────────
home="$TEST_DIR/adopt/home"
plugin="$TEST_DIR/adopt/plugin/0.6.0"
make_home "$home" "$plugin"
SESSION_TITLES_TEST_TMUX="$home/tmux.log" run_install "$home"
[ "$(cat "$home/tmux.log")" = "set-option -w -t @1 automatic-rename on" ] \
  || fail "expected exactly the manually named claude window to be adopted, got: $(cat "$home/tmux.log")"
[ -f "$home/.cache/box-bootstrap/session-titles-windows-adopted" ] || fail "adoption stamp missing"
grep -qF '@1 claude 0 my old name' "$home"/.cache/box-bootstrap/tmux-windows-before-titles-*.txt || fail "previous window names not recorded"
SESSION_TITLES_TEST_TMUX="$home/tmux.log" run_install "$home"
[ "$(wc -l < "$home/tmux.log")" -eq 1 ] || fail "second run adopted windows again"

# ── Without the plugin: box settings land, the service does not ─────────────
home="$TEST_DIR/noplugin/home"
make_home "$home" ""
run_install "$home"
[ -x "$home/.local/bin/session-title" ] || fail "wrapper not installed without the plugin"
grep -qF '# >>> box-bootstrap session-titles block >>>' "$home/.tmux.conf.local" || fail "tmux block missing without the plugin"
[ -e "$home/.config/systemd/user/session-titles.service" ] && fail "unit installed although the plugin is absent"
grep -qF 'skipping the service' "$home/install.log" || fail "missing-plugin warning not printed"

printf 'session-titles install tests passed\n'

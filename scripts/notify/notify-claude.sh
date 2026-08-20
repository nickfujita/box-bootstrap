#!/usr/bin/env bash
#
# Claude Code `Stop` hook — announce that a turn finished.
# Wired up by install.sh --agent-config; reads the hook payload on stdin.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INPUT="$(cat)"
STOP_HOOK_ACTIVE="$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)"
PROJECT="$(basename "$CWD" 2>/dev/null)"
HOST="$(hostname -s)"

# Log every stop event so a missing notification can be told apart from a
# notification that was sent but never arrived.
LOG="$HOME/.notify-claude.log"
echo "$(date '+%Y-%m-%d %H:%M:%S') [stop] stop_hook_active=${STOP_HOOK_ACTIVE} project=${PROJECT:-unknown}" >> "$LOG"

# Already inside a stop hook: do not re-notify.
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

"${SCRIPT_DIR}/notify-moshi.sh" "Claude | ${HOST}" "${PROJECT:-unknown} — task complete"
exit 0

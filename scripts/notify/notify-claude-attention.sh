#!/usr/bin/env bash
#
# Claude Code `Notification` hook — announce that the session wants input.
# Wired up by install.sh --agent-config; reads the hook payload on stdin.
#
# Notification events fire far more often than Stop events, so this one rate
# limits itself to at most one push per COOLDOWN_SECONDS.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COOLDOWN_SECONDS="${NOTIFY_ATTENTION_COOLDOWN:-60}"

INPUT="$(cat)"
NOTIFICATION_TYPE="$(printf '%s' "$INPUT" | jq -r '.notification_type // "unknown"' 2>/dev/null)"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)"
PROJECT="$(basename "$CWD" 2>/dev/null)"
HOST="$(hostname -s)"

LOG="$HOME/.notify-claude.log"
echo "$(date '+%Y-%m-%d %H:%M:%S') [attention] type=${NOTIFICATION_TYPE} project=${PROJECT:-unknown}" >> "$LOG"

COOLDOWN_FILE="$HOME/.notify-claude-last"
NOW="$(date +%s)"
if [ -f "$COOLDOWN_FILE" ]; then
  LAST="$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)"
  ELAPSED=$(( NOW - LAST ))
  if [ "$ELAPSED" -lt "$COOLDOWN_SECONDS" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [attention] SKIPPED (cooldown ${ELAPSED}s < ${COOLDOWN_SECONDS}s)" >> "$LOG"
    exit 0
  fi
fi
echo "$NOW" > "$COOLDOWN_FILE"

"${SCRIPT_DIR}/notify-moshi.sh" "Claude | ${HOST}" "${PROJECT:-unknown} — needs your input"
exit 0

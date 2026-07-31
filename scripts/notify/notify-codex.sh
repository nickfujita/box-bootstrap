#!/usr/bin/env bash
#
# Codex `notify` handler — announce that an agent turn finished.
# Codex passes the event as a single JSON argument.
#
# NOTE: install.sh deliberately does NOT point ~/.codex/config.toml's `notify`
# key at this script. On a bridge-equipped box the Matrix bridge installs its
# own wrapper as the single `notify` command and fans out to this script plus
# the bridge handler — pointing `notify` here directly would replace the bridge
# handler and silently break phone routing. Wire it up by hand only on a box
# with no bridge:
#
#     notify = ["<home>/.local/bin/notify-codex.sh"]

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

JSON="${1:-}"
[ -n "$JSON" ] || JSON='{}'
TYPE="$(printf '%s' "$JSON" | jq -r '.type // "unknown"' 2>/dev/null)"

if [ "$TYPE" = "agent-turn-complete" ]; then
  CWD="$(printf '%s' "$JSON" | jq -r '.cwd // ""' 2>/dev/null)"
  PROJECT="$(basename "$CWD" 2>/dev/null)"
  HOST="$(hostname -s)"
  "${SCRIPT_DIR}/notify-moshi.sh" "Codex | ${HOST}" "${PROJECT:-unknown} — task complete"
fi

exit 0

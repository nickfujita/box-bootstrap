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

# Suppress the notification for threads that are not the human's turn ending.
#
# Codex fires `notify` once per agent thread, and with `[agents] enabled` a
# single prompt fans out to max_concurrent_threads_per_session workers — so one
# human turn produced up to 7 pushes. Measured on a real box: 53 of the last 60
# notify events were background subagent threads (88%).
#
# `type` is NOT a usable filter — codex-cli emits exactly `agent-turn-complete`
# (1179 of 1180 logged events), so the check below passes for subagents too.
# The payload also carries no thread_source (0 of 1180), so the origin has to be
# read from the session rollout header, which is what the Matrix bridge does in
# codex_matrix/notify_handler.py -> transcript.is_unmirrored_session().
#
# Fails OPEN: if the rollout cannot be found or parsed we notify, so a lookup
# failure never silently swallows a real turn-complete.
codex_thread_is_internal() {
  local json="$1" thread_id rollout meta src parent client

  client="$(printf '%s' "$json" | jq -r '.client // ""' 2>/dev/null)"
  [ "$client" = "codex_exec" ] && return 0

  thread_id="$(printf '%s' "$json" | jq -r '.["thread-id"] // ""' 2>/dev/null)"
  [ -n "$thread_id" ] || return 1

  rollout="$(ls -1 "${CODEX_SESSIONS_DIR:-$HOME/.codex/sessions}"/*/*/*/rollout-*"${thread_id}".jsonl 2>/dev/null | head -1)"
  [ -n "$rollout" ] || return 1

  meta="$(head -1 "$rollout" 2>/dev/null)"
  [ -n "$meta" ] || return 1

  # thread_source lives under .payload in the session_meta line. It is a STRING
  # for top-level threads but a dict on some subagent rows, so filter by type.
  src="$(printf '%s' "$meta" | jq -r '
    (.thread_source // .payload.thread_source) as $s
    | if ($s | type) == "string" then $s else "" end' 2>/dev/null)"
  case "$src" in subagent | background) return 0 ;; esac

  parent="$(printf '%s' "$meta" | jq -r '(.parent_thread_id // .payload.parent_thread_id) // ""' 2>/dev/null)"
  [ -n "$parent" ] && return 0

  return 1
}

if [ "$TYPE" = "agent-turn-complete" ] && ! codex_thread_is_internal "$JSON"; then
  CWD="$(printf '%s' "$JSON" | jq -r '.cwd // ""' 2>/dev/null)"
  PROJECT="$(basename "$CWD" 2>/dev/null)"
  HOST="$(hostname -s)"
  "${SCRIPT_DIR}/notify-moshi.sh" "Codex | ${HOST}" "${PROJECT:-unknown} — task complete"
fi

exit 0

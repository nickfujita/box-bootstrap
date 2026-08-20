#!/usr/bin/env bash
#
# Push a notification through the Moshi webhook.
#
#   notify-moshi.sh [TITLE] [MESSAGE]
#
# The endpoint and its token live OUTSIDE this script, in
#
#     ~/.config/moshi/webhook.env      (mode 0600)
#
# so rotating the credential is an edit of that file, never a reinstall.
# Point $MOSHI_WEBHOOK_ENV somewhere else to override the location.
#
# Silence: `touch ~/.notifications-off` (or the notify-off shell function).
# Never fails loudly — this runs as an agent hook and must not break a turn.

set -u

# Global mute switch (toggled by notify-on / notify-off).
if [ -f "$HOME/.notifications-off" ]; then
  exit 0
fi

CONF="${MOSHI_WEBHOOK_ENV:-$HOME/.config/moshi/webhook.env}"
if [ -r "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
fi

URL="${MOSHI_WEBHOOK_URL:-}"
TOKEN="${MOSHI_WEBHOOK_TOKEN:-}"

# Not configured on this box: stay silent rather than erroring inside a hook.
[ -n "$URL" ] || exit 0

TITLE="${1:-Task Complete}"
MESSAGE="${2:-Your task finished!}"

if command -v jq >/dev/null 2>&1; then
  PAYLOAD="$(jq -nc \
    --arg token "$TOKEN" \
    --arg title "$TITLE" \
    --arg message "$MESSAGE" \
    '{token: $token, title: $title, message: $message}')"
else
  # Fallback JSON writer: escape backslashes and double quotes only.
  json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  PAYLOAD="{\"token\": \"$(json_escape "$TOKEN")\", \"title\": \"$(json_escape "$TITLE")\", \"message\": \"$(json_escape "$MESSAGE")\"}"
fi

curl -s -m 10 -X POST "$URL" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  >/dev/null 2>&1

exit 0

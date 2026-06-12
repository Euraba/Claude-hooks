#!/usr/bin/env bash
# Back-compat wrapper around lobby_stop_release (lib.sh). The Stop hook of
# record is stop-gate.sh, which performs the release itself only when it
# actually lets the session stop — wire THAT in settings.json, not this.
# Kept so older hand-wired settings keep working for role-less sessions.
. "$(dirname "$0")/lib.sh"

[[ -z "${CLAUDE_PROJECT_DIR:-}" ]] && exit 0
[[ -f "$LOBBY_FILE" ]] || exit 0
input=$(cat)
session_id=$(jq -r '.session_id // empty' <<<"$input")
[[ -z "$session_id" ]] && exit 0

lobby_stop_release "$session_id"
exit 0

#!/usr/bin/env bash
# Stop hook: end of turn — release this session's claims so other sessions
# can edit those files immediately. Session entry itself stays (heartbeat
# refreshed) until SessionEnd or stale-prune.
. "$(dirname "$0")/lib.sh"

[[ -z "${CLAUDE_PROJECT_DIR:-}" ]] && exit 0
[[ -f "$LOBBY_FILE" ]] || exit 0
input=$(cat)
session_id=$(jq -r '.session_id // empty' <<<"$input")
[[ -z "$session_id" ]] && exit 0

now=$(date +%s)
now_iso=$(date -Iseconds)

(
  flock 200
  lobby_write '
    .sessions |= map(
      if .session_id == $sid
      then .claims = []
           | .last_seen = $now_iso
           | .last_seen_epoch = ($now | tonumber)
      else . end
    )
  ' --arg sid "$session_id" --argjson now "$now" --arg now_iso "$now_iso"
) 200>"$LOBBY_LOCK"

exit 0

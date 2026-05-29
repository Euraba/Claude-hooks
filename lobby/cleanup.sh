#!/usr/bin/env bash
# SessionEnd hook: remove this session's entry from the lobby. If the session
# was in a room, that room's file is also deleted if no other members remain.
. "$(dirname "$0")/lib.sh"

[[ -z "${CLAUDE_PROJECT_DIR:-}" ]] && exit 0
[[ -f "$LOBBY_FILE" ]] || exit 0
input=$(cat)
session_id=$(jq -r '.session_id // empty' <<<"$input")
[[ -z "$session_id" ]] && exit 0

ROOMS_DIR="$LOBBY_DIR/rooms"

(
  flock 200
  # Snapshot the leaving session's room id (if any) before removing the entry.
  leaving_room=$(jq -r --arg sid "$session_id" '
    .sessions[] | select(.session_id == $sid) | .room_id // ""
  ' "$LOBBY_FILE")

  lobby_write '.sessions |= map(select(.session_id != $sid))' --arg sid "$session_id"

  if [[ -n "$leaving_room" ]]; then
    members=$(jq -r --arg room "$leaving_room" '[.sessions[] | select(.room_id == $room)] | length' "$LOBBY_FILE")
    if [[ "$members" -eq 0 ]]; then
      rm -f "$ROOMS_DIR/$leaving_room.jsonl" "$ROOMS_DIR/$leaving_room.jsonl.lock"
    fi
  fi
) 200>"$LOBBY_LOCK"

exit 0

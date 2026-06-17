#!/usr/bin/env bash
# SessionEnd hook: remove this session's entry from the lobby. If the session
# was in a room, that room's file is also deleted if no other members remain.
. "$(dirname "$0")/lib.sh"

# Fall back to the git-root anchor when launched without CLAUDE_PROJECT_DIR set.
[[ -z "${CLAUDE_PROJECT_DIR:-}" ]] && CLAUDE_PROJECT_DIR="${LOBBY_ANCHOR:-}"
export CLAUDE_PROJECT_DIR
[[ -z "${CLAUDE_PROJECT_DIR:-}" ]] && exit 0
[[ -f "$LOBBY_FILE" ]] || exit 0
input=$(cat)
session_id=$(jq -r '.session_id // empty' <<<"$input")
[[ -z "$session_id" ]] && exit 0

ROOMS_DIR="$LOBBY_DIR/rooms"
now_iso=$(date -Iseconds)

anchors=$(
  (
    flock -w 5 200 || exit 0
    # Snapshot the leaving session's room id, role links and foreign anchors
    # before removing the entry. Anchors are printed for the release loop below.
    leaving_room=$(jq -r --arg sid "$session_id" '
      .sessions[] | select(.session_id == $sid) | .room_id // ""
    ' "$LOBBY_FILE")
    leaving_role=$(jq -r --arg sid "$session_id" '
      .sessions[] | select(.session_id == $sid) | .role // ""
    ' "$LOBBY_FILE")
    leaving_main=$(jq -r --arg sid "$session_id" '
      .sessions[] | select(.session_id == $sid) | .main_sid // ""
    ' "$LOBBY_FILE")
    jq -r --arg sid "$session_id" '
      (.sessions[]? | select(.session_id == $sid) | .anchors // []) | .[]
    ' "$LOBBY_FILE"

    lobby_write "$LOBBY_JQ_DEFS"'
      ((.sessions[] | select(.session_id == $sid) | .claims) // []) as $freed
      | .sessions |= map(select(.session_id != $sid))
      | notify_waiters($freed; "(its holder session ended)"; $ts)
      | .waiters = ((.waiters // []) | map(select(.sid != $sid)))
    ' --arg sid "$session_id" --arg ts "$now_iso"

    if [[ "$leaving_role" == "main" && -n "$leaving_room" ]]; then
      # Waiting reviewers see this on their next wait cycle; their MAIN_GONE
      # check then releases them.
      append_room_line "$leaving_room" "$(jq -nc --arg ts "$now_iso" --arg s "${session_id:0:8}" \
        '{system: true, text: ("main " + $s + " ended"), ts: $ts}')"
    elif [[ "$leaving_role" == "reviewer" && -n "$leaving_main" ]]; then
      # If the departing reviewer held the review turn, advance/finalize past it.
      review_self_heal "$leaving_main"
    fi

    if [[ -n "$leaving_room" ]]; then
      members=$(jq -r --arg room "$leaving_room" '[.sessions[] | select(.room_id == $room)] | length' "$LOBBY_FILE")
      if [[ "$members" -eq 0 ]]; then
        rm -f "$ROOMS_DIR/$leaving_room.jsonl" "$ROOMS_DIR/$leaving_room.jsonl.lock"
      fi
    fi
  ) 200>"$LOBBY_LOCK"
)

# Remove this session from any foreign-repo lobbies it claimed files in.
while IFS= read -r anchor; do
  [[ -n "$anchor" ]] && lobby_release_anchor "$session_id" "$anchor" remove
done <<<"$anchors"

exit 0

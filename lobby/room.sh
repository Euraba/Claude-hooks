#!/usr/bin/env bash
# Private chat rooms between Claude sessions.
#
# A "room" is an append-only jsonl file under <repo>/.claude/rooms/.
# Membership is recorded as `room_id` on each session entry in lobby.json
# (plus `room_cursor`, the count of lines already delivered to that session).
# Delivery happens via inject.sh (UserPromptSubmit) and post-edit-inbox.sh
# (PostToolUse on Edit/Write/MultiEdit/NotebookEdit) so each side sees the
# other's new lines after their next edit or next user prompt.
#
# Usage:
#   room.sh invite --from <sid> --to <sid> [--topic <text>]
#   room.sh accept --session <sid> --room <room_id>
#   room.sh say    --session <sid> --text "<message>"
#   room.sh leave  --session <sid>
#   room.sh show   --session <sid>     # transcript of session's current room
#   room.sh show   --room    <room_id>
#   room.sh list
. "$(dirname "$0")/lib.sh"

ROOMS_DIR="$LOBBY_DIR/rooms"
INBOX_TOOL="$(dirname "$0")/btw.sh"

cmd="${1:-}"
[[ $# -gt 0 ]] && shift

from=""; to=""; topic=""; session_id=""; room_id=""; text=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)    from="${2:-}";       shift 2 ;;
    --to)      to="${2:-}";         shift 2 ;;
    --topic)   topic="${2:-}";      shift 2 ;;
    --session) session_id="${2:-}"; shift 2 ;;
    --room)    room_id="${2:-}";    shift 2 ;;
    --text)    text="${2:-}";       shift 2 ;;
    *) echo "room.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

lobby_init
mkdir -p "$ROOMS_DIR"

resolve_sid() {
  local needle="$1"
  jq -r --arg n "$needle" '
    .sessions | map(.session_id) as $ids
    | ($ids | map(select(. == $n))) as $exact
    | if ($exact | length) == 1 then $exact[0]
      else
        ($ids | map(select(startswith($n)))) as $pref
        | if ($pref | length) == 1 then $pref[0] else "" end
      end
  ' "$LOBBY_FILE"
}

session_room() {
  jq -r --arg sid "$1" '
    .sessions[] | select(.session_id == $sid) | .room_id // ""
  ' "$LOBBY_FILE"
}

append_room_line() {
  local room="$1"; local payload="$2"
  local f="$ROOMS_DIR/$room.jsonl"
  (
    flock 201
    printf '%s\n' "$payload" >> "$f"
  ) 201>"$f.lock"
}

case "$cmd" in
  invite)
    [[ -z "$from" || -z "$to" ]] && { echo "room.sh invite: need --from and --to" >&2; exit 2; }
    from_full=$(resolve_sid "$from"); [[ -z "$from_full" ]] && { echo "room.sh invite: --from did not match" >&2; exit 2; }
    to_full=$(resolve_sid "$to");     [[ -z "$to_full"   ]] && { echo "room.sh invite: --to did not match"   >&2; exit 2; }
    [[ "$from_full" == "$to_full" ]] && { echo "room.sh invite: cannot invite self" >&2; exit 2; }

    existing=$(session_room "$from_full")
    [[ -n "$existing" ]] && { echo "room.sh invite: --from is already in room $existing; /room leave first" >&2; exit 2; }

    room_id="r-$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    now_iso=$(date -Iseconds); now=$(date +%s)
    from_short="${from_full:0:8}"
    to_short="${to_full:0:8}"

    # Initialize room file with a system line.
    : > "$ROOMS_DIR/$room_id.jsonl"
    append_room_line "$room_id" "$(jq -nc \
      --arg ts "$now_iso" --arg from "$from_short" --arg to "$to_short" --arg topic "$topic" \
      '{system: true, text: ("room opened by " + $from + ", invited " + $to + (if $topic == "" then "" else " (topic: " + $topic + ")" end)), ts: $ts}')"

    # Set inviter's room_id and cursor=1 (they've already "seen" the open line).
    (
      flock 200
      lobby_prune
      lobby_write '
        .sessions |= map(
          if .session_id == $sid
          then .room_id = $room
             | .room_cursor = 1
             | .last_seen = $now_iso
             | .last_seen_epoch = ($now | tonumber)
          else . end
        )
      ' --arg sid "$from_full" --arg room "$room_id" --arg now_iso "$now_iso" --argjson now "$now"
    ) 200>"$LOBBY_LOCK"

    # Notify invitee via inbox.
    invite_msg="[ROOM INVITE] ${from_short} invites you to room ${room_id}"
    [[ -n "$topic" ]] && invite_msg="${invite_msg} (topic: ${topic})"
    invite_msg="${invite_msg}. Run /room accept ${room_id} to join, or ignore."
    "$INBOX_TOOL" send --from "$from_full" --to "$to_full" --text "$invite_msg"

    echo "$room_id"
    ;;

  accept)
    [[ -z "$session_id" || -z "$room_id" ]] && { echo "room.sh accept: need --session and --room" >&2; exit 2; }
    sid_full=$(resolve_sid "$session_id"); [[ -z "$sid_full" ]] && { echo "room.sh accept: --session did not match" >&2; exit 2; }
    [[ -f "$ROOMS_DIR/$room_id.jsonl" ]] || { echo "room.sh accept: room $room_id does not exist" >&2; exit 2; }

    existing=$(session_room "$sid_full")
    [[ -n "$existing" ]] && { echo "room.sh accept: already in room $existing; /room leave first" >&2; exit 2; }

    now_iso=$(date -Iseconds); now=$(date +%s)
    short="${sid_full:0:8}"
    append_room_line "$room_id" "$(jq -nc --arg ts "$now_iso" --arg s "$short" '{system: true, text: ($s + " joined"), ts: $ts}')"

    # Set room_id; cursor=0 so the invitee sees the opening line + topic.
    (
      flock 200
      lobby_write '
        .sessions |= map(
          if .session_id == $sid
          then .room_id = $room
             | .room_cursor = 0
             | .last_seen = $now_iso
             | .last_seen_epoch = ($now | tonumber)
          else . end
        )
      ' --arg sid "$sid_full" --arg room "$room_id" --arg now_iso "$now_iso" --argjson now "$now"
    ) 200>"$LOBBY_LOCK"

    echo "joined $room_id"
    ;;

  say)
    [[ -z "$session_id" || -z "$text" ]] && { echo "room.sh say: need --session and --text" >&2; exit 2; }
    sid_full=$(resolve_sid "$session_id"); [[ -z "$sid_full" ]] && { echo "room.sh say: --session did not match" >&2; exit 2; }
    room=$(session_room "$sid_full"); [[ -z "$room" ]] && { echo "room.sh say: not in a room" >&2; exit 2; }

    now_iso=$(date -Iseconds); short="${sid_full:0:8}"
    append_room_line "$room" "$(jq -nc \
      --arg from_short "$short" --arg from_full "$sid_full" --arg text "$text" --arg ts "$now_iso" \
      '{from_short: $from_short, from_full: $from_full, text: $text, ts: $ts}')"
    # Refresh sender's cursor so they don't see their own line as "new".
    lines=$(wc -l < "$ROOMS_DIR/$room.jsonl")
    (
      flock 200
      lobby_write '
        .sessions |= map(
          if .session_id == $sid then .room_cursor = ($n | tonumber) else . end
        )
      ' --arg sid "$sid_full" --argjson n "$lines"
    ) 200>"$LOBBY_LOCK"
    ;;

  leave)
    [[ -z "$session_id" ]] && { echo "room.sh leave: need --session" >&2; exit 2; }
    sid_full=$(resolve_sid "$session_id"); [[ -z "$sid_full" ]] && { echo "room.sh leave: --session did not match" >&2; exit 2; }
    room=$(session_room "$sid_full"); [[ -z "$room" ]] && { echo "room.sh leave: not in a room" >&2; exit 2; }

    now_iso=$(date -Iseconds); short="${sid_full:0:8}"
    append_room_line "$room" "$(jq -nc --arg ts "$now_iso" --arg s "$short" '{system: true, text: ($s + " left"), ts: $ts}')"

    (
      flock 200
      lobby_write '
        .sessions |= map(
          if .session_id == $sid then .room_id = null | .room_cursor = 0 else . end
        )
      ' --arg sid "$sid_full"
    ) 200>"$LOBBY_LOCK"

    # If no other session is still in this room, delete the file.
    members=$(jq -r --arg room "$room" '[.sessions[] | select(.room_id == $room)] | length' "$LOBBY_FILE")
    if [[ "$members" -eq 0 ]]; then
      rm -f "$ROOMS_DIR/$room.jsonl" "$ROOMS_DIR/$room.jsonl.lock"
    fi
    echo "left $room"
    ;;

  show)
    if [[ -n "$session_id" ]]; then
      sid_full=$(resolve_sid "$session_id"); [[ -z "$sid_full" ]] && { echo "room.sh show: --session did not match" >&2; exit 2; }
      room=$(session_room "$sid_full"); [[ -z "$room" ]] && { echo "room.sh show: session not in a room" >&2; exit 2; }
      room_id="$room"
    fi
    [[ -z "$room_id" ]] && { echo "room.sh show: need --session or --room" >&2; exit 2; }
    [[ -f "$ROOMS_DIR/$room_id.jsonl" ]] || { echo "room.sh show: room $room_id has no transcript" >&2; exit 2; }
    jq -r '
      if .system == true then "[system " + .ts + "] " + .text
      else "[" + .ts + "] " + .from_short + ": " + .text end
    ' "$ROOMS_DIR/$room_id.jsonl"
    ;;

  list)
    jq -r '
      .sessions
      | map(select((.room_id // "") != ""))
      | group_by(.room_id)
      | map(. as $g | "room " + $g[0].room_id + ": " + (map(.session_id[0:8]) | join(", ")))
      | if length == 0 then "(no active rooms)" else join("\n") end
    ' "$LOBBY_FILE"
    ;;

  ""|-h|--help|help)
    cat >&2 <<'EOF'
Usage:
  room.sh invite --from <sid> --to <sid> [--topic <text>]
  room.sh accept --session <sid> --room <room_id>
  room.sh say    --session <sid> --text "<message>"
  room.sh leave  --session <sid>
  room.sh show   (--session <sid> | --room <room_id>)
  room.sh list
EOF
    exit 2
    ;;

  *)
    echo "room.sh: unknown command: $cmd" >&2
    exit 2
    ;;
esac

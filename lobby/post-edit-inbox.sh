#!/usr/bin/env bash
# PostToolUse hook for Edit|Write|MultiEdit|NotebookEdit:
# After each file edit, deliver any inbox messages that haven't been shown
# to this session yet. Marks them `delivered_at = now` so they aren't
# re-injected on every subsequent edit. Messages remain in the inbox until
# the session runs `btw.sh ack` (so they also show again at the next
# UserPromptSubmit, which serves as a turn-boundary reminder).
. "$(dirname "$0")/lib.sh"

if [[ -z "${CLAUDE_PROJECT_DIR:-}" ]]; then
  echo '{}'
  exit 0
fi

input=$(cat)
session_id=$(jq -r '.session_id // empty' <<<"$input")
if [[ -z "$session_id" ]]; then
  echo '{}'
  exit 0
fi

# If lobby file doesn't exist yet (session never claimed anything), nothing to do.
[[ -f "$LOBBY_FILE" ]] || { echo '{}'; exit 0; }

now_iso=$(date -Iseconds)
now=$(date +%s)

context=$(
  (
    # Fail open on lock contention: skip delivery rather than stall the edit.
    flock -w 5 200 || exit 0
    lobby_prune

    # Pull undelivered messages for this session, render them, then mark delivered.
    undelivered=$(jq -r --arg sid "$session_id" --arg bin "$LOBBY_BIN" '
      ((.sessions[] | select(.session_id == $sid) | .inbox) // [])
      | map(select((.delivered_at // null) == null))
      | if length == 0 then ""
        else
          "[INBOX] New messages arrived from other Claude sessions while you were working. Address them or run `" + $bin + "/btw.sh ack --session " + $sid + "` after handling:\n" +
          (map("  - from " + .from_short + " at " + .sent_at + ": " + .text) | join("\n"))
        end
    ' "$LOBBY_FILE")

    if [[ -n "$undelivered" ]]; then
      lobby_write '
        .sessions |= map(
          if .session_id == $sid
          then .inbox = ((.inbox // []) | map(
                 if (.delivered_at // null) == null
                 then .delivered_at = $now_iso
                 else . end
               ))
               | .last_seen = $now_iso
               | .last_seen_epoch = ($now | tonumber)
          else . end
        )
      ' --arg sid "$session_id" --arg now_iso "$now_iso" --argjson now "$now"
    fi
    room_new=$(room_deliver_new "$session_id")
    if [[ -n "$undelivered" && -n "$room_new" ]]; then
      printf '%s\n%s' "$undelivered" "$room_new"
    elif [[ -n "$undelivered" ]]; then
      printf '%s' "$undelivered"
    else
      printf '%s' "$room_new"
    fi
  ) 200>"$LOBBY_LOCK"
)

if [[ -n "$context" ]]; then
  jq -nc --arg ctx "$context" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: $ctx
    }
  }'
else
  echo '{}'
fi
exit 0

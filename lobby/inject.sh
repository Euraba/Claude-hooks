#!/usr/bin/env bash
# UserPromptSubmit hook: refresh own heartbeat, inject other sessions' claims into context.
. "$(dirname "$0")/lib.sh"

if [[ -z "${CLAUDE_PROJECT_DIR:-}" ]]; then
  echo '{}'
  exit 0
fi

input=$(cat)
session_id=$(jq -r '.session_id // empty' <<<"$input")

lobby_init
now=$(date +%s)
now_iso=$(date -Iseconds)

context=$(
  (
    # Fail open on lock contention: inject nothing rather than stall the turn.
    flock -w 5 200 || exit 0
    lobby_prune
    # New turn: refresh own heartbeat AND clear this session's claims.
    # Claims represent "actively working on it this turn", not session-lifetime
    # state. Auto-claims on PreToolUse will re-populate as the model edits.
    if [[ -n "$session_id" ]]; then
      # Refresh heartbeat, clear this session's per-turn claims, and mark all
      # currently-undelivered inbox messages as delivered (since the next thing
      # the model reads is the injection below, which includes them).
      lobby_write '
        .sessions |= map(
          if .session_id == $sid
          then .last_seen = $now_iso
               | .last_seen_epoch = ($now | tonumber)
               | .claims = []
               | .inbox = ((.inbox // []) | map(
                   if (.delivered_at // null) == null
                   then .delivered_at = $now_iso
                   else . end
                 ))
          else . end
        )
      ' --arg sid "$session_id" --argjson now "$now" --arg now_iso "$now_iso"
    fi
    # Build context: 1) my own pending inbox (loud, at top), then 2) OTHER
    # sessions' claims/notes/planned_files. Always lead with this session's
    # own short id so the agent can pass --session to note.sh / btw.sh.
    room_text=""
    if [[ -n "$session_id" ]]; then
      room_text=$(room_deliver_new "$session_id")
    fi
    main_text=$(
    jq -r --arg sid "$session_id" '
      ((.sessions[] | select(.session_id == $sid) | .inbox) // []) as $inbox
      | [.sessions[] | select(
          .session_id != $sid and (
            ((.claims        // []) | length > 0) or
            ((.note          // "") | length > 0) or
            ((.planned_files // []) | length > 0)
          )
        )] as $others
      | if ($inbox | length) == 0 and ($others | length) == 0 then ""
        else
          "You are session " + ($sid[0:8]) + "." +
          (if ($inbox | length) > 0 then
             "\n[INBOX] Messages from other sessions (run `~/.claude/hooks/lobby/btw.sh ack --session " + $sid + "` after handling):\n" +
             ($inbox | map("  - from " + .from_short + " at " + .sent_at + ": " + .text) | join("\n"))
           else "" end) +
          (if ($others | length) > 0 then
             "\nOther active Claude sessions in this project:\n" +
             ($others | map(
               "- session " + (.session_id[0:8]) + " (started " + (.started_at // "?") + ")" +
               (if ((.note          // "") | length) > 0
                  then "\n    note: \"" + .note + "\"" else "" end) +
               (if ((.plan_path     // "") | length) > 0
                  then "\n    plan: " + .plan_path else "" end) +
               (if ((.planned_files // []) | length) > 0
                  then "\n    planned files: " + ((.planned_files // []) | join(", ")) else "" end) +
               (if ((.claims        // []) | length) > 0
                  then "\n    actively editing: " + ((.claims // []) | join(", ")) else "" end)
             ) | join("\n")) +
             "\nCoordinate via ~/.claude/hooks/lobby/note.sh (post intent) or /btw <short_id> <question> (ask another session) if you will touch overlapping files."
           else "" end)
        end
    ' "$LOBBY_FILE"
    )
    if [[ -n "$room_text" && -n "$main_text" ]]; then
      printf '%s\n%s' "$main_text" "$room_text"
    elif [[ -n "$room_text" ]]; then
      printf 'You are session %s.\n%s' "${session_id:0:8}" "$room_text"
    else
      printf '%s' "$main_text"
    fi
  ) 200>"$LOBBY_LOCK"
)

if [[ -n "$context" ]]; then
  jq -nc --arg ctx "$context" '{
    hookSpecificOutput: {
      hookEventName: "UserPromptSubmit",
      additionalContext: $ctx
    }
  }'
else
  echo '{}'
fi
exit 0

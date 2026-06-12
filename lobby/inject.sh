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
      lobby_write "$LOBBY_JQ_DEFS"'
        ((.sessions[] | select(.session_id == $sid) | .claims) // []) as $freed
        | .sessions |= map(
          if .session_id == $sid
          then .last_seen = $now_iso
               | .last_seen_epoch = ($now | tonumber)
               | .state = "active"
               | .claims = []
               | .inbox = ((.inbox // []) | map(
                   if (.delivered_at // null) == null
                   then .delivered_at = $now_iso
                   else . end
                 ))
          else . end
        )
        | notify_waiters($freed; $reason; $now_iso)
      ' --arg sid "$session_id" --argjson now "$now" --arg now_iso "$now_iso" \
        --arg reason "(released by ${session_id:0:8})"
    fi
    # Build context: 1) my own pending inbox (loud, at top), then 2) OTHER
    # sessions' claims/notes/planned_files. Always lead with this session's
    # own short id so the agent can pass --session to note.sh / btw.sh.
    room_text=""
    if [[ -n "$session_id" ]]; then
      room_text=$(room_deliver_new "$session_id")
    fi
    main_text=$(
    jq -r --arg sid "$session_id" --arg bin "$LOBBY_BIN" '
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
             "\n[INBOX] Messages from other sessions. Reply where relevant (`" + $bin + "/btw.sh send --from " + $sid + " --to <sender_short_id> --text \"...\"`), handle them alongside your main task, then run `" + $bin + "/btw.sh ack --session " + $sid + "`:\n" +
             ($inbox | map("  - from " + .from_short + " at " + .sent_at + ": " + .text) | join("\n"))
           else "" end) +
          (if ($others | length) > 0 then
             "\nOther active Claude sessions in this project:\n" +
             ($others | map(
               "- session " + (.session_id[0:8]) + " (" + (.state // "?") + ", started " + (.started_at // "?") + ")" +
               (if ((.note          // "") | length) > 0
                  then "\n    note: \"" + .note + "\"" else "" end) +
               (if ((.plan_path     // "") | length) > 0
                  then "\n    plan: " + .plan_path else "" end) +
               (if ((.planned_files // []) | length) > 0
                  then "\n    planned files: " + ((.planned_files // []) | join(", ")) else "" end) +
               (if ((.claims        // []) | length) > 0
                  then "\n    actively editing: " + ((.claims // []) | join(", ")) else "" end)
             ) | join("\n")) +
             "\nCoordinate via " + $bin + "/note.sh (post intent) or /btw <short_id> <question> (ask another session) if you will touch overlapping files."
           else "" end)
        end
    ' "$LOBBY_FILE"
    )
    # Role banner: keeps a roled session oriented even when a human prompts it
    # mid-loop (and is the only injection when nothing else is pending).
    role_text=""
    role=$(jq -r --arg sid "$session_id" '.sessions[] | select(.session_id == $sid) | .role // empty' "$LOBBY_FILE")
    if [[ "$role" == "main" ]]; then
      reviewers=$(jq -r --arg sid "$session_id" '
        [.sessions[] | select(.role == "reviewer" and .main_sid == $sid)]
        | sort_by(.reviewer_no)
        | map("R" + (.reviewer_no | tostring) + " " + .session_id[0:8])
        | join(", ")
      ' "$LOBBY_FILE")
      rstatus=$(jq -r --arg sid "$session_id" '.sessions[] | select(.session_id == $sid) | .review.status // "idle"' "$LOBBY_FILE")
      role_text="[ROLE] You are MAIN (reviewers: ${reviewers:-none})."
      if [[ "$rstatus" == "in_review" ]]; then
        role_text="$role_text A review round is IN PROGRESS — run $LOBBY_BIN/review-wait.sh --session $session_id and obey it before anything else."
      elif [[ "$rstatus" == "changes_requested" ]]; then
        role_text="$role_text Reviewers REQUESTED CHANGES — fix their findings (see $LOBBY_BIN/review.sh status) before anything else."
      fi
    elif [[ "$role" == "reviewer" ]]; then
      role_text=$(jq -r --arg sid "$session_id" --arg bin "$LOBBY_BIN" '
        .sessions[] | select(.session_id == $sid)
        | "[ROLE] You are REVIEWER R" + ((.reviewer_no // 0) | tostring) +
          " of " + ((.main_sid // "?")[0:8]) +
          ". You never edit files; after handling this prompt, return to your loop: run " + $bin + "/review-wait.sh --session " + .session_id + " and obey it."
      ' "$LOBBY_FILE")
    fi

    out=""
    for part in "$role_text" "$main_text" "$room_text"; do
      [[ -z "$part" ]] && continue
      if [[ -z "$out" ]]; then out="$part"; else out="$out
$part"; fi
    done
    if [[ -n "$out" && "$out" != *"You are session"* ]]; then
      out="You are session ${session_id:0:8}.
$out"
    fi
    printf '%s' "$out"
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

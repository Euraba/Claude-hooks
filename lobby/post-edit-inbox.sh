#!/usr/bin/env bash
# PostToolUse hook (all tools):
# After each tool call, deliver any inbox messages that haven't been shown
# to this session yet — so questions from other sessions reach an agent
# mid-execution instead of waiting for its next file edit or user prompt.
# Marks them `delivered_at = now` so they aren't re-injected on every
# subsequent tool call. Messages remain in the inbox until the session runs
# `btw.sh ack` (so they also show again at the next UserPromptSubmit, which
# serves as a turn-boundary reminder).
. "$(dirname "$0")/lib.sh"

if [[ -z "${CLAUDE_PROJECT_DIR:-}" ]]; then
  echo '{}'
  exit 0
fi

input=$(cat)
session_id=$(jq -r '.session_id // empty' <<<"$input")
transcript_path=$(jq -r '.transcript_path // empty' <<<"$input")
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
          "[INBOX] New messages from other Claude sessions arrived while you were working. Reply briefly now (`" + $bin + "/btw.sh send --from " + $sid + " --to <sender_short_id> --text \"...\"`), then CONTINUE your current task — answering does not require abandoning your work. Run `" + $bin + "/btw.sh ack --session " + $sid + "` once handled:\n" +
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

    # Advisory context warning for mains nearing the handoff threshold. The
    # authoritative succession trigger stays in stop-gate.sh (single trigger
    # point — no double-handoff races).
    ctx_warn=""
    role=$(jq -r --arg sid "$session_id" '.sessions[] | select(.session_id == $sid) | .role // empty' "$LOBBY_FILE")
    if [[ "$role" == "main" ]]; then
      handoff_status=$(jq -r --arg sid "$session_id" '.sessions[] | select(.session_id == $sid) | .handoff.status // empty' "$LOBBY_FILE")
      if [[ -z "$handoff_status" ]]; then
        pct=$(estimate_ctx_pct "$transcript_path")
        if [[ -n "$pct" && "$pct" -ge "${LOBBY_HANDOFF_PCT:-50}" ]]; then
          ctx_warn="[CONTEXT] You are at ~${pct}% context. Wrap up the current edit cleanly — a handoff to your reviewer will trigger the next time you stop."
        fi
      fi
    fi

    out=""
    for part in "$undelivered" "$room_new" "$ctx_warn"; do
      [[ -z "$part" ]] && continue
      if [[ -z "$out" ]]; then out="$part"; else out="$out
$part"; fi
    done
    printf '%s' "$out"
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

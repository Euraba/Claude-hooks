#!/usr/bin/env bash
# PreToolUse hook for Edit|Write|MultiEdit|NotebookEdit:
#   - If the target file is claimed by another live session, deny the tool call.
#   - Otherwise, record the claim under this session and allow.
. "$(dirname "$0")/lib.sh"

# Fall back to the git-root anchor when launched without CLAUDE_PROJECT_DIR set.
[[ -z "${CLAUDE_PROJECT_DIR:-}" ]] && CLAUDE_PROJECT_DIR="${LOBBY_ANCHOR:-}"
export CLAUDE_PROJECT_DIR
[[ -z "${CLAUDE_PROJECT_DIR:-}" ]] && exit 0
input=$(cat)
session_id=$(jq -r '.session_id // empty' <<<"$input")
file_path=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input")
[[ -z "$file_path" || -z "$session_id" ]] && exit 0

# Resolve to absolute path (project-relative -> $CLAUDE_PROJECT_DIR/...)
case "$file_path" in
  /*) abs_path="$file_path" ;;
  *)  abs_path="$CLAUDE_PROJECT_DIR/$file_path" ;;
esac

# Reviewers are read-only: they review and talk, they don't write. The check
# self-releases on promotion to main (succession flips .role). Unlocked read:
# worst case a just-promoted heir gets one spurious denial and retries.
lobby_init
my_role=$(jq -r --arg sid "$session_id" \
  '.sessions[] | select(.session_id == $sid) | .role // empty' "$LOBBY_FILE" 2>/dev/null)
if [[ "$my_role" == "reviewer" ]]; then
  my_no=$(jq -r --arg sid "$session_id" \
    '.sessions[] | select(.session_id == $sid) | .reviewer_no // empty' "$LOBBY_FILE" 2>/dev/null)
  reason="You are reviewer R${my_no:-?}: reviewers are read-only and may not edit files. Discuss in the review room ($LOBBY_BIN/room.sh say --session $session_id --text \"...\") or record a verdict ($LOBBY_BIN/review.sh verdict --session $session_id ...). You may edit only after promotion to main."
  jq -nc --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
fi

# If the target file lives in a git repo different from our cwd anchor,
# point this claim at the file's repo. That way two sessions launched from
# different dirs (e.g. one in the repo, one in a parent) still coordinate
# whenever they edit files in the same repo.
file_dir=$(dirname "$abs_path")
file_root=$(git -C "$file_dir" rev-parse --show-toplevel 2>/dev/null)
if [[ -n "$file_root" && "$file_root" != "$LOBBY_ANCHOR" ]]; then
  # Before re-anchoring, record the foreign anchor on our home-lobby entry.
  # release.sh (Stop) and cleanup.sh (SessionEnd) only know the home anchor;
  # without this, claims written into the other repo's lobby would linger
  # until stale-prune and block that repo's sessions for up to 30 minutes.
  lobby_init
  now=$(date +%s)
  now_iso=$(date -Iseconds)
  (
    flock -w 5 200 || exit 0
    lobby_write '
      if (.sessions | map(.session_id) | index($sid))
      then .sessions |= map(
             if .session_id == $sid
             then .anchors = ((.anchors // []) + [$anchor] | unique)
             else . end
           )
      else .sessions += [{
             session_id: $sid,
             started_at: $now_iso,
             last_seen: $now_iso,
             last_seen_epoch: ($now | tonumber),
             state: "active",
             claims: [],
             anchors: [$anchor]
           }]
      end
    ' --arg sid "$session_id" --arg anchor "$file_root" \
      --argjson now "$now" --arg now_iso "$now_iso"
  ) 200>"$LOBBY_LOCK"
  LOBBY_ANCHOR="$file_root"
  LOBBY_DIR="$file_root/.claude"
  LOBBY_FILE="$LOBBY_DIR/lobby.json"
  LOBBY_LOCK="$LOBBY_DIR/lobby.lock"
fi

lobby_init
now=$(date +%s)
now_iso=$(date -Iseconds)

other_claim=$(
  (
    # Fail open on lock contention: no claim check beats stalling every edit.
    flock -w 5 200 || exit 0
    lobby_prune
    # Is the path claimed by any OTHER live session? Return
    # "<sid>\t<state>\t<note>" so the deny reason can include the holder's
    # activity state and posted intent.
    other=$(jq -r --arg sid "$session_id" --arg path "$abs_path" '
      [.sessions[] | select(.session_id != $sid and ((.claims // []) | index($path)))]
      | if length > 0
        then (.[0].session_id + "\t" + (.[0].state // "active") + "\t" + (.[0].note // ""))
        else "" end
    ' "$LOBBY_FILE")
    if [[ -n "$other" ]]; then
      # Queue this session as a waiter: it gets an inbox notification when
      # the path is released (Stop, SessionEnd, or stale-prune).
      lobby_write '
        .waiters = (((.waiters // []) | map(select((.sid == $sid and .path == $path) | not)))
                    + [{sid: $sid, path: $path, queued_at: $now_iso}])
      ' --arg sid "$session_id" --arg path "$abs_path" --arg now_iso "$now_iso"
      printf '%s' "$other"
    else
      # Record claim + refresh heartbeat; a successful claim also dequeues
      # any waiter entry we had on this path (we got what we waited for).
      # Self-heal if we're not in the lobby.
      lobby_write '
        (
          if (.sessions | map(.session_id) | index($sid))
          then .sessions |= map(
                 if .session_id == $sid
                 then .claims = ((.claims // []) + [$path] | unique)
                      | .state = "active"
                      | .last_seen = $now_iso
                      | .last_seen_epoch = ($now | tonumber)
                      # A successful claim is real progress: a main fixing
                      # findings across many turns must not trip the
                      # same-reason Stop-block cap.
                      | .stop_blocks = 0
                 else . end
               )
          else .sessions += [{
                 session_id: $sid,
                 started_at: $now_iso,
                 last_seen: $now_iso,
                 last_seen_epoch: ($now | tonumber),
                 state: "active",
                 claims: [$path]
               }]
          end
        )
        | .waiters = ((.waiters // []) | map(select((.sid == $sid and .path == $path) | not)))
      ' --arg sid "$session_id" --arg path "$abs_path" \
        --argjson now "$now" --arg now_iso "$now_iso"
    fi
  ) 200>"$LOBBY_LOCK"
)

if [[ -n "$other_claim" ]]; then
  IFS=$'\t' read -r other_sid other_state other_note <<<"$other_claim"
  note_part=""
  [[ -n "$other_note" ]] && note_part=" That session's posted intent: \"$other_note\"."
  if [[ "$other_state" == "idle" ]]; then
    state_part=" That session is currently idle (waiting on its user), so a /btw reply may take a while — consider asking the user to coordinate."
  else
    state_part=" That session is currently active and will see a /btw after its next tool call."
  fi
  reason="$abs_path is currently claimed by another Claude session (${other_sid:0:8}) in this project.${note_part}${state_part} You have been queued and will get an [INBOX] notification when it is released — continue other work in the meantime, or ask directly with /btw ${other_sid:0:8} \"<your question>\" (e.g. 'will you modify <method>?')."
  jq -nc --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
fi
exit 0

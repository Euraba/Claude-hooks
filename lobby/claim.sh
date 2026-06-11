#!/usr/bin/env bash
# PreToolUse hook for Edit|Write|MultiEdit|NotebookEdit:
#   - If the target file is claimed by another live session, deny the tool call.
#   - Otherwise, record the claim under this session and allow.
. "$(dirname "$0")/lib.sh"

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

other_sid=$(
  (
    # Fail open on lock contention: no claim check beats stalling every edit.
    flock -w 5 200 || exit 0
    lobby_prune
    # Is the path claimed by any OTHER live session?
    other=$(jq -r --arg sid "$session_id" --arg path "$abs_path" '
      [.sessions[] | select(.session_id != $sid and ((.claims // []) | index($path)))]
      | if length > 0 then .[0].session_id else "" end
    ' "$LOBBY_FILE")
    if [[ -n "$other" ]]; then
      printf '%s' "$other"
    else
      # Record claim + refresh heartbeat. Self-heal if we're not in the lobby.
      lobby_write '
        (
          if (.sessions | map(.session_id) | index($sid))
          then .sessions |= map(
                 if .session_id == $sid
                 then .claims = ((.claims // []) + [$path] | unique)
                      | .last_seen = $now_iso
                      | .last_seen_epoch = ($now | tonumber)
                 else . end
               )
          else .sessions += [{
                 session_id: $sid,
                 started_at: $now_iso,
                 last_seen: $now_iso,
                 last_seen_epoch: ($now | tonumber),
                 claims: [$path]
               }]
          end
        )
      ' --arg sid "$session_id" --arg path "$abs_path" \
        --argjson now "$now" --arg now_iso "$now_iso"
    fi
  ) 200>"$LOBBY_LOCK"
)

if [[ -n "$other_sid" ]]; then
  reason="$abs_path is currently claimed by another Claude session (${other_sid:0:8}) in this project. Either wait for that session to release it, ask it directly with /btw ${other_sid:0:8} \"<your question>\" (e.g. 'will you modify <method>?'), or ask the user to coordinate."
  jq -nc --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
fi
exit 0

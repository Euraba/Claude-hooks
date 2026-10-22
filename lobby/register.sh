#!/usr/bin/env bash
# SessionStart hook: register this session in the project lobby.
#
# Role assignment (env vars on the `claude` launch command):
#   LOBBY_ROLE=main                                      -> this session is a MAIN
#   LOBBY_ROLE=reviewer:1|2|3 LOBBY_MAIN=<sid-or-prefix> -> attach as reviewer N
#
# SessionStart also fires mid-session (source "compact" or "resume"); a hard
# reset there would wipe the session's note, inbox, room membership — and for
# roled sessions their mission/review state. Preserve the existing entry and
# just refresh the heartbeat in those cases (and whenever the entry carries a
# role); genuinely fresh role-less contexts (startup, clear) reset the entry.
# The env role is applied only when the entry is new or on startup/clear.
#
# Emits a role briefing as additionalContext on EVERY source, which is what
# restores a main/reviewer's orientation after compaction or resume.
. "$(dirname "$0")/lib.sh"

# Fall back to the git-root anchor when launched without CLAUDE_PROJECT_DIR set.
[[ -z "${CLAUDE_PROJECT_DIR:-}" ]] && CLAUDE_PROJECT_DIR="${LOBBY_ANCHOR:-}"
export CLAUDE_PROJECT_DIR
[[ -z "${CLAUDE_PROJECT_DIR:-}" ]] && { echo '{}'; exit 0; }
input=$(cat)
session_id=$(jq -r '.session_id // empty' <<<"$input")
start_source=$(jq -r '.source // "startup"' <<<"$input")
[[ -z "$session_id" ]] && { echo '{}'; exit 0; }

lobby_init
now=$(date +%s)
now_iso=$(date -Iseconds)

role_env="${LOBBY_ROLE:-}"
main_env="${LOBBY_MAIN:-}"
want_role=""
want_no=""
sysmsg=""

case "$role_env" in
  "")     ;;
  main)   want_role="main" ;;
  reviewer:1|reviewer:2|reviewer:3)
          want_role="reviewer"; want_no="${role_env#reviewer:}" ;;
  *)      sysmsg="lobby: unrecognized LOBBY_ROLE='$role_env' (use 'main' or 'reviewer:1|2|3') — registered without a role." ;;
esac

# The flock block is a subshell: validation failures are reported by printing
# to stdout, captured here and surfaced as a systemMessage.
lock_msg=$(
(
  flock -w 5 200 || exit 0
  lobby_prune

  exists=$(jq -r --arg sid "$session_id" '(.sessions | map(.session_id) | index($sid)) != null' "$LOBBY_FILE")
  has_role=$(jq -r --arg sid "$session_id" '.sessions[] | select(.session_id == $sid) | .role // empty' "$LOBBY_FILE")

  preserve=false
  if [[ "$exists" == "true" ]]; then
    # NOTE: no `case` here — this runs inside $(...) and bash 3.2 cannot
    # parse `case` inside command substitution.
    [[ "$start_source" == "compact" || "$start_source" == "resume" ]] && preserve=true
    [[ -n "$has_role" ]] && preserve=true
  fi

  if [[ "$preserve" == "true" ]]; then
    # Merge: heartbeat only. Never drop role/mission/review on re-register.
    lobby_write '
      .sessions |= map(
        if .session_id == $sid
        then .last_seen = $now_iso | .last_seen_epoch = ($now | tonumber)
        else . end
      )
    ' --arg sid "$session_id" --argjson now "$now" --arg now_iso "$now_iso"
  else
    lobby_write '
      .sessions = (.sessions | map(select(.session_id != $sid))) + [{
        session_id: $sid,
        started_at: $now_iso,
        last_seen: $now_iso,
        last_seen_epoch: ($now | tonumber),
        state: "idle",
        claims: []
      }]
    ' --arg sid "$session_id" --argjson now "$now" --arg now_iso "$now_iso"
  fi

  apply_role=0
  if [[ -n "$want_role" ]]; then
    if [[ "$exists" != "true" || "$start_source" == "startup" || "$start_source" == "clear" ]]; then
      # Don't re-role a session that already moved on (e.g. promoted heir resuming).
      current_role=$(session_field "$session_id" '.role')
      if [[ -z "$current_role" || "$current_role" == "$want_role" ]]; then
        apply_role=1
      fi
    fi
  fi

  if [[ "$apply_role" == "1" && "$want_role" == "main" ]]; then
    lobby_write '
      .sessions |= map(
        if .session_id == $sid
        then .role = "main"
           | .review = (.review // {status: "idle", round: 0,
                                    max_rounds: ($maxr | tonumber), findings: []})
        else . end
      )
    ' --arg sid "$session_id" --arg maxr "${LOBBY_MAX_ROUNDS:-5}"
  elif [[ "$apply_role" == "1" && "$want_role" == "reviewer" ]]; then
    if [[ -z "$main_env" ]]; then
      printf '%s' "lobby: LOBBY_ROLE=reviewer:$want_no but LOBBY_MAIN is not set — registered without a role. Relaunch with LOBBY_MAIN=<main-session-id-prefix>."
    else
      main_full=$(resolve_sid "$main_env")
      main_role=""
      [[ -n "$main_full" ]] && main_role=$(session_field "$main_full" '.role')
      slot_taken=0
      if [[ -n "$main_full" ]]; then
        slot_taken=$(jq -r --arg m "$main_full" --argjson n "$want_no" --arg me "$session_id" '
          [.sessions[] | select(.role == "reviewer" and .main_sid == $m
                                and .reviewer_no == $n and .session_id != $me)] | length
        ' "$LOBBY_FILE")
      fi
      if [[ -z "$main_full" ]]; then
        printf '%s' "lobby: LOBBY_MAIN='$main_env' did not match any live session — reviewer not attached. Check the main's short id and relaunch."
      elif [[ "$main_role" != "main" ]]; then
        printf '%s' "lobby: session '${main_full:0:8}' is not a main (role: ${main_role:-none}) — reviewer not attached. Launch the main with LOBBY_ROLE=main first."
      elif [[ "$slot_taken" -gt 0 ]]; then
        printf '%s' "lobby: reviewer slot $want_no on main ${main_full:0:8} is already taken — reviewer not attached. Pick a free slot (1-3)."
      else
        # Attach. If the main already has a review room, join it with cursor=0
        # so a late-attached reviewer sees the full review history.
        review_room=$(session_field "$main_full" '.review.room_id')
        lobby_write '
          .sessions |= map(
            if .session_id == $sid
            then .role = "reviewer"
               | .reviewer_no = ($n | tonumber)
               | .main_sid = $main
               | (if $room != "" then .room_id = $room | .room_cursor = 0 else . end)
            else . end
          )
        ' --arg sid "$session_id" --argjson n "$want_no" \
          --arg main "$main_full" --arg room "${review_room:-}"
        if [[ -n "$review_room" ]]; then
          append_room_line "$review_room" "$(jq -nc --arg ts "$now_iso" --arg s "${session_id:0:8}" --arg n "$want_no" \
            '{system: true, text: ("reviewer R" + $n + " (" + $s + ") attached"), ts: $ts}')"
        fi
      fi
    fi
  fi
) 200>"$LOBBY_LOCK"
)
[[ -n "$lock_msg" ]] && sysmsg="$lock_msg"

# Build the role briefing from the ACTUAL lobby state (covers resume/compact
# of sessions that were roled earlier, incl. promoted heirs).
short="${session_id:0:8}"
build_briefing() {
  local role rno msid lens reviewers goal rstatus
  role=$(session_field "$session_id" '.role')
  case "$role" in
    main)
      reviewers=$(attached_reviewers "$session_id" | while IFS=$'\t' read -r no sid; do
        printf 'R%s %s, ' "$no" "${sid:0:8}"
      done)
      reviewers="${reviewers%, }"
      goal=$(session_field "$session_id" '.mission.goal')
      rstatus=$(session_field "$session_id" '.review.status')
      cat <<EOF
[LOBBY ROLE] You are session $short, role MAIN.
Reviewers attached: ${reviewers:-none yet}.
Mission: ${goal:-not set — set it early with: $LOBBY_BIN/mission.sh set --session $session_id --goal "<goal>" [--spec <path>] [--plan <path>]}
Workflow: when you finish a milestone (a spec, a plan, or working code), COMMIT your work, then declare it for review with: $LOBBY_BIN/review.sh request --session $session_id --summary "<what you did>" — then run $LOBBY_BIN/review-wait.sh --session $session_id repeatedly and obey its output until the round resolves. Your reviewers' findings must be fixed before you are allowed to stop; this loops until they approve. Current review status: ${rstatus:-idle}.
EOF
      ;;
    reviewer)
      rno=$(session_field "$session_id" '.reviewer_no')
      msid=$(session_field "$session_id" '.main_sid')
      case "$rno" in
        1) lens="full context: you will receive the goal, spec and plan; judge spec/plan compliance, completeness and design intent. You are also the designated heir — if the main runs out of context you will be promoted to main and continue its work." ;;
        2) lens="goal-only: you will receive only the goal (never read the spec); judge whether the result actually serves the goal." ;;
        3) lens="blind: you receive only the diff; judge code quality, readability and correctness in isolation. Do not seek out the spec or goal." ;;
        *) lens="reviewer" ;;
      esac
      cat <<EOF
[LOBBY ROLE] You are session $short, role REVIEWER R${rno} attached to main ${msid:0:8}.
Your lens — $lens
Standing instructions: NEVER edit files (edits will be denied). Never ask the user anything. Immediately run: $LOBBY_BIN/review-wait.sh --session $session_id via Bash and obey its output. When it prints NO_WORK, run it again. Repeat forever; your Stop hook will remind you if you forget. When it is your turn to review, record your verdict with the command it gives you, then return to review-wait.
EOF
      ;;
  esac
}
briefing=$(build_briefing)

if [[ -n "$briefing" || -n "$sysmsg" ]]; then
  jq -nc --arg ctx "$briefing" --arg sys "$sysmsg" '
    (if $ctx != "" then {hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}} else {} end)
    + (if $sys != "" then {systemMessage: $sys} else {} end)
  '
else
  echo '{}'
fi
exit 0

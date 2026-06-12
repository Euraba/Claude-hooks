#!/usr/bin/env bash
# The wake-up mechanism for the main/reviewer workflow. An idle Claude Code
# session fires no hooks, so reviewers (and a main waiting on a round) stay
# "awake" by running this in a loop via the Bash tool: it polls lobby state,
# heartbeats, and returns as soon as there is work — or NO_WORK at timeout,
# in which case the session is expected to run it again.
#
#   review-wait.sh --session <sid> [--timeout <sec>] [--interval <sec>]
#
# Defaults keep each invocation well under the Bash tool's 2-minute cap.
# Wake conditions, first match wins:
#   reviewer: PROMOTED (succession), REVIEW (your turn, packet per lens),
#             MAIN_GONE (your main ended)
#   main:     round resolved (changes_requested | approved | escalated)
. "$(dirname "$0")/lib.sh"

session_id=""
timeout="${LOBBY_WAIT_TIMEOUT:-90}"
interval="${LOBBY_WAIT_INTERVAL:-5}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)  session_id="${2:-}"; shift 2 ;;
    --timeout)  timeout="${2:-90}";  shift 2 ;;
    --interval) interval="${2:-5}";  shift 2 ;;
    *) echo "review-wait.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$session_id" ]] && { echo "review-wait.sh: missing --session" >&2; exit 2; }
lobby_init
sid_full=$(resolve_sid "$session_id")
[[ -z "$sid_full" ]] && { echo "review-wait.sh: --session '$session_id' did not match any live session" >&2; exit 2; }
short="${sid_full:0:8}"

# ---- packet builders (read-only, lock-free: lobby.json reads are atomic) ----

render_findings() { # main_sid round [request_changes_only]
  jq -r --arg sid "$1" --argjson r "$2" --arg only "${3:-}" '
    .sessions[] | select(.session_id == $sid)
    | (.review.findings // [])
    | map(select(.round == $r))
    | map(select($only == "" or .verdict == $only))
    | if length == 0 then "  (none yet)"
      else map("  - R" + (.reviewer_no | tostring) + " [" + .verdict + "]: " + .text) | join("\n")
      end
  ' "$LOBBY_FILE"
}

build_review_packet() { # I am a reviewer and it is my turn
  local main_sid="$1" my_no="$2"
  local round summary baseline goal spec plan
  round=$(session_field "$main_sid" '.review.round')
  summary=$(session_field "$main_sid" '.review.summary')
  baseline=$(session_field "$main_sid" '.review.baseline_ref')
  goal=$(session_field "$main_sid" '.mission.goal')
  spec=$(session_field "$main_sid" '.mission.spec_path')
  plan=$(session_field "$main_sid" '.mission.plan_path')

  echo "REVIEW — round $round, your turn (R$my_no)."
  case "$my_no" in
    1)
      echo "Lens R1 (full context): judge spec/plan compliance, completeness, design intent."
      echo "Goal: ${goal:-"(no goal registered)"}"
      if [[ -n "$spec" ]]; then echo "Spec: Read $spec"; else echo "Spec: none registered — judge against the goal and existing artifacts."; fi
      [[ -n "$plan" ]] && echo "Plan: Read $plan"
      echo "Main's summary of this milestone: ${summary:-"(none)"}"
      ;;
    2)
      echo "Lens R2 (goal-only): judge whether the result actually serves the goal. Do NOT read any spec or plan documents."
      echo "Goal: ${goal:-"(no goal registered)"}"
      echo "Main's summary of this milestone: ${summary:-"(none)"}"
      ;;
    3)
      echo "Lens R3 (blind): judge code quality, readability, correctness in isolation. You get only the diff — do not seek out the goal, spec, or summary. Form your own opinion from the diff alone BEFORE reading the earlier findings at the bottom."
      ;;
  esac
  echo
  if [[ -n "$baseline" ]]; then
    echo "Changes since baseline ${baseline:0:10}:"
    git -C "$LOBBY_ANCHOR" log --oneline "$baseline..HEAD" 2>/dev/null | sed 's/^/  /'
    git -C "$LOBBY_ANCHOR" diff --stat "$baseline" 2>/dev/null | sed 's/^/  /'
    echo "Read the full diff with: git -C $LOBBY_ANCHOR diff $baseline"
  else
    echo "No baseline ref recorded — review the working tree state (git -C $LOBBY_ANCHOR status / diff)."
  fi
  echo
  echo "Earlier findings this round (refute or extend them):"
  render_findings "$main_sid" "$round" ""
  echo
  echo "When done, record exactly one verdict:"
  echo "  $LOBBY_BIN/review.sh verdict --session $sid_full --verdict approve|request_changes --text \"<your findings>\""
  echo "You may also discuss first via: $LOBBY_BIN/room.sh say --session $sid_full --text \"...\""
  echo "Then run $LOBBY_BIN/review-wait.sh --session $sid_full again."
}

build_main_result() { # my round resolved
  local status="$1" round="$2"
  case "$status" in
    changes_requested)
      echo "CHANGES_REQUESTED — round $round findings:"
      render_findings "$sid_full" "$round" "request_changes"
      echo "Fix these, commit, then re-request: $LOBBY_BIN/review.sh request --session $sid_full --summary \"<what you fixed>\""
      ;;
    approved)
      echo "APPROVED — all reviewers approved round $round. Summarize the milestone for the user, then you may stop (the user will be notified)."
      ;;
    escalated)
      echo "ESCALATED — round cap reached without approval. Stop and tell the user the review is deadlocked; a human can resume it with: $LOBBY_BIN/review.sh reset --session $short"
      ;;
    *)
      echo "NO_REVIEW — no review round is in progress (status: ${status:-idle})."
      ;;
  esac
}

# ---- poll loop ---------------------------------------------------------------

elapsed=0
chatter=""

while :; do
  # One locked pass: heartbeat, self-heal, collect chatter, check wake conditions.
  out=$(
  (
    # Fail open on lock contention: an empty pass just means another cycle.
    flock -w 5 200 || exit 0
    lobby_prune
    now=$(date +%s); now_iso=$(date -Iseconds)
    # Heartbeat (the wait loop counts as being mid-turn, hence "active"); also
    # reset the Stop-gate's same-reason block counter — running this script is
    # the proof that the session is obeying its loop.
    lobby_write '
      .sessions |= map(
        if .session_id == $sid
        then .last_seen = $now_iso | .last_seen_epoch = ($now | tonumber)
           | .state = "active"
           | .stop_blocks = 0
        else . end
      )
    ' --arg sid "$sid_full" --arg now_iso "$now_iso" --argjson now "$now"

    role=$(session_field "$sid_full" '.role')
    main_sid=$(session_field "$sid_full" '.main_sid')

    # Heal the relevant main's chain (covers a dead reviewer holding the turn).
    if [[ "$role" == "reviewer" && -n "$main_sid" ]]; then
      review_self_heal "$main_sid"
    elif [[ "$role" == "main" ]]; then
      review_self_heal "$sid_full"
    fi

    # Chatter: new room lines + undelivered inbox (consumed now, so always print).
    room_new=$(room_deliver_new "$sid_full")
    inbox_new=$(jq -r --arg sid "$sid_full" '
      ((.sessions[] | select(.session_id == $sid) | .inbox) // [])
      | map(select((.delivered_at // null) == null))
      | if length == 0 then ""
        else "[INBOX] " + (map("from " + .from_short + ": " + .text) | join("; "))
        end
    ' "$LOBBY_FILE")
    if [[ -n "$inbox_new" ]]; then
      lobby_write '
        .sessions |= map(
          if .session_id == $sid
          then .inbox = ((.inbox // []) | map(
                 if (.delivered_at // null) == null then .delivered_at = $now_iso else . end))
          else . end
        )
      ' --arg sid "$sid_full" --arg now_iso "$now_iso"
    fi
    [[ -n "$room_new" ]]  && printf 'CHAT %s\n' "$(printf '%s' "$room_new" | tr '\n' '\036')"
    [[ -n "$inbox_new" ]] && printf 'CHAT %s\n' "$(printf '%s' "$inbox_new" | tr '\n' '\036')"

    # Wake conditions.
    if [[ "$role" == "main" ]]; then
      brief_in=$(session_field "$sid_full" '.handoff_brief_in')
      if [[ -n "$brief_in" ]]; then
        printf 'WAKE PROMOTED %s\n' "$brief_in"
        lobby_write '
          .sessions |= map(if .session_id == $sid then .handoff_brief_in = null | .idle_cycles = 0 else . end)
        ' --arg sid "$sid_full"
      else
        status=$(session_field "$sid_full" '.review.status')
        if [[ -n "$status" && "$status" != "in_review" ]]; then
          printf 'WAKE MAIN_RESULT %s %s\n' "$status" "$(session_field "$sid_full" '.review.round')"
          lobby_write '
            .sessions |= map(if .session_id == $sid then .idle_cycles = 0 else . end)
          ' --arg sid "$sid_full"
        fi
      fi
    elif [[ "$role" == "reviewer" ]]; then
      main_alive=$(jq -r --arg m "$main_sid" '[.sessions[] | select(.session_id == $m and .role == "main")] | length' "$LOBBY_FILE")
      if [[ -z "$main_sid" || "$main_alive" -eq 0 ]]; then
        printf 'WAKE MAIN_GONE\n'
      else
        status=$(session_field "$main_sid" '.review.status')
        turn=$(session_field "$main_sid" '.review.turn')
        my_no=$(session_field "$sid_full" '.reviewer_no')
        if [[ "$status" == "in_review" && "$turn" == "$my_no" ]]; then
          printf 'WAKE REVIEW %s %s\n' "$main_sid" "$my_no"
          lobby_write '
            .sessions |= map(if .session_id == $sid then .idle_cycles = 0 else . end)
          ' --arg sid "$sid_full"
        fi
      fi
    else
      printf 'WAKE NO_ROLE\n'
    fi
  ) 200>"$LOBBY_LOCK"
  )

  # Collect chatter lines; detect a wake line.
  wake=""
  while IFS= read -r line; do
    case "$line" in
      CHAT\ *) chatter="${chatter}$(printf '%s' "${line#CHAT }" | tr '\036' '\n')"$'\n' ;;
      WAKE\ *) wake="${line#WAKE }" ;;
    esac
  done <<EOF
$out
EOF

  if [[ -n "$wake" ]]; then
    [[ -n "$chatter" ]] && printf '%s\n' "$chatter"
    kind="${wake%% *}"
    case "$kind" in
      PROMOTED)
        # Everything after the marker is the path (may contain spaces).
        brief="${wake#PROMOTED }"; [[ "$brief" == "PROMOTED" ]] && brief=""
        echo "PROMOTED — you are now the MAIN session. The previous main ran out of context and handed off to you."
        echo "You may now edit files. Your reviewers (if any) are attached to you."
        if [[ -n "$brief" && -f "$brief" ]]; then
          echo "---- handoff brief ($brief) ----"
          cat "$brief"
          echo "---- end of brief ----"
        else
          echo "(handoff brief missing — check $HANDOFFS_DIR and the review room transcript)"
        fi
        echo "Continue the work from the brief. Re-read the spec/plan if referenced. Declare your next milestone with: $LOBBY_BIN/review.sh request --session $sid_full --summary \"...\""
        ;;
      REVIEW)
        set -- $wake   # REVIEW <main_sid> <my_no> — no spaces in either
        # Rendered WITHOUT the lobby lock: lobby.json reads are atomic, and the
        # git log/diff inside the packet can be slow on big repos — holding the
        # lock here would stall every other session's hooks.
        build_review_packet "$2" "$3"
        ;;
      MAIN_GONE)
        echo "MAIN_GONE — your main session ended without promoting you. Your review duties are over; you may stop now and tell the user."
        ;;
      MAIN_RESULT)
        set -- $wake   # MAIN_RESULT <status> <round>
        build_main_result "$2" "$3"
        ;;
      NO_ROLE)
        echo "NO_ROLE — this session has no lobby role; review-wait does not apply. Stop running it."
        ;;
    esac
    exit 0
  fi

  if (( elapsed + interval > timeout )); then
    # Timed out: count the idle cycle and hand back a re-run instruction.
    (
      flock -w 5 200 || exit 0
      lobby_write '
        .sessions |= map(if .session_id == $sid then .idle_cycles = ((.idle_cycles // 0) + 1) else . end)
      ' --arg sid "$sid_full"
    ) 200>"$LOBBY_LOCK"
    [[ -n "$chatter" ]] && printf '%s\n' "$chatter"
    role=$(session_field "$sid_full" '.role')
    if [[ "$role" == "reviewer" ]]; then
      msid=$(session_field "$sid_full" '.main_sid')
      st=$(session_field "$msid" '.review.status')
      tn=$(session_field "$msid" '.review.turn')
      echo "NO_WORK (review status: ${st:-idle}, turn: R${tn:-—}). Run $LOBBY_BIN/review-wait.sh --session $sid_full again now."
    else
      st=$(session_field "$sid_full" '.review.status')
      echo "NO_WORK (your review status: ${st:-idle}). Run $LOBBY_BIN/review-wait.sh --session $sid_full again now."
    fi
    exit 0
  fi

  sleep "$interval"
  elapsed=$(( elapsed + interval ))
done

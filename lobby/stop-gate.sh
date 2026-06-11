#!/usr/bin/env bash
# Stop hook: the enforcement point of the main/reviewer workflow. Decides, by
# role and review state, whether this session may go idle:
#
#   retired   -> never block; one-shot systemMessage telling the human about
#                the handoff and how to attach a fresh reviewer.
#   reviewer  -> block ("run review-wait") while its main lives, so reviewers
#                never go idle. Released when the main is gone or the idle cap
#                is hit.
#   main      -> succession trigger (context >= LOBBY_HANDOFF_PCT) first, then
#                block while findings are unresolved or a round is running.
#                approved/escalated are terminal: no block, one-shot message.
#
# Loop safety: every block either moves state toward a terminal state or bumps
# a same-reason counter (stop_blocks, reset by review-wait.sh / state changes);
# past LOBBY_MAX_SAME_BLOCKS the gate stops blocking and escalates to the
# human instead. Sessions without a role are untouched.
. "$(dirname "$0")/lib.sh"

[[ -z "${CLAUDE_PROJECT_DIR:-}" ]] && exit 0
[[ -f "$LOBBY_FILE" ]] || exit 0
input=$(cat)
session_id=$(jq -r '.session_id // empty' <<<"$input")
transcript_path=$(jq -r '.transcript_path // empty' <<<"$input")
[[ -z "$session_id" ]] && exit 0

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
HANDOFF_PCT="${LOBBY_HANDOFF_PCT:-50}"
MAX_SAME_BLOCKS="${LOBBY_MAX_SAME_BLOCKS:-3}"
MAX_IDLE_CYCLES="${LOBBY_REVIEWER_MAX_IDLE_CYCLES:-240}"

# The locked gate communicates the decision by printing marker lines
# (newlines in payloads encoded as \036):  BLOCK <reason> / SYS <message>
enc() { printf '%s' "$1" | tr '\n' '\036'; }

# Same-reason cap helper: prints the current count for this reason and
# persists sig+count. Caller decides whether to still block.
bump_block_counter() {
  local reason="$1" sig n prev_sig prev_n
  sig=$(printf '%s' "$reason" | cksum | awk '{print $1}')
  prev_sig=$(session_field "$session_id" '.stop_block_sig')
  prev_n=$(session_field "$session_id" '.stop_blocks')
  [[ "$prev_n" =~ ^[0-9]+$ ]] || prev_n=0
  if [[ "$prev_sig" == "$sig" ]]; then n=$((prev_n + 1)); else n=1; fi
  lobby_write '
    .sessions |= map(
      if .session_id == $sid then .stop_blocks = ($n | tonumber) | .stop_block_sig = $sig else . end
    )
  ' --arg sid "$session_id" --arg n "$n" --arg sig "$sig"
  printf '%s' "$n"
}

# The whole decision tree lives in a top-level function (NOT inline in the
# command substitution below) — bash 3.2 cannot parse `case` inside `$(...)`.
gate_decide() {
  lobby_prune

  local role short
  role=$(session_field "$session_id" '.role')
  [[ -z "$role" ]] && return 0
  short="${session_id:0:8}"

  if [[ "$role" == "retired" ]]; then
    notified=$(session_field "$session_id" '.handoff.notified')
    if [[ "$notified" != "true" ]]; then
      heir=$(session_field "$session_id" '.handoff.heir_sid')
      freed=$(session_field "$session_id" '.handoff.freed_no')
      lobby_write '
        .sessions |= map(if .session_id == $sid then .handoff.notified = true else . end)
      ' --arg sid "$session_id"
      printf 'SYS %s\n' "$(enc "lobby: this main session ran out of context and handed off to ${heir:0:8}, which is now the main. You can close this window. Optionally attach a fresh reviewer to the new main: LOBBY_ROLE=reviewer:${freed:-1} LOBBY_MAIN=${heir:0:8} claude")"
    fi
    exit 0
  fi

  if [[ "$role" == "reviewer" ]]; then
    main_sid=$(session_field "$session_id" '.main_sid')
    main_alive=0
    [[ -n "$main_sid" ]] && main_alive=$(jq -r --arg m "$main_sid" \
      '[.sessions[] | select(.session_id == $m and .role == "main")] | length' "$LOBBY_FILE")
    if [[ "$main_alive" -eq 0 ]]; then
      printf 'SYS %s\n' "$(enc "lobby: reviewer $short released — its main session ended.")"
      exit 0
    fi
    idle=$(session_field "$session_id" '.idle_cycles')
    [[ "$idle" =~ ^[0-9]+$ ]] || idle=0
    if [[ "$idle" -ge "$MAX_IDLE_CYCLES" ]]; then
      printf 'SYS %s\n' "$(enc "lobby: reviewer $short idle cap reached ($idle wait cycles with no work) — released. Relaunch or prompt it to resume reviewing.")"
      exit 0
    fi
    reason="You are reviewer R$(session_field "$session_id" '.reviewer_no') for ${main_sid:0:8}. Do not stop. Run $HOOKS_DIR/review-wait.sh --session $session_id via Bash and obey its output; when it prints NO_WORK, run it again."
    n=$(bump_block_counter "$reason")
    if [[ "$n" -gt "$MAX_SAME_BLOCKS" ]]; then
      printf 'SYS %s\n' "$(enc "lobby: reviewer $short kept trying to stop without running review-wait ($n times) — released. It may need a manual prompt.")"
      exit 0
    fi
    printf 'BLOCK %s\n' "$(enc "$reason")"
    exit 0
  fi

  # ---- role == main ----------------------------------------------------------

  # Succession first: a main past the context threshold must hand off before
  # doing anything else. Latched via handoff.status — but the latch re-checks
  # the estimate: auto-compaction can shrink context back under the threshold,
  # and a main must not be forced into a handoff it no longer needs. The latch
  # is kept when the estimate is unavailable (fail toward the safer state).
  handoff_status=$(session_field "$session_id" '.handoff.status')
  if [[ "$handoff_status" != "done" ]]; then
    has_reviewer=$(next_reviewer_no "$session_id" 0)
    pct=$(estimate_ctx_pct "$transcript_path")
    if [[ "$handoff_status" == "pending" && -n "$pct" && "$pct" -lt "$HANDOFF_PCT" ]]; then
      lobby_write '
        .sessions |= map(if .session_id == $sid then del(.handoff) else . end)
      ' --arg sid "$session_id"
      printf 'SYS %s\n' "$(enc "lobby: main $short is back at ${pct}% context (compaction?) — pending handoff cancelled.")"
      handoff_status=""
    fi
    if [[ "$handoff_status" == "pending" || ( -n "$pct" && -n "$has_reviewer" && "$pct" -ge "$HANDOFF_PCT" ) ]]; then
      if [[ -n "$has_reviewer" ]]; then
        brief_path=$(session_field "$session_id" '.handoff.brief_path')
        if [[ "$handoff_status" != "pending" ]]; then
          mkdir -p "$HANDOFFS_DIR"
          brief_path="$HANDOFFS_DIR/$short-$(date +%s).md"
          lobby_write '
            .sessions |= map(
              if .session_id == $sid
              then .handoff = {status: "pending", brief_path: $bp, notified: false}
              else . end
            )
          ' --arg sid "$session_id" --arg bp "$brief_path"
          printf 'SYS %s\n' "$(enc "lobby: main $short is at ${pct:-?}% context — handing off to reviewer R$has_reviewer.")"
        fi
        reason="Your context window is at ${pct:-the configured} threshold (>=${HANDOFF_PCT}%). Before stopping you MUST hand off to your reviewer: (1) Write a handoff brief to $brief_path covering: current state of the work, in-flight/unfinished tasks, mission goal + spec/plan paths, key decisions made, exact next steps, and current review status. (2) Then run: $HOOKS_DIR/succession.sh handoff --session $session_id --brief $brief_path — your lowest-numbered reviewer will be promoted to main and continue from your brief."
        n=$(bump_block_counter "$reason")
        if [[ "$n" -gt "$MAX_SAME_BLOCKS" ]]; then
          printf 'SYS %s\n' "$(enc "lobby: main $short failed to complete its handoff after $n attempts — letting it stop. Run the handoff manually or start a fresh session from the review room history.")"
          exit 0
        fi
        printf 'BLOCK %s\n' "$(enc "$reason")"
        exit 0
      fi
    fi
  fi

  status=$(session_field "$session_id" '.review.status')
  case "$status" in
    changes_requested)
      # With no live reviewers left, "fix and re-request" is impossible —
      # escalate to the human instead of blocking on it.
      if [[ -z "$(next_reviewer_no "$session_id" 0)" ]]; then
        lobby_write '
          .sessions |= map(
            if .session_id == $sid
            then .review.status = "escalated" | .review.notified = true
            else . end
          )
        ' --arg sid "$session_id"
        printf 'SYS %s\n' "$(enc "lobby: main $short has unresolved review findings but all its reviewers are gone — escalating to you. Attach a new reviewer (LOBBY_ROLE=reviewer:1 LOBBY_MAIN=$short claude) and run $HOOKS_DIR/review.sh reset --session $short to resume, or take over manually.")"
        exit 0
      fi
      round=$(session_field "$session_id" '.review.round')
      maxr=$(session_field "$session_id" '.review.max_rounds')
      findings=$(jq -r --arg sid "$session_id" '
        .sessions[] | select(.session_id == $sid)
        | (.review.round // 0) as $r
        | (.review.findings // [])
        | map(select(.round == $r and .verdict == "request_changes"))
        | map("- R" + (.reviewer_no | tostring) + ": " + .text) | join("\n")
      ' "$LOBBY_FILE")
      reason="Reviewers requested changes in round $round — you may not stop until they approve. Unresolved findings:
$findings
Fix these, commit, then start round $((${round:-0}+1))/${maxr:-5} with: $HOOKS_DIR/review.sh request --session $session_id --summary \"<what you fixed>\""
      n=$(bump_block_counter "$reason")
      if [[ "$n" -gt "$MAX_SAME_BLOCKS" ]]; then
        printf 'SYS %s\n' "$(enc "lobby: main $short stalled on round-$round findings ($n stop attempts without progress) — letting it stop. See review.sh status.")"
        exit 0
      fi
      printf 'BLOCK %s\n' "$(enc "$reason")"
      ;;
    in_review)
      reason="A review round is in progress (waiting on R$(session_field "$session_id" '.review.turn')). Do not stop and do not start new work. Run $HOOKS_DIR/review-wait.sh --session $session_id and obey its output."
      n=$(bump_block_counter "$reason")
      if [[ "$n" -gt "$MAX_SAME_BLOCKS" ]]; then
        printf 'SYS %s\n' "$(enc "lobby: main $short kept stopping during an in-progress round ($n times) — letting it stop. The round will still resolve; prompt the session to run review-wait.")"
        exit 0
      fi
      printf 'BLOCK %s\n' "$(enc "$reason")"
      ;;
    approved)
      notified=$(session_field "$session_id" '.review.notified')
      if [[ "$notified" != "true" ]]; then
        round=$(session_field "$session_id" '.review.round')
        lobby_write '
          .sessions |= map(if .session_id == $sid then .review.notified = true else . end)
        ' --arg sid "$session_id"
        printf 'SYS %s\n' "$(enc "lobby: milestone \"$(session_field "$session_id" '.review.summary')\" APPROVED by all reviewers after round $round — ready for your (human) review.")"
      fi
      ;;
    escalated)
      notified=$(session_field "$session_id" '.review.notified')
      if [[ "$notified" != "true" ]]; then
        lobby_write '
          .sessions |= map(if .session_id == $sid then .review.notified = true else . end)
        ' --arg sid "$session_id"
        printf 'SYS %s\n' "$(enc "lobby: review DEADLOCKED after $(session_field "$session_id" '.review.round') rounds — human input needed. Inspect: $HOOKS_DIR/review.sh status; transcript: $HOOKS_DIR/room.sh show --room $(session_field "$session_id" '.review.room_id'); resume with: $HOOKS_DIR/review.sh reset --session $short")"
      fi
      ;;
  esac
  return 0
}

out=$(
  (
    # Fail open on lock contention: a missed gate decision beats a hung Stop
    # hook freezing the session.
    flock -w 5 200 || exit 0
    gate_decide
  ) 200>"$LOBBY_LOCK"
)

block=""
sys=""
while IFS= read -r line; do
  case "$line" in
    BLOCK\ *) block=$(printf '%s' "${line#BLOCK }" | tr '\036' '\n') ;;
    SYS\ *)   sys=$(printf '%s' "${line#SYS }" | tr '\036' '\n') ;;
  esac
done <<EOF
$out
EOF

if [[ -n "$block" || -n "$sys" ]]; then
  jq -nc --arg reason "$block" --arg sys "$sys" '
    (if $reason != "" then {decision: "block", reason: $reason} else {} end)
    + (if $sys != "" then {systemMessage: $sys} else {} end)
  '
fi
exit 0

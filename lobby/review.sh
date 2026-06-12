#!/usr/bin/env bash
# Review state machine for the main/reviewer workflow.
#
#   review.sh request --session <main_sid> --summary "<what was done>"
#   review.sh verdict --session <reviewer_sid> --verdict approve|request_changes --text "<findings>"
#   review.sh status  [--session <sid>]
#   review.sh reset   --session <main_sid> [--max-rounds N]
#
# States (on the main's .review.status):
#   idle -> in_review -> changes_requested -> in_review -> ... -> approved
#                                          \-> escalated (round cap) -> reset
# All transitions happen under the lobby lock; only the reviewer whose number
# matches .review.turn may record a verdict. Round-completion logic lives in
# review_advance (lib.sh), shared with dead-reviewer self-healing.
. "$(dirname "$0")/lib.sh"

cmd="${1:-}"
[[ $# -gt 0 ]] && shift

session_id=""
summary=""
verdict=""
text=""
max_rounds_arg=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)    session_id="${2:-}";     shift 2 ;;
    --summary)    summary="${2:-}";        shift 2 ;;
    --verdict)    verdict="${2:-}";        shift 2 ;;
    --text)       text="${2:-}";           shift 2 ;;
    --max-rounds) max_rounds_arg="${2:-}"; shift 2 ;;
    *) echo "review.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

lobby_init

case "$cmd" in
  request)
    [[ -z "$session_id" || -z "$summary" ]] && {
      echo "review.sh request: need --session and --summary" >&2; exit 2; }
    sid_full=$(resolve_sid "$session_id")
    [[ -z "$sid_full" ]] && { echo "review.sh request: --session '$session_id' did not match" >&2; exit 2; }

    if [[ -n "$(git -C "$LOBBY_ANCHOR" status --porcelain 2>/dev/null)" ]]; then
      echo "review.sh request: WARNING — uncommitted changes; reviewers will diff the working tree against the baseline. Committing first is recommended." >&2
    fi

    now=$(date +%s)
    now_iso=$(date -Iseconds)
    head_ref=$(git -C "$LOBBY_ANCHOR" rev-parse HEAD 2>/dev/null || true)

    (
      flock -w 5 200 || { echo "lobby: lock busy, try again" >&2; exit 1; }
      lobby_prune

      role=$(session_field "$sid_full" '.role')
      [[ "$role" != "main" ]] && {
        echo "review.sh request: session ${sid_full:0:8} is not a main (role: ${role:-none})" >&2; exit 3; }

      status=$(session_field "$sid_full" '.review.status')
      case "$status" in
        in_review)
          echo "review.sh request: a round is already in progress (waiting on R$(session_field "$sid_full" '.review.turn')). Run $LOBBY_BIN/review-wait.sh --session $sid_full instead." >&2
          exit 3 ;;
        escalated)
          echo "review.sh request: review is escalated to the human after hitting the round cap. A human must run: $LOBBY_BIN/review.sh reset --session ${sid_full:0:8}" >&2
          exit 3 ;;
      esac

      first_turn=$(next_reviewer_no "$sid_full" 0)
      [[ -z "$first_turn" ]] && {
        echo "review.sh request: no live reviewers attached to ${sid_full:0:8} — nothing to review against. Proceed without review or have the user attach one (LOBBY_ROLE=reviewer:1 LOBBY_MAIN=${sid_full:0:8} claude)." >&2
        exit 3; }

      # Lazily create the persistent review room and pull main + all attached
      # reviewers into it (membership is implied by role — no invite handshake).
      room=$(session_field "$sid_full" '.review.room_id')
      if [[ -z "$room" ]]; then
        room="r-rev-$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
        mkdir -p "$ROOMS_DIR"
        : > "$ROOMS_DIR/$room.jsonl"
        append_room_line "$room" "$(jq -nc --arg ts "$now_iso" --arg s "${sid_full:0:8}" \
          '{system: true, text: ("review room opened for main " + $s), ts: $ts}')"
      fi
      lobby_write '
        .sessions |= map(
          if .session_id == $main or (.role == "reviewer" and .main_sid == $main)
          then (if .room_id != $room then .room_id = $room | .room_cursor = 0 else . end)
          else . end
        )
      ' --arg main "$sid_full" --arg room "$room"

      # Open the round. Fresh milestone (idle/approved) restarts at round 1;
      # a fix-round after changes_requested keeps the same baseline.
      lobby_write '
        .sessions |= map(
          if .session_id == $main
          then .review = ((.review // {})
                 | (if (.status // "idle") == "changes_requested"
                    then .round = ((.round // 0) + 1)
                    else .round = 1
                       | .findings = []   # findings are per-milestone; history lives in the room transcript
                       | (if $head != "" and (.baseline_ref // "") == "" then .baseline_ref = $head else . end)
                    end)
                 | .status = "in_review"
                 | .room_id = $room
                 | .summary = $summary
                 | .turn = ($turn | tonumber)
                 | .requested_at = $now_iso
                 | .notified = false
                 | .max_rounds = (.max_rounds // ($maxr | tonumber))
                 | .findings = (.findings // []))
             | .last_seen = $now_iso
             | .last_seen_epoch = ($now | tonumber)
          else . end
        )
      ' --arg main "$sid_full" --arg room "$room" --arg summary "$summary" \
        --arg turn "$first_turn" --arg head "$head_ref" \
        --arg maxr "${LOBBY_MAX_ROUNDS:-5}" \
        --arg now_iso "$now_iso" --argjson now "$now"

      round=$(session_field "$sid_full" '.review.round')
      baseline=$(session_field "$sid_full" '.review.baseline_ref')
      append_room_line "$room" "$(jq -nc --arg ts "$now_iso" --arg s "${sid_full:0:8}" \
        --arg r "$round" --arg sum "$summary" --arg b "${baseline:-?}" \
        '{system: true, text: ("review round " + $r + " requested by " + $s + ": " + $sum + " (baseline " + $b[0:10] + ")"), ts: $ts}')"
      # Main has "seen" everything up to and including its own request line.
      total=$(wc -l < "$ROOMS_DIR/$room.jsonl")
      lobby_write '
        .sessions |= map(if .session_id == $main then .room_cursor = ($n | tonumber) else . end)
      ' --arg main "$sid_full" --argjson n "$total"

      echo "review round $round open (turn: R$first_turn). Now run $LOBBY_BIN/review-wait.sh --session $sid_full repeatedly and obey its output until the round resolves. Do not start new work."
    ) 200>"$LOBBY_LOCK"
    exit $?
    ;;

  verdict)
    [[ -z "$session_id" || -z "$verdict" || -z "$text" ]] && {
      echo "review.sh verdict: need --session, --verdict, --text" >&2; exit 2; }
    case "$verdict" in
      approve|request_changes) ;;
      *) echo "review.sh verdict: --verdict must be approve or request_changes" >&2; exit 2 ;;
    esac
    sid_full=$(resolve_sid "$session_id")
    [[ -z "$sid_full" ]] && { echo "review.sh verdict: --session '$session_id' did not match" >&2; exit 2; }

    now=$(date +%s)
    now_iso=$(date -Iseconds)

    (
      flock -w 5 200 || { echo "lobby: lock busy, try again" >&2; exit 1; }
      lobby_prune

      role=$(session_field "$sid_full" '.role')
      [[ "$role" != "reviewer" ]] && {
        echo "review.sh verdict: session ${sid_full:0:8} is not a reviewer (role: ${role:-none})" >&2; exit 3; }
      my_no=$(session_field "$sid_full" '.reviewer_no')
      main_sid=$(session_field "$sid_full" '.main_sid')
      [[ -z "$main_sid" ]] && { echo "review.sh verdict: no main attached" >&2; exit 3; }

      status=$(session_field "$main_sid" '.review.status')
      turn=$(session_field "$main_sid" '.review.turn')
      if [[ "$status" != "in_review" || "$turn" != "$my_no" ]]; then
        echo "review.sh verdict: not your turn (status: ${status:-none}, turn: R${turn:-?}, you: R$my_no). Run $LOBBY_BIN/review-wait.sh --session $sid_full and wait for your turn." >&2
        exit 3
      fi

      round=$(session_field "$main_sid" '.review.round')
      room=$(session_field "$main_sid" '.review.room_id')

      lobby_write '
        .sessions |= map(
          if .session_id == $main
          then .review.findings = ((.review.findings // []) + [{
                 round: ($round | tonumber),
                 reviewer_no: ($no | tonumber),
                 verdict: $verdict,
                 text: $text,
                 at: $now_iso
               }])
          else . end
        )
      ' --arg main "$main_sid" --arg round "$round" --arg no "$my_no" \
        --arg verdict "$verdict" --arg text "$text" --arg now_iso "$now_iso"

      append_room_line "$room" "$(jq -nc \
        --arg from_short "${sid_full:0:8}" --arg from_full "$sid_full" \
        --arg t "[R${my_no}:${verdict}] ${text}" --arg ts "$now_iso" \
        '{from_short: $from_short, from_full: $from_full, text: $t, ts: $ts}')"
      total=$(wc -l < "$ROOMS_DIR/$room.jsonl")
      lobby_write '
        .sessions |= map(
          if .session_id == $sid then .room_cursor = ($n | tonumber)
             | .last_seen = $now_iso | .last_seen_epoch = ($now | tonumber)
          else . end
        )
      ' --arg sid "$sid_full" --argjson n "$total" --arg now_iso "$now_iso" --argjson now "$now"

      review_advance "$main_sid" "$my_no"

      new_status=$(session_field "$main_sid" '.review.status')
      if [[ "$new_status" == "in_review" ]]; then
        echo "verdict recorded; chain advanced to R$(session_field "$main_sid" '.review.turn'). Run $LOBBY_BIN/review-wait.sh --session $sid_full again."
      else
        echo "verdict recorded; round $round complete ($new_status). Run $LOBBY_BIN/review-wait.sh --session $sid_full again."
      fi
    ) 200>"$LOBBY_LOCK"
    exit $?
    ;;

  status)
    # Optional --session narrows to one main (a reviewer's sid resolves to its
    # main); without it, all mains are shown.
    filter_sid=""
    if [[ -n "$session_id" ]]; then
      sid_full=$(resolve_sid "$session_id")
      [[ -z "$sid_full" ]] && { echo "review.sh status: --session '$session_id' did not match" >&2; exit 2; }
      if [[ "$(session_field "$sid_full" '.role')" == "reviewer" ]]; then
        filter_sid=$(session_field "$sid_full" '.main_sid')
      else
        filter_sid="$sid_full"
      fi
    fi
    (
      flock -w 5 200 || { echo "lobby: lock busy, try again" >&2; exit 1; }
      lobby_prune
      jq -r --arg only "$filter_sid" '
        [.sessions[] | select(.role == "main" and ($only == "" or .session_id == $only))] as $mains
        | if ($mains | length) == 0 then "(no main sessions)"
          else $mains | map(. as $m |
            "main " + (.session_id[0:8]) +
            "\n  goal: " + (.mission.goal // "(not set)") +
            "\n  review: " + (.review.status // "idle") +
              " round " + ((.review.round // 0) | tostring) + "/" + ((.review.max_rounds // 5) | tostring) +
              (if .review.turn then " (turn: R" + (.review.turn | tostring) + ")" else "" end) +
              (if .review.room_id then " room " + .review.room_id else "" end) +
            "\n  summary: " + (.review.summary // "(none)") +
            ((.review.findings // []) | map(
              "\n  [round " + (.round | tostring) + "] R" + (.reviewer_no | tostring) + " " + .verdict + ": " + .text
            ) | add // "")
          ) | join("\n") end
      ' "$LOBBY_FILE"
    ) 200>"$LOBBY_LOCK"
    ;;

  reset)
    [[ -z "$session_id" ]] && { echo "review.sh reset: missing --session" >&2; exit 2; }
    sid_full=$(resolve_sid "$session_id")
    [[ -z "$sid_full" ]] && { echo "review.sh reset: --session '$session_id' did not match" >&2; exit 2; }
    (
      flock -w 5 200 || { echo "lobby: lock busy, try again" >&2; exit 1; }
      status=$(session_field "$sid_full" '.review.status')
      # Reset exists to resume an ESCALATED review; forcing changes_requested
      # from any other state would clobber a live round's turn (in_review) or
      # un-approve a finished one.
      if [[ "$status" != "escalated" ]]; then
        echo "review.sh reset: review for ${sid_full:0:8} is '${status:-idle}', not escalated — nothing to reset" >&2
        exit 3
      fi
      round=$(session_field "$sid_full" '.review.round')
      new_max="${max_rounds_arg:-$(( ${round:-0} + 5 ))}"
      lobby_write '
        .sessions |= map(
          if .session_id == $sid
          then .review.status = "changes_requested"
             | .review.turn = null
             | .review.max_rounds = ($maxr | tonumber)
             | .review.notified = false
          else . end
        )
      ' --arg sid "$sid_full" --arg maxr "$new_max"
      echo "review reset for ${sid_full:0:8}: status changes_requested, max_rounds $new_max (was: $status)"
    ) 200>"$LOBBY_LOCK"
    ;;

  ""|-h|--help|help)
    cat >&2 <<'EOF'
Usage:
  review.sh request --session <main_sid> --summary "<what was done>"
  review.sh verdict --session <reviewer_sid> --verdict approve|request_changes --text "<findings>"
  review.sh status  [--session <sid>]
  review.sh reset   --session <main_sid> [--max-rounds N]
EOF
    exit 2
    ;;

  *)
    echo "review.sh: unknown command: $cmd" >&2
    exit 2
    ;;
esac

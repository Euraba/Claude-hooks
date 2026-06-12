#!/usr/bin/env bash
# Context-overflow succession: promote a main's lowest-numbered reviewer to
# main. Triggered by the main itself after its Stop gate detects the context
# threshold (or voluntarily with --force).
#
#   succession.sh handoff --session <main_sid> --brief <path> [--force]
#
# In one locked transaction: the heir becomes main (inheriting mission +
# review state incl. the review room), remaining reviewers re-attach to the
# heir, and the old main is retired (its Stop gate stops blocking and tells
# the human what happened). The heir's running review-wait loop picks up the
# promotion via handoff_brief_in and receives the brief.
. "$(dirname "$0")/lib.sh"

cmd="${1:-}"
[[ $# -gt 0 ]] && shift

session_id=""
brief=""
force=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session) session_id="${2:-}"; shift 2 ;;
    --brief)   brief="${2:-}";      shift 2 ;;
    --force)   force=1;             shift 1 ;;
    *) echo "succession.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ "$cmd" != "handoff" ]] && {
  echo "Usage: succession.sh handoff --session <main_sid> --brief <path> [--force]" >&2; exit 2; }
[[ -z "$session_id" || -z "$brief" ]] && {
  echo "succession.sh handoff: need --session and --brief" >&2; exit 2; }

lobby_init
sid_full=$(resolve_sid "$session_id")
[[ -z "$sid_full" ]] && { echo "succession.sh: --session '$session_id' did not match" >&2; exit 2; }

brief=$(portable_realpath "$brief")
if [[ ! -s "$brief" && "$force" -eq 0 ]]; then
  echo "succession.sh: brief file $brief is missing or empty — write the handoff brief first (or pass --force)" >&2
  exit 2
fi

now=$(date +%s)
now_iso=$(date -Iseconds)
short="${sid_full:0:8}"

result=$(
(
  flock -w 10 200 || { echo "ERR lobby lock busy, run the handoff command again"; exit 4; }
  lobby_prune

  role=$(session_field "$sid_full" '.role')
  if [[ "$role" != "main" ]]; then
    echo "ERR session $short is not a main (role: ${role:-none})"
    exit 3
  fi

  heir_line=$(attached_reviewers "$sid_full" | head -n 1)
  if [[ -z "$heir_line" ]]; then
    echo "ERR no live reviewers attached to $short — nobody to promote. The session must wrap up on its own."
    exit 3
  fi
  heir_no="${heir_line%%	*}"
  heir_sid="${heir_line#*	}"

  mission_json=$(jq -c --arg sid "$sid_full" '.sessions[] | select(.session_id == $sid) | .mission // null' "$LOBBY_FILE")
  review_json=$(jq -c --arg sid "$sid_full" '.sessions[] | select(.session_id == $sid) | .review // null' "$LOBBY_FILE")

  lobby_write '
    .sessions |= map(
      if .session_id == $heir
      then .role = "main"
         | .mission = $mission
         | .review = $review
         | del(.reviewer_no, .main_sid)
         | .handoff_brief_in = $brief
         | .stop_blocks = 0
         | .idle_cycles = 0
      elif .role == "reviewer" and .main_sid == $old
      then .main_sid = $heir
      elif .session_id == $old
      then .role = "retired"
         | .claims = []
         | .handoff = {status: "done", brief_path: $brief, notified: false,
                       heir_sid: $heir, freed_no: ($heir_no | tonumber)}
      else . end
    )
  ' --arg heir "$heir_sid" --arg old "$sid_full" --arg brief "$brief" \
    --argjson mission "$mission_json" --argjson review "$review_json" \
    --arg heir_no "$heir_no"

  # If the heir was holding the review turn, advance/finalize past it.
  review_self_heal "$heir_sid"

  echo "OK $heir_sid $heir_no"
  exit 0
) 200>"$LOBBY_LOCK"
)
rc=$?

if [[ "$rc" -ne 0 || "$result" == ERR* ]]; then
  echo "succession.sh: ${result#ERR }" >&2
  exit 3
fi

set -- $result   # OK <heir_sid> <heir_no>
heir_sid="$2"
heir_no="$3"
heir_short="${heir_sid:0:8}"

room=$(session_field "$heir_sid" '.review.room_id')
if [[ -n "$room" ]]; then
  append_room_line "$room" "$(jq -nc --arg ts "$now_iso" \
    --arg t "main $short handed off to ${heir_short} (was R${heir_no}); brief: $brief" \
    '{system: true, text: $t, ts: $ts}')"
fi

# Redundant delivery path: inbox pointer to the brief (the heir's wait loop
# also detects the promotion directly via handoff_brief_in).
"$(dirname "$0")/btw.sh" send --from "$sid_full" --to "$heir_sid" \
  --text "[HANDOFF] You have been promoted to MAIN. Handoff brief: $brief" 2>/dev/null || true

echo "handoff complete: $heir_short (was R$heir_no) is now the main; this session ($short) is retired. Stop now — the user will be notified."
exit 0

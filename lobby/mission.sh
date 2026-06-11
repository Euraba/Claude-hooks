#!/usr/bin/env bash
# CLI for a main session's mission: the goal text plus optional spec/plan
# paths. Reviewers receive slices of this per their lens (R1 everything,
# R2 goal only, R3 nothing). On first set, records the review baseline ref.
#
# Usage:
#   mission.sh set --session <sid> --goal "<text>" [--spec <path>] [--plan <path>]
#   mission.sh show
. "$(dirname "$0")/lib.sh"

cmd="${1:-}"
[[ $# -gt 0 ]] && shift

session_id=""
goal=""
spec=""
plan=""
has_goal=0
has_spec=0
has_plan=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session) session_id="${2:-}"; shift 2 ;;
    --goal)    goal="${2:-}"; has_goal=1; shift 2 ;;
    --spec)    spec="${2:-}"; has_spec=1; shift 2 ;;
    --plan)    plan="${2:-}"; has_plan=1; shift 2 ;;
    *) echo "mission.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

lobby_init

case "$cmd" in
  set)
    [[ -z "$session_id" ]] && { echo "mission.sh set: missing --session" >&2; exit 2; }
    if [[ $has_goal -eq 0 && $has_spec -eq 0 && $has_plan -eq 0 ]]; then
      echo "mission.sh set: need at least one of --goal, --spec, --plan" >&2; exit 2
    fi
    sid_full=$(resolve_sid "$session_id")
    [[ -z "$sid_full" ]] && { echo "mission.sh set: --session '$session_id' did not match" >&2; exit 2; }

    role=$(session_field "$sid_full" '.role')
    if [[ "$role" == "reviewer" ]]; then
      echo "mission.sh set: session ${sid_full:0:8} is a reviewer — only mains have missions" >&2; exit 2
    fi

    [[ $has_spec -eq 1 && -n "$spec" ]] && spec=$(portable_realpath "$spec")
    [[ $has_plan -eq 1 && -n "$plan" ]] && plan=$(portable_realpath "$plan")

    baseline=$(git -C "$LOBBY_ANCHOR" rev-parse HEAD 2>/dev/null || true)
    now=$(date +%s)
    now_iso=$(date -Iseconds)
    set_goal_b=$([[ $has_goal -eq 1 ]] && echo true || echo false)
    set_spec_b=$([[ $has_spec -eq 1 ]] && echo true || echo false)
    set_plan_b=$([[ $has_plan -eq 1 ]] && echo true || echo false)

    (
      flock 200
      lobby_prune
      lobby_write '
        .sessions |= map(
          if .session_id == $sid
          then .role = (.role // "main")
             | .mission = ((.mission // {goal: null, spec_path: null, plan_path: null})
                 | (if $set_goal then .goal      = $goal else . end)
                 | (if $set_spec then .spec_path = (if $spec == "" then null else $spec end) else . end)
                 | (if $set_plan then .plan_path = (if $plan == "" then null else $plan end) else . end))
             | .review = (.review // {status: "idle", round: 0,
                                      max_rounds: ($maxr | tonumber), findings: []})
             | (if (.review.baseline_ref // "") == "" and $baseline != ""
                then .review.baseline_ref = $baseline else . end)
             | .last_seen = $now_iso
             | .last_seen_epoch = ($now | tonumber)
          else . end
        )
      ' --arg sid "$sid_full" --arg goal "$goal" --arg spec "$spec" --arg plan "$plan" \
        --argjson set_goal "$set_goal_b" --argjson set_spec "$set_spec_b" --argjson set_plan "$set_plan_b" \
        --arg baseline "$baseline" --arg maxr "${LOBBY_MAX_ROUNDS:-5}" \
        --arg now_iso "$now_iso" --argjson now "$now"
    ) 200>"$LOBBY_LOCK"
    echo "mission updated for ${sid_full:0:8}"
    ;;

  show)
    (
      flock 200
      lobby_prune
      jq -r '
        [.sessions[] | select(.role == "main")]
        | if length == 0 then "(no main sessions)"
          else map(
            "main " + (.session_id[0:8]) +
            "\n  goal: " + (.mission.goal // "(not set)") +
            "\n  spec: " + (.mission.spec_path // "(none)") +
            "\n  plan: " + (.mission.plan_path // "(none)") +
            "\n  review: " + (.review.status // "idle") +
              " (round " + ((.review.round // 0) | tostring) + ")"
          ) | join("\n") end
      ' "$LOBBY_FILE"
    ) 200>"$LOBBY_LOCK"
    ;;

  ""|-h|--help|help)
    cat >&2 <<'EOF'
Usage:
  mission.sh set --session <sid> --goal "<text>" [--spec <path>] [--plan <path>]
  mission.sh show
EOF
    exit 2
    ;;

  *)
    echo "mission.sh: unknown command: $cmd" >&2
    exit 2
    ;;
esac

#!/usr/bin/env bash
# CLI for managing per-session notes in the lobby.
# Notes are human-readable intent ("what I'm working on") that other sessions
# see via inject.sh. They persist within a session and are removed by
# cleanup.sh (SessionEnd) or lobby_prune (stale).
#
# Usage:
#   note.sh set --session <sid> [--note <text>] [--plan <path>] [--files <f1,f2,...>]
#   note.sh clear --session <sid>
#   note.sh show
. "$(dirname "$0")/lib.sh"

cmd="${1:-}"
[[ $# -gt 0 ]] && shift

session_id=""
note=""
plan=""
files=""
has_note=0
has_plan=0
has_files=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session) session_id="${2:-}"; shift 2 ;;
    --note)    note="${2:-}";       has_note=1;  shift 2 ;;
    --plan)    plan="${2:-}";       has_plan=1;  shift 2 ;;
    --files)   files="${2:-}";      has_files=1; shift 2 ;;
    *) echo "note.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$session_id" && -n "${CLAUDE_SESSION_ID:-}" ]]; then
  session_id="$CLAUDE_SESSION_ID"
fi

lobby_init

case "$cmd" in
  set)
    if [[ -z "$session_id" ]]; then
      echo "note.sh set: missing --session (and CLAUDE_SESSION_ID not in env)" >&2
      exit 2
    fi
    if [[ $has_note -eq 0 && $has_plan -eq 0 && $has_files -eq 0 ]]; then
      echo "note.sh set: need at least one of --note, --plan, --files" >&2
      exit 2
    fi

    # Resolve --files (comma-separated) to a JSON array of absolute paths.
    planned_files_json="[]"
    if [[ $has_files -eq 1 ]]; then
      planned_files_json=$(
        printf '%s' "$files" \
          | tr ',' '\n' \
          | awk '{gsub(/^ +| +$/, ""); if (NF) print}' \
          | while IFS= read -r f; do portable_realpath "$f"; done \
          | jq -R . | jq -s .
      )
    fi

    now_iso=$(date -Iseconds)
    now=$(date +%s)
    set_note_b=$([[ $has_note  -eq 1 ]] && echo true || echo false)
    set_plan_b=$([[ $has_plan  -eq 1 ]] && echo true || echo false)
    set_files_b=$([[ $has_files -eq 1 ]] && echo true || echo false)

    (
      flock -w 5 200 || { echo "note.sh set: lobby lock busy, try again" >&2; exit 1; }
      lobby_prune
      lobby_write '
        if (.sessions | map(.session_id) | index($sid))
        then .sessions |= map(
               if .session_id == $sid
               then (if $set_note  then .note          = $note  else . end)
                  | (if $set_plan  then .plan_path     = $plan  else . end)
                  | (if $set_files then .planned_files = $files else . end)
                  | .note_updated_at = $now_iso
                  | .last_seen       = $now_iso
                  | .last_seen_epoch = ($now | tonumber)
               else . end
             )
        else .sessions += [{
               session_id: $sid,
               started_at: $now_iso,
               last_seen: $now_iso,
               last_seen_epoch: ($now | tonumber),
               claims: [],
               note:           (if $set_note  then $note  else null end),
               plan_path:      (if $set_plan  then $plan  else null end),
               planned_files:  (if $set_files then $files else []   end),
               note_updated_at: $now_iso
             }]
        end
      ' \
        --arg sid "$session_id" \
        --arg note "$note" \
        --arg plan "$plan" \
        --argjson files "$planned_files_json" \
        --argjson set_note  "$set_note_b" \
        --argjson set_plan  "$set_plan_b" \
        --argjson set_files "$set_files_b" \
        --arg now_iso "$now_iso" \
        --argjson now "$now"
    ) 200>"$LOBBY_LOCK"
    ;;

  clear)
    if [[ -z "$session_id" ]]; then
      echo "note.sh clear: missing --session" >&2
      exit 2
    fi
    (
      flock -w 5 200 || { echo "note.sh clear: lobby lock busy, try again" >&2; exit 1; }
      lobby_write '
        .sessions |= map(
          if .session_id == $sid
          then .note            = null
             | .plan_path       = null
             | .planned_files   = []
             | .note_updated_at = null
          else . end
        )
      ' --arg sid "$session_id"
    ) 200>"$LOBBY_LOCK"
    ;;

  show)
    (
      flock -w 5 200 || { echo "note.sh show: lobby lock busy, try again" >&2; exit 1; }
      lobby_prune
      jq -r '
        .sessions[] |
        "session " + (.session_id[0:8]) + " (started " + (.started_at // "?") + ")" +
        (if ((.note // "") | length) > 0
           then "\n  note: " + .note else "" end) +
        (if ((.plan_path // "") | length) > 0
           then "\n  plan: " + .plan_path else "" end) +
        (if ((.planned_files // []) | length) > 0
           then "\n  planned files: " + ((.planned_files // []) | join(", ")) else "" end) +
        (if ((.claims // []) | length) > 0
           then "\n  actively editing: " + ((.claims // []) | join(", ")) else "" end)
      ' "$LOBBY_FILE"
    ) 200>"$LOBBY_LOCK"
    ;;

  ""|-h|--help|help)
    cat >&2 <<'EOF'
Usage:
  note.sh set --session <sid> [--note <text>] [--plan <path>] [--files <f1,f2,...>]
  note.sh clear --session <sid>
  note.sh show

Notes persist across turns within a session; cleared automatically when the
session ends or after 30min of inactivity.
EOF
    exit 2
    ;;

  *)
    echo "note.sh: unknown command: $cmd" >&2
    exit 2
    ;;
esac

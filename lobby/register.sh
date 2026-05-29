#!/usr/bin/env bash
# SessionStart hook: register this session in the project lobby.
. "$(dirname "$0")/lib.sh"

[[ -z "${CLAUDE_PROJECT_DIR:-}" ]] && exit 0
input=$(cat)
session_id=$(jq -r '.session_id // empty' <<<"$input")
[[ -z "$session_id" ]] && exit 0

lobby_init
now=$(date +%s)
now_iso=$(date -Iseconds)

(
  flock 200
  lobby_prune
  lobby_write '
    .sessions = (.sessions | map(select(.session_id != $sid))) + [{
      session_id: $sid,
      started_at: $now_iso,
      last_seen: $now_iso,
      last_seen_epoch: ($now | tonumber),
      claims: []
    }]
  ' --arg sid "$session_id" --argjson now "$now" --arg now_iso "$now_iso"
) 200>"$LOBBY_LOCK"

exit 0

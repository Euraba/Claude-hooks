#!/usr/bin/env bash
# SessionStart hook: register this session in the project lobby.
. "$(dirname "$0")/lib.sh"

[[ -z "${CLAUDE_PROJECT_DIR:-}" ]] && exit 0
input=$(cat)
session_id=$(jq -r '.session_id // empty' <<<"$input")
[[ -z "$session_id" ]] && exit 0
start_source=$(jq -r '.source // empty' <<<"$input")

# SessionStart also fires mid-session (source "compact" or "resume"); a hard
# reset there would wipe the session's note, inbox, and room membership.
# Preserve the existing entry and just refresh the heartbeat in those cases;
# genuinely fresh contexts (startup, clear) reset the entry.
preserve=false
case "$start_source" in compact|resume) preserve=true ;; esac

lobby_init
now=$(date +%s)
now_iso=$(date -Iseconds)

(
  flock -w 5 200 || exit 0
  lobby_prune
  lobby_write '
    if ($preserve and (.sessions | map(.session_id) | index($sid)))
    then .sessions |= map(
           if .session_id == $sid
           then .last_seen = $now_iso | .last_seen_epoch = ($now | tonumber)
           else . end
         )
    else .sessions = (.sessions | map(select(.session_id != $sid))) + [{
           session_id: $sid,
           started_at: $now_iso,
           last_seen: $now_iso,
           last_seen_epoch: ($now | tonumber),
           state: "idle",
           claims: []
         }]
    end
  ' --arg sid "$session_id" --argjson now "$now" --arg now_iso "$now_iso" \
    --argjson preserve "$preserve"
) 200>"$LOBBY_LOCK"

exit 0

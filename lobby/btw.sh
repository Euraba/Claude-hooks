#!/usr/bin/env bash
# Side-channel messaging between Claude sessions in the same project.
# Messages live in each session's `inbox` array in lobby.json. Senders write
# into the recipient's inbox; inject.sh surfaces a session's own inbox to it
# on UserPromptSubmit. Recipients run `btw.sh ack` after handling; ack only
# removes messages that were already delivered, so anything that arrived
# since the last injection stays queued.
#
# Usage:
#   btw.sh send  --from <sid_or_short> --to <sid_or_short_or_all> --text "..."
#   btw.sh inbox --session <sid_or_short>
#   btw.sh ack   --session <sid_or_short>
#   btw.sh show
. "$(dirname "$0")/lib.sh"

cmd="${1:-}"
[[ $# -gt 0 ]] && shift

from=""
to=""
text=""
session_id=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)    from="${2:-}";       shift 2 ;;
    --to)      to="${2:-}";         shift 2 ;;
    --text)    text="${2:-}";       shift 2 ;;
    --session) session_id="${2:-}"; shift 2 ;;
    *) echo "btw.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

lobby_init

# resolve_sid comes from lib.sh (exact match first, then unique prefix).

case "$cmd" in
  send)
    [[ -z "$from" || -z "$to" || -z "$text" ]] && {
      echo "btw.sh send: need --from, --to, --text" >&2; exit 2; }

    from_full=$(resolve_sid "$from")
    [[ -z "$from_full" ]] && { echo "btw.sh send: --from '$from' did not match any session" >&2; exit 2; }
    from_short="${from_full:0:8}"
    now_iso=$(date -Iseconds)

    if [[ "$to" == "all" ]]; then
      targets_json=$(jq --arg from "$from_full" '[.sessions[] | select(.session_id != $from) | .session_id]' "$LOBBY_FILE")
    else
      to_full=$(resolve_sid "$to")
      [[ -z "$to_full" ]] && { echo "btw.sh send: --to '$to' did not match any session" >&2; exit 2; }
      [[ "$to_full" == "$from_full" ]] && { echo "btw.sh send: cannot send to self" >&2; exit 2; }
      targets_json=$(jq -n --arg t "$to_full" '[$t]')
    fi

    if [[ "$(jq 'length' <<<"$targets_json")" -eq 0 ]]; then
      echo "btw.sh send: no recipients" >&2; exit 2
    fi

    (
      flock -w 5 200 || { echo "btw.sh send: lobby lock busy, try again" >&2; exit 1; }
      lobby_prune
      # Only the inbox is touched: a message must NOT refresh the recipient's
      # heartbeat, or a dead session that keeps receiving mail never goes
      # stale and its leftover claims linger forever.
      lobby_write '
        .sessions |= map(
          if (.session_id as $sid | $targets | index($sid))
          then .inbox = ((.inbox // []) + [{
                 from_short:   $from_short,
                 from_full:    $from_full,
                 text:         $text,
                 sent_at:      $now_iso,
                 delivered_at: null
               }])
          else . end
        )
      ' \
        --argjson targets "$targets_json" \
        --arg from_short "$from_short" \
        --arg from_full  "$from_full" \
        --arg text       "$text" \
        --arg now_iso    "$now_iso"
    ) 200>"$LOBBY_LOCK"
    ;;

  inbox)
    [[ -z "$session_id" ]] && { echo "btw.sh inbox: missing --session" >&2; exit 2; }
    sid_full=$(resolve_sid "$session_id")
    [[ -z "$sid_full" ]] && { echo "btw.sh inbox: --session '$session_id' did not match" >&2; exit 2; }
    (
      flock -w 5 200 || { echo "btw.sh inbox: lobby lock busy, try again" >&2; exit 1; }
      lobby_prune
      jq -r --arg sid "$sid_full" '
        .sessions[] | select(.session_id == $sid) | .inbox // [] |
        if length == 0 then "(empty)"
        else map("- from " + .from_short + " at " + .sent_at + ": " + .text) | join("\n")
        end
      ' "$LOBBY_FILE"
    ) 200>"$LOBBY_LOCK"
    ;;

  ack)
    [[ -z "$session_id" ]] && { echo "btw.sh ack: missing --session" >&2; exit 2; }
    sid_full=$(resolve_sid "$session_id")
    [[ -z "$sid_full" ]] && { echo "btw.sh ack: --session '$session_id' did not match" >&2; exit 2; }
    (
      flock -w 5 200 || { echo "btw.sh ack: lobby lock busy, try again" >&2; exit 1; }
      # Only drop messages that were already delivered (shown to the agent).
      # Anything that arrived after the last injection has not been seen yet
      # and must survive the ack.
      lobby_write '
        .sessions |= map(
          if .session_id == $sid
          then .inbox = ((.inbox // []) | map(select((.delivered_at // null) == null)))
          else . end
        )
      ' --arg sid "$sid_full"
    ) 200>"$LOBBY_LOCK"
    ;;

  show)
    (
      flock -w 5 200 || { echo "btw.sh show: lobby lock busy, try again" >&2; exit 1; }
      lobby_prune
      jq -r '
        .sessions[] |
        "session " + (.session_id[0:8]) + " inbox (" + (((.inbox // []) | length) | tostring) + "):" +
        (((.inbox // []) | map("\n  - from " + .from_short + " at " + .sent_at + ": " + .text)) | add // "")
      ' "$LOBBY_FILE"
    ) 200>"$LOBBY_LOCK"
    ;;

  ""|-h|--help|help)
    cat >&2 <<'EOF'
Usage:
  btw.sh send  --from <sid_or_short> --to <sid_or_short_or_all> --text "..."
  btw.sh inbox --session <sid_or_short>
  btw.sh ack   --session <sid_or_short>
  btw.sh show
EOF
    exit 2
    ;;

  *)
    echo "btw.sh: unknown command: $cmd" >&2
    exit 2
    ;;
esac

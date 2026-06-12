#!/usr/bin/env bash
# Sourced by lobby hook scripts. Provides shared state + helpers.

set -uo pipefail

STALE_AFTER_SEC="${LOBBY_STALE_AFTER_SEC:-1800}"
# Roled sessions (main/reviewer/retired) get a much longer prune TTL: a main
# legitimately sits idle for hours while the human is away, and pruning it
# would dissolve its whole reviewer setup (role, mission, review state).
ROLE_STALE_SEC="${LOBBY_ROLE_STALE_SEC:-86400}"

# Anchor the lobby to the enclosing git repo root if present, so two sessions
# launched at different depths inside the same repo share state. Fall back to
# CLAUDE_PROJECT_DIR (or cwd) when there's no git repo.
lobby_anchor() {
  local start="${CLAUDE_PROJECT_DIR:-$PWD}"
  local root
  root=$(git -C "$start" rev-parse --show-toplevel 2>/dev/null)
  if [[ -n "$root" ]]; then
    printf '%s' "$root"
  else
    printf '%s' "$start"
  fi
}

LOBBY_ANCHOR=$(lobby_anchor)
LOBBY_DIR="$LOBBY_ANCHOR/.claude"
LOBBY_FILE="$LOBBY_DIR/lobby.json"
LOBBY_LOCK="$LOBBY_DIR/lobby.lock"
ROOMS_DIR="$LOBBY_DIR/rooms"
HANDOFFS_DIR="$LOBBY_DIR/handoffs"

# Where the lobby scripts themselves live, for self-referencing paths in
# injected context (works regardless of where the repo was cloned).
LOBBY_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Opt-in debug log (set LOBBY_DEBUG_LOG=/path/to/log) to see hooks firing
# across sessions. Off by default: an always-on shared log in /tmp would
# grow unbounded and leak project paths to other users on the host.
if [[ -n "${LOBBY_DEBUG_LOG:-}" ]]; then
  {
    printf '[%s] %s pid=%s ppid=%s cwd=%s CLAUDE_PROJECT_DIR=%s anchor=%s\n' \
      "$(date -Iseconds)" "$0" "$$" "$PPID" "$PWD" "${CLAUDE_PROJECT_DIR:-UNSET}" "$LOBBY_ANCHOR"
  } >> "$LOBBY_DEBUG_LOG" 2>/dev/null || true
fi

lobby_init() {
  mkdir -p "$LOBBY_DIR"
  if [[ ! -s "$LOBBY_FILE" ]] || ! jq -e . "$LOBBY_FILE" >/dev/null 2>&1; then
    printf '{"sessions":[]}\n' > "$LOBBY_FILE"
  fi
  [[ -e "$LOBBY_LOCK" ]] || : > "$LOBBY_LOCK"
}

# Resolve a path to absolute, normalized form. Tolerates non-existent paths
# (so users can claim files they're about to create), like GNU `realpath -m`.
# Prefers GNU `realpath -m` when available (also resolves symlinks); falls
# back to a pure-bash implementation on BSD/macOS where `-m` doesn't exist
# and plain `realpath` errors on non-existent paths.
#
# The fallback does NOT resolve symlinks — the lobby uses these strings for
# human-readable display and string-equality claim checks, not canonical
# identity, so symlink resolution isn't load-bearing.
portable_realpath() {
  local p="$1"
  [[ -z "$p" ]] && { printf '\n'; return 0; }
  if realpath -m "$p" 2>/dev/null; then
    return 0
  fi
  case "$p" in
    /*) ;;
    *) p="$PWD/$p" ;;
  esac
  local IFS=/ part out=""
  for part in $p; do
    case "$part" in
      ''|.) ;;
      ..) out="${out%/*}" ;;
      *) out="$out/$part" ;;
    esac
  done
  printf '%s\n' "${out:-/}"
}

# File mtime in epoch seconds: GNU stat (-c) vs BSD/macOS stat (-f).
portable_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# Atomic write: jq into a temp file in the same dir, then rename.
lobby_write() {
  local filter=$1
  shift
  local tmp
  tmp=$(mktemp "$LOBBY_DIR/.lobby.XXXXXX")
  if jq "$@" "$filter" "$LOBBY_FILE" > "$tmp"; then
    mv "$tmp" "$LOBBY_FILE"
  else
    rm -f "$tmp"
    return 1
  fi
}

# Shared jq prelude, prepended to filters that release claims.
# notify_waiters($freed; $reason; $ts): for every queued waiter on a freed
# path, append a [CLAIM FREED] message to that session's inbox (delivered by
# the normal inbox machinery, mid-execution) and drop the queue entry.
LOBBY_JQ_DEFS='
  def notify_waiters($freed; $reason; $ts):
    (.waiters // []) as $ws
    | .sessions |= map(
        . as $s
        | ($ws | map(select(.sid == $s.session_id and (.path as $p | $freed | index($p)))) | map(.path)) as $hits
        | if ($hits | length) > 0
          then .inbox = ((.inbox // []) + ($hits | map({
                 from_short: "lobby",
                 from_full:  "lobby",
                 text: ("[CLAIM FREED] " + . + " is no longer claimed " + $reason + ". You asked to edit it; you can claim it now."),
                 sent_at: $ts,
                 delivered_at: null
               })))
          else . end
      )
    | .waiters = ((.waiters // []) | map(select((.path as $p | $freed | index($p)) | not)));
'

# Drop sessions whose last_seen_epoch is older than STALE_AFTER_SEC — notifying
# queued waiters on the dead sessions' claims and dropping dead sessions' own
# queue entries — then collect room transcripts left with no members. Caller
# holds lock.
lobby_prune() {
  local now now_iso
  now=$(date +%s)
  now_iso=$(date -Iseconds)
  lobby_write "$LOBBY_JQ_DEFS"'
    def is_stale: ((.last_seen_epoch // 0) | tonumber)
                  <= ($now - (if (.role // "") != "" then $rttl else $ttl end));
    (.sessions | map(select(is_stale))) as $dead
    | ($dead | map(.claims // []) | add // []) as $freed
    | ($dead | map(.session_id)) as $deadids
    | .sessions |= map(select(is_stale | not))
    | notify_waiters($freed; "(its holder went stale)"; $ts)
    | .waiters = ((.waiters // []) | map(select((.sid as $i | $deadids | index($i)) | not)))
  ' --argjson now "$now" --argjson ttl "$STALE_AFTER_SEC" \
    --argjson rttl "$ROLE_STALE_SEC" --arg ts "$now_iso"
  lobby_gc_rooms
}

# Delete room files whose room_id has no remaining member (e.g. the last
# member was stale-pruned, so neither leave nor SessionEnd ran). Files
# younger than 60s are skipped: invite creates the transcript before taking
# the lobby lock to record membership, so a brand-new room briefly has no
# member on record. Caller holds lock.
lobby_gc_rooms() {
  local rooms_dir="$LOBBY_DIR/rooms" f room mtime now
  [[ -d "$rooms_dir" ]] || return 0
  now=$(date +%s)
  for f in "$rooms_dir"/*.jsonl; do
    [[ -e "$f" ]] || break
    mtime=$(portable_mtime "$f") || continue
    (( now - mtime < 60 )) && continue
    room=$(basename "$f" .jsonl)
    if [[ $(jq -r --arg room "$room" \
          '[.sessions[] | select((.room_id // "") == $room)] | length' "$LOBBY_FILE") -eq 0 ]]; then
      rm -f "$f" "$f.lock"
    fi
  done
}

# Clear session $1's claims in the lobby anchored at $2 (mode "clear"), or
# remove its entry entirely (mode "remove"). Used for claims recorded in a
# different git repo than the session's home anchor. Takes that lobby's own
# lock; must NOT be called while holding another lobby lock.
lobby_release_anchor() {
  local sid="$1" anchor="$2" mode="${3:-clear}"
  local dir="$anchor/.claude"
  local file="$dir/lobby.json" lock="$dir/lobby.lock" tmp reason ts
  [[ -f "$file" ]] || return 0
  ts=$(date -Iseconds)
  reason="(released by ${sid:0:8})"
  [[ "$mode" == "remove" ]] && reason="(its holder session ended)"
  (
    flock -w 5 200 || exit 0
    tmp=$(mktemp "$dir/.lobby.XXXXXX") || exit 0
    if jq --arg sid "$sid" --arg mode "$mode" --arg reason "$reason" --arg ts "$ts" \
         "$LOBBY_JQ_DEFS"'
         ((.sessions[] | select(.session_id == $sid) | .claims) // []) as $freed
         | (if $mode == "remove"
            then .sessions |= map(select(.session_id != $sid))
            else .sessions |= map(if .session_id == $sid then .claims = [] else . end)
            end)
         | notify_waiters($freed; $reason; $ts)
         | (if $mode == "remove"
            then .waiters = ((.waiters // []) | map(select(.sid != $sid)))
            else . end)
       ' "$file" > "$tmp"; then
      mv "$tmp" "$file"
    else
      rm -f "$tmp"
    fi
  ) 200>"$lock"
}

# Resolve a short or full id to a full session_id present in lobby.json.
# Exact match wins; otherwise a unique prefix match. Empty result => not found
# or ambiguous.
resolve_sid() {
  local needle="$1"
  jq -r --arg n "$needle" '
    .sessions | map(.session_id) as $ids
    | ($ids | map(select(. == $n))) as $exact
    | if ($exact | length) == 1 then $exact[0]
      else
        ($ids | map(select(startswith($n)))) as $pref
        | if ($pref | length) == 1 then $pref[0] else "" end
      end
  ' "$LOBBY_FILE"
}

# Append one JSON line to a room transcript, under that room's own lock.
append_room_line() {
  local room="$1" payload="$2"
  local f="$ROOMS_DIR/$room.jsonl"
  mkdir -p "$ROOMS_DIR"
  (
    flock -w 5 201 || exit 1
    printf '%s\n' "$payload" >> "$f"
  ) 201>"$f.lock"
}

# Generic field getter: session_field <sid> <dotted-path>, e.g. '.review.turn'.
# Prints empty for missing/null. Booleans/numbers print as literals ("false"
# stays distinguishable from absent — deliberately NOT `// empty`, which would
# swallow boolean false).
session_field() {
  jq -r --arg sid "$1" --arg path "$2" \
    '.sessions[] | select(.session_id == $sid)
     | getpath($path | ltrimstr(".") | split(".")) as $v
     | if $v == null then empty else ($v | tostring) end' \
    "$LOBBY_FILE"
}

# Live reviewers attached to a main, sorted by number. One "no<TAB>sid" per line.
# (Presence in lobby.json implies live: lobby_prune removes stale sessions.)
attached_reviewers() {
  jq -r --arg m "$1" '
    [.sessions[] | select(.role == "reviewer" and .main_sid == $m)]
    | sort_by(.reviewer_no)
    | .[] | "\(.reviewer_no)\t\(.session_id)"
  ' "$LOBBY_FILE"
}

# Smallest live reviewer_no attached to $1 that is strictly greater than $2.
# Prints nothing if none — the single source of truth for chain order, so dead
# reviewers are skipped consistently everywhere.
next_reviewer_no() {
  jq -r --arg m "$1" --argjson after "$2" '
    [.sessions[] | select(.role == "reviewer" and .main_sid == $m) | .reviewer_no]
    | map(select(. > $after)) | min // empty
  ' "$LOBBY_FILE"
}

# Estimate context usage percent from a session transcript: the last
# non-sidechain assistant entry's usage block (input + cache read + cache
# creation tokens) over LOBBY_CTX_LIMIT. Prints an integer percent, or NOTHING
# on any parse failure — callers must treat empty as "unknown, do nothing".
estimate_ctx_pct() {
  local tp="$1" limit="${LOBBY_CTX_LIMIT:-200000}" used
  [[ -n "$tp" && -f "$tp" ]] || return 0
  used=$(tail -n 300 "$tp" 2>/dev/null | jq -rs '
    [ .[]? | select(.isSidechain != true) | .message? | objects | .usage? | objects ]
    | last // empty
    | ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0))
  ' 2>/dev/null)
  [[ "$used" =~ ^[0-9]+$ ]] || return 0
  printf '%d' $(( used * 100 / limit ))
}

# Advance a main's review chain past reviewer number $2 (0 = start of round).
# If a live reviewer is next, point review.turn at it; otherwise finalize the
# round from the verdicts recorded so far:
#   - any request_changes, round < max   -> changes_requested
#   - any request_changes, round >= max  -> escalated
#   - at least one approve, no RC        -> approved
#   - no verdicts, live reviewers exist  -> restart the round at the lowest
#     live reviewer (every voter died mid-round; approving a milestone nobody
#     reviewed would be silent auto-approval)
#   - no verdicts and no reviewers left  -> idle   (review aborted)
# Caller holds $LOBBY_LOCK. Posts a system line to the review room on finalize.
review_advance() {
  local main_sid="$1" after_no="$2"
  local next now_iso
  now_iso=$(date -Iseconds)
  next=$(next_reviewer_no "$main_sid" "$after_no")
  if [[ -n "$next" ]]; then
    lobby_write '
      .sessions |= map(
        if .session_id == $sid then .review.turn = ($next | tonumber) else . end
      )
    ' --arg sid "$main_sid" --arg next "$next"
    return 0
  fi
  local verdict_summary room round maxr approves rcs new_status head lowest
  room=$(session_field "$main_sid" '.review.room_id')
  round=$(session_field "$main_sid" '.review.round')
  [[ "$round" =~ ^[0-9]+$ ]] || round=1
  maxr=$(session_field "$main_sid" '.review.max_rounds')
  [[ "$maxr" =~ ^[0-9]+$ ]] || maxr=5
  approves=$(jq -r --arg sid "$main_sid" --argjson r "$round" '
    [.sessions[] | select(.session_id == $sid) | .review.findings // [] | .[]
     | select(.round == $r and .verdict == "approve")] | length' "$LOBBY_FILE")
  rcs=$(jq -r --arg sid "$main_sid" --argjson r "$round" '
    [.sessions[] | select(.session_id == $sid) | .review.findings // [] | .[]
     | select(.round == $r and .verdict == "request_changes")] | length' "$LOBBY_FILE")

  if [[ "$rcs" -gt 0 ]]; then
    if [[ "$round" -ge "$maxr" ]]; then new_status="escalated"; else new_status="changes_requested"; fi
  elif [[ "$approves" -gt 0 ]]; then
    new_status="approved"
  else
    lowest=$(next_reviewer_no "$main_sid" 0)
    if [[ -n "$lowest" ]]; then
      # Zero verdicts but reviewers are attached: restart the round.
      lobby_write '
        .sessions |= map(
          if .session_id == $sid then .review.turn = ($next | tonumber) else . end
        )
      ' --arg sid "$main_sid" --arg next "$lowest"
      if [[ -n "$room" ]]; then
        append_room_line "$room" "$(jq -nc --arg ts "$now_iso" \
          --arg t "round $round restarted at R$lowest (all verdicts were lost)" \
          '{system: true, text: $t, ts: $ts}')"
      fi
      return 0
    fi
    new_status="idle"
  fi

  # On approval the baseline advances to the approved HEAD now, while main is
  # still blocked in its wait loop — at the NEXT request HEAD would already
  # contain the next milestone's commits.
  head=$(git -C "$LOBBY_ANCHOR" rev-parse HEAD 2>/dev/null || true)
  lobby_write '
    .sessions |= map(
      if .session_id == $sid then
        .review.status = $new_status
        | .review.turn = null
        | .review.notified = false
        | (if $new_status == "approved" and $head != ""
           then .review.baseline_ref = $head else . end)
      else . end
    )
  ' --arg sid "$main_sid" --arg new_status "$new_status" --arg head "$head"
  if [[ -n "$room" ]]; then
    case "$new_status" in
      approved)          verdict_summary="round $round: APPROVED by all reviewers" ;;
      changes_requested) verdict_summary="round $round: changes requested — main must fix and re-request" ;;
      escalated)         verdict_summary="round $round: still not approved at max rounds — escalated to human" ;;
      idle)              verdict_summary="round $round: aborted (no reviewers left)" ;;
      *)                 verdict_summary="round $round: completed ($new_status)" ;;
    esac
    append_room_line "$room" "$(jq -nc --arg ts "$now_iso" --arg t "$verdict_summary" \
      '{system: true, text: $t, ts: $ts}')"
  fi
}

# If a main's review is in_review but review.turn points at a reviewer number
# with no live attached session, advance past it (or finalize). Idempotent;
# caller holds $LOBBY_LOCK.
review_self_heal() {
  local main_sid="$1" status turn alive
  status=$(session_field "$main_sid" '.review.status')
  [[ "$status" == "in_review" ]] || return 0
  turn=$(session_field "$main_sid" '.review.turn')
  [[ "$turn" =~ ^[0-9]+$ ]] || return 0
  alive=$(jq -r --arg m "$main_sid" --argjson n "$turn" '
    [.sessions[] | select(.role == "reviewer" and .main_sid == $m and .reviewer_no == $n)] | length
  ' "$LOBBY_FILE")
  [[ "$alive" -gt 0 ]] && return 0
  review_advance "$main_sid" "$turn"
}

# End-of-turn release for session $1: clear claims and foreign anchors, notify
# queued waiters, mark the session idle. Called by stop-gate.sh only when it
# actually lets the session stop — a blocked session keeps its claims. Takes
# the lobby lock itself; must NOT be called while holding it.
lobby_stop_release() {
  local sid="$1" now now_iso anchors
  now=$(date +%s)
  now_iso=$(date -Iseconds)
  anchors=$(
    (
      flock -w 5 200 || exit 0
      jq -r --arg sid "$sid" '
        (.sessions[]? | select(.session_id == $sid) | .anchors // []) | .[]
      ' "$LOBBY_FILE"
      lobby_write "$LOBBY_JQ_DEFS"'
        ((.sessions[] | select(.session_id == $sid) | .claims) // []) as $freed
        | .sessions |= map(
          if .session_id == $sid
          then .claims = []
               | .anchors = []
               | .state = "idle"
               | .last_seen = $now_iso
               | .last_seen_epoch = ($now | tonumber)
          else . end
        )
        | notify_waiters($freed; $reason; $now_iso)
      ' --arg sid "$sid" --argjson now "$now" --arg now_iso "$now_iso" \
        --arg reason "(released by ${sid:0:8})"
    ) 200>"$LOBBY_LOCK"
  )
  while IFS= read -r anchor; do
    [[ -n "$anchor" ]] && lobby_release_anchor "$sid" "$anchor" clear
  done <<<"$anchors"
  return 0
}

# Print any new room messages for $1 (session_id) and advance their room_cursor.
# Outputs the rendered text on stdout (empty if nothing new). Caller holds $LOBBY_LOCK.
# Requires $LOBBY_FILE, $LOBBY_DIR.
room_deliver_new() {
  local sid="$1"
  local rooms_dir="$LOBBY_DIR/rooms"
  local room cursor f total
  room=$(jq -r --arg sid "$sid" '.sessions[] | select(.session_id == $sid) | .room_id // ""' "$LOBBY_FILE")
  [[ -z "$room" ]] && return 0
  f="$rooms_dir/$room.jsonl"
  [[ -f "$f" ]] || return 0
  cursor=$(jq -r --arg sid "$sid" '.sessions[] | select(.session_id == $sid) | .room_cursor // 0' "$LOBBY_FILE")
  total=$(wc -l < "$f")
  if [[ "$total" -gt "$cursor" ]]; then
    # Render undelivered lines, skipping this session's own messages. `say`
    # deliberately does NOT advance the cursor (doing so could skip over a
    # concurrent message from the other member); own lines pass through here
    # and are filtered out at render time instead.
    local rendered
    rendered=$(tail -n +"$((cursor + 1))" "$f" | jq -r --arg sid "$sid" '
      select((.from_full // "") != $sid)
      | if .system == true then "  [system] " + .text
        else "  " + .from_short + ": " + .text end
    ')
    if [[ -n "$rendered" ]]; then
      printf '[ROOM %s] new messages (use `%s/room.sh say --session %s --text "..."` to reply, or `room.sh leave --session %s` to exit):\n%s' "$room" "$LOBBY_BIN" "$sid" "$sid" "$rendered"
    fi
    lobby_write '
      .sessions |= map(if .session_id == $sid then .room_cursor = ($n | tonumber) else . end)
    ' --arg sid "$sid" --argjson n "$total"
  fi
}

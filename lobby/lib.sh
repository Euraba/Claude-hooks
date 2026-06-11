#!/usr/bin/env bash
# Sourced by lobby hook scripts. Provides shared state + helpers.

set -uo pipefail

STALE_AFTER_SEC="${LOBBY_STALE_AFTER_SEC:-1800}"

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

# Debug log so we can see if hooks are firing across sessions.
{
  printf '[%s] %s pid=%s ppid=%s cwd=%s CLAUDE_PROJECT_DIR=%s anchor=%s\n' \
    "$(date -Iseconds)" "$0" "$$" "$PPID" "$PWD" "${CLAUDE_PROJECT_DIR:-UNSET}" "$LOBBY_ANCHOR"
} >> /tmp/lobby-hook-debug.log 2>/dev/null || true

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

# Drop sessions whose last_seen_epoch is older than STALE_AFTER_SEC, then
# collect room transcripts left with no members. Caller holds lock.
lobby_prune() {
  local now
  now=$(date +%s)
  lobby_write '.sessions |= map(select(((.last_seen_epoch // 0) | tonumber) > ($now - $ttl)))' \
    --argjson now "$now" --argjson ttl "$STALE_AFTER_SEC"
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
    mtime=$(stat -c %Y "$f" 2>/dev/null) || continue
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
  local file="$dir/lobby.json" lock="$dir/lobby.lock" tmp
  [[ -f "$file" ]] || return 0
  (
    flock -w 5 200 || exit 0
    tmp=$(mktemp "$dir/.lobby.XXXXXX") || exit 0
    if jq --arg sid "$sid" --arg mode "$mode" '
         if $mode == "remove"
         then .sessions |= map(select(.session_id != $sid))
         else .sessions |= map(if .session_id == $sid then .claims = [] else . end)
         end
       ' "$file" > "$tmp"; then
      mv "$tmp" "$file"
    else
      rm -f "$tmp"
    fi
  ) 200>"$lock"
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
      printf '[ROOM %s] new messages (use `~/.claude/hooks/lobby/room.sh say --session %s --text "..."` to reply, or `room.sh leave --session %s` to exit):\n%s' "$room" "$sid" "$sid" "$rendered"
    fi
    lobby_write '
      .sessions |= map(if .session_id == $sid then .room_cursor = ($n | tonumber) else . end)
    ' --arg sid "$sid" --argjson n "$total"
  fi
}

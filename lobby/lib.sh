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

# Drop sessions whose last_seen_epoch is older than STALE_AFTER_SEC. Caller holds lock.
lobby_prune() {
  local now
  now=$(date +%s)
  lobby_write '.sessions |= map(select(((.last_seen_epoch // 0) | tonumber) > ($now - $ttl)))' \
    --argjson now "$now" --argjson ttl "$STALE_AFTER_SEC"
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
    local rendered
    rendered=$(tail -n +"$((cursor + 1))" "$f" | jq -r '
      if .system == true then "  [system] " + .text
      else "  " + .from_short + ": " + .text end
    ')
    printf '[ROOM %s] new messages (use `~/.claude/hooks/lobby/room.sh say --session %s --text "..."` to reply, or `room.sh leave --session %s` to exit):\n%s' "$room" "$sid" "$sid" "$rendered"
    lobby_write '
      .sessions |= map(if .session_id == $sid then .room_cursor = ($n | tonumber) else . end)
    ' --arg sid "$sid" --argjson n "$total"
  fi
}

#!/usr/bin/env bash
# Idempotent installer for the Claude Code lobby hooks.
#
# - Verifies dependencies (jq, flock, git).
# - Registers the seven lobby hooks in ~/.claude/settings.json, replacing any
#   previous lobby entries and preserving all other settings/hooks. A
#   timestamped backup of settings.json is written first.
# - Installs the /btw, /room, /mission, /review-request, /review-status and
#   /handoff slash commands into ~/.claude/commands/, rewritten to point at
#   this clone of the repo.
#
# Safe to re-run after moving the repo or pulling updates.
# Override the config dir with CLAUDE_CONFIG_DIR (default: ~/.claude).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOBBY="$REPO_DIR/lobby"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
COMMANDS_DIR="$CLAUDE_DIR/commands"

missing=()
for dep in jq flock git; do
  command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
done
if (( ${#missing[@]} > 0 )); then
  echo "install.sh: missing dependencies: ${missing[*]}" >&2
  [[ "$(uname)" == "Darwin" ]] && echo "  on macOS: brew install ${missing[*]}" >&2
  exit 1
fi

mkdir -p "$CLAUDE_DIR" "$COMMANDS_DIR"

# --- hooks in settings.json --------------------------------------------------
[[ -s "$SETTINGS" ]] || printf '{}\n' > "$SETTINGS"
if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
  echo "install.sh: $SETTINGS is not valid JSON; fix it and re-run" >&2
  exit 1
fi
backup="$SETTINGS.bak.$(date +%s)"
cp "$SETTINGS" "$backup"

# For each event: drop entries that point at a lobby script (idempotence /
# repo moves), keep everything else, then append ours. Hook timeout is 10s,
# comfortably above the scripts' internal 5s lock wait.
tmp=$(mktemp "$CLAUDE_DIR/.settings.XXXXXX")
jq --arg lobby "$LOBBY" '
  def drop_lobby: (. // []) | map(select(
    any(.hooks[]?; (.command // "") | contains("/lobby/")) | not
  ));
  def entry($script): {hooks: [{type: "command", command: ($lobby + "/" + $script), timeout: 10}]};
  def entry($script; $matcher): entry($script) + {matcher: $matcher};
  .hooks = (.hooks // {})
  | .hooks.SessionStart     = ((.hooks.SessionStart     | drop_lobby) + [entry("register.sh")])
  | .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit | drop_lobby) + [entry("inject.sh")])
  | .hooks.PreToolUse       = ((.hooks.PreToolUse       | drop_lobby) + [entry("claim.sh"; "Edit|Write|MultiEdit|NotebookEdit")])
  | .hooks.PostToolUse      = ((.hooks.PostToolUse      | drop_lobby) + [entry("post-edit-inbox.sh")])
  | .hooks.Stop             = ((.hooks.Stop             | drop_lobby) + [entry("release.sh"), entry("stop-gate.sh")])
  | .hooks.SessionEnd       = ((.hooks.SessionEnd       | drop_lobby) + [entry("cleanup.sh")])
' "$SETTINGS" > "$tmp"
mv "$tmp" "$SETTINGS"

# --- slash commands -----------------------------------------------------------
for cmd in btw room mission review-request review-status handoff; do
  sed "s|~/.claude/hooks/lobby|$LOBBY|g" "$REPO_DIR/commands/$cmd.md" > "$COMMANDS_DIR/$cmd.md"
done

echo "Installed:"
echo "  hooks    -> $SETTINGS (backup: $backup)"
echo "  commands -> $COMMANDS_DIR/{btw,room,mission,review-request,review-status,handoff}.md"
echo
echo "Last step (manual): copy the 'Multi-session coordination' block from the"
echo "README into $CLAUDE_DIR/CLAUDE.md so agents know the protocol, then"
echo "restart any running Claude Code sessions."

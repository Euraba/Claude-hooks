---
description: Open a private chat room with another Claude session (invite/accept/say/leave/show/list)
allowed-tools: Bash
argument-hint: invite <short_id> [topic...] | accept <room_id> | say <text...> | leave | show | list
---

You are managing a private chat room with another active Claude session in this project. Rooms are append-only files under `<repo>/.claude/rooms/`. Membership is per-session; only members see room messages.

**Arguments**: `$ARGUMENTS`

The first token is the subcommand: `invite`, `accept`, `say`, `leave`, `show`, or `list`.

**Your own session short id** is shown in the most recent `UserPromptSubmit` injection (`You are session <short>.`). Pass that to `--session` / `--from` below. The script accepts a short id or a full id.

Steps by subcommand:

1. `invite <other_short_id> [topic words...]`
   Run: `~/.claude/hooks/lobby/room.sh invite --from <your_short> --to <target_short> --topic "<topic, if any>"`
   The script creates the room, sets your room_id, and sends the target a `[ROOM INVITE]` via the inbox. It prints the new `<room_id>`. Tell the user the room id so they can refer to it.

2. `accept <room_id>`
   Run: `~/.claude/hooks/lobby/room.sh accept --session <your_short> --room <room_id>`
   You then start seeing room messages via PostToolUse and UserPromptSubmit.

3. `say <message words...>`
   Run: `~/.claude/hooks/lobby/room.sh say --session <your_short> --text "<message>"`
   The other member sees it after their next tool call or next user prompt.

4. `leave`
   Run: `~/.claude/hooks/lobby/room.sh leave --session <your_short>`
   The room file is deleted when the last member leaves.

5. `show`
   Run: `~/.claude/hooks/lobby/room.sh show --session <your_short>`
   Prints the full transcript of your current room.

6. `list`
   Run: `~/.claude/hooks/lobby/room.sh list`
   Lists all active rooms and their members across the project.

Always report the script's output (or error) back to the user.

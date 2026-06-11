---
description: Send a side-channel message to another Claude session in this project (e.g. "will you modify method X in foo.ts?")
allowed-tools: Bash
argument-hint: <target_short_id|all> <message...>
---

You are sending a side-channel message to another active Claude session in this project via the lobby.

**Arguments**: `$ARGUMENTS`

The first whitespace-separated token is the target — either a session short id (e.g. `2fbe3510`) or the literal `all` to broadcast. Everything after the first token is the message text.

**Your own session short id** is shown in the most recent `UserPromptSubmit` injection (a line starting with `You are session <short>.`). If you do not see it, run `cat <repo_root>/.claude/lobby.json` and identify your entry by elimination.

**Steps**:

1. Parse `$ARGUMENTS` into `<target>` (first token) and `<message>` (remainder, trimmed).
2. If the message is empty, tell the user the format is `/btw <target> <message>` and stop.
3. Run, with your own short id (or full id) as `--from`:

   ```
   ~/.claude/hooks/lobby/btw.sh send --from <your_short_id> --to <target> --text "<message>"
   ```

4. Report success or the error from the script, in one line. Do not summarize the message itself.

After running, the recipient session(s) will see your message in their next `UserPromptSubmit` injection under `[INBOX]`. They clear it via `~/.claude/hooks/lobby/btw.sh ack --session <their_id>`.

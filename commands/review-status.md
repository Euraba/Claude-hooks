---
description: Show the lobby review state (round, turn, findings) for main sessions
allowed-tools: Bash
argument-hint: [main_short_id]
---

Show the review state machine for this project's main session(s).

**Arguments**: `$ARGUMENTS`

Run `~/.claude/hooks/lobby/review.sh status` — append `--session <short_id>` if the user named a specific session (a reviewer's id resolves to its main). Report the output verbatim in a code block.

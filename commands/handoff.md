---
description: Voluntarily hand this main session off to its heir reviewer (context-overflow succession)
allowed-tools: Bash, Write
argument-hint: (no arguments)
---

You are voluntarily handing off this MAIN session: your lowest-numbered reviewer will be promoted to main and continue the work from your brief. (The same flow triggers automatically when your context crosses the handoff threshold.)

Steps:

1. Write a thorough handoff brief to `<repo>/.claude/handoffs/<your_short_id>-handoff.md` covering: current state of the work, in-flight/unfinished tasks, the mission goal and spec/plan paths, key decisions made so far, exact next steps, and the current review status.
2. Run: `~/.claude/hooks/lobby/succession.sh handoff --session <your_full_or_short_id> --brief <that path>`
3. Report the script's output. After a successful handoff you are **retired**: do not start new work; tell the user the heir's short id and that the heir continues from your brief.

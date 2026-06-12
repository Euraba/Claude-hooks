---
description: Voluntarily hand this main session off to its lowest-numbered reviewer
allowed-tools: Bash, Write
argument-hint: [reason]
---

Hand off this main session now (without waiting for the context threshold). Reason given: "$ARGUMENTS"

**Steps**:

1. Write a handoff brief to `<repo>/.claude/handoffs/<your-short-id>-handoff.md` covering: current state of the work, in-flight/unfinished tasks, mission goal and spec/plan paths, key decisions made, exact next steps, and current review status.
2. Run:

   ```
   ~/.claude/hooks/lobby/succession.sh handoff --session <your-session-id> --brief <that-path>
   ```

3. Your lowest-numbered reviewer is promoted to main and receives the brief through its wait loop. Tell the user the handoff is complete and stop — your Stop hook will show them the details.

If there are no reviewers attached, the script will say so; in that case there is nobody to promote and you should wrap up normally instead.

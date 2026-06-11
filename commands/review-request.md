---
description: Declare a milestone done and start a review round with your attached reviewers
allowed-tools: Bash
argument-hint: <summary of what you did>
---

You finished a milestone (spec, plan, or working code) and want your reviewers to review it: "$ARGUMENTS"

**Steps**:

1. COMMIT your work first. Reviewers diff against the recorded baseline, and uncommitted work makes that diff misleading.
2. Run:

   ```
   ~/.claude/hooks/lobby/review.sh request --session <your-session-id> --summary "$ARGUMENTS"
   ```

3. Then run `~/.claude/hooks/lobby/review-wait.sh --session <your-session-id>` repeatedly and obey its output until the round resolves (approved / changes requested). Do not start new work while the round is open.

If it reports there are no reviewers attached, tell the user how to attach one (`LOBBY_ROLE=reviewer:1 LOBBY_MAIN=<your-short-id> claude`) and continue without review.

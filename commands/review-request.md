---
description: Declare a finished milestone for review by your attached reviewer sessions (main role only)
allowed-tools: Bash
argument-hint: <summary of what you did...>
---

You are requesting a review round from the reviewer sessions attached to you in the lobby.

**Arguments**: `$ARGUMENTS` — a one-line summary of the milestone you finished.

Steps:

1. Make sure the work is **committed** (`git status` clean) — reviewers diff the recorded baseline against `HEAD`. Commit first if needed.
2. Run: `~/.claude/hooks/lobby/review.sh request --session <your_short_id> --summary "<summary>"`
3. Obey the script's output: run `~/.claude/hooks/lobby/review-wait.sh --session <your_short_id>` repeatedly and follow what it prints until the round resolves (approved or changes requested). Do not start new work while the round is open.

If reviewers request changes, your Stop hook will keep you in the fix→re-request loop until they approve; the user is notified automatically on approval or escalation.

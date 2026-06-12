---
description: Set this main session's mission (goal, spec, plan) for its reviewers
allowed-tools: Bash
argument-hint: <goal text>
---

You are a MAIN session in the lobby's main/reviewer workflow, registering your mission so your reviewers know what to judge against.

**Arguments**: `$ARGUMENTS` — the goal text.

**Your own session id** is shown in injected context (a line starting with `You are session <short>.` or `[LOBBY ROLE] You are session <short>`).

**Steps**:

1. Run:

   ```
   ~/.claude/hooks/lobby/mission.sh set --session <your-session-id> --goal "$ARGUMENTS"
   ```

2. If a spec or plan document exists (or when you create one later), re-run with `--spec <path>` and/or `--plan <path>` so reviewer R1 can read them.
3. Report the recorded mission in one line.

Setting the mission also records the review baseline (current `HEAD`) that reviewers diff against — do this BEFORE starting milestone work, or round-1 reviewers will see an empty diff.

---
description: Set or show your main session's mission (goal + optional spec/plan) for the lobby review loop
allowed-tools: Bash
argument-hint: <goal text...> | show
---

You are managing this session's mission in the lobby main/reviewer workflow. The mission is what your attached reviewers judge milestones against.

**Arguments**: `$ARGUMENTS`

**Your own session short id** is shown in injected context (`You are session <short>.`).

- If the arguments are `show` (or empty), run: `~/.claude/hooks/lobby/mission.sh show`
- Otherwise treat the full arguments as the goal text and run:
  `~/.claude/hooks/lobby/mission.sh set --session <your_short_id> --goal "<arguments>"`
  If you maintain a spec or plan document for this work, pass them too via `--spec <abs path>` / `--plan <abs path>`.

Report the script's output back in one line. Setting a mission records the review **baseline** (current `HEAD`) that reviewers will diff against.

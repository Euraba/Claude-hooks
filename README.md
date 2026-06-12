# Claude Code Lobby — multi-session coordination hooks

A set of Bash hooks that let **multiple concurrent Claude Code sessions working in the
same project coordinate with each other** — so two agents don't silently stomp on the
same files, and can ask each other questions or hold a side conversation.

Everything is plain Bash + [`jq`](https://jqlang.github.io/jq/) + `flock`. There is no
daemon and no network: sessions communicate through a single JSON file
(`<repo>/.claude/lobby.json`) and append-only room transcripts under
`<repo>/.claude/rooms/`, all guarded by a file lock. Lock acquisitions time out after
5 seconds and fail open — coordination is advisory, so a wedged lock degrades to "no
coordination this turn" rather than stalling every hook and tool call.

## What it does

- **Presence** — every session registers itself on start and heartbeats each turn, so
  each agent can see who else is in the project and whether each session is currently
  `active` (mid-turn) or `idle` (waiting on its user).
- **File claims** — when an agent is about to `Edit`/`Write` a file, that file is claimed
  for the current turn. If another live session already holds the claim, the edit is
  **denied** with a reason telling the agent who holds it, that session's posted intent
  and activity state, and how to ask it about the file.
- **Claim queueing** — a denied session is queued automatically and receives an inbox
  notification the moment the file is released (turn end, session end, or stale-prune),
  so it can continue other work instead of retrying blind.
- **Intent notes** — an agent can post a one-line "what I'm working on", a plan path, and
  the files it expects to touch, which surfaces to other sessions.
- **`/btw` inbox messaging** — fire-and-forget questions to one session or all sessions.
- **`/room` private rooms** — a shared append-only transcript for sustained back-and-forth
  between two (or more) sessions.
- **Main/reviewer orchestration** — a role layer for autonomous review loops: a **main**
  session writes specs/code, 1–3 attached **reviewer** sessions review each milestone in
  a shared review room, main fixes findings until all approve, and when main's context
  runs low it hands off to a reviewer that is promoted in its place. See
  [Main/reviewer orchestration](#mainreviewer-orchestration) below.

All cross-session text reaches an agent by being **injected into its context** — at the
start of each turn (`UserPromptSubmit`) and after every tool call (`PostToolUse`), so
questions reach a working session mid-execution and a conversation can progress without
either side ending its turn.

## Install

```bash
git clone <repo-url> ~/.claude/hooks   # or anywhere you like
~/.claude/hooks/install.sh
```

`install.sh` is idempotent (safe to re-run after pulling updates or moving the repo). It:

1. Checks dependencies (`jq`, `flock`, `git`).
2. Registers the six hooks in `~/.claude/settings.json` — previous lobby entries are
   replaced, everything else is preserved, and a timestamped backup is written first.
3. Installs the `/btw`, `/room`, `/mission`, `/review-request`, `/review-status` and
   `/handoff` slash commands into `~/.claude/commands/`, rewritten to point at wherever
   you cloned the repo.

Then copy the [agent protocol block](#teach-your-agents-the-protocol) into your
`~/.claude/CLAUDE.md` and restart any running Claude Code sessions.

## How it's wired (hooks)

`install.sh` registers these scripts as Claude Code hooks in `~/.claude/settings.json`:

| Hook event        | Matcher                            | Script                | Role |
|-------------------|------------------------------------|-----------------------|------|
| `SessionStart`    | —                                  | `lobby/register.sh`   | Add this session to the lobby (on `compact`/`resume` the existing entry is preserved, heartbeat only). |
| `UserPromptSubmit`| —                                  | `lobby/inject.sh`     | Heartbeat, clear per-turn claims, inject inbox + other sessions' notes/claims + new room messages. |
| `PreToolUse`      | `Edit\|Write\|MultiEdit\|NotebookEdit` | `lobby/claim.sh`  | Deny edits from reviewers; claim the target file or deny if another session holds it. |
| `PostToolUse`     | — (all tools)                      | `lobby/post-edit-inbox.sh` | Heartbeat; deliver newly-arrived inbox / room messages mid-execution; warn a main nearing the handoff threshold. |
| `Stop`            | —                                  | `lobby/stop-gate.sh`  | Role gate: keep reviewers in their wait loop, keep a main working while findings are unresolved, trigger context-overflow succession. When it lets the session stop, it performs the end-of-turn release (claims, waiter notifications, idle state) — a blocked session keeps its claims. |
| `SessionEnd`      | —                                  | `lobby/cleanup.sh`    | Remove the session; delete rooms with no members left; notify the review room when a main ends. |

Supporting pieces:

- `lobby/lib.sh` — sourced by all of the above. Resolves the lobby anchor (git repo root,
  falling back to `CLAUDE_PROJECT_DIR`/cwd), provides atomic `jq` writes, stale-pruning, and
  room delivery.
- `lobby/note.sh` — CLI for intent notes (`set` / `clear` / `show`).
- `lobby/btw.sh` — CLI behind the `/btw` slash command (`send` / `inbox` / `ack` / `show`).
- `lobby/room.sh` — CLI behind the `/room` slash command (`invite` / `accept` / `say` /
  `leave` / `show` / `list`).
- `lobby/mission.sh` — CLI for a main's mission: goal text + spec/plan paths (`set` / `show`).
- `lobby/review.sh` — review state machine (`request` / `verdict` / `status` / `reset`).
- `lobby/review-wait.sh` — the polling wait loop that keeps reviewers (and a main waiting
  on a round) awake and returns work packets.
- `lobby/succession.sh` — promotes a reviewer to main on context-overflow handoff.
- `lobby/release.sh` — back-compat wrapper around the end-of-turn release for
  older hand-wired settings; `stop-gate.sh` is the Stop hook of record.

- `install.sh` — idempotent installer (hooks + slash commands).
- `commands/*.md` — the `/btw`, `/room`, `/mission`, `/review-request`, `/review-status`
  and `/handoff` slash commands, installed into `~/.claude/commands/`.
- `tests/smoke.sh` — end-to-end smoke test simulating two sessions across two repos.
- `tests/fake-flow.sh` — end-to-end exercise of the main/reviewer workflow with fake
  sessions (no real Claude needed).

## Main/reviewer orchestration

A role layer on top of the lobby that removes the human from the write→review→fix loop.
One **main** session does all the writing; up to three **reviewer** sessions are attached
to it (reviewer→main is 1:1, main→reviewers is 1:many). Reviewers are read-only: their
file edits are denied at `PreToolUse`, they review and talk in a shared review room.

### Launching

```bash
LOBBY_ROLE=main claude                                   # the main window
LOBBY_ROLE=reviewer:1 LOBBY_MAIN=<main-short-id> claude  # reviewer windows (slots 1-3)
```

The main's short id appears in its injected context (`You are session <short>`). All
reviewer slots are optional and explicitly numbered; the number picks the lens:

| Slot | Lens | Gets | Charge |
|------|------|------|--------|
| R1 | full context | goal + spec + plan | spec/plan compliance, completeness, design intent. **Designated heir** on succession. |
| R2 | goal-only | goal text only | does the result actually serve the goal? |
| R3 | blind | the diff only | code quality, readability, correctness in isolation. |

If there is no spec, the lenses degrade gracefully (R1 judges against the goal and
whatever artifacts exist). Soon after launch, main should register its mission:

```bash
<repo>/lobby/mission.sh set --session <sid> --goal "..." [--spec <path>] [--plan <path>]
```

(also `/mission`). This records the review **baseline** (current `HEAD`) that reviewers
diff against.

### The review loop

1. Main finishes a milestone (spec/plan/code), commits, and runs `/review-request "<summary>"`
   (`review.sh request`). This opens (or reuses) a review room with all attached
   reviewers and starts a round.
2. Reviewers review **sequentially in slot order**. Each gets a packet rendered for its
   lens (diff since baseline, its slice of the mission, earlier reviewers' findings this
   round to refute or extend) and records exactly one verdict:
   `review.sh verdict --verdict approve|request_changes --text "..."`.
3. When the last reviewer votes: all approve → **approved** (baseline advances, the human
   is notified via a `systemMessage`); any request-changes → **changes_requested** and
   main's Stop hook refuses to let it stop until it fixes the findings and re-requests
   (round + 1). At the round cap (`LOBBY_MAX_ROUNDS`, default 5) the loop **escalates**
   to the human instead of arguing forever (`review.sh reset` resumes it).

Approval requires at least one explicit `approve` verdict in the round — a round whose
verdicts were all lost (every voter died mid-round) restarts at the lowest live reviewer
instead of silently passing.

The whole loop is autonomous; the human only hears about it at approval or escalation.

### How reviewers stay awake

An idle Claude session fires no hooks, so reviewers run `review-wait.sh` in a loop via
the Bash tool: it heartbeats, polls lobby state, and returns a work packet (your turn to
review / you've been promoted / your main ended) or `NO_WORK` after `LOBBY_WAIT_TIMEOUT`
(default 90s), upon which the reviewer runs it again. The reviewer's Stop hook re-arms
the loop if the model ever drifts. **Trade-off:** reviewer windows are perpetually
mid-turn, costing a small constant token drip; `LOBBY_REVIEWER_MAX_IDLE_CYCLES`
(default 240 ≈ 6h of no work) releases them as a backstop.

Roled sessions are exempt from the normal 30-minute stale-prune and use their own much
longer TTL (`LOBBY_ROLE_STALE_SEC`, default 24h): a main legitimately sits idle while
the human is away, and pruning it would dissolve the whole orchestration. A crashed
main (no `SessionEnd`) is therefore detected by reviewers only via the idle-cycle cap.

### Context-overflow succession

Every time main stops, `stop-gate.sh` estimates context usage from the transcript's last
usage block. At ≥ `LOBBY_HANDOFF_PCT` (default 50%), main is blocked from stopping until
it (1) writes a handoff brief (state, in-flight work, decisions, next steps) to
`.claude/handoffs/` and (2) runs `succession.sh handoff`. In one transaction the
lowest-numbered reviewer becomes the new main (inheriting mission, review state, and
room), remaining reviewers re-attach to it, and the old main retires — its next stop
shows the human what happened and the exact command to attach a fresh reviewer on the
freed slot. The heir's wait loop delivers it the brief and it continues the work.
`/handoff` triggers the same flow voluntarily. If context usage falls back under the
threshold before the handoff happens (e.g. auto-compaction), the trigger un-latches and
the main carries on.

### Loop safety

Every Stop-block either moves the state machine toward a terminal state (approved,
escalated, retired, main-gone) or bumps a same-reason counter. A session that keeps
trying to stop without doing its job trips `LOBBY_MAX_SAME_BLOCKS` (default 3) and is
released with a `systemMessage` instead of spinning. The counter resets on evidence of
real progress — a successful file claim, a review request or verdict, or a wait-loop
wake that actually delivered work — so an honest main fixing findings across many turns
is never cut off, while an idle spinner is. A dead reviewer holding the review turn is
healed past automatically (`review_self_heal`), a `changes_requested` main whose last
reviewer died is released to the human instead of being blocked on an impossible
re-request, and the context estimate fails open (parse failure → no succession).

### Environment variables

| Var | Default | Meaning |
|-----|---------|---------|
| `LOBBY_ROLE` | — | `main` or `reviewer:1\|2\|3` at launch |
| `LOBBY_MAIN` | — | main session id (or prefix) a reviewer attaches to |
| `LOBBY_HANDOFF_PCT` | 50 | context % that triggers succession |
| `LOBBY_CTX_LIMIT` | 200000 | token denominator for the context estimate |
| `LOBBY_MAX_ROUNDS` | 5 | review rounds before escalating to the human |
| `LOBBY_WAIT_TIMEOUT` / `LOBBY_WAIT_INTERVAL` | 90 / 5 | review-wait return cadence (seconds) |
| `LOBBY_REVIEWER_MAX_IDLE_CYCLES` | 240 | NO_WORK cycles before a reviewer is released |
| `LOBBY_MAX_SAME_BLOCKS` | 3 | identical Stop-blocks before the gate gives up and escalates |
| `LOBBY_ROLE_STALE_SEC` | 86400 | stale-prune TTL for roled sessions (plain sessions: `LOBBY_STALE_AFTER_SEC`, 30 min) |

### Testing

`tests/fake-flow.sh` drives the whole flow (registration, lenses, chain order,
out-of-turn rejection, stop gating, succession, self-heal, escalation, fail-open
estimation) with fake sessions piping hook JSON into the scripts — no real Claude
sessions needed. For a live test, use three terminals (main + R1 + R2) and force
succession cheaply with `LOBBY_HANDOFF_PCT=1`.

## Data model

State lives at `<lobby-anchor>/.claude/lobby.json`, where the anchor is the enclosing git
repo root (so sessions launched at different depths in the same repo share state):

```jsonc
{
  "sessions": [
    {
      "session_id": "2fbe3510-…",      // full id; short id = first 8 chars
      "started_at": "2026-05-29T…",
      "last_seen": "…",
      "last_seen_epoch": 1748…,         // used for stale-pruning
      "claims": ["/abs/path/a.ts"],     // files held THIS turn; cleared on Stop
      "anchors": ["/other/repo"],       // foreign repo roots this session claimed files in
      "state": "active",                // "active" = mid-turn; "idle" = waiting on its user
      "note": "refactoring auth",       // optional intent
      "plan_path": "…",                 // optional
      "planned_files": ["/abs/…"],      // optional
      "inbox": [                         // /btw messages addressed to this session
        { "from_short": "…", "from_full": "…", "text": "…",
          "sent_at": "…", "delivered_at": null }
      ],
      "room_id": "r-ab12…",             // current room, if any
      "room_cursor": 3,                  // # of room lines already delivered

      // role layer (absent on plain sessions — legacy behavior unchanged)
      "role": "main",                    // "main" | "reviewer" | "retired"
      "reviewer_no": 1,                  // reviewers only (1..3)
      "main_sid": "…",                   // reviewers only: full sid of their main
      "mission": {                       // main only
        "goal": "ship the widget", "spec_path": null, "plan_path": null
      },
      "review": {                        // main only — the review state machine
        "status": "in_review",           // idle|in_review|changes_requested|approved|escalated
        "round": 2, "max_rounds": 5,
        "room_id": "r-rev-…",            // persistent review room
        "baseline_ref": "<sha>",         // reviewers diff against this; advances on approval
        "summary": "…", "turn": 2,       // reviewer_no whose turn it is (null between rounds)
        "requested_at": "…", "notified": false,
        "findings": [                    // structured verdicts (prose lives in the room)
          { "round": 1, "reviewer_no": 1, "verdict": "request_changes", "text": "…", "at": "…" }
        ]
      },
      "handoff": {                       // set on a main once succession starts
        "status": "pending",             // pending|done
        "brief_path": "…", "notified": false,
        "heir_sid": "…", "freed_no": 1   // recorded at promotion
      },
      "handoff_brief_in": "…",           // on the promoted heir until its wait loop consumes it
      "idle_cycles": 0,                  // reviewer NO_WORK counter (idle release cap)
      "stop_blocks": 0,                  // same-reason Stop-block counter (loop safety)
      "stop_block_sig": "…"
    }
  ],
  "waiters": [                           // claim queue: notified via inbox on release
    { "sid": "…", "path": "/abs/…", "queued_at": "…" }
  ]
}
```

Handoff briefs live in `<lobby-anchor>/.claude/handoffs/`; review rooms are ordinary
room transcripts named `r-rev-*` under `.claude/rooms/`.

- `<lobby-anchor>/.claude/lobby.lock` — `flock` target serializing all writes.
- `<lobby-anchor>/.claude/rooms/<room_id>.jsonl` — append-only room transcript (one JSON
  object per line), with its own `.lock`.

Claims are **per-turn** (cleared on `Stop` and at the next `UserPromptSubmit`), representing
"actively editing right now". A claim on a file in a *different* git repo than the session's
home anchor is recorded in that repo's lobby; the foreign repo root is tracked in `anchors`
on the home entry so `Stop`/`SessionEnd` release those claims too. A session denied a claim
is queued under `waiters` and gets a `[CLAIM FREED]` inbox notification when the path is
released, whichever way that happens. Notes/inbox/room membership are **per-session** and
persist until `SessionEnd` or stale-prune (default 30 min idle, `LOBBY_STALE_AFTER_SEC`).

## Usage (from inside a session)

The agent's own short id is shown in injected context as `You are session <short>.`. Pass the
**full** id to the scripts where possible (short ids resolve by unique prefix).

```bash
# Post intent so other sessions know what you're touching
~/.claude/hooks/lobby/note.sh set --session <sid> \
  --note "refactoring the auth module" \
  --files "/abs/path/auth.ts,/abs/path/login.ts"

# Ask another session a question (or broadcast with `all`)
/btw <other_short_id> Will you modify parseToken() in auth.ts?

# Acknowledge / clear your inbox after handling messages (only messages already
# shown to you are removed; ones that arrived since stay queued)
~/.claude/hooks/lobby/btw.sh ack --session <sid>

# Open a private room for sustained discussion
/room invite <other_short_id> auth-refactor
/room accept <room_id>
/room say <message>
/room leave
```

Inspect state manually:

```bash
~/.claude/hooks/lobby/note.sh show     # all sessions' notes/claims
~/.claude/hooks/lobby/btw.sh  show     # all inboxes
~/.claude/hooks/lobby/room.sh list     # active rooms and members
```

## Teach your agents the protocol

The hooks inject presence and messages into context, but agents also need standing
instructions: when to post intent notes, how to answer `[INBOX]` messages, room
etiquette. Copy this block into your `~/.claude/CLAUDE.md` (adjust the paths if you
cloned the repo somewhere other than `~/.claude/hooks`):

```markdown
## Multi-session coordination (lobby)

When `UserPromptSubmit` context tells you another Claude session is active in this
project (look for `You are session <short>. Other active Claude sessions...`), before
starting non-trivial work, post your intent so the other session can see what you're
touching:

    ~/.claude/hooks/lobby/note.sh set --session <your-full-session-id> \
      --note "<one-line intent>" \
      --plan "<path to your plan file, if any>" \
      --files "<comma-separated abs paths you expect to touch>"

- Your **short** id appears in the injection; pass the **full** session id to
  `--session`. If unknown, check `<repo>/.claude/lobby.json` for the entry whose
  short id matches.
- Re-post (overwrite) when scope changes. The note auto-clears on SessionEnd or
  after 30min idle.
- Clear early when done: `note.sh clear --session <sid>`.
- Skip for trivial edits (typos, one-file fixes unlikely to overlap).
- Inspect all sessions' notes: `~/.claude/hooks/lobby/note.sh show`.

### Asking another session a question (/btw)

If a file Edit/Write is denied because another session has claimed the file (the
`PreToolUse` deny reason mentions a session short id), do NOT just give up — you
are queued automatically and will get an `[INBOX]` notification when the file is
freed, so continue other work in the meantime. If you need an answer sooner, use
`/btw` to ask the holding session what it intends:

    /btw <other_short_id> Will you modify <method/symbol> in <file>? I need to <reason>.

- Targets a single session by short id, or `all` to broadcast.
- The recipient sees your message under `[INBOX]` after their next tool call
  (mid-execution) or at their next `UserPromptSubmit`. If you can usefully keep
  working while you wait, do — the reply reaches you the same way, after one of
  your own tool calls.
- When you receive a message under `[INBOX]`, answer briefly right away (with
  `/btw <sender_short_id> ...`) and then CONTINUE your current task — replying
  does not require stopping your work. Clear your inbox using the exact ack
  command shown in the injection.
- Inspect any session's inbox manually: `~/.claude/hooks/lobby/btw.sh show`.

### Private rooms (/room)

For sustained back-and-forth (more than one or two `/btw` exchanges), open a
private room. Each room is a shared append-only transcript; only members see it.
Delivery is the same as inbox: at `UserPromptSubmit` and after every tool call.

- `/room invite <other_short_id> [topic]` (creates the room, sends an inbox invite)
- Recipient: `/room accept <room_id>` (room id is in the `[ROOM INVITE]` message)
- Either side: `/room say <message>` to send, `/room show` for the transcript,
  `/room leave` when done.
- One room per session at a time. Room files auto-delete when the last member
  leaves or SessionEnd fires.
- When you see a `[ROOM …] new messages` block in injected context, reply with
  `/room say …` and don't ack via `btw.sh ack` (rooms have their own delivery
  state, separate from the inbox).
```

## Requirements

- Bash, `jq`, `flock`, `git`, and standard coreutils (`date`, `mktemp`, `od`, `wc`, …).
- Linux works out of the box. macOS needs `flock` (`brew install flock`); the GNU/BSD
  differences in `stat` and `realpath` are handled internally.
- Claude Code with hook support, and `CLAUDE_PROJECT_DIR` set (the hooks no-op without it).

Debugging: set `LOBBY_DEBUG_LOG=/some/path` to log every hook invocation (off by default).

---

## Known limitations

- **No true mutual exclusion against races.** Although every write holds an `flock`, the
  *check* in a slash command (resolve id, read state) and the *act* (the model's actual edit)
  span multiple process invocations. Claims reduce accidental overlap; they are advisory
  coordination, not a hard lock — a determined or out-of-band write can still collide.
- **Claims are coarse, file-level, and per-turn.** Two agents editing *different functions in
  the same file* can't both proceed: the second is denied outright. Conversely, a claim is
  released at `Stop`, so a long multi-turn edit on one file is unprotected between turns.
- **Delivery is poll-based, not push.** Messages surface after the recipient's next tool call
  or at its next `UserPromptSubmit`. A session that is idle (waiting on the user, not running
  tools) will not see an inbox/room message until it acts again.
- **Short-id (8-char prefix) collisions are unhandled.** `resolve_sid` returns empty on an
  ambiguous prefix, so commands silently fail to target rather than erroring helpfully. UUID
  prefixes make this unlikely but not impossible.
- **Stale state can linger or vanish early.** Pruning is lazy (only runs when some hook fires)
  and time-based. A crashed session lingers until another session triggers a prune; a session
  idle for >30 min is pruned even if still alive, dropping its claims/notes/room membership.
- **Best-effort cleanup.** `SessionEnd`/`Stop` may not fire on a hard crash or `kill -9`,
  leaving orphaned claims and inbox entries until stale-prune (which also garbage-collects
  room transcripts left with no members).
- **Same-host only.** Relies on `flock` and same-host filesystem semantics; it will not
  coordinate across machines or over a network share.
- **No schema versioning or migration.** A malformed `lobby.json` is silently reset to empty
  by `lobby_init`, discarding all live state. There is no version field to evolve the format.
- **Unbounded growth within a session.** Inboxes grow until `ack`; room transcripts grow
  until the last member leaves. No size cap, rotation, or truncation.
- **No authentication or privacy boundary.** Any process that can write the repo's `.claude/`
  can post as any session, read every inbox, and read any room transcript. "Private" rooms are
  private only by convention.
- **Hidden truncation in injection.** Long notes / many planned files are injected verbatim
  with no length budget, which can crowd the agent's context on busy projects.
- **Reviewer "read-only" is enforced only for the edit tools.** The `PreToolUse` deny covers
  `Edit|Write|MultiEdit|NotebookEdit`; a reviewer could still write files through `Bash`
  (`echo > file`, `sed -i`, …). Reviewers are cooperative agents instructed not to edit, so
  this is a guardrail, not a security boundary.
- **The review room occupies the single `room_id` slot.** A main or reviewer in the
  review flow can't simultaneously hold an ad-hoc `/room`; a parallel cursor slot is the
  future fix if it bites.
- **Reviewer wake-up is a polling loop, not push.** Reviewer windows stay perpetually
  mid-turn running `review-wait.sh`; cost is a small token drip, bounded by the idle cap.
- **A crashed main is detected slowly.** Roled sessions are exempt from the 30-min prune
  (`LOBBY_ROLE_STALE_SEC` defaults to 24h), so if a main dies without `SessionEnd`, its
  reviewers keep polling until their idle-cycle cap releases them.

## Plans to improve

- **Sub-file / symbol-level claims** — let agents claim a function or line range instead of a
  whole file, so non-overlapping work in one file can proceed concurrently.
- **Optional sticky claims** — a flag to hold a claim across turns for long edits, with an
  explicit release, instead of always dropping at `Stop`.
- **Lease/TTL on claims** — per-claim expiry independent of the session heartbeat, so a stuck
  turn can't hold a file indefinitely.
- **Better ambiguity handling** — when a short-id prefix is ambiguous, list the candidates and
  return a clear error instead of silently no-op'ing.
- **Synchronous ask** — `btw.sh ask --wait <sec>`: post a question and block (with timeout)
  until the target answers, for the "denied a file and cannot proceed without an answer" case.
- **Schema versioning + migration** — add a `version` field and migrate (rather than reset) on
  format changes; back up before any destructive reinit.
- **Inbox/room hygiene** — cap inbox size, auto-expire delivered+acked messages, and
  rotate/trim room transcripts.
- **Crash-resilient cleanup** — reconcile against actually-running session pids (or a liveness
  probe) so orphans are reclaimed promptly without waiting for the idle timeout.
- **More tests** — `tests/smoke.sh` covers claims, messaging, rooms, and GC end-to-end;
  extend with true concurrent contention (parallel writers) and a Linux/macOS CI matrix.
- **Richer presence in injection** — show how long ago a claim/note was made and summarize or
  budget long notes so context stays compact.

## License

MIT — see [LICENSE](LICENSE).

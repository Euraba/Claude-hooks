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
  each agent can see who else is active in the project.
- **File claims** — when an agent is about to `Edit`/`Write` a file, that file is claimed
  for the current turn. If another live session already holds the claim, the edit is
  **denied** with a reason telling the agent who holds it and how to ask them about it.
- **Intent notes** — an agent can post a one-line "what I'm working on", a plan path, and
  the files it expects to touch, which surfaces to other sessions.
- **`/btw` inbox messaging** — fire-and-forget questions to one session or all sessions.
- **`/room` private rooms** — a shared append-only transcript for sustained back-and-forth
  between two (or more) sessions.

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
3. Installs the `/btw` and `/room` slash commands into `~/.claude/commands/`, rewritten
   to point at wherever you cloned the repo.

Then copy the [agent protocol block](#teach-your-agents-the-protocol) into your
`~/.claude/CLAUDE.md` and restart any running Claude Code sessions.

## How it's wired (hooks)

`install.sh` registers these scripts as Claude Code hooks in `~/.claude/settings.json`:

| Hook event        | Matcher                            | Script                | Role |
|-------------------|------------------------------------|-----------------------|------|
| `SessionStart`    | —                                  | `lobby/register.sh`   | Add this session to the lobby (on `compact`/`resume` the existing entry is preserved, heartbeat only). |
| `UserPromptSubmit`| —                                  | `lobby/inject.sh`     | Heartbeat, clear per-turn claims, inject inbox + other sessions' notes/claims + new room messages. |
| `PreToolUse`      | `Edit\|Write\|MultiEdit\|NotebookEdit` | `lobby/claim.sh`  | Claim the target file or deny if another session holds it. |
| `PostToolUse`     | — (all tools)                      | `lobby/post-edit-inbox.sh` | Deliver newly-arrived inbox / room messages mid-execution, after any tool call. |
| `Stop`            | —                                  | `lobby/release.sh`    | End of turn: release this session's file claims. |
| `SessionEnd`      | —                                  | `lobby/cleanup.sh`    | Remove the session; delete rooms with no members left. |

Supporting pieces:

- `lobby/lib.sh` — sourced by all of the above. Resolves the lobby anchor (git repo root,
  falling back to `CLAUDE_PROJECT_DIR`/cwd), provides atomic `jq` writes, stale-pruning, and
  room delivery.
- `lobby/note.sh` — CLI for intent notes (`set` / `clear` / `show`).
- `lobby/btw.sh` — CLI behind the `/btw` slash command (`send` / `inbox` / `ack` / `show`).
- `lobby/room.sh` — CLI behind the `/room` slash command (`invite` / `accept` / `say` /
  `leave` / `show` / `list`).

- `install.sh` — idempotent installer (hooks + slash commands).
- `commands/btw.md`, `commands/room.md` — the `/btw` and `/room` slash commands,
  installed into `~/.claude/commands/`.
- `tests/smoke.sh` — end-to-end smoke test simulating two sessions across two repos.

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
      "note": "refactoring auth",       // optional intent
      "plan_path": "…",                 // optional
      "planned_files": ["/abs/…"],      // optional
      "inbox": [                         // /btw messages addressed to this session
        { "from_short": "…", "from_full": "…", "text": "…",
          "sent_at": "…", "delivered_at": null }
      ],
      "room_id": "r-ab12…",             // current room, if any
      "room_cursor": 3                   // # of room lines already delivered
    }
  ]
}
```

- `<lobby-anchor>/.claude/lobby.lock` — `flock` target serializing all writes.
- `<lobby-anchor>/.claude/rooms/<room_id>.jsonl` — append-only room transcript (one JSON
  object per line), with its own `.lock`.

Claims are **per-turn** (cleared on `Stop` and at the next `UserPromptSubmit`), representing
"actively editing right now". A claim on a file in a *different* git repo than the session's
home anchor is recorded in that repo's lobby; the foreign repo root is tracked in `anchors`
on the home entry so `Stop`/`SessionEnd` release those claims too. Notes/inbox/room
membership are **per-session** and persist until `SessionEnd` or stale-prune (default 30 min
idle, `LOBBY_STALE_AFTER_SEC`).

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
`PreToolUse` deny reason mentions a session short id), do NOT just give up. Use
`/btw` to ask that session what it intends:

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

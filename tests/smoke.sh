#!/usr/bin/env bash
# Smoke test for the lobby hook bug fixes. Simulates two sessions in repoA
# and a cross-repo claim into repoB.
set -u
H="$(cd "$(dirname "$0")/.." && pwd)/lobby"
T=$(mktemp -d /tmp/lobby-smoke.XXXXXX)
mkdir -p "$T/repoA" "$T/repoB"
git -C "$T/repoA" init -q
git -C "$T/repoB" init -q
export CLAUDE_PROJECT_DIR="$T/repoA"
SA=aaaa1111-1111-1111-1111-111111111111
SB=bbbb2222-2222-2222-2222-222222222222
A_LOBBY="$T/repoA/.claude/lobby.json"
B_LOBBY="$T/repoB/.claude/lobby.json"
pass=0; fail=0
check() { # check <desc> <cmd...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "PASS: $desc"; ((pass++)); else echo "FAIL: $desc"; ((fail++)); fi
}

echo "=== register both sessions ==="
echo "{\"session_id\":\"$SA\",\"source\":\"startup\"}" | "$H/register.sh"
echo "{\"session_id\":\"$SB\",\"source\":\"startup\"}" | "$H/register.sh"
check "both sessions registered" jq -e '.sessions | length == 2' "$A_LOBBY"

echo "=== claims: same-repo deny ==="
"$H/note.sh" set --session "$SA" --note "refactoring foo module"
out=$(echo "{\"session_id\":\"$SA\",\"tool_input\":{\"file_path\":\"$T/repoA/foo.ts\"}}" | "$H/claim.sh")
check "SA claim foo.ts allowed (no output)" test -z "$out"
out=$(echo "{\"session_id\":\"$SB\",\"tool_input\":{\"file_path\":\"$T/repoA/foo.ts\"}}" | "$H/claim.sh")
check "SB claim foo.ts denied" grep -q '"permissionDecision":"deny"' <<<"$out"
check "deny reason includes holder's note" grep -q "refactoring foo module" <<<"$out"
"$H/note.sh" clear --session "$SA"

echo "=== bug 1: cross-repo claim + release ==="
out=$(echo "{\"session_id\":\"$SA\",\"tool_input\":{\"file_path\":\"$T/repoB/bar.ts\"}}" | "$H/claim.sh")
check "SA cross-repo claim allowed" test -z "$out"
check "claim recorded in repoB lobby" jq -e --arg p "$T/repoB/bar.ts" \
  '.sessions[] | select(.session_id == "'$SA'") | .claims | index($p)' "$B_LOBBY"
check "anchor recorded in repoA lobby" jq -e --arg a "$T/repoB" \
  '.sessions[] | select(.session_id == "'$SA'") | .anchors | index($a)' "$A_LOBBY"
echo "{\"session_id\":\"$SA\"}" | "$H/release.sh"
check "home claims cleared on Stop" jq -e \
  '.sessions[] | select(.session_id == "'$SA'") | .claims == []' "$A_LOBBY"
check "home anchors cleared on Stop" jq -e \
  '.sessions[] | select(.session_id == "'$SA'") | (.anchors // []) == []' "$A_LOBBY"
check "FOREIGN claims cleared on Stop" jq -e \
  '.sessions[] | select(.session_id == "'$SA'") | .claims == []' "$B_LOBBY"

echo "=== bug 2: send must not refresh recipient heartbeat ==="
before=$(jq -r '.sessions[] | select(.session_id == "'$SB'") | .last_seen_epoch' "$A_LOBBY")
sleep 1.1
"$H/btw.sh" send --from "${SA:0:8}" --to "${SB:0:8}" --text "hello one"
after=$(jq -r '.sessions[] | select(.session_id == "'$SB'") | .last_seen_epoch' "$A_LOBBY")
check "recipient last_seen unchanged by send" test "$before" = "$after"

echo "=== bug 3: ack keeps undelivered messages ==="
out=$(echo "{\"session_id\":\"$SB\"}" | "$H/inject.sh")   # delivers "hello one"
check "inject shows INBOX with hello one" grep -q "hello one" <<<"$out"
"$H/btw.sh" send --from "${SA:0:8}" --to "${SB:0:8}" --text "hello two"   # undelivered
"$H/btw.sh" ack --session "${SB:0:8}"
inbox=$("$H/btw.sh" inbox --session "${SB:0:8}")
check "delivered msg removed by ack" bash -c "! grep -q 'hello one' <<<'$inbox'"
check "undelivered msg survives ack" grep -q "hello two" <<<"$inbox"

echo "=== bug 4: compact/resume preserve entry, startup resets ==="
"$H/note.sh" set --session "$SA" --note "working on X"
echo "{\"session_id\":\"$SA\",\"source\":\"compact\"}" | "$H/register.sh"
check "note survives compact" jq -e \
  '.sessions[] | select(.session_id == "'$SA'") | .note == "working on X"' "$A_LOBBY"
echo "{\"session_id\":\"$SA\",\"source\":\"resume\"}" | "$H/register.sh"
check "note survives resume" jq -e \
  '.sessions[] | select(.session_id == "'$SA'") | .note == "working on X"' "$A_LOBBY"
echo "{\"session_id\":\"$SA\",\"source\":\"startup\"}" | "$H/register.sh"
check "note reset on startup" jq -e \
  '.sessions[] | select(.session_id == "'$SA'") | (.note // "") == ""' "$A_LOBBY"

echo "=== bug 5: room say/deliver ordering ==="
RID=$("$H/room.sh" invite --from "${SA:0:8}" --to "${SB:0:8}" --topic smoketest)
check "invite returned room id" test -n "$RID"
"$H/room.sh" accept --session "${SB:0:8}" --room "$RID"
# B says first, then A says — under the old code A's say jumped its cursor
# past B's line and A never saw it.
"$H/room.sh" say --session "${SB:0:8}" --text "msg from B"
"$H/room.sh" say --session "${SA:0:8}" --text "msg from A"
outA=$(echo "{\"session_id\":\"$SA\"}" | "$H/inject.sh")
check "A sees B's earlier message" grep -q "msg from B" <<<"$outA"
check "A does not see own message" bash -c "! grep -q 'msg from A' <<<'$outA'"
outB=$(echo "{\"session_id\":\"$SB\"}" | "$H/inject.sh")
check "B sees A's message" grep -q "msg from A" <<<"$outB"
check "B does not see own message" bash -c "! grep -q 'msg from B' <<<'$outB'"
"$H/room.sh" leave --session "${SB:0:8}" >/dev/null
"$H/room.sh" leave --session "${SA:0:8}" >/dev/null
check "room file deleted after last leave" bash -c "! ls $T/repoA/.claude/rooms/*.jsonl 2>/dev/null"

echo "=== room GC: orphaned transcript collected by prune ==="
mkdir -p "$T/repoA/.claude/rooms"
echo '{"system":true,"text":"orphan"}' > "$T/repoA/.claude/rooms/r-dead00.jsonl"
touch -d "10 minutes ago" "$T/repoA/.claude/rooms/r-dead00.jsonl"
echo "{\"session_id\":\"$SA\"}" | "$H/inject.sh" >/dev/null
check "orphan room file GC'd" bash -c "! test -e $T/repoA/.claude/rooms/r-dead00.jsonl"
echo '{"system":true,"text":"fresh"}' > "$T/repoA/.claude/rooms/r-fresh0.jsonl"
echo "{\"session_id\":\"$SA\"}" | "$H/inject.sh" >/dev/null
check "fresh (<60s) room file NOT GC'd" test -e "$T/repoA/.claude/rooms/r-fresh0.jsonl"

echo "=== cleanup: SessionEnd removes session from foreign lobby too ==="
echo "{\"session_id\":\"$SA\",\"tool_input\":{\"file_path\":\"$T/repoB/baz.ts\"}}" | "$H/claim.sh" >/dev/null
echo "{\"session_id\":\"$SA\"}" | "$H/cleanup.sh"
check "SA removed from home lobby" bash -c "! jq -e '.sessions[] | select(.session_id == \"$SA\")' $A_LOBBY >/dev/null"
check "SA removed from foreign lobby" bash -c "! jq -e '.sessions[] | select(.session_id == \"$SA\")' $B_LOBBY >/dev/null"

echo
echo "=== RESULT: $pass passed, $fail failed (state in $T) ==="
exit $((fail > 0))

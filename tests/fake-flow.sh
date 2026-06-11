#!/usr/bin/env bash
# End-to-end exercise of the main/reviewer workflow with fake sessions:
# pipes hand-built hook stdin JSON into the lobby scripts exactly as Claude
# Code would, and asserts lobby.json state with jq after each step.
# No real Claude sessions are involved. Run: bash tests/fake-flow.sh
set -u

HOOKS="$(cd "$(dirname "$0")/../lobby" && pwd)"
TMP=$(mktemp -d /tmp/lobby-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

export CLAUDE_PROJECT_DIR="$TMP"
unset LOBBY_ROLE LOBBY_MAIN 2>/dev/null || true

MAIN="aaaa1111-0000-4000-8000-000000000001"
R1="bbbb2222-0000-4000-8000-000000000002"
R2="cccc3333-0000-4000-8000-000000000003"
LOBBY="$TMP/.claude/lobby.json"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }
assert_eq() { # desc expected actual
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
assert_contains() { # desc needle haystack
  case "$3" in *"$2"*) ok "$1" ;; *) fail "$1 (no '$2' in output: ${3:0:200})" ;; esac
}
field() { jq -r "$1" "$LOBBY"; }
hook() { # session_id extra-json
  jq -nc --arg sid "$1" "{session_id: \$sid} + ${2:-{\}}"
}

# ---- setup: a tiny git repo --------------------------------------------------
cd "$TMP"
git init -q .
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "init"
echo "v1" > app.txt
git add app.txt && git -c user.email=t@t -c user.name=t commit -q -m "base"

echo "== 1. registration & roles =="
out=$(hook "$MAIN" '{source: "startup"}' | LOBBY_ROLE=main "$HOOKS/register.sh")
assert_eq "main role set" "main" "$(field '.sessions[0].role')"
assert_contains "main briefing injected" "role MAIN" "$out"

out=$(hook "$R1" '{source: "startup"}' | LOBBY_ROLE=reviewer:1 LOBBY_MAIN=aaaa1111 "$HOOKS/register.sh")
assert_eq "r1 attached" "$MAIN" "$(field '.sessions[] | select(.session_id == "'$R1'") | .main_sid')"
assert_contains "r1 lens briefing" "REVIEWER R1" "$out"
assert_contains "r1 heir notice" "designated heir" "$out"

out=$(hook "dddd4444-0000-4000-8000-000000000004" '{source: "startup"}' \
  | LOBBY_ROLE=reviewer:1 LOBBY_MAIN=aaaa1111 "$HOOKS/register.sh")
assert_contains "duplicate slot rejected" "already taken" "$out"

out=$(hook "$R2" '{source: "startup"}' | LOBBY_ROLE=reviewer:2 LOBBY_MAIN=aaaa1111 "$HOOKS/register.sh")
assert_eq "r2 attached" "2" "$(field '.sessions[] | select(.session_id == "'$R2'") | .reviewer_no')"

# re-register on compact must not wipe the role
hook "$R1" '{source: "compact"}' | "$HOOKS/register.sh" >/dev/null
assert_eq "compact re-register keeps role" "reviewer" "$(field '.sessions[] | select(.session_id == "'$R1'") | .role')"

echo "== 2. mission =="
"$HOOKS/mission.sh" set --session "$MAIN" --goal "ship the widget" --spec "$TMP/SPEC.md" >/dev/null
assert_eq "goal stored" "ship the widget" "$(field '.sessions[] | select(.session_id == "'$MAIN'") | .mission.goal')"
baseline=$(field '.sessions[] | select(.session_id == "'$MAIN'") | .review.baseline_ref')
assert_eq "baseline = HEAD" "$(git rev-parse HEAD)" "$baseline"

echo "== 3. milestone work + review request =="
echo "v2" > app.txt
git add app.txt && git -c user.email=t@t -c user.name=t commit -q -m "milestone 1"
out=$("$HOOKS/review.sh" request --session "$MAIN" --summary "implemented widget v2" 2>&1)
assert_eq "status in_review" "in_review" "$(field '.sessions[] | select(.session_id == "'$MAIN'") | .review.status')"
assert_eq "turn is R1" "1" "$(field '.sessions[] | select(.session_id == "'$MAIN'") | .review.turn')"
room=$(field '.sessions[] | select(.session_id == "'$MAIN'") | .review.room_id')
assert_contains "room created" "r-rev-" "$room"
assert_eq "r2 pulled into room" "$room" "$(field '.sessions[] | select(.session_id == "'$R2'") | .room_id')"

echo "== 4. reviewer wait + chain order =="
out=$("$HOOKS/review-wait.sh" --session "$R1" --timeout 2 --interval 1)
assert_contains "r1 woken with packet" "REVIEW — round 1, your turn (R1)" "$out"
assert_contains "r1 lens content" "spec/plan compliance" "$out"
assert_contains "r1 sees diff pointer" "Read the full diff with:" "$out"

out=$("$HOOKS/review.sh" verdict --session "$R2" --verdict approve --text "lgtm" 2>&1)
rc=$?
assert_eq "out-of-turn verdict rejected" "3" "$rc"
assert_contains "rejection explains turn" "not your turn" "$out"

"$HOOKS/review.sh" verdict --session "$R1" --verdict request_changes --text "missing error handling in app.txt" >/dev/null
assert_eq "turn advanced to R2" "2" "$(field '.sessions[] | select(.session_id == "'$MAIN'") | .review.turn')"

out=$("$HOOKS/review-wait.sh" --session "$R2" --timeout 2 --interval 1)
assert_contains "r2 woken" "your turn (R2)" "$out"
assert_contains "r2 goal-only lens" "goal-only" "$out"
assert_contains "r2 sees earlier findings" "missing error handling" "$out"

"$HOOKS/review.sh" verdict --session "$R2" --verdict approve --text "serves the goal" >/dev/null
assert_eq "round complete -> changes_requested" "changes_requested" \
  "$(field '.sessions[] | select(.session_id == "'$MAIN'") | .review.status')"

echo "== 5. stop gate blocks main on findings =="
printf '%s\n' '{"isSidechain":false,"message":{"usage":{"input_tokens":10000,"cache_read_input_tokens":20000,"cache_creation_input_tokens":0}}}' > "$TMP/transcript.jsonl"
out=$(hook "$MAIN" "{transcript_path: \"$TMP/transcript.jsonl\"}" | "$HOOKS/stop-gate.sh")
assert_contains "main blocked" '"decision":"block"' "$out"
assert_contains "block carries findings" "missing error handling" "$out"

echo "== 6. main woken with result, fixes, round 2 approves =="
out=$("$HOOKS/review-wait.sh" --session "$MAIN" --timeout 2 --interval 1)
assert_contains "main gets CHANGES_REQUESTED" "CHANGES_REQUESTED" "$out"
echo "v3" > app.txt
git add app.txt && git -c user.email=t@t -c user.name=t commit -q -m "fix"
"$HOOKS/review.sh" request --session "$MAIN" --summary "added error handling" >/dev/null 2>&1
assert_eq "round bumped" "2" "$(field '.sessions[] | select(.session_id == "'$MAIN'") | .review.round')"
"$HOOKS/review.sh" verdict --session "$R1" --verdict approve --text "fixed" >/dev/null
"$HOOKS/review.sh" verdict --session "$R2" --verdict approve --text "good" >/dev/null
assert_eq "approved" "approved" "$(field '.sessions[] | select(.session_id == "'$MAIN'") | .review.status')"
assert_eq "baseline advanced to approved HEAD" "$(git rev-parse HEAD)" \
  "$(field '.sessions[] | select(.session_id == "'$MAIN'") | .review.baseline_ref')"

out=$(hook "$MAIN" "{transcript_path: \"$TMP/transcript.jsonl\"}" | "$HOOKS/stop-gate.sh")
assert_contains "approved: no block, human notified" "APPROVED" "$out"
assert_contains "approved: not a block" '"systemMessage"' "$out"
out=$(hook "$MAIN" "{transcript_path: \"$TMP/transcript.jsonl\"}" | "$HOOKS/stop-gate.sh")
assert_eq "approved notice is one-shot" "" "$out"

echo "== 7. reviewer edit denial + reviewer stop gate =="
out=$(hook "$R1" "{tool_input: {file_path: \"$TMP/app.txt\"}}" | "$HOOKS/claim.sh")
assert_contains "reviewer edit denied" '"permissionDecision":"deny"' "$out"
out=$(hook "$R1" '{}' | "$HOOKS/stop-gate.sh")
assert_contains "reviewer stop blocked" "Do not stop" "$out"
# without running review-wait between stops, the same-reason cap releases it
hook "$R1" '{}' | "$HOOKS/stop-gate.sh" >/dev/null
hook "$R1" '{}' | "$HOOKS/stop-gate.sh" >/dev/null
out=$(hook "$R1" '{}' | "$HOOKS/stop-gate.sh")
assert_contains "same-block cap releases reviewer" "released" "$out"
# review-wait resets the counter -> blocking resumes
"$HOOKS/review-wait.sh" --session "$R1" --timeout 1 --interval 1 >/dev/null
out=$(hook "$R1" '{}' | "$HOOKS/stop-gate.sh")
assert_contains "counter reset re-arms gate" '"decision":"block"' "$out"

echo "== 8. context overflow succession =="
printf '%s\n' '{"isSidechain":false,"message":{"usage":{"input_tokens":100000,"cache_read_input_tokens":30000,"cache_creation_input_tokens":5000}}}' > "$TMP/transcript.jsonl"
out=$(hook "$MAIN" "{transcript_path: \"$TMP/transcript.jsonl\"}" | "$HOOKS/stop-gate.sh")
assert_contains "handoff triggered + blocked" "hand off" "$out"
assert_eq "handoff latched" "pending" "$(field '.sessions[] | select(.session_id == "'$MAIN'") | .handoff.status')"
brief=$(field '.sessions[] | select(.session_id == "'$MAIN'") | .handoff.brief_path')
echo "state: widget v3 done; next: docs" > "$brief"
out=$("$HOOKS/succession.sh" handoff --session "$MAIN" --brief "$brief")
assert_contains "handoff completes" "now the main" "$out"
assert_eq "heir promoted" "main" "$(field '.sessions[] | select(.session_id == "'$R1'") | .role')"
assert_eq "heir inherits mission" "ship the widget" "$(field '.sessions[] | select(.session_id == "'$R1'") | .mission.goal')"
assert_eq "r2 repointed to heir" "$R1" "$(field '.sessions[] | select(.session_id == "'$R2'") | .main_sid')"
assert_eq "old main retired" "retired" "$(field '.sessions[] | select(.session_id == "'$MAIN'") | .role')"

out=$("$HOOKS/review-wait.sh" --session "$R1" --timeout 2 --interval 1)
assert_contains "heir gets PROMOTED packet" "PROMOTED" "$out"
assert_contains "heir receives brief" "widget v3 done" "$out"
assert_eq "brief marker cleared" "" "$(field '.sessions[] | select(.session_id == "'$R1'") | .handoff_brief_in // ""')"

out=$(hook "$MAIN" '{}' | "$HOOKS/stop-gate.sh")
assert_contains "retired main: human notified once" "handed off" "$out"
out=$(hook "$MAIN" '{}' | "$HOOKS/stop-gate.sh")
assert_eq "retired notice one-shot" "" "$out"

echo "== 9. dead reviewer self-heal + escalation =="
echo "v4" > app.txt
git add app.txt && git -c user.email=t@t -c user.name=t commit -q -m "m2"
"$HOOKS/review.sh" request --session "$R1" --summary "milestone 2" >/dev/null 2>&1
assert_eq "new main can request" "in_review" "$(field '.sessions[] | select(.session_id == "'$R1'") | .review.status')"
assert_eq "turn is R2 (only reviewer)" "2" "$(field '.sessions[] | select(.session_id == "'$R1'") | .review.turn')"
# kill R2 mid-turn (SessionEnd) -> chain must finalize, not hang
hook "$R2" '{}' | "$HOOKS/cleanup.sh"
status=$(field '.sessions[] | select(.session_id == "'$R1'") | .review.status')
assert_eq "self-heal finalizes round (no reviewers left -> idle)" "idle" "$status"

echo "== 9b. round cap -> escalated -> reset =="
R3="eeee5555-0000-4000-8000-000000000005"
hook "$R3" '{source: "startup"}' | LOBBY_ROLE=reviewer:1 LOBBY_MAIN=bbbb2222 "$HOOKS/register.sh" >/dev/null
# simulate a tight round cap
tmpf=$(mktemp); jq '(.sessions[] | select(.session_id == "'$R1'") | .review.max_rounds) = 1' "$LOBBY" > "$tmpf" && mv "$tmpf" "$LOBBY"
"$HOOKS/review.sh" request --session "$R1" --summary "milestone 3" >/dev/null 2>&1
"$HOOKS/review.sh" verdict --session "$R3" --verdict request_changes --text "nope" >/dev/null
assert_eq "round cap escalates" "escalated" "$(field '.sessions[] | select(.session_id == "'$R1'") | .review.status')"
out=$(hook "$R1" '{}' | "$HOOKS/stop-gate.sh")
assert_contains "escalation notifies human, no block" "DEADLOCKED" "$out"
assert_contains "escalation is not a block" '"systemMessage"' "$out"
out=$("$HOOKS/review.sh" request --session "$R1" --summary "retry" 2>&1); rc=$?
assert_eq "request refused while escalated" "3" "$rc"
"$HOOKS/review.sh" reset --session "$R1" >/dev/null
assert_eq "reset re-arms" "changes_requested" "$(field '.sessions[] | select(.session_id == "'$R1'") | .review.status')"

echo "== 10. estimate_ctx_pct fail-open =="
echo "not json at all" > "$TMP/garbage.jsonl"
. "$HOOKS/lib.sh"
assert_eq "garbage transcript -> empty" "" "$(estimate_ctx_pct "$TMP/garbage.jsonl")"
assert_eq "missing file -> empty" "" "$(estimate_ctx_pct "$TMP/nope.jsonl")"

echo "== 11. inject banner + promoted heir can edit =="
out=$(hook "$R3" '{}' | "$HOOKS/inject.sh")
assert_contains "reviewer banner injected" "REVIEWER R1" "$out"
out=$(hook "$R1" '{}' | "$HOOKS/inject.sh")
assert_contains "main banner injected" "You are MAIN" "$out"
assert_contains "changes_requested reminder" "REQUESTED CHANGES" "$out"
out=$(hook "$R1" "{tool_input: {file_path: \"$TMP/app.txt\"}}" | "$HOOKS/claim.sh")
assert_eq "promoted heir may edit (no deny)" "" "$out"

echo "== 12. zero-verdict round must restart, not auto-approve =="
M2="ffff6666-0000-4000-8000-000000000006"
RA="abab7777-0000-4000-8000-000000000007"
RB="cdcd8888-0000-4000-8000-000000000008"
hook "$M2" '{source: "startup"}' | LOBBY_ROLE=main "$HOOKS/register.sh" >/dev/null
hook "$RA" '{source: "startup"}' | LOBBY_ROLE=reviewer:2 LOBBY_MAIN=ffff6666 "$HOOKS/register.sh" >/dev/null
"$HOOKS/mission.sh" set --session "$M2" --goal "second widget" >/dev/null
echo "w1" > widget.txt
git add widget.txt && git -c user.email=t@t -c user.name=t commit -q -m "w1"
"$HOOKS/review.sh" request --session "$M2" --summary "widget m1" >/dev/null 2>&1
assert_eq "round open, turn = only reviewer (R2)" "2" "$(field '.sessions[] | select(.session_id == "'$M2'") | .review.turn')"
# a lower-numbered reviewer attaches mid-round...
hook "$RB" '{source: "startup"}' | LOBBY_ROLE=reviewer:1 LOBBY_MAIN=ffff6666 "$HOOKS/register.sh" >/dev/null
# ...then the turn-holder dies with no verdict recorded
hook "$RA" '{}' | "$HOOKS/cleanup.sh"
assert_eq "zero verdicts: round NOT approved" "in_review" "$(field '.sessions[] | select(.session_id == "'$M2'") | .review.status')"
assert_eq "round restarted at lowest live reviewer" "1" "$(field '.sessions[] | select(.session_id == "'$M2'") | .review.turn')"
"$HOOKS/review.sh" verdict --session "$RB" --verdict request_changes --text "widget lacks tests" >/dev/null
assert_eq "restarted round finalizes normally" "changes_requested" "$(field '.sessions[] | select(.session_id == "'$M2'") | .review.status')"

echo "== 13. stale-prune exempts roled sessions =="
P="9999aaaa-0000-4000-8000-000000000009"
S="8888bbbb-0000-4000-8000-000000000010"
hook "$P" '{source: "startup"}' | "$HOOKS/register.sh" >/dev/null            # plain
hook "$S" '{source: "startup"}' | LOBBY_ROLE=main "$HOOKS/register.sh" >/dev/null  # roled, no reviewers
old_epoch=$(( $(date +%s) - 7200 ))
tmpf=$(mktemp); jq --argjson e "$old_epoch" '
  .sessions |= map(if .session_id == "'$P'" or .session_id == "'$S'" then .last_seen_epoch = $e else . end)
' "$LOBBY" > "$tmpf" && mv "$tmpf" "$LOBBY"
hook "$M2" '{}' | "$HOOKS/inject.sh" >/dev/null     # any hook triggers prune
assert_eq "plain session pruned at 2h" "" "$(field '.sessions[] | select(.session_id == "'$P'") | .session_id // ""')"
assert_eq "roled session survives 2h" "$S" "$(field '.sessions[] | select(.session_id == "'$S'") | .session_id')"
hook "$M2" '{}' | LOBBY_ROLE_STALE_SEC=60 "$HOOKS/inject.sh" >/dev/null
assert_eq "roled session pruned past its own TTL" "" "$(field '.sessions[] | select(.session_id == "'$S'") | .session_id // ""')"

echo "== 14. stop_blocks: polling is not progress, fixing is =="
printf '%s\n' '{"isSidechain":false,"message":{"usage":{"input_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' > "$TMP/transcript.jsonl"
hook "$M2" "{transcript_path: \"$TMP/transcript.jsonl\"}" | "$HOOKS/stop-gate.sh" >/dev/null
assert_eq "block counted" "1" "$(field '.sessions[] | select(.session_id == "'$M2'") | .stop_blocks')"
"$HOOKS/review-wait.sh" --session "$M2" --timeout 1 --interval 1 >/dev/null
assert_eq "main polling does NOT reset the counter" "1" "$(field '.sessions[] | select(.session_id == "'$M2'") | .stop_blocks')"
hook "$M2" "{tool_input: {file_path: \"$TMP/widget.txt\"}}" | "$HOOKS/claim.sh" >/dev/null
assert_eq "a successful claim resets the counter" "0" "$(field '.sessions[] | select(.session_id == "'$M2'") | .stop_blocks')"

echo "== 15. reset is escalated-only =="
out=$("$HOOKS/review.sh" reset --session "$M2" 2>&1); rc=$?
assert_eq "reset refused outside escalated" "3" "$rc"
assert_contains "reset refusal explains itself" "not escalated" "$out"

echo "== 16. pending handoff un-latches when context recovers =="
printf '%s\n' '{"isSidechain":false,"message":{"usage":{"input_tokens":100000,"cache_read_input_tokens":30000,"cache_creation_input_tokens":5000}}}' > "$TMP/transcript.jsonl"
hook "$M2" "{transcript_path: \"$TMP/transcript.jsonl\"}" | "$HOOKS/stop-gate.sh" >/dev/null
assert_eq "handoff latched at 67%" "pending" "$(field '.sessions[] | select(.session_id == "'$M2'") | .handoff.status')"
printf '%s\n' '{"isSidechain":false,"message":{"usage":{"input_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' > "$TMP/transcript.jsonl"
out=$(hook "$M2" "{transcript_path: \"$TMP/transcript.jsonl\"}" | "$HOOKS/stop-gate.sh")
assert_contains "un-latch announced" "cancelled" "$out"
assert_eq "handoff cleared" "" "$(field '.sessions[] | select(.session_id == "'$M2'") | .handoff.status // ""')"
assert_contains "falls through to findings block" "widget lacks tests" "$out"

echo "== 17. changes_requested with no reviewers escalates instead of blocking =="
hook "$RB" '{}' | "$HOOKS/cleanup.sh"     # last reviewer leaves
out=$(hook "$M2" "{transcript_path: \"$TMP/transcript.jsonl\"}" | "$HOOKS/stop-gate.sh")
assert_contains "escalates to human" "reviewers are gone" "$out"
case "$out" in *'"decision":"block"'*) fail "zero-reviewer escalation must not block" ;; *) ok "zero-reviewer escalation does not block" ;; esac
assert_eq "status flipped to escalated" "escalated" "$(field '.sessions[] | select(.session_id == "'$M2'") | .review.status')"

echo "== 18. retired session gets a RETIRED wake, not NO_ROLE =="
out=$("$HOOKS/review-wait.sh" --session "$MAIN" --timeout 1 --interval 1)
assert_contains "retired wake message" "RETIRED" "$out"

echo "== 19. review-wait returns chatter immediately =="
# R3 is an idle reviewer (no wake pending), so chatter alone must end the wait.
"$HOOKS/btw.sh" send --from "$M2" --to "$R3" --text "heads up about widget" >/dev/null
out=$("$HOOKS/review-wait.sh" --session "$R3" --timeout 30 --interval 1)
assert_contains "inbox surfaced" "heads up about widget" "$out"
assert_contains "returns with MESSAGES instruction" "MESSAGES" "$out"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

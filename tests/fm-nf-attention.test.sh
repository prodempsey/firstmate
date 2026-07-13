#!/usr/bin/env bash
# Behavior tests for reconciling a recorded fleet-triage disposition into board attention.
#
# The load-bearing properties:
#   - a terminal disposition stops the item presenting as active FirstMate attention, and
#     stops it waking firstmate, without anyone remembering to do it;
#   - a held item stays visible but presents as held, with its reason and review date;
#   - a disposition is bound to the evidence it was decided against, so it can never suppress
#     a fresh terminal signal;
#   - clearing ATTENTION is never CLOSURE: no closure evidence is written, the task stays
#     un-closable without it, and it stays in the audit.
set -u

# shellcheck disable=SC1091 # Dynamic test-library path is resolved from BASH_SOURCE.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck disable=SC2153 # ROOT is provided by tests/lib.sh.
ATTENTION="$ROOT/bin/fm-nf-attention.sh"
RECONCILE="$ROOT/bin/fm-nf-reconcile.sh"
RECORD="$ROOT/bin/fm-fleet-triage-record.sh"
TASK_EVENTS="$ROOT/bin/fm-task-events.sh"
TMP_ROOT=$(fm_test_tmproot fm-nf-attention)

# A board stand-in: every attention and overlay write lands in one log, and every reply is a
# success, so a test can assert exactly what firstmate told the board and nothing more.
new_home() {  # <name>
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/fakebin"
  cat > "$home/fakebin/curl" <<'SH'
#!/usr/bin/env bash
url= body=
while [ "$#" -gt 0 ]; do
  case $1 in
    -d) body=$2; shift 2 ;;
    -H) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
if [ -n "$body" ]; then
  printf '%s\t%s\n' "$url" "$body" >> "$FM_TEST_BOARD_LOG"
else
  # A GET is a read-back: answer with the last thing written to this card, which is what
  # bin/fm-nf-ack.sh verifies its own write against.
  awk -F '\t' -v url="$url" '$1 == url {last = $2} END {print (last == "" ? "{}" : last)}' \
    "$FM_TEST_BOARD_LOG" 2>/dev/null || printf '{}\n'
fi
SH
  chmod +x "$home/fakebin/curl"
  printf '%s\n' "$home"
}

write_task() {  # <home> <id> <status-line>
  local home=$1 id=$2 status=$3
  fm_write_meta "$home/state/$id.meta" \
    "window=fm-$id" \
    "worktree=$home/worktrees/$id" \
    "project=demo" \
    "harness=claude" \
    "kind=ship" \
    "mode=local-only" \
    "yolo=off"
  printf '%s\n' "$status" > "$home/state/$id.status"
}

# The writer only acts for the session that owns the per-home lock, and every test process is
# in its own ancestry.
own_lock() {  # <home>
  printf '%s\n' "$$" > "$1/state/.lock"
}

evidence_version() {  # <home> <id>
  local home=$1 id=$2 fingerprint
  # shellcheck disable=SC1091 # Sourced from the repo under test.
  . "$ROOT/bin/fm-nf-attention-lib.sh"
  fingerprint=$(fm_nf_current_fingerprint "$home/state" "$id") || return 1
  fm_nf_attention_evidence_version "$id" "$fingerprint"
}

run_in_home() {  # <home> <command>...
  local home=$1
  shift
  FM_TEST_BOARD_LOG="$home/board.log" PATH="$home/fakebin:$PATH" \
    FM_HOME="$home" FM_BRIDGE_URL='http://board.test' "$@"
}

# Record a disposition exactly as firstmate does, against the item's current evidence.
disposition() {  # <home> <event> <id> <flag>...
  local home=$1 event=$2 id=$3 ev
  shift 3
  ev=$(evidence_version "$home" "$id") || fail "no terminal signal to disposition for $id"
  run_in_home "$home" "$RECORD" "$event" "needs_firstmate:$id" --evidence-version "$ev" "$@"
}

board_events() {  # <home>
  [ -f "$1/board.log" ] || return 0
  cut -f2 "$1/board.log" | jq -r '.event // .type'
}

test_terminal_disposition_clears_board_attention() {
  local home out
  home=$(new_home resolved)
  own_lock "$home"
  write_task "$home" landed-a1 'done: ready in branch fm/landed-a1'

  out=$(run_in_home "$home" "$RECONCILE")
  assert_contains "$out" 'NEEDS FIRSTMATE: 1 unhandled - landed-a1' \
    "an undispositioned terminal signal must ask for firstmate"

  disposition "$home" resolve landed-a1 --link 'local-main-9fe12ab' > /dev/null \
    || fail "recording a resolution should succeed"

  # The board reads this key ahead of every derived signal, so the card stops presenting as
  # active FirstMate attention the moment the disposition is recorded.
  assert_grep 'attentionOwner=none' "$home/state/landed-a1.meta" \
    "a terminal disposition should clear the card's attention"
  out=$(run_in_home "$home" "$RECONCILE")
  [ -z "$out" ] || fail "a dispositioned item must not keep waking firstmate, got: $out"
  out=$(run_in_home "$home" "$RECONCILE" list)
  assert_contains "$out" '0 unhandled, 1 dispositioned' \
    "a dispositioned item stays listed, as dispositioned rather than unhandled"
  pass "a recorded terminal disposition clears the card and the wake"
}

test_held_presents_as_held_with_reason_and_date() {
  local home out note
  home=$(new_home held)
  own_lock "$home"
  write_task "$home" parked-b2 'blocked: needs an upstream fix'
  write_task "$home" fresh-d4 'failed: tests are red'

  disposition "$home" hold parked-b2 --reason 'upstream fix lands in v2.4' \
    --review-after 2026-08-01 > /dev/null || fail "recording a hold should succeed"

  # A hold is not terminal: the card keeps its FirstMate attention and stays on the board.
  assert_no_grep 'attentionOwner=' "$home/state/parked-b2.meta" \
    "a hold must not clear the card's attention"
  assert_grep 'attention_hold_reason=upstream fix lands in v2.4' "$home/state/parked-b2.meta" \
    "a hold should record its reason"
  assert_grep 'attention_hold_review_after=2026-08-01' "$home/state/parked-b2.meta" \
    "a hold should record its review date"

  # What changes is how it PRESENTS: reviewed, with the reason and the review date on the card.
  assert_contains "$(board_events "$home")" 'reviewed' "a hold should leave a reviewed receipt"
  note=$(grep '/api/overlay' "$home/board.log" | cut -f2 | jq -r '.payload.text')
  assert_contains "$note" 'held: upstream fix lands in v2.4 - review after 2026-08-01' \
    "the card note should carry the hold's reason and review date"

  out=$(run_in_home "$home" "$RECONCILE")
  assert_contains "$out" 'fresh-d4' "an untouched terminal signal still wakes firstmate"
  assert_not_contains "$out" 'parked-b2' "a held item must not wake firstmate again"
  out=$(run_in_home "$home" "$RECONCILE" list)
  assert_contains "$out" '1 unhandled, 1 held' "held items are counted apart from unhandled ones"
  assert_contains "$out" '  held-until: 2026-08-01' "list should name the review date"
  assert_contains "$out" '  hold-reason: upstream fix lands in v2.4' "list should name the reason"
  pass "a held item presents as held, distinctly from untouched attention"
}

# A captain batch hands the card to the captain, and the board's captain-attention column has
# exactly one writer (AGENTS.md section 9). This reconciliation must go through it, not around
# it, or an item could clear firstmate's attention without ever reaching the captain's.
test_captain_batch_hands_the_card_to_the_captain() {
  local home body
  home=$(new_home captain-batch)
  own_lock "$home"
  write_task "$home" decide-k2 'needs-decision: two viable designs'

  disposition "$home" captain-batch decide-k2 --link order-ORD-041 > /dev/null \
    || fail "recording a captain batch should succeed"

  assert_grep 'attentionOwner=none' "$home/state/decide-k2.meta" \
    "a captain batch should stop asking firstmate"
  body=$(grep '/api/card/' "$home/board.log" | cut -f2 | tail -n 1)
  [ "$(printf '%s' "$body" | jq -r '.event')" = to_captain ] \
    || fail "a captain batch should transfer board attention to the captain, got: $body"
  [ "$(printf '%s' "$body" | jq -r '.open_item_id')" = order-ORD-041 ] \
    || fail "the hand-off should name the batch it went into"
  assert_grep 'decide-k2' "$home/state/.nf-handled" \
    "the hand-off should go through the one writer of the captain-attention column"
  pass "a captain batch hands the card to the captain through its one writer"
}

test_hold_expiry_restores_attention() {
  local home
  home=$(new_home expired)
  own_lock "$home"
  write_task "$home" stale-hold-c3 'blocked: waiting on a vendor'

  disposition "$home" hold stale-hold-c3 --reason 'vendor ticket' --review-after 2020-01-01 \
    > /dev/null || fail "recording a hold should succeed"
  # The review date has passed, so the hold no longer holds: the item is owed attention again.
  assert_contains "$(run_in_home "$home" "$RECONCILE")" 'stale-hold-c3' \
    "an expired hold should ask for firstmate again"
  assert_no_grep 'attention_state=' "$home/state/stale-hold-c3.meta" \
    "an expired hold should drop its held presentation"
  pass "an expired hold returns to unhandled"
}

# The writer refuses a review date no clock can read, but the ledger holds legacy rows that
# predate that refusal. Such a hold can never come due, so it is not a disposition - the
# item must present as open, exactly as the enumerator's hold_unreviewable does, instead of
# staying muted forever.
test_legacy_unreviewable_hold_presents_as_open() {
  local home ev out
  home=$(new_home unreviewable)
  own_lock "$home"
  write_task "$home" muted-d4 'done: ready in branch fm/muted-d4'
  ev=$(evidence_version "$home" muted-d4) || fail "no evidence version for muted-d4"
  # Appended by hand: the real writer refuses this date now, which is the point.
  jq -nc --arg ev "$ev" \
    '{item_id: "needs_firstmate:muted-d4", event: "outcome", outcome_type: "held",
      outcome_reason: "muted long ago", review_after: "next bug-triage pass", evidence_version: $ev}' \
    >> "$home/data/fleet-triage.jsonl"
  out=$(run_in_home "$home" "$RECONCILE")
  assert_contains "$out" 'muted-d4' \
    "a hold whose review date no clock can read must keep asking for firstmate"
  # And the guard's sweep sees the same thing: the one owner of "unattended" is shared.
  out=$(bash -c '. "$1/bin/fm-nf-attention-lib.sh"; fm_nf_unattended_ids "$2/state" "$2/data"' \
    _ "$ROOT" "$home")
  assert_contains "$out" 'muted-d4' "fm_nf_unattended_ids must agree with the reconciler"
  pass "a legacy unreviewable hold cannot park work forever"
}

# The turn-end guard's sweep is a thin, level-triggered view over fm_nf_attention_desired:
# open items and only open items, one id per line, straight from live task state.
test_unattended_ids_lists_open_items_only() {
  local home out
  home=$(new_home unattended-ids)
  own_lock "$home"
  write_task "$home" open-e5 'done: ready in branch fm/open-e5'
  write_task "$home" busy-f6 'working: still implementing'
  write_task "$home" landed-g7 'done: ready in branch fm/landed-g7'
  disposition "$home" resolve landed-g7 --link 'local-main-1234abc' > /dev/null \
    || fail "recording a resolution should succeed"
  write_task "$home" parked-h8 'blocked: waiting on vendor window'
  disposition "$home" hold parked-h8 --reason 'vendor maintenance' --review-after 2999-01-01 \
    > /dev/null || fail "recording a hold should succeed"
  out=$(bash -c '. "$1/bin/fm-nf-attention-lib.sh"; fm_nf_unattended_ids "$2/state" "$2/data"' \
    _ "$ROOT" "$home")
  [ "$out" = 'open-e5' ] \
    || fail "expected exactly the one open item, got: $(printf '%s' "$out" | tr '\n' ' ')"
  pass "fm_nf_unattended_ids reports open items only, one id per line"
}

test_new_signal_reopens_a_dispositioned_card() {
  local home
  home=$(new_home reopened)
  own_lock "$home"
  write_task "$home" moved-e5 'done: ready in branch fm/moved-e5'
  disposition "$home" resolve moved-e5 --link 'local-main-abc1234' > /dev/null
  assert_grep 'attentionOwner=none' "$home/state/moved-e5.meta" "the card should clear first"

  # The crew reports something new. A disposition is bound to the evidence it was decided
  # against, so it must never suppress a fresh terminal signal.
  printf '%s\n' 'failed: the merge broke the build' >> "$home/state/moved-e5.status"
  assert_contains "$(run_in_home "$home" "$RECONCILE")" 'NEEDS FIRSTMATE: 1 unhandled - moved-e5' \
    "a new terminal signal must reopen the card"
  assert_no_grep 'attentionOwner=' "$home/state/moved-e5.meta" \
    "a stale disposition must not leave an attention override behind"
  pass "a fresh terminal signal reopens a dispositioned card"
}

test_resurface_restores_attention() {
  local home
  home=$(new_home resurfaced)
  own_lock "$home"
  write_task "$home" reopen-f6 'done: ready in branch fm/reopen-f6'
  disposition "$home" resolve reopen-f6 --link 'local-main-abc1234' > /dev/null

  # A surface re-opens an item and clears the disposition it re-opens; the board must follow.
  disposition "$home" surface reopen-f6 > /dev/null
  assert_no_grep 'attentionOwner=' "$home/state/reopen-f6.meta" \
    "re-opening an item should restore its attention"
  assert_contains "$(run_in_home "$home" "$RECONCILE")" 'reopen-f6' \
    "a re-opened item should ask for firstmate again"
  pass "re-surfacing an item restores its board attention"
}

test_dangling_successor_reopens_the_card() {
  local home
  home=$(new_home dangling)
  own_lock "$home"
  write_task "$home" rework-g7 'failed: wrong approach'

  # The successor is the whole lineage of this outcome. If it does not exist, the disposition
  # is a lie, and the item is owed firstmate's attention rather than a cleared card.
  disposition "$home" successor rework-g7 --link ghost-h8 > /dev/null
  assert_contains "$(run_in_home "$home" "$RECONCILE")" 'rework-g7' \
    "a successor that does not exist should reopen the card"

  write_task "$home" ghost-h8 'working: redoing it properly'
  run_in_home "$home" "$ATTENTION" apply rework-g7 > /dev/null
  assert_grep 'attentionOwner=none' "$home/state/rework-g7.meta" \
    "a successor that exists should clear the card"
  pass "a successor outcome clears the card only while its successor exists"
}

# The gate this fix must not weaken. Clearing attention says firstmate dispositioned the work;
# it never says the work is closed. A stand-in for fleet-bridge's server-independent CLI holds
# the same line the real one does: no closure evidence, no close, and the task stays in the
# audit either way.
write_visibility_stub() {  # <home>
  cat > "$1/visibility.mjs" <<'JS'
#!/usr/bin/env node
import { appendFileSync, readFileSync } from 'node:fs';
const argv = process.argv.slice(2);
const log = process.env.FM_TEST_VISIBILITY_LOG;
appendFileSync(log, argv.join(' ') + '\n');
const known = () => { try { return readFileSync(log, 'utf8'); } catch { return ''; } };
if (argv[0] === 'record') process.exit(0);
if (argv[0] === 'audit') {
  // Every task the ledger knows is still in the audit; attention never removes one.
  const ids = [...known().matchAll(/^record (\S+)/gm)].map((m) => m[1]);
  console.log(JSON.stringify({ ok: true, recordCount: ids.length, records: ids.map((id) => ({ id })), diagnostics: [] }));
  process.exit(0);
}
if (argv[0] === 'close') {
  // Same rule the real CLI holds: a flag is not evidence, a value is.
  const value = (flag) => { const i = argv.indexOf(flag); return i >= 0 ? String(argv[i + 1] || '').trim() : ''; };
  if (!value('--sha') && !value('--report')) { console.error('terminal record lacks closure evidence'); process.exit(1); }
  process.exit(0);
}
process.exit(2);
JS
  chmod +x "$1/visibility.mjs"
}

test_clearing_attention_is_not_closure() {
  local home audit out rc=0
  home=$(new_home closure-gate)
  own_lock "$home"
  write_visibility_stub "$home"
  write_task "$home" unlanded-i9 'done: ready in branch fm/unlanded-i9'
  printf 'record unlanded-i9\n' > "$home/visibility.log"

  disposition "$home" resolve unlanded-i9 --link 'local-main-abc1234' > /dev/null
  assert_grep 'attentionOwner=none' "$home/state/unlanded-i9.meta" "the card should clear"

  # 1. The attention path writes to the board's attention and overlay surfaces only. It never
  #    touches the durable lifecycle ledger, so it cannot manufacture closure.
  assert_no_grep 'closure_evidence' "$home/board.log" \
    "clearing attention must never write closure evidence"
  assert_no_grep '"event":"closed"' "$home/board.log" \
    "clearing attention must never close a task"

  # 2. The closure gate still refuses a task with no closure evidence.
  out=$(FM_TEST_VISIBILITY_LOG="$home/visibility.log" FM_VISIBILITY_CLI="$home/visibility.mjs" \
    FM_HOME="$home" "$TASK_EVENTS" unlanded-i9 'done' landed fm/unlanded-i9 local-only '' 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a task with no closure evidence must still be un-closable"
  assert_contains "$out" 'closure evidence' "the refusal should name the missing evidence"

  # 3. And it is still in the audit: a cleared card is not a closed task.
  audit=$(FM_TEST_VISIBILITY_LOG="$home/visibility.log" node "$home/visibility.mjs" audit --json)
  [ "$(printf '%s' "$audit" | jq -r '[.records[].id] | index("unlanded-i9") // "missing"')" != missing ] \
    || fail "a dispositioned task must still appear in the visibility audit"

  # 4. The item also stays enumerable for triage: it is dispositioned, not erased.
  assert_contains "$(run_in_home "$home" "$RECONCILE" list)" 'unlanded-i9' \
    "a dispositioned item must stay listed for the enumerator"
  pass "clearing attention is not closure: the evidence gate and the audit both survive"
}

test_board_outage_still_clears_the_card() {
  local home
  home=$(new_home outage)
  own_lock "$home"
  write_task "$home" offline-j1 'done: ready in branch fm/offline-j1'
  # A curl that always fails is a cockpit that is down.
  printf '#!/usr/bin/env bash\nexit 7\n' > "$home/fakebin/curl"
  chmod +x "$home/fakebin/curl"

  disposition "$home" resolve offline-j1 --link 'local-main-abc1234' > /dev/null 2>&1
  assert_grep 'attentionOwner=none' "$home/state/offline-j1.meta" \
    "a disposition recorded while the board is down must still clear the card"
  [ -z "$(run_in_home "$home" "$RECONCILE" 2>/dev/null)" ] \
    || fail "a dispositioned item must not wake firstmate even when the board write failed"
  pass "a cleared card does not depend on the cockpit being up"
}

test_terminal_disposition_clears_board_attention
test_held_presents_as_held_with_reason_and_date
test_captain_batch_hands_the_card_to_the_captain
test_hold_expiry_restores_attention
test_legacy_unreviewable_hold_presents_as_open
test_unattended_ids_lists_open_items_only
test_new_signal_reopens_a_dispositioned_card
test_resurface_restores_attention
test_dangling_successor_reopens_the_card
test_clearing_attention_is_not_closure
test_board_outage_still_clears_the_card

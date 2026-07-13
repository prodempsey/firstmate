#!/usr/bin/env bash
# Behavior tests for reconciling a recorded fleet-triage disposition into board attention.
#
# The load-bearing properties:
#   - the OUTCOME TYPE decides whether attention is cleared, transferred, or held: only an
#     outcome meaning firstmate is FINISHED with the item may clear its card;
#   - a disposition that finishes the item (resolved, rejected, successor_created) stops it
#     presenting as active FirstMate attention, and stops it waking firstmate, without anyone
#     remembering to do it;
#   - a captain batch TRANSFERS the decision: the card stays visible and lands with the
#     captain, through the one writer of the captain-attention column;
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
  # bin/fm-nf-ack.sh verifies its own write against. The real Bridge TAKES the event in
  # snake_case and READS IT BACK in camelCase, so this stand-in must too - a read-back keyed
  # to the spelling we sent matched nothing on the real board, and every confirmed hand-off
  # was reported as a failed one.
  awk -F '\t' -v url="$url" '$1 == url {last = $2} END {print (last == "" ? "{}" : last)}' \
    "$FM_TEST_BOARD_LOG" 2>/dev/null \
    | jq -c 'with_entries(.key |= (if . == "open_item_id" then "openItemId"
                                   elif . == "successor_id" then "successorId"
                                   elif . == "status_fingerprint" then "statusFingerprint"
                                   else . end))'
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
#
# It must also not clear the card on the way. A captain batch is the outcome that TRANSFERS a
# decision, not one that ends it: the attentionOwner=none override the other terminal outcomes
# write outranks every derived signal, so writing it here took a decision the captain still
# owed straight off his board and left it in `stale` with no owner at all.
test_captain_batch_hands_the_card_to_the_captain() {
  local home body
  home=$(new_home captain-batch)
  own_lock "$home"
  write_task "$home" decide-k2 'needs-decision: two viable designs'

  disposition "$home" captain-batch decide-k2 --link order-ORD-041 > /dev/null \
    || fail "recording a captain batch should succeed"

  assert_no_grep 'attentionOwner=' "$home/state/decide-k2.meta" \
    "a captain batch must not clear the card; the decision is still owed, by the captain"
  body=$(grep '/api/card/' "$home/board.log" | cut -f2 | tail -n 1)
  [ "$(printf '%s' "$body" | jq -r '.event')" = to_captain ] \
    || fail "a captain batch should transfer board attention to the captain, got: $body"
  # The open item is the item's real lane-qualified triage id: that is what the captain's
  # board opens the decision against, and it is what the attention API takes.
  [ "$(printf '%s' "$body" | jq -r '.open_item_id')" = needs_firstmate:decide-k2 ] \
    || fail "the hand-off should name the item's lane-qualified id, got: $body"
  assert_grep 'decide-k2' "$home/state/.nf-handled" \
    "the hand-off should go through the one writer of the captain-attention column"
  assert_grep 'needs_firstmate:decide-k2' "$home/state/.nf-to-captain" \
    "a confirmed hand-off should leave the captain-attention receipt bin/fm-guard.sh reads"
  pass "a captain batch hands the card to the captain without clearing it"
}

# The regression this whole fix exists for. Every terminal outcome used to clear the card, so
# nothing distinguished "firstmate is finished with it" from "the captain now owes it" - and a
# recorded captain batch silently deleted a decision the captain still owed. The end-state of
# EACH outcome is asserted here, because the bug was that no test told them apart.
test_each_outcome_moves_attention_its_own_way() {
  local home last out
  home=$(new_home outcomes)
  own_lock "$home"
  write_task "$home" resolved-m1 'done: ready in branch fm/resolved-m1'
  write_task "$home" rejected-m2 'failed: not worth doing'
  write_task "$home" successor-m3 'failed: wrong approach'
  write_task "$home" successor-heir-m3 'working: redoing it properly'
  write_task "$home" captain-m4 'needs-decision: two viable designs'
  write_task "$home" held-m5 'blocked: needs an upstream fix'

  disposition "$home" resolve resolved-m1 --link local-main-abc1234 > /dev/null
  disposition "$home" reject rejected-m2 --reason 'superseded by the rewrite' > /dev/null
  disposition "$home" successor successor-m3 --link successor-heir-m3 > /dev/null
  disposition "$home" captain-batch captain-m4 --link captain-away-20260713 > /dev/null
  disposition "$home" hold held-m5 --reason 'upstream fix lands in v2.4' \
    --review-after 2026-08-01 > /dev/null

  # 1-3. FirstMate is finished with these three, so they stop presenting as its attention.
  #      This is the behavior the fix must not weaken.
  assert_grep 'attentionOwner=none' "$home/state/resolved-m1.meta" \
    "resolved should clear firstmate attention"
  assert_grep 'attentionOwner=none' "$home/state/rejected-m2.meta" \
    "rejected should clear firstmate attention"
  assert_grep 'attentionOwner=none' "$home/state/successor-m3.meta" \
    "successor_created should clear firstmate attention"

  # 4. A captain batch TRANSFERS: the card stays on the board and lands with the captain.
  assert_no_grep 'attentionOwner=' "$home/state/captain-m4.meta" \
    "captain_batch must not clear the card"
  last=$(grep "/api/card/[^/]*/captain-m4/attention" "$home/board.log" | cut -f2 | tail -n 1)
  [ "$(printf '%s' "$last" | jq -r '.event')" = to_captain ] \
    || fail "captain_batch should hand the card to the captain, got: $last"

  # 5. A hold PARKS: the card stays firstmate's, visible, presenting as held with its reason
  #    and review date - it must not vanish either.
  assert_no_grep 'attentionOwner=' "$home/state/held-m5.meta" \
    "held must not clear the card"
  assert_grep 'attention_state=held' "$home/state/held-m5.meta" "held should present as held"
  assert_grep 'attention_hold_reason=upstream fix lands in v2.4' "$home/state/held-m5.meta" \
    "a hold should carry its reason"
  assert_grep 'attention_hold_review_after=2026-08-01' "$home/state/held-m5.meta" \
    "a hold should carry its review date"

  # And the two non-clearing outcomes never post the board event that says firstmate reviewed
  # and finished with the card, which is what the clearing outcomes post.
  [ "$(grep -c "/api/card/[^/]*/captain-m4/attention" "$home/board.log")" = 1 ] \
    || fail "a captain batch should post exactly the hand-off, nothing that walks it back"

  # Firstmate is done with all five, so none of them keeps waking it - but the two the fleet
  # still owes are reported apart from the three it has finished with, and the captain batch
  # names the batch the decision went into rather than reading as an unconfirmed hand-off.
  [ -z "$(run_in_home "$home" "$RECONCILE")" ] \
    || fail "a confirmed hand-off, a hold, and three finished items must not wake firstmate"
  out=$(run_in_home "$home" "$RECONCILE" list)
  assert_contains "$out" '0 unhandled, 1 held, 1 with the captain, 3 dispositioned' \
    "each outcome should be counted as what it is"
  assert_contains "$out" '  with-the-captain: still owed, in batch captain-away-20260713' \
    "a captain batch should name the batch the decision is waiting in"
  pass "each outcome type moves attention its own way: cleared, transferred, or held"
}

# A hand-off the board refused is not a hand-off. The card must keep asking firstmate so the
# next pass retries it - the one thing it must never do is disappear from both columns.
test_a_refused_hand_off_keeps_the_card() {
  local home
  home=$(new_home captain-batch-refused)
  own_lock "$home"
  write_task "$home" refused-n7 'needs-decision: which of the two designs'
  # A curl that always fails is a board that refused the write (or a cockpit that is down).
  printf '#!/usr/bin/env bash\nexit 22\n' > "$home/fakebin/curl"
  chmod +x "$home/fakebin/curl"

  disposition "$home" captain-batch refused-n7 --link captain-away-20260713 > /dev/null 2>&1 \
    || true
  assert_no_grep 'attentionOwner=' "$home/state/refused-n7.meta" \
    "a refused hand-off must never clear the card"
  assert_contains "$(run_in_home "$home" "$RECONCILE" 2>/dev/null)" 'refused-n7' \
    "a decision that never reached the captain must keep asking firstmate"

  # The board comes back; the next pass completes the hand-off it owed.
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
  awk -F '\t' -v url="$url" '$1 == url {last = $2} END {print (last == "" ? "{}" : last)}' \
    "$FM_TEST_BOARD_LOG" 2>/dev/null \
    | jq -c 'with_entries(.key |= (if . == "open_item_id" then "openItemId"
                                   elif . == "successor_id" then "successorId"
                                   elif . == "status_fingerprint" then "statusFingerprint"
                                   else . end))'
fi
SH
  chmod +x "$home/fakebin/curl"
  run_in_home "$home" "$ATTENTION" sync > /dev/null
  assert_contains "$(board_events "$home")" 'to_captain' \
    "the retry should complete the hand-off the failed write owed"
  pass "a refused hand-off keeps the card and retries"
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

# The turn-end guard's sweep is a thin, level-triggered view over fm_nf_attention_desired,
# with the GATE's discharge rule on top: only resolved and rejected discharge it. A valid
# dated hold parks the board card, never the gate, so a held item still lists here even
# though the reconciler reports it as held rather than unhandled.
test_unattended_ids_apply_the_gate_discharge_rule() {
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
  printf '%s\n' "$out" | grep -qxF 'open-e5' || fail "an undispositioned item must list, got: $out"
  printf '%s\n' "$out" | grep -qxF 'parked-h8' || fail "a held item must still hold the gate, got: $out"
  printf '%s\n' "$out" | grep -qxF 'landed-g7' && fail "a resolved item must not hold the gate, got: $out"
  printf '%s\n' "$out" | grep -qxF 'busy-f6' && fail "a working task is not a terminal signal, got: $out"
  pass "fm_nf_unattended_ids lists gate-holding items: open and held in, resolved and non-terminal out"
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
test_each_outcome_moves_attention_its_own_way
test_a_refused_hand_off_keeps_the_card
test_hold_expiry_restores_attention
test_legacy_unreviewable_hold_presents_as_open
# The seam between the board card and the turn-end gate. They read the SAME captain-batch
# disposition and the SAME receipt, and they must agree: a confirmed hand-off puts the card in
# the captain's column AND stops the gate re-blocking the primary on a decision only the
# captain can make; an unconfirmed one leaves BOTH asking firstmate. A captain batch that
# discharged the gate without landing the card would be the original bug wearing a new hat.
test_captain_batch_satisfies_the_board_and_the_gate_together() {
  local home out body
  home=$(new_home captain-batch-gate)
  own_lock "$home"
  write_task "$home" decide-p9 'needs-decision: which of the two designs'

  disposition "$home" captain-batch decide-p9 --link captain-away-20260714 > /dev/null \
    || fail "recording a captain batch should succeed"

  # Board side: the card is handed over, never cleared.
  assert_no_grep 'attentionOwner=' "$home/state/decide-p9.meta" \
    "a captain batch must not clear the card"
  body=$(grep '/api/card/' "$home/board.log" | cut -f2 | tail -n 1)
  [ "$(printf '%s' "$body" | jq -r '.event')" = to_captain ] \
    || fail "the card should be handed to the captain, got: $body"

  # Gate side: the hand-off is confirmed by the fingerprint-bound receipt, so the gate lets
  # the primary end its turn instead of re-blocking on the captain's own decision.
  out=$(bash -c '. "$1/bin/fm-nf-attention-lib.sh"; fm_nf_unattended_ids "$2/state" "$2/data"' \
    _ "$ROOT" "$home")
  printf '%s\n' "$out" | grep -qxF 'decide-p9' \
    && fail "a CONFIRMED captain batch must not hold the turn-end gate, got: $out"

  # Now the same item with its receipt gone: the hand-off is no longer provable, so the card
  # goes back to asking firstmate and the gate blocks again. Neither side may take the ledger
  # row alone as proof the captain can see the decision.
  rm -f "$home/state/.nf-to-captain"
  out=$(bash -c '. "$1/bin/fm-nf-attention-lib.sh"; fm_nf_unattended_ids "$2/state" "$2/data"' \
    _ "$ROOT" "$home")
  printf '%s\n' "$out" | grep -qxF 'decide-p9' \
    || fail "an UNCONFIRMED captain batch must still hold the turn-end gate, got: $out"
  assert_contains "$(run_in_home "$home" "$RECONCILE")" 'decide-p9' \
    "an unconfirmed hand-off must keep asking firstmate"
  pass "a captain batch discharges the gate and lands the card, or neither"
}

test_unattended_ids_apply_the_gate_discharge_rule
test_captain_batch_satisfies_the_board_and_the_gate_together
test_new_signal_reopens_a_dispositioned_card
test_resurface_restores_attention
test_dangling_successor_reopens_the_card
test_clearing_attention_is_not_closure
test_board_outage_still_clears_the_card

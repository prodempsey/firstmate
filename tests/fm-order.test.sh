#!/usr/bin/env bash
# Behavior tests for the Captain Order Inbox (bin/fm-order.sh, bin/fm-order-lib.sh,
# bin/fm-order-duty.sh, bin/fm-order-capture-hook.sh).
#
# The load-bearing property under test is that a captain request is never lost and never
# falsely reported as safe. Everything here is a way of failing that: a burst where only
# the first request survives, a re-delivery that quietly forks into a second order, a
# write that failed while the acknowledgment said it succeeded, a lock refusal treated as
# a no-op, an inbox that went missing and read as "no orders", and a restart that forgets
# what was already recorded.
set -u

# shellcheck disable=SC1091 # Dynamic test-library path is resolved from BASH_SOURCE.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck disable=SC2153 # ROOT is provided by tests/lib.sh.
ORDER="$ROOT/bin/fm-order.sh"
DUTY="$ROOT/bin/fm-order-duty.sh"
HOOK="$ROOT/bin/fm-order-capture-hook.sh"
TMP_ROOT=$(fm_test_tmproot fm-order)

new_inbox() {  # <name> -> prints the inbox path
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  printf '%s/captain-orders.jsonl' "$dir"
}

# --- burst intake -------------------------------------------------------------------
# The captain sends four requests without waiting. All four must exist, in arrival order,
# each with its own id and the captain's own words.
INBOX=$(new_inbox burst)
export FM_ORDERS_PATH="$INBOX"

OUT=$("$ORDER" add \
  "Fix the bug history mismatch." \
  "Scout a new Helm layout." \
  "Investigate why reports lack successors." \
  "Add filtering to the bug list." 2>/dev/null)
[ "$(printf '%s\n' "$OUT" | grep -c '^recorded: ')" -eq 4 ] \
  || fail "burst intake recorded $(printf '%s\n' "$OUT" | grep -c '^recorded: ') of 4 requests"
pass "a burst of four requests is recorded in one intake"

IDS=$("$ORDER" list --json | jq -r '.orders[].order_id' | tr '\n' ' ')
[ "$IDS" = "ORD-001 ORD-002 ORD-003 ORD-004 " ] || fail "arrival order not preserved: $IDS"
pass "arrival order is preserved and every order has a stable id"

VERBATIM=$("$ORDER" show ORD-003 --json | jq -r '.original_request')
[ "$VERBATIM" = "Investigate why reports lack successors." ] \
  || fail "captain wording was not preserved verbatim: $VERBATIM"
pass "the captain original wording is preserved verbatim"

# A short title never replaces the captain's words.
"$ORDER" triage ORD-003 --title "Successor gap scout" >/dev/null
STILL=$("$ORDER" show ORD-003 --json | jq -r '.original_request')
[ "$STILL" = "Investigate why reports lack successors." ] \
  || fail "a normalized title overwrote the captain original request"
pass "a normalized short title does not overwrite the original request"

# --- idempotency and duplicate delivery ----------------------------------------------
BEFORE=$("$ORDER" list --json | jq '.orders | length')
DUP=$("$ORDER" add "Fix the bug history mismatch." 2>/dev/null)
AFTER=$("$ORDER" list --json | jq '.orders | length')
[ "$BEFORE" = "$AFTER" ] || fail "a re-delivered request created a second order"
printf '%s' "$DUP" | grep -q '^duplicate: ORD-001' \
  || fail "a re-delivered request did not link to the order that already holds it: $DUP"
pass "duplicate delivery links to the existing order instead of forking a second one"

COUNT=$("$ORDER" show ORD-001 --json | jq '.duplicate_delivery_count')
[ "$COUNT" = 1 ] || fail "the duplicate delivery was not preserved as evidence"
EV=$("$ORDER" show ORD-001 --json | jq -r '.duplicate_evidence[0].original_request')
[ "$EV" = "Fix the bug history mismatch." ] || fail "duplicate evidence lost the request text"
pass "the duplicate delivery is preserved as evidence on the existing order"

# Whitespace is not a different request.
"$ORDER" add "Fix   the bug history
mismatch." >/dev/null 2>&1
AFTER2=$("$ORDER" list --json | jq '.orders | length')
[ "$AFTER2" = "$AFTER" ] || fail "re-wrapped whitespace forked a duplicate order"
pass "whitespace-only differences do not fork a duplicate order"

# --- acknowledgment follows the write ------------------------------------------------
ACK=$("$ORDER" ack ORD-001 ORD-002)
printf '%s' "$ACK" | grep -q '^Recorded:' || fail "ack did not print the receipt block"
printf '%s' "$ACK" | grep -q 'ORD-001.*received' || fail "ack did not report the durable status"
pass "ack prints the brief receipt block from the durable record"

if "$ORDER" ack ORD-999 >/dev/null 2>&1; then
  fail "ack claimed an order that is not in the inbox was recorded"
fi
pass "ack refuses to acknowledge an order the inbox does not hold"

# --- partial failure ------------------------------------------------------------------
# Half a burst recorded must never read as a whole burst recorded. An unwritable inbox is
# the cheapest way to force the failure the acknowledgment contract turns on.
PART=$(new_inbox partial)
FM_ORDERS_PATH="$PART" "$ORDER" add "first request" >/dev/null 2>&1
chmod a-w "$PART"
set +e
POUT=$(FM_ORDERS_PATH="$PART" "$ORDER" add "second request" 2>&1)
PRC=$?
set -e
chmod u+w "$PART"
[ "$PRC" -ne 0 ] || fail "a failed intake exited zero"
printf '%s' "$POUT" | grep -q 'INTAKE FAILED' || fail "a failed intake did not say so: $POUT"
printf '%s' "$POUT" | grep -qi 'do not acknowledge' \
  || fail "a failed intake did not warn against acknowledging it"
printf '%s' "$POUT" | grep -q '^recorded: ' \
  && fail "a failed intake still printed a success line for the request it lost"
COUNT=$(FM_ORDERS_PATH="$PART" "$ORDER" list --json | jq '.orders | length')
[ "$COUNT" = 1 ] || fail "the failed request was somehow recorded anyway"
pass "a failed write is surfaced, exits non-zero, and never acknowledges the lost request"

# --- lock refusal ---------------------------------------------------------------------
LOCKED=$(new_inbox locked)
FM_ORDERS_PATH="$LOCKED" "$ORDER" init >/dev/null
mkdir "$LOCKED.lock"
printf '%s\n' "$$" > "$LOCKED.lock/pid"   # a LIVE holder: this test's own pid
set +e
LOUT=$(FM_ORDERS_PATH="$LOCKED" FM_ORDER_LOCK_TIMEOUT=1 "$ORDER" add "request during a locked inbox" 2>&1)
LRC=$?
set -e
[ "$LRC" -ne 0 ] || fail "a refused writer lock exited zero"
printf '%s' "$LOUT" | grep -q 'NOTHING was recorded' \
  || fail "a refused writer lock did not say the request was not recorded: $LOUT"
[ "$(FM_ORDERS_PATH="$LOCKED" "$ORDER" list --json | jq '.orders | length')" = 0 ] \
  || fail "a request was written despite the refused lock"
rm -rf "$LOCKED.lock"
# A dead holder must never wedge intake: the next writer breaks the abandoned lock.
mkdir "$LOCKED.lock"
printf '999999\n' > "$LOCKED.lock/pid"
FM_ORDERS_PATH="$LOCKED" FM_ORDER_LOCK_TIMEOUT=1 "$ORDER" add "request after an abandoned lock" >/dev/null 2>&1 \
  || fail "an abandoned lock (dead holder) wedged intake"
pass "a live writer lock refuses the write loudly; an abandoned one is broken, not obeyed"

# --- missing and unreadable state ------------------------------------------------------
set +e
MOUT=$(FM_ORDERS_PATH="$TMP_ROOT/gone/captain-orders.jsonl" "$ORDER" list 2>&1)
MRC=$?
set -e
[ "$MRC" -ne 0 ] || fail "a missing inbox read as an empty inbox and exited zero"
printf '%s' "$MOUT" | grep -q 'NOT the same as an empty inbox' \
  || fail "a missing inbox did not fail visibly: $MOUT"
pass "a missing inbox fails visibly instead of folding to zero orders"

# A corrupt row is skipped, never fatal, and never silent: a malformed received row loses
# a captain request verbatim, which is exactly the thing that must remain repairable.
CORRUPT=$(new_inbox corrupt)
FM_ORDERS_PATH="$CORRUPT" "$ORDER" add "a good request" >/dev/null 2>&1
printf 'this is not json\n' >> "$CORRUPT"
HEALTH=$(FM_ORDERS_PATH="$CORRUPT" "$ORDER" health)
[ "$(printf '%s' "$HEALTH" | jq '.malformed_rows')" = 1 ] \
  || fail "a malformed row was not counted"
[ "$(FM_ORDERS_PATH="$CORRUPT" "$ORDER" list --json | jq '.orders | length')" = 1 ] \
  || fail "a malformed row broke the fold instead of being skipped"
FM_ORDERS_PATH="$CORRUPT" "$DUTY" 2>&1 >/dev/null | grep -q 'malformed row' \
  || fail "the duty banner stayed silent about a corrupt inbox"
pass "a malformed row is skipped, counted, and surfaced rather than lost silently"

# --- restart recovery -------------------------------------------------------------------
# Nothing about the inbox lives in a process: a fresh invocation with no shared state must
# see every order, its lineage, and its history exactly as the last one left them.
export FM_ORDERS_PATH="$INBOX"
"$ORDER" dispatch ORD-002 --scout helm-scout-x9 >/dev/null
"$ORDER" claim ORD-002 --owner crew-helm-scout-x9 >/dev/null
REC=$(env -i PATH="$PATH" HOME="$HOME" FM_ORDERS_PATH="$INBOX" "$ORDER" show ORD-002 --json)
[ "$(printf '%s' "$REC" | jq -r '.status')" = dispatched ] || fail "status did not survive a restart"
[ "$(printf '%s' "$REC" | jq -r '.owner')" = crew-helm-scout-x9 ] || fail "owner did not survive a restart"
[ "$(printf '%s' "$REC" | jq -r '.linked_scout_ids[0]')" = helm-scout-x9 ] \
  || fail "lineage did not survive a restart"
HIST=$(env -i PATH="$PATH" HOME="$HOME" FM_ORDERS_PATH="$INBOX" "$ORDER" show ORD-002 --history)
printf '%s' "$HIST" | grep -q 'received' || fail "audit history lost the received event"
printf '%s' "$HIST" | grep -q 'dispatch' || fail "audit history lost the dispatch event"
pass "orders, lineage, and audit history survive a restart with no shared process state"

# --- lineage contract --------------------------------------------------------------------
"$ORDER" dispatch ORD-004 >/dev/null 2>&1 \
  && fail "an order was dispatched to nothing"
"$ORDER" complete ORD-004 >/dev/null 2>&1 \
  && fail "an order was completed with no outcome link"
"$ORDER" reject ORD-004 >/dev/null 2>&1 \
  && fail "an order was rejected with no reason"
"$ORDER" hold ORD-004 --reason "waiting on the captain" >/dev/null 2>&1 \
  && fail "an order was held with no review condition"
pass "a disposition with no lineage is refused: seen is not handled"

"$ORDER" release ORD-002 >/dev/null
[ "$("$ORDER" show ORD-002 --json | jq -r '.owner')" = null ] \
  || fail "release did not clear the owner"
pass "release clears a claim, because an explicit null is an update"

"$ORDER" complete ORD-002 --link "data/helm-scout-x9/report.md" >/dev/null
DONE=$("$ORDER" show ORD-002 --json)
[ "$(printf '%s' "$DONE" | jq -r '.outcome_type')" = completed ] || fail "outcome_type not recorded"
[ "$(printf '%s' "$DONE" | jq -r '.actionable')" = false ] \
  || fail "a completed order with lineage is still demanding attention"
pass "a completed order with lineage stops asking for attention"

# --- attention rules -----------------------------------------------------------------
# An untriaged order, an unowned dispatch, an expired hold, and a cleared blocker are the
# states in which an order is waiting on firstmate and nothing else will say so.
ATT=$(new_inbox attention)
export FM_ORDERS_PATH="$ATT"
"$ORDER" add "untriaged one" "hold one" "blocked one" "blocker" >/dev/null 2>&1
"$ORDER" hold ORD-002 --reason "captain asked to wait" --review-after 2020-01-01 >/dev/null
"$ORDER" block ORD-003 --reason "waits on ORD-004" --depends-on ORD-004 >/dev/null
"$ORDER" complete ORD-004 --link "local main" >/dev/null
LIST=$("$ORDER" list --json)
att() { printf '%s' "$LIST" | jq -r --arg id "$1" '.orders[] | select(.order_id == $id) | .attention'; }
[ "$(att ORD-001)" = untriaged ] || fail "an untriaged order did not surface: $(att ORD-001)"
[ "$(att ORD-002)" = hold_expired ] || fail "an expired hold did not surface: $(att ORD-002)"
[ "$(att ORD-003)" = blocker_cleared ] || fail "a cleared blocker did not surface: $(att ORD-003)"
[ "$(att ORD-004)" = ok ] || fail "a completed order is still actionable: $(att ORD-004)"
pass "untriaged, expired-hold, and cleared-blocker orders surface as needing action"

# --- chat capture and drain ------------------------------------------------------------
# The runtime half of the mandatory drain: a captain message is on disk before firstmate
# reasons about it, and it stays visible until it is recorded or explicitly dismissed.
CAPTURED=$(new_inbox captured)
export FM_ORDERS_PATH="$CAPTURED"
printf '{"prompt":"Add pagination to the bug list."}' | "$HOOK"
printf '{"prompt":"Add pagination to the bug list."}' | "$HOOK"   # a replayed prompt
"$HOOK" --text "thanks, that looks right"
[ "$("$ORDER" pending --json | jq 'length')" = 2 ] \
  || fail "the hook did not spool exactly two distinct captures"
pass "a chat capture is spooled before firstmate takes a turn, and a replay does not double it"

"$DUTY" 2>&1 >/dev/null | grep -q 'NOT yet drained' \
  || fail "the duty banner did not surface undrained captures"
pass "an undrained capture is visible at turn start without relying on an instruction"

CAP=$("$ORDER" pending --json | jq -r '.[] | select(.text | startswith("Add pagination")) | .capture_id')
CHATTER=$("$ORDER" pending --json | jq -r '.[] | select(.text | startswith("thanks")) | .capture_id')
"$ORDER" add --from-pending "$CAP" >/dev/null
[ "$("$ORDER" list --json | jq -r '.orders[0].original_request')" = "Add pagination to the bug list." ] \
  || fail "the drained capture did not preserve the captain wording"
"$ORDER" dismiss "$CHATTER" --reason "not a request: acknowledgment" >/dev/null
[ "$("$ORDER" pending --json | jq 'length')" = 0 ] || fail "the spool did not clear after the drain"
"$ORDER" dismiss "$CHATTER" >/dev/null 2>&1 && fail "a capture was dismissed with no reason"
grep -q 'not a request' "$(dirname "$CAPTURED")/captain-chat-dismissed.jsonl" \
  || fail "a dismissed capture was dropped instead of durably recorded"
pass "a drained capture becomes an order verbatim; a dismissal is recorded with its reason"

# Re-capturing and re-draining the same message after a restart must not fork an order.
printf '{"prompt":"Add pagination to the bug list."}' | "$HOOK"
"$ORDER" add --from-pending "$CAP" >/dev/null 2>&1
[ "$("$ORDER" list --json | jq '.orders | length')" = 1 ] \
  || fail "re-draining a replayed capture forked a second order"
pass "re-draining the same capture after a restart is idempotent"

[ -z "$("$DUTY" 2>&1 >/dev/null)" ] && fail "the duty banner stayed silent with an untriaged order"
"$ORDER" triage ORD-001 --title "Bug list pagination" >/dev/null
"$ORDER" dispatch ORD-001 --task bug-list-page-a1 >/dev/null
"$ORDER" claim ORD-001 --owner crew-bug-list-page-a1 >/dev/null
[ -z "$("$DUTY" 2>&1 >/dev/null)" ] || fail "the duty banner still fires on a clear inbox"
pass "the duty banner goes silent once every order is triaged, owned, and linked"

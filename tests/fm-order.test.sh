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

# A writer that died AFTER mkdir but BEFORE recording its pid leaves a PID-LESS
# lockdir (the pid write is best-effort). That must be reclaimed once it ages past
# the grace, not wedge intake forever. Backdate the lockdir mtime so it is already
# past a 1-second grace on the first probe.
rm -rf "$LOCKED.lock"
mkdir "$LOCKED.lock"                      # no pid file: writer died before the pid write
touch -t 197001010101 "$LOCKED.lock"      # age it well past the grace
FM_ORDERS_PATH="$LOCKED" FM_ORDER_LOCK_TIMEOUT=3 FM_ORDER_LOCK_PIDLESS_GRACE=1 \
  "$ORDER" add "request after a pid-less lock" >/dev/null 2>&1 \
  || fail "a pid-less abandoned lockdir (writer died before the pid write) wedged intake"
# And a FRESH pid-less lockdir inside the grace must still be respected, not stolen:
# with a grace longer than the timeout, the write is refused rather than racing a
# writer that may be about to record its pid.
rm -rf "$LOCKED.lock"
mkdir "$LOCKED.lock"                      # fresh pid-less lockdir (mtime = now)
set +e
FROUT=$(FM_ORDERS_PATH="$LOCKED" FM_ORDER_LOCK_TIMEOUT=1 FM_ORDER_LOCK_PIDLESS_GRACE=30 \
  "$ORDER" add "request against a fresh pid-less lock" 2>&1)
FRRC=$?
set -e
[ "$FRRC" -ne 0 ] || fail "a fresh pid-less lock inside its grace was stolen instead of respected"
printf '%s' "$FROUT" | grep -q 'NOTHING was recorded' \
  || fail "a fresh pid-less lock refusal did not report the request was not recorded: $FROUT"
rm -rf "$LOCKED.lock"
pass "a pid-less lock is reclaimed only after its grace: aged is broken, fresh is respected"

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

# --- a real-sized inbox ----------------------------------------------------------------
# THE TEST THAT WOULD HAVE CAUGHT IT. Every read path in fm-order.sh was dead on the real
# inbox and green in this file, because this file only ever built a handful of orders. The
# reader passed the folded ledger to jq as an ARGUMENT, so it worked until the fold outgrew
# the kernel's per-argument limit (128KB on Linux) and then failed all at once with
# "Argument list too long" - digest, list, metrics, the duty banner, and the fleet-triage
# captain-orders lane, on an inbox whose data was perfectly intact.
#
# So the fixture is generated large enough to have tripped the original E2BIG, and asserted
# to still be that large: a fixture that quietly shrinks below the limit is a test that
# quietly stops testing this. It is generated, never committed - the inbox is real captain
# data and the real one is never read, copied, or written by this suite.
BIG=$(new_inbox big)
export FM_ORDERS_PATH="$BIG"
BIG_ORDERS=400
PAD=$(printf 'x%.0s' $(seq 1 800))
i=1
while [ "$i" -le "$BIG_ORDERS" ]; do
  printf '{"schema":"firstmate/captain-order/v1","order_id":"ORD-%03d","event":"received","ts":"2026-07-01T00:00:00Z","received_at":"2026-07-01T00:00:00Z","source":"chat","idempotency_key":"key-%03d","original_request":"captain request %03d %s","short_title":"request %03d","status":"received","priority":"normal","priority_source":"default","owner":null,"linked_task_ids":[],"linked_scout_ids":[],"linked_bug_ids":[],"related_order_ids":[],"dependency_ids":[],"captain_decision_required":false,"recorded_by":"captain","updated_at":"2026-07-01T00:00:00Z"}\n' \
    "$i" "$i" "$i" "$PAD" "$i" >> "$BIG"
  i=$((i + 1))
done

# The argv limit this class of bug dies on is MAX_ARG_STRLEN: 128KB for any SINGLE argument,
# regardless of how much room ARG_MAX leaves overall. The fixture must exceed it, or it is
# not exercising the failure.
ARG_STRLEN_LIMIT=131072
BIG_BYTES=$(wc -c < "$BIG")
[ "$BIG_BYTES" -gt "$ARG_STRLEN_LIMIT" ] \
  || fail "the large-inbox fixture is only $BIG_BYTES bytes: too small to reach the $ARG_STRLEN_LIMIT-byte argument limit that broke every read path, so it proves nothing"

for verb in "list" "list --json" "list --actionable" "list --actionable --json" "metrics" "metrics --json" "digest" "health" "show ORD-200" "ack ORD-200"; do
  # shellcheck disable=SC2086 # The verb and its flags are deliberately word-split.
  "$ORDER" $verb >/dev/null 2>&1 \
    || fail "'$verb' failed on a $BIG_BYTES-byte inbox: the reader still cannot read a real one"
done
pass "every read path survives an inbox far past the argument limit that killed them all"

BIG_TOTAL=$("$ORDER" list --json | jq '.orders | length')
[ "$BIG_TOTAL" = "$BIG_ORDERS" ] \
  || fail "the large inbox folded to $BIG_TOTAL orders, not $BIG_ORDERS: the reader is dropping orders"
[ "$("$ORDER" list --actionable | wc -l)" = "$BIG_ORDERS" ] \
  || fail "--actionable did not surface every untriaged order in the large inbox"
[ "$("$ORDER" metrics --json | jq '.metrics.untriaged')" = "$BIG_ORDERS" ] \
  || fail "metrics undercounted a large inbox"
"$ORDER" digest | grep -q "CAPTAIN ORDERS: $BIG_ORDERS needing action" \
  || fail "the digest did not report every order in a large inbox"
[ "$("$ORDER" show ORD-200 --json | jq -r '.original_request')" = "captain request 200 $PAD" ] \
  || fail "a long captain request was not preserved verbatim in a large inbox"
pass "a large inbox folds to every order, verbatim, across list, metrics, and the digest"

# The duty banner is what the captain actually sees, and it is the thing that was crying
# lost-orders. On a large, intact inbox it must report the orders, not a failure.
BIGDUTY=$("$DUTY" 2>&1 >/dev/null)
printf '%s' "$BIGDUTY" | grep -qi 'could not be read\|reader failed' \
  && fail "the duty banner claimed a large but perfectly intact inbox was unreadable"
printf '%s' "$BIGDUTY" | grep -q "$BIG_ORDERS order(s) still need action" \
  || fail "the duty banner did not report the orders in a large inbox: $BIGDUTY"
pass "the duty banner reads a large inbox truthfully instead of manufacturing a data-loss alarm"

# A captain request is not bounded by an argument list either: a pasted spec arrives through
# the capture hook and is drained into the ledger, and both once handed it to jq as argv.
LONGTEXT=$(printf 'y%.0s' $(seq 1 200000))
LONGBOX=$(new_inbox longtext)
export FM_ORDERS_PATH="$LONGBOX"
printf '{"prompt":"%s"}' "$LONGTEXT" | "$HOOK"
[ "$("$ORDER" pending --json | jq 'length')" = 1 ] \
  || fail "the capture hook silently dropped a captain message larger than the argument limit"
LONGCAP=$("$ORDER" pending --json | jq -r '.[0].capture_id')
"$ORDER" add --from-pending "$LONGCAP" >/dev/null 2>&1 \
  || fail "a captain message larger than the argument limit could not be drained into an order"
[ "$("$ORDER" show ORD-001 --json | jq -r '.original_request | length')" = "${#LONGTEXT}" ] \
  || fail "a long captain request was truncated or lost on its way into the ledger"
pass "a captain message far larger than the argument limit is captured and recorded verbatim"

# --- honest failure modes ---------------------------------------------------------------
# An inbox that cannot be READ and a READER that crashed are different conditions with
# different remedies, and saying "treat this as lost captain requests" for both is how a
# reader's own defect becomes a standing false alarm about the captain's data. The reader
# reports them with different exit codes; the duty banner and the triage lane branch on them.
UNREAD=$(new_inbox unreadable)
export FM_ORDERS_PATH="$UNREAD"
"$ORDER" add "an order that must not be reported as lost" >/dev/null 2>&1
chmod 000 "$UNREAD"
set +e
UOUT=$(FM_ORDERS_PATH="$UNREAD" "$ORDER" list 2>&1)
URC=$?
UDUTY=$(FM_ORDERS_PATH="$UNREAD" "$DUTY" 2>&1 >/dev/null)
set -e
chmod 644 "$UNREAD"
if [ "$URC" -eq 0 ]; then
  # Running as root (or an fs that ignores the mode) makes this unenforceable, not passed.
  pass "SKIPPED: an unreadable inbox cannot be simulated here (the mode did not deny the read)"
else
  [ "$URC" -eq 5 ] || fail "an unreadable inbox exited $URC, not the inbox-unreadable code 5"
  printf '%s' "$UOUT" | grep -qi 'could not be read' \
    || fail "an unreadable inbox did not say so: $UOUT"
  printf '%s' "$UDUTY" | grep -qi 'lost captain requests' \
    || fail "the duty banner did not raise the data alarm for a genuinely unreadable inbox"
  pass "an inbox that cannot be read is reported as possible lost orders, loudly"
fi

# A crashed READER, with the ledger intact underneath it: exactly the shipped failure. The
# reader is broken here by denying it the one jq mode its enrichment step needs, which
# leaves the fold and the health scan working - so the inbox is provably readable and only
# the reader is dead. It must say that, and must NOT cry lost orders.
CRASH=$(new_inbox readercrash)
export FM_ORDERS_PATH="$CRASH"
"$ORDER" add "an order the reader must not disown" >/dev/null 2>&1
SHIMDIR="$TMP_ROOT/shim"
mkdir -p "$SHIMDIR"
REALJQ=$(command -v jq)
cat > "$SHIMDIR/jq" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  [ "\$a" = --slurpfile ] && { printf 'jq: simulated reader defect\n' >&2; exit 5; }
done
exec "$REALJQ" "\$@"
SHIM
chmod +x "$SHIMDIR/jq"
set +e
COUT=$(PATH="$SHIMDIR:$PATH" "$ORDER" list 2>&1)
CRC=$?
CDUTY=$(PATH="$SHIMDIR:$PATH" "$DUTY" 2>&1 >/dev/null)
set -e
[ "$CRC" -eq 6 ] || fail "a crashed reader exited $CRC, not the reader-failed code 6"
printf '%s' "$COUT" | grep -qi 'READER FAILED' \
  || fail "a crashed reader did not say the reader failed: $COUT"
printf '%s' "$COUT" | grep -qi 'simulated reader defect' \
  || fail "a crashed reader did not name the underlying error: $COUT"
printf '%s' "$COUT" | grep -qi 'lost captain requests\|may be lost\|orders may be lost' \
  && fail "a crashed reader claimed the captain's orders may be lost; the ledger was intact"
printf '%s' "$COUT" | grep -qi 'NOT lost orders' \
  || fail "a crashed reader did not say plainly that nothing was lost: $COUT"
printf '%s' "$CDUTY" | grep -qi 'READER FAILED' \
  || fail "the duty banner did not report a reader failure as a reader failure: $CDUTY"
printf '%s' "$CDUTY" | grep -qi 'lost captain requests' \
  && fail "the duty banner raised a false lost-orders alarm for a defect in its own reader"
[ "$(PATH="$SHIMDIR:$PATH" "$ORDER" health | jq '.present')" = true ] \
  || fail "the inbox was not actually readable underneath the simulated reader defect"
pass "a crashed reader blames the reader and names the error, and never disowns the captain's orders"

# === ORD-260 slice S1: the ACCOUNTED predicate, the audit surface, park/rollup, and =====
# === machine-checkable holds. The load-bearing property is that a captain order the ======
# === fleet stopped working is caught (unaccounted), and that queue-with-a-reason - not ===
# === paperwork - is what accounts for it. ================================================

# --- hold validation: a review condition must be machine-checkable ----------------------
# A hold whose review_after is prose nothing can evaluate never expires, so the order it
# parks silently disappears (the L3 loss mode). The write refuses free text; it accepts an
# ISO date, an ISO instant, and the two typed terminal-event keys.
HV=$(new_inbox holdvalidate)
export FM_ORDERS_PATH="$HV"
"$ORDER" add "h1" "h2" "h3" "h4" "h5" "h6" >/dev/null 2>&1
"$ORDER" hold ORD-001 --reason "captain approves it" --review-after "when the captain approves" >/dev/null 2>&1 \
  && fail "a hold on free text was accepted; it can never expire"
"$ORDER" hold ORD-001 --reason r --review-after 2030-01-01 >/dev/null 2>&1 \
  || fail "a hold on a plain ISO date was refused"
"$ORDER" hold ORD-002 --reason r --review-after 2030-01-01T09:00:00Z >/dev/null 2>&1 \
  || fail "a hold on a full ISO instant was refused"
"$ORDER" hold ORD-003 --reason r --review-after "task:fix-login-k3:terminal" >/dev/null 2>&1 \
  || fail "a hold on a task:<id>:terminal event key was refused"
"$ORDER" hold ORD-004 --reason r --review-after "order:ORD-006:terminal" >/dev/null 2>&1 \
  || fail "a hold on an order:<id>:terminal event key was refused"
"$ORDER" hold ORD-005 --reason r --review-after "task::terminal" >/dev/null 2>&1 \
  && fail "a hold on a malformed event key (empty id) was accepted"
"$ORDER" hold ORD-005 --reason r --review-after "queue:x:terminal" >/dev/null 2>&1 \
  && fail "a hold on an unknown event type was accepted as a valid key"
# An empty review condition is still refused, by the lineage contract that owns that path.
HERR=$("$ORDER" hold ORD-005 --reason r 2>&1) && fail "a hold with no review condition was accepted"
printf '%s' "$HERR" | grep -q 'review-after' || fail "an empty-review hold did not name the missing condition: $HERR"
pass "a hold's review condition must be a machine-checkable date or typed event key, never free text"

# --- the ACCOUNTED predicate, branch by branch (control plane NOT reachable) -------------
# audit writes a deterministic result file, so give it a temp state dir of its own and never
# the production one. FM_ORDER_ACCOUNT_GRACE_SECS=0 removes the freshness grace so every
# non-fresh branch is exercised directly; the fresh branch is checked separately below.
# FM_ORDER_CP_DATA_DIR points at a nonexistent dir so no control plane is reachable here; the
# control-plane-verified live-work and task-event branches get their own section further down.
ACC=$(new_inbox accounted)
export FM_ORDERS_PATH="$ACC"
export FM_ORDER_CP_DATA_DIR="$TMP_ROOT/no-such-cp-store"
ACC_STATE="$TMP_ROOT/accounted-state"
OLD=2026-01-01T00:00:00Z   # old enough to be well past any grace
"$ORDER" add --received-at "$OLD" \
  "live owner" "no owner" "queued good" "queued no reason" "queued no blocker" \
  "held future" "held past" "held order live" "held order fired" "held task" \
  "decision" "received stale" "blocker target" >/dev/null 2>&1
# ORD-001 dispatched with an owner and linked work; no control plane -> live_owner_unverified.
"$ORDER" dispatch ORD-001 --task task-live >/dev/null
"$ORDER" claim ORD-001 --owner crew-live >/dev/null
# ORD-002 dispatched but never claimed -> unaccounted (no owner, no live task).
"$ORDER" dispatch ORD-002 --task task-orphan >/dev/null
# ORD-003 queued WITH a recorded reason AND a blocker (ORD-012, still live) -> accounted.
"$ORDER" queue ORD-003 --reason "waits on ORD-012" --depends-on ORD-012 >/dev/null
# ORD-004 queued with a blocker but no reason -> unaccounted.
"$ORDER" queue ORD-004 --depends-on ORD-012 >/dev/null
# ORD-005 queued with a reason but no blocker -> unaccounted.
"$ORDER" queue ORD-005 --reason "just waiting" >/dev/null
# ORD-006 held on a future date; ORD-007 held on a past date.
"$ORDER" hold ORD-006 --reason r --review-after 2999-01-01 >/dev/null
"$ORDER" hold ORD-007 --reason r --review-after 2000-01-01 >/dev/null
# ORD-008 held until ORD-012 (a still-live order) terminal -> event not fired -> accounted.
# ORD-009 held until ORD-013 terminal, and ORD-013 is completed below -> fired -> unaccounted.
"$ORDER" hold ORD-008 --reason r --review-after "order:ORD-012:terminal" >/dev/null
"$ORDER" hold ORD-009 --reason r --review-after "order:ORD-013:terminal" >/dev/null
# ORD-010 held on a task terminal event: machine-checkable, but with no control plane reachable
# it cannot be evaluated here -> held_task_event_unverified (accounted, but flagged unverified).
"$ORDER" hold ORD-010 --reason r --review-after "task:some-task-x9:terminal" >/dev/null
# ORD-011 captain_decision with no board receipt -> unaccounted.
"$ORDER" decision ORD-011 --reason "captain must pick A or B" >/dev/null
# ORD-012 left as received (untriaged) -> unaccounted past grace, and a live event target.
# ORD-013 is the fired-event target; complete it so ORD-009's event key has fired.
"$ORDER" complete ORD-013 --link "local main" >/dev/null

# jq's `//` treats BOTH null and false as absent, so `.field // "-"` would turn an
# accounted=false into "-"; select over an array and tostring the first hit instead, so a
# false reads as "false" and a missing (terminal, excluded) order reads as "-".
audit_field() {  # <order-id> <jq-field>
  FM_STATE_OVERRIDE="$ACC_STATE" FM_ORDER_ACCOUNT_GRACE_SECS=0 "$ORDER" audit --json \
    | jq -r --arg id "$1" --arg f "$2" \
        '[.orders[] | select(.order_id == $id) | .[$f]] | if length == 0 then "-" else (.[0] | tostring) end'
}
# With no control plane, the audit records that fact rather than silently pretending to verify.
[ "$(FM_STATE_OVERRIDE="$ACC_STATE" FM_ORDER_ACCOUNT_GRACE_SECS=0 "$ORDER" audit --json | jq -r '.control_plane.available')" = false ] \
  || fail "the audit claimed a control plane was reachable when none was"
[ "$(audit_field ORD-001 basis)" = live_owner_unverified ] || fail "a dispatched order without a reachable control plane was not flagged live_owner_unverified"
[ "$(audit_field ORD-002 accounted)" = false ] || fail "a dispatched order with no owner and no live task was accounted"
[ "$(audit_field ORD-003 basis)" = queued_with_reason_and_blocker ] || fail "a queued order with a reason and a blocker was not accounted"
[ "$(audit_field ORD-004 accounted)" = false ] || fail "a queued order with no reason was accounted"
[ "$(audit_field ORD-005 accounted)" = false ] || fail "a queued order with no blocker was accounted"
[ "$(audit_field ORD-005 unaccounted_reason)" = "queued with no blocker dependency" ] || fail "a blocker-less queue did not name its gap"
[ "$(audit_field ORD-006 basis)" = held_date_future ] || fail "a hold on a future date was not accounted"
[ "$(audit_field ORD-007 accounted)" = false ] || fail "a hold whose review date has passed was accounted"
[ "$(audit_field ORD-008 basis)" = held_event_pending ] || fail "a hold on a live order's terminal event was not accounted"
[ "$(audit_field ORD-009 accounted)" = false ] || fail "a hold whose order-terminal event has fired was still accounted"
[ "$(audit_field ORD-010 basis)" = held_task_event_unverified ] || fail "a task-terminal hold with no control plane was not flagged unverified"
[ "$(audit_field ORD-011 accounted)" = false ] || fail "a captain_decision with no board receipt was accounted"
[ "$(audit_field ORD-012 accounted)" = false ] || fail "a received order past grace was accounted"
pass "ACCOUNTED evaluates every branch with no control plane: fresh/unverified-live/queued/held/decision"

# The blocker target ORD-013 completed -> terminal -> excluded from the audit entirely.
[ "$(audit_field ORD-013 accounted)" = "-" ] \
  || fail "a terminal (completed) order appeared in the non-terminal audit"
pass "a terminal order is excluded from the audit; only non-terminal orders are evaluated"

# The freshness grace: a brand-new order is accounted with the default 4h grace even with no
# lineage, and the same order flips to unaccounted once the grace is zero.
FRESH=$(new_inbox fresh)
export FM_ORDERS_PATH="$FRESH"
"$ORDER" add "just arrived" >/dev/null 2>&1
[ "$(FM_STATE_OVERRIDE="$TMP_ROOT/fresh-state" "$ORDER" audit --json | jq -r '.orders[0].basis')" = fresh ] \
  || fail "a brand-new order was not accounted as fresh under the default grace"
[ "$(FM_STATE_OVERRIDE="$TMP_ROOT/fresh-state" FM_ORDER_ACCOUNT_GRACE_SECS=0 "$ORDER" audit --json | jq -r '.orders[0].accounted')" = false ] \
  || fail "the same order stayed accounted once the grace was removed"
pass "the freshness grace accounts a new order and releases it once the grace elapses"

# A dispatched order with an owner but no linked work is a distinct gap. The CLI cannot
# produce one (dispatch requires a link), so a raw ledger row exercises that predicate branch.
NOLINK=$(new_inbox nolink)
export FM_ORDERS_PATH="$NOLINK"
"$ORDER" add "raw dispatched" >/dev/null 2>&1
printf '{"schema":"firstmate/captain-order/v1","order_id":"ORD-001","event":"dispatch","ts":"2026-01-02T00:00:00Z","status":"dispatched","owner":"crew-x","linked_task_ids":[],"linked_scout_ids":[],"linked_bug_ids":[],"updated_at":"2026-01-02T00:00:00Z"}\n' >> "$NOLINK"
[ "$(FM_STATE_OVERRIDE="$TMP_ROOT/nolink-state" FM_ORDER_ACCOUNT_GRACE_SECS=0 "$ORDER" audit --json | jq -r '.orders[0].unaccounted_reason')" = "dispatched with no linked work" ] \
  || fail "a dispatched order with an owner but no lineage was not caught as unaccounted"
pass "a dispatched order with an owner but no linked work is caught as unaccounted"

# --- the audit result file --------------------------------------------------------------
# The audit writes a deterministic product to state/.order-audit-last.json, the same pattern
# as .triage-duty-last.json, so a later reader (slice S2's gate) does a cheap file read.
AF=$(new_inbox auditfile)
export FM_ORDERS_PATH="$AF"
AF_STATE="$TMP_ROOT/auditfile-state"
"$ORDER" add --received-at "$OLD" "one accounted" "one not" >/dev/null 2>&1
"$ORDER" dispatch ORD-001 --task t >/dev/null; "$ORDER" claim ORD-001 --owner c >/dev/null
FM_STATE_OVERRIDE="$AF_STATE" FM_ORDER_ACCOUNT_GRACE_SECS=0 "$ORDER" audit >/dev/null
RESULT="$AF_STATE/.order-audit-last.json"
[ -f "$RESULT" ] || fail "audit did not write the result file"
[ "$(jq -r '.schema' "$RESULT")" = "fm-order-audit/v1" ] || fail "the audit result file has the wrong schema"
[ "$(jq -r '.non_terminal' "$RESULT")" = 2 ] || fail "the audit result file miscounted non-terminal orders"
[ "$(jq -r '.unaccounted' "$RESULT")" = 1 ] || fail "the audit result file miscounted unaccounted orders"
[ "$(jq -r '.unaccounted_orders[0].order_id' "$RESULT")" = ORD-002 ] || fail "the audit result file did not carry the unaccounted order id"
# The human summary names the count and the offending order.
FM_STATE_OVERRIDE="$AF_STATE" FM_ORDER_ACCOUNT_GRACE_SECS=0 "$ORDER" audit | grep -q "1 of 2 non-terminal order(s) UNACCOUNTED" \
  || fail "the audit human summary did not report the unaccounted count"
# A fully-accounted inbox says so and reports zero.
"$ORDER" complete ORD-002 --link "local main" >/dev/null
FM_STATE_OVERRIDE="$AF_STATE" FM_ORDER_ACCOUNT_GRACE_SECS=0 "$ORDER" audit | grep -q "all 1 non-terminal order(s) accounted" \
  || fail "a clear audit did not report all orders accounted"
pass "audit writes a deterministic result file and prints a truthful summary"

# --- park: the captain-parked batch verb ------------------------------------------------
PK=$(new_inbox park)
export FM_ORDERS_PATH="$PK"
"$ORDER" add --received-at "$OLD" "park a" "park b" "park c" >/dev/null 2>&1
"$ORDER" park 2>/dev/null && fail "park with no ids was accepted"
"$ORDER" park ORD-001 2>/dev/null && fail "park with no --captain-ack was accepted"
"$ORDER" park ORD-001 ORD-002 --captain-ack "captain parked 2026-07-22" >/dev/null \
  || fail "a captain-acked batch park was refused"
[ "$("$ORDER" show ORD-001 --json | jq -r '.status')" = captain_parked ] || fail "park did not set captain_parked"
[ "$("$ORDER" show ORD-001 --json | jq -r '.captain_ack')" = "captain parked 2026-07-22" ] || fail "park did not record the captain receipt"
# captain_parked is terminal: it stops asking for attention and is excluded from the audit.
[ "$("$ORDER" show ORD-001 --json | jq -r '.actionable')" = false ] || fail "a captain_parked order still demands attention"
[ "$("$ORDER" metrics --json | jq -r '.metrics.captain_parked')" = 2 ] || fail "metrics did not count captain_parked orders"
PKAUDIT=$(FM_STATE_OVERRIDE="$TMP_ROOT/park-state" FM_ORDER_ACCOUNT_GRACE_SECS=0 "$ORDER" audit --json)
printf '%s' "$PKAUDIT" | jq -e '.orders[] | select(.order_id == "ORD-001")' >/dev/null \
  && fail "a captain_parked order appeared in the non-terminal audit"
# Re-parking a terminal order is refused rather than silently rewriting its disposition; a
# batch with one bad id still parks the good ones and exits non-zero.
set +e
POUT=$("$ORDER" park ORD-001 ORD-003 --captain-ack "again" 2>&1)
PRC=$?
set -e
[ "$PRC" -ne 0 ] || fail "a park batch containing an already-terminal order exited zero"
printf '%s' "$POUT" | grep -q 'already terminal' || fail "re-parking a terminal order was not refused: $POUT"
[ "$("$ORDER" show ORD-003 --json | jq -r '.status')" = captain_parked ] || fail "the good id in a partial park batch was not parked"
pass "park batches captain-acked parks into a terminal state and refuses to overwrite a terminal one"

# --- rollup: formal supersede-into-lead -------------------------------------------------
RU=$(new_inbox rollup)
export FM_ORDERS_PATH="$RU"
"$ORDER" add --received-at "$OLD" "lead" "saga 1" "saga 2" "saga 3" "other" >/dev/null 2>&1
"$ORDER" rollup ORD-001 2>/dev/null && fail "rollup with no --absorb was accepted"
"$ORDER" rollup ORD-001 --absorb ORD-001 2>/dev/null && fail "rollup of a lead into itself was accepted"
"$ORDER" rollup ORD-099 --absorb ORD-002 2>/dev/null && fail "rollup into a nonexistent lead was accepted"
"$ORDER" rollup ORD-001 --absorb ORD-002 ORD-003 ORD-004 >/dev/null \
  || fail "a variadic rollup of three orders was refused"
for a in ORD-002 ORD-003 ORD-004; do
  [ "$("$ORDER" show "$a" --json | jq -r '.status')" = superseded ] || fail "$a was not superseded by the rollup"
  [ "$("$ORDER" show "$a" --json | jq -r '.outcome_link')" = ORD-001 ] || fail "$a was not linked to the lead"
done
# Chains must terminate in a terminal order: a rollup that would close a supersede cycle is
# refused (ORD-002 already supersedes into ORD-001, so ORD-001 -> ORD-002 would loop).
"$ORDER" rollup ORD-002 --absorb ORD-001 2>/dev/null \
  && fail "a rollup that would create a supersede cycle was accepted"
# An already-terminal order cannot be absorbed (its disposition would be overwritten).
"$ORDER" rollup ORD-001 --absorb ORD-002 2>/dev/null \
  && fail "an already-superseded order was absorbed again"
# The rolled-up saga collapses to one accountable lead thread; the absorbed orders drop out
# of the actionable audit because superseded is terminal.
RUAUDIT=$(FM_STATE_OVERRIDE="$TMP_ROOT/rollup-state" FM_ORDER_ACCOUNT_GRACE_SECS=0 "$ORDER" audit --json)
[ "$(printf '%s' "$RUAUDIT" | jq '[.orders[] | select(.order_id == "ORD-002" or .order_id == "ORD-003")] | length')" = 0 ] \
  || fail "an absorbed order still appears in the non-terminal audit"
pass "rollup supersedes a saga's orders into one lead thread and refuses cycles and terminal absorbs"

# === QA round 1 regressions (report qa-dj-s1-q94) =======================================

# --- Finding 2: `blocked` is never accounted by paperwork alone -------------------------
# The authority grants the queue-with-a-reason exception to `queued` only. A blocked order
# carrying a reason and a dependency but no live work must NOT be accounted.
BLK=$(new_inbox blockedpaper)
export FM_ORDERS_PATH="$BLK"
"$ORDER" add --received-at "$OLD" "blocked with paperwork" "its blocker" >/dev/null 2>&1
"$ORDER" block ORD-001 --reason "waits on ORD-002" --depends-on ORD-002 >/dev/null
BA=$(FM_STATE_OVERRIDE="$TMP_ROOT/blk-state" FM_ORDER_ACCOUNT_GRACE_SECS=0 "$ORDER" audit --json \
     | jq -r '.orders[] | select(.order_id == "ORD-001") | "\(.accounted) \(.basis)"')
[ "$BA" = "false unaccounted" ] \
  || fail "a blocked order with only a reason and a dependency was accounted as paperwork: $BA"
pass "a blocked order is not accounted merely because a block event carries prose and a dependency"

# --- Finding 3: a park receipt never satisfies a captain decision -----------------------
# A captain_parked order is terminal, so it cannot be rewritten into captain_decision at all;
# and even a captain_decision that somehow carries a captain_ack (never a board receipt) is
# unaccounted. Both halves are checked.
DEC=$(new_inbox decisionreceipt)
export FM_ORDERS_PATH="$DEC"
"$ORDER" add --received-at "$OLD" "park then decision" >/dev/null 2>&1
"$ORDER" park ORD-001 --captain-ack "park receipt" >/dev/null
"$ORDER" decision ORD-001 --reason "a different decision" 2>/dev/null \
  && fail "a terminal captain_parked order was rewritten into a captain_decision"
DECR=$("$ORDER" decision ORD-001 --reason "x" 2>&1) || true
printf '%s' "$DECR" | grep -q 'already terminal' || fail "rewriting a terminal order was not refused by name: $DECR"
# A raw captain_decision row carrying a stale captain_ack but no board receipt is unaccounted.
DEC2=$(new_inbox decisionreceipt2)
export FM_ORDERS_PATH="$DEC2"
"$ORDER" add "raw decision" >/dev/null 2>&1
printf '{"schema":"firstmate/captain-order/v1","order_id":"ORD-001","event":"decision","ts":"2026-01-02T00:00:00Z","received_at":"2026-01-01T00:00:00Z","status":"captain_decision","captain_ack":"park receipt","board_receipt":null,"hold_reason":"different decision needed","updated_at":"2026-01-02T00:00:00Z"}\n' >> "$DEC2"
D2A=$(FM_STATE_OVERRIDE="$TMP_ROOT/dec2-state" FM_ORDER_ACCOUNT_GRACE_SECS=0 "$ORDER" audit --json \
      | jq -r '.orders[] | select(.order_id == "ORD-001") | "\(.accounted) \(.unaccounted_reason)"')
[ "$D2A" = "false captain decision pending with no board receipt" ] \
  || fail "a captain_decision carrying only a park receipt was accounted: $D2A"
pass "a park receipt never satisfies a captain decision, and a terminal order cannot be rewritten"

# --- Finding 4: supersede/rollup never leave a dangling or looping chain -----------------
CHN=$(new_inbox chains)
export FM_ORDERS_PATH="$CHN"
"$ORDER" add "a" "b" "c" >/dev/null 2>&1
# The sanctioned supersede writer refuses a nonexistent survivor, so the dangling chain in
# the QA reproduction can never be created.
"$ORDER" supersede ORD-001 --by ORD-999 2>/dev/null \
  && fail "supersede accepted a nonexistent survivor target"
SERR=$("$ORDER" supersede ORD-001 --by ORD-999 2>&1) || true
printf '%s' "$SERR" | grep -q 'does not exist' || fail "supersede did not name the missing target: $SERR"
# duplicate --of a missing order is refused the same way.
"$ORDER" duplicate ORD-001 --of ORD-999 2>/dev/null && fail "duplicate accepted a nonexistent survivor target"
# A rollup whose lead sits on a pre-existing dangling chain (injected raw) is refused: the
# writer resolves the lead's whole survivor chain before writing.
CHN2=$(new_inbox chains2)
export FM_ORDERS_PATH="$CHN2"
"$ORDER" add "dangling lead" "absorb me" >/dev/null 2>&1
printf '{"schema":"firstmate/captain-order/v1","order_id":"ORD-001","event":"supersede","ts":"2026-01-02T00:00:00Z","status":"superseded","outcome_link":"ORD-777","updated_at":"2026-01-02T00:00:00Z"}\n' >> "$CHN2"
RERR=$("$ORDER" rollup ORD-001 --absorb ORD-002 2>&1) || true
printf '%s' "$RERR" | grep -q 'ORD-777 does not exist' \
  || fail "rollup did not reject a lead whose survivor chain dangles: $RERR"
pass "supersede and rollup reject missing survivors and dangling chains at the sanctioned writer"

# --- Finding 5: audit fails nonzero when it cannot publish its result file ---------------
WF=$(new_inbox writefail)
export FM_ORDERS_PATH="$WF"
"$ORDER" add "one order" >/dev/null 2>&1
# A regular file where the state dir should be makes mkdir -p and the atomic write fail.
WF_STATE_PARENT="$TMP_ROOT/writefail-state"
mkdir -p "$WF_STATE_PARENT"
: > "$WF_STATE_PARENT/blocker"
set +e
WFOUT=$(FM_STATE_OVERRIDE="$WF_STATE_PARENT/blocker" "$ORDER" audit 2>&1)
WFRC=$?
set -e
[ "$WFRC" -ne 0 ] || fail "audit exited zero when it could not publish its result file"
printf '%s' "$WFOUT" | grep -q 'could not atomically publish' \
  || fail "audit did not report the publish failure: $WFOUT"
[ ! -f "$WF_STATE_PARENT/blocker/.order-audit-last.json" ] \
  || fail "audit wrote a result file into a path that should have failed"
pass "audit fails nonzero when its deterministic result file cannot be atomically published"

# --- Finding 1: control-plane task truth drives the live-work and task-event branches ----
# This requires a runnable control plane (node + an initialized PGlite store). When one is
# not available - e.g. CI does not install control-plane deps - the branch is unverifiable
# here, and the CP-unavailable fallback is already covered above, so this is skipped.
unset FM_ORDER_CP_DATA_DIR
CP_BIN="$ROOT/control-plane/bin/cp.mjs"
CP_STORE="$TMP_ROOT/cp-store"
if command -v node >/dev/null 2>&1 && [ -f "$CP_BIN" ] \
   && node "$CP_BIN" init --data-dir "$CP_STORE" >/dev/null 2>&1; then
  cp_do() { node "$CP_BIN" "$@" --data-dir "$CP_STORE"; }
  # t-live stays queued (a non-terminal, live status); t-dead is cancelled -> archived.
  cp_do create-task --command-id c1 t-live --kind ship --origin captain_order --order-ref ORD-001 --title live >/dev/null 2>&1
  cp_do create-task --command-id c2 t-dead --kind ship --origin captain_order --order-ref ORD-002 --title dead >/dev/null 2>&1
  DEADREV=$(cp_do task-head t-dead | jq -r '.revision')
  cp_do cancel --command-id c3 --expected-revision "$DEADREV" t-dead --reason "done" >/dev/null 2>&1
  [ "$(cp_do task-head t-dead | jq -r '.status')" = archived ] \
    || fail "the control-plane test fixture did not reach a terminal (archived) task"

  CPBOX=$(new_inbox cpaudit)
  export FM_ORDERS_PATH="$CPBOX"
  CP_STATE="$TMP_ROOT/cpaudit-state"
  "$ORDER" add --received-at "$OLD" "linked live" "linked dead" "held task live" "held task dead" >/dev/null 2>&1
  "$ORDER" dispatch ORD-001 --task t-live >/dev/null; "$ORDER" claim ORD-001 --owner c >/dev/null
  "$ORDER" dispatch ORD-002 --task t-dead >/dev/null; "$ORDER" claim ORD-002 --owner c >/dev/null
  "$ORDER" hold ORD-003 --reason r --review-after "task:t-live:terminal" >/dev/null
  "$ORDER" hold ORD-004 --reason r --review-after "task:t-dead:terminal" >/dev/null
  cp_audit() {  # <order-id> <field>
    FM_STATE_OVERRIDE="$CP_STATE" FM_ORDER_CP_DATA_DIR="$CP_STORE" FM_ORDER_ACCOUNT_GRACE_SECS=0 \
      "$ORDER" audit --json \
      | jq -r --arg id "$1" --arg f "$2" \
          '[.orders[] | select(.order_id == $id) | .[$f]] | if length == 0 then "-" else (.[0] | tostring) end'
  }
  [ "$(FM_STATE_OVERRIDE="$CP_STATE" FM_ORDER_CP_DATA_DIR="$CP_STORE" FM_ORDER_ACCOUNT_GRACE_SECS=0 "$ORDER" audit --json | jq -r '.control_plane.available')" = true ] \
    || fail "the audit did not report the control plane as reachable"
  [ "$(cp_audit ORD-001 basis)" = live_owner ] \
    || fail "an order linked to a LIVE control-plane task was not accounted as live_owner"
  [ "$(cp_audit ORD-002 accounted)" = false ] \
    || fail "an order linked only to an ARCHIVED control-plane task was still accounted"
  [ "$(cp_audit ORD-002 unaccounted_reason)" = "dispatched but no linked task is live" ] \
    || fail "a dead-task order did not name that its linked work is not live"
  [ "$(cp_audit ORD-003 basis)" = held_task_event_pending ] \
    || fail "a task-terminal hold on a LIVE task was not accounted pending"
  [ "$(cp_audit ORD-004 accounted)" = false ] \
    || fail "a task-terminal hold whose task is ARCHIVED (fired) was still accounted"
  pass "the live-work and task-event branches read control-plane task truth: live accounts, dead does not"
else
  pass "SKIPPED: control-plane task-truth check needs a runnable control plane (node + PGlite store)"
fi

#!/usr/bin/env bash
# Behavior tests for the Reconciler - the continuous, bounded, idempotent closure loop
# (ORD-277 slice 1): bin/fm-reconciler.sh.
#
# The load-bearing properties, one per Davy Jones closure check plus the pass contract:
#   - a non-terminal order whose linked task the control plane reports COMPLETED is
#     surfaced as an `order-complete` proposal with a `complete` closing command (the
#     completion fan-out a closeout skipped);
#   - a dispatched order whose linked task VANISHED (control plane "task not found") or
#     ended without completing is surfaced as `dead-linkage` with a `clarify` command;
#   - a `held` order whose machine-checkable review condition has FIRED is surfaced as
#     `expired-hold` with a `triage` command;
#   - NOTHING is proposed complete without positive control-plane proof: with no control
#     plane, completion and dead-linkage fail CLOSED and the banner says so (FC-002);
#   - the pass NEVER mutates the inbox (proposals only) and is idempotent;
#   - the check lane emits one wake line only when there are actionable proposals, and the
#     `install` verb writes the state/reconciler.check.sh shim.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "ok - fm-reconciler: skipped (no jq)"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "ok - fm-reconciler: skipped (no node)"; exit 0; }

# fm-order.sh write verbs and fm-reconciler.sh are primary-only, and firstmate development
# runs inside a disposable crewmate worktree whose .fm-crew-role marker resolves to
# "crewmate". Apply the sanctioned audited override so this suite is self-running there; a
# clean CI checkout has no marker and is already primary, so the override is a no-op.
export FM_ROLE_OVERRIDE=primary
export FM_ROLE_OVERRIDE_REASON="ORD-277 reconciler test fixtures inside a disposable worktree"

# shellcheck disable=SC2153 # ROOT is provided by tests/lib.sh.
ORDER="$ROOT/bin/fm-order.sh"
RECON="$ROOT/bin/fm-reconciler.sh"
TMP_ROOT=$(fm_test_tmproot fm-reconciler)
fm_git_identity fmtest fmtest@example.invalid

# A fake control-plane CLI: `task-head ... <id>` prints {status} for an id present in the
# FAKE_CP_TASKS map (JSON object id->status) and prints "task not found" (exit 1) for any
# other id - including the availability probe sentinel, which is exactly how a real,
# initialized store answers an unknown id. This lets the suite drive every task state
# without a Postgres store, while exercising the same code path bin/fm-reconciler.sh uses.
FAKE_CP="$TMP_ROOT/fake-cp.mjs"
cat > "$FAKE_CP" <<'JS'
const args = process.argv.slice(2);
const tid = args[args.length - 1];
const map = JSON.parse(process.env.FAKE_CP_TASKS || '{}');
if (Object.prototype.hasOwnProperty.call(map, tid)) {
  process.stdout.write(JSON.stringify({ task_id: tid, status: map[tid] }) + '\n');
  process.exit(0);
}
process.stdout.write(JSON.stringify({ error: `task not found: ${tid}`, code: 'validation' }) + '\n');
process.exit(1);
JS

# fresh_home <name>: a home with its own inbox and state dir. Sets HOME_DIR/INBOX/STATE.
fresh_home() {
  local name=$1
  HOME_DIR="$TMP_ROOT/$name"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data" "$HOME_DIR/cpdata"
  INBOX="$HOME_DIR/captain-orders.jsonl"
  STATE="$HOME_DIR/state"
}

# order/recon: run each scoped to the current fresh_home. The control plane is OFF by
# default (a data dir that does not initialize a store); a case that wants it on sets
# FAKE_CP_TASKS and calls with_cp.
order() {
  FM_ORDERS_PATH="$INBOX" FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$ROOT" \
    FM_ORDER_CP_DATA_DIR="$HOME_DIR/no-cp-store" "$ORDER" "$@"
}
recon() {
  FM_ORDERS_PATH="$INBOX" FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$ROOT" \
    FM_ORDER_ACCOUNT_GRACE_SECS=0 FM_ORDER_CP_DATA_DIR="$HOME_DIR/no-cp-store" "$RECON" "$@"
}
# with_cp: reconciler with the fake control plane reachable and FAKE_CP_TASKS honored.
with_cp() {
  FM_ORDERS_PATH="$INBOX" FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$ROOT" \
    FM_ORDER_ACCOUNT_GRACE_SECS=0 \
    FM_ORDER_CP_CLI="$FAKE_CP" FM_ORDER_CP_DATA_DIR="$HOME_DIR/cpdata" \
    FAKE_CP_TASKS="$FAKE_CP_TASKS" "$RECON" "$@"
}
order_cp() {
  FM_ORDERS_PATH="$INBOX" FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$ROOT" \
    FM_ORDER_CP_CLI="$FAKE_CP" FM_ORDER_CP_DATA_DIR="$HOME_DIR/cpdata" \
    FAKE_CP_TASKS="$FAKE_CP_TASKS" "$ORDER" "$@"
}

# ============================================================================
# Part A - the completion fan-out sweep (order-complete)
# ============================================================================

# --- A1: a dispatched order whose linked task COMPLETED -> order-complete proposal ---
fresh_home a1
export FAKE_CP_TASKS='{"task-done":"completed"}'
order add "Land the widget" >/dev/null
order dispatch ORD-001 --task task-done >/dev/null
JSON=$(with_cp --json)
[ "$(printf '%s' "$JSON" | jq -r '.counts.order_complete')" = 1 ] \
  || fail "a dispatched order with a completed linked task was not proposed order-complete"
[ "$(printf '%s' "$JSON" | jq -r '.proposals[0].command')" = "bin/fm-order.sh complete ORD-001 --link <evidence>" ] \
  || fail "the order-complete proposal did not carry the one-line complete command"
printf '%s' "$JSON" | jq -e '.control_plane.available == true' >/dev/null \
  || fail "the pass did not record the control plane as available"
pass "a completed linked task yields an order-complete proposal with a complete command"

# --- A2: FC-002 - a completed-looking order is NOT proposed complete with no control plane ---
fresh_home a2
order add "Land the widget" >/dev/null
order dispatch ORD-001 --task task-done >/dev/null
JSON=$(recon --json)   # no control plane reachable
[ "$(printf '%s' "$JSON" | jq -r '.control_plane.available')" = false ] \
  || fail "the pass claimed a control plane was reachable when none was"
[ "$(printf '%s' "$JSON" | jq -r '.counts.order_complete')" = 0 ] \
  || fail "an order was proposed complete with no control plane to prove it (FC-002 violation)"
[ "$(printf '%s' "$JSON" | jq -r '.counts.dead_linkage')" = 0 ] \
  || fail "a linkage was asserted dead with no control plane to prove it (FC-002 violation)"
[ "$(printf '%s' "$JSON" | jq -r '.counts.residual')" -ge 1 ] \
  || fail "the unverifiable order was dropped instead of retained as residual (FC-002 violation)"
recon report | grep -F 'control plane UNAVAILABLE' >/dev/null \
  || fail "the banner did not warn that completion checks ran fail-closed with no control plane"
pass "with no control plane, no completion or dead-linkage is claimed and the order is retained (FC-002)"

# --- A3: a live linked task is accounted, never surfaced ---
fresh_home a3
export FAKE_CP_TASKS='{"task-live":"running"}'
order add "In-progress work" >/dev/null
order dispatch ORD-001 --task task-live >/dev/null
JSON=$(with_cp --json)
[ "$(printf '%s' "$JSON" | jq -r '.counts.actionable')" = 0 ] \
  || fail "an order whose linked task is still live was surfaced as actionable"
[ "$(printf '%s' "$JSON" | jq -r '.counts.residual')" = 0 ] \
  || fail "an order whose linked task is still live was surfaced as residual"
pass "an order with a live linked task is accounted and never surfaced"

# ============================================================================
# Part B - dead-linkage detection
# ============================================================================

# --- B1: a dispatched order whose task VANISHED -> dead-linkage ---
fresh_home b1
export FAKE_CP_TASKS='{}'   # no task exists -> every id is "task not found"
order add "Orphaned work" >/dev/null
order dispatch ORD-001 --task vanished-task >/dev/null
JSON=$(with_cp --json)
[ "$(printf '%s' "$JSON" | jq -r '.counts.dead_linkage')" = 1 ] \
  || fail "a dispatched order whose task vanished was not proposed dead-linkage"
printf '%s' "$JSON" | jq -e '.proposals[0].command | startswith("bin/fm-order.sh clarify ORD-001")' >/dev/null \
  || fail "the dead-linkage proposal did not carry a clarify closing command"
printf '%s' "$JSON" | jq -e '.proposals[0].detail | test("not found")' >/dev/null \
  || fail "the dead-linkage detail did not cite the vanished task"
pass "a dispatched order whose task vanished yields a dead-linkage proposal"

# --- B2: a dispatched order with NO linked task is the deadest linkage ---
fresh_home b2
export FAKE_CP_TASKS='{}'
# Reach a dispatched order with no links by dispatching then having the (nonexistent) task
# read as vanished is B1; here we craft a dispatched row that carries an empty task list by
# dispatching against a scout, leaving linked_task_ids empty.
order add "Dispatched to nothing linkable" >/dev/null
order dispatch ORD-001 --scout only-a-scout >/dev/null
JSON=$(with_cp --json)
[ "$(printf '%s' "$JSON" | jq -r '.counts.dead_linkage')" = 1 ] \
  || fail "a dispatched order with no linked task was not surfaced as dead-linkage"
printf '%s' "$JSON" | jq -e '.proposals[0].detail | test("no linked task")' >/dev/null \
  || fail "the no-linked-task dead-linkage did not name its gap"
pass "a dispatched order with no linked task is surfaced as dead-linkage"

# ============================================================================
# Part C - expired machine-checkable holds
# ============================================================================

# --- C1: a hold on a past ISO date has fired -> expired-hold ---
fresh_home c1
order add "Held on a date" "Held on a future date" >/dev/null
order hold ORD-001 --reason "wait for the window" --review-after 2020-01-01 >/dev/null
order hold ORD-002 --reason "wait for the window" --review-after 2999-01-01 >/dev/null
JSON=$(recon --json)
[ "$(printf '%s' "$JSON" | jq -r '.counts.expired_hold')" = 1 ] \
  || fail "exactly the past-dated hold should have expired"
printf '%s' "$JSON" | jq -e '.proposals[] | select(.order_id=="ORD-001") | .command == "bin/fm-order.sh triage ORD-001"' >/dev/null \
  || fail "the expired-hold proposal did not carry a triage revisit command"
printf '%s' "$JSON" | jq -e '[.proposals[].order_id] | index("ORD-002") | not' >/dev/null \
  || fail "a hold on a future date was wrongly reported as expired"
pass "a hold on a past date fires and proposes a revisit; a future-dated hold does not"

# --- C2: a task:<id>:terminal hold fires only on positive control-plane proof ---
fresh_home c2
export FAKE_CP_TASKS='{"gate-task":"completed"}'
order add "Held until a task finishes" >/dev/null
order_cp hold ORD-001 --reason "wait for gate-task" --review-after task:gate-task:terminal >/dev/null
[ "$(with_cp --json | jq -r '.counts.expired_hold')" = 1 ] \
  || fail "a task-terminal hold did not fire when the control plane reports the task completed"
# With no control plane, the same hold must NOT be reported fired (fail-closed).
[ "$(recon --json | jq -r '.counts.expired_hold')" = 0 ] \
  || fail "a task-terminal hold fired with no control plane to prove the task is terminal (FC-002)"
pass "a task-terminal hold fires on positive proof and fails closed without the control plane"

# ============================================================================
# Part D - the pass contract: no mutation, idempotent, check lane, install
# ============================================================================

# --- D1: the pass never mutates the inbox (proposals only) ---
fresh_home d1
export FAKE_CP_TASKS='{"task-done":"completed"}'
order add "Land it" >/dev/null
order dispatch ORD-001 --task task-done >/dev/null
BEFORE=$(cksum < "$INBOX")
with_cp report >/dev/null
with_cp --json >/dev/null
with_cp check >/dev/null
AFTER=$(cksum < "$INBOX")
[ "$BEFORE" = "$AFTER" ] || fail "the reconciler mutated the order inbox; it must only propose"
[ "$(FM_ORDERS_PATH="$INBOX" FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$ROOT" "$ORDER" show ORD-001 --json | jq -r '.status')" = dispatched ] \
  || fail "the order status changed; the reconciler must never close an order itself"
pass "the reconciler never mutates the inbox - the order stays exactly as it was"

# --- D2: idempotent - two identical passes produce identical proposals ---
fresh_home d2
export FAKE_CP_TASKS='{"task-done":"completed"}'   # gone-task absent -> vanished
order add "One" "Two" >/dev/null
order dispatch ORD-001 --task task-done >/dev/null
order dispatch ORD-002 --task gone-task >/dev/null   # not in map -> vanished
P1=$(with_cp --json | jq -S '.proposals | map(del(.evidence))')
P2=$(with_cp --json | jq -S '.proposals | map(del(.evidence))')
[ "$P1" = "$P2" ] || fail "two identical reconciler passes produced different proposals"
pass "the pass is idempotent - identical input yields identical proposals"

# --- D3: the check lane emits a wake line only when there are actionable proposals ---
fresh_home d3
export FAKE_CP_TASKS='{"task-done":"completed"}'
order add "Actionable" >/dev/null
order dispatch ORD-001 --task task-done >/dev/null
LINE=$(with_cp check)
printf '%s\n' "$LINE" | grep -F 'reconciler:' >/dev/null \
  || fail "the check lane did not emit a wake line when a proposal was actionable"
printf '%s\n' "$LINE" | grep -F 'closure proposal' >/dev/null \
  || fail "the check wake line did not summarize the closure proposals"
# A clean home (no actionable proposals) emits nothing on the check lane. Use a fresh state
# dir so the cadence marker from the run above does not suppress the second run.
fresh_home d3b
export FAKE_CP_TASKS='{"task-live":"running"}'
order add "Not actionable" >/dev/null
order dispatch ORD-001 --task task-live >/dev/null
OUT=$(with_cp check)
[ -z "$OUT" ] || fail "the check lane emitted output when there was nothing actionable: $OUT"
pass "the check lane wakes only on actionable proposals and is silent otherwise"

# --- D4: the check lane is cadence-bounded - a second immediate run is suppressed ---
fresh_home d4
export FAKE_CP_TASKS='{"task-done":"completed"}'
order add "Actionable" >/dev/null
order dispatch ORD-001 --task task-done >/dev/null
FIRST=$(FM_ORDERS_PATH="$INBOX" FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$ROOT" \
  FM_ORDER_ACCOUNT_GRACE_SECS=0 FM_RECONCILER_CHECK_INTERVAL=3600 \
  FM_ORDER_CP_CLI="$FAKE_CP" FM_ORDER_CP_DATA_DIR="$HOME_DIR/cpdata" FAKE_CP_TASKS="$FAKE_CP_TASKS" \
  "$RECON" check)
SECOND=$(FM_ORDERS_PATH="$INBOX" FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$ROOT" \
  FM_ORDER_ACCOUNT_GRACE_SECS=0 FM_RECONCILER_CHECK_INTERVAL=3600 \
  FM_ORDER_CP_CLI="$FAKE_CP" FM_ORDER_CP_DATA_DIR="$HOME_DIR/cpdata" FAKE_CP_TASKS="$FAKE_CP_TASKS" \
  "$RECON" check)
[ -n "$FIRST" ] || fail "the first check run produced no wake line"
[ -z "$SECOND" ] || fail "a second check within the cadence window was not suppressed: $SECOND"
pass "the check lane is cadence-bounded - a second run inside the window is silent"

# --- D5: install writes the watcher check shim that execs the check lane ---
fresh_home d5
OUT=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$ROOT" "$RECON" install)
printf '%s\n' "$OUT" | grep -F 'reconciler.check.sh' >/dev/null \
  || fail "install did not report writing the reconciler.check.sh shim"
[ -x "$STATE/reconciler.check.sh" ] || fail "install did not create an executable check shim"
if ! grep -F 'fm-reconciler.sh' "$STATE/reconciler.check.sh" >/dev/null \
   || ! grep -Fw 'check' "$STATE/reconciler.check.sh" >/dev/null; then
  fail "the check shim does not exec the reconciler check lane"
fi
# install is idempotent: a second run is a no-op that reports up-to-date.
OUT2=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$ROOT" "$RECON" install)
printf '%s\n' "$OUT2" | grep -F 'up to date' >/dev/null \
  || fail "a second install did not report the shim already up to date"
pass "install writes an executable, idempotent reconciler.check.sh shim for the watcher"

# --- D6: a home that never took a captain order is all-clear, never an error ---
fresh_home d6
OUT=$(FM_ORDERS_PATH="$INBOX" FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$ROOT" "$RECON" report)
printf '%s\n' "$OUT" | grep -F 'all clear' >/dev/null \
  || fail "a home with no inbox did not report all-clear"
CHECK=$(FM_ORDERS_PATH="$INBOX" FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$ROOT" "$RECON" check)
[ -z "$CHECK" ] || fail "a home with no inbox produced a check wake line: $CHECK"
pass "a home with no captain order inbox is all-clear and silent, never an error"

# --- D7: all four checks coalesce into ONE banner ---
fresh_home d7
export FAKE_CP_TASKS='{"done-task":"completed"}'   # gone absent -> vanished
order add "Completed" "Vanished" "Held past date" >/dev/null
order dispatch ORD-001 --task done-task >/dev/null
order dispatch ORD-002 --task gone >/dev/null
order hold ORD-003 --reason "wait" --review-after 2020-01-01 >/dev/null
OUT=$(with_cp report)
RULES=$(printf '%s\n' "$OUT" | grep -c '^●━')
[ "$RULES" -eq 2 ] || fail "the coalesced summary was not a single banner (found $RULES rules, expected 2)"
printf '%s\n' "$OUT" | grep -F 'ORDER COMPLETE' >/dev/null || fail "the banner omitted the order-complete section"
printf '%s\n' "$OUT" | grep -F 'DEAD LINKAGE' >/dev/null || fail "the banner omitted the dead-linkage section"
printf '%s\n' "$OUT" | grep -F 'EXPIRED HOLD' >/dev/null || fail "the banner omitted the expired-hold section"
printf '%s\n' "$OUT" | grep -F 'Proposals only' >/dev/null || fail "the banner omitted the proposals-only contract line"
pass "all four closure checks coalesce into one banner with per-item closing commands"

echo "ok - fm-reconciler: all reconciler behavior tests passed"

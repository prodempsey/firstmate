#!/usr/bin/env bash
# Behavior tests for fm-guard.sh's fleet-triage supervision preflight (Phase 2B,
# point 3): a deterministic, cheap read of state/.triage-duty-last.json - the
# volatile cache bin/fm-triage-duty.sh writes on every pass - that warns before a
# return to silent supervision walks past actionable work nobody owns, or past a
# pass that failed to enumerate at all. This suite pins the file-read contract in
# isolation from the enumerator: it writes the cache file directly rather than
# running a real triage pass, the same way fm-tangle-guard.test.sh pins the tangle
# alarm without a real crewmate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-triage-guard)

# A home whose STATE dir fm-guard.sh reads from. No state/*.meta files are ever
# written here, which pins that this preflight fires independent of in-flight
# task count (unlike the watcher-liveness alarm right below it in fm-guard.sh).
make_home() {
  local dir
  mkdir -p "$TMP_ROOT"
  dir=$(mktemp -d "$TMP_ROOT/case.XXXXXX")
  mkdir -p "$dir/state"
  printf '%s\n' "$dir"
}

run_guard() {  # <home> [FM_GUARD_READ_ONLY]
  local home=$1 read_only=${2:-0}
  FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_GUARD_READ_ONLY="$read_only" \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

write_cache() {  # <home> <json>
  printf '%s\n' "$2" > "$1/state/.triage-duty-last.json"
}

test_no_cache_file_is_silent() {
  local home out
  home=$(make_home)
  out=$(run_guard "$home")
  assert_not_contains "$out" "FLEET TRIAGE" "guard alarmed with no triage-duty cache present at all"
  pass "no state/.triage-duty-last.json means no triage preflight banner"
}

test_clean_pass_is_silent() {
  local home out
  home=$(make_home)
  write_cache "$home" '{"ok":true,"trigger":"teardown","scope":"full","ts":"2026-07-11T00:00:00Z","actionable":0,"ownerless":0,"unhealthy":0,"captain_gated":0,"fingerprint":"x"}'
  out=$(run_guard "$home")
  assert_not_contains "$out" "FLEET TRIAGE" "guard alarmed on a clean, ownerless-free last pass"
  pass "a clean last pass (ownerless: 0) stays silent"
}

test_ownerless_actionable_items_alarm() {
  local home out
  home=$(make_home)
  write_cache "$home" '{"ok":true,"trigger":"teardown","scope":"full","ts":"2026-07-11T00:00:00Z","actionable":3,"ownerless":2,"unhealthy":0,"captain_gated":1,"fingerprint":"x"}'
  out=$(run_guard "$home")
  assert_contains "$out" "FLEET TRIAGE ATTENTION" "guard did not alarm on ownerless actionable items"
  assert_contains "$out" "2 of 3 actionable" "guard banner did not name the ownerless/actionable counts"
  assert_contains "$out" "1 captain-gated" "guard banner did not name the captain-gated count"
  assert_contains "$out" "teardown" "guard banner did not name the trigger of the last pass"
  assert_contains "$out" "bin/fm-fleet-triage-record.sh" "guard banner did not point at the ledger writer"
  pass "ownerless actionable items in the last pass alarm on the next supervision preflight"
}

test_read_only_session_gets_no_repair_instruction() {
  local home out
  home=$(make_home)
  write_cache "$home" '{"ok":true,"trigger":"teardown","scope":"full","ts":"2026-07-11T00:00:00Z","actionable":1,"ownerless":1,"unhealthy":0,"captain_gated":0,"fingerprint":"x"}'
  out=$(run_guard "$home" 1)
  assert_contains "$out" "FLEET TRIAGE ATTENTION" "read-only guard did not keep the triage-attention alarm"
  assert_contains "$out" "cannot record dispositions" "read-only guard did not explain disposition ownership"
  assert_contains "$out" "fleet lock owns this" "read-only guard did not explain disposition ownership"
  assert_not_contains "$out" "Load the fleet-triage skill and disposition" "read-only guard printed a disposition instruction it cannot carry out"
  pass "a read-only session sees the same alarm worded as an ownership note, not a repair instruction"
}

test_failed_last_pass_alarms() {
  local home out
  home=$(make_home)
  write_cache "$home" '{"ok":false,"trigger":"heartbeat","scope":"full","ts":"2026-07-11T00:00:00Z","error":"fm-fleet-triage: jq not found"}'
  out=$(run_guard "$home")
  assert_contains "$out" "FLEET TRIAGE DUTY - LAST PASS FAILED TO ENUMERATE" "guard did not alarm on a failed last pass"
  assert_contains "$out" "heartbeat" "guard banner did not name the trigger of the failed pass"
  assert_contains "$out" "jq not found" "guard banner did not surface the enumerator's own error"
  pass "a failed last pass keeps alarming at every later supervision checkpoint, not just once"
}

test_fires_regardless_of_in_flight_count() {
  # No state/*.meta was ever written in any case above (make_home creates only
  # state/), so watcher-liveness's own in_flight gate would exit 0 immediately if
  # the triage preflight depended on it. Pin that it does not: the ATTENTION
  # banner in test_ownerless_actionable_items_alarm already proves this, so this
  # case just asserts the watcher-down banner (which DOES depend on in_flight)
  # stays absent while the triage banner is present, confirming they are
  # independent checks rather than one gating the other.
  local home out
  home=$(make_home)
  write_cache "$home" '{"ok":true,"trigger":"teardown","scope":"full","ts":"2026-07-11T00:00:00Z","actionable":1,"ownerless":1,"unhealthy":0,"captain_gated":0,"fingerprint":"x"}'
  out=$(run_guard "$home")
  assert_contains "$out" "FLEET TRIAGE ATTENTION" "triage preflight did not fire with zero tasks in flight"
  assert_not_contains "$out" "WATCHER DOWN" "watcher-liveness alarm should stay silent with zero tasks in flight"
  pass "the triage preflight fires independent of in-flight task count"
}

test_never_blocks_or_changes_exit_status() {
  local home rc
  home=$(make_home)
  write_cache "$home" '{"ok":false,"trigger":"heartbeat","scope":"full","ts":"2026-07-11T00:00:00Z","error":"boom"}'
  run_guard "$home" >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "fm-guard.sh must always exit 0; it warns, it never blocks"
  pass "the triage preflight never changes fm-guard.sh's exit status"
}

# --- The dropped-captain-decision alarm. ---------------------------------------------
# A captain decision reaches the captain durably through exactly one mechanism: a card in
# the Bridge's needs_human column, written only by bin/fm-nf-ack.sh --to-captain, which
# leaves a local receipt at state/.nf-to-captain. The alarm compares the captain-gated
# orders in the cached triage pass against those receipts. What has to hold: a gated order
# with no receipt is named with a runnable fix command, a fully marked fleet is silent,
# missing evidence is reported as missing rather than as health, and the guard never marks
# anything itself - it detects, firstmate decides.

# A gate block as bin/fm-triage-duty.sh records it. ownerless/actionable stay 0 so the
# preflight above cannot contribute output and "silent" means silent.
gate_cache() {  # <captain_gates-json>
  printf '{"ok":true,"trigger":"session-start","scope":"full","ts":"2026-07-13T00:00:00Z","actionable":0,"ownerless":0,"unhealthy":0,"captain_gated":1,"fingerprint":"x","captain_gates":%s}' "$1"
}

ONE_GATED_ORDER='{"orders_total":1,"orders":[{"item_id":"captain_orders:ORD-001","order_id":"ORD-001","title":"Ship or revert the away-mode rework","task":"away-rework-k3"}],"other_total":0,"other":[]}'

write_receipt() {  # <home> <open-item-id> <task-id>
  printf '%s\t%s\tfp\t2026-07-13T00:00:00Z\n' "$2" "$3" >> "$1/state/.nf-to-captain"
}

test_gated_order_with_no_card_alarms() {
  local home out
  home=$(make_home)
  write_cache "$home" "$(gate_cache "$ONE_GATED_ORDER")"
  out=$(run_guard "$home")
  assert_contains "$out" "DROPPED CAPTAIN DECISION" "guard did not alarm on a captain-gated order with no needs_human card"
  assert_contains "$out" "ORD-001" "guard did not name the specific dropped order"
  assert_contains "$out" "Ship or revert the away-mode rework" "guard did not name what the captain is being asked to decide"
  assert_contains "$out" "bin/fm-nf-ack.sh --to-captain ORD-001 away-rework-k3" "guard did not print the exact command that fixes this order"
  pass "a captain-gated order with no needs_human card is named, with its runnable fix command"
}

test_marked_gate_is_completely_silent() {
  local home out
  home=$(make_home)
  write_cache "$home" "$(gate_cache "$ONE_GATED_ORDER")"
  write_receipt "$home" ORD-001 away-rework-k3
  out=$(run_guard "$home")
  [ -z "$out" ] || fail "a fleet whose every captain gate is marked must print NOTHING, got: $out"
  pass "every captain gate marked produces no output at all"
}

test_only_the_unmarked_gate_is_named() {
  local home out gates
  home=$(make_home)
  gates='{"orders_total":2,"orders":[{"item_id":"captain_orders:ORD-001","order_id":"ORD-001","title":"Marked one","task":"t1"},{"item_id":"captain_orders:ORD-002","order_id":"ORD-002","title":"Dropped one","task":"t2"}],"other_total":0,"other":[]}'
  write_cache "$home" "$(gate_cache "$gates")"
  write_receipt "$home" ORD-001 t1
  out=$(run_guard "$home")
  assert_contains "$out" "ORD-002" "guard did not name the one gate that has no card"
  assert_not_contains "$out" "ORD-001" "guard named an order that already has a needs_human card"
  assert_contains "$out" "1 captain-gated order(s)" "guard did not count only the unmarked gates"
  pass "a marked gate is excluded and only the genuinely dropped one is named"
}

test_gate_with_no_linked_task_asks_for_the_link_first() {
  # Regression: the gate rendering is split on a NON-whitespace delimiter. `read` collapses
  # runs of IFS whitespace, so a tab-delimited rendering silently dropped this order's empty
  # task field and shifted its TITLE into the command - printing a fix command naming a
  # "task" that never existed.
  local home out gates
  home=$(make_home)
  gates='{"orders_total":1,"orders":[{"item_id":"captain_orders:ORD-007","order_id":"ORD-007","title":"Pick the retention policy","task":null}],"other_total":0,"other":[]}'
  write_cache "$home" "$(gate_cache "$gates")"
  out=$(run_guard "$home")
  assert_contains "$out" "ORD-007: Pick the retention policy" "guard lost the title of a gate with no linked task"
  assert_contains "$out" "--to-captain ORD-007 <task-id>" "guard did not ask for a task id it does not have"
  assert_contains "$out" "bin/fm-order.sh link ORD-007 --task" "guard did not name the step that supplies the missing task link"
  assert_not_contains "$out" "--to-captain ORD-007 Pick" "guard printed the order's TITLE where a task id belongs"
  pass "a gate with no linked task asks for the link instead of inventing a task id"
}

test_missing_gate_detail_is_reported_not_assumed_healthy() {
  # A pass recorded before captain-gate detail existed (or one whose gate block is null) is
  # MISSING EVIDENCE. Reporting it as silence would be reporting "no dropped decisions" from
  # a check that never ran.
  local home out
  home=$(make_home)
  write_cache "$home" '{"ok":true,"trigger":"session-start","scope":"full","ts":"2026-07-13T00:00:00Z","actionable":0,"ownerless":0,"unhealthy":0,"captain_gated":0,"fingerprint":"x"}'
  out=$(run_guard "$home")
  assert_contains "$out" "cannot check for dropped captain decisions" "guard silently reported health from a pass with no captain-gate detail"
  assert_contains "$out" "bin/fm-triage-duty.sh" "guard did not say how to refresh the missing evidence"
  pass "a pass with no captain-gate detail is reported as unavailable, never as all clear"
}

test_gates_outside_the_order_inbox_are_context_not_an_alarm() {
  # A captain-gated item with no open item (a standing visibility umbrella row) has nothing
  # to key a card to, so it cannot be a DROPPED card. It must not fire the alarm by itself -
  # an alarm that fires forever on standing work is one nobody reads - but it IS named inside
  # a banner that fires for a real dropped order.
  local home out gates
  home=$(make_home)
  gates='{"orders_total":0,"orders":[],"other_total":1,"other":[{"item_id":"visibility_history:umb-1","lane":"visibility_history","source_id":"umb-1","title":"Standing umbrella"}]}'
  write_cache "$home" "$(gate_cache "$gates")"
  out=$(run_guard "$home")
  [ -z "$out" ] || fail "a captain-gated item with no open item must not fire the dropped-decision alarm on its own, got: $out"

  gates='{"orders_total":1,"orders":[{"item_id":"captain_orders:ORD-001","order_id":"ORD-001","title":"Real dropped decision","task":"t1"}],"other_total":1,"other":[{"item_id":"visibility_history:umb-1","lane":"visibility_history","source_id":"umb-1","title":"Standing umbrella"}]}'
  write_cache "$home" "$(gate_cache "$gates")"
  out=$(run_guard "$home")
  assert_contains "$out" "DROPPED CAPTAIN DECISION" "a real dropped order must still alarm"
  assert_contains "$out" "umb-1" "a firing banner did not carry the other captain-gated items as context"
  assert_contains "$out" "bin/fm-order.sh add" "the banner did not say how an item with no open item reaches the board"
  pass "gates with no open item are context inside a firing banner, never an alarm of their own"
}

test_read_only_session_is_not_told_to_mark() {
  local home out
  home=$(make_home)
  write_cache "$home" "$(gate_cache "$ONE_GATED_ORDER")"
  out=$(run_guard "$home" 1)
  assert_contains "$out" "DROPPED CAPTAIN DECISION" "read-only guard dropped the alarm entirely"
  assert_contains "$out" "must not write the board" "read-only guard did not explain who owns the marking"
  assert_not_contains "$out" "Marking is yours" "read-only guard told a session it cannot act to go mark the board"
  pass "a read-only session sees the alarm worded as an ownership note, not a marking instruction"
}

test_guard_never_marks_anything() {
  # The guard detects and names; firstmate decides and marks. Auto-routing a decision to the
  # captain's board would make a false positive worse than the bug this catches, so the guard
  # must leave every byte of state exactly as it found it.
  local home before after
  home=$(make_home)
  write_cache "$home" "$(gate_cache "$ONE_GATED_ORDER")"
  before=$(find "$home" -type f -exec md5sum {} \; | sort | md5sum)
  run_guard "$home" >/dev/null 2>&1
  after=$(find "$home" -type f -exec md5sum {} \; | sort | md5sum)
  [ "$before" = "$after" ] || fail "fm-guard.sh mutated state while checking for dropped captain decisions"
  assert_absent "$home/state/.nf-to-captain" "fm-guard.sh wrote a to-captain receipt itself; it must never mark the board"
  pass "the guard marks, writes, and mutates nothing"
}

test_dropped_decision_alarm_never_changes_exit_status() {
  local home rc
  home=$(make_home)
  write_cache "$home" "$(gate_cache "$ONE_GATED_ORDER")"
  run_guard "$home" >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "fm-guard.sh must always exit 0; it warns, it never blocks"
  pass "the dropped-captain-decision alarm never blocks the guarded operation"
}

test_end_to_end_from_a_real_captain_order() {
  # The cases above pin the guard's file-read contract against a written cache. This one
  # proves the whole chain the bug actually broke: a REAL captain order recorded in the real
  # inbox, gated on the captain by the real CLI, enumerated by the real fleet-triage
  # enumerator, cached by a real duty pass, and detected by the guard - with the real receipt
  # ledger clearing it. No fixture stands in for any link.
  local home out ord
  home=$(make_home)
  mkdir -p "$home/data"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '%s\n' "$$" > "$home/state/.lock"

  export FM_ORDERS_PATH="$home/orders.jsonl"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-order.sh" init >/dev/null 2>&1
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-order.sh" \
    add "Decide whether to ship the away-mode rework" >/dev/null 2>&1
  ord=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-order.sh" list --json \
    | jq -r '.orders[0].order_id')
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-order.sh" \
    link "$ord" --task away-rework-k3 >/dev/null 2>&1
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-order.sh" \
    decision "$ord" --reason "captain owes the ship-or-revert call" >/dev/null 2>&1

  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$home" FM_FLEET_TRIAGE_BUG_CLI=off \
    "$ROOT/bin/fm-triage-duty.sh" session-start >/dev/null 2>&1

  out=$(run_guard "$home")
  assert_contains "$out" "DROPPED CAPTAIN DECISION" "the real chain (order -> enumerator -> duty cache -> guard) did not surface a dropped decision"
  assert_contains "$out" "bin/fm-nf-ack.sh --to-captain $ord away-rework-k3" "the alarm did not print the real order's runnable fix command"

  # The receipt fm-nf-ack.sh appends only after the Bridge reads the card back.
  write_receipt "$home" "$ord" away-rework-k3
  out=$(run_guard "$home")
  assert_not_contains "$out" "DROPPED CAPTAIN DECISION" "a marked captain gate still alarmed"
  unset FM_ORDERS_PATH
  pass "end to end: a real captain-gated order alarms, and its needs_human card clears the alarm"
}

test_no_cache_file_is_silent
test_clean_pass_is_silent
test_ownerless_actionable_items_alarm
test_read_only_session_gets_no_repair_instruction
test_failed_last_pass_alarms
test_fires_regardless_of_in_flight_count
test_never_blocks_or_changes_exit_status
test_gated_order_with_no_card_alarms
test_marked_gate_is_completely_silent
test_only_the_unmarked_gate_is_named
test_gate_with_no_linked_task_asks_for_the_link_first
test_missing_gate_detail_is_reported_not_assumed_healthy
test_gates_outside_the_order_inbox_are_context_not_an_alarm
test_read_only_session_is_not_told_to_mark
test_guard_never_marks_anything
test_dropped_decision_alarm_never_changes_exit_status
test_end_to_end_from_a_real_captain_order

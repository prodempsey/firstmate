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

test_no_cache_file_is_silent
test_clean_pass_is_silent
test_ownerless_actionable_items_alarm
test_read_only_session_gets_no_repair_instruction
test_failed_last_pass_alarms
test_fires_regardless_of_in_flight_count
test_never_blocks_or_changes_exit_status

#!/usr/bin/env bash
# Behavior tests for the additive Needs FirstMate local-state reconciler.
set -u

# shellcheck disable=SC1091 # Dynamic test-library path is resolved from BASH_SOURCE.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECONCILE="$ROOT/bin/fm-nf-reconcile.sh"
ACK="$ROOT/bin/fm-nf-ack.sh"
TMP_ROOT=$(fm_test_tmproot fm-nf-reconcile)

new_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

write_task() {
  local home=$1 id=$2 status=$3 kind=${4:-ship}
  fm_write_meta "$home/state/$id.meta" \
    "window=fm-$id" \
    "worktree=$home/worktrees/$id" \
    "project=demo" \
    "harness=codex" \
    "kind=$kind" \
    "mode=local-only" \
    "yolo=off"
  printf '%s\n' "$status" > "$home/state/$id.status"
}

run_reconcile() {
  local home=$1
  shift
  FM_HOME="$home" "$RECONCILE" "$@"
}

run_ack() {
  local home=$1
  shift
  FM_HOME="$home" "$ACK" "$@"
}

test_unhandled_terminal_emits_once() {
  local home out
  home=$(new_home emits-once)
  write_task "$home" ready-a1 'done: ready in branch fm/ready-a1 @ abcdef1'

  out=$(run_reconcile "$home")
  assert_contains "$out" 'NEEDS FIRSTMATE: 1 unhandled - ready-a1' \
    "first check should surface the unhandled terminal task"
  out=$(run_reconcile "$home")
  [ -z "$out" ] || fail "unchanged surfaced set should be silent, got: $out"
  pass "unhandled terminal status emits once"
}

test_acked_unchanged_is_silent() {
  local home out ledger_lines
  home=$(new_home acked)
  write_task "$home" ack-me-b2 'blocked: waiting for a credential'
  run_reconcile "$home" >/dev/null

  run_ack "$home" ack-me-b2 >/dev/null
  run_ack "$home" ack-me-b2 >/dev/null
  ledger_lines=$(wc -l < "$home/state/.nf-handled" | tr -d ' ')
  [ "$ledger_lines" -eq 1 ] || fail "idempotent ack should write one ledger row"
  out=$(run_reconcile "$home")
  [ -z "$out" ] || fail "acked unchanged terminal task should be silent, got: $out"
  pass "acked unchanged card is silent"
}

test_changed_fingerprint_reemits() {
  local home out old_fingerprint new_fingerprint
  home=$(new_home changed)
  write_task "$home" change-c3 'needs-decision: choose A or B'
  run_reconcile "$home" >/dev/null
  run_ack "$home" change-c3 >/dev/null
  old_fingerprint=$(cut -f2 "$home/state/.nf-handled")

  printf '%s\n' 'failed: option A failed during validation' >> "$home/state/change-c3.status"
  out=$(run_reconcile "$home")
  assert_contains "$out" 'NEEDS FIRSTMATE: 1 unhandled - change-c3' \
    "changed terminal signal should surface again"
  new_fingerprint=$(run_reconcile "$home" list | sed -n 's/^  fingerprint: //p')
  [ "$old_fingerprint" != "$new_fingerprint" ] || fail "changed signal should change fingerprint"
  pass "changed fingerprint re-emits"
}

test_local_state_without_board_data() {
  local home out
  home=$(new_home local-only)
  write_task "$home" local-d4 'done: local state is authoritative'
  out=$(FM_NF_BOARD_URL='http://127.0.0.1:1/unreachable' run_reconcile "$home" list)
  assert_contains "$out" 'NEEDS FIRSTMATE: 1 unhandled' "local state should produce a list"
  assert_contains "$out" 'signal: done: local state is authoritative' \
    "list should expose the local terminal signal"
  assert_contains "$out" "meta: $home/state/local-d4.meta" "list should expose local triage paths"
  pass "local state works without board data"
}

test_install_is_idempotent() {
  local home shim first_sum second_sum first_mtime second_mtime out
  home=$(new_home install)
  write_task "$home" install-e5 'done: install test'
  run_reconcile "$home" install >/dev/null
  shim="$home/state/needs-firstmate.check.sh"
  assert_present "$shim" "install should create the watcher check shim"
  [ -x "$shim" ] || fail "installed watcher check shim should be executable"
  first_sum=$(cksum "$shim")
  first_mtime=$(stat -c %Y "$shim")
  sleep 1
  run_reconcile "$home" install >/dev/null
  second_sum=$(cksum "$shim")
  second_mtime=$(stat -c %Y "$shim")
  [ "$first_sum" = "$second_sum" ] || fail "reinstall should preserve shim content"
  [ "$first_mtime" = "$second_mtime" ] || fail "reinstall should not churn shim mtime"
  out=$("$shim")
  assert_contains "$out" 'NEEDS FIRSTMATE: 1 unhandled - install-e5' \
    "installed shim should execute the reconciler through the watcher contract"
  pass "install creates an idempotent check shim"
}

test_only_matching_local_terminal_tasks_are_listed() {
  local home out
  home=$(new_home filter)
  write_task "$home" working-f6 'working: still active'
  write_task "$home" secondmate-f7 'done: persistent supervisor idle' secondmate
  printf '%s\n' 'done: orphan status' > "$home/state/orphan-f8.status"
  out=$(run_reconcile "$home" list)
  [ "$out" = 'NEEDS FIRSTMATE: none' ] || fail "ineligible local signals should be excluded, got: $out"
  pass "reconciler requires matching task state and excludes secondmates"
}

test_phase_two_flags_are_non_mutating_stubs() {
  local home status
  home=$(new_home phase-two)
  write_task "$home" phase-g9 'done: waiting for future ownership support'
  status=0
  run_ack "$home" --to-captain phase-g9 >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "Phase 2 stub should return a usage-style code"
  assert_absent "$home/state/.nf-handled" "Phase 2 stub must not acknowledge the signal"
  pass "Phase 2 ownership flags are explicit non-mutating stubs"
}

test_unhandled_terminal_emits_once
test_acked_unchanged_is_silent
test_changed_fingerprint_reemits
test_local_state_without_board_data
test_install_is_idempotent
test_only_matching_local_terminal_tasks_are_listed
test_phase_two_flags_are_non_mutating_stubs

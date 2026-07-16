#!/usr/bin/env bash
# Scope E - durable scoped governance holds. Proves a hold survives a simulated
# FirstMate/watcher restart, blocks a held task from dispatch, allows authorized
# recovery, and refuses release without an authorization reference.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOLD="$ROOT/bin/fm-hold.sh"
TMP_ROOT=$(fm_test_tmproot fm-hold)
export FM_HOME="$TMP_ROOT/home" FM_STATE_OVERRIDE="$TMP_ROOT/home/state"
mkdir -p "$FM_STATE_OVERRIDE"
export FM_GOV_NOW=2026-07-15T00:00:00Z

# Regression 14: a durable hold survives a simulated FirstMate/watcher restart.
# The hold lives in state/holds/ as a file, so a fresh process (a new FirstMate or
# watcher) reads the same block - nothing is kept in memory.
test_hold_survives_restart() {
  "$HOLD" add --kind milestone --value memory-pr1-evidence --reason "PR-1 evidence frozen" >/dev/null
  # Simulate restart: a brand-new process reads the durable store.
  ( "$HOLD" check --milestone memory-pr1-evidence ) >/dev/null 2>&1
  local status=$?
  expect_code 3 "$status" "the hold must still block after a simulated restart"
  # And the on-disk record is what carried it across the 'restart'.
  assert_present "$FM_STATE_OVERRIDE/holds" "holds must be stored on disk"
  pass "a durable hold survives a simulated FirstMate/watcher restart"
}

# Regression 15 (unit): a held PR-2 task cannot dispatch. The dispatch enforcement
# point calls `fm-hold.sh check` and refuses on exit 3.
test_held_pr2_task_blocked() {
  "$HOLD" add --kind milestone --value memory-pr2 --reason "PR-2 held pending incident controls" >/dev/null
  local out status
  out=$("$HOLD" check --task memory-pr2-build-x --milestone memory-pr2 2>&1); status=$?
  expect_code 3 "$status" "a task under the PR-2 hold must be blocked"
  assert_contains "$out" "HELD: milestone=memory-pr2" "the block must name the hold"
  pass "a held PR-2 task cannot dispatch"
}

test_unrelated_task_not_blocked() {
  local status
  "$HOLD" check --task some-other-task --milestone unrelated-milestone >/dev/null 2>&1
  status=$?
  expect_code 0 "$status" "an unrelated task must not be blocked"
  pass "a task outside every hold scope is not blocked"
}

test_recovery_work_allowed() {
  local status
  "$HOLD" check --milestone memory-pr2 --recovery >/dev/null 2>&1
  status=$?
  expect_code 0 "$status" "explicitly-authorized recovery work must be allowed"
  pass "explicitly-authorized incident-recovery work is never blocked"
}

test_scoped_by_project_task_branch() {
  "$HOLD" add --kind project --value firstmate --reason "whole project frozen" >/dev/null
  "$HOLD" add --kind task --value some-task-t9 --reason "one task frozen" >/dev/null
  "$HOLD" add --kind branch --value fm/hot-branch --reason "one branch frozen" >/dev/null
  "$HOLD" check --project firstmate >/dev/null 2>&1; expect_code 3 "$?" "project-scoped hold must match by project"
  "$HOLD" check --task some-task-t9 >/dev/null 2>&1; expect_code 3 "$?" "task-scoped hold must match by task"
  "$HOLD" check --branch fm/hot-branch >/dev/null 2>&1; expect_code 3 "$?" "branch-scoped hold must match by branch"
  pass "holds scope by project, task, and branch"
}

# Regression 18: a hold release without an authorization reference fails.
test_release_requires_authorization() {
  "$HOLD" add --kind milestone --value memory-pr3 --reason "PR-3 held" >/dev/null
  local out status
  out=$("$HOLD" release --kind milestone --value memory-pr3 2>&1); status=$?
  expect_code 1 "$status" "release without authorization must fail"
  assert_contains "$out" "authorization" "must explain the authorization requirement"
  # Still held.
  "$HOLD" check --milestone memory-pr3 >/dev/null 2>&1; expect_code 3 "$?" "the hold must remain after a refused release"
  pass "a hold release without an authorization reference fails"
}

test_release_with_authorization_audits() {
  "$HOLD" add --kind milestone --value memory-pr4 --reason "PR-4 held" >/dev/null
  "$HOLD" release --kind milestone --value memory-pr4 --authorization captain-order-42 --reason "controls landed" >/dev/null
  "$HOLD" check --milestone memory-pr4 >/dev/null 2>&1; expect_code 0 "$?" "an authorized release must clear the hold"
  assert_grep "release" "$FM_STATE_OVERRIDE/holds/audit.log" "release must append an audit record"
  assert_grep "captain-order-42" "$FM_STATE_OVERRIDE/holds/audit.log" "audit must record the authorization reference"
  pass "an authorized release clears the hold and appends an audit record"
}

# Independent-review regression: two values that slug identically must not collide
# onto one file and make a hold silently disappear.
test_slug_collision_keeps_both_holds() {
  "$HOLD" add --kind branch --value "fm/collide-x" --reason "slash form" >/dev/null
  "$HOLD" add --kind branch --value "fm-collide-x" --reason "dash form" >/dev/null
  "$HOLD" check --branch "fm/collide-x" >/dev/null 2>&1; expect_code 3 "$?" "the slash-form hold must survive"
  "$HOLD" check --branch "fm-collide-x" >/dev/null 2>&1; expect_code 3 "$?" "the dash-form hold must survive"
  pass "distinct values that slug identically do not collide (no disappearing hold)"
}

test_hold_survives_restart
test_held_pr2_task_blocked
test_slug_collision_keeps_both_holds
test_unrelated_task_not_blocked
test_recovery_work_allowed
test_scoped_by_project_task_branch
test_release_requires_authorization
test_release_with_authorization_audits

pass "fm-hold: all durable-hold cases passed"

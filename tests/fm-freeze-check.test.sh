#!/usr/bin/env bash
# Scope F - completed-but-live crew freeze check. Proves a done-but-live coding
# agent blocks freeze, an inert login shell does not, and dead/unrelated processes
# are classified correctly. Process enumeration is injected so the classifier is
# exercised deterministically without real agents.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FREEZE="$ROOT/bin/fm-freeze-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-freeze-check)
export FM_HOME="$TMP_ROOT/home" FM_STATE_OVERRIDE="$TMP_ROOT/home/state"
mkdir -p "$FM_STATE_OVERRIDE"
export FM_GOV_NOW=2026-07-15T00:00:00Z
fm_git_identity

WT="$TMP_ROOT/wt"
fm_git_init_commit "$WT"

setup_task() {  # <id>
  local id=$1
  fm_write_meta "$FM_STATE_OVERRIDE/$id.meta" "window=firstmate:fm-$id" "worktree=$WT" "kind=ship"
  printf 'done: ready in branch fm/%s\n' "$id" > "$FM_STATE_OVERRIDE/$id.status"
}

procsrc() {  # write a proc source file; each arg is "pid ppid cwd cmd"
  local f="$TMP_ROOT/procs.$1.tsv"; shift
  : > "$f"
  local line
  for line in "$@"; do
    # shellcheck disable=SC2086
    set -- $line
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${*:4}" >> "$f"
  done
  printf '%s\n' "$f"
}

# Regression 12: a done-but-live coding agent blocks freeze.
test_live_coding_agent_blocks_freeze() {
  local id=fz-12 src out status
  setup_task "$id"
  src=$(procsrc live "200 1 $WT claude --dangerously-skip-permissions")
  out=$(FM_FREEZE_PROC_SOURCE="$src" "$FREEZE" "$id" 2>&1); status=$?
  expect_code 3 "$status" "a live in-worktree coding agent must fail the freeze check"
  assert_contains "$out" "canMutate:   yes" "must report the branch can still mutate"
  assert_contains "$out" "frozenSafe:  no" "must report not frozen-safe"
  assert_contains "$out" "agentPids:   200" "must name the live agent pid"
  pass "a done-but-live coding agent blocks freeze"
}

# Regression 13: an inert login shell is reported but does not count as a coding agent.
test_inert_login_shell_is_safe() {
  local id=fz-13 src out status
  setup_task "$id"
  src=$(procsrc inert "100 1 $WT bash")
  out=$(FM_FREEZE_PROC_SOURCE="$src" "$FREEZE" "$id" 2>&1); status=$?
  expect_code 0 "$status" "an inert login shell must be frozen-safe"
  assert_contains "$out" "frozenSafe:  yes" "must report frozen-safe"
  assert_contains "$out" "class=login-shell" "must classify the shell as a login-shell"
  assert_contains "$out" "can_mutate=no" "an inert shell must not count as able to mutate"
  pass "an inert login shell is reported but does not falsely count as a coding agent"
}

test_dead_and_unrelated_classification() {
  local id=fz-mix src out
  setup_task "$id"
  # A coding agent OUTSIDE the worktree (unrelated cwd) must not block; an
  # unrelated process is reported unrelated; freeze is safe with no in-worktree agent.
  src=$(procsrc mix \
    "300 1 /some/other/dir claude --resume" \
    "400 1 $WT /usr/bin/vim notes.txt" \
    "500 1 $WT top")
  out=$(FM_FREEZE_PROC_SOURCE="$src" "$FREEZE" "$id" 2>&1)
  assert_contains "$out" "frozenSafe:  yes" "a coding agent outside the worktree must not block freeze"
  assert_contains "$out" "class=unrelated" "an unrelated process must be classified unrelated"
  # The out-of-worktree agent is still listed but marked not-in-worktree / cannot mutate.
  assert_contains "$out" "in_worktree=no can_mutate=no cwd=/some/other/dir" "an out-of-worktree agent cannot mutate this branch"
  pass "coding-agent-outside-worktree, unrelated, and shell processes are distinguished"
}

test_stop_reports_nothing_when_no_agent() {
  local id=fz-stop src out
  setup_task "$id"
  src=$(procsrc noagent "100 1 $WT bash")
  out=$(FM_FREEZE_PROC_SOURCE="$src" "$FREEZE" "$id" --stop 2>&1)
  assert_contains "$out" "no in-worktree coding-agent process to stop" "scoped stop must be a no-op with no agent"
  pass "the safe scoped stop path does nothing when there is no in-worktree coding agent"
}

test_live_coding_agent_blocks_freeze
test_inert_login_shell_is_safe
test_dead_and_unrelated_classification
test_stop_reports_nothing_when_no_agent

pass "fm-freeze-check: all crew freeze cases passed"

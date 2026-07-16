#!/usr/bin/env bash
# Scope D - pre-QA gate ordering. Proves final independent QA cannot dispatch until
# every pre-QA gate is satisfied, and that QA is read-only: a QA finding cannot be
# turned into a code fix without a new commit that re-runs the gates.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GOVERN="$ROOT/bin/fm-govern.sh"
TMP_ROOT=$(fm_test_tmproot fm-govern-preqa)
export FM_HOME="$TMP_ROOT/home" FM_STATE_OVERRIDE="$TMP_ROOT/home/state"
mkdir -p "$FM_STATE_OVERRIDE"
export FM_GOV_NOW=2026-07-15T00:00:00Z
fm_git_identity

REPO="$TMP_ROOT/repo"
fm_git_init_commit "$REPO"
SHA=$(git -C "$REPO" rev-parse HEAD)

seed() {  # <task> ; frozen + review pass at SHA
  local task=$1
  "$GOVERN" record init "$task" local-only "$REPO" ident "fm/$task" "$SHA" "$SHA" "work.txt" 1 >/dev/null
  "$GOVERN" record freeze "$task" "$SHA" >/dev/null
  "$GOVERN" record attest "$task" review "$SHA" pass >/dev/null
}

preqa() { "$GOVERN" preqa-gate "$@" 2>&1; }

# Regression 10: final QA cannot dispatch before pre-QA gates complete.
test_preqa_blocks_until_all_gates() {
  local task=pq-10 out status
  seed "$task"

  out=$(preqa --task "$task" --tree-clean 0 --no-mutating-process 1 --tests-recorded 1); status=$?
  expect_code 1 "$status" "dirty tree must block QA"
  assert_contains "$out" "working tree not clean" "must name the dirty-tree blocker"

  out=$(preqa --task "$task" --tree-clean 1 --no-mutating-process 0 --tests-recorded 1); status=$?
  expect_code 1 "$status" "a live mutating process must block QA"
  assert_contains "$out" "branch-mutating process" "must name the mutating-process blocker"

  out=$(preqa --task "$task" --tree-clean 1 --no-mutating-process 1 --tests-recorded 0); status=$?
  expect_code 1 "$status" "missing tests must block QA"
  assert_contains "$out" "tests not recorded" "must name the tests blocker"

  # All gates satisfied -> READY.
  out=$(preqa --task "$task" --tree-clean 1 --no-mutating-process 1 --tests-recorded 1); status=$?
  expect_code 0 "$status" "QA must dispatch once every pre-QA gate is satisfied"
  assert_contains "$out" "READY" "must report READY"
  pass "final QA cannot dispatch before every pre-QA gate completes"
}

test_preqa_blocks_without_review() {
  local task=pq-noreview out status
  "$GOVERN" record init "$task" local-only "$REPO" ident "fm/$task" "$SHA" "$SHA" "work.txt" 1 >/dev/null
  "$GOVERN" record freeze "$task" "$SHA" >/dev/null
  out=$(preqa --task "$task" --tree-clean 1 --no-mutating-process 1 --tests-recorded 1); status=$?
  expect_code 1 "$status" "no independent review must block QA"
  assert_contains "$out" "review is not complete" "must name the review blocker"
  pass "final QA is blocked until independent review is complete"
}

test_preqa_blocks_with_unresolved_findings() {
  local task=pq-findings out status path
  seed "$task"
  path="$FM_STATE_OVERRIDE/$task.governance.json"
  jq '.classification.unresolvedFindings = 2' "$path" > "$path.tmp" && mv "$path.tmp" "$path"
  out=$(preqa --task "$task" --tree-clean 1 --no-mutating-process 1 --tests-recorded 1); status=$?
  expect_code 1 "$status" "unresolved actionable findings must block QA"
  assert_contains "$out" "unresolved actionable finding" "must name the findings blocker"
  pass "final QA is blocked while unresolved actionable findings remain"
}

test_preqa_blocks_without_freeze() {
  local task=pq-nofreeze out status
  "$GOVERN" record init "$task" local-only "$REPO" ident "fm/$task" "$SHA" "$SHA" "work.txt" 1 >/dev/null
  "$GOVERN" record attest "$task" review "$SHA" pass 2>/dev/null || true
  out=$(preqa --task "$task" --tree-clean 1 --no-mutating-process 1 --tests-recorded 1); status=$?
  expect_code 1 "$status" "an unfrozen candidate must block QA"
  pass "final QA is blocked until the candidate is frozen at an exact SHA"
}

# Regression 11: QA cannot convert its own finding into a code fix. Recording a QA
# FAIL is read-only (no commit, freeze intact); the fix must be a NEW commit that
# invalidates the freeze and forces a fresh exact-SHA QA.
test_qa_fail_is_read_only_and_forces_recycle() {
  local task=pq-11 head_before head_after fixsha out status
  seed "$task"
  "$GOVERN" record attest "$task" qa "$SHA" fail >/dev/null
  head_before=$(git -C "$REPO" rev-parse HEAD)
  # QA recorded a verdict but changed no code and did not clear the freeze.
  [ "$("$GOVERN" record get "$task" qa.verdict)" = fail ] || fail "QA verdict must be recorded as fail"
  [ "$("$GOVERN" record get "$task" landingReady)" = false ] || fail "a QA fail must not be landing-ready"
  [ "$("$GOVERN" record get "$task" frozen.sha)" = "$SHA" ] || fail "QA is read-only; freeze must be intact after a QA fail"
  head_after=$(git -C "$REPO" rev-parse HEAD)
  [ "$head_before" = "$head_after" ] || fail "recording a QA verdict must not create a commit"

  # The fix is a NEW commit -> observing it invalidates the freeze.
  printf 'fix\n' > "$REPO/work.txt"; git -C "$REPO" add work.txt; git -C "$REPO" commit -qm "fix the QA finding"
  fixsha=$(git -C "$REPO" rev-parse HEAD)
  "$GOVERN" record observe "$task" --head "$fixsha" >/dev/null
  [ "$("$GOVERN" record get "$task" frozen.sha)" = "" ] || fail "the fix commit must invalidate the old freeze"
  # A fresh exact-SHA QA cannot be attested until the new candidate is re-frozen.
  out=$("$GOVERN" record attest "$task" qa "$fixsha" pass 2>&1); status=$?
  expect_code 1 "$status" "QA cannot be attested before the new candidate is re-frozen"
  pass "a QA finding cannot become a code fix without a new commit and a fresh exact-SHA QA"
}

test_preqa_blocks_until_all_gates
test_preqa_blocks_without_review
test_preqa_blocks_with_unresolved_findings
test_preqa_blocks_without_freeze
test_qa_fail_is_read_only_and_forces_recycle

pass "fm-govern-preqa: all pre-QA ordering cases passed"

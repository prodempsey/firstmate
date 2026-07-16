#!/usr/bin/env bash
# Scope A - explicit delivery-mode validation. Proves the exact Memory PR-1
# contradiction (a local-only task whose brief also says push/update a PR) is
# refused, plus the fork/upstream/multi-canonical/deploy/merge-method conflicts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GOVERN="$ROOT/bin/fm-govern.sh"
TMP_ROOT=$(fm_test_tmproot fm-govern-delivery)
export FM_HOME="$TMP_ROOT/home" FM_STATE_OVERRIDE="$TMP_ROOT/home/state" FM_CONFIG_OVERRIDE="$TMP_ROOT/home/config"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE"
export FM_GOV_NOW=2026-07-15T00:00:00Z

run() { "$GOVERN" "$@" 2>&1; }

# Regression 1 (unit): the historical contradictory PR-1 brief fails.
test_local_only_push_pr_contradiction_refused() {
  local brief="$TMP_ROOT/pr1-brief.txt" out status
  printf 'Implement the registry fix.\npush/update PR #592 with the change.\nlocal-only: no remote/PR.\n' > "$brief"
  out=$(run delivery-check --mode local-only --text-file "$brief"); status=$?
  expect_code 1 "$status" "contradictory local-only+PR brief must be refused"
  assert_contains "$out" "CONFLICT" "refusal must name the conflict"
  assert_contains "$out" "local-only" "diagnostic must name the declared delivery mode"
  assert_contains "$out" "PR" "diagnostic must name the conflicting push/PR instruction"
  pass "local-only + 'push/update PR #592' is refused, naming both conflicting sides"
}

test_local_only_pr_flag_refused() {
  local out status
  out=$(run delivery-check --mode local-only --pr 592); status=$?
  expect_code 1 "$status" "local-only with a --pr target must be refused"
  assert_contains "$out" "CONFLICT" "must report a conflict"
  pass "local-only with an explicit PR target is refused"
}

test_fork_pr_targeting_upstream_refused() {
  local out status
  out=$(run delivery-check --mode fork-pr --target upstream); status=$?
  expect_code 1 "$status" "fork-pr targeting upstream must be refused"
  assert_contains "$out" "fork-pr" "must name the mode"
  pass "fork-pr targeting upstream is refused"
}

test_upstream_pr_targeting_fork_refused() {
  local out status
  out=$(run delivery-check --mode upstream-pr --target fork); status=$?
  expect_code 1 "$status" "upstream-pr targeting fork must be refused"
  assert_contains "$out" "upstream-pr" "must name the mode"
  pass "upstream-pr targeting a fork is refused"
}

test_multiple_canonical_repos_refused() {
  local out status
  out=$(run delivery-check --mode upstream-pr --target upstream --canonical-repos "owner/repo owner/fork"); status=$?
  expect_code 1 "$status" "two canonical repositories must be refused"
  assert_contains "$out" "canonical" "must name the split-brain declaration"
  pass "more than one canonical repository is refused"
}

test_multiple_canonical_prs_refused() {
  local out status
  out=$(run delivery-check --mode upstream-pr --target upstream --canonical-prs "591 592"); status=$?
  expect_code 1 "$status" "two canonical PRs must be refused"
  pass "more than one canonical delivery route (PR) is refused"
}

test_deploy_target_unreachable_refused() {
  local out status
  out=$(run delivery-check --mode local-only --deploy-target /srv/runtime --deploy-reachable 0); status=$?
  expect_code 1 "$status" "a path that does not reach the deployment target must be refused"
  assert_contains "$out" "deployment target" "must name the unreachable deployment target"
  pass "a delivery path that does not reach the deployment target is refused"
}

test_merge_method_not_preserving_sha_refused() {
  local out status
  out=$(run delivery-check --mode upstream-pr --target upstream --merge-method rebase --preserves-sha 0); status=$?
  expect_code 1 "$status" "a merge method that cannot preserve the exact SHA must be refused"
  assert_contains "$out" "exact reviewed SHA" "must explain the SHA-preservation requirement"
  pass "a merge method that cannot preserve the exact reviewed SHA is refused"
}

test_invalid_mode_refused() {
  local out status
  out=$(run delivery-check --mode publish-everywhere); status=$?
  expect_code 1 "$status" "an unknown delivery mode must be refused"
  pass "an unknown delivery mode is refused before dispatch"
}

test_clean_local_only_ok() {
  local brief="$TMP_ROOT/clean.txt" out status
  printf 'Implement the fix in branch fm/x and stop for local review.\n' > "$brief"
  out=$(run delivery-check --mode local-only --text-file "$brief"); status=$?
  expect_code 0 "$status" "a clean local-only task must pass"
  assert_contains "$out" "OK" "must report OK"
  pass "a clean local-only declaration with no remote instruction passes"
}

test_clean_upstream_pr_ok() {
  local out status
  out=$(run delivery-check --mode upstream-pr --target upstream --canonical-repos "owner/repo" --merge-method squash --preserves-sha 1); status=$?
  expect_code 0 "$status" "a consistent upstream-pr declaration must pass"
  pass "a consistent single-canonical upstream-pr declaration passes"
}

test_local_only_push_pr_contradiction_refused
test_local_only_pr_flag_refused
test_fork_pr_targeting_upstream_refused
test_upstream_pr_targeting_fork_refused
test_multiple_canonical_repos_refused
test_multiple_canonical_prs_refused
test_deploy_target_unreachable_refused
test_merge_method_not_preserving_sha_refused
test_invalid_mode_refused
test_clean_local_only_ok
test_clean_upstream_pr_ok

pass "fm-govern-delivery: all delivery-mode validation cases passed"

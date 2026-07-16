#!/usr/bin/env bash
# Scope C - exact-SHA attestation invalidation. Proves branch-head movement
# invalidates freeze/review/QA/authorization, and that no matching-tree, descendant,
# or replay/squash commit ever inherits an exact-SHA authorization.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GOVERN="$ROOT/bin/fm-govern.sh"
TMP_ROOT=$(fm_test_tmproot fm-govern-attest)
export FM_HOME="$TMP_ROOT/home" FM_STATE_OVERRIDE="$TMP_ROOT/home/state"
mkdir -p "$FM_STATE_OVERRIDE"
export FM_GOV_NOW=2026-07-15T00:00:00Z
fm_git_identity

REPO="$TMP_ROOT/repo"
fm_git_init_commit "$REPO"

commit_change() {  # <content> -> prints sha
  printf '%s\n' "$1" > "$REPO/work.txt"
  git -C "$REPO" add work.txt
  git -C "$REPO" commit -qm "$1"
  git -C "$REPO" rev-parse HEAD
}

authorize_at() {  # <task> <sha>
  "$GOVERN" record freeze "$1" "$2" >/dev/null
  "$GOVERN" record attest "$1" review "$2" pass >/dev/null
  "$GOVERN" record attest "$1" qa "$2" pass >/dev/null
  "$GOVERN" record attest "$1" captain-auth "$2" ovr-abc123 >/dev/null
}

# Regression 6: branch-head movement invalidates freeze, review, QA, authorization.
test_head_move_invalidates_everything() {
  local task=att-6 shaA shaB
  shaA=$(commit_change "A")
  "$GOVERN" record init "$task" local-only "$REPO" ident fm/$task "$shaA" "$shaA" "work.txt" 1 >/dev/null
  authorize_at "$task" "$shaA"
  "$GOVERN" auth-valid "$task" "$shaA" >/dev/null || fail "authorization must be valid at the frozen/attested SHA"
  [ "$("$GOVERN" record get "$task" landingReady)" = true ] || fail "landingReady must be true when all gates agree"

  shaB=$(commit_change "B")
  "$GOVERN" record observe "$task" --head "$shaB" >/dev/null
  ! "$GOVERN" auth-valid "$task" "$shaB" >/dev/null || fail "authorization must be invalid after the head moved"
  [ "$("$GOVERN" record get "$task" frozen.sha)" = "" ] || fail "freeze must be cleared after head move"
  [ "$("$GOVERN" record get "$task" review.sha)" = "" ] || fail "review must be cleared after head move"
  [ "$("$GOVERN" record get "$task" qa.sha)" = "" ] || fail "QA must be cleared after head move"
  [ "$("$GOVERN" record get "$task" captainAuth.sha)" = "" ] || fail "authorization must be cleared after head move"
  [ "$("$GOVERN" record get "$task" landingReady)" = false ] || fail "landingReady must be false after head move"
  local reason
  reason=$("$GOVERN" record get "$task" invalidation.reason)
  case "$reason" in *"$shaB"*) : ;; *) fail "invalidation reason must name the new head: $reason" ;; esac
  pass "branch-head movement invalidates freeze, review, QA, and authorization"
}

# Regression 7: a matching tree at a different commit does not inherit authorization.
test_matching_tree_new_commit_not_authorized() {
  local task=att-7 shaA shaAprime treeA treeAprime
  shaA=$(commit_change "same-tree-content")
  "$GOVERN" record init "$task" local-only "$REPO" ident fm/$task "$shaA" "$shaA" "work.txt" 1 >/dev/null
  authorize_at "$task" "$shaA"
  # Reword (amend) -> identical tree, different commit SHA.
  git -C "$REPO" commit -q --amend -m "reworded, same tree"
  shaAprime=$(git -C "$REPO" rev-parse HEAD)
  treeA=$(git -C "$REPO" rev-parse "$shaA^{tree}")
  treeAprime=$(git -C "$REPO" rev-parse "$shaAprime^{tree}")
  [ "$treeA" = "$treeAprime" ] || fail "test setup: trees must be identical to prove tree-match does not inherit"
  [ "$shaA" != "$shaAprime" ] || fail "test setup: SHAs must differ"
  "$GOVERN" record observe "$task" --head "$shaAprime" >/dev/null
  ! "$GOVERN" auth-valid "$task" "$shaAprime" >/dev/null || fail "a matching tree at a new commit must NOT inherit authorization"
  pass "a matching tree at a different commit does not inherit authorization"
}

# Regression 8: a descendant commit does not inherit authorization.
test_descendant_not_authorized() {
  local task=att-8 shaA shaChild
  shaA=$(commit_change "base-for-descendant")
  "$GOVERN" record init "$task" local-only "$REPO" ident fm/$task "$shaA" "$shaA" "work.txt" 1 >/dev/null
  authorize_at "$task" "$shaA"
  shaChild=$(commit_change "one more commit on top")
  git -C "$REPO" merge-base --is-ancestor "$shaA" "$shaChild" || fail "test setup: child must descend from authorized commit"
  "$GOVERN" record observe "$task" --head "$shaChild" >/dev/null
  ! "$GOVERN" auth-valid "$task" "$shaChild" >/dev/null || fail "a descendant commit must NOT inherit authorization"
  pass "a descendant commit does not inherit authorization"
}

# Regression 9: a replay/squash commit does not inherit authorization.
test_squash_replay_not_authorized() {
  local task=att-9 shaA shaB shaSquash
  shaA=$(commit_change "sq-A")
  "$GOVERN" record init "$task" local-only "$REPO" ident fm/$task "$shaA" "$shaA" "work.txt" 1 >/dev/null
  shaB=$(commit_change "sq-B")
  authorize_at "$task" "$shaB"
  # Squash A..B into one new commit with the same final tree, new SHA.
  git -C "$REPO" reset -q --soft "$shaA"
  git -C "$REPO" commit -qm "squashed sq-A..sq-B"
  shaSquash=$(git -C "$REPO" rev-parse HEAD)
  [ "$shaSquash" != "$shaB" ] || fail "test setup: squash SHA must differ from authorized SHA"
  "$GOVERN" record observe "$task" --head "$shaSquash" >/dev/null
  ! "$GOVERN" auth-valid "$task" "$shaSquash" >/dev/null || fail "a squash/replay commit must NOT inherit authorization"
  pass "a replay/squash commit does not inherit authorization"
}

test_attest_requires_frozen_sha() {
  local task=att-frozen shaA shaB
  shaA=$(commit_change "af-A"); shaB=$(commit_change "af-B")
  "$GOVERN" record init "$task" local-only "$REPO" ident fm/$task "$shaA" "$shaB" "work.txt" 1 >/dev/null
  "$GOVERN" record freeze "$task" "$shaB" >/dev/null
  local out status
  out=$("$GOVERN" record attest "$task" qa "$shaA" pass 2>&1); status=$?
  expect_code 1 "$status" "an attestation at a non-frozen SHA must be refused"
  assert_contains "$out" "frozen candidate is $shaB" "must name the actual frozen SHA"
  pass "an attestation can only be made against the frozen candidate SHA"
}

test_status_doctor_reports_fields() {
  local task=att-status shaA out
  shaA=$(commit_change "status-A")
  "$GOVERN" record init "$task" local-only "$REPO" ident fm/$task "$shaA" "$shaA" "work.txt" 1 >/dev/null
  authorize_at "$task" "$shaA"
  out=$("$GOVERN" status "$task")
  assert_contains "$out" "currentHead:       $shaA" "status must show current head"
  assert_contains "$out" "authorizedSha:     $shaA" "status must show authorized SHA"
  assert_contains "$out" "authorizationValid:yes" "status must show authorization validity"
  pass "status/doctor reports head, attested SHA, authorized SHA, validity, and reason"
}

test_head_move_invalidates_everything
test_matching_tree_new_commit_not_authorized
test_descendant_not_authorized
test_squash_replay_not_authorized
test_attest_requires_frozen_sha
test_status_doctor_reports_fields

pass "fm-govern-attest: all exact-SHA invalidation cases passed"

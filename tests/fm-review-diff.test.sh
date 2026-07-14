#!/usr/bin/env bash
# Tests for bin/fm-review-diff.sh.
#
# The base must be the one the work will actually land on, chosen by delivery
# mode, and the tool must fail loudly rather than guess a base it cannot resolve.
#
# Base matrix:
#   (e) mode=local-only with a DIVERGED origin -> base is local <default>, so the
#       diff is the change set, not the whole cross-lineage gap (the regression:
#       the old code picked origin/<default> whenever an origin remote existed)
#   (f) mode=no-mistakes -> base is origin/<default>, the branch its PR merges into
#   (g) mode unresolvable (no mode= in meta, project not registered) -> loud failure
#   (h) mode=no-mistakes with no origin remote -> loud failure, no guessed base
#
# PR-head matrix (compare side; must not regress):
#   (a) pr= + reachable pr_head= -> diff uses PR head, not the lagging local branch
#   (b) pr= without pr_head= -> fetch refs/pull/<n>/head and diff that
#   (c) pr= absent -> unchanged worktree-branch diff
#   (d) pr= present but PR head unreachable -> fallback to local branch + warning
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

REVIEW_DIFF="$ROOT/bin/fm-review-diff.sh"
TMP_ROOT=$(fm_test_tmproot fm-review-diff-tests)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/data"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  printf 'base\n' > "$case_dir/_seed/feature.txt"
  git -C "$case_dir/_seed" add feature.txt
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -qm "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"

  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

# A diverged fleet: local main carries local-only work that was never pushed, and
# origin/main carries upstream commits local main never took. This is the shape
# that made the old code report a one-file fix as a whole-lineage rewrite.
make_diverged_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/data"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  printf 'base\n' > "$case_dir/_seed/feature.txt"
  git -C "$case_dir/_seed" add feature.txt
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -qm "origin baseline"
  git -C "$case_dir/_seed" push -q origin main

  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true

  # origin/main moves on with work local main never takes.
  printf 'upstream\n' > "$case_dir/_seed/upstream-only.txt"
  git -C "$case_dir/_seed" add upstream-only.txt
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -qm "upstream-only commit"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"

  # local main carries local-only tooling that was never pushed.
  printf 'local tooling\n' > "$case_dir/project/local-tool.sh"
  git -C "$case_dir/project" add local-tool.sh
  git -C "$case_dir/project" commit -qm "local-only tooling"

  # The crewmate branches off local main and makes one small change.
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  printf 'fixed\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "the actual fix"

  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

write_task_meta() {
  local case_dir=$1 mode=$2
  shift 2
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "mode=$mode" \
    "$@"
}

# Meta with no mode= at all: the legacy shape whose base must come from the
# registry, or fail loudly when the registry cannot answer either.
write_task_meta_without_mode() {
  local case_dir=$1
  shift
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "$@"
}

stale_and_pr_commits() {
  local case_dir=$1
  printf 'stale-local\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "stale local branch"

  git -C "$case_dir/wt" checkout -q -b pr-head-tmp
  printf 'pr-fixed\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "pipeline fix on PR"
  PR_SHA=$(git -C "$case_dir/wt" rev-parse HEAD)

  git -C "$case_dir/wt" checkout -q fm/task-x1
}

run_review_diff() {
  local case_dir=$1
  shift
  # FM_DATA_OVERRIDE points at the case's own (empty by default) data dir so the
  # registry fallback can never reach this developer's real data/projects.md.
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
    "$REVIEW_DIFF" "$@"
}

test_pr_meta_uses_pr_head_not_stale_local() {
  local case_dir out
  case_dir=$(make_case pr-head-sha)
  stale_and_pr_commits "$case_dir"
  write_task_meta "$case_dir" no-mistakes \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=$PR_SHA"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+pr-fixed' "pr-head-sha: diff should show the PR head content"
  assert_not_contains "$out" 'stale-local' "pr-head-sha: diff must not use the stale local branch"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "pr-head-sha: should not warn when pr_head is reachable"
  pass "fm-review-diff uses recorded pr_head instead of the lagging local branch"
}

test_pr_meta_fetches_pull_head_without_recorded_sha() {
  local case_dir out
  case_dir=$(make_case pr-fetch)
  stale_and_pr_commits "$case_dir"
  git -C "$case_dir/wt" push -q origin "pr-head-tmp:refs/pull/9/head"
  write_task_meta "$case_dir" no-mistakes "pr=https://github.com/example/repo/pull/9"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+pr-fixed' "pr-fetch: diff should use fetched PR head"
  assert_not_contains "$out" 'stale-local' "pr-fetch: diff must not use the stale local branch"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "pr-fetch: should not warn when fetch succeeds"
  pass "fm-review-diff fetches refs/pull/<n>/head when pr_head= is absent"
}

test_no_pr_meta_uses_local_branch() {
  local case_dir out
  case_dir=$(make_case no-pr-meta)
  stale_and_pr_commits "$case_dir"
  write_task_meta "$case_dir" no-mistakes

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+stale-local' "no-pr-meta: diff should still use the local branch"
  assert_not_contains "$out" '+pr-fixed' "no-pr-meta: diff must not jump to the unpushed PR commit"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "no-pr-meta: no warning without pr= in meta"
  pass "fm-review-diff without pr= keeps the worktree-branch diff"
}

test_unreachable_pr_head_falls_back_with_warning() {
  local case_dir out err
  case_dir=$(make_case fetch-fallback)
  stale_and_pr_commits "$case_dir"
  # The PR head is unreachable: the recorded sha is not a real object here, and
  # refs/pull/9/head was never pushed, so the fetch cannot resolve it either.
  write_task_meta "$case_dir" no-mistakes \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

  set +e
  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")
  set -e
  err=$(cat "$case_dir/stderr")

  assert_contains "$err" 'warning: PR head unavailable; diff may lag the open PR' \
    "fetch-fallback: must warn when PR head cannot be resolved"
  assert_contains "$out" '+stale-local' "fetch-fallback: should fall back to the local branch diff"
  assert_not_contains "$out" '+pr-fixed' "fetch-fallback: must not invent a PR head diff offline"
  pass "fm-review-diff falls back to local branch with a warning when PR head is unreachable"
}

test_local_only_diffs_against_local_default_not_diverged_origin() {
  local case_dir out
  case_dir=$(make_diverged_case local-only-diverged)
  write_task_meta "$case_dir" local-only

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" 'diff base: main (local)' \
    "local-only-diverged: must diff against the branch fm-merge-local.sh will fast-forward"
  assert_contains "$out" '+fixed' "local-only-diverged: the actual change must be visible"
  assert_contains "$out" '1 file changed' \
    "local-only-diverged: the change set is one file; anything more is lineage noise"
  # Against the diverged origin/main, the never-pushed local work is misreported
  # as content this task added - the inflation that makes the review worthless -
  # and upstream-only content it never touched must never appear either.
  assert_not_contains "$out" 'local-tool.sh' \
    "local-only-diverged: local-only tooling must not be reported as part of this change"
  assert_not_contains "$out" 'upstream-only.txt' \
    "local-only-diverged: must not report cross-lineage content as part of this change"
  pass "fm-review-diff diffs a local-only task against local main, not the diverged origin"
}

test_pr_mode_diffs_against_origin_default() {
  local case_dir out
  case_dir=$(make_diverged_case pr-mode-origin)
  write_task_meta "$case_dir" no-mistakes

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" 'diff base: origin/main' \
    "pr-mode-origin: a PR-based task must diff against the branch its PR merges into"
  assert_contains "$out" '+fixed' "pr-mode-origin: the actual change must still be visible"
  pass "fm-review-diff diffs a PR-based task against origin/<default>"
}

test_unresolvable_mode_fails_loudly() {
  local case_dir status err
  case_dir=$(make_diverged_case unresolvable-mode)
  write_task_meta_without_mode "$case_dir"

  set +e
  run_review_diff "$case_dir" task-x1 > "$case_dir/out" 2> "$case_dir/stderr"
  status=$?
  set -e
  err=$(cat "$case_dir/stderr")

  [ "$status" -ne 0 ] || fail "unresolvable-mode: must exit non-zero rather than guess a base"
  assert_contains "$err" 'cannot resolve the delivery mode' \
    "unresolvable-mode: must say why the base is unknown"
  assert_not_contains "$(cat "$case_dir/out")" 'diff base:' \
    "unresolvable-mode: must not print a diff against a guessed base"
  pass "fm-review-diff fails loudly when the landing base cannot be resolved"
}

test_mode_falls_back_to_registry() {
  local case_dir out
  case_dir=$(make_diverged_case registry-mode)
  write_task_meta_without_mode "$case_dir"
  printf -- '- %s [local-only] - diverged fleet project (added 2026-07-14)\n' \
    "$(basename "$case_dir/project")" > "$case_dir/data/projects.md"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" 'diff base: main (local)' \
    "registry-mode: a meta without mode= must take the mode from the registry"
  assert_not_contains "$out" 'upstream-only.txt' \
    "registry-mode: must not fall back to the diverged origin base"
  pass "fm-review-diff resolves a missing mode= from the project registry"
}

test_pr_mode_without_origin_fails_loudly() {
  local case_dir status err
  case_dir=$(make_diverged_case pr-mode-no-origin)
  write_task_meta "$case_dir" no-mistakes
  git -C "$case_dir/project" remote remove origin

  set +e
  run_review_diff "$case_dir" task-x1 > "$case_dir/out" 2> "$case_dir/stderr"
  status=$?
  set -e
  err=$(cat "$case_dir/stderr")

  [ "$status" -ne 0 ] || fail "pr-mode-no-origin: must exit non-zero, not diff against the local branch"
  assert_contains "$err" 'no origin remote' \
    "pr-mode-no-origin: must say the PR base is unresolvable"
  assert_not_contains "$(cat "$case_dir/out")" 'diff base:' \
    "pr-mode-no-origin: must not print a diff against a guessed base"
  pass "fm-review-diff fails loudly when a PR-based task has no remote base to compare against"
}

test_local_only_diffs_against_local_default_not_diverged_origin
test_pr_mode_diffs_against_origin_default
test_unresolvable_mode_fails_loudly
test_mode_falls_back_to_registry
test_pr_mode_without_origin_fails_loudly
test_pr_meta_uses_pr_head_not_stale_local
test_pr_meta_fetches_pull_head_without_recorded_sha
test_no_pr_meta_uses_local_branch
test_unreachable_pr_head_falls_back_with_warning

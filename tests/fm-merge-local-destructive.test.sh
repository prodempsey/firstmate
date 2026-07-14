#!/usr/bin/env bash
# Behavior tests for fm-merge-local.sh's destructive-merge backstop
# (bug-20260714043857-416f07b4).
#
# A branch built on a base that is missing part of the default branch carries a
# tree without those files. Fast-forward-only does not protect against it: once
# such a branch is an ancestor-descendant of the default branch, the merge
# happily deletes every file the base was missing. fm-merge-local.sh must refuse
# any merge whose diff deletes tracked files no commit on the branch ever
# touched, and must still allow deletions the branch made deliberately.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-destructive)

# A project whose local main carries commits a stale base does not have:
# base commit -> "tooling" files added on main afterwards. Echoes the base SHA
# (the stale base a pooled worktree would have handed a crew). Nothing untracked
# is left behind: fm-merge-local.sh refuses a dirty project, by design.
make_project() {  # <proj>
  local proj=$1 base f
  fm_git_init_commit "$proj"
  git -C "$proj" branch -M main
  base=$(git -C "$proj" rev-parse HEAD)
  for f in tooling-a tooling-b tooling-c; do
    printf 'fleet tooling %s\n' "$f" > "$proj/$f.sh"
  done
  git -C "$proj" add tooling-a.sh tooling-b.sh tooling-c.sh
  git -C "$proj" commit -qm 'local-only fleet tooling'
  printf '%s\n' "$base"
}

# The post-merge durable-closure write (bin/fm-task-events.sh) talks to fleet
# bridge's visibility CLI, which no test fixture has. Stub it via the script's own
# FM_VISIBILITY_CLI knob: these tests are about the merge guard, not closure
# bookkeeping, and a successful merge must still reach that step.
VIS_STUB="$TMP_ROOT/visibility-stub.mjs"
mkdir -p "$TMP_ROOT"
printf 'process.exit(0);\n' > "$VIS_STUB"

run_merge() {  # <home> <id>
  local home=$1 id=$2
  env FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_VISIBILITY_CLI="$VIS_STUB" \
    "$MERGE" "$id" 2>&1
}

setup_task() {  # <home> <id> <proj>
  local home=$1 id=$2 proj=$3
  mkdir -p "$home/state"
  fm_write_meta "$home/state/$id.meta" \
    "project=$proj" "mode=local-only" "kind=ship" "yolo=off"
}

# T1: the live bug. A branch based on the stale base, made a fast-forwardable
# descendant of main by a merge that keeps its own tree, deletes the tooling
# files its base never had. That merge must be REFUSED.
test_refuses_deletions_branch_never_touched() {
  local home proj id base out status
  id=stale-base-t1
  home="$TMP_ROOT/t1-home"
  proj="$TMP_ROOT/t1-proj"
  base=$(make_project "$proj")
  setup_task "$home" "$id" "$proj"

  # Crew branches from the stale base and makes one honest, unrelated change.
  git -C "$proj" checkout -q -b "fm/$id" "$base"
  printf 'the actual fix\n' > "$proj/fix.txt"
  git -C "$proj" add fix.txt
  git -C "$proj" commit -qm 'the real work: one file'
  # It then absorbs main in a way that keeps its own tree, so the branch becomes
  # a fast-forward of main while its tree is still missing main's tooling.
  git -C "$proj" merge -q -s ours --no-edit main -m 'absorb main'
  git -C "$proj" checkout -q main

  # Precondition: git really would fast-forward, and really would delete.
  git -C "$proj" merge-base --is-ancestor main "fm/$id" ||
    fail "T1 fixture is not a fast-forward; the guard under test would not be reached"
  git -C "$proj" diff --diff-filter=D --name-only "main..fm/$id" | grep -q tooling-a.sh ||
    fail "T1 fixture does not reproduce the deletion; nothing to guard"

  out=$(run_merge "$home" "$id"); status=$?

  expect_code 1 "$status" "destructive merge must be refused"$'\n'"$out"
  assert_contains "$out" "REFUSED" "refusal must say REFUSED"
  assert_contains "$out" "no commit on fm/$id ever touched" \
    "refusal must explain the files were never touched by the branch"
  assert_contains "$out" "tooling-a.sh" "refusal must name the files it would have deleted"
  # The whole point: main still has its tooling.
  assert_present "$proj/tooling-a.sh" "refused merge must leave main's tooling on disk"
  assert_present "$proj/tooling-b.sh" "refused merge must leave main's tooling on disk"
  git -C "$proj" cat-file -e "main:tooling-c.sh" ||
    fail "refused merge must leave main's tooling tracked on main"
  pass "T1: merge deleting tracked files the branch never touched is refused; main intact"
}

# T2: a branch that deliberately deletes a file (its own commit records the
# deletion) still merges. The guard must not block honest removals.
test_allows_deliberate_deletion() {
  local home proj id out status
  id=intentional-del-t2
  home="$TMP_ROOT/t2-home"
  proj="$TMP_ROOT/t2-proj"
  make_project "$proj" >/dev/null
  setup_task "$home" "$id" "$proj"

  git -C "$proj" checkout -q -b "fm/$id" main
  git -C "$proj" rm -q tooling-b.sh
  printf 'replacement\n' > "$proj/tooling-b2.sh"
  git -C "$proj" add tooling-b2.sh
  git -C "$proj" commit -qm 'retire tooling-b in favour of tooling-b2'
  git -C "$proj" checkout -q main

  out=$(run_merge "$home" "$id"); status=$?

  expect_code 0 "$status" "deliberate deletion must still merge"$'\n'"$out"
  assert_contains "$out" "merged fm/$id into local main" "expected the merge to land"
  assert_absent "$proj/tooling-b.sh" "the deliberately deleted file should be gone"
  assert_present "$proj/tooling-b2.sh" "the replacement should be present"
  assert_present "$proj/tooling-a.sh" "untouched tooling must survive"
  pass "T2: a deletion the branch's own commit made is allowed through"
}

# T3: an ordinary add-only branch is unaffected by the guard.
test_allows_clean_branch() {
  local home proj id out status
  id=clean-branch-t3
  home="$TMP_ROOT/t3-home"
  proj="$TMP_ROOT/t3-proj"
  make_project "$proj" >/dev/null
  setup_task "$home" "$id" "$proj"

  git -C "$proj" checkout -q -b "fm/$id" main
  printf 'new feature\n' > "$proj/feature.sh"
  git -C "$proj" add feature.sh
  git -C "$proj" commit -qm 'add feature'
  git -C "$proj" checkout -q main

  out=$(run_merge "$home" "$id"); status=$?

  expect_code 0 "$status" "clean add-only branch must merge"$'\n'"$out"
  assert_present "$proj/feature.sh" "feature should have landed"
  assert_present "$proj/tooling-a.sh" "tooling must survive"
  pass "T3: an ordinary add-only branch merges unaffected"
}

test_refuses_deletions_branch_never_touched
test_allows_deliberate_deletion
test_allows_clean_branch

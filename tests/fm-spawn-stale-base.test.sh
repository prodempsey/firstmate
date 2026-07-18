#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's stale-base guard (bug-20260714043857-416f07b4).
#
# A pooled worktree can be parked on a commit that does NOT contain the project's
# local default-branch tip - a stale pool slot, or a base that predates commits
# that only ever landed locally (the firstmate repo's own local-only tooling is
# the live case). A crew launched there has no way to know: everything on the
# local default branch but missing from its base reads to git as "this branch
# deletes those files", which is how a nine-file change presented as ~19.6k
# deletions across 154 files.
#
# So fm-spawn must never SILENTLY launch a crew onto such a base. It either
# re-places the (clean) worktree onto the local default-branch commit, or it
# refuses loudly. It must never write meta and launch on a stale base.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-stale-base)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|send-keys) exit 0 ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
# Record every non-get invocation (notably `return`) so a test can assert that a
# refused spawn released the lease it acquired (bughunt-fm-h2 finding 1).
if [ -n "${FM_TEST_TH_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$FM_TEST_TH_LOG"
fi
if [ "${1:-}" = get ]; then
  printf '%s\n' "${FM_TEST_LEASE_PATH:-${FM_FAKE_PANE_PATH:-}}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

run_spawn() {  # <home> <id> <proj> <worktree> <fakebin>
  local home=$1 id=$2 proj=$3 wt=$4 fakebin=$5
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  printf 'brief\n' > "$home/data/$id/brief.md"
  env -u TMUX \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
    FM_FAKE_PANE_PATH="$wt" FM_TEST_LEASE_PATH="$wt" \
    TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" codex 2>&1
}

# A project whose local main carries a commit the pooled worktree's base does
# not have. Echoes "<proj> <stale-base-sha>".
make_stale_project() {  # <proj>
  local proj=$1 base
  fm_git_init_commit "$proj"
  git -C "$proj" branch -M main
  base=$(git -C "$proj" rev-parse HEAD)
  printf 'fleet tooling\n' > "$proj/tooling.sh"
  printf 'captain orders\n' > "$proj/orders.md"
  git -C "$proj" add tooling.sh orders.md
  git -C "$proj" commit -qm 'local-only fleet tooling'
  printf '%s\n' "$base"
}

# S1: clean pooled worktree parked on the stale base. The crew must NOT be left
# there: fm-spawn re-places the worktree onto local main before launch.
test_stale_base_worktree_is_replaced_onto_local_main() {
  local home proj base pool_wt fakebin out status id
  id=stale-base-s1
  home="$TMP_ROOT/s1-home"
  proj="$TMP_ROOT/s1-proj"
  mkdir -p "$home/data"
  base=$(make_stale_project "$proj")
  proj=$(cd "$proj" && pwd)
  pool_wt="$TMP_ROOT/.treehouse/s1-pool/1/repo"
  # The bug in one line: the pool slot is on the stale base, not on local main.
  git -C "$proj" worktree add -q --detach "$pool_wt" "$base"
  pool_wt=$(cd "$pool_wt" && pwd)
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/s1-fake")

  # Precondition: this really is a stale base, and it really is missing the files.
  git -C "$pool_wt" merge-base --is-ancestor main HEAD 2>/dev/null &&
    fail "S1 fixture base already contains main; nothing stale to guard"
  [ -f "$pool_wt/tooling.sh" ] && fail "S1 fixture base should be missing main's tooling"

  out=$(run_spawn "$home" "$id" "$proj" "$pool_wt" "$fakebin"); status=$?
  rm -rf "/tmp/fm-$id" 2>/dev/null || true

  expect_code 0 "$status" "clean stale-base worktree should be repaired, not refused"$'\n'"$out"
  git -C "$pool_wt" merge-base --is-ancestor main HEAD ||
    fail "crew was left on a base that does not contain local main"$'\n'"$out"
  assert_present "$pool_wt/tooling.sh" "re-placed worktree must have main's tooling present"
  assert_present "$pool_wt/orders.md" "re-placed worktree must have main's tooling present"
  pass "S1: a clean worktree on a stale base is re-placed onto local main before launch"
}

# S2: the worktree is on a stale base AND dirty, so it cannot be safely
# re-placed. fm-spawn must refuse loudly rather than launch onto the bad base.
test_dirty_stale_base_worktree_refused() {
  local home proj base pool_wt fakebin out status id
  id=stale-dirty-s2
  home="$TMP_ROOT/s2-home"
  proj="$TMP_ROOT/s2-proj"
  mkdir -p "$home/data"
  base=$(make_stale_project "$proj")
  proj=$(cd "$proj" && pwd)
  pool_wt="$TMP_ROOT/.treehouse/s2-pool/1/repo"
  git -C "$proj" worktree add -q --detach "$pool_wt" "$base"
  pool_wt=$(cd "$pool_wt" && pwd)
  printf 'leftover\n' > "$pool_wt/leftover.txt"
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/s2-fake")

  out=$(run_spawn "$home" "$id" "$proj" "$pool_wt" "$fakebin"); status=$?
  rm -rf "/tmp/fm-$id" 2>/dev/null || true

  expect_code 1 "$status" "dirty stale-base worktree must refuse"$'\n'"$out"
  assert_contains "$out" "does not contain" "refusal must name the stale-base problem"
  assert_contains "$out" "mass deletion" "refusal must explain the consequence"
  assert_absent "$home/state/$id.meta" "a refused spawn must not write meta"
  pass "S2: a dirty worktree on a stale base is refused loudly; no meta written"
}

# S3: a pool worktree already on local main spawns normally and is left alone.
test_fresh_base_unaffected() {
  local home proj pool_wt fakebin out status id head_before head_after
  id=fresh-base-s3
  home="$TMP_ROOT/s3-home"
  proj="$TMP_ROOT/s3-proj"
  mkdir -p "$home/data"
  make_stale_project "$proj" >/dev/null
  proj=$(cd "$proj" && pwd)
  pool_wt="$TMP_ROOT/.treehouse/s3-pool/1/repo"
  git -C "$proj" worktree add -q --detach "$pool_wt" main
  pool_wt=$(cd "$pool_wt" && pwd)
  head_before=$(git -C "$pool_wt" rev-parse HEAD)
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/s3-fake")

  out=$(run_spawn "$home" "$id" "$proj" "$pool_wt" "$fakebin"); status=$?
  rm -rf "/tmp/fm-$id" 2>/dev/null || true

  expect_code 0 "$status" "good base should spawn normally"$'\n'"$out"
  head_after=$(git -C "$pool_wt" rev-parse HEAD)
  [ "$head_before" = "$head_after" ] ||
    fail "guard moved a worktree that already contained local main"
  assert_present "$home/state/$id.meta" "successful spawn must write meta"
  pass "S3: a worktree already containing local main is spawned untouched"
}

# S4: a spawn refused AFTER the treehouse lease was acquired must RETURN that
# lease, not leak it (bughunt-fm-h2 finding 1). The dirty stale-base refuse is a
# convenient post-lease refusal: the lease is held when fm-spawn decides to abort.
# Before the fix the lease was leaked (only the pre-lease membership path returned
# it), which exhausts the pool over repeated failed spawns.
test_refused_spawn_returns_leased_worktree() {
  local home proj base pool_wt fakebin out status id th_log
  id=stale-leak-s4
  home="$TMP_ROOT/s4-home"
  proj="$TMP_ROOT/s4-proj"
  th_log="$TMP_ROOT/s4-th.log"
  : > "$th_log"
  mkdir -p "$home/data"
  base=$(make_stale_project "$proj")
  proj=$(cd "$proj" && pwd)
  pool_wt="$TMP_ROOT/.treehouse/s4-pool/1/repo"
  git -C "$proj" worktree add -q --detach "$pool_wt" "$base"
  pool_wt=$(cd "$pool_wt" && pwd)
  printf 'leftover\n' > "$pool_wt/leftover.txt"   # dirty => refused after lease
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/s4-fake")

  export FM_TEST_TH_LOG="$th_log"
  out=$(run_spawn "$home" "$id" "$proj" "$pool_wt" "$fakebin"); status=$?
  unset FM_TEST_TH_LOG
  rm -rf "/tmp/fm-$id" 2>/dev/null || true

  expect_code 1 "$status" "dirty stale-base worktree must refuse"$'\n'"$out"
  assert_absent "$home/state/$id.meta" "a refused spawn must not leave meta behind"
  grep -q "return .*$pool_wt" "$th_log" \
    || fail "refused spawn must return the leased worktree; treehouse calls were:"$'\n'"$(cat "$th_log")"
  pass "S4: a spawn refused after the lease is acquired returns the leased worktree"
}

test_stale_base_worktree_is_replaced_onto_local_main
test_dirty_stale_base_worktree_refused
test_fresh_base_unaffected
test_refused_spawn_returns_leased_worktree

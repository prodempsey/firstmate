#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh project-membership + pool-prefix guards.
#
# Layer A: captured worktree must share git-common-dir with the target project
# and must not be the primary checkout.
# Layer B: worktree comes from `treehouse get --lease` (not pane cwd), so a
# same-repo sibling path reported by the pane cannot latch into meta.
# Pool-prefix: treehouse acquires must sit under `/.treehouse/` so long-lived
# same-repo siblings (serving checkouts) are refused even if they share a
# common-dir.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-project)

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
  # Lease path is authoritative. Optional FM_TEST_LEASE_PATH overrides the
  # default FM_FAKE_PANE_PATH so tests can feed a wrong pane path while the
  # lease still returns the correct pool slot (race / sibling latch guard).
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ]; then
  if [ -n "${FM_TEST_LEASE_PATH:-}" ]; then
    printf '%s\n' "$FM_TEST_LEASE_PATH"
  else
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
  fi
  exit 0
fi
# Best-effort release after a refused lease; no-op is fine in tests.
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

run_spawn() {
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5
  local lease=${6:-$pane}
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  printf 'brief\n' > "$home/data/$id/brief.md"
  env -u TMUX \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
    FM_FAKE_PANE_PATH="$pane" \
    FM_TEST_LEASE_PATH="$lease" \
    TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" codex 2>&1
}

# T1: foreign project's worktree (`.fb-redesign` class when spawning firstmate)
test_foreign_project_worktree_refused() {
  local home proj foreign foreign_wt fakebin out status id
  id="foreign-wt-t1"
  home="$TMP_ROOT/foreign-home"
  mkdir -p "$home/data"
  proj="$TMP_ROOT/foreign-proj"
  foreign="$TMP_ROOT/foreign-other"
  fm_git_init_commit "$proj"
  fm_git_init_commit "$foreign"
  foreign_wt="$TMP_ROOT/.treehouse/other-pool/1/wt"
  git -C "$foreign" worktree add -q --detach "$foreign_wt"
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/foreign-fake")

  out=$(run_spawn "$home" "$id" "$proj" "$foreign_wt" "$fakebin"); status=$?
  rm -rf "/tmp/fm-$id" 2>/dev/null || true

  expect_code 1 "$status" "foreign worktree must refuse"
  assert_contains "$out" "not a linked worktree of project" \
    "foreign worktree lacked membership error"
  assert_contains "$out" "git-common-dir=" \
    "membership error should include common-dir detail"
  assert_absent "$home/state/$id.meta" "foreign refuse must not write meta"
  pass "T1: foreign project worktree is refused with membership error; no meta"
}

# T2: same-repo long-lived sibling outside the pool (serving checkout class)
test_same_repo_sibling_outside_pool_refused() {
  local home proj sibling fakebin out status id
  id="sibling-wt-t2"
  home="$TMP_ROOT/sibling-home"
  mkdir -p "$home/data"
  proj="$TMP_ROOT/sibling-proj"
  fm_git_init_commit "$proj"
  sibling="$TMP_ROOT/serving-checkout"
  git -C "$proj" worktree add -q --detach "$sibling"
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/sibling-fake")

  out=$(run_spawn "$home" "$id" "$proj" "$sibling" "$fakebin"); status=$?
  rm -rf "/tmp/fm-$id" 2>/dev/null || true

  expect_code 1 "$status" "same-repo sibling outside pool must refuse"
  assert_contains "$out" "not under the treehouse pool" \
    "sibling outside pool lacked non_pool error"
  assert_absent "$home/state/$id.meta" "sibling refuse must not write meta"
  pass "T2: same-repo long-lived sibling outside pool is refused; no meta"
}

# T3: correct pool worktree of the project is accepted
test_correct_pool_worktree_accepted() {
  local home proj pool_wt fakebin out status id meta_wt
  id=pool-ok-t3
  home="$TMP_ROOT/pool-ok-home"
  mkdir -p "$home/data"
  proj="$TMP_ROOT/pool-ok-proj"
  fm_git_init_commit "$proj"
  # Canonicalize: meta records PROJ_ABS from cd+pwd (logical form).
  proj=$(cd "$proj" && pwd)
  pool_wt="$TMP_ROOT/.treehouse/pool-ok/1/repo"
  git -C "$proj" worktree add -q --detach "$pool_wt"
  pool_wt=$(cd "$pool_wt" && pwd)
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/pool-ok-fake")

  out=$(run_spawn "$home" "$id" "$proj" "$pool_wt" "$fakebin"); status=$?
  rm -rf "/tmp/fm-$id" 2>/dev/null || true

  expect_code 0 "$status" "correct pool worktree should succeed"$'\n'"$out"
  assert_present "$home/state/$id.meta" "successful spawn must write meta"
  meta_wt=$(grep '^worktree=' "$home/state/$id.meta" | cut -d= -f2-)
  [ "$meta_wt" = "$pool_wt" ] || fail "meta worktree='$meta_wt' expected '$pool_wt'"
  assert_grep "project=$proj" "$home/state/$id.meta" "meta project= mismatch"
  pass "T3: correct pool worktree is accepted and recorded in meta"
}

# T6: race sequence - pane would report sibling first; lease returns pool path
test_lease_not_pane_race_latches_pool_path() {
  local home proj pool_wt sibling fakebin out status id meta_wt
  id=race-lease-t6
  home="$TMP_ROOT/race-home"
  mkdir -p "$home/data"
  proj="$TMP_ROOT/race-proj"
  fm_git_init_commit "$proj"
  pool_wt="$TMP_ROOT/.treehouse/race-pool/1/repo"
  sibling="$TMP_ROOT/race-serving"
  git -C "$proj" worktree add -q --detach "$pool_wt"
  git -C "$proj" worktree add -q --detach "$sibling"
  pool_wt=$(cd "$pool_wt" && pwd)
  sibling=$(cd "$sibling" && pwd)
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/race-fake")

  # Pane path is the sibling; lease override is the pool (Layer B authority).
  out=$(run_spawn "$home" "$id" "$proj" "$sibling" "$fakebin" "$pool_wt"); status=$?
  rm -rf "/tmp/fm-$id" 2>/dev/null || true

  expect_code 0 "$status" "lease-authoritative spawn should succeed"$'\n'"$out"
  meta_wt=$(grep '^worktree=' "$home/state/$id.meta" | cut -d= -f2-)
  [ "$meta_wt" = "$pool_wt" ] \
    || fail "race latch: meta worktree='$meta_wt' expected pool '$pool_wt' (not sibling '$sibling')"
  [ "$meta_wt" != "$sibling" ] || fail "race latch: meta recorded the sibling serving path"
  pass "T6: lease path wins over sibling pane path; meta never latches the sibling"
}

# T4/T5 covered by fm-tangle-guard; re-assert isolation errors stay distinct.
test_isolation_errors_stay_distinct_from_membership() {
  local home proj fakebin out status id
  id=isol-primary-t4
  home="$TMP_ROOT/isol-home"
  mkdir -p "$home/data"
  proj="$TMP_ROOT/isol-proj"
  fm_git_init_commit "$proj"
  mkdir -p "$proj/sub"
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/isol-fake")

  out=$(run_spawn "$home" "$id" "$proj" "$proj/sub" "$fakebin"); status=$?
  rm -rf "/tmp/fm-$id" 2>/dev/null || true
  expect_code 1 "$status" "primary subdir must refuse"
  assert_contains "$out" "did not yield an isolated worktree" \
    "primary should use isolation error, not membership"
  assert_not_contains "$out" "not a linked worktree of project" \
    "primary must not be reported as membership failure"
  assert_absent "$home/state/$id.meta" "isolation refuse must not write meta"
  pass "T4: isolation failure stays distinct from membership error"
}

test_foreign_project_worktree_refused
test_same_repo_sibling_outside_pool_refused
test_correct_pool_worktree_accepted
test_lease_not_pane_race_latches_pool_path
test_isolation_errors_stay_distinct_from_membership

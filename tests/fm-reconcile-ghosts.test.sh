#!/usr/bin/env bash
# Ghost reconciliation clears dead, safe task metas, preserves unsafe work,
# and - the confirm-twice safeguard (bug-20260710152159-d3f294fa) - never
# reaps a meta on a single transient dead read.
#
# FC-001 (closed-schema positive proof): A conclusion may be drawn only from ONE atomic pass that positively proves conformance to a single declared, closed schema; authority defaults to none and is NEVER inferred from the absence of a failing check.
# FC-002 (absence is never discharge): An obligation is cleared ONLY by positive proof from a fresh, structurally-complete, authoritative snapshot that provably enumerates that obligation's status; absent/stale/corrupt/partial coverage RETAINS the prior fact unchanged (fail-open when CREATING a block, fail-closed when DISCHARGING one).
#
# The real cleanup path remains fm-teardown.sh; these tests fake only the
# runtime endpoint and treehouse return so the teardown safety logic still runs
# against real synthetic git worktrees.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-reconcile-ghosts)
RECONCILE="$ROOT/bin/fm-reconcile-ghosts.sh"

fm_git_identity "Firstmate Tests" "tests@example.invalid"

# make_fake_tooling <dir>: a fake tmux whose list-windows inventory mirrors
# fm_backend_target_exists's real tmux branch, plus an optional
# FM_FAKE_TMUX_FORCE_DEAD_CALLS knob that forces the first N two-call inventory
# probes to report dead regardless of the windows file.
make_fake_tooling() {  # <dir> -> echoes fakebin dir
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'tmux'
  for arg in "$@"; do printf '\x1f%s' "$arg"; done
  printf '\n'
} >> "$FM_FAKE_TMUX_LOG"
case "${1:-}" in
  list-windows)
    format=
    while [ $# -gt 0 ]; do
      case "$1" in
        -F) format=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    count=0
    [ -f "$FM_FAKE_TMUX_DM_CALLS" ] && count=$(cat "$FM_FAKE_TMUX_DM_CALLS")
    count=$((count + 1))
    printf '%s\n' "$count" > "$FM_FAKE_TMUX_DM_CALLS"
    if [ "$count" -le "$((FM_FAKE_TMUX_FORCE_DEAD_CALLS * 2))" ]; then
      exit 0
    fi
    case "$format" in
      '#{session_name}:#{window_name}') cat "$FM_FAKE_TMUX_WINDOWS" ;;
      '#{session_name}:#{window_index}') : ;;
      '#{window_name}') sed 's/^[^:]*://' "$FM_FAKE_TMUX_WINDOWS" ;;
      *) cat "$FM_FAKE_TMUX_WINDOWS" ;;
    esac
    exit 0
    ;;
  kill-window)
    exit 0
    ;;
  display-message)
    target=""
    prev=""
    for a in "$@"; do
      [ "$prev" = "-t" ] && target="$a"
      prev="$a"
    done
    if grep -Fxq -- "$target" "$FM_FAKE_TMUX_WINDOWS" 2>/dev/null; then
      printf '%%1\n'
      exit 0
    fi
    case "$target" in
      *:*) : ;;
      *)
        if grep -Fq -- ":$target" "$FM_FAKE_TMUX_WINDOWS" 2>/dev/null; then
          printf '%%1\n'
          exit 0
        fi
        ;;
    esac
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'cwd=%s' "$PWD"
  for arg in "$@"; do printf '\x1f%s' "$arg"; done
  printf '\n'
} >> "$FM_FAKE_TREEHOUSE_LOG"
if [ "${1:-}" = status ] && [ -n "${FM_FAKE_TREEHOUSE_STATUS:-}" ]; then
  cat "$FM_FAKE_TREEHOUSE_STATUS"
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

make_fake_root() {  # <dir> -> echoes fake firstmate root
  local root=$1
  mkdir -p "$root/bin"
  cat > "$root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$root/bin/fm-guard.sh"
  cat > "$root/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$root/bin/fm-fleet-sync.sh"
  printf '%s\n' '#!/usr/bin/env node' 'process.exit(0);' > "$root/visibility.mjs"
  printf '%s\n' "$root"
}

setup_home() {  # <dir> -> echoes home
  local home=$1
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

# The worktree is created as a treehouse POOL slot: fm-teardown only returns (and
# only detaches/branch-deletes) a worktree that is a registered worktree of the
# project AND a pool slot, so a ghost recorded outside the pool is deliberately
# left alone rather than returned.
setup_project_with_worktree() {  # <project> <worktree> <branch>
  local project=$1 worktree=$2 branch=$3
  mkdir -p "$(dirname "$worktree")"
  mkdir -p "$project"
  git -C "$project" init -q
  printf 'base\n' > "$project/file.txt"
  git -C "$project" add file.txt
  git -C "$project" commit -qm initial
  git -C "$project" branch -M main
  git -C "$project" worktree add -q -b "$branch" "$worktree" main
}

# run_reconcile <fakebin> <home> <fake-root> <windows> <tmux-log> <treehouse-log> <dm-calls> [force-dead-calls]
# FM_GHOST_SETTLE_SECS=0 keeps the suite fast; the double-read code path still
# runs, it just does not sleep for real between the two probes.
run_reconcile() {
  local fakebin=$1 home=$2 fake_root=$3 windows=$4 tmux_log=$5 treehouse_log=$6 dm_calls=$7 force_dead=${8:-0}
  local run_home=$home run_path="$fakebin:$BASE_PATH"
  if [ "${FM_TEST_HOME_OVERRIDE+x}" = x ]; then
    run_home=$FM_TEST_HOME_OVERRIDE
  fi
  if [ -n "${FM_TEST_RUN_PATH:-}" ]; then
    run_path=$FM_TEST_RUN_PATH
  fi
  (
    cd "$home" || exit 1
    env -u FM_PRIMARY_HOME -u FM_CREWMATE -u FM_TASK_ID \
      PATH="$run_path" \
      FM_HOME="$run_home" \
      FM_ROOT_OVERRIDE="$fake_root" \
      FM_STATE_OVERRIDE="${FM_TEST_STATE_OVERRIDE:-}" \
      FM_VISIBILITY_CLI="$fake_root/visibility.mjs" \
      FM_TASK_ENUM_TEST_AFTER_LIST_HOOK="${FM_TEST_ENUM_AFTER_LIST_HOOK:-}" \
      FM_GHOST_SETTLE_SECS=0 \
      FM_FAKE_TMUX_WINDOWS="$windows" \
      FM_FAKE_TMUX_LOG="$tmux_log" \
      FM_FAKE_TREEHOUSE_LOG="$treehouse_log" \
      FM_FAKE_TREEHOUSE_STATUS="${FM_FAKE_TREEHOUSE_STATUS:-}" \
      FM_FAKE_TMUX_DM_CALLS="$dm_calls" \
      FM_FAKE_TMUX_FORCE_DEAD_CALLS="$force_dead" \
      "$RECONCILE"
  )
}

assert_enumeration_failure() {  # <output> <rc> <label>
  local out=$1 rc=$2 label=$3 attention_count
  [ "$rc" -ne 0 ] || fail "$label: enumeration failure must exit nonzero"
  assert_contains "$out" "GHOST_RECONCILE: ATTENTION:" "$label: must emit a loud finding"
  assert_contains "$out" "enumeration=failed cleared=0" "$label: must emit the failed-enumeration summary"
  assert_contains "$out" "no task records were touched" "$label: must state the mutation-free result"
  assert_not_contains "$out" "no in-flight metadata found" "$label: must never false-clean"
  attention_count=$(printf '%s\n' "$out" | grep -c '^GHOST_RECONCILE: ATTENTION:')
  [ "$attention_count" -eq 1 ] || fail "$label: expected exactly one ATTENTION, got $attention_count"
}

test_landed_dead_meta_is_cleared() {
  local dir fakebin fake_root home repo wt windows tmux_log treehouse_log dm_calls out
  dir="$TMP_ROOT/landed"
  mkdir -p "$dir"
  fakebin=$(make_fake_tooling "$dir")
  fake_root=$(make_fake_root "$dir/fake-root")
  home=$(setup_home "$dir/home")
  repo="$dir/project"
  wt="$dir/.treehouse/pool/worktree"
  windows="$dir/windows"
  tmux_log="$dir/tmux.log"
  treehouse_log="$dir/treehouse.log"
  dm_calls="$dir/dm-calls"
  : > "$windows"
  : > "$tmux_log"
  : > "$treehouse_log"
  setup_project_with_worktree "$repo" "$wt" fm/landed
  printf 'landed\n' > "$wt/landed.txt"
  git -C "$wt" add landed.txt
  git -C "$wt" commit -qm landed
  git -C "$repo" merge -q --ff-only fm/landed
  fm_write_meta "$home/state/landed.meta" \
    "window=fleet:fm-landed" \
    "worktree=$wt" \
    "project=$repo" \
    "harness=echo" \
    "kind=ship" \
    "mode=local-only" \
    "yolo=off"
  touch "$home/state/landed.status" "$home/state/landed.turn-ended"

  out=$(run_reconcile "$fakebin" "$home" "$fake_root" "$windows" "$tmux_log" "$treehouse_log" "$dm_calls")

  assert_absent "$home/state/landed.meta" "landed ghost meta should be removed"
  assert_absent "$home/state/landed.status" "landed ghost status should be removed"
  assert_contains "$out" "GHOST_RECONCILE: landed torn down cleanly" "landed ghost should be reported as torn down"
  assert_grep "$wt" "$treehouse_log" "landed ghost should return the recorded worktree"
  [ "$(cat "$dm_calls")" -ge 4 ] || fail "reconciler should have confirmed the dead reading with a second probe (inventory calls: $(cat "$dm_calls"))"
  pass "ghost reconciliation clears a landed dead meta (confirmed dead on both reads) through fm-teardown"
}

test_corrupt_home_worktree_preserves_every_record_without_proof() {
  local dir fakebin fake_root home windows tmux_log treehouse_log dm_calls out record
  dir="$TMP_ROOT/corrupt-home"
  mkdir -p "$dir"
  fakebin=$(make_fake_tooling "$dir")
  fake_root=$(make_fake_root "$dir/fake-root")
  home=$(setup_home "$dir/home")
  windows="$dir/windows"
  tmux_log="$dir/tmux.log"
  treehouse_log="$dir/treehouse.log"
  dm_calls="$dir/dm-calls"
  : > "$windows"
  : > "$tmux_log"
  : > "$treehouse_log"
  touch "$home/KEEP_HOME"
  fm_write_meta "$home/state/corrupt.meta" \
    "window=fleet:fm-corrupt" \
    "worktree=$home" \
    "project=$dir/project" \
    "harness=echo" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  touch \
    "$home/state/corrupt.status" \
    "$home/state/corrupt.turn-ended" \
    "$home/state/corrupt.check.sh" \
    "$home/state/corrupt.pi-ext.ts" \
    "$home/state/corrupt.grok-turnend-token"

  out=$(run_reconcile "$fakebin" "$home" "$fake_root" "$windows" "$tmux_log" "$treehouse_log" "$dm_calls")

  for record in \
    corrupt.meta \
    corrupt.status \
    corrupt.turn-ended \
    corrupt.check.sh \
    corrupt.pi-ext.ts \
    corrupt.grok-turnend-token; do
    assert_present "$home/state/$record" \
      "corrupt-home reconciliation must preserve $record without positive landed/closed proof"
  done
  assert_present "$home/KEEP_HOME" "corrupt-home reconciliation must not remove the active home"
  [ ! -s "$treehouse_log" ] || fail "corrupt-home reconciliation called treehouse unexpectedly"
  assert_contains "$out" "GHOST_RECONCILE: ATTENTION: corrupt has corrupt worktree=$home matching FM_HOME" \
    "corrupt-home ghost should be listed loudly as its own finding"
  assert_contains "$out" "landed/closed state cannot be proven, so every task record was preserved" \
    "corrupt-home finding should state the fail-closed reason"
  assert_contains "$out" "summary cleared=0 corrupt_preserved=1 preserved=1" \
    "corrupt-home ghost should count as preserved, never cleared"
  pass "corrupt-home reconciliation performs zero deletions without positive landed/closed proof"
}

test_unreadable_state_directory_fails_loud_without_touching_records() {
  local dir fakebin fake_root home windows tmux_log treehouse_log dm_calls out rc before after attention_count
  dir="$TMP_ROOT/unreadable-state"
  mkdir -p "$dir"
  fakebin=$(make_fake_tooling "$dir")
  fake_root=$(make_fake_root "$dir/fake-root")
  home=$(setup_home "$dir/home")
  windows="$dir/windows"
  tmux_log="$dir/tmux.log"
  treehouse_log="$dir/treehouse.log"
  dm_calls="$dir/dm-calls"
  : > "$windows"
  : > "$tmux_log"
  : > "$treehouse_log"
  fm_write_meta "$home/state/unreadable.meta" \
    "window=fleet:fm-unreadable" \
    "worktree=$home" \
    "project=$dir/project" \
    "harness=echo" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  printf 'working: retained obligation\n' > "$home/state/unreadable.status"
  before=$(cksum "$home/state/unreadable.meta" "$home/state/unreadable.status")

  chmod 000 "$home/state"
  out=$(run_reconcile "$fakebin" "$home" "$fake_root" "$windows" "$tmux_log" "$treehouse_log" "$dm_calls" 2>&1)
  rc=$?
  chmod 700 "$home/state"
  after=$(cksum "$home/state/unreadable.meta" "$home/state/unreadable.status")

  [ "$rc" -ne 0 ] || fail "an unreadable state directory must make reconciliation exit nonzero"
  [ "$after" = "$before" ] || fail "an unreadable state directory must leave task records byte-identical"
  [ ! -s "$tmux_log" ] || fail "an unreadable state directory must not probe or kill a backend endpoint"
  [ ! -s "$treehouse_log" ] || fail "an unreadable state directory must not call treehouse"
  assert_contains "$out" "GHOST_RECONCILE: ATTENTION:" \
    "an unreadable state directory must emit a loud finding"
  assert_contains "$out" "cannot enumerate task metadata" \
    "the finding must identify failed enumeration"
  assert_contains "$out" "no task records were touched" \
    "the finding must state the mutation-free outcome"
  assert_not_contains "$out" "no in-flight metadata found" \
    "failed enumeration must never be reported as a provably empty fleet"
  attention_count=$(printf '%s\n' "$out" | grep -c '^GHOST_RECONCILE: ATTENTION:')
  [ "$attention_count" -eq 1 ] || fail "enumeration failure must emit exactly one ATTENTION finding, got $attention_count"
  pass "unreadable state-directory enumeration fails loud and nonzero without touching any record"
}

test_missing_non_directory_and_symlink_loop_state_fail_closed() {
  local shape dir fakebin fake_root home windows tmux_log treehouse_log dm_calls out rc
  for shape in missing non-directory symlink-loop; do
    dir="$TMP_ROOT/state-shape-$shape"
    mkdir -p "$dir"
    fakebin=$(make_fake_tooling "$dir")
    fake_root=$(make_fake_root "$dir/fake-root")
    home=$(setup_home "$dir/home")
    windows="$dir/windows"
    tmux_log="$dir/tmux.log"
    treehouse_log="$dir/treehouse.log"
    dm_calls="$dir/dm-calls"
    : > "$windows"
    : > "$tmux_log"
    : > "$treehouse_log"
    rmdir "$home/state"
    case "$shape" in
      missing) ;;
      non-directory) : > "$home/state" ;;
      symlink-loop) ln -s state "$home/state" ;;
    esac

    out=$(run_reconcile "$fakebin" "$home" "$fake_root" "$windows" "$tmux_log" "$treehouse_log" "$dm_calls" 2>&1)
    rc=$?

    assert_enumeration_failure "$out" "$rc" "$shape state path"
    [ ! -s "$tmux_log" ] || fail "$shape state path: backend tooling must not run"
    [ ! -s "$treehouse_log" ] || fail "$shape state path: treehouse must not run"
  done
  pass "missing, non-directory, and looping state paths are total enumeration failures"
}

test_empty_or_unset_home_never_false_cleans_without_an_override() {
  local dir fakebin fake_root home override windows tmux_log treehouse_log dm_calls out rc
  dir="$TMP_ROOT/empty-home"
  mkdir -p "$dir"
  fakebin=$(make_fake_tooling "$dir")
  fake_root=$(make_fake_root "$dir/fake-root")
  home=$(setup_home "$dir/home")
  override="$dir/override-state"
  mkdir -p "$override"
  windows="$dir/windows"
  tmux_log="$dir/tmux.log"
  treehouse_log="$dir/treehouse.log"
  dm_calls="$dir/dm-calls"
  : > "$windows"
  : > "$tmux_log"
  : > "$treehouse_log"

  out=$(FM_TEST_HOME_OVERRIDE='' run_reconcile \
    "$fakebin" "$home" "$fake_root" "$windows" "$tmux_log" "$treehouse_log" "$dm_calls" 2>&1)
  rc=$?
  assert_enumeration_failure "$out" "$rc" "empty home without state override"

  out=$(FM_TEST_HOME_OVERRIDE='' FM_TEST_STATE_OVERRIDE="$override" run_reconcile \
    "$fakebin" "$home" "$fake_root" "$windows" "$tmux_log" "$treehouse_log" "$dm_calls" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "an explicit readable state override must work with an empty home"
  assert_contains "$out" "no in-flight metadata found" \
    "completed zero-record override enumeration should prove emptiness"
  assert_not_contains "$out" "ATTENTION:" \
    "completed zero-record override enumeration must not report failure"
  pass "empty home fails closed unless an explicit state override yields a complete proof"
}

test_real_empty_state_is_the_only_empty_fleet_success() {
  local dir fakebin fake_root home windows tmux_log treehouse_log dm_calls out rc
  dir="$TMP_ROOT/real-empty"
  mkdir -p "$dir"
  fakebin=$(make_fake_tooling "$dir")
  fake_root=$(make_fake_root "$dir/fake-root")
  home=$(setup_home "$dir/home")
  windows="$dir/windows"
  tmux_log="$dir/tmux.log"
  treehouse_log="$dir/treehouse.log"
  dm_calls="$dir/dm-calls"
  : > "$windows"
  : > "$tmux_log"
  : > "$treehouse_log"

  out=$(run_reconcile "$fakebin" "$home" "$fake_root" "$windows" "$tmux_log" "$treehouse_log" "$dm_calls" 2>&1)
  rc=$?

  [ "$rc" -eq 0 ] || fail "a completed canonical zero-record enumeration must succeed"
  assert_contains "$out" "no in-flight metadata found" "zero-record proof should report an empty fleet"
  assert_not_contains "$out" "enumeration=failed" "zero-record proof must remain distinct from failure"
  pass "a completed canonical zero-record pass is the sole empty-fleet proof"
}

test_canary_symlink_enumerates_nonempty_target() {
  local dir fakebin fake_root home real_state windows tmux_log treehouse_log dm_calls out rc
  dir="$TMP_ROOT/canary-symlink"
  mkdir -p "$dir"
  fakebin=$(make_fake_tooling "$dir")
  fake_root=$(make_fake_root "$dir/fake-root")
  home=$(setup_home "$dir/home")
  real_state="$dir/real-state"
  mv "$home/state" "$real_state"
  ln -s "$real_state" "$home/state"
  windows="$dir/windows"
  tmux_log="$dir/tmux.log"
  treehouse_log="$dir/treehouse.log"
  dm_calls="$dir/dm-calls"
  : > "$windows"
  : > "$tmux_log"
  : > "$treehouse_log"
  fm_write_meta "$real_state/symlink-canary.meta" \
    "window=fleet:fm-symlink-canary" \
    "worktree=$home" \
    "project=$dir/project" \
    "harness=echo" \
    "kind=ship" \
    "mode=no-mistakes"
  touch "$real_state/symlink-canary.status"

  out=$(run_reconcile "$fakebin" "$home" "$fake_root" "$windows" "$tmux_log" "$treehouse_log" "$dm_calls" 2>&1)
  rc=$?

  [ "$rc" -eq 0 ] || fail "CANARY-SYMLINK: a valid top-level state symlink must be followed"
  assert_contains "$out" "ATTENTION: symlink-canary has corrupt worktree=" \
    "CANARY-SYMLINK: the target record must be enumerated and dispositioned"
  assert_not_contains "$out" "no in-flight metadata found" \
    "CANARY-SYMLINK: a nonempty symlink target must never false-clean"
  assert_present "$real_state/symlink-canary.meta" "CANARY-SYMLINK: preserved meta must remain"
  pass "CANARY-SYMLINK follows one canonical root and never reports a nonempty target as empty"
}

test_non_regular_meta_entries_fail_the_whole_pass() {
  local shape dir fakebin fake_root home windows tmux_log treehouse_log dm_calls out rc target
  for shape in symlink fifo; do
    dir="$TMP_ROOT/nonregular-$shape"
    mkdir -p "$dir"
    fakebin=$(make_fake_tooling "$dir")
    fake_root=$(make_fake_root "$dir/fake-root")
    home=$(setup_home "$dir/home")
    windows="$dir/windows"
    tmux_log="$dir/tmux.log"
    treehouse_log="$dir/treehouse.log"
    dm_calls="$dir/dm-calls"
    : > "$windows"
    : > "$tmux_log"
    : > "$treehouse_log"
    case "$shape" in
      symlink)
        target="$dir/target"
        printf 'window=fleet:fm-nonregular\n' > "$target"
        ln -s "$target" "$home/state/nonregular.meta"
        ;;
      fifo) mkfifo "$home/state/nonregular.meta" ;;
    esac

    out=$(run_reconcile "$fakebin" "$home" "$fake_root" "$windows" "$tmux_log" "$treehouse_log" "$dm_calls" 2>&1)
    rc=$?

    assert_enumeration_failure "$out" "$rc" "non-regular $shape meta"
    [ ! -s "$tmux_log" ] || fail "non-regular $shape meta: backend tooling must not run"
    [ ! -s "$treehouse_log" ] || fail "non-regular $shape meta: treehouse must not run"
    assert_present "$home/state/nonregular.meta" "non-regular $shape meta must remain"
  done
  pass "symlink and fifo metadata entries fail the complete pass without mutation"
}

test_single_unreadable_meta_fails_the_whole_pass() {
  local dir fakebin fake_root home windows tmux_log treehouse_log dm_calls out rc before after
  dir="$TMP_ROOT/unreadable-meta"
  mkdir -p "$dir"
  fakebin=$(make_fake_tooling "$dir")
  fake_root=$(make_fake_root "$dir/fake-root")
  home=$(setup_home "$dir/home")
  windows="$dir/windows"
  tmux_log="$dir/tmux.log"
  treehouse_log="$dir/treehouse.log"
  dm_calls="$dir/dm-calls"
  : > "$windows"
  : > "$tmux_log"
  : > "$treehouse_log"
  fm_write_meta "$home/state/unreadable-entry.meta" \
    "window=fleet:fm-unreadable-entry" \
    "worktree=$home" \
    "project=$dir/project"
  touch "$home/state/unreadable-entry.status"
  before=$(cksum "$home/state/unreadable-entry.meta" "$home/state/unreadable-entry.status")
  chmod 000 "$home/state/unreadable-entry.meta"

  out=$(run_reconcile "$fakebin" "$home" "$fake_root" "$windows" "$tmux_log" "$treehouse_log" "$dm_calls" 2>&1)
  rc=$?
  chmod 600 "$home/state/unreadable-entry.meta"
  after=$(cksum "$home/state/unreadable-entry.meta" "$home/state/unreadable-entry.status")

  assert_enumeration_failure "$out" "$rc" "single unreadable meta"
  [ "$after" = "$before" ] || fail "single unreadable meta: records must remain byte-identical"
  [ ! -s "$treehouse_log" ] || fail "single unreadable meta: treehouse must not run"
  pass "one unreadable metadata entry invalidates the entire snapshot"
}

test_canary_late_unreadable_blocks_earlier_eligible_cleanup() {
  local dir fakebin fake_root home repo wt windows tmux_log treehouse_log dm_calls out rc before after
  dir="$TMP_ROOT/canary-late-unreadable"
  mkdir -p "$dir"
  fakebin=$(make_fake_tooling "$dir")
  fake_root=$(make_fake_root "$dir/fake-root")
  home=$(setup_home "$dir/home")
  repo="$dir/project"
  wt="$dir/.treehouse/pool/worktree"
  windows="$dir/windows"
  tmux_log="$dir/tmux.log"
  treehouse_log="$dir/treehouse.log"
  dm_calls="$dir/dm-calls"
  : > "$windows"
  : > "$tmux_log"
  : > "$treehouse_log"
  setup_project_with_worktree "$repo" "$wt" fm/a-landed
  printf 'landed\n' > "$wt/landed.txt"
  git -C "$wt" add landed.txt
  git -C "$wt" commit -qm landed
  git -C "$repo" merge -q --ff-only fm/a-landed
  fm_write_meta "$home/state/a-landed.meta" \
    "window=fleet:fm-a-landed" \
    "worktree=$wt" \
    "project=$repo" \
    "kind=ship" \
    "mode=local-only"
  touch "$home/state/a-landed.status"
  fm_write_meta "$home/state/z-unreadable.meta" \
    "window=fleet:fm-z-unreadable" \
    "worktree=$home" \
    "project=$dir/other-project"
  touch "$home/state/z-unreadable.status"
  before=$(cksum "$home/state/a-landed.meta" "$home/state/a-landed.status" \
    "$home/state/z-unreadable.meta" "$home/state/z-unreadable.status")
  chmod 000 "$home/state/z-unreadable.meta"

  out=$(run_reconcile "$fakebin" "$home" "$fake_root" "$windows" "$tmux_log" "$treehouse_log" "$dm_calls" 2>&1)
  rc=$?
  chmod 600 "$home/state/z-unreadable.meta"
  after=$(cksum "$home/state/a-landed.meta" "$home/state/a-landed.status" \
    "$home/state/z-unreadable.meta" "$home/state/z-unreadable.status")

  assert_enumeration_failure "$out" "$rc" "CANARY-LATE-UNREADABLE"
  [ "$after" = "$before" ] || fail "CANARY-LATE-UNREADABLE: every record must remain byte-identical"
  [ ! -s "$treehouse_log" ] || fail "CANARY-LATE-UNREADABLE: eligible task must not reach teardown"
  pass "CANARY-LATE-UNREADABLE validates every entry before clearing an earlier eligible task"
}

test_entry_vanishing_after_listing_fails_before_other_cleanup() {
  local dir fakebin fake_root home repo wt windows tmux_log treehouse_log dm_calls hook out rc before after
  dir="$TMP_ROOT/vanish-after-list"
  mkdir -p "$dir"
  fakebin=$(make_fake_tooling "$dir")
  fake_root=$(make_fake_root "$dir/fake-root")
  home=$(setup_home "$dir/home")
  repo="$dir/project"
  wt="$dir/.treehouse/pool/worktree"
  windows="$dir/windows"
  tmux_log="$dir/tmux.log"
  treehouse_log="$dir/treehouse.log"
  dm_calls="$dir/dm-calls"
  hook="$dir/after-list"
  : > "$windows"
  : > "$tmux_log"
  : > "$treehouse_log"
  setup_project_with_worktree "$repo" "$wt" fm/a-eligible
  git -C "$repo" merge -q --ff-only fm/a-eligible
  fm_write_meta "$home/state/a-eligible.meta" \
    "window=fleet:fm-a-eligible" \
    "worktree=$wt" \
    "project=$repo" \
    "kind=ship" \
    "mode=local-only"
  touch "$home/state/a-eligible.status"
  fm_write_meta "$home/state/z-vanish.meta" \
    "window=fleet:fm-z-vanish" \
    "worktree=$home" \
    "project=$dir/other-project"
  before=$(cksum "$home/state/a-eligible.meta" "$home/state/a-eligible.status")
  cat > "$hook" <<'SH'
#!/usr/bin/env bash
rm -f "$1/z-vanish.meta"
SH
  chmod +x "$hook"

  out=$(FM_TEST_ENUM_AFTER_LIST_HOOK="$hook" run_reconcile \
    "$fakebin" "$home" "$fake_root" "$windows" "$tmux_log" "$treehouse_log" "$dm_calls" 2>&1)
  rc=$?
  after=$(cksum "$home/state/a-eligible.meta" "$home/state/a-eligible.status")

  assert_enumeration_failure "$out" "$rc" "vanished metadata entry"
  [ "$after" = "$before" ] || fail "vanished entry: every other record must remain byte-identical"
  [ ! -s "$treehouse_log" ] || fail "vanished entry: no other task may reach teardown"
  pass "a metadata entry vanishing between listing and read invalidates the pass before mutation"
}

test_readable_truncated_and_binary_records_are_preserved() {
  local dir fakebin fake_root home windows tmux_log treehouse_log dm_calls out rc before after
  dir="$TMP_ROOT/readable-malformed"
  mkdir -p "$dir"
  fakebin=$(make_fake_tooling "$dir")
  fake_root=$(make_fake_root "$dir/fake-root")
  home=$(setup_home "$dir/home")
  windows="$dir/windows"
  tmux_log="$dir/tmux.log"
  treehouse_log="$dir/treehouse.log"
  dm_calls="$dir/dm-calls"
  : > "$windows"
  : > "$tmux_log"
  : > "$treehouse_log"
  printf 'window=fleet:fm-readable-malformed\nworktree=%s\n\000garbage\n' "$home" \
    > "$home/state/readable-malformed.meta"
  printf '\000\377retained-status\n' > "$home/state/readable-malformed.status"
  before=$(cksum "$home/state/readable-malformed.meta" "$home/state/readable-malformed.status")

  out=$(run_reconcile "$fakebin" "$home" "$fake_root" "$windows" "$tmux_log" "$treehouse_log" "$dm_calls" 2>&1)
  rc=$?
  after=$(cksum "$home/state/readable-malformed.meta" "$home/state/readable-malformed.status")

  [ "$rc" -eq 0 ] || fail "readable malformed metadata should reach conservative disposition"
  [ "$after" = "$before" ] || fail "readable malformed metadata/status must remain byte-identical"
  assert_contains "$out" "ATTENTION: readable-malformed has corrupt worktree=" \
    "readable malformed metadata must be preserved visibly"
  [ ! -s "$treehouse_log" ] || fail "readable malformed corrupt-home record must not call teardown"
  pass "readable truncated/binary records are parsed as unproven and preserved with ATTENTION"
}

test_unlanded_dead_meta_is_preserved() {
  local dir fakebin fake_root home repo wt windows tmux_log treehouse_log dm_calls out
  dir="$TMP_ROOT/unlanded"
  mkdir -p "$dir"
  fakebin=$(make_fake_tooling "$dir")
  fake_root=$(make_fake_root "$dir/fake-root")
  home=$(setup_home "$dir/home")
  repo="$dir/project"
  wt="$dir/.treehouse/pool/worktree"
  windows="$dir/windows"
  tmux_log="$dir/tmux.log"
  treehouse_log="$dir/treehouse.log"
  dm_calls="$dir/dm-calls"
  : > "$windows"
  : > "$tmux_log"
  : > "$treehouse_log"
  setup_project_with_worktree "$repo" "$wt" fm/unlanded
  printf 'unlanded\n' > "$wt/unlanded.txt"
  git -C "$wt" add unlanded.txt
  git -C "$wt" commit -qm unlanded
  fm_write_meta "$home/state/unlanded.meta" \
    "window=fleet:fm-unlanded" \
    "worktree=$wt" \
    "project=$repo" \
    "harness=echo" \
    "kind=ship" \
    "mode=local-only" \
    "yolo=off"
  touch "$home/state/unlanded.status"

  out=$(run_reconcile "$fakebin" "$home" "$fake_root" "$windows" "$tmux_log" "$treehouse_log" "$dm_calls")

  assert_present "$home/state/unlanded.meta" "unlanded ghost meta should be preserved"
  assert_present "$home/state/unlanded.status" "unlanded ghost status should be preserved"
  assert_contains "$out" "GHOST_RECONCILE: ATTENTION: unlanded endpoint is dead but teardown refused or failed" "unlanded ghost should be surfaced loudly"
  assert_contains "$out" "REFUSED: no positive landed proof" "teardown's fail-closed reason should be included in reconcile output"
  assert_not_contains "$(cat "$treehouse_log")" $'\x1freturn\x1f' "unlanded ghost should not return the worktree"
  pass "ghost reconciliation preserves and surfaces a CONFIRMED dead meta with unlanded work (fm-teardown.sh's independent safety layer)"
}

test_landed_meta_in_recycled_slot_is_cleared_without_touching_new_holder() {
  local dir fakebin fake_root home repo wt windows tmux_log treehouse_log dm_calls status out occupant_head
  dir="$TMP_ROOT/recycled"
  mkdir -p "$dir"
  fakebin=$(make_fake_tooling "$dir")
  fake_root=$(make_fake_root "$dir/fake-root")
  home=$(setup_home "$dir/home")
  repo="$dir/project"
  wt="$dir/.treehouse/pool/worktree"
  windows="$dir/windows"
  tmux_log="$dir/tmux.log"
  treehouse_log="$dir/treehouse.log"
  dm_calls="$dir/dm-calls"
  status="$dir/treehouse-status"
  : > "$windows"
  : > "$tmux_log"
  : > "$treehouse_log"
  setup_project_with_worktree "$repo" "$wt" fm/recycled
  printf 'landed\n' > "$wt/landed.txt"
  git -C "$wt" add landed.txt
  git -C "$wt" commit -qm landed
  git -C "$repo" merge -q --ff-only fm/recycled

  # Recycle the same pool residency to another task with unrelated work.
  git -C "$wt" checkout -qb fm/occupant main
  printf 'occupant\n' > "$wt/occupant.txt"
  git -C "$wt" add occupant.txt
  git -C "$wt" commit -qm occupant
  occupant_head=$(git -C "$wt" rev-parse HEAD)
  printf '1 leased %s (held by fm-occupant)\n' "$wt" > "$status"

  fm_write_meta "$home/state/recycled.meta" \
    "window=fleet:fm-recycled" \
    "worktree=$wt" \
    "project=$repo" \
    "harness=echo" \
    "kind=ship" \
    "mode=local-only" \
    "yolo=off"
  touch "$home/state/recycled.status"

  out=$(FM_FAKE_TREEHOUSE_STATUS="$status" run_reconcile \
    "$fakebin" "$home" "$fake_root" "$windows" "$tmux_log" "$treehouse_log" "$dm_calls")

  assert_absent "$home/state/recycled.meta" "landed recycled ghost meta should be removed"
  assert_absent "$home/state/recycled.status" "landed recycled ghost status should be removed"
  assert_contains "$out" "GHOST_RECONCILE: recycled torn down cleanly" "recycled ghost should close end-to-end"
  assert_not_contains "$(cat "$treehouse_log")" $'\x1freturn\x1f' "recycled slot must not be returned under the stale task"
  [ "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" = "fm/occupant" ] \
    || fail "recycled slot's new branch was changed"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$occupant_head" ] \
    || fail "recycled slot's new commit was changed"
  pass "landed task in a recycled slot clears end-to-end without touching the new holder"
}

test_valid_terminal_proof_clears_when_task_branch_is_already_gone() {
  local dir fakebin fake_root home repo wt windows tmux_log treehouse_log dm_calls status out sha
  dir="$TMP_ROOT/terminal-proof"
  mkdir -p "$dir"
  fakebin=$(make_fake_tooling "$dir")
  fake_root=$(make_fake_root "$dir/fake-root")
  home=$(setup_home "$dir/home")
  repo="$dir/project"
  wt="$dir/.treehouse/pool/worktree"
  windows="$dir/windows"
  tmux_log="$dir/tmux.log"
  treehouse_log="$dir/treehouse.log"
  dm_calls="$dir/dm-calls"
  status="$dir/treehouse-status"
  : > "$windows"
  : > "$tmux_log"
  : > "$treehouse_log"
  setup_project_with_worktree "$repo" "$wt" fm/occupant
  sha=$(git -C "$repo" rev-parse main)
  printf '1 leased %s (held by fm-occupant)\n' "$wt" > "$status"
  {
    jq -nc --arg sha "$sha" '{
      schema:"fleet-bridge/task-event/v1",home:"home",id:"terminal-proof",
      event:"closure_evidence",branch:"fm/terminal-proof",mode:"local-only",
      outcome:"landed before cleanup",sha:$sha
    }'
    jq -nc '{
      schema:"fleet-bridge/task-event/v1",home:"home",id:"terminal-proof",
      event:"closed",disposition:"landed",outcome:"landed before cleanup",
      closed_at:"2026-07-25T00:00:00Z"
    }'
  } > "$home/state/task-lifecycle.jsonl"
  fm_write_meta "$home/state/terminal-proof.meta" \
    "window=fleet:fm-terminal-proof" \
    "worktree=$wt" \
    "project=$repo" \
    "harness=echo" \
    "kind=ship" \
    "mode=local-only" \
    "yolo=off"
  touch "$home/state/terminal-proof.status"

  out=$(FM_FAKE_TREEHOUSE_STATUS="$status" run_reconcile \
    "$fakebin" "$home" "$fake_root" "$windows" "$tmux_log" "$treehouse_log" "$dm_calls")

  assert_absent "$home/state/terminal-proof.meta" "valid terminal proof should clear meta"
  assert_absent "$home/state/terminal-proof.status" "valid terminal proof should clear status"
  assert_contains "$out" "GHOST_RECONCILE: terminal-proof torn down cleanly" \
    "valid terminal proof should recover cleanup after branch pruning"
  assert_not_contains "$(cat "$treehouse_log")" $'\x1freturn\x1f' \
    "terminal recovery must not return the recycled occupant's slot"
  pass "a complete durable landed/closed proof clears lingering volatile state after the task branch is gone"
}

test_complete_mixed_snapshot_dispositions_every_record() {
  local dir fakebin fake_root home landed_repo landed_wt unlanded_repo unlanded_wt
  local windows tmux_log treehouse_log dm_calls out
  dir="$TMP_ROOT/mixed-proof-store"
  mkdir -p "$dir"
  fakebin=$(make_fake_tooling "$dir")
  fake_root=$(make_fake_root "$dir/fake-root")
  home=$(setup_home "$dir/home")
  landed_repo="$dir/landed-project"
  landed_wt="$dir/landed/.treehouse/pool/worktree"
  unlanded_repo="$dir/unlanded-project"
  unlanded_wt="$dir/unlanded/.treehouse/pool/worktree"
  windows="$dir/windows"
  tmux_log="$dir/tmux.log"
  treehouse_log="$dir/treehouse.log"
  dm_calls="$dir/dm-calls"
  : > "$windows"
  : > "$tmux_log"
  : > "$treehouse_log"

  setup_project_with_worktree "$landed_repo" "$landed_wt" fm/mixed-landed
  printf 'landed\n' > "$landed_wt/landed.txt"
  git -C "$landed_wt" add landed.txt
  git -C "$landed_wt" commit -qm landed
  git -C "$landed_repo" merge -q --ff-only fm/mixed-landed
  fm_write_meta "$home/state/mixed-landed.meta" \
    "window=fleet:fm-mixed-landed" \
    "worktree=$landed_wt" \
    "project=$landed_repo" \
    "kind=ship" \
    "mode=local-only"
  touch "$home/state/mixed-landed.status"

  setup_project_with_worktree "$unlanded_repo" "$unlanded_wt" fm/mixed-unlanded
  printf 'unlanded\n' > "$unlanded_wt/unlanded.txt"
  git -C "$unlanded_wt" add unlanded.txt
  git -C "$unlanded_wt" commit -qm unlanded
  fm_write_meta "$home/state/mixed-unlanded.meta" \
    "window=fleet:fm-mixed-unlanded" \
    "worktree=$unlanded_wt" \
    "project=$unlanded_repo" \
    "kind=ship" \
    "mode=local-only"
  touch "$home/state/mixed-unlanded.status"

  out=$(run_reconcile "$fakebin" "$home" "$fake_root" "$windows" "$tmux_log" "$treehouse_log" "$dm_calls")

  assert_absent "$home/state/mixed-landed.meta" "mixed snapshot should clear its positively landed record"
  assert_absent "$home/state/mixed-landed.status" "mixed snapshot should clear landed volatile status"
  assert_present "$home/state/mixed-unlanded.meta" "mixed snapshot must preserve its unlanded record"
  assert_present "$home/state/mixed-unlanded.status" "mixed snapshot must preserve unlanded status"
  assert_contains "$out" "GHOST_RECONCILE: mixed-landed torn down cleanly" \
    "mixed snapshot should disposition the landed record"
  assert_contains "$out" "ATTENTION: mixed-unlanded endpoint is dead but teardown refused or failed" \
    "mixed snapshot should surface the preserved record"
  assert_contains "$out" "summary cleared=1 corrupt_preserved=0 preserved=1" \
    "mixed snapshot should attest both dispositions"
  pass "one complete multi-record proof supports mixed clear and preserve dispositions"
}

# --- confirm-twice safeguard (bug-20260710152159-d3f294fa) ------------------

test_transient_dead_read_is_not_reaped() {
  local dir fakebin fake_root home repo wt windows tmux_log treehouse_log dm_calls out
  dir="$TMP_ROOT/transient-miss"
  mkdir -p "$dir"
  fakebin=$(make_fake_tooling "$dir")
  fake_root=$(make_fake_root "$dir/fake-root")
  home=$(setup_home "$dir/home")
  repo="$dir/project"
  wt="$dir/worktree"
  windows="$dir/windows"
  tmux_log="$dir/tmux.log"
  treehouse_log="$dir/treehouse.log"
  dm_calls="$dir/dm-calls"
  # The crew's window IS genuinely alive (present in the live-windows list),
  # matching the real incident: engine-room-p0 was actively working the whole
  # time. FORCE_DEAD_CALLS=1 makes only the FIRST inventory probe report
  # dead - reproducing the transient miss a grouped-session rebuild caused -
  # while every probe after that reads the true, live state.
  printf 'fleet:fm-engine-room\n' > "$windows"
  : > "$tmux_log"
  : > "$treehouse_log"
  setup_project_with_worktree "$repo" "$wt" fm/engine-room
  fm_write_meta "$home/state/engine-room.meta" \
    "window=fleet:fm-engine-room" \
    "worktree=$wt" \
    "project=$repo" \
    "harness=echo" \
    "kind=ship" \
    "mode=local-only" \
    "yolo=off"
  touch "$home/state/engine-room.status"

  out=$(run_reconcile "$fakebin" "$home" "$fake_root" "$windows" "$tmux_log" "$treehouse_log" "$dm_calls" 1)

  assert_present "$home/state/engine-room.meta" "a crew that resolves alive on the confirming recheck must NOT be reaped"
  assert_present "$home/state/engine-room.status" "a crew that resolves alive on the confirming recheck must keep its status log"
  assert_contains "$out" "GHOST_RECONCILE: engine-room read dead once but resolved alive on recheck" "the transient-miss recovery must be reported"
  [ ! -s "$treehouse_log" ] || fail "a transient single-probe miss must never call teardown/treehouse at all"
  [ "$(cat "$dm_calls")" -ge 4 ] || fail "reconciler should have re-probed after the first dead read (inventory calls: $(cat "$dm_calls"))"
  pass "ghost reconciliation never reaps a crew on a single transient dead read - it must resolve alive twice-checked, not once"
}

test_missing_tmux_probe_fails_once_without_reaping_any_live_record() {
  local dir fakebin fake_root home windows tmux_log treehouse_log dm_calls
  local tool tool_path out rc before after
  dir="$TMP_ROOT/missing-tmux-probe"
  mkdir -p "$dir"
  fakebin=$(make_fake_tooling "$dir")
  rm -f "$fakebin/tmux"
  for tool in bash cat dirname find grep mktemp mv rm sed sleep stat uname; do
    tool_path=$(command -v "$tool") || fail "test prerequisite unavailable: $tool"
    ln -s "$tool_path" "$fakebin/$tool"
  done
  [ ! -e "$fakebin/tmux" ] || fail "missing-tmux fixture accidentally retained tmux"

  fake_root=$(make_fake_root "$dir/fake-root")
  home=$(setup_home "$dir/home")
  windows="$dir/windows"
  tmux_log="$dir/tmux.log"
  treehouse_log="$dir/treehouse.log"
  dm_calls="$dir/dm-calls"
  : > "$windows"
  : > "$tmux_log"
  : > "$treehouse_log"
  fm_write_meta "$home/state/alpha.meta" \
    "window=fleet:fm-alpha" \
    "worktree=$dir/alpha-worktree" \
    "project=$dir/alpha-project" \
    "harness=echo" \
    "kind=ship" \
    "mode=local-only"
  fm_write_meta "$home/state/bravo.meta" \
    "window=fleet:fm-bravo" \
    "worktree=$dir/bravo-worktree" \
    "project=$dir/bravo-project" \
    "harness=echo" \
    "kind=ship" \
    "mode=local-only"
  printf 'working: alpha is live\n' > "$home/state/alpha.status"
  printf 'working: bravo is live\n' > "$home/state/bravo.status"
  before=$(cksum "$home/state/alpha.meta" "$home/state/alpha.status" \
    "$home/state/bravo.meta" "$home/state/bravo.status")

  out=$(FM_TEST_RUN_PATH="$fakebin" run_reconcile \
    "$fakebin" "$home" "$fake_root" "$windows" "$tmux_log" \
    "$treehouse_log" "$dm_calls" 2>&1)
  rc=$?
  after=$(cksum "$home/state/alpha.meta" "$home/state/alpha.status" \
    "$home/state/bravo.meta" "$home/state/bravo.status")

  assert_enumeration_failure "$out" "$rc" "missing tmux probe"
  assert_contains "$out" "required tmux probe is unavailable" \
    "missing tmux probe must identify the unavailable authority"
  [ "$after" = "$before" ] ||
    fail "missing tmux probe changed live task records instead of retaining them byte-identically"
  [ ! -s "$treehouse_log" ] ||
    fail "missing tmux probe entered teardown instead of stopping before every mutation"
  pass "FC-002/FC-004: a missing tmux probe emits one failure and reaps zero live tasks"
}

test_landed_dead_meta_is_cleared
test_corrupt_home_worktree_preserves_every_record_without_proof
test_unreadable_state_directory_fails_loud_without_touching_records
test_missing_non_directory_and_symlink_loop_state_fail_closed
test_empty_or_unset_home_never_false_cleans_without_an_override
test_real_empty_state_is_the_only_empty_fleet_success
test_canary_symlink_enumerates_nonempty_target
test_non_regular_meta_entries_fail_the_whole_pass
test_single_unreadable_meta_fails_the_whole_pass
test_canary_late_unreadable_blocks_earlier_eligible_cleanup
test_entry_vanishing_after_listing_fails_before_other_cleanup
test_readable_truncated_and_binary_records_are_preserved
test_unlanded_dead_meta_is_preserved
test_landed_meta_in_recycled_slot_is_cleared_without_touching_new_holder
test_valid_terminal_proof_clears_when_task_branch_is_already_gone
test_complete_mixed_snapshot_dispositions_every_record
test_transient_dead_read_is_not_reaped
test_missing_tmux_probe_fails_once_without_reaping_any_live_record

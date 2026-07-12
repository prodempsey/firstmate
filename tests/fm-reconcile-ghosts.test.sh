#!/usr/bin/env bash
# Ghost reconciliation clears dead, safe task metas, preserves unsafe work,
# and - the confirm-twice safeguard (bug-20260710152159-d3f294fa) - never
# reaps a meta on a single transient dead read.
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
  env PATH="$fakebin:$BASE_PATH" \
    FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$fake_root" \
    FM_GHOST_SETTLE_SECS=0 \
    FM_FAKE_TMUX_WINDOWS="$windows" \
    FM_FAKE_TMUX_LOG="$tmux_log" \
    FM_FAKE_TREEHOUSE_LOG="$treehouse_log" \
    FM_FAKE_TMUX_DM_CALLS="$dm_calls" \
    FM_FAKE_TMUX_FORCE_DEAD_CALLS="$force_dead" \
    "$RECONCILE"
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
  setup_project_with_worktree "$repo" "$wt" fm-landed
  printf 'landed\n' > "$wt/landed.txt"
  git -C "$wt" add landed.txt
  git -C "$wt" commit -qm landed
  git -C "$repo" merge -q --ff-only fm-landed
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

test_corrupt_home_worktree_clears_state_only() {
  local dir fakebin fake_root home windows tmux_log treehouse_log dm_calls out
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
  touch "$home/state/corrupt.status" "$home/state/corrupt.check.sh"

  out=$(run_reconcile "$fakebin" "$home" "$fake_root" "$windows" "$tmux_log" "$treehouse_log" "$dm_calls")

  assert_absent "$home/state/corrupt.meta" "corrupt-home ghost meta should be removed"
  assert_absent "$home/state/corrupt.status" "corrupt-home ghost status should be removed"
  assert_present "$home/KEEP_HOME" "corrupt-home reconciliation must not remove the active home"
  [ ! -s "$treehouse_log" ] || fail "corrupt-home reconciliation called treehouse unexpectedly"
  assert_contains "$out" "cleared corrupt-home ghost state only" "corrupt-home ghost should report state-only cleanup"
  pass "ghost reconciliation never returns or removes a worktree path that is the active home"
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
  setup_project_with_worktree "$repo" "$wt" fm-unlanded
  printf 'dirty\n' > "$wt/dirty.txt"
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
  assert_contains "$out" "REFUSED: local-only worktree" "teardown refusal should be included in reconcile output"
  [ ! -s "$treehouse_log" ] || fail "unlanded ghost should not return the worktree"
  pass "ghost reconciliation preserves and surfaces a CONFIRMED dead meta with unlanded work (fm-teardown.sh's independent safety layer)"
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
  setup_project_with_worktree "$repo" "$wt" fm-engine-room
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

test_landed_dead_meta_is_cleared
test_corrupt_home_worktree_clears_state_only
test_unlanded_dead_meta_is_preserved
test_transient_dead_read_is_not_reaped

#!/usr/bin/env bash
# Ghost reconciliation clears dead, safe task metas and preserves unsafe work.
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
    case "$format" in
      '#{window_name}') sed 's/^[^:]*://' "$FM_FAKE_TMUX_WINDOWS" ;;
      *) cat "$FM_FAKE_TMUX_WINDOWS" ;;
    esac
    exit 0
    ;;
  kill-window)
    exit 0
    ;;
  display-message)
    printf '%%1\n'
    exit 0
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

setup_project_with_worktree() {  # <project> <worktree> <branch>
  local project=$1 worktree=$2 branch=$3
  mkdir -p "$project"
  git -C "$project" init -q
  printf 'base\n' > "$project/file.txt"
  git -C "$project" add file.txt
  git -C "$project" commit -qm initial
  git -C "$project" branch -M main
  git -C "$project" worktree add -q -b "$branch" "$worktree" main
}

run_reconcile() {  # <fakebin> <home> <fake-root> <tmux-windows> <tmux-log> <treehouse-log>
  local fakebin=$1 home=$2 fake_root=$3 windows=$4 tmux_log=$5 treehouse_log=$6
  env PATH="$fakebin:$BASE_PATH" \
    FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$fake_root" \
    FM_FAKE_TMUX_WINDOWS="$windows" \
    FM_FAKE_TMUX_LOG="$tmux_log" \
    FM_FAKE_TREEHOUSE_LOG="$treehouse_log" \
    "$RECONCILE"
}

test_landed_dead_meta_is_cleared() {
  local dir fakebin fake_root home repo wt windows tmux_log treehouse_log out
  dir="$TMP_ROOT/landed"
  mkdir -p "$dir"
  fakebin=$(make_fake_tooling "$dir")
  fake_root=$(make_fake_root "$dir/fake-root")
  home=$(setup_home "$dir/home")
  repo="$dir/project"
  wt="$dir/worktree"
  windows="$dir/windows"
  tmux_log="$dir/tmux.log"
  treehouse_log="$dir/treehouse.log"
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

  out=$(run_reconcile "$fakebin" "$home" "$fake_root" "$windows" "$tmux_log" "$treehouse_log")

  assert_absent "$home/state/landed.meta" "landed ghost meta should be removed"
  assert_absent "$home/state/landed.status" "landed ghost status should be removed"
  assert_contains "$out" "GHOST_RECONCILE: landed torn down cleanly" "landed ghost should be reported as torn down"
  assert_grep "$wt" "$treehouse_log" "landed ghost should return the recorded worktree"
  pass "ghost reconciliation clears a landed dead meta through fm-teardown"
}

test_corrupt_home_worktree_clears_state_only() {
  local dir fakebin fake_root home windows tmux_log treehouse_log out
  dir="$TMP_ROOT/corrupt-home"
  mkdir -p "$dir"
  fakebin=$(make_fake_tooling "$dir")
  fake_root=$(make_fake_root "$dir/fake-root")
  home=$(setup_home "$dir/home")
  windows="$dir/windows"
  tmux_log="$dir/tmux.log"
  treehouse_log="$dir/treehouse.log"
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

  out=$(run_reconcile "$fakebin" "$home" "$fake_root" "$windows" "$tmux_log" "$treehouse_log")

  assert_absent "$home/state/corrupt.meta" "corrupt-home ghost meta should be removed"
  assert_absent "$home/state/corrupt.status" "corrupt-home ghost status should be removed"
  assert_present "$home/KEEP_HOME" "corrupt-home reconciliation must not remove the active home"
  [ ! -s "$treehouse_log" ] || fail "corrupt-home reconciliation called treehouse unexpectedly"
  assert_contains "$out" "cleared corrupt-home ghost state only" "corrupt-home ghost should report state-only cleanup"
  pass "ghost reconciliation never returns or removes a worktree path that is the active home"
}

test_unlanded_dead_meta_is_preserved() {
  local dir fakebin fake_root home repo wt windows tmux_log treehouse_log out
  dir="$TMP_ROOT/unlanded"
  mkdir -p "$dir"
  fakebin=$(make_fake_tooling "$dir")
  fake_root=$(make_fake_root "$dir/fake-root")
  home=$(setup_home "$dir/home")
  repo="$dir/project"
  wt="$dir/worktree"
  windows="$dir/windows"
  tmux_log="$dir/tmux.log"
  treehouse_log="$dir/treehouse.log"
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

  out=$(run_reconcile "$fakebin" "$home" "$fake_root" "$windows" "$tmux_log" "$treehouse_log")

  assert_present "$home/state/unlanded.meta" "unlanded ghost meta should be preserved"
  assert_present "$home/state/unlanded.status" "unlanded ghost status should be preserved"
  assert_contains "$out" "GHOST_RECONCILE: ATTENTION: unlanded endpoint is dead but teardown refused or failed" "unlanded ghost should be surfaced loudly"
  assert_contains "$out" "REFUSED: local-only worktree" "teardown refusal should be included in reconcile output"
  [ ! -s "$treehouse_log" ] || fail "unlanded ghost should not return the worktree"
  pass "ghost reconciliation preserves and surfaces dead metas with unlanded work"
}

test_landed_dead_meta_is_cleared
test_corrupt_home_worktree_clears_state_only
test_unlanded_dead_meta_is_preserved

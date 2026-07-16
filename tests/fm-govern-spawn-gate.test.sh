#!/usr/bin/env bash
# Integration - the fm-spawn governance dispatch gate. Proves the historical
# contradictory PR-1 brief fails BEFORE a crew is launched, a held task cannot
# dispatch, a clean governed task launches and gets a durable record, and an
# ungoverned task's dispatch path is unchanged (no governance side effects).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HOLD="$ROOT/bin/fm-hold.sh"
TMP_ROOT=$(fm_test_tmproot fm-govern-spawn-gate)
export FM_GOV_NOW=2026-07-15T00:00:00Z

make_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|select-window|set-option|rename-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do [ "$prev" = "-l" ] && printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"; prev=$a; done
    fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ]; then printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0; fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# Build one isolated case: home, project, real worktree, fakebin, brief, decl.
make_case() {  # <name> <id> ; echoes "home|proj|wt|fakebin|launchlog|id"
  local name=$1 id=$2 dir home proj wt fakebin launchlog
  dir="$TMP_ROOT/$name"
  home="$dir/home"; proj="$dir/project"; wt="$dir/.treehouse/1/wt"
  launchlog="$dir/launch.log"
  fakebin=$(make_fakebin "$dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$dir|$home|$proj|$wt|$fakebin|$launchlog|$id"
}

run_spawn() {  # <home> <proj> <wt> <fakebin> <launchlog> <id> [extra fm-spawn args...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 launchlog=$5 id=$6; shift 6
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" \
    TMUX="fake,1,0" FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" "$@" 2>&1
}

# Regression 1 (at dispatch): the contradictory PR-1 brief fails before a crew launches.
test_contradiction_refused_before_launch() {
  local rec dir home proj wt fakebin launchlog id out status
  rec=$(make_case contradiction pr1-fix-x1)
  IFS='|' read -r dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  printf 'Implement the registry fix.\npush/update PR #592.\nlocal-only: no remote/PR.\n' > "$home/data/$id/brief.md"
  printf 'mode=local-only\n' > "$home/data/$id/governance.decl"

  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id")
  status=$?
  expect_code 1 "$status" "the contradictory governed spawn must be refused"
  assert_contains "$out" "governance gate REFUSED" "must report the governance refusal"
  assert_absent "$home/state/$id.meta" "no meta may be written when the gate refuses"
  [ ! -s "$launchlog" ] || fail "no crew may be launched when the gate refuses (launch.log not empty)"
  pass "the contradictory PR-1 local-only/push-PR brief fails before a crew is launched"
}

# Regression 15 (at dispatch): a held task cannot dispatch.
test_held_task_cannot_dispatch() {
  local rec dir home proj wt fakebin launchlog id out status
  rec=$(make_case held memory-pr2-build-z2)
  IFS='|' read -r dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  printf 'Implement the PR-2 slice in branch fm/%s.\n' "$id" > "$home/data/$id/brief.md"
  printf 'mode=local-only\nmilestone=memory-pr2\n' > "$home/data/$id/governance.decl"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$HOLD" add --kind milestone --value memory-pr2 --reason "PR-2 held" >/dev/null

  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id")
  status=$?
  expect_code 1 "$status" "a held task must be refused at dispatch"
  assert_contains "$out" "durable hold blocks this work" "must report the hold refusal"
  assert_absent "$home/state/$id.meta" "no meta may be written when a hold blocks dispatch"
  pass "a held (PR-2) task cannot dispatch"
}

# A clean governed task launches and gets a durable exact-SHA record.
test_clean_governed_task_launches_with_record() {
  local rec dir home proj wt fakebin launchlog id out status
  rec=$(make_case clean-governed mem-clean-z3)
  IFS='|' read -r dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  printf 'Implement the fix in branch fm/%s and stop for local review.\n' "$id" > "$home/data/$id/brief.md"
  printf 'mode=local-only\nscope=memory/\n' > "$home/data/$id/governance.decl"

  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id")
  status=$?
  expect_code 0 "$status" "a clean governed task must launch"
  assert_contains "$out" "spawned $id" "spawn must report success"
  assert_present "$home/state/$id.meta" "meta must be written for a launched governed task"
  assert_present "$home/state/$id.governance.json" "a governed task must get a durable governance record"
  assert_grep '"governed": true' "$home/state/$id.governance.json" "the record must mark the task governed"
  assert_grep '"deliveryMode": "local-only"' "$home/state/$id.governance.json" "the record must carry the delivery mode"
  pass "a clean governed task launches and gets a durable exact-SHA record"
}

# An ungoverned task (no decl) dispatches exactly as before - no governance side effects.
test_ungoverned_task_unchanged() {
  local rec dir home proj wt fakebin launchlog id out status
  rec=$(make_case ungoverned plain-task-z4)
  IFS='|' read -r dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  printf 'Do the ordinary change in branch fm/%s.\n' "$id" > "$home/data/$id/brief.md"
  # No governance.decl -> ungoverned path.

  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id")
  status=$?
  expect_code 0 "$status" "an ungoverned task must dispatch normally"
  assert_contains "$out" "spawned $id" "spawn must report success"
  assert_present "$home/state/$id.meta" "meta must be written normally"
  assert_absent "$home/state/$id.governance.json" "an ungoverned task must NOT get a governance record"
  pass "an ungoverned task's dispatch path is unchanged (no governance side effects)"
}

test_contradiction_refused_before_launch
test_held_task_cannot_dispatch
test_clean_governed_task_launches_with_record
test_ungoverned_task_unchanged

pass "fm-govern-spawn-gate: all dispatch-gate integration cases passed"

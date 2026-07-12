#!/usr/bin/env bash
# Behavior tests for the gemini crew harness adapter: env-marker detection in
# fm-harness.sh and the --yolo launch template in fm-spawn.sh. gemini has no
# turn-end hook (see the harness-adapters skill), so unlike fm-grok-harness.test.sh
# there is no hook-install/teardown coverage here - the launch template and
# detection layer are the only gemini-specific mechanics fm-spawn.sh owns.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-gemini-harness)

test_gemini_detect_own_env_marker() {
  local got
  got=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT GEMINI_CLI=1 "$ROOT/bin/fm-harness.sh")
  [ "$got" = gemini ] || fail "fm-harness.sh did not detect gemini via GEMINI_CLI=1 (got '$got')"
  pass "fm-harness.sh detects gemini from the GEMINI_CLI=1 env marker"
}

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
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  # fm-spawn leases the worktree via `treehouse get --lease`, whose stdout is the
  # leased path. Echo the pool worktree the case advertises via FM_FAKE_PANE_PATH.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ]; then
  printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

test_gemini_spawn_uses_yolo_launch_template() {
  local case_dir home proj wt fakebin launchlog id out status launch
  case_dir="$TMP_ROOT/spawn"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/.treehouse/pool/1/wt"
  launchlog="$case_dir/launch.log"
  id=gemini-spawn-z1
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  mkdir -p "$case_dir/.treehouse/pool/1"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  : > "$launchlog"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" gemini --model gemini-2.5-pro --effort high 2>&1)
  status=$?
  expect_code 0 "$status" "gemini spawn should succeed"
  assert_contains "$out" "spawned $id harness=gemini" "spawn did not report harness=gemini"
  assert_grep "harness=gemini" "$home/state/$id.meta" "meta missing harness=gemini"
  assert_grep "model=gemini-2.5-pro" "$home/state/$id.meta" "meta missing requested model"
  assert_grep "effort=high" "$home/state/$id.meta" "meta did not record requested effort for traceability"

  launch=$(cat "$launchlog")
  assert_contains "$launch" "gemini --yolo --model 'gemini-2.5-pro'" "gemini launch did not thread --yolo and --model"
  assert_not_contains "$launch" "--effort" "gemini launch must never emit an effort flag (none verified)"
  assert_not_contains "$launch" "reasoning-effort" "gemini launch must never emit an effort flag (none verified)"
  pass "gemini spawn uses the --yolo launch template, threads --model, and never emits an effort flag"
}

test_gemini_detect_own_env_marker
test_gemini_spawn_uses_yolo_launch_template

#!/usr/bin/env bash
# fm-peek fail-closed home contract (bughunt-fm-h2 finding 6).
#
# fm-peek resolves a bare task-id / legacy fm-<id> selector against THIS home's
# state/<id>.meta, exactly like fm-send. Without an explicit FM_HOME it used to
# fall back to the script's own repo root and resolve the selector against the
# WRONG home's state (or the legacy tmux inventory), reading the wrong endpoint,
# while fm-send refused. These tests pin the mirrored contract: a home-scoped
# selector requires a non-empty, existing FM_HOME with a state dir, and a fully-
# qualified explicit backend target (contains ':') stays the escape hatch that
# needs no home resolution.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PEEK="$ROOT/bin/fm-peek.sh"
TMP_ROOT=$(fm_test_tmproot fm-peek-strict)

make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  capture-pane)
    printf 'PANE CONTENT for %s\n' "${FM_FAKE_PEEK_TAG:-x}"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

setup_home() {  # <name> -> echoes home dir
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$home"
}

# --- unset FM_HOME with a home-scoped selector must fail closed ---------------
test_unset_fm_home_with_task_id_fails() {
  local dir fb err rc
  dir="$TMP_ROOT/nohome"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); err="$dir/peek.err"

  env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" \
    "$PEEK" some-task-id >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unset FM_HOME with a task-id selector should fail"
  assert_contains "$(cat "$err")" "FM_HOME is not set" "unset FM_HOME diagnostic should be explicit"
  pass "fm-peek strict: a task-id selector with unset FM_HOME fails before resolving"
}

# --- FM_HOME pointing at a nonexistent dir must fail --------------------------
test_missing_fm_home_dir_fails() {
  local dir fb err rc
  dir="$TMP_ROOT/badhome"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); err="$dir/peek.err"

  PATH="$fb:$PATH" FM_HOME="$dir/does-not-exist" FM_ROOT_OVERRIDE="$dir" \
    "$PEEK" some-task-id >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a nonexistent FM_HOME should fail"
  assert_contains "$(cat "$err")" "is not a directory" "nonexistent FM_HOME diagnostic should be explicit"
  pass "fm-peek strict: a task-id selector with a nonexistent FM_HOME fails"
}

# --- FM_HOME set but its state dir missing must fail --------------------------
test_missing_state_dir_fails() {
  local dir fb err rc home
  dir="$TMP_ROOT/nostate"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); err="$dir/peek.err"
  home="$dir/home"; mkdir -p "$home"   # home exists, but no state/ under it

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$dir" \
    "$PEEK" some-task-id >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a home without a state dir should fail"
  assert_contains "$(cat "$err")" "state dir" "missing-state diagnostic should name the state dir"
  pass "fm-peek strict: a task-id selector with a missing state dir fails"
}

# --- healthy home-scoped read still works ------------------------------------
test_task_id_with_home_resolves() {
  local dir fb err rc home out
  dir="$TMP_ROOT/healthy"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); err="$dir/peek.err"; home=$(setup_home healthy)
  fm_write_meta "$home/state/lane-ok.meta" "window=sess:fm-lane-ok" "kind=ship"

  out=$( PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_FAKE_PEEK_TAG=ok \
    "$PEEK" lane-ok 2>"$err" ); rc=$?
  expect_code 0 "$rc" "a task-id resolves and captures when FM_HOME and its state exist"
  assert_contains "$out" "PANE CONTENT for ok" "peek should return the captured pane content"
  pass "fm-peek strict: a task-id resolves through home metadata and captures"
}

# --- explicit backend target is the escape hatch: no FM_HOME needed -----------
test_explicit_target_needs_no_fm_home() {
  local dir fb err rc out
  dir="$TMP_ROOT/explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); err="$dir/peek.err"

  out=$( env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_FAKE_PEEK_TAG=direct \
    "$PEEK" sess:win 2>"$err" ); rc=$?
  expect_code 0 "$rc" "a fully-qualified explicit backend target should peek without FM_HOME"
  assert_contains "$out" "PANE CONTENT for direct" "explicit-target peek should capture directly"
  pass "fm-peek strict: an explicit backend target (contains ':') peeks without FM_HOME"
}

test_unset_fm_home_with_task_id_fails
test_missing_fm_home_dir_fails
test_missing_state_dir_fails
test_task_id_with_home_resolves
test_explicit_target_needs_no_fm_home

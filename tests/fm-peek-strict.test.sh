#!/usr/bin/env bash
# fm-peek fail-closed home contract (bughunt-fm-h2 finding 6).
#
# fm-peek resolves EVERY target form against THIS home's state, exactly like
# fm-send. Without an explicit FM_HOME it used to fall back to the script's own
# repo root and resolve the selector against the WRONG home's state, reading the
# wrong endpoint. A colon target (`session:window`) is NOT backend-qualified - it
# only names a window - so it must still resolve its backend from this home's
# metadata and must not bypass the home check (the QA-flagged hole: a no-home colon
# target defaulted to tmux and could read a non-tmux provider's endpoint). These
# tests pin the mirrored contract: FM_HOME with an existing state dir is required
# for ALL forms, colon targets included.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PEEK="$ROOT/bin/fm-peek.sh"
TMP_ROOT=$(fm_test_tmproot fm-peek-strict)

make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  # The tmux stub records that it was reached (FM_FAKE_TMUX_MARK), so a test can
  # prove peek refused BEFORE routing anything through the (possibly wrong) backend.
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  capture-pane)
    [ -n "${FM_FAKE_TMUX_MARK:-}" ] && : > "$FM_FAKE_TMUX_MARK"
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

# --- QA repro: a colon target with no FM_HOME must fail closed, not guess a backend
# Reproduces the QA finding exactly: no FM_HOME, no state dir, and a herdr-SHAPED
# colon target (`default:w1:p2`). The old escape hatch let this through and defaulted
# to tmux, reading the wrong provider. It must now refuse BEFORE touching any
# backend - the tmux stub must never be reached.
test_explicit_colon_target_still_requires_fm_home() {
  local dir fb err rc mark
  dir="$TMP_ROOT/colon-nohome"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); err="$dir/peek.err"; mark="$dir/tmux-was-called"

  env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_FAKE_TMUX_MARK="$mark" \
    "$PEEK" default:w1:p2 >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a colon target with no FM_HOME must fail closed, not guess a backend"
  assert_contains "$(cat "$err")" "FM_HOME is not set" "colon-target no-home diagnostic should be explicit"
  [ ! -e "$mark" ] || fail "peek routed a no-home colon target through tmux instead of refusing (the QA hole)"
  pass "fm-peek strict: a colon target with no FM_HOME fails closed and never reaches a backend"
}

# A colon target WITH FM_HOME resolves its backend from this home's metadata (the
# tmux default only when no meta says otherwise). The non-tmux side - a herdr-
# recorded colon target routing through herdr and never tmux - is proven in
# tests/fm-backend-herdr.test.sh (test_scripts_route_explicit_target_through_meta_backend).
test_colon_target_with_home_resolves_via_meta() {
  local dir fb err rc home out
  dir="$TMP_ROOT/colon-home"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); err="$dir/peek.err"; home=$(setup_home colon-home)
  # No meta for this window -> backend inference defaults to tmux, but only because
  # FM_HOME/state were present and consulted first.
  out=$( PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_FAKE_PEEK_TAG=viahome \
    "$PEEK" sess:win 2>"$err" ); rc=$?
  expect_code 0 "$rc" "a colon target with a valid FM_HOME should resolve and capture"
  assert_contains "$out" "PANE CONTENT for viahome" "colon-target peek with FM_HOME should capture"
  pass "fm-peek strict: a colon target resolves through home state when FM_HOME is set"
}

test_unset_fm_home_with_task_id_fails
test_missing_fm_home_dir_fails
test_missing_state_dir_fails
test_task_id_with_home_resolves
test_explicit_colon_target_still_requires_fm_home
test_colon_target_with_home_resolves_via_meta

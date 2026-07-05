#!/usr/bin/env bash
# tmux target-existence checks must prove the specific window exists.
#
# tmux display-message can resolve a missing session:window target to the
# session's active pane, so this suite fakes that false-alive behavior and pins
# fm_backend_target_exists to the structural window inventory instead.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-backend-tmux-target-exists)

make_fake_tmux() {  # <dir> -> echoes fakebin dir
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
  display-message)
    printf '%%1\n'
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

run_exists() {  # <fakebin> <windows-file> <log> <target> <expected-label>
  local fakebin=$1 windows=$2 log=$3 target=$4 expected=$5
  env PATH="$fakebin:$BASE_PATH" \
    FM_FAKE_TMUX_WINDOWS="$windows" \
    FM_FAKE_TMUX_LOG="$log" \
    ROOT="$ROOT" \
    bash -c ". \"$ROOT/bin/fm-backend.sh\"; if fm_backend_target_exists tmux \"\$1\" \"\$2\"; then printf alive; else printf dead; fi" \
    _ "$target" "$expected"
}

test_session_window_target_is_exact() {
  local dir fakebin windows log live dead
  dir="$TMP_ROOT/session-target"
  mkdir -p "$dir"
  fakebin=$(make_fake_tmux "$dir")
  windows="$dir/windows"
  log="$dir/tmux.log"
  printf '%s\n' 'fleet:fm-live' 'fleet:active' > "$windows"
  : > "$log"

  live=$(run_exists "$fakebin" "$windows" "$log" "fleet:fm-live" "fm-live")
  dead=$(run_exists "$fakebin" "$windows" "$log" "fleet:fm-missing" "fm-missing")

  [ "$live" = alive ] || fail "existing session:window target should be alive"
  [ "$dead" = dead ] || fail "missing session:window target should be dead"
  assert_no_grep "display-message" "$log" "tmux target-existence check should not use display-message"
  pass "tmux target exists: session-qualified targets are checked against exact windows"
}

test_bare_window_target_uses_window_inventory() {
  local dir fakebin windows log live dead
  dir="$TMP_ROOT/bare-target"
  mkdir -p "$dir"
  fakebin=$(make_fake_tmux "$dir")
  windows="$dir/windows"
  log="$dir/tmux.log"
  printf '%s\n' 'fleet:fm-live' 'other:fm-other' > "$windows"
  : > "$log"

  live=$(run_exists "$fakebin" "$windows" "$log" "fm-live" "fm-live")
  dead=$(run_exists "$fakebin" "$windows" "$log" "fm-missing" "fm-missing")

  [ "$live" = alive ] || fail "existing bare fm window should be alive"
  [ "$dead" = dead ] || fail "missing bare fm window should be dead"
  assert_no_grep "display-message" "$log" "bare target-existence check should not use display-message"
  pass "tmux target exists: bare fm labels are checked against the window inventory"
}

test_expected_label_mismatch_is_dead() {
  local dir fakebin windows log got
  dir="$TMP_ROOT/label-mismatch"
  mkdir -p "$dir"
  fakebin=$(make_fake_tmux "$dir")
  windows="$dir/windows"
  log="$dir/tmux.log"
  printf '%s\n' 'fleet:fm-other' > "$windows"
  : > "$log"

  got=$(run_exists "$fakebin" "$windows" "$log" "fleet:fm-other" "fm-wanted")

  [ "$got" = dead ] || fail "target whose window name differs from expected label should be dead"
  assert_no_grep "display-message" "$log" "expected-label check should not use display-message"
  pass "tmux target exists: expected label must match the resolved window"
}

test_session_window_target_is_exact
test_bare_window_target_uses_window_inventory
test_expected_label_mismatch_is_dead

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
      # tmux addresses a window after the colon by NAME or by INDEX, so the check
      # reads both inventories. They are separate fixtures here: FM_FAKE_TMUX_WINDOWS
      # holds session:name rows, FM_FAKE_TMUX_INDEXES holds session:index rows.
      '#{session_name}:#{window_index}') cat "${FM_FAKE_TMUX_INDEXES:-/dev/null}" ;;
      *) cat "$FM_FAKE_TMUX_WINDOWS" ;;
    esac
    exit 0
    ;;
  display-message)
    # Pane-id lookup. FM_FAKE_TMUX_PANES is a TAB-separated map of
    # "<requested target>\t<pane id tmux reports back>". An unlisted target is a
    # pane that does not exist: real tmux fails the command, so exit non-zero. A
    # target mapped to a DIFFERENT id models tmux answering about some other pane,
    # which the exact-id comparison in fm_backend_target_exists must reject.
    _target=; _prev=
    for _arg in "$@"; do
      [ "$_prev" = -t ] && _target=$_arg
      _prev=$_arg
    done
    awk -F'\t' -v t="$_target" '$1 == t { print $2; found = 1 } END { exit !found }' \
      "${FM_FAKE_TMUX_PANES:-/dev/null}" || exit 1
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# FM_FAKE_TMUX_INDEXES / FM_FAKE_TMUX_PANES are optional and default to empty, so
# a case that does not set them sees no window indexes and no panes at all.
run_exists() {  # <fakebin> <windows-file> <log> <target> <expected-label>
  local fakebin=$1 windows=$2 log=$3 target=$4 expected=$5
  env PATH="$fakebin:$BASE_PATH" \
    FM_FAKE_TMUX_WINDOWS="$windows" \
    FM_FAKE_TMUX_INDEXES="${FM_FAKE_TMUX_INDEXES:-/dev/null}" \
    FM_FAKE_TMUX_PANES="${FM_FAKE_TMUX_PANES:-/dev/null}" \
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

# --- pane-id targets (%N) -----------------------------------------------------
#
# fm-send and the away-mode daemon address firstmate's OWN supervisor pane by pane
# id (from $TMUX_PANE), not by window. The window inventory cannot answer for that
# form, so the check asks tmux directly and compares the id it gets back with the
# id it asked about - trusting exit 0 alone would let any other pane answer.

test_pane_id_target_matches_itself() {
  local dir fakebin windows panes log got
  dir="$TMP_ROOT/pane-match"
  mkdir -p "$dir"
  fakebin=$(make_fake_tmux "$dir")
  windows="$dir/windows"; panes="$dir/panes"; log="$dir/tmux.log"
  printf '%s\n' 'fleet:fm-live' > "$windows"
  printf '%%3\t%%3\n' > "$panes"
  : > "$log"

  got=$(FM_FAKE_TMUX_PANES="$panes" run_exists "$fakebin" "$windows" "$log" "%3" "")

  [ "$got" = alive ] || fail "a live pane id should be alive"
  assert_grep "display-message" "$log" "a pane-id target must be resolved through display-message"
  assert_no_grep "list-windows" "$log" "a pane-id target must not be looked up in the window inventory"
  pass "tmux target exists: a pane id that tmux reports back as itself is alive"
}

test_pane_id_resolving_to_another_pane_is_dead() {
  local dir fakebin windows panes log got
  dir="$TMP_ROOT/pane-mismatch"
  mkdir -p "$dir"
  fakebin=$(make_fake_tmux "$dir")
  windows="$dir/windows"; panes="$dir/panes"; log="$dir/tmux.log"
  printf '%s\n' 'fleet:fm-live' > "$windows"
  # tmux answers exit 0, but about a DIFFERENT pane than the one asked about.
  printf '%%3\t%%9\n' > "$panes"
  : > "$log"

  got=$(FM_FAKE_TMUX_PANES="$panes" run_exists "$fakebin" "$windows" "$log" "%3" "")

  [ "$got" = dead ] || fail "a pane id answered by a DIFFERENT pane must be dead, not trusted on exit 0"
  pass "tmux target exists: a pane id that resolves to another pane is dead"
}

test_absent_pane_id_is_dead() {
  local dir fakebin windows panes log got
  dir="$TMP_ROOT/pane-absent"
  mkdir -p "$dir"
  fakebin=$(make_fake_tmux "$dir")
  windows="$dir/windows"; panes="$dir/panes"; log="$dir/tmux.log"
  printf '%s\n' 'fleet:fm-live' > "$windows"
  : > "$panes"   # no panes at all: the pane genuinely does not exist
  : > "$log"

  got=$(FM_FAKE_TMUX_PANES="$panes" run_exists "$fakebin" "$windows" "$log" "%7" "")

  [ "$got" = dead ] || fail "a pane id that does not exist should be dead"
  pass "tmux target exists: a pane id tmux cannot resolve at all is dead"
}

# --- session:index targets ----------------------------------------------------
#
# The away-mode daemon's default supervisor target is firstmate:0 - a window
# INDEX, not a name - so the inventory is matched by index as well as by name.

test_session_index_target_matches_index_inventory() {
  local dir fakebin windows indexes log got
  dir="$TMP_ROOT/index-match"
  mkdir -p "$dir"
  fakebin=$(make_fake_tmux "$dir")
  windows="$dir/windows"; indexes="$dir/indexes"; log="$dir/tmux.log"
  # The window is NAMED fm-live, so only the index inventory can match "fleet:0".
  printf '%s\n' 'fleet:fm-live' > "$windows"
  printf '%s\n' 'fleet:0' > "$indexes"
  : > "$log"

  got=$(FM_FAKE_TMUX_INDEXES="$indexes" run_exists "$fakebin" "$windows" "$log" "fleet:0" "")

  [ "$got" = alive ] || fail "a session:index target present in the index inventory should be alive"
  assert_no_grep "display-message" "$log" "a session:index target must not fall back to display-message"
  pass "tmux target exists: a session:index target is matched against the window-index inventory"
}

test_missing_session_index_target_is_dead() {
  local dir fakebin windows indexes log got
  dir="$TMP_ROOT/index-missing"
  mkdir -p "$dir"
  fakebin=$(make_fake_tmux "$dir")
  windows="$dir/windows"; indexes="$dir/indexes"; log="$dir/tmux.log"
  printf '%s\n' 'fleet:fm-live' > "$windows"
  printf '%s\n' 'fleet:0' > "$indexes"
  : > "$log"

  got=$(FM_FAKE_TMUX_INDEXES="$indexes" run_exists "$fakebin" "$windows" "$log" "fleet:9" "")

  [ "$got" = dead ] || fail "a session:index target absent from the index inventory should be dead"
  assert_no_grep "display-message" "$log" "a missing session:index target must not be rescued by display-message"
  pass "tmux target exists: a session:index target with no matching index is dead"
}

test_session_window_target_is_exact
test_bare_window_target_uses_window_inventory
test_expected_label_mismatch_is_dead
test_pane_id_target_matches_itself
test_pane_id_resolving_to_another_pane_is_dead
test_absent_pane_id_is_dead
test_session_index_target_matches_index_inventory
test_missing_session_index_target_is_dead

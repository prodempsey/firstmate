#!/usr/bin/env bash
# tests/fm-send-claude-composer-e2e.test.sh - the acceptance test for the false
# "Enter swallowed" (task fm-send-submit-fix; bug bug-20260713225443-7ad73432).
#
# A REAL tmux pane runs a composer drawn exactly like the claude build captured
# live on 2026-07-13: the prompt glyph `❯` (U+276F) followed by a U+00A0 NO-BREAK
# SPACE, between two U+2500 rules. The real bin/fm-send.sh then steers it over
# the real tmux backend. Before the fix, fm-send read that idle row as `pending`
# ("your text is still in the composer"), retried Enter, and exited 1 on a
# message the pane had already received. This pins the two halves of the fix:
#
#   exit 0                     - the delivered message is reported as delivered.
#   delivered exactly once     - the Enter retries never produce a second turn.
#
# Isolation: a dedicated tmux socket (tmux -L fm-send-e2e-<pid>) plus a PATH shim
# that routes bin/fm-send.sh's bare `tmux` calls to it, so nothing touches the
# captain's own tmux server. Teardown kills that private socket's server only.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-send-e2e-$$"

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

TMP_ROOT=$(fm_test_tmproot fm-send-e2e)
HOME_DIR="$TMP_ROOT/home"
STATE_DIR="$HOME_DIR/state"
mkdir -p "$STATE_DIR"
LOG_FILE="$TMP_ROOT/submitted.log"
: > "$LOG_FILE"

# --- the composer under test: claude's real shape ---------------------------
#
# Drawn by the pane itself (not the terminal driver's echo, whose cursor
# placement varies across CI environments): a U+2500 rule, then a cursor row of
# `❯` + U+00A0 + whatever has been typed but not yet submitted. Written with
# \x escapes so this file stays plain ASCII in git.
LOOP_SCRIPT="$TMP_ROOT/claude-composer.sh"
cat > "$LOOP_SCRIPT" <<'LOOP'
#!/usr/bin/env bash
LOG="$1"
GLYPH=$(printf '\xe2\x9d\xaf')     # U+276F ❯
NBSP=$(printf '\xc2\xa0')          # U+00A0 NO-BREAK SPACE
RULE=$(printf '\xe2\x94\x80%.0s' 1 2 3 4 5 6 7 8 9 10)   # U+2500 rules
OLD_STTY=$(stty -g 2>/dev/null || true)
[ -z "$OLD_STTY" ] || stty -echo -icanon min 1 time 0 2>/dev/null || true
trap '[ -z "$OLD_STTY" ] || stty "$OLD_STTY" 2>/dev/null || true' EXIT INT TERM

buf=
redraw() { printf '\r\033[K%s%s%s' "$GLYPH" "$NBSP" "$buf"; }
submit() {
  printf '%s\n' "$buf" >> "$LOG"
  buf=
  printf '\r\033[K\n%s\n' "$RULE"
  redraw
}

printf '%s\n' "$RULE"
redraw
while IFS= read -r -n 1 ch; do
  if [ -z "$ch" ]; then submit; continue; fi
  case "$ch" in
    $'\r'|$'\n') submit ;;
    $'\177'|$'\b') buf=${buf%?}; redraw ;;
    *) buf="${buf}${ch}"; redraw ;;
  esac
done
LOOP
chmod +x "$LOOP_SCRIPT"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s crew -n fm-crew-e2e -x 120 -y 40
"$REAL_TMUX" -L "$SOCKET" send-keys -t crew:fm-crew-e2e "bash '$LOOP_SCRIPT' '$LOG_FILE'" Enter
sleep 1  # let the composer draw its idle row

# tmux shim: fm-send.sh calls a bare `tmux`; route it to the private socket.
SHIM_DIR=$(fm_fakebin "$TMP_ROOT")
cat > "$SHIM_DIR/tmux" <<SHIM
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SHIM
chmod +x "$SHIM_DIR/tmux"

fm_write_meta "$STATE_DIR/crew-e2e.meta" \
  "window=crew:fm-crew-e2e" \
  "worktree=$TMP_ROOT" \
  "project=demo" \
  "harness=claude" \
  "kind=ship" \
  "mode=local-only" \
  "yolo=off"

# --- the idle composer must read empty, not pending -------------------------

test_idle_pane_reads_empty() {
  local state
  state=$(PATH="$SHIM_DIR:$PATH" bash -c \
    ". '$ROOT/bin/fm-tmux-lib.sh'; fm_tmux_composer_state crew:fm-crew-e2e")
  [ "$state" = empty ] \
    || fail "a real idle claude-shaped composer pane must read empty, got '$state'"
  pass "fm_tmux_composer_state: a real tmux pane drawing claude's '❯'+U+00A0 composer reads empty"
}

# --- fm-send exits 0 and the crew receives the message exactly once ----------

test_send_reports_success_and_delivers_once() {
  local rc=0 out hits
  out=$(PATH="$SHIM_DIR:$PATH" FM_HOME="$HOME_DIR" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" crew-e2e 'rebase onto main' 2>&1) || rc=$?
  expect_code 0 "$rc" "fm-send on a delivered message"
  assert_not_contains "$out" "Enter swallowed" "fm-send must not report a swallow for a delivered message"
  sleep 0.5
  hits=$(grep -c -F 'rebase onto main' "$LOG_FILE" || true)
  [ "$hits" = 1 ] \
    || fail "the crew must receive the message exactly once, got $hits deliveries"
  pass "fm-send.sh: a real send to a live claude-shaped pane exits 0 and delivers exactly once"
}

test_idle_pane_reads_empty
test_send_reports_success_and_delivers_once

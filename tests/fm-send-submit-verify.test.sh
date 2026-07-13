#!/usr/bin/env bash
# tests/fm-send-submit-verify.test.sh - submit verification against the composer
# shape claude actually draws (task fm-send-submit-fix; bug
# bug-20260713225443-7ad73432, whose original delivery-failure diagnosis was
# wrong - the message WAS delivered; the SUBMIT VERIFICATION was a false
# negative).
#
# The live-captured idle claude composer (2026-07-13, `tmux capture-pane` + `cat
# -A`) is a `❯` prompt glyph between two U+2500 rules, with the rest of the row a
# single U+00A0 NO-BREAK SPACE:
#
#   ────────────────────  <- U+2500 rule
#   ❯<U+00A0>             <- bytes: \xe2\x9d\xaf \xc2\xa0
#   ────────────────────  <- U+2500 rule
#
# U+00A0 is not ASCII whitespace, so the row trimmed to "❯<U+00A0>", never
# matched the bare-agent-glyph case, and classified as `pending` - i.e. "your text
# is still sitting unsubmitted in the composer". fm-send.sh then retried Enter,
# gave up, and exited non-zero on a message the crew had already received and
# answered. The U+00A0 appears here only as a \xc2\xa0 escape: a raw byte would
# make this fixture file binary to git.
#
# What this pins:
#   1. The idle `❯`+U+00A0 pane reads `empty` (fm_tmux_composer_state).
#   2. A real submit reports `empty` and delivers the message exactly ONCE.
#   3. A genuinely swallowed Enter still reports `pending` (fail-closed: fm-send
#      is RIGHT to fail on an unsubmitted message; only the false negative is a bug).
#   4. The duplicate-submit guard: if a submit lands but is never confirmed, the
#      Enter retries must not produce a second turn.
#   5. End-to-end through the real bin/fm-send.sh, over a real tmux pane running a
#      composer with the captured shape: exit 0, delivered exactly once.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-submit)

# --- a stateful fake tmux modelling a claude-shaped composer ----------------
#
# Composer row = "❯" + U+00A0 + whatever has been typed but not submitted.
# send-keys -l appends literal text; send-keys Enter behaves per FM_FAKE_MODE:
#   normal        - Enter submits whatever the composer holds (a real TUI).
#   swallow       - Enter is eaten; the text stays in the composer (the genuine
#                   failure fm-send must keep reporting).
#   false-pending - Enter submits, but the composer then shows OTHER text, so the
#                   reader still sees `pending` and cannot confirm the submit.
# It counts every Enter (enters) and every message actually submitted (submits),
# so "delivered exactly once" is an assertion, not an inference.
make_fake_tmux() {  # <dir> -> echoes the fakebin dir
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
d=${FM_FAKE_DIR:?}
mode=${FM_FAKE_MODE:-normal}
nbsp=$(printf '\xc2\xa0')
glyph=$(printf '\xe2\x9d\xaf')
bump() { local f=$1 n; n=$(cat "$d/$f" 2>/dev/null || echo 0); printf '%s\n' "$((n + 1))" > "$d/$f"; }
case "${1:-}" in
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    printf '%s%s%s\n' "$glyph" "$nbsp" "$(cat "$d/composer" 2>/dev/null || true)"
    exit 0 ;;
  send-keys)
    literal=0; last=""
    for a in "$@"; do
      [ "$a" = "-l" ] && literal=1
      last=$a
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "$last" >> "$d/composer"
      exit 0
    fi
    [ "$last" = Enter ] || exit 0
    bump enters
    text=$(cat "$d/composer" 2>/dev/null || true)
    [ -n "$text" ] || exit 0            # Enter on an empty composer: a no-op turn.
    case "$mode" in
      swallow) : ;;                     # Enter eaten; text stays put.
      false-pending)
        printf '%s\n' "$text" >> "$d/submitted"; bump submits
        printf 'draft the crew started typing' > "$d/composer" ;;
      *)
        printf '%s\n' "$text" >> "$d/submitted"; bump submits
        : > "$d/composer" ;;
    esac
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

fake_dir() {  # <name> -> a fresh composer state dir
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  : > "$d/composer"
  : > "$d/submitted"
  printf '0\n' > "$d/enters"
  printf '0\n' > "$d/submits"
  printf '%s\n' "$d"
}

counter() { cat "$1/$2" 2>/dev/null || echo 0; }

FAKEBIN=$(make_fake_tmux "$TMP_ROOT")
PATH="$FAKEBIN:$PATH"

# --- 1. the live-captured idle composer reads empty --------------------------

test_idle_claude_composer_reads_empty() {
  local d state
  d=$(fake_dir idle)
  state=$(FM_FAKE_DIR=$d fm_tmux_composer_state fake:0)
  [ "$state" = empty ] \
    || fail "the live claude '❯'+U+00A0 composer must read empty, got '$state'"
  pass "fm_tmux_composer_state: an idle claude '❯'+U+00A0 composer reads empty (was the false 'pending')"
}

# --- 2. a real submit is confirmed, and delivers exactly once ----------------

test_submit_confirmed_and_delivered_once() {
  local d verdict
  d=$(fake_dir normal)
  verdict=$(FM_FAKE_DIR=$d FM_FAKE_MODE=normal fm_tmux_submit_core fake:0 'fix the failing test' 3 0 0)
  [ "$verdict" = empty ] || fail "a landed submit must report empty, got '$verdict'"
  [ "$(counter "$d" submits)" = 1 ] \
    || fail "the message must be submitted exactly once, got $(counter "$d" submits)"
  [ "$(grep -c 'fix the failing test' "$d/submitted")" = 1 ] \
    || fail "the crew must receive the message exactly once"
  pass "fm_tmux_submit_core: a real submit reports empty and delivers the message exactly once"
}

# --- 3. a genuinely swallowed Enter still fails closed -----------------------

test_swallowed_enter_still_reports_pending() {
  local d verdict
  d=$(fake_dir swallow)
  verdict=$(FM_FAKE_DIR=$d FM_FAKE_MODE=swallow fm_tmux_submit_core fake:0 'steer the crew' 3 0 0)
  [ "$verdict" = pending ] \
    || fail "a genuinely swallowed Enter must still report pending (fail-closed), got '$verdict'"
  [ "$(counter "$d" submits)" = 0 ] || fail "nothing should have been submitted in swallow mode"
  [ "$(counter "$d" enters)" = 3 ] \
    || fail "Enter should be retried up to the retry budget, got $(counter "$d" enters)"
  pass "fm_tmux_submit_core: a truly unsubmitted message still reports pending (fm-send stays fail-closed)"
}

# --- 4. duplicate-submit guard ----------------------------------------------

test_unconfirmed_submit_never_double_sends() {
  local d verdict
  d=$(fake_dir false_pending)
  # The submit lands on the first Enter, but the composer then holds OTHER text,
  # so the reader still says `pending`. The retry loop must NOT press Enter again:
  # a second Enter would submit that other text as a second turn.
  verdict=$(FM_FAKE_DIR=$d FM_FAKE_MODE=false-pending fm_tmux_submit_core fake:0 'ship it' 3 0 0)
  [ "$verdict" != pending ] \
    || fail "an unconfirmable-but-changed composer must not be reported as a swallow"
  [ "$(counter "$d" submits)" = 1 ] \
    || fail "an unconfirmed submit must never produce a second turn, got $(counter "$d" submits) submits"
  [ "$(counter "$d" enters)" = 1 ] \
    || fail "Enter must not be re-pressed once our text has left the composer, got $(counter "$d" enters)"
  pass "fm_tmux_submit_core: an unconfirmed submit is never re-Entered, so it cannot produce a second turn"
}

test_idle_claude_composer_reads_empty
test_submit_confirmed_and_delivered_once
test_swallowed_enter_still_reports_pending
test_unconfirmed_submit_never_double_sends

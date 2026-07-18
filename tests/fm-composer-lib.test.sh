#!/usr/bin/env bash
# tests/fm-composer-lib.test.sh - the shared composer-content classifier
# (bin/fm-composer-lib.sh), the ONE fleet-wide owner every backend adapter
# delegates its empty|pending|unknown verdict to.
#
# The load-bearing contract, task fm-composer-shellglyph-safety:
#   1. A BARE shell prompt glyph (`>`/`$`/`%`/`#`) on an unstructured row is a
#      dead shell, NOT an empty agent composer - it must read `unknown`
#      (unsafe-for-injection), never `empty`. This is the safety fix.
#   2. The SAME shell glyph INSIDE a bordered composer box is the harness's own
#      prompt and still reads `empty` (existing behavior preserved).
#   3. The AGENT prompt glyphs `❯` (claude) and `›` (codex) are a genuine empty
#      agent composer either way, bordered or bare.
#   4. Real unsubmitted text reads `pending`; a known idle placeholder reads
#      `empty`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"

# classify <bordered> <content> [idle_re] -> echoes the verdict.
classify() { fm_composer_classify_content "$@"; }

# --- Safety fix: bare shell prompt is NOT an empty agent composer -----------

test_bare_shell_glyphs_are_unknown() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 0 "$g")
    [ "$out" = unknown ] \
      || fail "bare shell glyph '$g' must read unknown (dead shell, unsafe), got '$out'"
  done
  pass "fm_composer_classify_content: a bare shell prompt glyph (>/\$/%/#) reads unknown, never empty"
}

test_stripped_unbordered_content_uses_plain_content() {
  local plain out
  for plain in '$' 'user@host $'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = unknown ] \
      || fail "stripped unbordered content '$plain' must retain its unknown safety verdict, got '$out'"
  done
  for plain in '❯' '›'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = empty ] \
      || fail "a stripped agent glyph '$plain' must remain empty, got '$out'"
  done
  pass "fm_composer_classify_content: stripped unbordered content is unknown except verified agent glyphs"
}

test_bare_shell_prompt_with_command_is_not_empty() {
  local out
  # A dead shell showing a typed command must not read empty either.
  out=$(classify 0 '$ ls -la')
  [ "$out" != empty ] || fail "a bare shell prompt with a command must not read empty, got '$out'"
  pass "fm_composer_classify_content: a bare shell prompt carrying a command is not empty"
}

# --- Preserved: shell glyph inside a composer box is the harness prompt ------

test_bordered_shell_glyph_is_empty() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 1 "$g")
    [ "$out" = empty ] \
      || fail "a shell glyph '$g' inside a bordered composer box must read empty, got '$out'"
  done
  pass "fm_composer_classify_content: a bare prompt glyph inside a bordered composer box reads empty (claude's own idle composer)"
}

# --- Agent glyphs are empty either way --------------------------------------

test_agent_glyphs_are_empty_bordered_and_bare() {
  local out
  out=$(classify 0 '❯'); [ "$out" = empty ] || fail "bare claude '❯' should read empty, got '$out'"
  out=$(classify 0 '›'); [ "$out" = empty ] || fail "bare codex '›' should read empty, got '$out'"
  out=$(classify 1 '❯'); [ "$out" = empty ] || fail "bordered claude '❯' should read empty, got '$out'"
  out=$(classify 1 '›'); [ "$out" = empty ] || fail "bordered codex '›' should read empty, got '$out'"
  pass "fm_composer_classify_content: agent prompt glyphs (❯ claude, › codex) read empty bordered or bare"
}

# --- Empty content and idle placeholder -------------------------------------

test_empty_content_is_empty() {
  local out
  out=$(classify 0 ''); [ "$out" = empty ] || fail "empty bare content should read empty, got '$out'"
  out=$(classify 1 ''); [ "$out" = empty ] || fail "empty bordered content should read empty, got '$out'"
  pass "fm_composer_classify_content: an empty composer reads empty"
}

test_idle_placeholder_is_empty() {
  local idle='^Type a message\.\.\.$' out
  # Placeholder with no prompt glyph (grok's bordered empty composer).
  out=$(classify 1 'Type a message...' "$idle")
  [ "$out" = empty ] || fail "the grok idle placeholder should read empty, got '$out'"
  # Placeholder after an agent glyph (post-strip match).
  out=$(classify 0 '❯ Type a message...' "$idle")
  [ "$out" = empty ] || fail "the idle placeholder after a glyph should read empty, got '$out'"
  # Without the idle regex it is just text -> pending.
  out=$(classify 1 'Type a message...')
  [ "$out" = pending ] || fail "without an idle regex the placeholder text is pending, got '$out'"
  pass "fm_composer_classify_content: a known idle placeholder reads empty, before and after glyph stripping"
}

test_idle_placeholder_case_mode_is_explicit() {
  local idle='^Type a message\.\.\.$' out
  out=$(classify 1 'type a message...' "$idle")
  [ "$out" = pending ] || fail "a case-variant idle placeholder should remain pending by default, got '$out'"
  out=$(classify 1 'type a message...' "$idle" insensitive)
  [ "$out" = empty ] || fail "an explicitly insensitive idle placeholder should read empty, got '$out'"
  pass "fm_composer_classify_content: idle matching preserves the caller's case mode"
}

# --- Real text is pending ---------------------------------------------------

test_real_text_is_pending() {
  local out
  out=$(classify 0 '❯ fix findings 1 and 3'); [ "$out" = pending ] || fail "bare '❯ <text>' should be pending, got '$out'"
  out=$(classify 1 '> deploy staging now'); [ "$out" = pending ] || fail "bordered '> <text>' should be pending, got '$out'"
  # A slash-command popup argument-hint placeholder is still unsubmitted text.
  out=$(classify 1 '/compact compaction instructions'); [ "$out" = pending ] || fail "a popup placeholder fill should be pending, got '$out'"
  pass "fm_composer_classify_content: real unsubmitted text reads pending (including a popup argument-hint fill)"
}

# --- Non-breaking-space padding (task fm-send-submit-fix) -------------------
#
# The claude build captured live on 2026-07-13 draws its idle composer as a `❯`
# glyph between two U+2500 rules, with the rest of the row a single U+00A0
# NO-BREAK SPACE (real captured bytes: \xe2\x9d\xaf \xc2\xa0). U+00A0 is not
# ASCII whitespace, so the row used to trim to "❯<U+00A0>", miss the bare
# agent-glyph case, and classify as `pending` - the false "Enter swallowed" that
# made fm-send report failure on messages it had delivered. The U+00A0 is written
# as an escape here on purpose: a raw byte would make this fixture file binary to
# git and invisible in review.

test_nbsp_padded_agent_glyph_is_empty() {
  local nbsp row out
  nbsp=$(printf '\xc2\xa0')
  # The real captured composer row: prompt glyph + NO-BREAK SPACE, nothing else.
  row=$(printf '\xe2\x9d\xaf\xc2\xa0')
  out=$(classify 0 "$row")
  [ "$out" = empty ] \
    || fail "claude's idle '❯'+U+00A0 composer must read empty, got '$out'"
  # Same row reached through the ghost-stripped/plain-content path.
  out=$(classify 0 '' '' sensitive "$row")
  [ "$out" = empty ] \
    || fail "a ghost-stripped '❯'+U+00A0 composer must read empty, got '$out'"
  # Codex's glyph and a trailing narrow no-break space (U+202F) fold too.
  out=$(classify 0 "$(printf '\xe2\x80\xba\xe2\x80\xaf')")
  [ "$out" = empty ] || fail "'›'+U+202F should read empty, got '$out'"
  # An ordinary-space-padded glyph keeps reading empty (unchanged behavior).
  out=$(classify 0 '❯   ')
  [ "$out" = empty ] || fail "'❯' padded with ASCII spaces should read empty, got '$out'"
  # And an all-NBSP row with no glyph at all is just an empty row.
  out=$(classify 1 "$nbsp$nbsp")
  [ "$out" = empty ] || fail "an all-NBSP bordered row should read empty, got '$out'"
  pass "fm_composer_classify_content: a non-breaking-space-padded agent composer reads empty"
}

test_nbsp_does_not_loosen_the_safety_verdicts() {
  local out
  # A bare shell prompt padded the same way is STILL a dead shell, not a composer.
  out=$(classify 0 "$(printf '\x24\xc2\xa0')")
  [ "$out" = unknown ] \
    || fail "a bare shell prompt padded with U+00A0 must stay unknown, got '$out'"
  out=$(classify 0 '' '' sensitive "$(printf '\x24\xc2\xa0')")
  [ "$out" = unknown ] \
    || fail "a ghost-stripped bare shell prompt with U+00A0 must stay unknown, got '$out'"
  # Real unsubmitted text separated from the glyph by a U+00A0 is STILL pending.
  out=$(classify 0 "$(printf '\xe2\x9d\xaf\xc2\xa0fix findings 1 and 3')")
  [ "$out" = pending ] \
    || fail "real text after a U+00A0 must stay pending, got '$out'"
  # Inside a composer box, the harness's own shell-style glyph stays empty.
  out=$(classify 1 "$(printf '\x3e\xc2\xa0')")
  [ "$out" = empty ] || fail "a bordered '>'+U+00A0 prompt should read empty, got '$out'"
  pass "fm_composer_classify_content: NBSP folding keeps unknown/pending verdicts intact"
}

# --- OSC / string escape sequences (bughunt-fm-h2 finding 2) ----------------
#
# Modern terminals and TUIs inject OSC-8 hyperlinks (ESC ] 8 ; ; URL ST ... ST)
# and other string escape sequences that a plain capture keeps as bytes. The
# stripper used to remove only CSI (ESC [ ... final) sequences, so an OSC run
# survived: fm_composer_strip_ansi left the ESC in place and fm_composer_strip_ghost
# dropped only the ESC byte, turning the payload into printable garbage like
# "]8;;http://...\". That garbage is non-empty content, so a genuinely empty
# composer - or a bare agent glyph wrapped in an OSC-8 link - misread as `pending`
# on the safety-critical empty|pending|unknown contract. Both strippers must now
# consume the whole string sequence through its String Terminator (BEL or ESC \).
ESC_BYTE=$(printf '\033'); BEL_BYTE=$(printf '\007')

test_osc_wrapped_agent_glyph_is_empty() {
  local row plain ghost out
  # OSC-8 hyperlink (ST=ESC\ terminated) wrapping a bare claude glyph.
  row="${ESC_BYTE}]8;;http://example.com${ESC_BYTE}\\❯${ESC_BYTE}]8;;${ESC_BYTE}\\"
  plain=$(printf '%s' "$row" | fm_composer_strip_ansi)
  [ "$plain" = '❯' ] || fail "strip_ansi must drop the OSC-8 wrapper, got '$plain'"
  ghost=$(printf '%s' "$row" | fm_composer_strip_ghost)
  [ "$ghost" = '❯' ] || fail "strip_ghost must drop the OSC-8 wrapper, got '$ghost'"
  out=$(classify 0 "$(fm_composer_trim "$plain")")
  [ "$out" = empty ] || fail "an OSC-8-wrapped agent glyph must read empty, got '$out'"
  # BEL-terminated OSC around codex's glyph resolves the same way.
  row="${ESC_BYTE}]8;;http://x${BEL_BYTE}›${ESC_BYTE}]8;;${BEL_BYTE}"
  plain=$(printf '%s' "$row" | fm_composer_strip_ansi)
  [ "$plain" = '›' ] || fail "strip_ansi must drop a BEL-terminated OSC, got '$plain'"
  out=$(classify 0 "$(fm_composer_trim "$plain")")
  [ "$out" = empty ] || fail "a BEL-terminated OSC around '›' must read empty, got '$out'"
  pass "fm_composer_strip_*: an OSC-8-wrapped agent glyph is stripped and reads empty"
}

test_osc_only_empty_row_is_empty() {
  local row plain ghost out
  # An OSC sequence with no visible text at all (e.g. a title/hyperlink-clear run)
  # must strip to nothing, not to a `pending` row of leftover bytes.
  row="${ESC_BYTE}]8;;http://x${ESC_BYTE}\\${ESC_BYTE}]8;;${ESC_BYTE}\\"
  plain=$(printf '%s' "$row" | fm_composer_strip_ansi)
  [ -z "$plain" ] || fail "strip_ansi must reduce an OSC-only row to empty, got '$plain'"
  ghost=$(printf '%s' "$row" | fm_composer_strip_ghost)
  [ -z "$ghost" ] || fail "strip_ghost must reduce an OSC-only row to empty, got '$ghost'"
  out=$(classify 0 "$(fm_composer_trim "$plain")")
  [ "$out" = empty ] || fail "an OSC-only row must read empty, got '$out'"
  # BEL-terminated OSC-0 window-title sequence, same expectation.
  row="${ESC_BYTE}]0;my window title${BEL_BYTE}"
  plain=$(printf '%s' "$row" | fm_composer_strip_ansi)
  [ -z "$plain" ] || fail "strip_ansi must drop a BEL-terminated OSC title, got '$plain'"
  pass "fm_composer_strip_*: an OSC-only row strips to empty and reads empty"
}

test_osc_stripping_preserves_real_text() {
  local row plain out
  # A real typed message that merely CONTAINS an OSC-8 link must keep its text and
  # stay `pending` - the fix drops escape sequences, never real content.
  row="fix ${ESC_BYTE}]8;;http://bug${ESC_BYTE}\\the bug${ESC_BYTE}]8;;${ESC_BYTE}\\ now"
  plain=$(printf '%s' "$row" | fm_composer_strip_ansi)
  [ "$plain" = 'fix the bug now' ] \
    || fail "strip_ansi must keep the linked text, got '$plain'"
  out=$(classify 0 "$(fm_composer_trim "$plain")")
  [ "$out" = pending ] || fail "real text with an OSC-8 link must stay pending, got '$out'"
  pass "fm_composer_strip_ansi: OSC stripping preserves the real linked text (stays pending)"
}

test_bare_shell_glyphs_are_unknown
test_stripped_unbordered_content_uses_plain_content
test_nbsp_padded_agent_glyph_is_empty
test_nbsp_does_not_loosen_the_safety_verdicts
test_osc_wrapped_agent_glyph_is_empty
test_osc_only_empty_row_is_empty
test_osc_stripping_preserves_real_text
test_bare_shell_prompt_with_command_is_not_empty
test_bordered_shell_glyph_is_empty
test_agent_glyphs_are_empty_bordered_and_bare
test_empty_content_is_empty
test_idle_placeholder_is_empty
test_idle_placeholder_case_mode_is_explicit
test_real_text_is_pending

#!/usr/bin/env bash
# fm-tmux-lib.sh — shared tmux pane primitives for firstmate.
#
# ONE source of truth for: busy detection, composer-empty (pending-input)
# detection, and a verify-and-retry-Enter submit. Sourced by both the away-mode
# daemon (bin/fm-supervise-daemon.sh) and bin/fm-send.sh so the composer/submit
# logic cannot drift between the two.
#
# Why this exists (incident afk-invx-i5): the daemon's old composer check only
# recognized a BARE prompt glyph ("> ") as an empty composer. claude draws its
# input box with box-drawing borders ("│ > … │"), so every idle claude pane read
# as "pending input" and the away-mode daemon deferred 100% of escalations for
# 9.5 hours with no escape. The detector below strips the box borders before
# deciding, so a bordered-but-empty composer is correctly seen as empty. The same
# corrected detector backs the submit acknowledgement (a submit "landed" iff the
# composer is empty afterward), fixing the parallel false "Enter swallowed".
#
# Ghost text (incident composer-robust): claude renders a predicted-next-prompt
# "suggestion" as dim/faint text inside an otherwise-empty composer. A plain
# capture cannot tell it apart from text a human typed, so the old reader saw an
# idle pane as holding pending input and the daemon deferred injection / firstmate
# misjudged the pane. The composer reader now captures just the cursor line WITH
# ANSI styling (tmux capture-pane -e) and extracts the real typed content with the
# shared, fleet-wide fm_composer_strip_ghost (bin/fm-composer-lib.sh), which drops
# every de-emphasised run - dim/faint (SGR 2) AND a dark/muted truecolor
# foreground - so ghost/placeholder text never counts as real input. The styled
# capture is consumed internally and parsed into a boolean here; it is NEVER
# surfaced (fm-peek and every human/LLM-facing path stay plain), and only the
# single composer row is captured, so no escape-laden pane bulk is produced. This
# is harness-generic: any harness that de-emphasises placeholder/ghost text
# benefits, and the herdr adapter routes through the same owner (task
# afk-herdr-false-pending), so the two backends cannot drift.
#
# Per-harness override: FM_COMPOSER_IDLE_RE matches an empty composer after
# ghost and structural border stripping. FM_BUSY_REGEX overrides the busy
# footer set (mirrors fm-watch.sh / the daemon).
#
# All functions are `set -u` and `set -e` safe (guarded tmux calls, explicit
# returns) so they can be sourced into either context.
#
# Composer-content classification (empty|pending|unknown, and the fleet-wide
# rule that a BARE shell prompt glyph is a dead shell, not an empty agent
# composer) is NOT owned here: it is the shared bin/fm-composer-lib.sh, sourced
# below and reused by every backend adapter so the decision cannot drift.

# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-composer-lib.sh"

# Busy footers per harness (mirror fm-watch.sh). claude/codex: "esc to
# interrupt"; opencode: "esc interrupt"; pi: "Working..."; grok: "Ctrl+c:cancel"
# (grok's mid-turn cancel hint, shown iff a turn is running - verified grok 0.2.73);
# gemini: "esc to cancel" (spinner line "Thinking... (esc to cancel, Ns)" - verified
# gemini-cli 0.50.0).
FM_TMUX_BUSY_REGEX_DEFAULT='esc (to )?interrupt|esc to cancel|Working\.\.\.|Ctrl\+c:cancel'

# fm_tmux_strip_ghost: thin adapter over the shared, fleet-wide ghost extractor
# fm_composer_strip_ghost (bin/fm-composer-lib.sh). It drops de-emphasised
# ghost/placeholder runs - dim/faint (SGR 2, claude's/codex's ghost) AND a
# dark/muted truecolor foreground (grok's placeholder) - from one captured,
# styled composer line and prints the plain, real-typed text. Kept as a named
# tmux entry point (and for existing callers/tests) but owns no logic of its own,
# so the tmux and herdr adapters cannot drift apart on what counts as ghost text.
fm_tmux_strip_ghost() { fm_composer_strip_ghost; }

# fm_tmux_composer_state: classify the cursor/composer line of <target> as
#   empty   - no pending input (blank, a busy footer, an empty agent composer, or
#             only de-emphasised ghost/placeholder text). Safe to inject; also the positive
#             acknowledgement that a submit landed.
#   pending - real, unsubmitted text on the cursor line (a human mid-typing, or a
#             previous injection whose Enter was swallowed). Defer / retry.
#   unknown - the pane could not be read (tmux error), OR the cursor line is a
#             bare shell prompt (`$`/`%`/`#`/`>`) - a dead shell, not an agent
#             composer, so NOT a safe injection target. The caller decides.
#
# The cursor line is captured WITH ANSI styling (capture-pane -e) and bounded to
# the single composer row (-S/-E). The bordered flag (a genuine composer box) is
# read from the PLAIN row (fm_composer_strip_ansi keeps ghost text so the box
# border is still visible), while the real-typed CONTENT is extracted with the
# shared fm_composer_strip_ghost so dim/faint AND dark-truecolor ghost text drops
# out before classification (grok's dark box border drops with the ghost, which
# is why the bordered flag is read from the plain row, not the ghost-stripped
# one). Both are internal only, never surfaced. The detector strips the harness's
# box-drawing composer borders ("│ … │", heavy "┃", or a plain ASCII "|") using
# literal-string substitution (bash 3.2 safe, locale-independent - no \u escapes,
# no multibyte character classes), and delegates the empty/pending/unknown
# decision to the shared owner fm_composer_classify_content
# (bin/fm-composer-lib.sh). The bordered flag is what lets a bordered `│ > │`
# (claude's own idle composer) read empty while a bare, unbordered `$ ` dead-shell
# prompt reads unknown.
# Set by fm_tmux_composer_probe on every call, so a caller that needs BOTH the
# verdict and the row's real typed content (the submit core's duplicate-submit
# guard) pays for one capture, not two.
FM_TMUX_COMPOSER_STATE=unknown
FM_TMUX_COMPOSER_CONTENT=""

# fm_tmux_composer_probe: read <target>'s composer row once and set
# FM_TMUX_COMPOSER_STATE (empty|pending|unknown) and FM_TMUX_COMPOSER_CONTENT
# (the ghost-stripped, border-stripped, non-breaking-space-normalized real typed
# content of the row; empty string when the pane could not be read). Always
# returns 0. fm_tmux_composer_state is the thin printing wrapper.
#
# Every trim here routes through the shared fm_composer_trim_into
# (bin/fm-composer-lib.sh), which folds non-breaking spaces to ASCII spaces: the
# claude build verified on 2026-07-13 pads its idle `❯` composer with a U+00A0,
# which bash's [[:space:]] trims do NOT strip, so a plain trim left "❯<U+00A0>"
# and the row misread as pending (the false "Enter swallowed" this fixed).
fm_tmux_composer_probe() {  # <target>
  local target=$1 cy raw plain stripped bordered=0
  FM_TMUX_COMPOSER_STATE=unknown
  FM_TMUX_COMPOSER_CONTENT=""
  cy=$(tmux display-message -p -t "$target" '#{cursor_y}' 2>/dev/null) || return 0
  case "$cy" in ''|*[!0-9]*) return 0 ;; esac
  raw=$(tmux capture-pane -e -p -t "$target" -S "$cy" -E "$cy" 2>/dev/null) || return 0
  # bordered: from the plain row (borders survive an all-ANSI strip).
  plain=$(printf '%s\n' "$raw" | fm_composer_strip_ansi)
  fm_composer_trim_into plain "$plain"
  case "$plain" in
    '│'*'│'|'┃'*'┃'|'|'*'|') bordered=1 ;;
  esac
  # content: from the ghost-stripped row (real typed text only).
  stripped=$(printf '%s\n' "$raw" | fm_composer_strip_ghost)
  fm_composer_trim_into stripped "$stripped"
  case "$stripped" in
    '│'*'│') stripped=${stripped#│}; stripped=${stripped%│} ;;
    '┃'*'┃') stripped=${stripped#┃}; stripped=${stripped%┃} ;;
    '|'*'|') stripped=${stripped#|}; stripped=${stripped%|} ;;
  esac
  fm_composer_trim_into stripped "$stripped"
  FM_TMUX_COMPOSER_CONTENT=$stripped
  # A busy footer landing on the cursor line is not pending input (tmux-specific:
  # only tmux captures the raw cursor row, which may BE the footer).
  if [ -n "$stripped" ] \
     && printf '%s' "$stripped" | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"; then
    FM_TMUX_COMPOSER_STATE=empty
    return 0
  fi
  FM_TMUX_COMPOSER_STATE=$(fm_composer_classify_content \
    "$bordered" "$stripped" "${FM_COMPOSER_IDLE_RE:-}" insensitive "$plain")
  return 0
}

fm_tmux_composer_state() {  # <target> -> empty|pending|unknown
  fm_tmux_composer_probe "$1"
  printf '%s' "$FM_TMUX_COMPOSER_STATE"
}

# fm_pane_input_pending: 0 (pending) if the cursor line holds real unsubmitted
# text, 1 otherwise. An unreadable pane is treated as NOT pending (fail-safe:
# the same bias the old daemon used — an unknown pane defers nothing here).
fm_pane_input_pending() {  # <target>
  [ "$(fm_tmux_composer_state "$1")" = pending ]
}

# fm_pane_is_busy: 0 if the pane's last few non-blank lines show a busy footer
# (an agent mid-turn). Scans a 40-line tail like fm-watch.sh.
# Non-blank tail depth is 12, not 6: verified empirically (gemini-cli 0.50.0)
# that gemini's footer chrome below its "Thinking..." spinner line - a
# separator, a YOLO/skill-count row, another separator, the composer
# placeholder, another separator, and a workspace/branch/sandbox/model info
# bar (header + values, 2 lines) - is 7 non-blank lines deep, which a tail -6
# window cuts the spinner line off of entirely, false-reading a genuinely busy
# gemini pane as idle. 12 covers that with margin and is a no-op risk for the
# shorter-footer harnesses (claude/codex/opencode/pi/grok), whose busy line
# already sits within the last 1-2 non-blank lines.
FM_TMUX_BUSY_TAIL_LINES=12
fm_pane_is_busy() {  # <target>
  local win=$1 tail40
  tail40=$(tmux capture-pane -p -t "$win" -S -40 2>/dev/null) || return 1
  printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -"$FM_TMUX_BUSY_TAIL_LINES" \
    | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"
}

# fm_tmux_submit_core: type <text> into <target> ONCE, then submit with Enter,
# verifying the composer cleared. Retries Enter ONLY — never retypes, because a
# swallowed Enter leaves our text in the composer and retyping would duplicate
# it. Echoes the final verdict on stdout (empty|pending|unknown|send-failed) so callers can
# pick their own success policy:
#   - the daemon clears its buffer only on "empty" (strict: an unknown pane must
#     not be mistaken for a delivered escalation).
#   - fm-send fails only on "pending" (lenient: a positively-confirmed swallow),
#     so an unreadable pane never turns a normal steer into a false error.
# DUPLICATE-SUBMIT GUARD (task fm-send-submit-fix). A retry only ever presses
# Enter again, never retypes, so it cannot concatenate text - but a retry pressed
# against a composer that no longer holds our text is a blind Enter into whatever
# the harness put there next, and the whole point of this fix is that the
# composer read CAN be wrong. So when the caller supplies <expected-pending>, the
# content the composer held right after we typed, a retry fires only while the
# row still holds EXACTLY that content: our text, still sitting there unsubmitted.
# The moment the row's content differs (our text left the composer, i.e. the
# submit landed even if it was not classified as such), the loop stops pressing
# Enter and reports `unknown` - honest ("we could not confirm"), and by
# construction incapable of producing a second turn. fm-send treats `unknown` as
# delivered (lenient: never turn a normal steer into a false error), while the
# away-mode daemon treats it as undelivered and keeps its buffer (strict).
# Without <expected-pending> the loop keeps its original retry-while-pending
# behavior.
fm_tmux_submit_enter_core() {  # <target> <retries> <enter-sleep> [expected-pending]
  local target=$1 retries=$2 sleep_s=$3 expected=${4-} guard=0 i=0 state
  [ "$#" -ge 4 ] && guard=1
  while :; do
    tmux send-keys -t "$target" Enter 2>/dev/null || true
    sleep "$sleep_s"
    fm_tmux_composer_probe "$target"
    state=$FM_TMUX_COMPOSER_STATE
    [ "$state" = pending ] || { printf '%s' "$state"; return 0; }
    if [ "$guard" = 1 ] && [ "$FM_TMUX_COMPOSER_CONTENT" != "$expected" ]; then
      # Pending, but no longer OUR text: never press Enter at it again.
      printf 'unknown'; return 0
    fi
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

fm_tmux_submit_core() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5
  tmux send-keys -t "$target" -l "$text" 2>/dev/null || { printf 'send-failed'; return 0; }
  sleep "$settle"
  # Snapshot what the composer holds now, BEFORE the first Enter: that is the
  # only content a retry may ever be pressed against (see the guard above). If
  # the typed text is not readable back as pending content (an unreadable pane, a
  # harness that hides the composer), fall back to the unguarded retry loop - it
  # only ever sends Enter, so it is no worse than before.
  fm_tmux_composer_probe "$target"
  if [ "$FM_TMUX_COMPOSER_STATE" = pending ] && [ -n "$FM_TMUX_COMPOSER_CONTENT" ]; then
    fm_tmux_submit_enter_core "$target" "$retries" "$sleep_s" "$FM_TMUX_COMPOSER_CONTENT"
    return 0
  fi
  fm_tmux_submit_enter_core "$target" "$retries" "$sleep_s"
}

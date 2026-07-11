#!/usr/bin/env bash
# Spool a captain chat message to disk BEFORE firstmate gets a turn on it.
#
# Usage (as a harness prompt-submit hook, reading the harness JSON on stdin):
#   fm-order-capture-hook.sh
# Usage (explicit text):
#   fm-order-capture-hook.sh --text 'fix the login bug'
#
# WHY THIS EXISTS. A chat request cannot be durably recorded until firstmate takes a turn,
# so the operating rule ("drain new captain requests into the inbox before any other work")
# is the primary guarantee. An instruction alone is not a mechanism: if firstmate never
# gets there, nothing on disk knows a request arrived. This hook closes that gap where the
# harness allows it. It runs at prompt submission, writes the captain's words verbatim to
# the inbox's pending spool, and exits. From that moment the message exists on disk whether
# or not firstmate ever reasons about it, and bin/fm-order-duty.sh will not stop saying so
# until the capture is either recorded as an order or explicitly dismissed with a reason.
#
# It is deliberately NOT an order. A chat turn may be an order, a reply, an approval, or
# small talk, and only firstmate can tell which. The spool holds raw captures; the drain
# turns the real requests into orders (`fm-order.sh add --from-pending <id>`) and dismisses
# the rest with a recorded reason (`fm-order.sh dismiss <id> --reason ...`).
#
# The capture id is a hash of the message text, so the SAME message replayed by a harness
# retry or a session resume produces the same capture and therefore, once drained, the same
# order - idempotency starts here rather than at the drain.
#
# INSTALL. Claude Code: a UserPromptSubmit hook in the primary's settings (see
# docs/captain-orders.md). Any harness that can run a command on prompt submit works the
# same way; a harness that cannot simply falls back to the operating rule, which is why
# this hook never blocks and always exits 0.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck disable=SC1091 # Dynamic sibling path is resolved from BASH_SOURCE.
. "$SCRIPT_DIR/fm-order-lib.sh"

TEXT=''
SOURCE=chat
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --text) TEXT=${2:-}; shift 2 ;;
    --source) SOURCE=${2:-chat}; shift 2 ;;
    *) shift ;;
  esac
done

# A hook that breaks the captain's prompt is worse than a hook that misses a capture, so
# every failure path below exits 0 and stays silent on stdout.
command -v jq >/dev/null 2>&1 || exit 0

if [ -z "$TEXT" ] && [ ! -t 0 ]; then
  RAW=$(cat 2>/dev/null || true)
  if [ -n "$RAW" ]; then
    # Harness hook payloads are JSON with the prompt under one of these keys; anything
    # else is treated as the raw prompt text.
    TEXT=$(printf '%s' "$RAW" \
      | jq -r '(.prompt // .user_prompt // .message // .text // empty)' 2>/dev/null || true)
    [ -n "$TEXT" ] || TEXT=$RAW
  fi
fi

[ -n "$TEXT" ] || exit 0

INBOX=$(fm_order_inbox_path "$FM_HOME")
PENDING_DIR=$(fm_order_pending_dir "$INBOX")
mkdir -p "$PENDING_DIR" 2>/dev/null || exit 0

HASH=$(printf '%s' "$TEXT" | fm_triage_hash | cut -c1-12)
CAPTURE_ID="cap-$HASH"
FILE="$PENDING_DIR/$CAPTURE_ID.json"

# Same text, same capture: a replayed prompt must not spool twice.
[ -f "$FILE" ] && exit 0

TMP="$FILE.tmp.$$"
if jq -cn --arg text "$TEXT" --arg ts "$(fm_triage_now)" --arg source "$SOURCE" \
  '{captured_at: $ts, source: $source, text: $text}' > "$TMP" 2>/dev/null; then
  mv -f "$TMP" "$FILE" 2>/dev/null || rm -f "$TMP" 2>/dev/null
fi
exit 0

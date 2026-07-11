#!/usr/bin/env bash
# Print the captain-order intake duty banner when the inbox is not clear.
#
# Usage:
#   fm-order-duty.sh [--trigger <turn-start|supervision|session-start>]
#
# WHY THIS EXISTS. "Drain new captain requests before any other work" is an operating
# rule, and an operating rule that nothing enforces is a rule that gets skipped exactly
# when the fleet is busiest - which is the failure this whole mechanism exists to prevent.
# So the state that the rule is supposed to produce is checked by a script instead: an
# undrained chat capture, an order still sitting untriaged, an order whose blocker cleared,
# a hold whose review date arrived, or a corrupt inbox row all raise a bordered banner on
# stderr at the moments firstmate is about to do something else (a turn's wake drain, an
# arm of silent supervision, session start).
#
# THIS COMMAND IS READ-ONLY AND NON-BLOCKING, exactly like bin/fm-guard.sh and
# bin/fm-triage-duty.sh: it reads the inbox, prints to stderr so a caller's parseable
# stdout stays byte-identical, writes nothing, and always exits 0. Silent when the inbox
# is clear, when it does not exist yet (a home that has never taken an order is not in a
# bad state), and under FM_ORDER_DUTY=off.
#
# An UNREADABLE inbox is NOT silence. A missing file is a fresh home; a file that exists
# and cannot be folded is a lost captain request, and it says so.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck disable=SC1091 # Dynamic sibling path is resolved from BASH_SOURCE.
. "$SCRIPT_DIR/fm-order-lib.sh"

TRIGGER=turn-start
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --trigger) TRIGGER=${2:-turn-start}; shift 2 ;;
    *) shift ;;
  esac
done

case "${FM_ORDER_DUTY:-on}" in off|OFF|0|false|FALSE) exit 0 ;; esac
command -v jq >/dev/null 2>&1 || exit 0

INBOX=$(fm_order_inbox_path "$FM_HOME")
PENDING_DIR=$(fm_order_pending_dir "$INBOX")

PENDING=0
if [ -d "$PENDING_DIR" ]; then
  for f in "$PENDING_DIR"/*.json; do
    [ -f "$f" ] || continue
    PENDING=$((PENDING + 1))
  done
fi

ACTIONABLE=0
MALFORMED=0
SUMMARY=''
if [ -f "$INBOX" ]; then
  if LIST=$("$SCRIPT_DIR/fm-order.sh" list --json 2>/dev/null); then
    ACTIONABLE=$(printf '%s' "$LIST" | jq -r '.metrics.actionable // 0')
    MALFORMED=$(printf '%s' "$LIST" | jq -r '.health.malformed_rows // 0')
    SUMMARY=$(printf '%s' "$LIST" | jq -r '
      [.orders[] | select(.actionable)][:5][]
      | "●    " + .order_id + " [" + (.status // "received") + " !" + .attention + "] "
        + ((.short_title // .original_request) | gsub("[[:space:]]+"; " ") | .[0:70])')
  else
    MALFORMED=-1
  fi
fi

[ "$PENDING" -eq 0 ] && [ "$ACTIONABLE" -eq 0 ] && [ "$MALFORMED" -eq 0 ] && exit 0

RULE='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
{
  printf '●%s\n' "$RULE"
  printf '●  CAPTAIN ORDER INBOX - %s\n' "$TRIGGER"
  if [ "$MALFORMED" -lt 0 ]; then
    printf '●  THE INBOX AT %s COULD NOT BE READ.\n' "$INBOX"
    printf '●  Treat this as lost captain requests, not as an empty inbox. Repair it before\n'
    printf '●  telling the captain anything about what is or is not recorded.\n'
  elif [ "$MALFORMED" -gt 0 ]; then
    printf '●  %s malformed row(s) in %s: a corrupt received row loses a captain request verbatim.\n' \
      "$MALFORMED" "$INBOX"
    printf '●  Repair or quarantine them: bin/fm-order.sh health\n'
  fi
  if [ "$PENDING" -gt 0 ]; then
    printf '●  %s captain chat message(s) captured but NOT yet drained into the inbox.\n' "$PENDING"
    printf '●  Drain them FIRST, before any other work in this turn:\n'
    printf '●      bin/fm-order.sh pending\n'
    printf '●      bin/fm-order.sh add --from-pending <capture-id>     (it is a request)\n'
    printf '●      bin/fm-order.sh dismiss <capture-id> --reason <why> (it is not)\n'
  fi
  if [ "$ACTIONABLE" -gt 0 ]; then
    printf '●  %s order(s) still need action - untriaged, ownerless, stale, missing lineage,\n' "$ACTIONABLE"
    printf '●  a cleared blocker, or an expired hold:\n'
    [ -n "$SUMMARY" ] && printf '%s\n' "$SUMMARY"
    printf '●  Triage them (bin/fm-order.sh digest), and record every disposition through\n'
    printf '●  bin/fm-order.sh - an order that was merely read is still waiting.\n'
  fi
  printf '●  Recording an order is not launching a crew: intake is unbounded, execution is not.\n'
  printf '●%s\n' "$RULE"
} >&2
exit 0

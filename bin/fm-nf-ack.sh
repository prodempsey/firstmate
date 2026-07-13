#!/usr/bin/env bash
# Acknowledge the current local terminal signal for one Needs FirstMate task.
#
# Usage:
#   fm-nf-ack.sh <id>
#   fm-nf-ack.sh --to-captain <open-item-id> <id>
#   fm-nf-ack.sh --reworking <successor-id> <id>
#
# --to-captain is the only writer of the board's captain-attention column: it is
# owed before any message asking the captain for that task's decision is written
# (AGENTS.md section 9, docs/captain-attention.md). The task must currently show
# a terminal signal (done:, blocked:, failed:, needs-decision:); a decision with
# no such card gets a captain-gated backlog item or a captain order instead.
#
# Because it is that sole writer, it also leaves a local receipt at state/.nf-to-captain
# (open_item_id, task_id, status_fingerprint, ts), appended only AFTER the Bridge write is
# read back and verified. That receipt is what lets bin/fm-guard.sh's dropped-captain-decision
# alarm prove, without calling the Bridge on every wake, that a captain-gated order actually
# reached the board - the rule above can still be skipped, and the receipt is how the skip is
# detected. It records a card the Bridge CONFIRMED, never an intent to write one: a receipt
# for a failed write would silence the very alarm that exists to catch the missing card.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LEDGER="$STATE/.nf-handled"

# shellcheck disable=SC1091 # Dynamic sibling path is resolved from BASH_SOURCE.
. "$SCRIPT_DIR/fm-nf-lib.sh"

usage() {
  cat <<'EOF'
usage:
  fm-nf-ack.sh <id>                                 record a reviewed receipt
  fm-nf-ack.sh --to-captain <open-item-id> <id>     transfer board attention to the captain
  fm-nf-ack.sh --reworking <successor-id> <id>      transfer board attention to a successor task

Record a reviewed receipt, or transfer durable board attention.

--to-captain is the only writer of the board's captain-attention column, and is
owed before any message asking the captain for that task's decision is written
(AGENTS.md section 9). The task must currently show a terminal signal: done:,
blocked:, failed:, or needs-decision:.
EOF
}

EVENT=reviewed EXTRA_NAME='' EXTRA_VALUE=''
case "${1:-}" in
  --to-captain) [ "$#" -eq 3 ] || { usage >&2; exit 2; }; EVENT=to_captain; EXTRA_NAME=open_item_id; EXTRA_VALUE=$2; ID=$3 ;;
  --reworking) [ "$#" -eq 3 ] || { usage >&2; exit 2; }; EVENT=reworking; EXTRA_NAME=successor_id; EXTRA_VALUE=$2; ID=$3 ;;
  -h|--help)
    usage
    exit 0
    ;;
esac

[ -n "${ID:-}" ] || { [ "$#" -eq 1 ] || { usage >&2; exit 2; }; ID=$1; }
case "$ID" in
  ''|*[!a-zA-Z0-9._-]*)
    printf 'fm-nf-ack: invalid task id: %s\n' "$ID" >&2
    exit 2
    ;;
esac

# The board card is keyed by HOME NAME, so a home this command cannot name is a card it
# cannot address. FM_HOME resolves the same way it does in every other bin/ script (explicit
# FM_HOME, then FM_ROOT_OVERRIDE, then this repo root), but a home that is relative, empty,
# or a filesystem root basenames into a garbage path segment, and a request to a garbage path
# comes back 404 - which an operator reads as "the board rejected the write", not "firstmate
# built a malformed URL". This command is the ONLY writer of the captain's attention column,
# so a write that fails invisibly here is precisely a dropped captain decision, the failure
# this whole path exists to prevent. Refuse loudly, and refuse before touching any state.
case "$FM_HOME" in
  /*) : ;;
  *)
    printf 'fm-nf-ack: FM_HOME must be an absolute path to a firstmate home, got: %s\n' "$FM_HOME" >&2
    exit 2
    ;;
esac
HOME_NAME=$(basename "$FM_HOME")
case "$HOME_NAME" in
  ''|.|..|/)
    printf 'fm-nf-ack: cannot derive a board home name from FM_HOME=%s; set FM_HOME to the firstmate home directory\n' "$FM_HOME" >&2
    exit 2
    ;;
esac

FINGERPRINT=$(fm_nf_current_fingerprint "$STATE" "$ID") || {
  printf 'fm-nf-ack: no current local terminal signal for %s\n' "$ID" >&2
  exit 1
}

mkdir -p "$STATE"
TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
if ! [ -f "$LEDGER" ] || ! awk -F '\t' -v id="$ID" -v fp="$FINGERPRINT" '$1==id && $2==fp {found=1} END {exit !found}' "$LEDGER"; then
  printf '%s\t%s\t%s\treviewed\n' "$ID" "$FINGERPRINT" "$TS" >> "$LEDGER"
fi
BASE=${FM_BRIDGE_URL:-http://127.0.0.1:8787}
URL="$BASE/api/card/$HOME_NAME/$ID/attention"
BODY=$(jq -nc --arg event "$EVENT" --arg fp "$FINGERPRINT" --arg actor firstmate --arg name "$EXTRA_NAME" --arg value "$EXTRA_VALUE" '{event:$event,status_fingerprint:$fp,actor:$actor} + if $name=="" then {} else {($name):$value} end')
# The URL rides in every failure message: an attention write that fails is a captain decision
# on the floor, and "it failed" without the address it failed against is not a report anyone
# can act on - a wrong home name and a down Bridge read identically otherwise.
curl -fsS -H 'content-type: application/json' -d "$BODY" "$URL" >/dev/null || { printf 'fm-nf-ack: attention API write failed (%s); task remains open\n' "$URL" >&2; exit 1; }
READBACK=$(curl -fsS "$URL") || { printf 'fm-nf-ack: attention API read-back failed (%s); task remains open\n' "$URL" >&2; exit 1; }
printf '%s' "$READBACK" | jq -e --arg event "$EVENT" --arg value "$EXTRA_VALUE" --arg name "$EXTRA_NAME" '.event==$event and ($name=="" or .[$name]==$value)' >/dev/null || { echo "fm-nf-ack: attention API read-back mismatch; task remains open" >&2; exit 1; }
# Local receipt for a CONFIRMED needs_human card, per the header. Written last, so nothing
# reaches it that the Bridge did not read back.
if [ "$EVENT" = to_captain ]; then
  printf '%s\t%s\t%s\t%s\n' "$EXTRA_VALUE" "$ID" "$FINGERPRINT" "$TS" >> "$STATE/.nf-to-captain"
fi
printf 'still open; %s receipt recorded for %s at %s\n' "$EVENT" "$ID" "$TS"

#!/usr/bin/env bash
# Acknowledge the current local terminal signal for one Needs FirstMate task.
#
# Usage:
#   fm-nf-ack.sh <id>
#   fm-nf-ack.sh --to-captain <open-item-id> <id>
#   fm-nf-ack.sh --reworking <successor-id> <id>
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
usage: fm-nf-ack.sh <id>

Record a reviewed receipt, or transfer durable board attention.
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

FINGERPRINT=$(fm_nf_current_fingerprint "$STATE" "$ID") || {
  printf 'fm-nf-ack: no current local terminal signal for %s\n' "$ID" >&2
  exit 1
}

mkdir -p "$STATE"
TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
if ! [ -f "$LEDGER" ] || ! awk -F '\t' -v id="$ID" -v fp="$FINGERPRINT" '$1==id && $2==fp {found=1} END {exit !found}' "$LEDGER"; then
  printf '%s\t%s\t%s\treviewed\n' "$ID" "$FINGERPRINT" "$TS" >> "$LEDGER"
fi
BASE=${FM_BRIDGE_URL:-http://127.0.0.1:7447}
URL="$BASE/api/card/$(basename "$FM_HOME")/$ID/attention"
BODY=$(jq -nc --arg event "$EVENT" --arg fp "$FINGERPRINT" --arg actor firstmate --arg name "$EXTRA_NAME" --arg value "$EXTRA_VALUE" '{event:$event,status_fingerprint:$fp,actor:$actor} + if $name=="" then {} else {($name):$value} end')
curl -fsS -H 'content-type: application/json' -d "$BODY" "$URL" >/dev/null || { echo "fm-nf-ack: attention API write failed; task remains open" >&2; exit 1; }
READBACK=$(curl -fsS "$URL") || { echo "fm-nf-ack: attention API read-back failed; task remains open" >&2; exit 1; }
printf '%s' "$READBACK" | jq -e --arg event "$EVENT" --arg value "$EXTRA_VALUE" --arg name "$EXTRA_NAME" '.event==$event and ($name=="" or .[$name]==$value)' >/dev/null || { echo "fm-nf-ack: attention API read-back mismatch; task remains open" >&2; exit 1; }
printf 'still open; %s receipt recorded for %s at %s\n' "$EVENT" "$ID" "$TS"

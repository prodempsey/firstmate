#!/usr/bin/env bash
# Acknowledge the current local terminal signal for one Needs FirstMate task.
#
# Usage:
#   fm-nf-ack.sh <id>
#   fm-nf-ack.sh --to-captain <id>       Phase 2 stub only.
#   fm-nf-ack.sh --reworking <new-id> <id>  Phase 2 stub only.
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

Record the task's current local terminal-signal fingerprint as handled.
--to-captain and --reworking are reserved Phase 2 board-ownership stubs.
EOF
}

case "${1:-}" in
  --to-captain)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    printf 'fm-nf-ack: --to-captain is a Phase 2 stub; no acknowledgement or board re-ownership was recorded\n' >&2
    exit 2
    ;;
  --reworking)
    [ "$#" -eq 3 ] || { usage >&2; exit 2; }
    printf 'fm-nf-ack: --reworking is a Phase 2 stub; no acknowledgement or board re-ownership was recorded\n' >&2
    exit 2
    ;;
  -h|--help)
    usage
    exit 0
    ;;
esac

[ "$#" -eq 1 ] || { usage >&2; exit 2; }
ID=$1
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
KEY=$(printf '%s\t%s' "$ID" "$FINGERPRINT")
if [ -f "$LEDGER" ] && grep -Fqx -- "$KEY" "$LEDGER" 2>/dev/null; then
  printf 'acknowledged: %s %s\n' "$ID" "$FINGERPRINT"
  exit 0
fi
printf '%s\n' "$KEY" >> "$LEDGER"
printf 'acknowledged: %s %s\n' "$ID" "$FINGERPRINT"

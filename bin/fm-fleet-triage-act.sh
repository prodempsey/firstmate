#!/usr/bin/env bash
# Apply the ONE fully-mechanical fleet-triage auto-action: unblock backlog items whose
# blocker the enumerator has already proven done.
#
# Usage:
#   fm-fleet-triage-act.sh unblock             Dry run (default): print what would unblock.
#   fm-fleet-triage-act.sh unblock --apply     Run `tasks-axi unblock <id> --by <blocker>`
#                                              for each candidate, then record the
#                                              disposition through fm-fleet-triage-record.sh.
#
# WHY EXACTLY ONE ACTION LIVES HERE. A `backlog_hygiene` item with status `blocker_done`
# is the only triage candidate whose correction is mechanically known: the enumerator
# computed, purely from data/backlog.md structure, that the row's blocker is done, and
# `tasks-axi unblock` is the sanctioned, reversible verb for exactly that correction.
# Every other lane needs a judgment call firstmate must make first - matching a bug to
# its evidence, judging a report superseded, weighing dispatch scope and overlap - so no
# other subcommand is added here. This script decides nothing: it executes a correction
# the enumerator already proved, and records that it did.
#
# The recorded outcome is `resolved`, linked to the completed blocker and bound to the
# evidence version the candidate was enumerated with. The unblocked row then re-surfaces
# on the next scan as `ready` with health `evidence_changed`, which is correct: whether
# to DISPATCH the newly-ready item is firstmate's judgment, never this script's.
#
# --apply refuses without the per-home session lock, refuses under
# FLEET_TRIAGE_MODE=enumerate_only, and refuses when the tasks-axi backlog backend is
# unavailable (config/backlog-backend=manual, or tasks-axi missing or incompatible):
# the safety case for acting unattended IS the sanctioned CLI verb, so there is no
# hand-edit fallback. The dry run is read-only and needs none of those.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck disable=SC1091 # Dynamic sibling path is resolved from BASH_SOURCE.
. "$SCRIPT_DIR/fm-fleet-triage-lib.sh"
# shellcheck disable=SC1091 # Dynamic sibling path is resolved from BASH_SOURCE.
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

usage() {
  cat <<'EOF'
usage: fm-fleet-triage-act.sh unblock [--dry-run|--apply]

Unblock backlog_hygiene items whose blocker the fleet-triage enumerator has proven done,
via `tasks-axi unblock <id> --by <blocker>`, recording each disposition through
bin/fm-fleet-triage-record.sh. This is the single sanctioned mechanical auto-action;
every other triage lane needs firstmate's judgment first and is acted on through the
owning domain interface directly, then recorded.

The dry run is the default and changes nothing. --apply executes, and requires the
per-home session lock, an active (not enumerate_only) triage mode, and an available
tasks-axi backlog backend.
EOF
}

die() {
  printf 'fm-fleet-triage-act: %s\n' "$1" >&2
  exit "${2:-1}"
}

ACTION=${1:-}
case "$ACTION" in
  -h|--help) usage; exit 0 ;;
  unblock) shift ;;
  '') usage >&2; exit 2 ;;
  *) usage >&2; die "unknown action: $ACTION" 2 ;;
esac

APPLY=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=true; shift ;;
    --dry-run) APPLY=false; shift ;;
    *) usage >&2; die "unknown option: $1" 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || die 'jq not found'

if [ "$APPLY" = true ]; then
  fm_triage_enumerate_only \
    && die 'refused: FLEET_TRIAGE_MODE=enumerate_only forbids domain actions; run the dry run instead'
  fm_triage_owns_lock "$STATE" \
    || die 'refused: this session does not own the fleet session lock; only the locked primary may unblock backlog items'
  fm_tasks_axi_backend_available "$CONFIG" \
    || die 'refused: the tasks-axi backlog backend is unavailable (config/backlog-backend=manual, or tasks-axi missing or incompatible); unblock by hand and record the outcome with fm-fleet-triage-record.sh'
fi

TRIAGE_JSON=$("$SCRIPT_DIR/fm-fleet-triage.sh" --json) \
  || die 'could not enumerate current triage items'

# Only ACTIONABLE blocker_done items qualify: one already dispositioned (a hold, a
# rejection) was a deliberate firstmate decision this script must not override.
CANDIDATES=$(printf '%s' "$TRIAGE_JSON" | jq -r '
  .items[]
  | select(.lane == "backlog_hygiene" and .status == "blocker_done" and .actionable == true)
  | select((.blocked_by // "") != "")
  | [.id, .blocked_by, .item_id, .evidence_version] | @tsv')

if [ -z "$CANDIDATES" ]; then
  printf 'nothing to unblock: no actionable blocker_done items\n'
  exit 0
fi

FAILED=0
COUNT=0
while IFS=$'\t' read -r id blocker item_id ev; do
  [ -n "$id" ] || continue
  COUNT=$((COUNT + 1))
  if [ "$APPLY" != true ]; then
    printf 'would unblock: %s --by %s (%s)\n' "$id" "$blocker" "$item_id"
    continue
  fi
  if ! tasks-axi unblock "$id" --by "$blocker"; then
    printf 'fm-fleet-triage-act: tasks-axi unblock %s --by %s failed; leaving %s actionable\n' \
      "$id" "$blocker" "$item_id" >&2
    FAILED=1
    continue
  fi
  printf 'unblocked: %s --by %s\n' "$id" "$blocker"
  # Record only after the domain action is durable, bound to the evidence the candidate
  # was enumerated with: the post-unblock evidence has already moved to `ready`, and that
  # move is exactly what re-surfaces the item for firstmate's dispatch judgment.
  if ! "$SCRIPT_DIR/fm-fleet-triage-record.sh" resolve "$item_id" \
    --link "$blocker" \
    --reason "blocker $blocker is done; unblocked mechanically via tasks-axi unblock" \
    --evidence-version "$ev"; then
    printf 'fm-fleet-triage-act: %s was unblocked but its disposition could not be recorded; record it with fm-fleet-triage-record.sh resolve %s --link %s\n' \
      "$item_id" "$item_id" "$blocker" >&2
    FAILED=1
  fi
done <<EOF
$CANDIDATES
EOF

if [ "$APPLY" != true ]; then
  printf 'dry run: %s item(s) would be unblocked; re-run with --apply to execute\n' "$COUNT"
fi
exit "$FAILED"

#!/usr/bin/env bash
# Record one fleet-triage processing or lineage event. This is the ONLY sanctioned
# writer of the triage processing ledger (data/fleet-triage.jsonl).
#
# Usage:
#   fm-fleet-triage-record.sh surface <item-id>...        Stamp first sight, durably.
#   fm-fleet-triage-record.sh surface --all               Stamp every ACTIONABLE item.
#   fm-fleet-triage-record.sh claim <item-id> --owner <who>
#   fm-fleet-triage-record.sh release <item-id> [--reason <why>]
#   fm-fleet-triage-record.sh successor <item-id> --link <task-id> [--reason <note>]
#   fm-fleet-triage-record.sh resolve <item-id> --link <evidence-ref> [--reason <note>]
#   fm-fleet-triage-record.sh reject <item-id> --reason <why>
#   fm-fleet-triage-record.sh hold <item-id> --reason <why> --review-after <when>
#   fm-fleet-triage-record.sh captain-batch <item-id> --link <batch-id>
#
# TERMINAL OUTCOMES REQUIRE LINEAGE. This command refuses to record a terminal outcome
# without it, which is what stops an item from being "handled" merely because it was
# printed, seen, or acknowledged. successor_created, resolved, and captain_batch need
# --link; rejected needs --reason; held needs both --reason and --review-after.
# There is deliberately no acknowledge verb: an acknowledgement is not an outcome.
#
# Events set fields, and an explicit null IS a set: the fold accumulates, so a terminal
# outcome clears the claim it ends, and a surface clears the disposition it re-opens.
# Clearing applies only to the folded CURRENT state; the ledger keeps every event verbatim.
#
# Writes are refused unless this session owns the per-home session lock, and refused
# entirely under FLEET_TRIAGE_MODE=enumerate_only.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck disable=SC1091 # Dynamic sibling path is resolved from BASH_SOURCE.
. "$SCRIPT_DIR/fm-fleet-triage-lib.sh"

LEDGER=$(fm_triage_ledger_path "$DATA")

usage() {
  sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'fm-fleet-triage-record: %s\n' "$1" >&2
  exit "${2:-1}"
}

command -v jq >/dev/null 2>&1 || die 'jq not found'

EVENT=${1:-}
case "$EVENT" in
  -h|--help|'') usage; exit 0 ;;
  surface|claim|release|successor|resolve|reject|hold|captain-batch) shift ;;
  *) usage >&2; die "unknown event: $EVENT" 2 ;;
esac

ALL=false
OWNER=''
LINK=''
REASON=''
REVIEW_AFTER=''
EVIDENCE_VERSION=''
ITEMS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --all) ALL=true; shift ;;
    --owner) [ "$#" -ge 2 ] || die 'missing value for --owner' 2; OWNER=$2; shift 2 ;;
    --link) [ "$#" -ge 2 ] || die 'missing value for --link' 2; LINK=$2; shift 2 ;;
    --reason) [ "$#" -ge 2 ] || die 'missing value for --reason' 2; REASON=$2; shift 2 ;;
    --review-after) [ "$#" -ge 2 ] || die 'missing value for --review-after' 2; REVIEW_AFTER=$2; shift 2 ;;
    --evidence-version) [ "$#" -ge 2 ] || die 'missing value for --evidence-version' 2; EVIDENCE_VERSION=$2; shift 2 ;;
    -*) usage >&2; die "unknown option: $1" 2 ;;
    *) ITEMS+=("$1"); shift ;;
  esac
done

# --- Kill switch and lock: refuse to mutate anything before doing any work. --------
fm_triage_enumerate_only \
  && die 'refused: FLEET_TRIAGE_MODE=enumerate_only forbids ledger writes and domain actions'

fm_triage_owns_lock "$STATE" \
  || die 'refused: this session does not own the fleet session lock; only the locked primary may claim or record outcomes'

# --- Outcome and lineage contract. -------------------------------------------------
outcome_for() {  # <event>
  case "$1" in
    successor) printf 'successor_created' ;;
    resolve) printf 'resolved' ;;
    reject) printf 'rejected' ;;
    hold) printf 'held' ;;
    captain-batch) printf 'captain_batch' ;;
    *) return 1 ;;
  esac
}

PROCESSING_STATE=''
OUTCOME=''
if OUTCOME=$(outcome_for "$EVENT"); then
  case "$(fm_triage_outcome_requires "$OUTCOME")" in
    link)
      [ -n "$LINK" ] \
        || die "refused: outcome '$OUTCOME' requires --link naming its lineage; an outcome without a link is not a disposition"
      ;;
    reason)
      [ -n "$REASON" ] \
        || die "refused: outcome '$OUTCOME' requires --reason"
      ;;
    hold)
      [ -n "$REASON" ] || die 'refused: a hold requires --reason'
      [ -n "$REVIEW_AFTER" ] \
        || die 'refused: a hold requires --review-after (a date or an explicit unblock condition); silent indefinite holds are not allowed'
      ;;
  esac
  PROCESSING_STATE=terminal
  [ "$OUTCOME" = held ] && PROCESSING_STATE=held
else
  OUTCOME=''
  case "$EVENT" in
    surface) PROCESSING_STATE=surfaced ;;
    claim)
      [ -n "$OWNER" ] || die 'refused: claim requires --owner'
      PROCESSING_STATE=claimed
      ;;
    release) PROCESSING_STATE=surfaced ;;
  esac
fi

# --- Resolve the item set and its current evidence versions. -----------------------
# An outcome is bound to the evidence it was decided against, so a later scan can tell
# that the evidence moved and invalidate the stale processing assumption.
TRIAGE_JSON=''
load_triage() {
  [ -n "$TRIAGE_JSON" ] && return 0
  TRIAGE_JSON=$("$SCRIPT_DIR/fm-fleet-triage.sh" --json) \
    || die 'could not enumerate current triage items'
}

# --all stamps first sight of the items that still need one, which is every ACTIONABLE
# item. It deliberately skips items that are already dispositioned and healthy: a surface
# re-opens an item and clears the disposition it is re-opening, so a blanket --all across
# every enumerated item would resurrect settled work on each pass - and this command is
# meant to be safe to run on a schedule. Re-opening a finished item is a deliberate act;
# it needs an explicit `surface <item-id>`.
if [ "$ALL" = true ]; then
  [ "$EVENT" = surface ] || die '--all is only supported for the surface event' 2
  load_triage
  while IFS= read -r id; do
    [ -n "$id" ] && ITEMS+=("$id")
  done < <(printf '%s' "$TRIAGE_JSON" | jq -r '.items[] | select(.actionable) | .item_id')
  [ "${#ITEMS[@]}" -gt 0 ] || { printf 'nothing to surface: no actionable items\n'; exit 0; }
fi

[ "${#ITEMS[@]}" -gt 0 ] || die 'no item id given' 2

mkdir -p "$DATA"
NOW=$(fm_triage_now)
DECIDED_BY=${FM_TRIAGE_ACTOR:-firstmate}

for item in "${ITEMS[@]}"; do
  case "$item" in
    *:*) : ;;
    *) die "invalid item id (expected <lane>:<source-id>): $item" 2 ;;
  esac

  ev=$EVIDENCE_VERSION
  if [ -z "$ev" ]; then
    load_triage
    ev=$(printf '%s' "$TRIAGE_JSON" \
      | jq -r --arg id "$item" '(.items[] | select(.item_id == $id) | .evidence_version) // empty')
    # release is the one verb allowed on evidence that has already gone away: it exists
    # precisely to let go of a claim on a vanished item.
    if [ -z "$ev" ] && [ "$EVENT" != release ]; then
      die "refused: $item is not currently enumerated; its evidence no longer exists, so an outcome recorded against it would be dangling"
    fi
  fi

  jq -cn \
    --arg schema 'firstmate/fleet-triage-item/v1' \
    --arg item_id "$item" \
    --arg event "$EVENT" \
    --arg processing_state "$PROCESSING_STATE" \
    --arg evidence_version "$ev" \
    --arg ts "$NOW" \
    --arg owner "$OWNER" \
    --arg outcome_type "$OUTCOME" \
    --arg outcome_link "$LINK" \
    --arg outcome_reason "$REASON" \
    --arg review_after "$REVIEW_AFTER" \
    --arg decided_by "$DECIDED_BY" '
    {schema: $schema, item_id: $item_id, event: $event, ts: $ts}
    + (if $processing_state == "" then {} else {processing_state: $processing_state} end)
    + (if $evidence_version == "" then {} else {evidence_version: $evidence_version} end)
    # An event carries only the keys it means to set, and an explicit null IS the update:
    # the fold accumulates, so a null overwrites a field where an absent key would leave
    # the previous value standing. `release` has always relied on that to clear a claim.
    #
    # A surface RE-OPENS an item, so it must also clear the disposition it is re-opening.
    # Without this a re-surfaced item still advertised outcome_type "resolved" with a
    # live-looking link and decision date, and kept the owner of the crew that finished and
    # left - a phantom that excluded it from the ownerless metric, so firstmate believed
    # someone was on it. Only the FOLDED CURRENT STATE is cleared; every prior event stays
    # in the append-only ledger verbatim, which is where the history belongs.
    + (if $event == "surface"
       then {first_seen_at: $ts,
             outcome_type: null, outcome_link: null, outcome_reason: null,
             decided_at: null, decided_by: null, review_after: null}
       else {} end)
    + (if $event == "claim" then {owner: $owner, claimed_at: $ts} else {} end)
    + (if $event == "release" then {owner: null, claimed_at: null} else {} end)
    # A terminal outcome ends the work, so it ends the claim with it. Otherwise an item
    # folded to terminal AND actively claimed at once, which is not a state the fleet can
    # be in. A hold is deliberately excluded: it parks work that still has an owner.
    + (if $processing_state == "terminal" then {owner: null, claimed_at: null} else {} end)
    + (if $outcome_type == "" then {}
       else {outcome_type: $outcome_type, decided_by: $decided_by, decided_at: $ts} end)
    + (if $outcome_link == "" then {} else {outcome_link: $outcome_link} end)
    + (if $outcome_reason == "" then {} else {outcome_reason: $outcome_reason} end)
    + (if $review_after == "" then {} else {review_after: $review_after} end)
  ' >> "$LEDGER"

  printf 'recorded: %s %s' "$EVENT" "$item"
  [ -n "$OUTCOME" ] && printf ' -> %s' "$OUTCOME"
  [ -n "$LINK" ] && printf ' (%s)' "$LINK"
  printf '\n'
done

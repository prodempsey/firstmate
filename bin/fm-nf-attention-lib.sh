#!/usr/bin/env bash
# Shared owner of one decision: given the recorded fleet-triage disposition of a
# needs_firstmate item, what should that task's Fleet Bridge card be presenting?
#
# The triage ledger (data/fleet-triage.jsonl) records WHAT firstmate decided. The board
# records what still WANTS firstmate. Nothing used to connect them, so a reviewed,
# dispositioned, even landed task kept presenting as an active Needs FirstMate card until
# teardown ran. This library is the missing connection, and it is the one place the mapping
# is decided; bin/fm-nf-attention.sh applies it and bin/fm-nf-reconcile.sh reports it.
#
# ATTENTION IS NOT CLOSURE. A cleared card says "firstmate dispositioned this"; it never
# writes closure evidence, never closes a durable TaskRecord, and never removes a task from
# `visibility audit`. A task with no closure evidence stays un-closable and stays in the
# audit. Closure remains teardown's job, through bin/fm-task-events.sh.
#
# Every desired state is bound to the EVIDENCE the disposition was decided against, exactly
# as the enumerator's self-audit is: a new status line mints a new evidence version, so a
# stale disposition can never suppress a fresh terminal signal.

_FM_NF_ATTENTION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091 # Dynamic sibling path is resolved from BASH_SOURCE.
. "$_FM_NF_ATTENTION_LIB_DIR/fm-nf-lib.sh"
# shellcheck disable=SC1091 # Dynamic sibling path is resolved from BASH_SOURCE.
. "$_FM_NF_ATTENTION_LIB_DIR/fm-fleet-triage-lib.sh"

# Print the folded triage ledger for one home's data dir. Callers fold once and reuse.
fm_nf_attention_fold() {  # <data-dir>
  fm_triage_fold "$(fm_triage_ledger_path "$1")"
}

# Print the needs_firstmate evidence version for one live terminal signal.
# Only the structured fields the lane's evidence version names participate, so this is the
# same hash fm-fleet-triage.sh computes for the same item and the two can never disagree.
fm_nf_attention_evidence_version() {  # <task-id> <fingerprint>
  jq -cn --arg id "$1" --arg fp "$2" \
    '{lane: "needs_firstmate", id: $id, source_fingerprint: $fp}' \
    | fm_triage_evidence_version
}

# True when a terminal outcome carries the lineage its type requires. Mirrors the
# enumerator's dangling_outcome check, delegating the contract itself to its one owner.
fm_nf_attention_lineage_ok() {  # <outcome> <link> <reason> <review-after>
  local requires
  requires=$(fm_triage_outcome_requires "$1" 2>/dev/null) || return 1
  case "$requires" in
    link) [ -n "$2" ] ;;
    reason) [ -n "$3" ] ;;
    hold) [ -n "$3" ] && [ -n "$4" ] ;;
    *) return 1 ;;
  esac
}

# True when a hold's review date has arrived, read through the ONE review-date parser
# (fm_triage_review_epoch), so this and the enumerator's health ladder can never disagree
# about whether a hold has come due. A review date no clock can read is handled by the
# caller below, and it does NOT leave the hold standing: an unexpirable hold is a mute
# button, which the enumerator fails back into the queue as hold_unreviewable.
fm_nf_attention_hold_expired() {  # <review-after>
  local epoch now
  epoch=$(fm_triage_review_epoch "$1" 2>/dev/null) || return 1
  now=$(date -u +%s)
  [ "$now" -ge "$epoch" ]
}

# True when the successor task named by a successor_created outcome still exists in this
# home, as a live task or as a backlog row. A successor that vanished makes the disposition
# a lie, so the item is owed firstmate's attention again - the enumerator calls the same
# condition successor_missing.
fm_nf_attention_successor_present() {  # <state-dir> <data-dir> <link>
  local state=$1 data=$2 link=$3
  [ -n "$link" ] || return 1
  [ -f "$state/$link.meta" ] && return 0
  [ -f "$data/backlog.md" ] && grep -qF -- "$link" "$data/backlog.md" && return 0
  return 1
}

# Print the desired board attention for one task as compact JSON:
#   {state, outcome, link, reason, review_after, fingerprint, evidence_version, why}
# where state is one of:
#   terminal - dispositioned and still healthy; the card must stop asking for firstmate.
#   held     - parked with a reason and a review date; the card stays visible, but as held.
#   open     - never dispositioned, or the disposition no longer holds (evidence moved, the
#              hold expired, the lineage dangles, the successor is gone). The natural signal
#              owns the card, which is also the fail-safe direction for anything unknown.
fm_nf_attention_desired() {  # <state-dir> <data-dir> <task-id> <fold-json>
  local state=$1 data=$2 id=$3 fold=$4
  local fp entry outcome recorded_ev link reason review_after ev='' want=open why=''

  fp=$(fm_nf_current_fingerprint "$state" "$id" 2>/dev/null) || fp=''
  entry=$(printf '%s' "$fold" | jq -c --arg k "needs_firstmate:$id" '.[$k] // {}')
  outcome=$(printf '%s' "$entry" | jq -r '.outcome_type // ""')
  recorded_ev=$(printf '%s' "$entry" | jq -r '.evidence_version // ""')
  link=$(printf '%s' "$entry" | jq -r '.outcome_link // ""')
  reason=$(printf '%s' "$entry" | jq -r '.outcome_reason // ""')
  review_after=$(printf '%s' "$entry" | jq -r '.review_after // ""')

  if [ -z "$fp" ]; then
    why='no live terminal signal'
  elif [ -z "$outcome" ]; then
    why='never dispositioned'
  else
    ev=$(fm_nf_attention_evidence_version "$id" "$fp")
    if [ "$recorded_ev" != "$ev" ]; then
      why='evidence changed since the disposition was recorded'
    elif ! fm_nf_attention_lineage_ok "$outcome" "$link" "$reason" "$review_after"; then
      why="dangling outcome: $outcome is missing the lineage it requires"
    else
      case "$outcome" in
        held)
          if ! fm_triage_review_date_ok "$review_after"; then
            # A hold whose review date cannot be read can never come due, so it is not a
            # disposition - it is silence with paperwork, and the item is still open. The
            # writer refuses these now; this catches legacy rows, mirroring the
            # enumerator's hold_unreviewable.
            why="hold review date cannot be read ($review_after)"
          elif fm_nf_attention_hold_expired "$review_after"; then
            why="hold expired (review after $review_after)"
          else
            want=held
            why="held until $review_after"
          fi
          ;;
        successor_created)
          if fm_nf_attention_successor_present "$state" "$data" "$link"; then
            want=terminal
            why="reworking in successor $link"
          else
            why="successor $link no longer exists"
          fi
          ;;
        resolved|rejected|captain_batch)
          want=terminal
          why=$outcome
          ;;
        *)
          why="unrecognized outcome: $outcome"
          ;;
      esac
    fi
  fi

  jq -cn --arg state "$want" --arg outcome "$outcome" --arg link "$link" \
    --arg reason "$reason" --arg review_after "$review_after" \
    --arg fingerprint "$fp" --arg evidence_version "$ev" --arg why "$why" \
    '{state: $state, outcome: $outcome, link: $link, reason: $reason,
      review_after: $review_after, fingerprint: $fingerprint,
      evidence_version: $evidence_version, why: $why}'
}

# Print the id of every UNATTENDED needs_firstmate item in a home, one per line. Unattended
# means exactly what fm_nf_attention_desired above calls `open`: a live terminal signal
# (done/blocked/failed/needs-decision) that firstmate has never dispositioned, or whose
# recorded disposition no longer holds. That decision stays owned by fm_nf_attention_desired;
# this is only the sweep over the home.
#
# LEVEL-TRIGGERED, DIRECT FROM SOURCE. It reads state/<id>.meta plus state/<id>.status and
# the triage ledger, every call. It reads no cached summary of them - a cache reflects the
# last duty pass, not the present, so a gate built on one both misses fresh work and blocks
# on work already discharged. This is what bin/fm-turnend-guard.sh gates the turn end on,
# and the same per-item decision bin/fm-nf-reconcile.sh reports as unhandled; nothing about
# "is this work unattended" is decided anywhere else.
fm_nf_unattended_ids() {  # <state-dir> <data-dir>
  local state=$1 data=$2 fold meta id
  [ -d "$state" ] || return 1
  fold=$(fm_nf_attention_fold "$data") || return 1
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    # No live terminal signal (still working, or a secondmate) - nothing is owed.
    fm_nf_current_fingerprint "$state" "$id" >/dev/null 2>&1 || continue
    [ "$(fm_nf_attention_desired "$state" "$data" "$id" "$fold" \
      | jq -r '.state' 2>/dev/null)" = open ] || continue
    printf '%s\n' "$id"
  done
}

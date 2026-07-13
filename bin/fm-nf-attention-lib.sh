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

# True when a captain hand-off actually reached the board. bin/fm-nf-ack.sh appends to
# state/.nf-to-captain only AFTER the Bridge reads the card back, so a receipt for this task
# against THIS evidence is the one durable proof the captain can see the decision. Without it
# the hand-off is still owed, and firstmate - not the captain - is who owes it.
fm_nf_attention_captain_confirmed() {  # <state-dir> <task-id> <fingerprint>
  local receipts="$1/.nf-to-captain"
  [ -f "$receipts" ] || return 1
  [ -n "$3" ] || return 1
  awk -F '\t' -v id="$2" -v fp="$3" '$2 == id && $3 == fp {found = 1} END {exit !found}' "$receipts"
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
#   {state, outcome, link, reason, review_after, fingerprint, evidence_version, confirmed, why}
# where confirmed says whether a captain hand-off actually reached the board, and state is one
# of:
#   terminal - firstmate is FINISHED with it (resolved, rejected, reworking in a successor);
#              the card must stop asking for firstmate.
#   captain  - firstmate is not finished with it, but the captain is: a captain batch does not
#              end the decision, it TRANSFERS it. The card must stay visible and land in the
#              captain's column, so this state clears nothing - clearing it is what silently
#              dropped decisions the captain still owed.
#   held     - parked with a reason and a review date; the card stays visible, but as held.
#   open     - never dispositioned, or the disposition no longer holds (evidence moved, the
#              hold expired, the lineage dangles, the successor is gone). The natural signal
#              owns the card, which is also the fail-safe direction for anything unknown.
#
# The outcome TYPE decides which of those it is. A terminal outcome is not automatically a
# cleared card: only an outcome that means firstmate is done with the work may clear one.
fm_nf_attention_desired() {  # <state-dir> <data-dir> <task-id> <fold-json>
  local state=$1 data=$2 id=$3 fold=$4
  local fp entry outcome recorded_ev link reason review_after ev='' want=open why=''
  local confirmed=false

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
        captain_batch)
          # The decision is still owed; it is simply owed by the captain now. Presenting this
          # as terminal is what made the card vanish from his board.
          want=captain
          if fm_nf_attention_captain_confirmed "$state" "$id" "$fp"; then
            confirmed=true
            why="handed to the captain in $link"
          else
            # Recorded, but the board never confirmed the card. The captain cannot see a
            # decision that never reached him, so this stays firstmate's to finish.
            why="hand-off to the captain not confirmed on the board (batch $link)"
          fi
          ;;
        resolved|rejected)
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
    --argjson confirmed "$confirmed" \
    '{state: $state, outcome: $outcome, link: $link, reason: $reason,
      review_after: $review_after, fingerprint: $fingerprint,
      evidence_version: $evidence_version, confirmed: $confirmed, why: $why}'
}

# True for the TURN-END GATE when a captain_batch hand-off verifiably reached the captain's
# board for this task's CURRENT terminal signal. bin/fm-nf-ack.sh --to-captain appends to
# state/.nf-to-captain (open_item_id, task_id, status_fingerprint, ts) only AFTER the Bridge
# write is read back and verified, and the receipt binds the fingerprint, so a fresh
# terminal signal re-opens the gate no matter what was acknowledged before. This is the
# gate's own check of that lifecycle evidence; the BOARD-side presentation of a captain
# batch stays owned elsewhere (see captain-batch-drop-b6) and is deliberately not decided
# here.
#
# The predicate itself is fm_nf_attention_captain_confirmed above - ONE reading of the receipt
# ledger, so the gate and the board card can never disagree about whether the captain can
# actually see a decision. The two names are kept because they answer different questions of
# the same evidence: this one asks whether the GATE is discharged, that one asks what the CARD
# should present.
fm_nf_unattended_captain_confirmed() {  # <state-dir> <task-id> <fingerprint>
  fm_nf_attention_captain_confirmed "$@"
}

# Print the id of every needs_firstmate item that still holds the TURN-END GATE, one per
# line. The per-item classification stays owned by fm_nf_attention_desired above; this is
# only the sweep over the home, plus the gate's own discharge rule (ORD-060 section 2):
#
#   The gate is discharged ONLY by real lifecycle changes: the work landing and the task
#   tearing down (its meta/status leave state/); the crew's status moving off a terminal
#   verb (a steer to `paused:`, a `resolved:` follow-up, a relaunch); a genuine terminal
#   disposition - `resolved` or `rejected` with valid lineage against current evidence; or
#   a captain decision VERIFIABLY transferred to the captain's still-visible Needs You
#   column (a captain_batch outcome whose board hand-off is confirmed by the
#   fingerprint-bound receipt above) - so the primary stops re-blocking on work only the
#   captain can decide, while the decision itself cannot disappear through a mere
#   acknowledgment or ledger row.
#
#   Everything else keeps blocking, deliberately: an ack receipt, a re-surface, a claim, a
#   `hold` (even a valid dated one - it parks the BOARD CARD, never this gate),
#   `successor_created`, and an UNCONFIRMED `captain_batch`. Those are paper moves; the
#   incident this gate exists for was eight holds recorded in 137 seconds to mute the
#   lane, and a captain_batch row silently vanishing a decision
#   (bug-20260713154240-10d127e0). The gate is therefore stricter than
#   bin/fm-nf-reconcile.sh's "unhandled" count, which reports held and dispositioned items
#   separately for the board.
#
# LEVEL-TRIGGERED, DIRECT FROM SOURCE. It reads state/<id>.meta plus state/<id>.status and
# the triage ledger, every call. It reads no cached summary of them - a cache reflects the
# last duty pass, not the present, so a gate built on one both misses fresh work and blocks
# on work already discharged. This is what bin/fm-turnend-guard.sh gates the turn end on.
fm_nf_unattended_ids() {  # <state-dir> <data-dir>
  local state=$1 data=$2 fold meta id fp desired want outcome
  [ -d "$state" ] || return 1
  fold=$(fm_nf_attention_fold "$data") || return 1
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    # No live terminal signal (still working, or a secondmate) - nothing is owed.
    fp=$(fm_nf_current_fingerprint "$state" "$id" 2>/dev/null) || continue
    desired=$(fm_nf_attention_desired "$state" "$data" "$id" "$fold") || continue
    want=$(printf '%s' "$desired" | jq -r '.state' 2>/dev/null) || continue
    outcome=$(printf '%s' "$desired" | jq -r '.outcome' 2>/dev/null) || continue
    if [ "$outcome" = captain_batch ] \
      && fm_nf_unattended_captain_confirmed "$state" "$id" "$fp"; then
      continue
    fi
    if [ "$want" = terminal ]; then
      case "$outcome" in
        resolved|rejected) continue ;;
      esac
    fi
    printf '%s\n' "$id"
  done
}

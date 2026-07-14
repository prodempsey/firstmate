#!/usr/bin/env bash
# Anti-evasion metrics for the primary turn-end guard (docs/turnend-guard.md, ORD-060
# section 8). READ-ONLY: folds the guard's decision log and the live needs_firstmate lane
# into the counters that tell whether the gate is enforcing or being evaded. It mutates
# nothing and is safe to run from any session.
#
# Two panels:
#
#   CUMULATIVE (state/.turnend-guard.log, since last trim) - every guard decision counted
#   by outcome, plus the one aggregate that IS the acceptance metric's complement:
#   permits_with_unattended_work, the number of permitted turn ends recorded while the
#   lane counted > 0 (loop-protection, guard-error, kill-switch, and afk permits all land
#   here; allowed_after_valid_progress does too when work remained). The primary success
#   metric is that ordinary permits among these stay at zero.
#
#   LIVE (state/<id>.meta + status + the triage ledger, right now):
#     unattended            items currently holding the gate (fm_nf_unattended_ids).
#     paper_parked          items whose terminal signal REMAINS while a non-discharging
#                           disposition sits on them (held, successor_created, unconfirmed
#                           captain_batch, or a bare claim) - the evasion signature.
#     discharged_pending    items whose terminal signal remains but whose disposition is
#                           genuine (resolved/rejected with lineage, or a board-confirmed
#                           captain transfer) - normally a short-lived state before
#                           teardown clears the signal itself.
#
# Cumulative REAL discharges (landed, merged, torn down) are not reconstructable from
# these two sources alone: they live in the backlog's Done section and each task's
# lifecycle records. The gate's own observed proxy is allowed_after_valid_progress.
#
# Usage: fm-turnend-metrics.sh [--json]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LOG="${FM_TURNEND_LOG:-$STATE/.turnend-guard.log}"

JSON=false
[ "${1:-}" = --json ] && JSON=true

command -v jq >/dev/null 2>&1 || { printf 'fm-turnend-metrics: jq is required\n' >&2; exit 1; }

# shellcheck disable=SC1091 # Dynamic sibling path is resolved from BASH_SOURCE.
. "$SCRIPT_DIR/fm-nf-attention-lib.sh"

# --- cumulative panel, folded from the decision log --------------------------
CUM=$(jq -Rn '
  [inputs | fromjson? | select(type == "object")] as $rows
  | def n($d): [$rows[] | select(.decision == $d)] | length;
  {evaluations: ($rows | length),
   blocked_needs_firstmate: n("blocked_needs_firstmate"),
   blocked_watcher_down: n("blocked_watcher_down"),
   allowed_needs_firstmate_empty: n("allowed_needs_firstmate_empty"),
   allowed_after_valid_progress: n("allowed_after_valid_progress"),
   allowed_loop_protection_without_progress: n("allowed_loop_protection_without_progress"),
   allowed_guard_error: n("allowed_guard_error"),
   allowed_duty_disabled: n("allowed_duty_disabled"),
   allowed_afk_owner: n("allowed_afk_owner"),
   permits_with_unattended_work:
     ([$rows[] | select((.decision | startswith("allowed")) and ((.needs_firstmate // 0) > 0))]
      | length)}
' < "$LOG" 2>/dev/null) || CUM=''
[ -n "$CUM" ] || CUM='{"evaluations":0,"blocked_needs_firstmate":0,"blocked_watcher_down":0,"allowed_needs_firstmate_empty":0,"allowed_after_valid_progress":0,"allowed_loop_protection_without_progress":0,"allowed_guard_error":0,"allowed_duty_disabled":0,"allowed_afk_owner":0,"permits_with_unattended_work":0}'

# --- live panel, classified from source ---------------------------------------
live_unattended=0
live_paper_parked=0
live_discharged_pending=0
paper_ids=''
if [ -d "$STATE" ]; then
  fold=$(fm_nf_attention_fold "$DATA" 2>/dev/null) || fold='{}'
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    fp=$(fm_nf_current_fingerprint "$STATE" "$id" 2>/dev/null) || continue
    desired=$(fm_nf_attention_desired "$STATE" "$DATA" "$id" "$fold" 2>/dev/null) || continue
    want=$(printf '%s' "$desired" | jq -r '.state' 2>/dev/null) || continue
    outcome=$(printf '%s' "$desired" | jq -r '.outcome' 2>/dev/null) || continue
    claimed=$(printf '%s' "$fold" | jq -r --arg k "needs_firstmate:$id" '.[$k].owner // ""' 2>/dev/null) || claimed=''
    if [ "$outcome" = captain_batch ] && fm_nf_unattended_captain_confirmed "$STATE" "$id" "$fp"; then
      live_discharged_pending=$((live_discharged_pending + 1))
      continue
    fi
    if [ "$want" = terminal ]; then
      case "$outcome" in
        resolved|rejected)
          live_discharged_pending=$((live_discharged_pending + 1))
          continue
          ;;
      esac
    fi
    live_unattended=$((live_unattended + 1))
    # The evasion signature: the signal remains AND paper sits on it.
    if [ -n "$outcome" ] || [ -n "$claimed" ]; then
      live_paper_parked=$((live_paper_parked + 1))
      paper_ids="$paper_ids $id"
    fi
  done
fi

RESULT=$(jq -cn \
  --argjson cumulative "$CUM" \
  --argjson unattended "$live_unattended" \
  --argjson paper "$live_paper_parked" \
  --argjson pending "$live_discharged_pending" \
  --arg paper_ids "${paper_ids# }" \
  '{cumulative: $cumulative,
    live: {unattended: $unattended,
           paper_parked: $paper,
           paper_parked_ids: $paper_ids,
           discharged_pending_teardown: $pending}}')

if [ "$JSON" = true ]; then
  printf '%s\n' "$RESULT"
else
  printf '%s' "$RESULT" | jq -r '
    "TURN-END GUARD METRICS",
    "cumulative (decision log):",
    ("  evaluations:                      " + (.cumulative.evaluations | tostring)),
    ("  blocked (needs_firstmate):        " + (.cumulative.blocked_needs_firstmate | tostring)),
    ("  blocked (watcher only):           " + (.cumulative.blocked_watcher_down | tostring)),
    ("  allowed: lane empty:              " + (.cumulative.allowed_needs_firstmate_empty | tostring)),
    ("  allowed: after valid progress:    " + (.cumulative.allowed_after_valid_progress | tostring)),
    ("  allowed: loop protection, NO progress: " + (.cumulative.allowed_loop_protection_without_progress | tostring)),
    ("  allowed: guard error:             " + (.cumulative.allowed_guard_error | tostring)),
    ("  allowed: kill switch engaged:     " + (.cumulative.allowed_duty_disabled | tostring)),
    ("  allowed: afk stand-down:          " + (.cumulative.allowed_afk_owner | tostring)),
    ("  PERMITS WITH UNATTENDED WORK:     " + (.cumulative.permits_with_unattended_work | tostring)),
    "live (state + ledger, now):",
    ("  unattended (holding the gate):    " + (.live.unattended | tostring)),
    ("  paper-parked (signal remains under a non-discharging disposition): "
      + (.live.paper_parked | tostring)
      + (if .live.paper_parked_ids == "" then "" else " [" + .live.paper_parked_ids + "]" end)),
    ("  genuinely dispositioned, teardown pending: " + (.live.discharged_pending_teardown | tostring))
  '
fi

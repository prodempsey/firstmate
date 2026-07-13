#!/usr/bin/env bash
# Run the fleet-triage duty pass for a fleet-state change that just happened, and
# print a banner ONLY when the pass finds actionable state.
#
# Usage:
#   fm-triage-duty.sh <trigger> [--detail <text>]
#
# Triggers (scope in parens):
#   wake-drain        an actionable wake was just drained          (targeted)
#   heartbeat         a heartbeat wake reached the agent            (full)
#   ship-complete     a ship task's work just landed                (full)
#   scout-complete    a scout task's report just closed out         (full)
#   teardown          a task was just torn down                     (full)
#   session-start     the locked primary finished session start     (full)
#   recovery          recovery reconciled a dead/respawned endpoint (full)
#   backlog-mutation  a tasks-axi or hand-edited backlog change      (full)
#   bug-mutation      a bug was recorded or resolved via the bug CLI (full)
#   blocker-freed     a blocker completed and may free dependents    (full)
#   afk-exit          the captain returned; away-mode catch-up ran   (full)
#
# session-start and recovery have no OTHER script chokepoint of their own (recovery
# in particular reuses the session-start digest per AGENTS.md section 5), so calling
# this trigger explicitly at those points is what gives them coverage. backlog-mutation,
# bug-mutation, blocker-freed, and afk-exit have NO script chokepoint firstmate owns at
# all - tasks-axi and the bug CLI are external tools, and away-mode exit is a
# conversational transition - so those four are documented operating instructions
# (AGENTS.md, the fleet-triage and afk skills) that name this exact command rather than
# a caller wired in bin/.
#
# TWO SEPARATE SWITCHES - do not confuse them:
#   FM_TRIAGE_DUTY=off             this script produces NO output and runs NOTHING:
#                                  no enumeration, no state-file write, no banner.
#                                  An escape hatch to disable the duty entirely.
#   FLEET_TRIAGE_MODE=enumerate_only   this script (and the enumerator it calls)
#                                  still RUN and REPORT normally; only a ledger write or
#                                  domain action is refused (enforced by
#                                  bin/fm-fleet-triage-record.sh, not here). A duty pass
#                                  under enumerate_only can still print a banner and
#                                  still writes its own state/.triage-duty-last.json
#                                  cache, because reporting is exactly what this mode
#                                  keeps allowed.
#
# WHY THIS EXISTS. Phase 1 (the enumerator, bin/fm-fleet-triage.sh) and the outcome
# ledger (bin/fm-fleet-triage-record.sh) existed, but were consulted at exactly one
# moment: locked session start. Phase 2A wired a banner into every fleet-state-changing
# script, but the banner was a static reminder - it never ran the enumerator itself, so
# it proved nothing was actually consulted. This phase closes that gap: this script
# NOW runs the read-only enumerator for the trigger's scope, and a banner appears only
# when the enumerator actually finds actionable state, carrying that state's machine-
# readable summary (trigger, scope, actionable, ownerless, unhealthy, captain_gated,
# fingerprint) so a caller can act on it without re-parsing prose.
#
# THIS COMMAND RECORDS NO DISPOSITION. It runs the read-only enumerator
# (bin/fm-fleet-triage.sh --json) and renders its digest; it never records an outcome, never
# claims, never mutates the backlog, bugs, or any task. It writes exactly two things, and
# neither is a judgment about any item:
#   state/.triage-duty-last.json  a volatile cache of this pass's OWN result, read cheaply by
#                                 the supervision preflight in bin/fm-guard.sh so it does not
#                                 re-enumerate. The turn-end guard deliberately does NOT read
#                                 it: a cache reflects the last pass, not the moment the turn
#                                 ends, so bin/fm-turnend-guard.sh reads the needs_firstmate
#                                 lane live (docs/turnend-guard.md).
#   a `surface` row per UNSEEN item, through the sanctioned writer
#                                 (bin/fm-fleet-triage-record.sh surface --new), which stamps
#                                 first_seen_at. Nothing else ever wrote one, so no item had a
#                                 persisted first-sight time, every item reported an age of
#                                 zero forever, and stale_unprocessed - the only escalator in
#                                 the model - was dead code. An item ignored for thirteen hours
#                                 read exactly like one that appeared this instant. The stamp
#                                 is confined to items the ledger has never seen, so it can
#                                 never clear a disposition; see --new in that writer.
# THIS COMMAND IS NON-BLOCKING FOR CALLERS. A known trigger always exits 0, whether the
# pass found nothing, found actionable state, or the enumerator itself failed - a caller
# wrapping this in `|| true` is defense in depth, never the only thing standing between
# an enumerator crash and a silently lost signal. An enumeration failure still prints a
# clearly labeled FAILED banner (this is what `|| true` must never be allowed to swallow
# alone) and still updates the state cache with ok:false, so bin/fm-guard.sh's preflight
# keeps surfacing it on every later supervision checkpoint even if this banner scrolls
# off screen. An unknown or missing trigger is a bug in the CALLER, not a fleet
# condition, and is the one case that still fails loudly with a non-zero exit.
#
# Silent (no enumeration, no state write, no banner) when: FM_TRIAGE_DUTY=off, this
# session does not own the per-home fleet lock (triage belongs to the locked primary),
# or state/.afk exists (the away daemon owns supervision; the duty resumes at
# afk-exit).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LAST_RESULT="$STATE/.triage-duty-last.json"
MAX_ITEMS=${FM_FLEET_TRIAGE_DIGEST_MAX_ITEMS:-8}
GATE_MAX=${FM_FLEET_TRIAGE_GATE_MAX_ITEMS:-10}

# shellcheck disable=SC1091 # Dynamic sibling path is resolved from BASH_SOURCE.
. "$SCRIPT_DIR/fm-fleet-triage-lib.sh"

usage() {
  sed -n '2,41p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

TRIGGER=''
DETAIL=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --detail) DETAIL=${2:-}; shift 2 ;;
    -*) printf 'fm-triage-duty: unknown flag: %s\n' "$1" >&2; exit 2 ;;
    *)
      [ -z "$TRIGGER" ] || { printf 'fm-triage-duty: unexpected argument: %s\n' "$1" >&2; exit 2; }
      TRIGGER=$1; shift ;;
  esac
done

# An unknown or missing trigger is a bug in the CALLER, not a fleet condition, so it
# fails loudly instead of running a pass nobody asked for. Call sites guard with
# `|| true`, so this still cannot break the operation it follows.
case "$TRIGGER" in
  wake-drain)       LABEL='ACTIONABLE WAKE DRAINED';        SCOPE_KEY=targeted ;;
  heartbeat)        LABEL='HEARTBEAT WAKE REACHED THE AGENT'; SCOPE_KEY=full ;;
  ship-complete)    LABEL='SHIP WORK LANDED';                SCOPE_KEY=full ;;
  scout-complete)   LABEL='SCOUT REPORT CLOSED OUT';         SCOPE_KEY=full ;;
  teardown)         LABEL='TASK TORN DOWN';                  SCOPE_KEY=full ;;
  session-start)    LABEL='SESSION START';                   SCOPE_KEY=full ;;
  recovery)         LABEL='RECOVERY RECONCILED THE FLEET';   SCOPE_KEY=full ;;
  backlog-mutation) LABEL='BACKLOG MUTATED';                 SCOPE_KEY=full ;;
  bug-mutation)     LABEL='BUG RECORDED OR RESOLVED';        SCOPE_KEY=full ;;
  blocker-freed)    LABEL='BLOCKER COMPLETED - DEPENDENTS MAY BE FREE'; SCOPE_KEY=full ;;
  afk-exit)         LABEL='AWAY-MODE CATCH-UP';              SCOPE_KEY=full ;;
  '') printf 'fm-triage-duty: a trigger is required\n\n' >&2; usage >&2; exit 2 ;;
  *)  printf 'fm-triage-duty: unknown trigger: %s\n\n' "$TRIGGER" >&2; usage >&2; exit 2 ;;
esac

if [ "$SCOPE_KEY" = targeted ]; then
  SCOPE_TEXT='targeted (start with the lane the wake touched, then check what it changed)'
else
  SCOPE_TEXT='full (every lane)'
fi

case "${FM_TRIAGE_DUTY:-on}" in off|OFF|0|false|FALSE) exit 0 ;; esac
[ -e "$STATE/.afk" ] && exit 0
fm_triage_owns_lock "$STATE" || exit 0

TMP_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-triage-duty.err.XXXXXX") || exit 0
# shellcheck disable=SC2317 # Invoked by the EXIT trap below.
# shellcheck disable=SC2317,SC2329 # Invoked by the EXIT trap below.
cleanup() { rm -f "$TMP_ERR"; }
trap cleanup EXIT

# --- Write the volatile last-pass cache atomically. bin/fm-guard.sh's supervision
# preflight reads this file directly instead of re-running the enumerator, so it must
# never observe a partially written file. ------------------------------------------
write_last_result() {  # <json>
  mkdir -p "$STATE"
  local tmp="$STATE/.triage-duty-last.json.tmp.$$"
  printf '%s\n' "$1" > "$tmp" && mv -f "$tmp" "$LAST_RESULT"
}

RULE='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'

# --- Run the read-only enumerator ONCE for this pass. ------------------------------
JSON_OUT=$("$SCRIPT_DIR/fm-fleet-triage.sh" --json 2>"$TMP_ERR")
RC=$?

if [ "$RC" -ne 0 ] || ! printf '%s' "$JSON_OUT" | jq -e '.schema == "fm-fleet-triage/v2"' >/dev/null 2>&1; then
  # --- Enumeration failed. Surface it as a stable finding, never swallow it. -------
  ERR_SNIPPET=$(tr '\n' ' ' < "$TMP_ERR" | cut -c1-300)
  [ -n "$ERR_SNIPPET" ] || ERR_SNIPPET="fm-fleet-triage.sh exited $RC with no stderr"
  NOW=$(fm_triage_now)
  FAIL_JSON=$(jq -cn --arg trigger "$TRIGGER" --arg scope "$SCOPE_KEY" --arg ts "$NOW" \
    --arg err "$ERR_SNIPPET" \
    '{ok: false, trigger: $trigger, scope: $scope, ts: $ts, error: $err}')
  write_last_result "$FAIL_JSON"
  {
    printf '●%s\n' "$RULE"
    printf '●  FLEET TRIAGE DUTY - ENUMERATION FAILED (%s)\n' "$LABEL"
    [ -n "$DETAIL" ] && printf '●  %s\n' "$DETAIL"
    printf '●  bin/fm-fleet-triage.sh --json did not return a valid fm-fleet-triage/v2 result:\n'
    printf '●    %s\n' "$ERR_SNIPPET"
    printf '●  This is a runtime/triage-health finding, not silence: fleet-triage visibility is\n'
    printf '●  degraded until this is fixed. Investigate with bin/fm-fleet-triage.sh --json directly,\n'
    printf '●  and do not treat an unrelated "|| true" on the caller as having handled this.\n'
    printf '●%s\n' "$RULE"
  } >&2
  exit 0
fi

# --- Enumeration succeeded. Compute and persist the machine-readable pass result. --
RESULT_LINE=$(printf '%s' "$JSON_OUT" | fm_triage_pass_result "$TRIGGER" "$SCOPE_KEY")
ACTIONABLE=$(printf '%s' "$RESULT_LINE" | jq -r '.actionable')
case "$ACTIONABLE" in ''|*[!0-9]*) ACTIONABLE=0 ;; esac

NOW=$(fm_triage_now)
# The captain-gate detail rides in the CACHE only, never in RESULT_LINE: bin/fm-guard.sh's
# dropped-captain-decision alarm needs the gated items by id to prove a needs_human card is
# missing, but the banner below already lists actionable items in its digest, and putting
# them in the printed result line too would pay for the same items twice in the agent's
# context. A gate list this pass cannot compute is recorded as null, which the guard reports
# as unavailable rather than as an all-clear.
GATES=$(printf '%s' "$JSON_OUT" | fm_triage_captain_gates "$GATE_MAX" 2>/dev/null) || GATES=''
[ -n "$GATES" ] || GATES=null
write_last_result "$(printf '%s' "$RESULT_LINE" \
  | jq -c --arg ts "$NOW" --argjson gates "$GATES" '. + {ok: true, ts: $ts, captain_gates: $gates}')"

# --- Stamp first sight of anything the ledger has never seen. -----------------------
# This is what makes age real (see the header). It runs through the sanctioned writer rather
# than appending here, so the ledger keeps exactly one writer, and it hands that writer the
# enumeration this pass already paid for instead of making it run a second one. Best-effort
# and non-fatal in both directions: a failed stamp costs age accuracy, never the duty pass or
# the caller it wraps, and the writer refuses under enumerate_only, which is why that mode
# skips it rather than printing a refusal on every pass.
if ! fm_triage_enumerate_only; then
  TMP_JSON=$(mktemp "${TMPDIR:-/tmp}/fm-triage-duty.json.XXXXXX") || TMP_JSON=''
  if [ -n "$TMP_JSON" ]; then
    printf '%s\n' "$JSON_OUT" > "$TMP_JSON"
    FM_TRIAGE_JSON_FILE="$TMP_JSON" "$SCRIPT_DIR/fm-fleet-triage-record.sh" surface --new \
      >/dev/null 2>&1 || true
    rm -f "$TMP_JSON"
  fi
fi

# Digest only when actionable state exists. A clear fleet stays exactly as silent as
# every other diagnostic in this codebase ("silence means all good"); a caller's
# `|| true` therefore has nothing captain-relevant to swallow on the common path.
[ "$ACTIONABLE" -gt 0 ] || exit 0

DIGEST_TEXT=$(printf '%s' "$JSON_OUT" | fm_triage_render_digest "$MAX_ITEMS")

{
  printf '●%s\n' "$RULE"
  printf '●  FLEET TRIAGE DUTY - %s\n' "$LABEL"
  [ -n "$DETAIL" ] && printf '●  %s\n' "$DETAIL"
  printf '●  %s pass (trigger: %s). Fleet state just changed, so what the triage ledger\n' "$SCOPE_TEXT" "$TRIGGER"
  printf '●  says changed with it. This pass already ran bin/fm-fleet-triage.sh --json:\n'
  printf '●  TRIAGE_DUTY_RESULT: %s\n' "$RESULT_LINE"
  printf '%s\n' "$DIGEST_TEXT" | sed 's/^/●  /'
  printf '●  Before resuming silent supervision:\n'
  printf '●    1. Load the fleet-triage skill.\n'
  printf '●    2. Run bin/fm-fleet-triage.sh --json for full item detail beyond this digest.\n'
  printf '●    3. Record every disposition with bin/fm-fleet-triage-record.sh. A terminal\n'
  printf '●       outcome must name its lineage, and being seen is not an outcome.\n'
  if fm_triage_enumerate_only; then
    printf '●  FLEET_TRIAGE_MODE=enumerate_only: classify and report only; every ledger\n'
    printf '●  write and domain action is refused. Report what you would have done.\n'
  fi
  printf '●  Do not resume supervision while an actionable item still has no owner, claim,\n'
  printf '●  successor, hold with a review condition, captain batch, rejection, or resolution.\n'
  printf '●%s\n' "$RULE"
} >&2
exit 0

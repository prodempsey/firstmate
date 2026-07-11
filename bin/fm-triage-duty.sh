#!/usr/bin/env bash
# Print the fleet-triage duty banner for a fleet-state change that just happened.
#
# Usage:
#   fm-triage-duty.sh <trigger> [--detail <text>]
#
# Triggers (exactly the ones a firstmate script emits):
#   wake-drain       an actionable wake was just drained          (targeted pass)
#   heartbeat        a heartbeat wake reached the agent           (full pass)
#   ship-complete    a ship task's work just landed               (full pass)
#   scout-complete   a scout task's report just closed out        (full pass)
#   teardown         a task was just torn down                    (full pass)
#
# The other trigger points named in AGENTS.md - backlog mutation, bug recording or
# resolution, and AFK-exit catch-up - go through tools this repo does not own
# (tasks-axi, the bug CLI) or through a conversational transition with no script
# chokepoint at all, so they are wired as operating instructions rather than here.
#
# WHY THIS EXISTS. The enumerator (bin/fm-fleet-triage.sh) and the outcome ledger
# (bin/fm-fleet-triage-record.sh) already exist, but they were consulted at exactly
# one moment: locked session start. Everything that CHANGES fleet state - a wake, a
# merge, a teardown - changes what the ledger would say, and nothing prompted anyone
# to look. That is how a finished scout sat stale in-flight for a day with no
# successor. This script is the prompt: it is cheap, it prints, and it never acts.
#
# THIS COMMAND IS READ-ONLY AND NON-BLOCKING. It reads the session lock, the away
# flag, and its own argv. It runs no enumeration (deliberately - a full enumerate is
# far too costly for a per-wake path; the cheap --check mode that would allow it is a
# later phase), performs no domain action, writes no ledger, and always exits 0 for a
# known trigger so a caller can never be broken by it. Like bin/fm-guard.sh, the
# banner goes to stderr, so a caller's parseable stdout stays byte-identical.
#
# Silent when: this session does not own the per-home fleet lock (triage belongs to
# the locked primary), state/.afk exists (the away daemon owns supervision; the duty
# resumes at AFK-exit catch-up), or FM_TRIAGE_DUTY=off (escape hatch).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck disable=SC1091 # Dynamic sibling path is resolved from BASH_SOURCE.
. "$SCRIPT_DIR/fm-fleet-triage-lib.sh"

usage() {
  sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
# fails loudly instead of printing a banner nobody can act on. Call sites guard with
# `|| true`, so this still cannot break the operation it follows.
case "$TRIGGER" in
  wake-drain)     LABEL='ACTIONABLE WAKE DRAINED'; SCOPE='targeted (start with the lane the wake touched, then check what it changed)' ;;
  heartbeat)      LABEL='HEARTBEAT WAKE REACHED THE AGENT'; SCOPE='full (every lane)' ;;
  ship-complete)  LABEL='SHIP WORK LANDED'; SCOPE='full (every lane)' ;;
  scout-complete) LABEL='SCOUT REPORT CLOSED OUT'; SCOPE='full (every lane)' ;;
  teardown)       LABEL='TASK TORN DOWN'; SCOPE='full (every lane)' ;;
  '') printf 'fm-triage-duty: a trigger is required\n\n' >&2; usage >&2; exit 2 ;;
  *)  printf 'fm-triage-duty: unknown trigger: %s\n\n' "$TRIGGER" >&2; usage >&2; exit 2 ;;
esac

case "${FM_TRIAGE_DUTY:-on}" in off|OFF|0|false|FALSE) exit 0 ;; esac
[ -e "$STATE/.afk" ] && exit 0
fm_triage_owns_lock "$STATE" || exit 0

RULE='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
{
  printf '●%s\n' "$RULE"
  printf '●  FLEET TRIAGE DUTY - %s\n' "$LABEL"
  [ -n "$DETAIL" ] && printf '●  %s\n' "$DETAIL"
  printf '●  Fleet state just changed, so what the triage ledger says changed with it.\n'
  printf '●  Before resuming silent supervision:\n'
  printf '●    1. Load the fleet-triage skill.\n'
  printf '●    2. Run a %s pass: bin/fm-fleet-triage.sh --digest\n' "$SCOPE"
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

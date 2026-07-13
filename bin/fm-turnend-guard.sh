#!/usr/bin/env bash
# Primary turn-end guard for the firstmate PRIMARY session only.
#
# It blocks a turn end for either of two independent reasons: supervision is off (tasks in
# flight, no live watcher), or finished crew work is still unattended (the needs_firstmate
# lane is non-empty, read live from local task state at the moment of evaluation). See "the
# actual predicate" below for why the second one exists and why it is scoped to that one
# lane. Every primary evaluation - permitted or blocked - is recorded in the decision log
# at state/.turnend-guard.log (see "decision log" below).
#
# fm-guard.sh (bin/fm-guard.sh) is pull-based: it only warns when some other
# supervision script happens to run. A primary session that ends a turn without
# resuming its harness supervision protocol, and then never runs another
# fleet-touching command itself, can sit blind for hours.
# This script is push-based: verified harness turn-end hooks invoke it every time
# the primary is about to end a turn.
# Claude and codex can block directly by preserving exit status 2 and stderr.
# OpenCode, pi, and grok adapters use the same predicate and force one bounded
# follow-up because their turn-end events are passive.
# See docs/turnend-guard.md for the per-harness mechanics, validation evidence,
# and fail-open tradeoffs.
#
# Ships with TRACKED harness hook files at the repo root, so this file is
# checked out into every worktree of this repo: the primary checkout, any
# crewmate/scout task worktree spawned to work on firstmate itself (the
# recursive "firstmate improving itself" case), and every secondmate home
# (treehouse-leased or git-cloned). It must therefore scope itself to the
# PRIMARY at runtime and stay a silent, fast no-op everywhere else.
#
# Loop-guard: never block twice in the same turn. Claude Code and codex Stop
# payloads carry stop_hook_active=true when the CURRENT stop attempt was itself
# already forced by an earlier block this turn; on that signal we always allow
# the stop, whether or not watcher supervision actually got resumed. Passive
# harness adapters provide their own one-follow-up guard before calling this
# script.
# That bounds this to at most one forced continuation per turn - never a wedged,
# un-endable session - while still nagging again on a later turn if the problem
# persists.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"
# The decision log: one JSON line per primary turn-end evaluation, permitted ones included.
LOG="${FM_TURNEND_LOG:-$STATE/.turnend-guard.log}"
LOG_MAX=${FM_TURNEND_LOG_MAX:-2000}
LOG_IDS=8
SHOW_IDS=10

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"

# Read the whole turn-end hook payload once; never block on unreadable/absent
# stdin.
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# jq is the repo's established JSON dependency (bin/fm-x-poll.sh uses the same
# "missing jq -> silent no-op" degrade). Without it we cannot safely read the
# loop-guard field, so we must never block - fail open, not noisy.
command -v jq >/dev/null 2>&1 || exit 0

# The loop-guard exit itself moves BELOW the predicate evaluation: a stop permitted only
# because one continuation was already forced this turn is exactly the event the decision
# log must record (a permitted turn end with work possibly still unattended), so it cannot
# short-circuit before the predicates and the log run.
STOP_HOOK_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null) || exit 0

# --- scope precisely to the PRIMARY checkout --------------------------------
# Excludes secondmate homes (the .fm-secondmate-home marker is written at seed
# time regardless of whether the home was treehouse-leased or git-cloned; see
# bin/fm-home-seed.sh) and ordinary crewmate/scout task worktrees of
# firstmate-on-itself (bin/fm-spawn.sh only ever hands those out as genuine
# linked `git worktree`s - it aborts the spawn otherwise - so a plain,
# non-worktree checkout is never one of those). A linked worktree's git-dir
# lives under the main repo's .git/worktrees/<name> and differs from the common
# (shared) git-dir; only the main, non-worktree checkout has the two equal.
[ -f "$FM_ROOT/.fm-secondmate-home" ] && exit 0
GIT_DIR=$(git -C "$FM_ROOT" rev-parse --git-dir 2>/dev/null) || exit 0
GIT_COMMON_DIR=$(git -C "$FM_ROOT" rev-parse --git-common-dir 2>/dev/null) || exit 0
[ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || exit 0
[ -f "$FM_ROOT/AGENTS.md" ] || exit 0
[ -d "$FM_ROOT/bin" ] || exit 0
[ -d "$STATE" ] || exit 0

# --- the actual predicate ----------------------------------------------------
# TWO INDEPENDENT REASONS TO BLOCK, and either one alone is enough.
#
#   1. SUPERVISION IS OFF - tasks in flight with no live watcher. The original predicate,
#      unchanged below.
#   2. FINISHED WORK IS UNATTENDED - the needs_firstmate lane is non-empty, read LIVE from
#      state/<id>.meta plus state/<id>.status and the triage ledger at the moment of this
#      evaluation, never from a cached summary of them. A cache reflects the last duty
#      pass, not the present: it would miss work that finished since, and hold the turn
#      hostage for work already discharged.
#
# Why (2) exists. Before it, arming the watcher was a complete and sufficient way to end any
# turn, no matter how much finished-but-unhandled work was piled up, because supervision
# liveness was the only thing this system could actually compel. Every triage mechanism -
# the duty banner, fm-guard.sh's preflight, the skill, AGENTS.md - printed to stderr and
# exited 0. So a primary could end a turn cleanly holding 61 actionable, 61 ownerless items
# and a pile of finished crew branches nobody had landed, and did, for thirteen hours. The
# rule against ending a turn with supervision off was enforced; the rule against ending a
# turn with the fleet's work undone was a printf. This closes that asymmetry.
#
# Why ONLY the needs_firstmate lane, and not all actionable items. That lane is bounded by
# the number of live tasks, it cannot be flooded by an audit backfill, and it is
# level-triggered off state/<id>.meta plus state/<id>.status - so it is discharged by LANDING
# or TEARING DOWN the work, never by paperwork. Gating on the full actionable set would let a
# backfill flood wedge the primary, which is exactly the liability a future session would
# rip out.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

fm_supervision_status "$STATE" "$GRACE"

blind=0
if [ "$FM_SUP_IN_FLIGHT" -gt 0 ] \
  && ! fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
  blind=1
fi

# UNATTENDED FINISHED WORK, READ LEVEL-TRIGGERED FROM SOURCE. fm_nf_unattended_ids walks
# state/<id>.meta plus state/<id>.status and the triage ledger on every call
# (bin/fm-nf-attention-lib.sh, the one owner of what "unattended" means, and the same
# per-item decision bin/fm-nf-reconcile.sh reports as unhandled). The sweep is bounded by
# the number of live tasks, so its cost on the turn-end path stays proportional to the
# fleet, never to any audit backlog. An item leaves this list only when the work is landed,
# torn down, or dispositioned with lineage - never by arming the watcher.
#
# FAIL OPEN, ALWAYS. Any failure to read the live state - a missing or broken library, a
# jq error, an unreadable state dir - yields an empty list and blocks nothing: the guard
# falls back to the supervision predicate alone, exactly as it behaved before this lane
# existed. A guard that can wedge the primary is worse than the bug it catches.
#
# Two deliberate stand-downs, both logged via nf_gate below:
#   away mode      the away daemon owns supervision and escalation while state/.afk exists;
#                  a turn-end block would fight the daemon's own batching loop.
#   FM_TRIAGE_DUTY=off  the captain-sanctioned kill switch for the whole fleet-triage duty;
#                  the gate is part of the duty, so the switch stands it down too - the
#                  operator escape hatch if the gate itself ever misbehaves.
nf=0
nf_ids=''
nf_gate=on
if [ -e "$STATE/.afk" ]; then
  nf_gate=afk
else
  case "${FM_TRIAGE_DUTY:-on}" in
    off|OFF|0|false|FALSE) nf_gate=duty-off ;;
  esac
fi
if [ "$nf_gate" = on ]; then
  # shellcheck source=bin/fm-nf-attention-lib.sh
  . "$SCRIPT_DIR/fm-nf-attention-lib.sh" 2>/dev/null || true
  if command -v fm_nf_unattended_ids >/dev/null 2>&1; then
    nf_ids=$(fm_nf_unattended_ids "$STATE" "$DATA" 2>/dev/null) || nf_ids=''
  fi
  [ -n "$nf_ids" ] && nf=$(printf '%s\n' "$nf_ids" | grep -c .)
  case "$nf" in ''|*[!0-9]*) nf=0; nf_ids='' ;; esac
fi

# Bounded id digest carried in both the block message and the decision log, so the primary
# sees WHICH items it is being held for without a second command.
nf_digest=''
if [ "$nf" -gt 0 ]; then
  nf_digest=$(printf '%s\n' "$nf_ids" | head -n "$LOG_IDS" | paste -sd, -)
  [ "$nf" -gt "$LOG_IDS" ] && nf_digest="$nf_digest,+$((nf - LOG_IDS)) more"
fi

watcher_desc=healthy
[ "$FM_SUP_IN_FLIGHT" -eq 0 ] && watcher_desc=no-tasks-in-flight
[ "$blind" -eq 1 ] && watcher_desc=down

# --- decision log ------------------------------------------------------------
# Every primary turn-end evaluation is recorded, permitted ones included: the acceptance
# metric for this gate is "zero permitted turn ends while unattended needs-firstmate work
# exists", and that is only measurable if the permits are on the record too. One JSON line
# per evaluation - timestamp, watcher status, lane count, bounded item digest, the decision,
# the block reason, and whether loop protection was active. NO TRANSCRIPT CONTENT, ever:
# ids, counts, and decisions, nothing the model said or read.
# Best-effort: a log that cannot be written must never change the decision or wedge the turn.
log_decision() {  # <allowed|blocked> <reason>
  local line
  line=$(jq -cn \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg watcher "$watcher_desc" \
    --argjson in_flight "$FM_SUP_IN_FLIGHT" \
    --argjson nf "$nf" \
    --arg nf_items "$nf_digest" \
    --arg nf_gate "$nf_gate" \
    --arg decision "$1" \
    --arg reason "$2" \
    --argjson loop_protection "$([ "$STOP_HOOK_ACTIVE" = true ] && echo true || echo false)" \
    '{ts: $ts, watcher: $watcher, in_flight: $in_flight, needs_firstmate: $nf,
      nf_items: $nf_items, nf_gate: $nf_gate, decision: $decision, reason: $reason,
      loop_protection: $loop_protection}' 2>/dev/null) || return 0
  printf '%s\n' "$line" >> "$LOG" 2>/dev/null || return 0
  # Bounded: this is an operational trail, not an archive.
  if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt "$LOG_MAX" ]; then
    if tail -n "$((LOG_MAX / 2))" "$LOG" > "$LOG.tmp.$$" 2>/dev/null; then
      mv -f "$LOG.tmp.$$" "$LOG" 2>/dev/null || rm -f "$LOG.tmp.$$" 2>/dev/null
    else
      rm -f "$LOG.tmp.$$" 2>/dev/null
    fi
  fi
  return 0
}

# Loop protection: never block twice in one turn (see the header). Recorded, because a
# permitted turn end with work still unattended is exactly the event the acceptance metric
# counts, and it must not be invisible just because the loop guard is why it was permitted.
if [ "$STOP_HOOK_ACTIVE" = true ]; then
  log_decision allowed 'loop protection: already forced one continuation this turn'
  exit 0
fi

if [ "$blind" -eq 0 ] && [ "$nf" -eq 0 ]; then
  log_decision allowed 'supervision healthy, no unattended needs-firstmate work'
  exit 0
fi

afk=0
[ -e "$STATE/.afk" ] && afk=1
x_mode=0
[ -f "$CONFIG/x-mode.env" ] && x_mode=1
rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
block_reason=''

if [ "$blind" -eq 1 ]; then
  block_reason='watcher-down'
  REASON=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --afk "$afk" --x-mode "$x_mode" --repair-line 2>/dev/null \
    || printf '%s\n' 'tasks in flight, no live watcher - resume supervision according to the session-start operating block before ending the turn')
  {
    printf '●%s\n' "$rule"
    printf '●  TURN WOULD END BLIND - SUPERVISION IS OFF\n'
    printf '●  %s task(s) in flight, but no live watcher holds this home lock (last beat: %s).\n' "$FM_SUP_IN_FLIGHT" "$FM_SUP_BEACON_DESC"
    printf '●  %s\n' "$REASON"
    printf '●%s\n' "$rule"
  } >&2
fi

if [ "$nf" -gt 0 ]; then
  if [ -z "$block_reason" ]; then
    block_reason=unattended-needs-firstmate
  else
    block_reason="$block_reason+unattended-needs-firstmate"
  fi
  {
    printf '●%s\n' "$rule"
    printf '●  TURN WOULD END WITH FINISHED WORK UNATTENDED\n'
    printf '●  %s crew signal(s) reported done, blocked, failed, or needs-decision and\n' "$nf"
    printf '●  nobody has attended to them:\n'
    printf '%s\n' "$nf_ids" | head -n "$SHOW_IDS" | sed 's/^/●    /'
    [ "$nf" -gt "$SHOW_IDS" ] && printf '●    ... and %s more\n' "$((nf - SHOW_IDS))"
    printf '●  RE-ARMING THE WATCHER DOES NOT SATISFY THIS CONDITION. Supervision liveness\n'
    printf '●  is a separate check, and a live watcher discharges none of the work above.\n'
    printf '●  An item leaves this list only when its work is landed, torn down, or\n'
    printf '●  dispositioned with lineage:\n'
    printf '●    bin/fm-nf-reconcile.sh list        each item, and why it is still open\n'
    printf '●    bin/fm-fleet-triage.sh --json      full item detail\n'
    printf '●    bin/fm-fleet-triage-record.sh      record each disposition, with its lineage\n'
    printf '●%s\n' "$rule"
  } >&2
fi
log_decision blocked "$block_reason"
exit 2

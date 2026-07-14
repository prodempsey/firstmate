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
# WHAT DISCHARGES THE UNATTENDED-WORK GATE (ORD-059 section 2). Only real state changes:
#   - landing the work and tearing the task down (its meta/status leave state/);
#   - the crew's status moving off a terminal verb (a steer to `paused:`, a `resolved:`
#     follow-up after a decision, a relaunch);
#   - a genuine terminal disposition: `resolved` or `rejected` recorded with valid lineage
#     against the item's current evidence.
# NOTHING ELSE DOES. Not an fm-nf-ack receipt, not re-arming the watcher, not a triage
# `claim`, not a `hold` (even a valid dated one - holds park the BOARD CARD, never this
# gate), not `successor_created`, not `captain_batch`, and never any cached triage summary.
# The rule lives in fm_nf_unattended_ids (bin/fm-nf-attention-lib.sh).
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
# the decision-outcome taxonomy, and fail-open tradeoffs.
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
# the stop, whether or not anything actually got fixed. Passive harness
# adapters provide their own one-follow-up guard before calling this script.
# That bounds this to at most one forced continuation per turn - never a
# wedged, un-endable session - while still nagging again on a later turn if the
# problem persists. The permit is PROGRESS-AWARE in the record (ORD-059
# section 1): a loop-guarded stop is logged as allowed_empty or allowed_progress
# only when the lane is clear or the blocked id set actually shrank; otherwise
# it is logged as stood_down_loop_protection, which is an enforcement stand-down,
# never a compliant permit.
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
# The id set the last BLOCKED evaluation was blocked on, for the progress-aware loop-guard
# classification: a second stop attempt is compliant only if this set actually shrank.
BLOCK_IDS_FILE="$STATE/.turnend-guard-block-ids"

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"

# Read the whole turn-end hook payload once; never block on unreadable/absent
# stdin.
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# --- scope precisely to the PRIMARY checkout --------------------------------
# Excludes secondmate homes (the .fm-secondmate-home marker is written at seed
# time regardless of whether the home was treehouse-leased or git-cloned; see
# bin/fm-home-seed.sh) and ordinary crewmate/scout task worktrees of
# firstmate-on-itself (bin/fm-spawn.sh only ever hands those out as genuine
# linked `git worktree`s - it aborts the spawn otherwise - so a plain,
# non-worktree checkout is never one of those). A linked worktree's git-dir
# lives under the main repo's .git/worktrees/<name> and differs from the common
# (shared) git-dir; only the main, non-worktree checkout has the two equal.
# Scoping runs BEFORE the jq dependency check so a guard-error alarm can only
# ever fire in the one checkout that is actually a primary.
[ -f "$FM_ROOT/.fm-secondmate-home" ] && exit 0
GIT_DIR=$(git -C "$FM_ROOT" rev-parse --git-dir 2>/dev/null) || exit 0
GIT_COMMON_DIR=$(git -C "$FM_ROOT" rev-parse --git-common-dir 2>/dev/null) || exit 0
[ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || exit 0
[ -f "$FM_ROOT/AGENTS.md" ] || exit 0
[ -d "$FM_ROOT/bin" ] || exit 0
[ -d "$STATE" ] || exit 0

rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'

# --- guard-error path --------------------------------------------------------
# Fail-open MAY remain (a wedged primary is worse than the bug this catches), but a failed
# state inspection is NOT an ordinary empty-lane permit (ORD-059 section 3): it is loud, it
# is logged as its own guard_error outcome naming the failed component, and it raises a
# durable operational-health signal, because a gate that is silently dead looks exactly
# like a gate with nothing to say.

# Raise the durable health signal through the sanctioned bug CLI (the same one the triage
# enumerator's bugs lane reads; FM_FLEET_TRIAGE_BUG_CLI overrides it, `off` disables).
# Deduped per failed component via a state marker so a persistent failure files one bug,
# not one per turn end; the marker set is cleared by the next healthy evaluation so a
# recurrence after repair files a fresh one. Best-effort in every direction.
signal_guard_error_bug() {  # <component> <detail>
  local cli slug marker
  cli=${FM_FLEET_TRIAGE_BUG_CLI:-}
  [ "$cli" = off ] && return 0
  if [ -z "$cli" ]; then
    cli=$(command -v bug 2>/dev/null) || return 0
  fi
  [ -x "$cli" ] || return 0
  slug=$(printf '%s' "$1" | tr -c 'a-zA-Z0-9' '-')
  marker="$STATE/.turnend-guard-error-reported-$slug"
  [ -e "$marker" ] && return 0
  "$cli" record "turn-end guard could not inspect fleet state ($1): $2. The unattended-work gate is failing open until this is repaired; see state/.turnend-guard.log for guard_error decisions." \
    --quiet >/dev/null 2>&1 || return 0
  : > "$marker" 2>/dev/null || true
}

guard_error_banner() {  # <component> <detail>
  {
    printf '●%s\n' "$rule"
    printf '●  TURN-END GUARD ERROR - FLEET STATE COULD NOT BE INSPECTED\n'
    printf '●  Failed component: %s\n' "$1"
    printf '●  %s\n' "$2"
    printf '●  The unattended-work gate is FAILING OPEN: this turn end is permitted, but it\n'
    printf '●  is recorded as guard_error, not as a compliant permit. Repair the component;\n'
    printf '●  a durable bug signal has been raised if the bug CLI is available.\n'
    printf '●%s\n' "$rule"
  } >&2
}

# Log a guard_error decision without jq (jq itself may be the failed component). Every
# interpolated value here is guard-controlled text, never transcript content.
log_guard_error_raw() {  # <component>
  printf '{"ts":"%s","watcher":"unknown","in_flight":-1,"needs_firstmate":-1,"nf_items":"","nf_gate":"on","nf_error":"%s","decision":"guard_error","reason":"%s","loop_protection":false}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$1" >> "$LOG" 2>/dev/null || true
}

# jq is the repo's established JSON dependency. Without it we cannot safely read the
# loop-guard field, so we can never block - but in the primary this is a guard outage,
# not a healthy silence.
if ! command -v jq >/dev/null 2>&1; then
  guard_error_banner 'jq' 'jq is not on PATH, so the hook payload and the needs_firstmate lane cannot be read.'
  log_guard_error_raw 'jq missing'
  signal_guard_error_bug 'jq missing' 'jq is not on PATH in the primary'
  exit 0
fi

if ! STOP_HOOK_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null); then
  guard_error_banner 'hook payload' 'the turn-end hook payload did not parse as JSON, so the loop-guard state is unknown and blocking would risk an un-endable session.'
  log_guard_error_raw 'hook payload unparseable'
  signal_guard_error_bug 'hook payload unparseable' 'the turn-end hook payload did not parse as JSON'
  exit 0
fi

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
# (bin/fm-nf-attention-lib.sh, the one owner of the gate's discharge rule - see this file's
# header for what discharges and what deliberately does not). The sweep is bounded by the
# number of live tasks, so its cost on the turn-end path stays proportional to the fleet,
# never to any audit backlog.
#
# The sweep runs under BOTH stand-downs too (away mode, FM_TRIAGE_DUTY=off): the gate does
# not enforce there, but the decision log still records what the stand-down suppressed, so
# a stand-down can never silently lose work.
#
# FAIL OPEN, WITH A GUARD-ERROR RECORD. Any failure to read the live state blocks nothing,
# but it is classified as guard_error (loud banner, named component, durable bug signal),
# never as an ordinary empty lane - see the guard-error path above.
nf=0
nf_ids=''
nf_error=''
nf_gate=on
if [ -e "$STATE/.afk" ]; then
  nf_gate=afk
else
  case "${FM_TRIAGE_DUTY:-on}" in
    off|OFF|0|false|FALSE) nf_gate=duty-off ;;
  esac
fi
if [ ! -f "$SCRIPT_DIR/fm-nf-attention-lib.sh" ]; then
  nf_error='fm-nf-attention-lib.sh missing'
else
  # shellcheck source=bin/fm-nf-attention-lib.sh
  if ! . "$SCRIPT_DIR/fm-nf-attention-lib.sh" 2>/dev/null; then
    nf_error='fm-nf-attention-lib.sh failed to source'
  elif ! command -v fm_nf_unattended_ids >/dev/null 2>&1; then
    nf_error='fm_nf_unattended_ids undefined after source'
  elif ! nf_ids=$(fm_nf_unattended_ids "$STATE" "$DATA" 2>/dev/null); then
    nf_error='fm_nf_unattended_ids failed'
    nf_ids=''
  fi
fi
[ -n "$nf_ids" ] && nf=$(printf '%s\n' "$nf_ids" | grep -c .)
case "$nf" in ''|*[!0-9]*) nf=0; nf_ids='' ;; esac

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
# Every primary turn-end evaluation is recorded, one JSON line each - timestamp, watcher
# status, lane count, bounded item digest, gate state, read-error component, the decision,
# the reason, and whether loop protection was active. NO TRANSCRIPT CONTENT, ever: ids,
# counts, and decisions, nothing the model said or read.
#
# The decision taxonomy (ORD-059 section 1). Only the first two are compliant permits; the
# acceptance metric "zero permitted turn ends while unattended Needs FirstMate work exists"
# counts every other permitted outcome against it.
#   allowed_empty               the lane was genuinely empty (and the watcher healthy).
#   allowed_progress            loop-guarded stop after real progress: the id set the turn
#                               was blocked on actually shrank.
#   blocked                     the turn end was refused (exit 2).
#   stood_down_loop_protection  permitted ONLY because hook recursion protection forbids a
#                               second block; the unattended set did not shrink.
#   stood_down_afk              permitted because away mode owns supervision.
#   stood_down_duty_off         permitted because the FM_TRIAGE_DUTY=off kill switch is
#                               engaged (loud on stderr, never silent).
#   guard_error                 permitted because the guard could not inspect state.
# Best-effort: a log that cannot be written must never change the decision or wedge the turn.
log_decision() {  # <decision> <reason>
  local line
  line=$(jq -cn \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg watcher "$watcher_desc" \
    --argjson in_flight "$FM_SUP_IN_FLIGHT" \
    --argjson nf "$nf" \
    --arg nf_items "$nf_digest" \
    --arg nf_gate "$nf_gate" \
    --arg nf_error "$nf_error" \
    --arg decision "$1" \
    --arg reason "$2" \
    --argjson loop_protection "$([ "$STOP_HOOK_ACTIVE" = true ] && echo true || echo false)" \
    '{ts: $ts, watcher: $watcher, in_flight: $in_flight, needs_firstmate: $nf,
      nf_items: $nf_items, nf_gate: $nf_gate, nf_error: $nf_error,
      decision: $decision, reason: $reason, loop_protection: $loop_protection}' 2>/dev/null) \
    || return 0
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

# A healthy, genuinely-empty evaluation closes any open block episode and clears the
# guard-error report markers, so a repaired component that breaks again files a fresh bug.
mark_healthy() {
  rm -f "$BLOCK_IDS_FILE" 2>/dev/null || true
  rm -f "$STATE"/.turnend-guard-error-reported-* 2>/dev/null || true
}

# The FM_TRIAGE_DUTY=off kill switch is a captain-sanctioned operator escape hatch, and an
# escape hatch in use must never look like a normal healthy path: it prints loudly on every
# primary turn end while engaged (ORD-059 section 5).
duty_off_banner() {
  {
    printf '●%s\n' "$rule"
    printf '●  FLEET-TRIAGE KILL SWITCH ENGAGED (FM_TRIAGE_DUTY=off)\n'
    if [ "$nf" -gt 0 ]; then
      printf '●  The unattended-work gate is STOOD DOWN while %s item(s) need firstmate:\n' "$nf"
      printf '%s\n' "$nf_ids" | head -n "$SHOW_IDS" | sed 's/^/●    /'
    elif [ -n "$nf_error" ]; then
      printf '●  The unattended-work gate is STOOD DOWN and the lane could not be read (%s).\n' "$nf_error"
    else
      printf '●  The unattended-work gate is STOOD DOWN (the lane is currently empty).\n'
    fi
    printf '●  This is an operator escape hatch, not a normal operating mode. Unset\n'
    printf '●  FM_TRIAGE_DUTY to restore enforcement.\n'
    printf '●%s\n' "$rule"
  } >&2
}

# --- classify the permitted outcomes ------------------------------------------
# Everything below either exits 0 with an honest decision record, or falls through to the
# block at the bottom.

if [ "$nf_gate" = duty-off ]; then
  duty_off_banner
fi

if [ "$STOP_HOOK_ACTIVE" = true ]; then
  # Loop protection: never block twice in one turn (see the header). The permit is
  # unconditional; the CLASSIFICATION is not (ORD-059 section 1): compliance requires the
  # lane empty or the blocked id set to have shrunk, and a stand-down or error is recorded
  # as itself.
  case "$nf_gate" in
    afk) log_decision stood_down_afk 'away mode owns supervision'; exit 0 ;;
    duty-off) log_decision stood_down_duty_off 'FM_TRIAGE_DUTY=off kill switch engaged'; exit 0 ;;
  esac
  if [ -n "$nf_error" ]; then
    guard_error_banner "$nf_error" 'the loop-guarded stop is permitted, but the lane state is unknown.'
    log_decision guard_error "$nf_error"
    signal_guard_error_bug "$nf_error" 'needs_firstmate lane read failed on the turn-end path'
    exit 0
  fi
  if [ "$nf" -eq 0 ]; then
    if [ "$blind" -eq 1 ]; then
      log_decision stood_down_loop_protection 'loop protection forced the permit; the watcher is still down'
    else
      mark_healthy
      log_decision allowed_empty 'lane empty, supervision healthy'
    fi
    exit 0
  fi
  progress=0
  if [ -f "$BLOCK_IDS_FILE" ]; then
    while IFS= read -r prior_id; do
      [ -n "$prior_id" ] || continue
      if ! printf '%s\n' "$nf_ids" | grep -qxF -- "$prior_id"; then
        progress=1
        break
      fi
    done < "$BLOCK_IDS_FILE"
  fi
  if [ "$progress" -eq 1 ]; then
    rm -f "$BLOCK_IDS_FILE" 2>/dev/null || true
    log_decision allowed_progress 'the unattended id set shrank since the blocked attempt'
  else
    log_decision stood_down_loop_protection 'loop protection forced the permit; no unattended item was discharged'
  fi
  exit 0
fi

# First stop attempt of the turn. Stand-downs and read failures on the unattended-work axis
# never mask the independent watcher predicate below.
if [ "$blind" -eq 0 ]; then
  case "$nf_gate" in
    afk)
      if [ "$nf" -gt 0 ] || [ -n "$nf_error" ]; then
        log_decision stood_down_afk 'away mode owns supervision'
      else
        log_decision allowed_empty 'lane empty, supervision healthy (away mode)'
      fi
      exit 0
      ;;
    duty-off)
      if [ "$nf" -gt 0 ] || [ -n "$nf_error" ]; then
        log_decision stood_down_duty_off 'FM_TRIAGE_DUTY=off kill switch engaged'
      else
        log_decision allowed_empty 'lane empty, supervision healthy (kill switch engaged)'
      fi
      exit 0
      ;;
  esac
  if [ -n "$nf_error" ]; then
    guard_error_banner "$nf_error" 'this turn end is permitted fail-open; the lane state is unknown.'
    log_decision guard_error "$nf_error"
    signal_guard_error_bug "$nf_error" 'needs_firstmate lane read failed on the turn-end path'
    exit 0
  fi
  if [ "$nf" -eq 0 ]; then
    mark_healthy
    log_decision allowed_empty 'lane empty, supervision healthy'
    exit 0
  fi
fi

# --- block ---------------------------------------------------------------------
afk=0
[ -e "$STATE/.afk" ] && afk=1
x_mode=0
[ -f "$CONFIG/x-mode.env" ] && x_mode=1
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

nf_blocking=0
if [ "$nf" -gt 0 ] && [ "$nf_gate" = on ]; then
  nf_blocking=1
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
    printf '●  Acks, claims, holds, successors, and captain batches do not either - they\n'
    printf '●  park the board card, never this gate. An item leaves this list only when its\n'
    printf '●  work is landed, torn down, genuinely resolved or rejected with lineage, or\n'
    printf '●  its crew status moves off the terminal verb (a steer to paused:, a resolved:\n'
    printf '●  follow-up):\n'
    printf '●    bin/fm-nf-reconcile.sh list        each item, and its current disposition\n'
    printf '●    bin/fm-fleet-triage.sh --json      full item detail\n'
    printf '●    bin/fm-fleet-triage-record.sh      record each disposition, with its lineage\n'
    printf '●%s\n' "$rule"
  } >&2
fi

# A lane-read failure alongside a watcher block is not a permit, but it must still be
# loud and still raise the durable signal: the watcher repair below would otherwise hide
# a dead gate behind a healthy-looking block.
if [ -n "$nf_error" ] && [ "$nf_gate" = on ]; then
  guard_error_banner "$nf_error" 'this turn end is blocked for the watcher; the lane state is unknown.'
  signal_guard_error_bug "$nf_error" 'needs_firstmate lane read failed on the turn-end path'
fi

# Record the id set this block stands on, so the loop-guarded second attempt can tell real
# progress from an unchanged pile. A watcher-only block records an empty set.
if [ "$nf_blocking" -eq 1 ]; then
  printf '%s\n' "$nf_ids" > "$BLOCK_IDS_FILE" 2>/dev/null || true
else
  : > "$BLOCK_IDS_FILE" 2>/dev/null || true
fi
log_decision blocked "$block_reason"
exit 2

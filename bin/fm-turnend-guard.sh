#!/usr/bin/env bash
# Turn-end guard for any firstmate PRIMARY session: the main home OR a
# secondmate's own home. A secondmate runs its own primary firstmate session and
# is guarded exactly like the main primary; only child crew/scout worktrees are
# exempt (see the scoping block below and docs/turnend-guard.md).
#
# It blocks a turn end for either of two independent reasons: supervision is off (tasks in
# flight, no live watcher), or finished crew work is still unattended (the needs_firstmate
# lane is non-empty, read live from local task state at the moment of evaluation). See "the
# actual predicate" below for why the second one exists and why it is scoped to that one
# lane. Every primary evaluation - permitted or blocked - is recorded in the decision log
# at state/.turnend-guard.log (see "decision log" below).
#
# WHAT DISCHARGES THE UNATTENDED-WORK GATE (ORD-060 section 2). Only real lifecycle
# changes:
#   - landing the work and tearing the task down (its meta/status leave state/), which
#     covers merged ships, captured-then-torn-down scout reports, and safe returns;
#   - the crew's status moving off a terminal verb (a steer to `paused:`, a `resolved:`
#     follow-up after a decision, a relaunch);
#   - a genuine terminal disposition: `resolved` or `rejected` recorded with valid lineage
#     against the item's current evidence;
#   - a captain decision VERIFIABLY transferred to the captain's still-visible Needs You
#     column: a `captain_batch` outcome whose board hand-off is confirmed by the
#     fingerprint-bound receipt fm-nf-ack.sh --to-captain writes only after Bridge
#     read-back.
# NOTHING ELSE DOES. Not a reviewed fm-nf-ack receipt, not re-arming the watcher, not a
# triage `surface` or `claim`, not a `hold` (even a valid dated one - holds park the BOARD
# CARD, never this gate), not `successor_created`, not an UNCONFIRMED `captain_batch`, not
# a narrative "I handled it", and never any cached triage summary.
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
# Ships with TRACKED harness hook files at the repo root, so this file lands in
# every home and worktree of this repo: the primary home, every secondmate home
# (treehouse-leased or git-cloned), and any crewmate/scout task worktree spawned
# to work on firstmate itself (the recursive "firstmate improving itself" case).
# A secondmate home runs its OWN primary firstmate session, so it must be
# guarded like the main primary; only child crew/scout worktrees are exempt. It
# must therefore scope itself at runtime to a real primary - the main home or a
# genuinely marked secondmate home - and stay a silent, fast no-op everywhere
# else. A deployed primary home is NOT necessarily a git checkout - the live
# runtime home is a rebaselined, non-git tree - so scoping identifies the
# primary from what a home IS, never from git-ness. See the scoping block below.
#
# Loop-guard: never block twice in the same turn. Claude Code and codex Stop
# payloads carry stop_hook_active=true when the CURRENT stop attempt was itself
# already forced by an earlier block this turn; on that signal we always allow
# the stop, whether or not anything actually got fixed. Passive harness
# adapters provide their own one-follow-up guard before calling this script.
# That bounds this to at most one forced continuation per turn - never a
# wedged, un-endable session - while still nagging again on a later turn if the
# problem persists. The permit is PROGRESS-AWARE in the record (ORD-059
# section 1): a loop-guarded stop is logged as allowed_needs_firstmate_empty or allowed_after_valid_progress
# only when the lane is clear or the blocked id set actually shrank; otherwise
# it is logged as allowed_loop_protection_without_progress, which is an enforcement stand-down,
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

# --- scope precisely to the PRIMARY home ------------------------------------
# Identify the primary POSITIVELY, from what a firstmate home IS. Git-ness is a
# DISCRIMINATOR APPLIED WHERE IT APPLIES, never a precondition for this gate to
# exist at all.
#
# This scoping used to open with `git rev-parse --git-dir || exit 0`. A deployed
# runtime home is a REBASELINED, NON-GIT tree - bin/ is a plain directory and there
# is no .git - so in the one place the gate is actually installed, git rev-parse
# failed and the guard exited before evaluating anything. It could never fire where
# it was deployed, while every test suite (which builds a git fixture) stayed green
# (bug-20260714023716-7c5e1bfb). Both deployment shapes must work: a git-checkout
# home (the template/dev shape) AND a non-git rebaselined runtime home.
#
# A PRIMARY home is one that:
#   - has the shape of a firstmate home: AGENTS.md, bin/, and a state/ dir (the
#     state dir is the FM_HOME/FM_STATE_OVERRIDE one this evaluation would read);
#   - is the main home OR a genuinely marked secondmate home. A secondmate home
#     runs its OWN primary firstmate session, so a GENUINE .fm-secondmate-home
#     marker (written by bin/fm-home-seed.sh at seed time, treehouse-leased or
#     git-cloned alike) force-INCLUDES it as a guarded primary whether it is a
#     linked worktree or a plain checkout;
#   - is NOT a crewmate/scout task worktree of firstmate-on-itself. bin/fm-spawn.sh
#     only ever hands those out as genuine linked `git worktree`s - it aborts the
#     spawn otherwise - so WHEN the root is an UNMARKED git checkout root the
#     linked-worktree test still discriminates exactly: a linked worktree's git-dir
#     lives under the main repo's .git/worktrees/<name> and differs from the common
#     (shared) git-dir, while a main checkout has the two equal. A root that is not
#     a git checkout root cannot be one of those worktrees, so it is not excluded;
#   - is not a session that another live session has locked out (below).
# Scoping runs BEFORE the jq dependency check so a guard-error alarm can only ever
# fire in a home that is actually a primary.

# Return 0 when $1 (a firstmate root) carries a GENUINE secondmate-home marker.
# bin/fm-home-seed.sh writes .fm-secondmate-home at a seeded secondmate home's
# root (gitignored, so it never propagates into a child worktree); its content is
# the secondmate id. Validate the marker's form so a stray/empty/symlink file
# cannot spoof inclusion and an unmarked child is never guarded by accident: it
# must be a regular (non-symlink) file whose first line, with all whitespace
# removed, is a non-empty id token (letters, digits, dot, underscore, dash only).
# The allowlist is matched under forced C (ASCII) collation - `local LC_ALL=C`,
# restored on return - so a locale-crafted non-ASCII id cannot slip through the
# range match and spoof force-inclusion. This is a deliberately lightweight
# guard-local presence check, distinct from fm-ff-lib.sh's validate_secondmate_home
# (which matches an EXPECTED id and does path-safety); the guard does not source
# that heavier library.
fm_root_is_secondmate_home() {
  local marker="$1/.fm-secondmate-home" id LC_ALL=C
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  IFS= read -r id < "$marker" 2>/dev/null || return 1
  id=${id//[[:space:]]/}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# A genuinely-marked secondmate home is force-included as a guarded primary
# (whether treehouse leased it as a linked worktree or it is a git-cloned plain
# checkout); only an unmarked root falls through to the linked-worktree
# exemption below.
SECONDMATE_PRIMARY=0
if fm_root_is_secondmate_home "$FM_ROOT" || fm_root_is_secondmate_home "$FM_HOME"; then
  SECONDMATE_PRIMARY=1
fi
[ -f "$FM_ROOT/AGENTS.md" ] || exit 0
[ -d "$FM_ROOT/bin" ] || exit 0
[ -d "$STATE" ] || exit 0

# The linked-worktree exclusion, applied only where the concept exists and never to a
# genuinely marked secondmate home (a treehouse-leased secondmate home IS a linked
# worktree, but it runs its own primary session and must stay guarded). The toplevel
# comparison keeps this precise: it fires on a task worktree (whose root IS the git
# toplevel), not on a non-git home that merely happens to sit inside some unrelated
# repo's tree.
GIT_TOP=$(git -C "$FM_ROOT" rev-parse --show-toplevel 2>/dev/null || true)
if [ "$SECONDMATE_PRIMARY" -eq 0 ] && [ -n "$GIT_TOP" ] && [ "$(cd "$GIT_TOP" 2>/dev/null && pwd -P)" = "$(cd "$FM_ROOT" && pwd -P)" ]; then
  GIT_DIR=$(git -C "$FM_ROOT" rev-parse --git-dir 2>/dev/null || true)
  GIT_COMMON_DIR=$(git -C "$FM_ROOT" rev-parse --git-common-dir 2>/dev/null || true)
  [ -n "$GIT_DIR" ] && [ "$GIT_DIR" != "$GIT_COMMON_DIR" ] && exit 0
fi

# A session that does not own this home must not act on it. The per-home session lock
# (state/.lock, written by bin/fm-lock.sh) names the harness pid that holds the fleet;
# a session that could not acquire it operates read-only (AGENTS.md section 3) and has
# no supervision of its own to resume, so this guard must neither block it nor write
# the decision log, the block-id set, or the wake queue from it.
#
# FAIL ARMED, never inert: only a PROVABLY foreign live holder stands the guard down.
# An absent lock, a garbage lock, a dead holder, or an ancestry walk that cannot be
# completed all leave the guard armed. An unreadable lock must never become a second
# quiet way for this gate not to exist - that is the bug this scoping fix is for.
[ "$(fm_session_lock_owner "$STATE")" = other ] && exit 0

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
  printf '{"ts":"%s","watcher":"unknown","in_flight":-1,"needs_firstmate":-1,"nf_items":"","nf_gate":"on","nf_error":"%s","decision":"allowed_guard_error","reason":"%s","loop_protection":false}\n' \
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
# The sweep runs in a subshell so a broken library can never poison this shell, and under
# timeout(1) where available so a hung read is classified instead of hanging the hook (the
# harness's own hook timeout would fail open anyway, but invisibly). Exit codes 3/4 are the
# subshell's own bounded classification; 124 is timeout(1)'s.
NF_LIB="$SCRIPT_DIR/fm-nf-attention-lib.sh"
# shellcheck disable=SC2016 # A bash -c program: $1/$2/$3 are the subshell's args, not this shell's.
NF_SWEEP='. "$1" 2>/dev/null || exit 3
command -v fm_nf_unattended_ids >/dev/null 2>&1 || exit 4
fm_nf_unattended_ids "$2" "$3"'
if [ ! -f "$NF_LIB" ]; then
  nf_error='fm-nf-attention-lib.sh missing'
else
  if command -v timeout >/dev/null 2>&1; then
    nf_ids=$(timeout "${FM_TURNEND_SWEEP_TIMEOUT:-30}" bash -c "$NF_SWEEP" _ "$NF_LIB" "$STATE" "$DATA" 2>/dev/null)
    sweep_rc=$?
  else
    nf_ids=$(bash -c "$NF_SWEEP" _ "$NF_LIB" "$STATE" "$DATA" 2>/dev/null)
    sweep_rc=$?
  fi
  case "$sweep_rc" in
    0) : ;;
    3) nf_error='fm-nf-attention-lib.sh failed to source'; nf_ids='' ;;
    4) nf_error='fm_nf_unattended_ids undefined after source'; nf_ids='' ;;
    124) nf_error='fm_nf_unattended_ids timed out'; nf_ids='' ;;
    *) nf_error='fm_nf_unattended_ids failed'; nf_ids='' ;;
  esac
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
# The decision taxonomy (ORD-060 section 1, outcome names as prescribed there). Only the
# first two are compliant permits; the acceptance metric "zero permitted turn ends while
# unattended Needs FirstMate work exists" counts every other permitted outcome against it.
#   allowed_needs_firstmate_empty    the lane was genuinely empty and the watcher healthy.
#   allowed_after_valid_progress     loop-guarded stop after real progress: the id set the
#                                    turn was blocked on actually shrank.
#   blocked_needs_firstmate          refused (exit 2) with unattended work named; the
#                                    watcher may be down too (the reason says so).
#   blocked_watcher_down             refused (exit 2) for the watcher alone.
#   allowed_loop_protection_without_progress  permitted ONLY because hook recursion
#                                    protection forbids a second block in one turn and
#                                    nothing was discharged; a durable check wake is queued
#                                    so the work fronts the next primary turn. NOT proof
#                                    the work was handled.
#   allowed_guard_error              permitted because state could not be inspected. NOT
#                                    proof of anything.
#   allowed_duty_disabled            permitted because the FM_TRIAGE_DUTY=off kill switch
#                                    is engaged (loud on stderr, never silent).
#   allowed_afk_owner                permitted because away mode owns supervision.
#
# The watcher's verdict alone is NOT enough to explain a decision, so each record also
# carries the OBSERVATIONS behind it: the lock pid, whether that pid was alive, each
# identity/home/path comparison, the beacon age, and which check failed first
# (FM_WATCHER_DIAG_*, set by fm_watcher_healthy in bin/fm-wake-lib.sh). Logging only
# watcher=down left every field that could explain a block null, and "no live watcher
# (last beat: 1s ago)" reads as impossible until you can see WHICH check failed - the
# beacon outlives the watcher that touched it, so a fresh beacon with an ABSENT lock is
# both real and normal after a watcher exits on a wake. That gap cost three wrong
# diagnoses of a genuine supervision collapse (a broken check waking the watcher every
# cycle, so it exited and released the lock every cycle). fail=no-lock-pid with a fresh
# beacon_age says it in one line.
# Best-effort: a log that cannot be written must never change the decision or wedge the turn.
log_decision() {  # <decision> <reason>
  local line beacon_age
  beacon_age=${FM_WATCHER_DIAG_BEACON_AGE:-}
  case "$beacon_age" in
    ''|*[!0-9]*) beacon_age=null ;;
  esac
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
    --argjson beacon_age "$beacon_age" \
    --arg lock_pid "${FM_WATCHER_DIAG_LOCK_PID:-none}" \
    --arg lock_pid_alive "${FM_WATCHER_DIAG_PID_ALIVE:-unknown}" \
    --arg identity_match "${FM_WATCHER_DIAG_IDENTITY_MATCH:-unknown}" \
    --arg home_match "${FM_WATCHER_DIAG_HOME_MATCH:-unknown}" \
    --arg path_match "${FM_WATCHER_DIAG_PATH_MATCH:-unknown}" \
    --arg watcher_fail "${FM_WATCHER_DIAG_FAIL:-unknown}" \
    --argjson loop_protection "$([ "$STOP_HOOK_ACTIVE" = true ] && echo true || echo false)" \
    '{ts: $ts, watcher: $watcher, in_flight: $in_flight, needs_firstmate: $nf,
      nf_items: $nf_items, nf_gate: $nf_gate, nf_error: $nf_error,
      decision: $decision, reason: $reason, loop_protection: $loop_protection,
      beacon_age: $beacon_age, lock_pid: $lock_pid, lock_pid_alive: $lock_pid_alive,
      identity_match: $identity_match, home_match: $home_match, path_match: $path_match,
      watcher_fail: $watcher_fail}' 2>/dev/null) \
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
    afk) log_decision allowed_afk_owner 'away mode owns supervision'; exit 0 ;;
    duty-off) log_decision allowed_duty_disabled 'FM_TRIAGE_DUTY=off kill switch engaged'; exit 0 ;;
  esac
  if [ -n "$nf_error" ]; then
    guard_error_banner "$nf_error" 'the loop-guarded stop is permitted, but the lane state is unknown.'
    log_decision allowed_guard_error "$nf_error"
    signal_guard_error_bug "$nf_error" 'needs_firstmate lane read failed on the turn-end path'
    exit 0
  fi
  if [ "$nf" -eq 0 ]; then
    if [ "$blind" -eq 1 ]; then
      log_decision allowed_loop_protection_without_progress 'loop protection forced the permit; the watcher is still down'
    else
      mark_healthy
      log_decision allowed_needs_firstmate_empty 'lane empty, supervision healthy'
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
    log_decision allowed_after_valid_progress 'the unattended id set shrank since the blocked attempt'
  else
    # The turn is ending with unresolved terminal work and only recursion protection let it
    # (the hook contract forbids a second block; a wedged primary is worse). The limitation
    # is not hidden: beyond the honest decision record, queue one durable check wake so
    # bin/fm-wake-drain.sh puts the unresolved items at the FRONT of the next primary turn.
    # Deduped: one pending record at a time, or a stuck pile would flood the queue.
    if command -v fm_wake_append >/dev/null 2>&1 \
      && ! grep -q "	check	turnend-guard	" "$STATE/.wake-queue" 2>/dev/null; then
      fm_wake_append check turnend-guard \
        "turn ended with unresolved terminal work under loop protection: $nf_digest - handle these before any new work" \
        >/dev/null 2>&1 || true
    fi
    log_decision allowed_loop_protection_without_progress 'loop protection forced the permit; no unattended item was discharged'
  fi
  exit 0
fi

# First stop attempt of the turn. Stand-downs and read failures on the unattended-work axis
# never mask the independent watcher predicate below.
if [ "$blind" -eq 0 ]; then
  case "$nf_gate" in
    afk)
      if [ "$nf" -gt 0 ] || [ -n "$nf_error" ]; then
        log_decision allowed_afk_owner 'away mode owns supervision'
      else
        log_decision allowed_needs_firstmate_empty 'lane empty, supervision healthy (away mode)'
      fi
      exit 0
      ;;
    duty-off)
      if [ "$nf" -gt 0 ] || [ -n "$nf_error" ]; then
        log_decision allowed_duty_disabled 'FM_TRIAGE_DUTY=off kill switch engaged'
      else
        log_decision allowed_needs_firstmate_empty 'lane empty, supervision healthy (kill switch engaged)'
      fi
      exit 0
      ;;
  esac
  if [ -n "$nf_error" ]; then
    guard_error_banner "$nf_error" 'this turn end is permitted fail-open; the lane state is unknown.'
    log_decision allowed_guard_error "$nf_error"
    signal_guard_error_bug "$nf_error" 'needs_firstmate lane read failed on the turn-end path'
    exit 0
  fi
  if [ "$nf" -eq 0 ]; then
    mark_healthy
    log_decision allowed_needs_firstmate_empty 'lane empty, supervision healthy'
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
    # Those two lines look self-contradictory on their own: the beacon outlives the
    # watcher that touched it, so a fresh beacon with an ABSENT lock is real. Say what
    # was actually observed, and which check decided it.
    printf '●  observed: lock pid=%s alive=%s identity=%s home=%s path=%s beacon=%ss -> %s\n' \
      "${FM_WATCHER_DIAG_LOCK_PID:-none}" \
      "${FM_WATCHER_DIAG_PID_ALIVE:-unknown}" \
      "${FM_WATCHER_DIAG_IDENTITY_MATCH:-unknown}" \
      "${FM_WATCHER_DIAG_HOME_MATCH:-unknown}" \
      "${FM_WATCHER_DIAG_PATH_MATCH:-unknown}" \
      "${FM_WATCHER_DIAG_BEACON_AGE:-unknown}" \
      "${FM_WATCHER_DIAG_FAIL:-unknown}"
    printf '●  %s\n' "$REASON"
    printf '●  full decision record: %s\n' "$LOG"
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
    printf '●  Acks, surfaces, claims, holds, successors, and unconfirmed captain batches\n'
    printf '●  do not either - they park the board card, never this gate. An item leaves\n'
    printf '●  this list only when its work is landed, torn down, genuinely resolved or\n'
    printf '●  rejected with lineage, verifiably handed to the captain (fm-nf-ack.sh\n'
    printf '●  --to-captain, board-confirmed), or its crew status moves off the terminal\n'
    printf '●  verb (a steer to paused:, a resolved: follow-up):\n'
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
if [ "$nf_blocking" -eq 1 ]; then
  log_decision blocked_needs_firstmate "$block_reason"
else
  log_decision blocked_watcher_down "$block_reason"
fi
exit 2

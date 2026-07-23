#!/usr/bin/env bash
# Turn-end guard for any firstmate PRIMARY session: the main home OR a
# secondmate's own home. A secondmate runs its own primary firstmate session and
# is guarded exactly like the main primary; only child crew/scout worktrees are
# exempt (see the scoping block below and docs/turnend-guard.md).
#
# It blocks a turn end for any of three independent reasons: supervision is off (tasks in
# flight, no live watcher); finished crew work is still unattended (the needs_firstmate lane
# is non-empty, read live from local task state at the moment of evaluation); or captain
# orders are unaccounted past grace (ORD-260 slice S2 - a cheap read of the deterministic
# audit file state/.order-audit-last.json written by `fm-order.sh audit`, never a
# re-enumeration). See "the actual predicate" below for why each exists and how each is
# bounded. Every primary evaluation - permitted or blocked - is recorded in the decision log
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
# The checkout that SUPPLIED this Stop hook, resolved from the script's own location
# and NEVER from FM_ROOT_OVERRIDE. The linked-worktree exemption is a question about
# WHERE THE HOOK LIVES (a crewmate/scout task worktree vs a primary home), which is
# fixed by the script path, not by the operational root the session reads state from.
# Production crewmates inherit FM_ROOT_OVERRIDE=<runtime>, a deliberately non-git tree,
# so an FM_ROOT-based exemption inspected the runtime's absent .git, skipped the
# exclusion, and let the crew worktree run the primary sweep and fail open - the exact
# reopening of ORD-231's failure path found by qa-g2-q4 finding 1. HOOK_ROOT closes it.
HOOK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$HOOK_ROOT}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"
HARNESS=${FM_SUPERVISION_HARNESS:-}
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
HARNESS=$(fm_supervision_primary_harness "$STATE" "$FM_HOME" "$HARNESS")
# The fm-harness.sh subprocess runs only when neither the durable record nor
# the ambient environment answers - never unconditionally on this hot path.
case "$HARNESS" in
  ''|unknown) HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown) ;;
esac

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

# Return 0 when <root>/.git identifies a LINKED git worktree, git-binary-independently.
# A linked worktree's .git is a regular file whose "gitdir:" target lives under the main
# repo's .git/worktrees/<name>; that /worktrees/ path is the discriminator. It is exactly
# what bin/fm-spawn.sh hands a crewmate/scout firstmate-on-itself task, and it distinguishes
# a linked worktree from BOTH a plain checkout (whose .git is a directory) AND a
# separate-git-dir main checkout (whose .git is also a file but whose "gitdir:" target is
# its own git dir, outside any worktrees/ path - qa-g2-q4 finding 4). No `git` invocation,
# so a transient/broken git can never reopen the exemption.
hook_root_is_linked_worktree() {  # <root>
  local gitfile="$1/.git" line
  [ -L "$gitfile" ] && return 1
  [ -f "$gitfile" ] || return 1
  IFS= read -r line < "$gitfile" 2>/dev/null || return 1
  case "$line" in
    'gitdir: '*'/worktrees/'*) return 0 ;;
    'gitdir:'*'/worktrees/'*) return 0 ;;
  esac
  return 1
}

# A genuinely-marked secondmate home is force-included as a guarded primary
# (whether treehouse leased it as a linked worktree or it is a git-cloned plain
# checkout); only an unmarked root falls through to the linked-worktree
# exemption below.
# The secondmate force-include is keyed on the HOOK CHECKOUT first (a secondmate runs its
# own primary session from its own home, so HOOK_ROOT is that home), then the operational
# roots for compatibility. A crewmate worktree never carries the gitignored marker, so this
# can never spoof-include one.
SECONDMATE_PRIMARY=0
if fm_root_is_secondmate_home "$HOOK_ROOT" || fm_root_is_secondmate_home "$FM_ROOT" || fm_root_is_secondmate_home "$FM_HOME"; then
  SECONDMATE_PRIMARY=1
fi

# FAIL-CLOSED linked-worktree exclusion, resolved from the HOOK CHECKOUT (HOOK_ROOT) and
# git-binary-INDEPENDENT, applied BEFORE any state-shaped check or log write so an excluded
# crew worktree leaves no trace. bin/fm-spawn.sh only ever hands a crewmate/scout
# firstmate-on-itself task a genuine linked worktree; hook_root_is_linked_worktree() names
# one precisely (a .git gitfile targeting a .../worktrees/ path), which no transient/broken
# git can defeat and which does not misfire on a separate-git-dir primary. A genuinely-marked
# secondmate home is force-included above and must NOT be excluded here, even though a
# treehouse-leased one IS a linked worktree.
if [ "$SECONDMATE_PRIMARY" -eq 0 ] && hook_root_is_linked_worktree "$HOOK_ROOT"; then
  exit 0
fi

[ -f "$FM_ROOT/AGENTS.md" ] || exit 0
[ -d "$FM_ROOT/bin" ] || exit 0
[ -d "$STATE" ] || exit 0

# The git-based linked-worktree exclusion, kept as a secondary discriminator on HOOK_ROOT for
# the case a checkout's .git is a directory but git-dir still differs from git-common-dir.
# Applied only where the concept exists and never to a genuinely marked secondmate home. The
# toplevel comparison keeps this precise: it fires on a task worktree (whose root IS the git
# toplevel), not on a non-git home that merely happens to sit inside some unrelated repo's
# tree. This is a fallback only - the git-independent file check above is authoritative for
# the linked-worktree shape and never depends on `git` succeeding.
GIT_TOP=$(git -C "$HOOK_ROOT" rev-parse --show-toplevel 2>/dev/null || true)
if [ "$SECONDMATE_PRIMARY" -eq 0 ] && [ -n "$GIT_TOP" ] && [ "$(cd "$GIT_TOP" 2>/dev/null && pwd -P)" = "$(cd "$HOOK_ROOT" && pwd -P)" ]; then
  GIT_DIR=$(git -C "$HOOK_ROOT" rev-parse --git-dir 2>/dev/null || true)
  GIT_COMMON_DIR=$(git -C "$HOOK_ROOT" rev-parse --git-common-dir 2>/dev/null || true)
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

# Caller identity for every guard-error record and decision-log line, so a guard_error can
# be traced to the process that produced it - the traceability gap that made ORD-231's
# duplicate bugs impossible to attribute (data/turnend-failopen-x6/report.md sections 4 and
# 6.1). Read from globals at call time; FM_ROOT, STATE, and HARNESS are all resolved before
# any guard-error path runs. Pure-builtin cwd (pwd), so it works even on a degraded PATH.
guard_caller_cwd() { pwd -P 2>/dev/null || pwd 2>/dev/null || printf '?'; }
guard_caller_host() { uname -n 2>/dev/null || printf '?'; }
guard_caller_line() {
  printf 'fm_root=%s state=%s cwd=%s hook_source=%s host=%s pid=%s' \
    "$FM_ROOT" "$STATE" "$(guard_caller_cwd)" "${HARNESS:-unknown}" "$(guard_caller_host)" "$$"
}
# Minimal JSON string escaping via bash parameter expansion (no external command), so the
# jq-free guard-error record path stays valid even when jq itself is the failed component.
json_escape() {  # <string>
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

# The fleet-wide coalescing store for the durable guard-error bug signal. It must be shared
# across every firstmate home and worktree for the user, because the failure fires in many
# of them at once (the shipped Stop hook runs the primary guard in every firstmate-repo
# worktree). Default to a per-user cache path; FM_GUARD_ERROR_COALESCE_DIR overrides it
# (tests point it at a temp dir), and a home with no HOME/cache falls back to its own state.
guard_error_coalesce_dir() {
  if [ -n "${FM_GUARD_ERROR_COALESCE_DIR:-}" ]; then
    printf '%s' "$FM_GUARD_ERROR_COALESCE_DIR"
  elif [ -n "${XDG_CACHE_HOME:-}" ]; then
    printf '%s/firstmate/guard-error' "$XDG_CACHE_HOME"
  elif [ -n "${HOME:-}" ]; then
    printf '%s/.cache/firstmate/guard-error' "$HOME"
  else
    printf '%s/.guard-error-coalesce' "$STATE"
  fi
}

# Round 4 migration helper only: older guard builds used <slug>.lock as a mkdir lock
# directory with pid/epoch metadata. The flock rewrite below uses that same path as a
# kernel-owned lock file, so a leftover directory must be cleared first. New code never
# creates lock directories. Missing, malformed, or dead-owner metadata is therefore safely
# treated as a stale legacy artifact; a live owner is given a bounded wait and then skipped.
guard_error_clear_legacy_lock_dir() {  # <lock-path> <now-epoch>
  local lock=$1 now=$2 waited=0 hpid hepoch stale wait_s
  [ -d "$lock" ] || return 0
  stale=${FM_GUARD_ERROR_LOCK_STALE:-30}
  case "$stale" in *[!0-9]*) stale=30 ;; '') stale=30 ;; esac
  wait_s=${FM_GUARD_ERROR_FLOCK_WAIT:-5}
  case "$wait_s" in *[!0-9]*) wait_s=5 ;; '') wait_s=5 ;; esac
  while [ -d "$lock" ]; do
    hpid=''; hepoch=''
    IFS= read -r hpid < "$lock/pid" 2>/dev/null || hpid=''
    IFS= read -r hepoch < "$lock/epoch" 2>/dev/null || hepoch=''
    case "$hpid" in *[!0-9]*) hpid='' ;; esac
    case "$hepoch" in *[!0-9]*) hepoch=0 ;; '') hepoch=0 ;; esac
    if [ -z "$hpid" ] \
       || ! kill -0 "$hpid" 2>/dev/null \
       || { [ "$hepoch" -gt 0 ] && [ "$((now - hepoch))" -ge "$stale" ]; }; then
      rm -rf "$lock" 2>/dev/null || true
      [ -d "$lock" ] || return 0
      continue
    fi
    waited=$((waited + 1))
    [ "$waited" -ge "$wait_s" ] && return 1
    sleep 1 2>/dev/null || true
  done
  return 0
}

guard_error_lock_failure_fallback() {  # <slug> <dir> <component> <detail> <reason> <now> <caller> <cli>
  local slug=$1 dir=$2 component=$3 detail=$4 reason=$5 now=$6 caller=$7 cli=$8 fallback bug_id
  fallback="$dir/$slug.lock-fallback.occurrences"
  printf '%s\tpid=%s\tlock_failure=%s\t%s\n' "$now" "$$" "$reason" "$caller" >> "$fallback" 2>/dev/null || true
  bug_id=''
  if [ -n "$cli" ] && [ "$cli" != off ] && [ -x "$cli" ]; then
    bug_id=$("$cli" record "turn-end guard could not record its coalesced guard-error signal ($component): coalescing lock failure: $reason. Original detail: $detail. Caller: $caller. Fallback occurrence path: $fallback. The unattended-work gate is failing open until this is repaired." \
      --quiet 2>/dev/null) || bug_id=''
  fi
  {
    printf '●%s\n' "$rule"
    printf '●  TURN-END GUARD COALESCING LOCK FAILURE\n'
    printf '●  %s\n' "$reason"
    printf '●  Fallback occurrence path: %s\n' "$fallback"
    if [ -n "$bug_id" ]; then
      printf '●  Fallback bug signal: %s\n' "$bug_id"
    elif [ -n "$cli" ] && [ "$cli" != off ]; then
      printf '●  Fallback bug signal: attempted but not confirmed.\n'
    else
      printf '●  Fallback bug signal: unavailable or disabled.\n'
    fi
    printf '●%s\n' "$rule"
  } >&2
}

# Raise the durable health signal through the sanctioned bug CLI (the same one the triage
# enumerator's bugs lane reads; FM_FLEET_TRIAGE_BUG_CLI overrides it, `off` disables).
#
# COALESCED, FLEET-WIDE, TIME-WINDOWED (ORD-231). The old per-$STATE marker could not stop a
# DIFFERENT home or worktree from re-filing the identical text, and the next healthy
# evaluation cleared it, so an INTERMITTENT failure filed a fresh captain bug on every
# recurrence - ~58 identical open bugs in three days (data/turnend-failopen-x6/report.md
# sections 5 and 6.4). This keys on the failure fingerprint (the component slug) in a shared
# store: the FIRST occurrence in a window files ONE bug carrying caller identity; every later
# occurrence with the same fingerprint only updates the shared record. After the window
# elapses a genuinely-new recurrence surfaces a fresh bug, so a real regression is never muted
# forever. Best-effort in every direction: a coalescing failure never changes the fail-open
# decision.
#
# CRUCIALLY, coalescing suppresses only DUPLICATE bug FILINGS, never the occurrence itself.
# The round-3 lock-directory/lock-free append design is deliberately gone: it could lose a
# line during compaction and could strand an ownerless lock directory forever. Round 4 uses
# one kernel-owned flock for rotation, append, summary update, and bug-filing eligibility;
# rotation happens before the current append, so no append can land on an inode about to be
# replaced. The coalescing window advances ONLY on a CONFIRMED successful bug filing; a
# failed bug CLI leaves the signal eligible for a bounded retry rather than muting it for
# the whole window.
# Generalized (ORD-260 S2): the coalescing ENGINE is fingerprint-agnostic. <slug-source>
# derives the dedup fingerprint, <body> is the filed bug's human text, and the optional
# <occ-detail> is appended to each occurrence line. signal_guard_error_bug (guard-state read
# failures), signal_order_audit_anomaly, and signal_standdown_anomaly are thin wrappers, so
# every coalesced signal shares this one anti-spam mechanism - the structural fix for the
# bug-per-occurrence class (guard-error-spam-j6).
signal_coalesced_bug() {  # <slug-source> <body> [<occ-detail>]
  local cli slug dir rec lock occ window retry now caller k v
  local count first last_bug last_attempt bug_id new_id occ_dropped lines max keep drop
  local window_ok in_failure_backoff flock_wait

  slug=$(printf '%s' "$1" | tr -c 'a-zA-Z0-9' '-')
  dir=$(guard_error_coalesce_dir)
  window=${FM_GUARD_ERROR_COALESCE_WINDOW:-86400}
  case "$window" in *[!0-9]*) window=86400 ;; '') window=86400 ;; esac
  retry=${FM_GUARD_ERROR_BUG_RETRY:-60}
  case "$retry" in *[!0-9]*) retry=60 ;; '') retry=60 ;; esac
  now=$(date -u +%s 2>/dev/null || printf 0)
  caller=$(guard_caller_line)

  cli=${FM_FLEET_TRIAGE_BUG_CLI:-}
  if [ "$cli" != off ] && [ -z "$cli" ]; then
    cli=$(command -v bug 2>/dev/null || true)
  fi
  if [ "$cli" != off ] && { [ -z "$cli" ] || [ ! -x "$cli" ]; }; then
    cli=''
  fi

  mkdir -p "$dir" 2>/dev/null || {
    guard_error_lock_failure_fallback "$slug" "$dir" "$1" "$2" "coalescing directory create failed: $dir" "$now" "$caller" "$cli"
    return 0
  }
  rec="$dir/$slug.record"
  lock="$dir/$slug.lock"
  occ="$dir/$slug.occurrences"

  command -v flock >/dev/null 2>&1 || {
    guard_error_lock_failure_fallback "$slug" "$dir" "$1" "$2" 'flock command not found' "$now" "$caller" "$cli"
    return 0
  }
  guard_error_clear_legacy_lock_dir "$lock" "$now" || {
    guard_error_lock_failure_fallback "$slug" "$dir" "$1" "$2" "legacy lock migration timed out: $lock" "$now" "$caller" "$cli"
    return 0
  }
  flock_wait=${FM_GUARD_ERROR_FLOCK_WAIT:-5}
  case "$flock_wait" in *[!0-9]*) flock_wait=5 ;; '') flock_wait=5 ;; esac

  exec 9>"$lock" || {
    guard_error_lock_failure_fallback "$slug" "$dir" "$1" "$2" "lock file open failed: $lock" "$now" "$caller" "$cli"
    return 0
  }
  if [ "$flock_wait" -gt 0 ]; then
    if ! flock -w "$flock_wait" 9; then
      exec 9>&- || true
      guard_error_lock_failure_fallback "$slug" "$dir" "$1" "$2" "flock acquisition failed for $lock after ${flock_wait}s" "$now" "$caller" "$cli"
      return 0
    fi
  elif ! flock -n 9; then
    exec 9>&- || true
    guard_error_lock_failure_fallback "$slug" "$dir" "$1" "$2" "flock acquisition failed for $lock without waiting" "$now" "$caller" "$cli"
    return 0
  fi

  (
    trap 'rm -f "$rec.tmp.$$" "$occ.tmp.$$" 2>/dev/null || true; exec 9>&- || true' EXIT HUP INT TERM

    count=0
    first=$now
    last_bug=0
    last_attempt=0
    bug_id='-'
    occ_dropped=0
    if [ -f "$rec" ]; then
      while IFS='=' read -r k v; do
        case "$k" in
          first_seen) first=$v ;;
          last_bug_epoch) last_bug=$v ;;
          last_attempt_epoch) last_attempt=$v ;;
          bug_id) bug_id=$v ;;
          occ_dropped) occ_dropped=$v ;;
        esac
      done < "$rec"
      case "$last_bug" in *[!0-9]*) last_bug=0 ;; '') last_bug=0 ;; esac
      case "$last_attempt" in *[!0-9]*) last_attempt=0 ;; '') last_attempt=0 ;; esac
      case "$first" in *[!0-9]*) first=$now ;; '') first=$now ;; esac
      case "$occ_dropped" in *[!0-9]*) occ_dropped=0 ;; '') occ_dropped=0 ;; esac
    fi

    # Rotate before appending the current occurrence. Because rotation and append share one
    # flock, no concurrent append can target an old inode that is about to be replaced. Guard
    # the file-existence check first: a bare `< "$occ"` on a not-yet-created occurrence file
    # leaks a shell redirection error past `2>/dev/null` (the redirect is attempted before it
    # applies), which the first coalesced signal in a home would otherwise print to stderr.
    if [ -f "$occ" ]; then
      lines=$(wc -l < "$occ" 2>/dev/null || printf 0)
    else
      lines=0
    fi
    lines=${lines//[!0-9]/}
    [ -n "$lines" ] || lines=0
    max=${FM_GUARD_ERROR_OCC_MAX:-1000}
    case "$max" in *[!0-9]*) max=1000 ;; '') max=1000 ;; esac
    if [ "$lines" -ge "$max" ]; then
      keep=$((max / 2))
      [ "$keep" -ge 1 ] || keep=1
      drop=$((lines - keep))
      if tail -n "$keep" "$occ" > "$occ.tmp.$$" 2>/dev/null && mv -f "$occ.tmp.$$" "$occ" 2>/dev/null; then
        occ_dropped=$((occ_dropped + drop))
        lines=$keep
      else
        rm -f "$occ.tmp.$$" 2>/dev/null || true
      fi
    fi

    occ_field=$caller
    [ -n "${3:-}" ] && occ_field=$(printf '%s\t%s' "$caller" "$3")
    if printf '%s\tpid=%s\t%s\n' "$now" "$$" "$occ_field" >> "$occ" 2>/dev/null; then
      lines=$((lines + 1))
    fi
    count=$((occ_dropped + lines))

    # File one captain bug per fingerprint per window - but advance the window ONLY on a
    # CONFIRMED success. A failed CLI keeps last_bug where it was so the signal stays
    # eligible on the next occurrence, with a short retry backoff only after failed attempts.
    window_ok=0
    { [ "$last_bug" -eq 0 ] || [ "$((now - last_bug))" -ge "$window" ]; } && window_ok=1
    in_failure_backoff=0
    { [ "$last_attempt" -gt "$last_bug" ] && [ "$((now - last_attempt))" -lt "$retry" ]; } && in_failure_backoff=1
    if [ -n "$cli" ] && [ "$cli" != off ] && [ "$window_ok" -eq 1 ] && [ "$in_failure_backoff" -eq 0 ]; then
      last_attempt=$now
      new_id=$("$cli" record "$2 Caller: $caller. Coalesced per failure fingerprint ($slug): every occurrence is serialized under flock into $occ (aggregated, count=$count) and repeat occurrences update the shared record ($rec) instead of filing new bugs; see state/.turnend-guard.log for the guard's decision records." \
        --quiet 2>/dev/null) || new_id=''
      if [ -n "$new_id" ]; then
        bug_id=$new_id
        last_bug=$now
      fi
    fi

    # Persist the shared record (plain key=value; never sourced back, so no code-exec risk).
    if {
      printf 'fingerprint=%s\n' "$slug"
      printf 'first_seen=%s\n' "$first"
      printf 'last_bug_epoch=%s\n' "$last_bug"
      printf 'last_attempt_epoch=%s\n' "$last_attempt"
      printf 'last_seen=%s\n' "$now"
      printf 'count=%s\n' "$count"
      printf 'occ_dropped=%s\n' "$occ_dropped"
      printf 'bug_id=%s\n' "$bug_id"
      printf 'last_caller=%s\n' "$caller"
    } > "$rec.tmp.$$" 2>/dev/null; then
      mv -f "$rec.tmp.$$" "$rec" 2>/dev/null || rm -f "$rec.tmp.$$" 2>/dev/null
    else
      rm -f "$rec.tmp.$$" 2>/dev/null || true
    fi
  )
  exec 9>&- || true
  return 0
}

# Guard-state read-failure signal (the original caller): a fail-open guard error on the
# turn-end path. The fingerprint is the failed component, so distinct failures stay distinct.
signal_guard_error_bug() {  # <component> <detail>
  signal_coalesced_bug "$1" \
    "turn-end guard could not inspect fleet state ($1): $2. The unattended-work gate is failing open until this is repaired." \
    "component=$1"
}

# Order-audit read-failure signal (ORD-260 S2): the deterministic order-accounting file
# state/.order-audit-last.json was present but could not be trusted (unparseable, wrong
# schema, or a count that disagrees with its own list), so the third predicate fails open.
# A stale-but-valid file is a refresh-cadence gap, NOT a breakage, and is logged only - it
# never reaches this signal, so an unwired refresh cadence can never spam the bug ledger.
signal_order_audit_anomaly() {  # <reason>
  signal_coalesced_bug "order-audit-$1" \
    "turn-end guard could not trust the captain-order accounting file state/.order-audit-last.json ($1): the unaccounted-orders predicate is failing open until a valid \`fm-order.sh audit\` refreshes it." \
    "reason=$1"
}

# No-progress stand-down signal (ORD-260 S2, report section 5.1-C4): the harness loop guard
# forced a permit while unattended work or an unaccounted order remained. ONE coalesced,
# occurrence-counted anomaly - never a bug per turn - so a repeated enforcement stand-down is
# durably visible without reopening the bug-per-occurrence spam class this slice subsumes.
signal_standdown_anomaly() {  # <reason-text> [<ids-digest>]
  local digest=${2:-${combined_digest:-none}}
  [ -n "$digest" ] || digest=none
  signal_coalesced_bug turnend-standdown-no-progress \
    "turn-end guard stood the unattended-work / unaccounted-order gate down under loop protection without discharging work: $1. The harness loop guard forbids blocking a turn twice, so this is an enforcement stand-down, not a compliant permit." \
    "nf=$nf orders=$orders ids=$digest"
}

guard_error_banner() {  # <component> <detail>
  {
    printf '●%s\n' "$rule"
    printf '●  TURN-END GUARD ERROR - FLEET STATE COULD NOT BE INSPECTED\n'
    printf '●  Failed component: %s\n' "$1"
    printf '●  %s\n' "$2"
    printf '●  The unattended-work gate is FAILING OPEN: this turn end is permitted, but it\n'
    printf '●  is recorded as guard_error, not as a compliant permit. Repair the component;\n'
    printf '●  a durable bug signal will be attempted if the bug CLI is available.\n'
    printf '●  Any coalescing-lock failure is reported explicitly below.\n'
    printf '●%s\n' "$rule"
  } >&2
}

# ORD-260 S2: the order-accounting file was present but untrustworthy (corrupt/malformed).
# The unaccounted-orders predicate fails open, loudly, and raises one coalesced anomaly.
order_error_banner() {  # <reason> <detail>
  {
    printf '●%s\n' "$rule"
    printf '●  TURN-END GUARD: CAPTAIN-ORDER ACCOUNTING FILE COULD NOT BE TRUSTED\n'
    printf '●  Problem: %s\n' "$1"
    printf '●  %s\n' "$2"
    printf '●  The unaccounted-orders gate is FAILING OPEN for this turn. Refresh it with a\n'
    printf '●  valid run of bin/fm-order.sh audit; a durable bug signal will be attempted.\n'
    printf '●%s\n' "$rule"
  } >&2
}

# Log a guard_error decision without jq (jq itself may be the failed component). Every
# interpolated value here is guard-controlled text, never transcript content. Carries caller
# identity so even a jq-less guard_error is traceable to its originating process (ORD-231).
log_guard_error_raw() {  # <component>
  local esc_comp esc_root esc_state esc_cwd esc_host esc_hook
  esc_comp=$(json_escape "$1")
  esc_root=$(json_escape "$FM_ROOT")
  esc_state=$(json_escape "$STATE")
  esc_cwd=$(json_escape "$(guard_caller_cwd)")
  esc_host=$(json_escape "$(guard_caller_host)")
  esc_hook=$(json_escape "${HARNESS:-unknown}")
  printf '{"ts":"%s","watcher":"unknown","in_flight":-1,"needs_firstmate":-1,"nf_items":"","nf_gate":"on","nf_error":"%s","decision":"allowed_guard_error","reason":"%s","loop_protection":false,"fm_root":"%s","state_dir":"%s","cwd":"%s","hook_source":"%s","host":"%s","pid":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$esc_comp" "$esc_comp" "$esc_root" "$esc_state" "$esc_cwd" "$esc_hook" "$esc_host" "$$" >> "$LOG" 2>/dev/null || true
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
# THREE INDEPENDENT REASONS TO BLOCK, and any one alone is enough.
#
#   1. SUPERVISION IS OFF - tasks in flight with no live watcher. The original predicate,
#      unchanged below.
#   2. FINISHED WORK IS UNATTENDED - the needs_firstmate lane is non-empty, read LIVE from
#      state/<id>.meta plus state/<id>.status and the triage ledger at the moment of this
#      evaluation, never from a cached summary of them. A cache reflects the last duty
#      pass, not the present: it would miss work that finished since, and hold the turn
#      hostage for work already discharged.
#   3. CAPTAIN ORDERS UNACCOUNTED PAST GRACE (ORD-260 slice S2) - the deterministic audit
#      file state/.order-audit-last.json reports unaccounted > 0. This is a CHEAP FILE READ
#      of a script product (`fm-order.sh audit`, slice S1), NEVER a re-enumeration on the
#      turn-end path. It fails open on an absent/stale/corrupt file (see the order read
#      above), and enforces only a fresh, valid one.
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
# Why (3) exists, and why it is FLOOD-PROOF. Captain orders had the same asymmetry: an order
# dispatched then orphaned (crew died, or finished without closing the order) was surfaced by
# banners but compelled by nothing (report section 0). The gate demands ACCOUNTING, not
# completion: an order is discharged by linking live work, queuing it with a reason, a
# machine-checkable hold, a board-confirmed park/decision, or a terminal outcome with
# evidence - all cheap, all legitimate - so even 100 orders can be honestly accounted in
# bounded time (queue them with reasons; that IS accounting, and it is true), and a backfill
# flood gets the `fm-order.sh park --captain-ack` batch verb (one ack accounts the batch).
#
# Why (2) is scoped to ONLY the needs_firstmate lane, not all actionable items. That lane is
# bounded by the number of live tasks, it cannot be flooded by an audit backfill, and it is
# level-triggered off state/<id>.meta plus state/<id>.status - so it is discharged by LANDING
# or TEARING DOWN the work, never by paperwork. Gating on the full actionable set would let a
# backfill flood wedge the primary, which is exactly the liability a future session would
# rip out.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

fm_supervision_health "$STATE" "$WATCH" "$GRACE" "$FM_HOME" "$HARNESS"
blind=0
if [ "$FM_SUP_IN_FLIGHT" -gt 0 ] && [ "$FM_SUP_HEALTHY" = false ]; then
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
run_nf_sweep() {  # sets nf_ids and sweep_rc
  if command -v timeout >/dev/null 2>&1; then
    nf_ids=$(timeout "${FM_TURNEND_SWEEP_TIMEOUT:-30}" bash -c "$NF_SWEEP" _ "$NF_LIB" "$STATE" "$DATA" 2>/dev/null)
    sweep_rc=$?
  else
    nf_ids=$(bash -c "$NF_SWEEP" _ "$NF_LIB" "$STATE" "$DATA" 2>/dev/null)
    sweep_rc=$?
  fi
}
if [ ! -f "$NF_LIB" ]; then
  nf_error='fm-nf-attention-lib.sh missing'
else
  # BOUNDED RETRY before declaring guard_error (ORD-231). The sweep failure that spammed
  # ~58 duplicate captain bugs was TRANSIENT under concurrent Stop-hook fan-in, not a code
  # defect: the lib is byte-identical across homes and sources cleanly in isolation
  # (data/turnend-failopen-x6/report.md section 2). A small retry, well inside
  # FM_TURNEND_SWEEP_TIMEOUT, absorbs the transient case; a persistently-broken environment
  # still reports guard_error after the last attempt rather than hanging. A timeout (124) is
  # never retried - it already consumed the hook's budget.
  sweep_attempts=${FM_TURNEND_SWEEP_ATTEMPTS:-2}
  case "$sweep_attempts" in *[!0-9]*) sweep_attempts=2 ;; '') sweep_attempts=2 ;; esac
  [ "$sweep_attempts" -lt 1 ] && sweep_attempts=1
  sweep_try=1
  while :; do
    run_nf_sweep
    if [ "$sweep_rc" -eq 0 ] || [ "$sweep_rc" -eq 124 ] || [ "$sweep_try" -ge "$sweep_attempts" ]; then
      break
    fi
    sweep_try=$((sweep_try + 1))
    sleep "${FM_TURNEND_SWEEP_RETRY_DELAY:-0.2}" 2>/dev/null || true
  done
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

# --- UNACCOUNTED CAPTAIN ORDERS: the third blocking predicate --------------------------
# ORD-260 slice S2, report section 5.1-C4. A CHEAP FILE READ of the deterministic audit
# product state/.order-audit-last.json (written by `fm-order.sh audit`, slice S1) - NEVER a
# re-enumeration of the inbox on the turn-end path. The audit already accounts every order
# younger than its accounting grace via its `fresh` branch, so the file's `unaccounted`
# count IS unaccounted_orders_past_grace, and `unaccounted > 0` blocks exactly as
# needs_firstmate does. Discharge is by REAL accounting acts (link live work, queue with a
# reason and blocker, machine-checkable hold, board-confirmed park/decision, or a terminal
# outcome with evidence) FOLLOWED BY a fresh `fm-order.sh audit`; re-running the audit alone
# never discharges, because the predicate is over the orders, not over the file.
#
# FAIL OPEN, inheriting the guard's discipline:
#   - absent          -> the audit is not wired in this home (S2 can ship ahead of the
#                        refresh cadence); the predicate does not fire. No block, no anomaly.
#   - stale           -> a not-refreshed file is a refresh-cadence gap, not a breakage:
#                        fail open, log order_error, but NO bug (that would reopen the very
#                        bug-per-occurrence spam this slice removes for an unwired cadence).
#   - unreadable/malformed/count-mismatch -> the writer produced an untrustworthy file: fail
#                        open, loud banner, and ONE coalesced anomaly (the design's
#                        fail-open-with-coalesced-anomaly discipline).
#   - present, parseable, fresh -> ENFORCE.
ORDER_AUDIT="${FM_ORDER_AUDIT_FILE:-$STATE/.order-audit-last.json}"
orders=0
order_ids=''
order_error=''
order_audit_age=''   # empty => file absent (predicate did not fire); else integer seconds
# order_authoritative is the LINCHPIN of the retry state machine (QA qa-dj-s2r2-q106): it is 1
# ONLY for a present, parseable, valid, FRESH file whose ids read cleanly. Absent, stale, and
# corrupt reads are all non-authoritative (0). A non-authoritative read can never DISCHARGE a
# previously blocked order on a loop-guarded retry - only a fresh authoritative audit that no
# longer lists an order establishes accounting progress for it.
order_authoritative=0
if [ -f "$ORDER_AUDIT" ]; then
  now_epoch=$(date -u +%s 2>/dev/null || printf 0)
  case "$now_epoch" in ''|*[!0-9]*) now_epoch=0 ;; esac
  # ONE ATOMIC validate-and-emit pass (design ruling qa-dj-s2 sections 2.2 and 5.1). A single jq
  # read proves the file is a COMPLETE, unambiguous snapshot and emits the validated ids from
  # that very generation, so no downstream consumer can observe a different (partial or swapped)
  # generation - closing the two-pass read race that is itself a covert partial-coverage source.
  # It emits "OK<TAB>age<TAB>grace" followed by the validated order_ids one per line on success,
  # or "ERR<TAB>reason" on any structural/completeness failure; an unparseable file makes jq exit
  # non-zero, caught by the `||`. Every requirement is FAIL-CLOSED - authority is granted only by
  # positively proving ALL of: schema; an ISO generated_at; unaccounted is a number;
  # unaccounted == array length; unaccounted_orders is an array; EVERY element is an object with a
  # UNIQUE NON-EMPTY STRING order_id; and the validated-id count equals unaccounted. Completeness
  # is part of authority, not an afterthought: a file that count-matches but does not cover every
  # id it declares (the q107 shape) is corrupt, and a corrupt file speaks for NO id.
  order_meta=$(jq -r --argjson now "$now_epoch" '
    def valid_ids($arr):
      [ $arr[] | if (type == "object") then .order_id else null end
               | if (type == "string" and . != "") then . else empty end ];
    if (.schema // "") != "fm-order-audit/v1" then "ERR\tbad-schema"
    else ((.generated_at // "") | (try fromdateiso8601 catch null)) as $gen
      | if $gen == null then "ERR\tbad-timestamp"
        else ((.grace_seconds // 14400) | if type == "number" then . else 14400 end) as $grace
          | (.unaccounted // null) as $u
          | if ($u | type) != "number" then "ERR\tno-count"
            else (.unaccounted_orders // []) as $arr
              | if ($arr | type) != "array" then "ERR\tbad-orders-array"
                elif $u != ($arr | length) then "ERR\tcount-mismatch"
                else (valid_ids($arr)) as $ids
                  | if ($ids | length) != $u then "ERR\tpartial-id"
                    elif (($ids | unique | length) != ($ids | length)) then "ERR\tduplicate-id"
                    else "OK\t" + (($now - $gen) | tostring) + "\t" + ($grace | tostring)
                         + (if ($ids | length) > 0 then "\n" + ($ids | join("\n")) else "" end)
                    end
                end
            end
        end
    end' "$ORDER_AUDIT" 2>/dev/null) || order_meta=$'ERR\tunreadable'
  order_first=${order_meta%%$'\n'*}          # first line: OK<TAB>age<TAB>grace | ERR<TAB>reason
  order_kind=${order_first%%$'\t'*}
  if [ "$order_kind" = OK ]; then
    order_rest=${order_first#*$'\t'}
    o_age=${order_rest%%$'\t'*}; o_grace=${order_rest#*$'\t'}
    case "$o_age" in ''|*[!0-9-]*) o_age=0 ;; esac
    case "$o_grace" in ''|*[!0-9]*) o_grace=14400 ;; esac
    order_audit_age=$o_age
    # Staleness bound: the audit's own accounting grace, overridable. Older than this is too
    # stale to enforce on (benign, non-authoritative); within it a positively-validated snapshot
    # is authoritative for its complete id set - and only then.
    order_max_age=${FM_TURNEND_ORDER_AUDIT_MAX_AGE:-$o_grace}
    case "$order_max_age" in ''|*[!0-9]*) order_max_age=$o_grace ;; esac
    if [ "$o_age" -gt "$order_max_age" ]; then
      order_error='order-audit-stale'
    else
      # Authoritative: orders/order_ids come ONLY from this pass's validated, complete list -
      # the lines emitted after the OK header.
      order_authoritative=1
      [ "$order_meta" != "$order_first" ] && order_ids=${order_meta#*$'\n'}
      [ -n "$order_ids" ] && orders=$(printf '%s\n' "$order_ids" | grep -c .)
    fi
  else
    order_error="order-audit-${order_first#*$'\t'}"
  fi
fi
case "$orders" in ''|*[!0-9]*) orders=0 ;; esac

# Bounded order-id digest for the block message and decision log.
order_digest=''
if [ "$orders" -gt 0 ]; then
  order_digest=$(printf '%s\n' "$order_ids" | head -n "$LOG_IDS" | paste -sd, -)
  [ "$orders" -gt "$LOG_IDS" ] && order_digest="$order_digest,+$((orders - LOG_IDS)) more"
fi

# The combined id set the loop-guard progress check and the block-id record stand on: nf
# crew ids plus unaccounted order ids prefixed `order:` so the two namespaces never collide.
if [ -n "$order_ids" ]; then
  order_prefixed=$(printf '%s\n' "$order_ids" | sed 's/^/order:/')
else
  order_prefixed=''
fi
combined_ids=$(printf '%s\n' "$nf_ids" "$order_prefixed" | grep . || true)
combined_digest=''
if [ -n "$combined_ids" ]; then
  combined_count=$(printf '%s\n' "$combined_ids" | grep -c .)
  combined_digest=$(printf '%s\n' "$combined_ids" | head -n "$LOG_IDS" | paste -sd, -)
  [ "$combined_count" -gt "$LOG_IDS" ] && combined_digest="$combined_digest,+$((combined_count - LOG_IDS)) more"
fi

watcher_desc=$FM_SUP_HEALTH_STATE
[ "$FM_SUP_IN_FLIGHT" -eq 0 ] && watcher_desc=no-tasks-in-flight

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
  local line beacon_age order_age
  beacon_age=${FM_WATCHER_DIAG_BEACON_AGE:-}
  case "$beacon_age" in
    ''|*[!0-9]*) beacon_age=null ;;
  esac
  # order_audit_age is the deterministic age of state/.order-audit-last.json, or null when
  # the file is absent (the order predicate simply did not fire this evaluation).
  order_age=${order_audit_age:-}
  case "$order_age" in
    ''|*[!0-9-]*) order_age=null ;;
  esac
  line=$(jq -cn \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg watcher "$watcher_desc" \
    --argjson in_flight "$FM_SUP_IN_FLIGHT" \
    --argjson nf "$nf" \
    --arg nf_items "$nf_digest" \
    --arg nf_gate "$nf_gate" \
    --arg nf_error "$nf_error" \
    --argjson orders "$orders" \
    --arg order_items "$order_digest" \
    --arg order_error "$order_error" \
    --argjson order_audit_age "$order_age" \
    --arg decision "$1" \
    --arg reason "$2" \
    --argjson beacon_age "$beacon_age" \
    --arg lock_pid "${FM_WATCHER_DIAG_LOCK_PID:-none}" \
    --arg lock_pid_alive "${FM_WATCHER_DIAG_PID_ALIVE:-unknown}" \
    --arg identity_match "${FM_WATCHER_DIAG_IDENTITY_MATCH:-unknown}" \
    --arg home_match "${FM_WATCHER_DIAG_HOME_MATCH:-unknown}" \
    --arg path_match "${FM_WATCHER_DIAG_PATH_MATCH:-unknown}" \
    --arg watcher_fail "${FM_WATCHER_DIAG_FAIL:-unknown}" \
    --arg supervision_health "${FM_SUP_HEALTH_STATE:-unknown}" \
    --arg supervision_reason "${FM_SUP_HEALTH_REASON:-unknown}" \
    --arg supervision_harness "$HARNESS" \
    --arg fm_root "$FM_ROOT" \
    --arg state_dir "$STATE" \
    --arg cwd "$(guard_caller_cwd)" \
    --arg hook_source "${HARNESS:-unknown}" \
    --arg host "$(guard_caller_host)" \
    --argjson pid "$$" \
    --argjson loop_protection "$([ "$STOP_HOOK_ACTIVE" = true ] && echo true || echo false)" \
    '{ts: $ts, watcher: $watcher, in_flight: $in_flight, needs_firstmate: $nf,
      nf_items: $nf_items, nf_gate: $nf_gate, nf_error: $nf_error,
      orders: $orders, order_items: $order_items, order_error: $order_error,
      order_audit_age: $order_audit_age,
      decision: $decision, reason: $reason, loop_protection: $loop_protection,
      beacon_age: $beacon_age, lock_pid: $lock_pid, lock_pid_alive: $lock_pid_alive,
      identity_match: $identity_match, home_match: $home_match, path_match: $path_match,
      watcher_fail: $watcher_fail, supervision_health: $supervision_health,
      supervision_reason: $supervision_reason, supervision_harness: $supervision_harness,
      fm_root: $fm_root, state_dir: $state_dir, cwd: $cwd, hook_source: $hook_source,
      host: $host, pid: $pid}' 2>/dev/null) \
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

# A healthy, genuinely-empty evaluation closes any open block episode. It deliberately does
# NOT reset the guard-error coalescing store: an INTERMITTENT failure interleaves healthy
# evaluations with failing ones, and clearing the dedup on every healthy pass is exactly
# what re-filed a fresh captain bug on each recurrence (ORD-231). The coalescing window
# alone governs when a genuinely-new recurrence surfaces again.
mark_healthy() {
  rm -f "$BLOCK_IDS_FILE" 2>/dev/null || true
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
# THREE independent reasons to block, any one enough: supervision off (blind), unattended
# finished crew work (nf), and unaccounted captain orders past grace (orders). nf and orders
# each fail OPEN on a read error - their count is 0 and their *_error names the failure - so
# a read error never blocks, but it never masks the watcher axis either. Both work axes
# enforce only while nf_gate == on: afk and the duty kill switch stand BOTH down, exactly as
# they always did for nf. Everything below exits 0 with an honest record, or falls through to
# the block at the bottom.

nf_blocking=0
[ "$nf" -gt 0 ] && [ "$nf_gate" = on ] && nf_blocking=1
order_blocking=0
[ "$orders" -gt 0 ] && [ "$nf_gate" = on ] && order_blocking=1
work=$((nf + orders))

# order-audit-stale is BENIGN metadata - a refresh-cadence gap, not a broken read. It is
# recorded in order_error for observability, but it must NEVER drive control flow: an honest
# stale audit that flipped the evaluation into allowed_guard_error would MASK a known
# no-progress stand-down (its coalesced anomaly and its durable wake) and weaken the
# progress-aware loop guard (QA qa-dj-s2-q104). Only a genuinely unreadable/malformed/
# count-mismatched file is a broken read.
order_broken=0
case "$order_error" in ''|order-audit-stale) : ;; *) order_broken=1 ;; esac
# A GENUINE read failure on either axis. This selects the fail-open allowed_guard_error path,
# but ONLY when no readable axis (known work or watcher-down) determines the outcome first -
# it signals and announces, it never masks a stand-down.
read_broken=0
{ [ -n "$nf_error" ] || [ "$order_broken" -eq 1 ]; } && read_broken=1

# The reason string for an allowed_guard_error permit, naming whichever axis GENUINELY could
# not be read (a stale audit is never named as a read failure here). Only called when
# read_broken == 1, so at least one genuinely-broken axis is present.
read_error_reason() {
  if [ -n "$nf_error" ] && [ "$order_broken" -eq 1 ]; then
    printf 'lane: %s; orders: %s' "$nf_error" "$order_error"
  elif [ -n "$nf_error" ]; then
    printf '%s' "$nf_error"
  else
    printf '%s' "$order_error"
  fi
}

# Raise the durable, coalesced signal for whichever axis GENUINELY could not be read - but
# ONLY while the gate is enforcing (a stand-down owns its own escalation). Each axis keys its
# own fingerprint. A STALE order file is a refresh-cadence gap, not a breakage, so it is
# logged but never signalled here.
signal_read_errors() {
  [ "$nf_gate" = on ] || return 0
  [ -n "$nf_error" ] && signal_guard_error_bug "$nf_error" 'needs_firstmate lane read failed on the turn-end path'
  [ "$order_broken" -eq 1 ] && signal_order_audit_anomaly "$order_error"
  return 0
}

# The order-audit banner, printed only for a genuine breakage (never for a stale file).
order_error_banner_if_broken() {  # <detail>
  [ "$order_broken" -eq 1 ] && order_error_banner "$order_error" "$1"
  return 0
}

# Announce every GENUINELY-broken axis (loud banners) without deciding the outcome. Used
# wherever a read failure must be surfaced alongside - not instead of - the real decision.
announce_read_errors() {  # <nf-detail> <order-detail>
  [ -n "$nf_error" ] && guard_error_banner "$nf_error" "$1"
  order_error_banner_if_broken "$2"
  return 0
}

# One coalesced anomaly per no-progress stand-down, plus its honest decision record. This is
# what makes an enforcement stand-down durably visible without a bug per occurrence. The
# optional ids-digest names the still-outstanding set (which, on a retry with a
# non-authoritative audit, includes RETAINED prior order ids the current read cannot see).
record_standdown_no_progress() {  # <reason-text> [<ids-digest>]
  signal_standdown_anomaly "$1" "${2:-}"
  log_decision allowed_loop_protection_without_progress "$1"
}

if [ "$nf_gate" = duty-off ]; then
  duty_off_banner
fi

if [ "$STOP_HOOK_ACTIVE" = true ]; then
  # Loop protection: never block twice in one turn (see the header). The permit is
  # unconditional; the CLASSIFICATION is not (ORD-059 section 1): compliance requires the
  # work axes empty or the blocked id set to have shrunk, and a stand-down or error is
  # recorded as itself.
  case "$nf_gate" in
    afk) log_decision allowed_afk_owner 'away mode owns supervision'; exit 0 ;;
    duty-off) log_decision allowed_duty_disabled 'FM_TRIAGE_DUTY=off kill switch engaged'; exit 0 ;;
  esac
  # A GENUINE read failure is announced and signalled, but it does NOT decide the outcome: a
  # known no-progress stand-down (from the READABLE axes - unchanged work, or the watcher
  # still down) must still be recorded with its coalesced anomaly and durable wake, never
  # swallowed by an independent audit failure (QA qa-dj-s2-q104).
  # A GENUINELY broken read (corrupt audit / crew-lane read failure) is announced and gets its
  # own independent coalesced anomaly. It never DECIDES the retry outcome: the state machine
  # below classifies from the durable prior block and the readable axes regardless.
  if [ "$read_broken" -eq 1 ]; then
    announce_read_errors 'the loop-guarded stop is permitted, but the lane state is unknown.' \
                         'the loop-guarded stop is permitted, but the order-accounting state is unknown.'
    signal_read_errors
  fi

  # --- RETRY STATE MACHINE (QA qa-dj-s2r2-q106) --------------------------------------------
  # The prior BLOCK_IDS_FILE is DURABLE knowledge across the two stop attempts. An order id in
  # it stays outstanding until a FRESH AUTHORITATIVE audit proves it removed; a non-authoritative
  # current read (absent | stale | corrupt) can NEVER discharge a prior order or count as
  # progress. Crew ids are always live-checkable against nf_ids, so a real crew shrink is still
  # recognized even when the order axis is temporarily unknown. The full (audit-authority x
  # prior-block x watcher) table this encodes lives in docs/turnend-guard.md.
  prior_orders=''
  [ -f "$BLOCK_IDS_FILE" ] && prior_orders=$(grep '^order:' "$BLOCK_IDS_FILE" 2>/dev/null || true)
  has_prior_orders=0
  [ -n "$prior_orders" ] && has_prior_orders=1
  # The order component of the still-outstanding set: the current authoritative ids when the
  # audit is fresh, else the RETAINED prior order ids (fail closed - unknown != discharged).
  if [ "$order_authoritative" -eq 1 ]; then
    retained_orders=$order_prefixed
  else
    retained_orders=$prior_orders
  fi
  outstanding=$(printf '%s\n' "$nf_ids" "$retained_orders" | grep . || true)
  outstanding_count=0
  [ -n "$outstanding" ] && outstanding_count=$(printf '%s\n' "$outstanding" | grep -c .)
  outstanding_digest=''
  if [ "$outstanding_count" -gt 0 ]; then
    outstanding_digest=$(printf '%s\n' "$outstanding" | head -n "$LOG_IDS" | paste -sd, -)
    [ "$outstanding_count" -gt "$LOG_IDS" ] && outstanding_digest="$outstanding_digest,+$((outstanding_count - LOG_IDS)) more"
  fi

  if [ "$outstanding_count" -eq 0 ]; then
    # Nothing outstanding: every prior blocked item is provably gone (crew left the lane, and
    # any prior order was authoritatively removed, or there were none). The stale/absent/corrupt
    # cases never reach here while a prior order is retained.
    if [ "$blind" -eq 1 ]; then
      record_standdown_no_progress 'loop protection forced the permit; the watcher is still down'
    elif [ "$read_broken" -eq 1 ]; then
      log_decision allowed_guard_error "$(read_error_reason)"
    else
      mark_healthy
      log_decision allowed_needs_firstmate_empty 'lane empty, supervision healthy'
    fi
    exit 0
  fi

  # Outstanding work remains. Decide authoritative progress vs a no-progress stand-down.
  if [ "$order_authoritative" -eq 0 ] && [ "$has_prior_orders" -eq 1 ]; then
    # FAIL CLOSED: prior orders of UNKNOWN current status keep this a no-progress stand-down,
    # even if the crew lane shrank - staleness is not an accounting act (qa-dj-s2r2-q106).
    progress=0
  else
    # Fresh authoritative order state, or no prior orders: a prior blocked id provably absent
    # from the outstanding set is a real accounting/crew discharge.
    progress=0
    if [ -f "$BLOCK_IDS_FILE" ]; then
      while IFS= read -r prior_id; do
        [ -n "$prior_id" ] || continue
        if ! printf '%s\n' "$outstanding" | grep -qxF -- "$prior_id"; then
          progress=1
          break
        fi
      done < "$BLOCK_IDS_FILE"
    fi
  fi

  if [ "$progress" -eq 1 ]; then
    rm -f "$BLOCK_IDS_FILE" 2>/dev/null || true
    log_decision allowed_after_valid_progress 'the blocked id set shrank via an authoritative read'
  else
    # The turn is ending with unresolved terminal work or unaccounted (or unknown-status
    # retained) orders and only recursion protection let it. Queue one durable check wake
    # naming the STILL-OUTSTANDING set (retained prior orders included), deduped to one pending
    # record, then record the stand-down with its one coalesced anomaly.
    if command -v fm_wake_append >/dev/null 2>&1 \
      && ! grep -q "	check	turnend-guard	" "$STATE/.wake-queue" 2>/dev/null; then
      fm_wake_append check turnend-guard \
        "turn ended with unresolved terminal work or unaccounted orders under loop protection: $outstanding_digest - handle these before any new work" \
        >/dev/null 2>&1 || true
    fi
    record_standdown_no_progress 'loop protection forced the permit; no unattended item or unaccounted order was discharged' "$outstanding_digest"
  fi
  exit 0
fi

# First stop attempt of the turn. Stand-downs and read failures on the work axes never mask
# the independent watcher predicate below, so all of this is gated on blind == 0.
if [ "$blind" -eq 0 ]; then
  case "$nf_gate" in
    afk)
      if [ "$work" -gt 0 ] || [ "$read_broken" -eq 1 ]; then
        log_decision allowed_afk_owner 'away mode owns supervision'
      else
        log_decision allowed_needs_firstmate_empty 'lane empty, supervision healthy (away mode)'
      fi
      exit 0
      ;;
    duty-off)
      if [ "$work" -gt 0 ] || [ "$read_broken" -eq 1 ]; then
        log_decision allowed_duty_disabled 'FM_TRIAGE_DUTY=off kill switch engaged'
      else
        log_decision allowed_needs_firstmate_empty 'lane empty, supervision healthy (kill switch engaged)'
      fi
      exit 0
      ;;
  esac
  # Gate is on. With neither work axis blocking and the watcher healthy, the turn may end - as
  # a fail-open guard_error permit only if a GENUINE read failed (a stale audit is benign and
  # permits cleanly), otherwise a clean empty-lane permit.
  if [ "$nf_blocking" -eq 0 ] && [ "$order_blocking" -eq 0 ]; then
    if [ "$read_broken" -eq 1 ]; then
      announce_read_errors 'this turn end is permitted fail-open; the lane state is unknown.' \
                           'this turn end is permitted fail-open; the order-accounting state is unknown.'
      signal_read_errors
      log_decision allowed_guard_error "$(read_error_reason)"
    else
      mark_healthy
      log_decision allowed_needs_firstmate_empty 'lane empty, supervision healthy'
    fi
    exit 0
  fi
fi

# --- block ---------------------------------------------------------------------
afk=0
[ -e "$STATE/.afk" ] && afk=1
x_mode=0
[ -f "$CONFIG/x-mode.env" ] && x_mode=1
block_reason=''
add_block_reason() {  # <token>
  if [ -z "$block_reason" ]; then block_reason=$1; else block_reason="$block_reason+$1"; fi
}

if [ "$blind" -eq 1 ]; then
  add_block_reason watcher-down
  REASON=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --harness "$HARNESS" --afk "$afk" --x-mode "$x_mode" --repair-line 2>/dev/null \
    || printf '%s\n' 'tasks in flight, no live watcher - resume supervision according to the session-start operating block before ending the turn')
  {
    printf '●%s\n' "$rule"
    printf '●  TURN WOULD END BLIND - SUPERVISION IS OFF\n'
    printf '●  %s task(s) in flight, but supervision continuity is not healthy (%s: %s; last beat: %s).\n' \
      "$FM_SUP_IN_FLIGHT" "$FM_SUP_HEALTH_STATE" "$FM_SUP_HEALTH_REASON" "$FM_SUP_BEACON_DESC"
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

if [ "$nf_blocking" -eq 1 ]; then
  add_block_reason unattended-needs-firstmate
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

# The third block reason (ORD-260 S2): captain orders past the accounting grace with no live
# owner, no machine-checkable hold, and no board-confirmed decision. Re-running the audit is
# not discharge; only a real accounting act followed by a fresh audit clears an order.
if [ "$order_blocking" -eq 1 ]; then
  add_block_reason unaccounted-orders
  {
    printf '●%s\n' "$rule"
    printf '●  TURN WOULD END WITH CAPTAIN ORDERS UNACCOUNTED\n'
    printf '●  %s captain order(s) are past the accounting grace with no live owner, no\n' "$orders"
    printf '●  machine-checkable hold, and no board-confirmed decision:\n'
    printf '%s\n' "$order_ids" | head -n "$SHOW_IDS" | sed 's/^/●    /'
    [ "$orders" -gt "$SHOW_IDS" ] && printf '●    ... and %s more\n' "$((orders - SHOW_IDS))"
    printf '●  RE-RUNNING THE AUDIT ALONE DOES NOT SATISFY THIS CONDITION. An order leaves\n'
    printf '●  this list only when it is genuinely accounted - linked to live work, queued\n'
    printf '●  with a recorded reason and blocker, held on a machine-checkable condition,\n'
    printf '●  parked or decided with a board-confirmed receipt, or completed or rejected\n'
    printf '●  with evidence - and a fresh audit then records it:\n'
    printf '●    bin/fm-order.sh show <id> --history            why this order is unaccounted\n'
    printf '●    bin/fm-order.sh park <id>... --captain-ack <r> captain-parked batch (one ack)\n'
    printf '●    bin/fm-order.sh rollup <lead> --absorb <id>... fold a saga into one thread\n'
    printf '●    bin/fm-order.sh audit                          re-evaluate accounting now\n'
    printf '●%s\n' "$rule"
  } >&2
fi

# A read failure alongside a block is not a permit, but it must still be loud and still raise
# the durable signal on each broken axis: the block below would otherwise hide a dead gate
# behind a healthy-looking block. A stale order file is logged only, never signalled.
if [ "$nf_gate" = on ]; then
  if [ -n "$nf_error" ]; then
    guard_error_banner "$nf_error" 'this turn end is blocked; the lane state is unknown.'
    signal_guard_error_bug "$nf_error" 'needs_firstmate lane read failed on the turn-end path'
  fi
  case "$order_error" in
    ''|order-audit-stale) : ;;
    *)
      order_error_banner "$order_error" 'this turn end is blocked; the order-accounting state is unknown.'
      signal_order_audit_anomaly "$order_error"
      ;;
  esac
fi

# Record the id set this block stands on, so the loop-guarded second attempt can tell real
# progress from an unchanged pile. A watcher-only block records an empty set; a work block
# records the combined crew+order id set.
if [ "$nf_blocking" -eq 1 ] || [ "$order_blocking" -eq 1 ]; then
  printf '%s\n' "$combined_ids" > "$BLOCK_IDS_FILE" 2>/dev/null || true
else
  : > "$BLOCK_IDS_FILE" 2>/dev/null || true
fi
# Decision label precedence: needs_firstmate, then unaccounted orders, then watcher-only. The
# block_reason string still names every axis that fired.
if [ "$nf_blocking" -eq 1 ]; then
  log_decision blocked_needs_firstmate "$block_reason"
elif [ "$order_blocking" -eq 1 ]; then
  log_decision blocked_unaccounted_orders "$block_reason"
else
  log_decision blocked_watcher_down "$block_reason"
fi
exit 2

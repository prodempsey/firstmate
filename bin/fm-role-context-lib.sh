#!/usr/bin/env bash
# fm-role-context-lib.sh - the ONE canonical resolver of "is this process the primary
# firstmate, a crewmate, or neither?" for operation-level role enforcement.
#
# Why a resolver and not an env-var check: an environment variable (FM_CREWMATE) is
# supporting context, not a trusted boundary - a crewmate can unset or change it. So
# this library treats DURABLE task/worktree evidence as authoritative and the env as
# corroboration only. A process sitting in a crewmate worktree is a crewmate even with
# FM_CREWMATE unset, because the worktree membership is recorded durably by the primary.
#
# This is OPERATIONAL role enforcement within one Unix account - it reduces accidental
# and confused-deputy primary actions from crewmates. It is NOT, and does not claim to
# be, OS-level privilege isolation.
#
# Public surface:
#   fm_role_context           -> prints exactly one of: primary | crewmate | unknown
#                                and sets FM_ROLE_REASON (a bounded, secret-free diagnostic).
#   fm_require_primary <op>    -> 0 when proven primary; refuses (returns 2, diagnostic on
#                                stderr) for crewmate OR unknown (fail closed).
#
# Signals, in PRECEDENCE (durable evidence outranks env):
#   1. Durable marker <worktree-root>/.fm-crew-role (written into a crew worktree at spawn).
#   2. Task-worktree membership: cwd's worktree root == a worktree= recorded in a primary
#      home state/*.meta.
#   3. Env corroboration: FM_CREWMATE=1, FM_TASK_ID.
#   4. Primary evidence: cwd under the primary home/checkout, no crewmate marker/membership.
# Explicit, narrow, AUDITED override: FM_ROLE_OVERRIDE=primary with FM_ROLE_OVERRIDE_REASON
# forces primary but appends an audit record; used only for a primary that must act inside
# a crew worktree.

_FM_ROLE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_ROLE_LIB_DIR="."
FM_ROLE_MARKER_NAME=".fm-crew-role"

# Git worktree root of a directory, or empty.
_fm_role_worktree_root() {
  git -C "${1:-$PWD}" rev-parse --show-toplevel 2>/dev/null || true
}

# The primary home whose state/*.meta records the task worktrees.
_fm_role_primary_home() {
  printf '%s' "${FM_PRIMARY_HOME:-${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$_FM_ROLE_LIB_DIR/.." && pwd)}}}"
}

_fm_role_realpath() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }

# 0 if <worktree-root> is recorded as a task worktree in ANY authoritative state dir.
# Authority order: the NON-env physical install root's state (a crew cannot repoint it),
# then FM_STATE_OVERRIDE (test/augment), then the resolved home's state. Checking the
# install-root state is what stops the FM_HOME/FM_PRIMARY_HOME repoint-to-empty bypass.
_fm_role_is_task_worktree() {  # <worktree-root>
  local wt=$1 meta mwt wt_real mwt_real d state_dirs=''
  [ -n "$wt" ] || return 1
  wt_real=$(_fm_role_realpath "$wt")
  state_dirs="$(_fm_role_install_root)/state"
  [ -n "${FM_STATE_OVERRIDE:-}" ] && state_dirs="$state_dirs $FM_STATE_OVERRIDE"
  state_dirs="$state_dirs $(_fm_role_primary_home)/state"
  for d in $state_dirs; do
    [ -d "$d" ] || continue
    for meta in "$d"/*.meta; do
      [ -e "$meta" ] || continue
      mwt=$(grep -m1 '^worktree=' "$meta" 2>/dev/null | cut -d= -f2-)
      [ -n "$mwt" ] || continue
      mwt_real=$(_fm_role_realpath "$mwt")
      [ "$mwt_real" = "$wt_real" ] && return 0
    done
  done
  return 1
}

# Append one audit record for an explicit role override (secret-free).
_fm_role_audit_override() {  # <reason>
  local home state log now
  home=$(_fm_role_primary_home)
  state="${FM_STATE_OVERRIDE:-$home/state}"
  log="$state/role-override-audit.log"
  now="${FM_GOV_NOW:-$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)}"
  mkdir -p "$state" 2>/dev/null || true
  printf '%s\toverride=primary\tpid=%s\tcwd=%s\treason=%s\n' "$now" "$$" "$PWD" "$1" >> "$log" 2>/dev/null || true
}

# _fm_role_emit <role> <reason>: set both the global result and reason (so a DIRECT
# caller - fm_require_primary - sees the reason even though a $(...) caller runs in a
# subshell) and print the role for $(...) callers. FM_ROLE_RESULT/FM_ROLE_REASON.
_fm_role_emit() { FM_ROLE_RESULT=$1; FM_ROLE_REASON=$2; printf '%s' "$1"; }

# The physical install root of THIS library (bin/..), derived from BASH_SOURCE and NOT
# from any environment variable, so a process cannot repoint it. Its state/ is the
# non-env membership authority (MAJOR 2 fix); FM_STATE_OVERRIDE only augments it.
_fm_role_install_root() { (cd "$_FM_ROLE_LIB_DIR/.." 2>/dev/null && pwd -P) || printf '%s' "$_FM_ROLE_LIB_DIR/.."; }

fm_role_context() {
  local wt durable_crew=0 env_crew=0 primary_ev=0 reason='' home home_real pwd_real install_real

  # Explicit, narrow, audited override first (a primary acting inside a crew worktree).
  if [ "${FM_ROLE_OVERRIDE:-}" = primary ]; then
    if [ -n "${FM_ROLE_OVERRIDE_REASON:-}" ]; then
      _fm_role_audit_override "$FM_ROLE_OVERRIDE_REASON"
      _fm_role_emit primary "primary: explicit audited override (reason recorded)"; return 0
    fi
    _fm_role_emit unknown "unknown: FM_ROLE_OVERRIDE=primary ignored - FM_ROLE_OVERRIDE_REASON required for an audited override"; return 0
  fi

  wt=$(_fm_role_worktree_root "$PWD")
  # Durable marker (env-independent) - checked against the resolved worktree root.
  if [ -n "$wt" ] && [ -f "$wt/$FM_ROLE_MARKER_NAME" ]; then
    durable_crew=1; reason="durable $FM_ROLE_MARKER_NAME marker in $wt"
  fi
  # Task-worktree membership: authority is the NON-env physical install root's state
  # (FM_STATE_OVERRIDE augments it for tests). A crew cannot erase this by repointing
  # FM_HOME/FM_PRIMARY_HOME (MAJOR 2).
  if [ "$durable_crew" = 0 ] && [ -n "$wt" ] && _fm_role_is_task_worktree "$wt"; then
    durable_crew=1; reason="cwd worktree $wt recorded as a task worktree in primary state"
  fi
  { [ "${FM_CREWMATE:-}" = 1 ] || [ -n "${FM_TASK_ID:-}" ]; } && env_crew=1

  # POSITIVE primary evidence: cwd under the primary home OR under the physical install
  # checkout. Required to return `primary`; its absence fails CLOSED (BLOCKER 1).
  home=$(_fm_role_primary_home); home_real=$(_fm_role_realpath "$home")
  install_real=$(_fm_role_install_root)
  pwd_real=$(_fm_role_realpath "$PWD")
  case "$pwd_real" in
    "$home_real"|"$home_real"/*|"$install_real"|"$install_real"/*) [ "$durable_crew" = 0 ] && primary_ev=1 ;;
  esac

  # DURABLE crewmate evidence wins over any env/primary signal (closes the unset-env bypass).
  if [ "$durable_crew" = 1 ]; then
    _fm_role_emit crewmate "crewmate: $reason (env FM_CREWMATE=${FM_CREWMATE:-<unset>})"; return 0
  fi
  # Env asserts crewmate -> crewmate (least privilege), or conflicting if it also looks primary.
  if [ "$env_crew" = 1 ]; then
    if [ "$primary_ev" = 1 ]; then
      _fm_role_emit unknown "unknown: conflicting - env asserts crewmate (FM_CREWMATE=${FM_CREWMATE:-<unset>} FM_TASK_ID=${FM_TASK_ID:-<unset>}) but cwd $pwd_real looks primary; no durable crew evidence"; return 0
    fi
    _fm_role_emit crewmate "crewmate: env asserts crewmate (FM_CREWMATE=${FM_CREWMATE:-<unset>} FM_TASK_ID=${FM_TASK_ID:-<unset>}); no primary evidence"; return 0
  fi
  # No crewmate signal. Return primary ONLY with positive primary evidence; otherwise
  # FAIL CLOSED as unknown (BLOCKER 1: a crew that cd's to a neutral dir and clears its
  # env has no positive primary evidence and must not be treated as primary).
  if [ "$primary_ev" = 1 ]; then
    _fm_role_emit primary "primary: cwd $pwd_real under primary home/checkout; no crewmate marker/membership/env"; return 0
  fi
  _fm_role_emit unknown "unknown: no crewmate evidence, but cwd $pwd_real is not under the primary home ($home_real) or the install checkout ($install_real); failing closed"; return 0
}

# fm_require_primary <op>: gate a primary-only MUTATION. Read-only commands must NOT call
# this - they stay available to every role. crewmate refuses; unknown fails closed.
fm_require_primary() {
  local op=${1:-primary-only operation} role
  # Call directly (NOT in $()) so FM_ROLE_RESULT/FM_ROLE_REASON propagate to this shell
  # and the refusal names the deciding signals (MINOR 5).
  fm_role_context >/dev/null
  role=${FM_ROLE_RESULT:-unknown}
  case "$role" in
    primary) return 0 ;;
    crewmate)
      printf 'error: %s refused - this process is a crewmate, not the primary firstmate.\n' "$op" >&2
      printf '       role evidence: %s\n' "${FM_ROLE_REASON:-crewmate}" >&2
      return 2 ;;
    *)
      printf 'error: %s refused - role could not be proven primary; failing closed.\n' "$op" >&2
      printf '       role evidence: %s\n' "${FM_ROLE_REASON:-unknown}" >&2
      return 2 ;;
  esac
}

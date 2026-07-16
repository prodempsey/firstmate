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

# 0 if <worktree-root> is recorded as a task worktree in the primary home's metas.
_fm_role_is_task_worktree() {  # <worktree-root>
  local wt=$1 home state meta mwt wt_real mwt_real
  [ -n "$wt" ] || return 1
  home=$(_fm_role_primary_home)
  state="${FM_STATE_OVERRIDE:-$home/state}"
  wt_real=$(_fm_role_realpath "$wt")
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    mwt=$(grep -m1 '^worktree=' "$meta" 2>/dev/null | cut -d= -f2-)
    [ -n "$mwt" ] || continue
    mwt_real=$(_fm_role_realpath "$mwt")
    [ "$mwt_real" = "$wt_real" ] && return 0
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

fm_role_context() {
  local wt durable_crew=0 env_crew=0 primary_ev=0 reason='' home home_real pwd_real

  # Explicit, narrow, audited override first (a primary acting inside a crew worktree).
  if [ "${FM_ROLE_OVERRIDE:-}" = primary ]; then
    if [ -n "${FM_ROLE_OVERRIDE_REASON:-}" ]; then
      _fm_role_audit_override "$FM_ROLE_OVERRIDE_REASON"
      FM_ROLE_REASON="primary: explicit audited override (reason recorded)"
      printf 'primary'; return 0
    fi
    # Override without a reason is not honored - it must be explicit AND audited.
    FM_ROLE_REASON="unknown: FM_ROLE_OVERRIDE=primary ignored - FM_ROLE_OVERRIDE_REASON required for an audited override"
    printf 'unknown'; return 0
  fi

  wt=$(_fm_role_worktree_root "$PWD")
  if [ -n "$wt" ] && [ -f "$wt/$FM_ROLE_MARKER_NAME" ]; then
    durable_crew=1; reason="durable $FM_ROLE_MARKER_NAME marker in $wt"
  fi
  if [ "$durable_crew" = 0 ] && [ -n "$wt" ] && _fm_role_is_task_worktree "$wt"; then
    durable_crew=1; reason="cwd worktree $wt recorded as a task worktree in primary state"
  fi
  { [ "${FM_CREWMATE:-}" = 1 ] || [ -n "${FM_TASK_ID:-}" ]; } && env_crew=1

  home=$(_fm_role_primary_home)
  home_real=$(_fm_role_realpath "$home")
  pwd_real=$(_fm_role_realpath "$PWD")
  case "$pwd_real" in
    "$home_real"|"$home_real"/*) [ "$durable_crew" = 0 ] && primary_ev=1 ;;
  esac

  # DURABLE crewmate evidence wins over any env signal - closes the unset-FM_CREWMATE bypass.
  if [ "$durable_crew" = 1 ]; then
    FM_ROLE_REASON="crewmate: $reason (env FM_CREWMATE=${FM_CREWMATE:-<unset>})"
    printf 'crewmate'; return 0
  fi
  # Env asserts crewmate but cwd looks like the primary home: conflicting -> fail closed.
  if [ "$env_crew" = 1 ] && [ "$primary_ev" = 1 ]; then
    FM_ROLE_REASON="unknown: conflicting - env asserts crewmate (FM_CREWMATE=${FM_CREWMATE:-<unset>} FM_TASK_ID=${FM_TASK_ID:-<unset>}) but cwd $pwd_real is under primary home with no durable crew evidence"
    printf 'unknown'; return 0
  fi
  # Env asserts crewmate, no durable evidence, not clearly primary: least privilege -> crewmate.
  if [ "$env_crew" = 1 ]; then
    FM_ROLE_REASON="crewmate: env asserts crewmate (FM_CREWMATE=${FM_CREWMATE:-<unset>} FM_TASK_ID=${FM_TASK_ID:-<unset>}); no primary evidence"
    printf 'crewmate'; return 0
  fi
  # No crewmate signal of ANY kind (no durable marker, no task-worktree membership, no
  # FM_CREWMATE, no FM_TASK_ID). fm-spawn ALWAYS attaches durable evidence to a crewmate,
  # so a process carrying none provably is not a firstmate-launched crewmate: it is the
  # primary (or a secondmate in its own home, which is the primary there). cwd under the
  # primary home is an additional positive signal but not required - the existing primary
  # command flows and test harnesses run from varied cwds. `unknown` is therefore reserved
  # for genuinely CONFLICTING signals (handled above), which fail closed.
  if [ "$primary_ev" = 1 ]; then
    FM_ROLE_REASON="primary: cwd $pwd_real under primary home $home_real; no crewmate marker/membership/env"
  else
    FM_ROLE_REASON="primary: no crewmate marker/membership/env evidence present (a crewmate always carries durable evidence)"
  fi
  printf 'primary'; return 0
}

# fm_require_primary <op>: gate a primary-only MUTATION. Read-only commands must NOT call
# this - they stay available to every role. crewmate refuses; unknown fails closed.
fm_require_primary() {
  local op=${1:-primary-only operation} role
  role=$(fm_role_context)
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

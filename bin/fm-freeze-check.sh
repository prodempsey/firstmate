#!/usr/bin/env bash
# fm-freeze-check.sh - safe read-only inspection of whether a task's candidate is
# actually FROZEN, i.e. whether any live coding agent or child process could still
# mutate its branch (Scope F of the Memory PR-1 incident prevention controls).
#
# A crew status of `done` is NOT proof the candidate is frozen: the coding agent may
# still be alive in its pane, able to make one more commit. This inspection reports
# the task's process reality - agent PID, child PIDs, command, working directory,
# worktree, branch, branch SHA, whether an active process can still mutate, and the
# hold state - and FAILS (exit 3) while any live coding agent within the task's
# worktree can mutate. It distinguishes an active coding agent from an inert login
# shell, a dead/stale PID, and an unrelated process.
#
# --stop offers a SAFE, SCOPED process-stop: it signals ONLY the coding-agent PIDs
# whose working directory is inside this task's worktree. It never runs fm-teardown,
# never kills a tmux server or session, and never triggers fleet synchronization.
#
# Testability: process enumeration is injectable. Set FM_FREEZE_PROC_SOURCE to a file
# of "pid<TAB>ppid<TAB>cwd<TAB>command" lines to drive the classifier deterministically
# without real processes; absent, live /proc + ps are read.
#
# Usage: fm-freeze-check.sh <task-id> [--json] [--stop]
# Exit:  0 frozen-safe (no live agent can mutate), 3 live agent can mutate, 2 error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-governance-lib.sh
. "$SCRIPT_DIR/fm-governance-lib.sh"

ID=${1:-}
[ -n "$ID" ] || { echo "usage: fm-freeze-check.sh <task-id> [--json] [--stop]" >&2; exit 2; }
shift || true
JSON=0 STOP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift ;;
    --stop) STOP=1; shift ;;
    *) shift ;;
  esac
done

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 2; }
meta_val() { grep -m1 "^$1=" "$META" 2>/dev/null | cut -d= -f2- || true; }
WORKTREE=$(meta_val worktree)
STATUS_LINE=''
[ -f "$STATE/$ID.status" ] && STATUS_LINE=$(grep -v '^[[:space:]]*$' "$STATE/$ID.status" 2>/dev/null | tail -1 || true)

WT_REAL=''
[ -n "$WORKTREE" ] && WT_REAL=$(cd "$WORKTREE" 2>/dev/null && pwd -P || printf '%s' "$WORKTREE")
BRANCH=''; BRANCH_SHA=''
if [ -n "$WT_REAL" ] && [ -d "$WT_REAL" ]; then
  BRANCH=$(git -C "$WT_REAL" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  BRANCH_SHA=$(git -C "$WT_REAL" rev-parse HEAD 2>/dev/null || true)
fi

# --- enumerate candidate processes -----------------------------------------
# Emit "pid<TAB>ppid<TAB>cwd<TAB>command" for every process that either lives under
# the task's worktree (cwd inside it) or is otherwise associated with the task pane.
enumerate_procs() {
  if [ -n "${FM_FREEZE_PROC_SOURCE:-}" ]; then
    [ -f "$FM_FREEZE_PROC_SOURCE" ] && cat "$FM_FREEZE_PROC_SOURCE"
    return 0
  fi
  local pid cwd cmd
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    [ -r "$d/cwd" ] || continue
    cwd=$(readlink "$d/cwd" 2>/dev/null) || continue
    cmd=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null | sed 's/[[:space:]]*$//') || continue
    [ -n "$cmd" ] || continue
    local ppid
    ppid=$(awk '/^PPid:/{print $2}' "$d/status" 2>/dev/null || echo 0)
    printf '%s\t%s\t%s\t%s\n' "$pid" "$ppid" "$cwd" "$cmd"
  done
}

# cwd is inside the task worktree?
cwd_in_worktree() {  # <cwd>
  [ -n "$WT_REAL" ] || return 1
  case "$1" in "$WT_REAL"|"$WT_REAL"/*) return 0 ;; *) return 1 ;; esac
}

CAN_MUTATE=0
AGENT_PIDS=''
declare -a REPORT_LINES=()
STOP_PIDS=''

while IFS=$'\t' read -r pid ppid cwd cmd; do
  [ -n "${pid:-}" ] || continue
  class=$(fm_gov_classify_process "$cmd")
  in_wt=no
  cwd_in_worktree "$cwd" && in_wt=yes
  mutate=no
  if [ "$class" = coding-agent ] && [ "$in_wt" = yes ]; then
    mutate=yes
    CAN_MUTATE=1
    AGENT_PIDS="${AGENT_PIDS:+$AGENT_PIDS }$pid"
    STOP_PIDS="${STOP_PIDS:+$STOP_PIDS }$pid"
  fi
  REPORT_LINES+=("pid=$pid ppid=$ppid class=$class in_worktree=$in_wt can_mutate=$mutate cwd=$cwd cmd=$cmd")
done <<EOF
$(enumerate_procs)
EOF

# Hold state for this task (best-effort; a missing holds store is "not held").
HOLD_STATE=clear
if "$SCRIPT_DIR/fm-hold.sh" check --task "$ID" >/dev/null 2>&1; then HOLD_STATE=clear; else HOLD_STATE=held; fi

FROZEN_SAFE=1
[ "$CAN_MUTATE" = 1 ] && FROZEN_SAFE=0

if [ "$JSON" = 1 ]; then
  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "${REPORT_LINES[@]:-}" | jq -R . | jq -sc \
      --arg id "$ID" --arg status "$STATUS_LINE" --arg wt "$WT_REAL" --arg br "$BRANCH" \
      --arg sha "$BRANCH_SHA" --arg agents "$AGENT_PIDS" --arg hold "$HOLD_STATE" \
      --argjson canmutate "$([ "$CAN_MUTATE" = 1 ] && echo true || echo false)" \
      --argjson frozensafe "$([ "$FROZEN_SAFE" = 1 ] && echo true || echo false)" '
      {task:$id, status:$status, worktree:$wt, branch:$br, branchSha:$sha,
       agentPids:($agents|split(" ")|map(select(length>0))), canMutate:$canmutate,
       frozenSafe:$frozensafe, hold:$hold, processes:.}'
  fi
else
  echo "task:        $ID"
  echo "status:      ${STATUS_LINE:-<none>}"
  echo "worktree:    ${WT_REAL:-<none>}"
  echo "branch:      ${BRANCH:-<none>}"
  echo "branchSha:   ${BRANCH_SHA:-<none>}"
  echo "agentPids:   ${AGENT_PIDS:-<none>}"
  echo "canMutate:   $([ "$CAN_MUTATE" = 1 ] && echo yes || echo no)"
  echo "frozenSafe:  $([ "$FROZEN_SAFE" = 1 ] && echo yes || echo no)"
  echo "hold:        $HOLD_STATE"
  echo "processes:"
  if [ "${#REPORT_LINES[@]}" -gt 0 ]; then
    printf '  %s\n' "${REPORT_LINES[@]}"
  else
    echo "  <none>"
  fi
fi

if [ "$STOP" = 1 ]; then
  if [ -z "$STOP_PIDS" ]; then
    echo "stop: no in-worktree coding-agent process to stop for $ID" >&2
  else
    for pid in $STOP_PIDS; do
      # Scoped stop only: SIGTERM, then SIGKILL if still alive. Never a broad kill.
      kill -TERM "$pid" 2>/dev/null || true
    done
    sleep "${FM_FREEZE_STOP_GRACE:-2}"
    for pid in $STOP_PIDS; do
      kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    done
    echo "stopped scoped coding-agent pids: $STOP_PIDS" >&2
    # Re-evaluate: after a stop the candidate should be frozen-safe.
    exit 0
  fi
fi

[ "$FROZEN_SAFE" = 1 ] && exit 0 || exit 3

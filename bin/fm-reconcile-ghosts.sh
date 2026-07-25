#!/usr/bin/env bash
# Reconcile dead task endpoints left behind after a cockpit/fleet-bridge
# restart.
#
# This script is a locked-session-start mutating sweep.
# It only decides whether a recorded backend endpoint is structurally gone.
# Ordinary cleanup is delegated to fm-teardown.sh so landed-work, scout-report,
# local-only, dirty-worktree, and backend-specific removal safety stay in one
# place.
# A corrupt legacy shape where worktree= points at the active firstmate home
# cannot prove either task lineage or landed state. It is reported separately
# and preserved without calling teardown or deleting any task record.
# bin/fm-backend.sh's fm_enumerate_task_records owns the closed enumeration
# contract: one canonical state directory, a complete name snapshot, every
# entry attested regular/read-complete/parsed, and a trailing count before this
# script may enter disposition. Failure is total and mutation-free; a completed
# zero-count proof is the only source of the empty-fleet message.
#
# Confirm-twice safeguard (bug-20260710152159-d3f294fa): a live,
# actively-working crew can transiently read as a dead endpoint - e.g. a tmux
# window briefly failing to resolve while a grouped session is being rebuilt -
# and a single missed liveness probe must never be enough evidence to reap a
# crew mid-flight (engine-room-p0, 2026-07-10; only the separate unlanded-work
# refusal below saved it that time). A meta is only treated as a true ghost
# once fm_backend_target_exists reports it dead on TWO independent reads, with
# a short settle delay (FM_GHOST_SETTLE_SECS, default 2s) between them. This
# is a second, independent layer stacked on top of - never a replacement for -
# fm-teardown.sh's own unlanded-work refusal.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GHOST_SETTLE_SECS="${FM_GHOST_SETTLE_SECS:-2}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

canonical_dir() {  # <path>
  local path=$1
  [ -n "$path" ] || return 1
  [ -d "$path" ] || return 1
  ( cd "$path" && pwd -P )
}

worktree_is_active_home() {  # <worktree>
  local worktree=$1 wt_abs home_abs
  wt_abs=$(canonical_dir "$worktree" 2>/dev/null) || return 1
  home_abs=$(canonical_dir "$FM_HOME" 2>/dev/null) || return 1
  [ "$wt_abs" = "$home_abs" ]
}

enumeration_failed() {  # <reason> [canonical-or-input-path]
  local reason=$1 path=${2:-$STATE}
  printf 'GHOST_RECONCILE: ATTENTION: cannot enumerate task metadata in %s (%s); no task records were touched.\n' "$path" "$reason"
  printf 'GHOST_RECONCILE: summary enumeration=failed cleared=0 corrupt_preserved=unknown preserved=unknown\n'
  exit 1
}

TASK_SNAPSHOT=$(mktemp "${TMPDIR:-/tmp}/fm-ghost-records.XXXXXX" 2>/dev/null) \
  || enumeration_failed "could not create a complete enumeration snapshot"
trap 'rm -f "$TASK_SNAPSHOT"' EXIT
if ! fm_enumerate_task_records "$STATE" "$TASK_SNAPSHOT"; then
  enumeration_failed "$FM_TASK_ENUM_REASON" "$FM_TASK_ENUM_CANONICAL_STATE"
fi

DEAD_FOUND=0
CLEARED=0
CORRUPT_PRESERVED=0
PRESERVED=0

record_index=0
exec 8< "$TASK_SNAPSHOT" \
  || enumeration_failed "completed enumeration snapshot could not be opened" "$FM_TASK_ENUM_CANONICAL_STATE"
while [ "$record_index" -lt "$FM_TASK_ENUM_COUNT" ]; do
  fm_task_record_snapshot_read 8 \
    || enumeration_failed "completed enumeration snapshot could not be read" "$FM_TASK_ENUM_CANONICAL_STATE"
  id=$FM_TASK_RECORD_ID
  meta=$FM_TASK_RECORD_META
  backend=$FM_TASK_RECORD_BACKEND
  target=$FM_TASK_RECORD_TARGET
  worktree=$FM_TASK_RECORD_WORKTREE
  record_index=$((record_index + 1))

  if [ -z "$target" ]; then
    PRESERVED=$((PRESERVED + 1))
    printf 'GHOST_RECONCILE: ATTENTION: %s has no backend target in %s; preserved for manual recovery.\n' "$id" "$meta"
    continue
  fi

  if fm_backend_target_exists "$backend" "$target" "fm-$id"; then
    continue
  fi

  # First read says dead. Do not act on a single miss: re-check after a short
  # settle delay and require BOTH reads to agree before this counts as a true
  # ghost (see the confirm-twice safeguard note above).
  sleep "$GHOST_SETTLE_SECS"
  if fm_backend_target_exists "$backend" "$target" "fm-$id"; then
    printf 'GHOST_RECONCILE: %s read dead once but resolved alive on recheck after %ss - treating as a transient miss, not reaping.\n' "$id" "$GHOST_SETTLE_SECS"
    continue
  fi

  DEAD_FOUND=1
  if worktree_is_active_home "$worktree"; then
    PRESERVED=$((PRESERVED + 1))
    CORRUPT_PRESERVED=$((CORRUPT_PRESERVED + 1))
    printf 'GHOST_RECONCILE: ATTENTION: %s has corrupt worktree=%s matching FM_HOME; landed/closed state cannot be proven, so every task record was preserved.\n' "$id" "$worktree"
    continue
  fi

  if out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-teardown.sh" "$id" 2>&1); then
    CLEARED=$((CLEARED + 1))
    first_line=$(printf '%s\n' "$out" | sed -n '1p')
    printf 'GHOST_RECONCILE: %s torn down cleanly: %s\n' "$id" "${first_line:-teardown succeeded}"
  else
    PRESERVED=$((PRESERVED + 1))
    printf 'GHOST_RECONCILE: ATTENTION: %s endpoint is dead but teardown refused or failed; state preserved.\n' "$id"
    printf '%s\n' "$out" | sed 's/^/  /'
  fi
done
exec 8<&-

if [ "$FM_TASK_ENUM_COUNT" -eq 0 ]; then
  printf 'GHOST_RECONCILE: no in-flight metadata found.\n'
elif [ "$DEAD_FOUND" -eq 0 ] && [ "$PRESERVED" -eq 0 ]; then
  printf 'GHOST_RECONCILE: no dead task endpoints found.\n'
fi

printf 'GHOST_RECONCILE: summary cleared=%s corrupt_preserved=%s preserved=%s\n' "$CLEARED" "$CORRUPT_PRESERVED" "$PRESERVED"

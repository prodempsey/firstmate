#!/usr/bin/env bash
# Reconcile dead task endpoints left behind after a cockpit/fleet-bridge
# restart.
#
# This script is a locked-session-start mutating sweep.
# It only decides whether a recorded backend endpoint is structurally gone.
# Ordinary cleanup is delegated to fm-teardown.sh so landed-work, scout-report,
# local-only, dirty-worktree, and backend-specific removal safety stay in one
# place.
# The one bypass is a known corrupt legacy shape where worktree= points at the
# active firstmate home itself; that is never a removable worktree, so only the
# task's volatile state records are cleared.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

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

remove_task_state_records() {  # <id>
  local id=$1
  rm -f \
    "$STATE/$id.status" \
    "$STATE/$id.turn-ended" \
    "$STATE/$id.check.sh" \
    "$STATE/$id.meta" \
    "$STATE/$id.pi-ext.ts" \
    "$STATE/$id.grok-turnend-token"
}

META_FOUND=0
DEAD_FOUND=0
CLEARED=0
CORRUPT_CLEARED=0
PRESERVED=0

for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  META_FOUND=1
  id=$(basename "$meta" .meta)
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")

  if [ -z "$target" ]; then
    PRESERVED=$((PRESERVED + 1))
    printf 'GHOST_RECONCILE: ATTENTION: %s has no backend target in %s; preserved for manual recovery.\n' "$id" "$meta"
    continue
  fi

  if fm_backend_target_exists "$backend" "$target" "fm-$id"; then
    continue
  fi

  DEAD_FOUND=1
  worktree=$(fm_meta_get "$meta" worktree)
  if worktree_is_active_home "$worktree"; then
    remove_task_state_records "$id"
    CLEARED=$((CLEARED + 1))
    CORRUPT_CLEARED=$((CORRUPT_CLEARED + 1))
    printf 'GHOST_RECONCILE: %s cleared corrupt-home ghost state only; worktree=%s matched FM_HOME and was not touched.\n' "$id" "$worktree"
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

if [ "$META_FOUND" -eq 0 ]; then
  printf 'GHOST_RECONCILE: no in-flight metadata found.\n'
elif [ "$DEAD_FOUND" -eq 0 ] && [ "$PRESERVED" -eq 0 ]; then
  printf 'GHOST_RECONCILE: no dead task endpoints found.\n'
fi

printf 'GHOST_RECONCILE: summary cleared=%s corrupt_state_only=%s preserved=%s\n' "$CLEARED" "$CORRUPT_CLEARED" "$PRESERVED"

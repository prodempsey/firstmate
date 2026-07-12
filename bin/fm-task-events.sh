#!/usr/bin/env bash
# Write closure evidence through Fleet Bridge's server-independent visibility CLI.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

visibility_cli() {
  local candidate
  if [ -n "${FM_VISIBILITY_CLI:-}" ]; then
    printf '%s\n' "$FM_VISIBILITY_CLI"
    return
  fi
  for candidate in "$FM_HOME/projects/fleet-bridge/bin/visibility.mjs" "$FM_ROOT/projects/fleet-bridge/bin/visibility.mjs"; do
    [ -f "$candidate" ] && { printf '%s\n' "$candidate"; return; }
  done
  return 1
}

[ "$#" -ge 6 ] || { echo "usage: fm-task-events.sh <id> <disposition> <outcome> <branch> <mode> <sha-or-report>" >&2; exit 2; }
ID=$1 DISPOSITION=$2 OUTCOME=$3 BRANCH=$4 MODE=$5 EVIDENCE=$6
CLI=$(visibility_cli) || { echo "blocked: fleet-bridge visibility CLI not found" >&2; exit 1; }
args=(close "$ID" --disposition "$DISPOSITION" --outcome "$OUTCOME" --branch "$BRANCH" --mode "$MODE")
if [ "$MODE" = scout-report ]; then args+=(--report "$EVIDENCE"); else args+=(--sha "$EVIDENCE"); fi
node "$CLI" "${args[@]}"

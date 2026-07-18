#!/usr/bin/env bash
# Print the tail of a crewmate endpoint (bounded, for cheap diagnosis).
# Usage: fm-peek.sh <target> [lines=40]
#   <target> may be an exact task id, a legacy fm-<id> task label resolved
#   through this home's state/<id>.meta, or an explicit backend target.
#
# Fail-closed home contract (mirrors fm-send.sh): a bare task-id or legacy
# fm-<id> selector is resolved against THIS home's state/<id>.meta, so without an
# explicit FM_HOME peek would silently resolve it against a guessed default root
# (or the wrong home's legacy inventory) and read the WRONG endpoint. A task-id
# or bare-name selector therefore requires a non-empty, existing FM_HOME with a
# state dir. A fully-qualified explicit backend target (contains ':') names the
# endpoint directly, needs no home resolution, and is the standing escape hatch -
# exactly the ':' form fm_backend_resolve_selector uses as-is.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

RAW_TARGET=$1
N=${2:-40}

case "$RAW_TARGET" in
  *:*) : ;;  # explicit backend target: no home resolution, escape hatch preserved
  *)
    if [ -z "${FM_HOME:-}" ]; then
      echo "error: FM_HOME is not set; fm-peek refuses to resolve a task selector without an explicit firstmate home (pass session:window to target an endpoint outside this home)" >&2
      exit 1
    fi
    if [ ! -d "$FM_HOME" ]; then
      echo "error: FM_HOME '$FM_HOME' is not a directory; fm-peek cannot resolve this home's state" >&2
      exit 1
    fi
    if [ ! -d "${FM_STATE_OVERRIDE:-$FM_HOME/state}" ]; then
      echo "error: state dir '${FM_STATE_OVERRIDE:-$FM_HOME/state}' is missing; fm-peek cannot resolve targets for FM_HOME '$FM_HOME'" >&2
      exit 1
    fi
    ;;
esac

FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

T=$(fm_backend_resolve_selector "$RAW_TARGET" "$STATE")

BACKEND=$(fm_backend_of_selector "$RAW_TARGET" "$T" "$STATE")
EXPECTED_LABEL=$(fm_backend_expected_label_of_selector "$RAW_TARGET" "$STATE")

fm_backend_capture "$BACKEND" "$T" "$N" "$EXPECTED_LABEL"

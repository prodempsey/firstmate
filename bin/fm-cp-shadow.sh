#!/usr/bin/env bash
# fm-cp-shadow.sh - the thin, optional, env-gated HOOK POINT that mirrors ONE firstmate
# lifecycle action into the control-plane store, fire-and-forget, in parallel with the
# legacy operation (ORD-256 cutover stage CW2 shadow run).
#
# INERT BY DEFAULT. This hook is a no-op unless CP_SHADOW=1 is set in the environment.
# Shipping the hook is the template's job; ENABLING it in a runtime home (exporting
# CP_SHADOW=1, and wiring calls at the lifecycle chokepoints below) is firstmate's
# OPERATIONAL act, deliberately not done here. The legacy stores remain the operational
# authority until a later cutover stage; this only writes a parallel shadow trail.
#
# NEVER BLOCKS OR FAILS A LEGACY OP. Two guarantees stack: the mirror is backgrounded and
# fully detached, so a slow or wedged shadow write cannot delay the caller; and this script
# always exits 0, so a lifecycle script that calls it is never failed by a mirror problem.
# The underlying tool (control-plane/bin/cp-shadow.mjs) additionally logs every store error
# to a divergence file and exits 0 itself.
#
# Intended chokepoints (firstmate wires these when it enables the shadow run; each maps to a
# cp-shadow action - see control-plane/bin/cp-shadow.mjs --help):
#   task filed            fm-cp-shadow.sh task-filed --task <id> --kind <k> --title <t> [--repo <r>]
#   dispatched            fm-cp-shadow.sh dispatched --task <id>        (queued annotation; NOT begin-run)
#   status transition     fm-cp-shadow.sh status     --task <id> --status <s>
#   completion / failure  fm-cp-shadow.sh completed|failed --task <id>
#   teardown              fm-cp-shadow.sh teardown   --task <id>
#   archive               fm-cp-shadow.sh archived   --task <id>
#
# Store location and divergence log are resolved by the tool from FM_HOME (or the
# CP_SHADOW_DATA_DIR / CP_SHADOW_DIVERGENCE overrides); this hook passes its arguments
# through unchanged.
set -eu

# Gate: absent or any value other than exactly "1" -> silent no-op success.
if [ "${CP_SHADOW:-0}" != "1" ]; then
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CP_SHADOW_BIN="$ROOT/control-plane/bin/cp-shadow.mjs"

# Missing tool -> silent no-op. A mirror that cannot run must never fail the legacy op.
if [ ! -f "$CP_SHADOW_BIN" ]; then
  exit 0
fi

# Background and detach the mirror; discard its output. The subshell isolates the launch so
# a missing `node` or any spawn failure cannot escape to fail this hook or its caller.
( node "$CP_SHADOW_BIN" "$@" >/dev/null 2>&1 & ) || true

exit 0

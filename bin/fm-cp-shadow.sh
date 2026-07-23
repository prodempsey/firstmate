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
#
# FILE GATE (FM_HOME/config/cp-shadow.env). Env-only gating is fragile: a lifecycle script
# invoked from a non-interactive shell that never sourced the bashrc exports sees CP_SHADOW
# unset and silently no-ops, so a whole run of lifecycle actions can go unmirrored without a
# trace. To make enabling durable, when CP_SHADOW is UNSET in the environment this hook reads
# the optional LOCAL config file FM_HOME/config/cp-shadow.env (gitignored class, firstmate's
# own operational act, never shipped) for KEY=VALUE lines and exports them for the mirror:
#   CP_SHADOW=1                 turn the shadow run on (any other value stays inert)
#   CP_SHADOW_DATA_DIR=<path>   store override (see above)
#   CP_ORDER_SOURCE_PATH=<path> captain-order source override for order snapshots
#   CP_SHADOW_DIVERGENCE=<path> divergence-log override (optional)
# Only those four keys are honoured, and the value is the LITERAL rest of the line: no shell
# evaluation and no inline-comment trimming, so a comment must be its own line (CP_SHADOW=1
# with a trailing "# note" would set the value to "1 # note" and stay inert). Every other line
# - a #-comment, a blank, an unknown key, anything malformed - is ignored, and a malformed OR
# UNREADABLE file can never fail the caller (an open error is treated as inert, exit 0).
# Explicit ambient env always wins: a variable already set in the environment is left
# untouched, and if CP_SHADOW is set ambiently the file is not consulted at all. An absent
# file is inert exactly as before.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CP_SHADOW_BIN="$ROOT/control-plane/bin/cp-shadow.mjs"

# Export a config-file value only when its key is unset in the environment, so an explicit
# ambient value always wins. Restricted to the four honoured keys by its callers.
fm_cp_shadow_apply() { # <key> <value>
  case "$1" in
    CP_SHADOW)             [ -z "${CP_SHADOW+x}" ]             && export CP_SHADOW="$2" ;;
    CP_SHADOW_DATA_DIR)    [ -z "${CP_SHADOW_DATA_DIR+x}" ]    && export CP_SHADOW_DATA_DIR="$2" ;;
    CP_ORDER_SOURCE_PATH)  [ -z "${CP_ORDER_SOURCE_PATH+x}" ]  && export CP_ORDER_SOURCE_PATH="$2" ;;
    CP_SHADOW_DIVERGENCE)  [ -z "${CP_SHADOW_DIVERGENCE+x}" ]  && export CP_SHADOW_DIVERGENCE="$2" ;;
  esac
  return 0
}

# File gate: only consulted when CP_SHADOW is entirely unset in the environment (ambient
# CP_SHADOW, even "0" or empty, wins outright). Parse defensively - accept only the four
# honoured KEY=VALUE lines, ignore everything else - so a malformed file never fails us.
if [ -z "${CP_SHADOW+x}" ]; then
  CP_SHADOW_ENV_FILE="${FM_HOME:-$ROOT}/config/cp-shadow.env"
  if [ -f "$CP_SHADOW_ENV_FILE" ]; then
    # Slurp with a masked read: an unreadable or otherwise unopenable file yields empty
    # content and a clean exit, never a set -e abort mid-hook. Reading the content once here
    # (rather than redirecting the loop straight from the file) also closes the TOCTOU window
    # between the -f test and the open, and iterating a here-string can never fail to open.
    # tr drops any NUL bytes so a pathological file cannot spill a "ignored null byte" warning
    # onto the caller's stderr; the cat masks the open error so an unreadable file stays inert.
    fm_cp_content=$(cat "$CP_SHADOW_ENV_FILE" 2>/dev/null | tr -d '\000') || fm_cp_content=""
    while IFS= read -r fm_cp_line || [ -n "$fm_cp_line" ]; do
      case "$fm_cp_line" in
        CP_SHADOW=*|CP_SHADOW_DATA_DIR=*|CP_ORDER_SOURCE_PATH=*|CP_SHADOW_DIVERGENCE=*)
          fm_cp_key=${fm_cp_line%%=*}
          fm_cp_val=${fm_cp_line#*=}
          fm_cp_val=${fm_cp_val%$'\r'}   # tolerate a CRLF file
          fm_cp_shadow_apply "$fm_cp_key" "$fm_cp_val"
          ;;
        *) : ;;
      esac
    done <<< "$fm_cp_content"
    unset fm_cp_content fm_cp_line fm_cp_key fm_cp_val
  fi
fi

# Gate: absent or any value other than exactly "1" -> silent no-op success.
if [ "${CP_SHADOW:-0}" != "1" ]; then
  exit 0
fi

# Missing tool -> silent no-op. A mirror that cannot run must never fail the legacy op.
if [ ! -f "$CP_SHADOW_BIN" ]; then
  exit 0
fi

# Background and detach the mirror; discard its output. The subshell isolates the launch so
# a missing `node` or any spawn failure cannot escape to fail this hook or its caller.
( node "$CP_SHADOW_BIN" "$@" >/dev/null 2>&1 & ) || true

exit 0

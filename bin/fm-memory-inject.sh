#!/usr/bin/env bash
# Spawn-time governed memory injection (Memory PR-4, milestone B).
#
# Thin, fail-open wrapper that fm-spawn.sh calls for a ship/scout task just before
# it creates any backend window, leases a worktree, or launches the agent. It asks
# the memory CLI (`mem inject-brief`) to recall governed fleet memory for the task
# and inject a bounded, POINTER-ONLY `## Fleet memory` block into the finalized
# brief, leaving a spawn-time proof at data/<id>/memory-proof.json.
#
# Two layers keep this safe and inert:
#   1. Opt-in gate. Injection is OFF unless explicitly enabled (env
#      FM_MEMORY_INJECT=1, or a config/memory-inject.enabled file whose first line
#      is not a disable token). Default OFF means spawn behavior is byte-identical
#      to today until an operator turns it on - the same inert-until-opted-in
#      posture as X mode and cp-shadow.
#   2. Fail-open. Even when enabled, `mem inject-brief` mutates the brief ONLY when
#      there is proven memory to inject: an empty registry (current production
#      state), a proven zero-hit, a recall failure, a stale/missing index, an
#      unresolved {TASK}, or a missing memory CLI all leave the brief unchanged.
#      This wrapper NEVER fails the spawn - every path exits 0.
#
# Usage: fm-memory-inject.sh --task <id> --brief <path> --project <name> --kind <ship|scout>
#          [--max-pointers N] [--max-bytes N] [--candidate-cap N] [--proof-out <path>]
#
# Env:
#   FM_MEMORY_INJECT   1 = force enable, 0 = force disable, unset = config-gated.
#   MEM_CLI            override the memory CLI command (default: node <root>/memory/bin/mem.mjs).
#   MEM_REGISTRY_DIR   registry to recall from (default: the memory package default).
#   FM_MEMORY_DEBUG    when set, print skip reasons to stderr instead of staying silent.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

usage() {
  awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"
}

debug() { [ -n "${FM_MEMORY_DEBUG:-}" ] && echo "fm-memory-inject: $*" >&2 || true; }

TASK="" BRIEF="" PROJECT="" KIND="" PROOF_OUT=""
PASS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --task) TASK=${2:-}; shift 2 ;;
    --brief) BRIEF=${2:-}; shift 2 ;;
    --project) PROJECT=${2:-}; shift 2 ;;
    --kind) KIND=${2:-}; shift 2 ;;
    --proof-out) PROOF_OUT=${2:-}; shift 2 ;;
    --max-pointers|--max-bytes|--candidate-cap|--memory-type|--status|--scope)
      PASS+=("$1" "${2:-}"); shift 2 ;;
    *) debug "ignoring unknown arg: $1"; shift ;;
  esac
done

# --- opt-in gate ------------------------------------------------------------
enabled=0
case "${FM_MEMORY_INJECT:-}" in
  1|true|yes|on) enabled=1 ;;
  0|false|no|off) enabled=0 ;;
  "")
    # Config-gated: enabled when config/memory-inject.enabled exists and its first
    # non-empty line is not a disable token.
    gate_file="$CONFIG/memory-inject.enabled"
    if [ -f "$gate_file" ]; then
      first=$(grep -m1 '[^[:space:]]' "$gate_file" 2>/dev/null | tr -d '[:space:]' || true)
      case "$first" in
        0|false|no|off) enabled=0 ;;
        *) enabled=1 ;;
      esac
    fi
    ;;
  *) enabled=0 ;;
esac

if [ "$enabled" -ne 1 ]; then
  debug "disabled (FM_MEMORY_INJECT='${FM_MEMORY_INJECT:-}', no enabling config); brief unchanged"
  exit 0
fi

# --- required inputs --------------------------------------------------------
if [ -z "$TASK" ] || [ -z "$BRIEF" ] || [ -z "$PROJECT" ] || [ -z "$KIND" ]; then
  debug "missing required arg (task/brief/project/kind); brief unchanged"
  exit 0
fi
if [ ! -f "$BRIEF" ]; then
  debug "brief not a regular file: $BRIEF; nothing to inject"
  exit 0
fi

# --- resolve the memory CLI -------------------------------------------------
# Prefer an explicit MEM_CLI (tests / custom installs). Otherwise use node against
# the package that ships in this repo. If neither node nor MEM_CLI is available,
# injection is a silent no-op (fail-open): the brief is left exactly as-is.
if [ -n "${MEM_CLI:-}" ]; then
  # shellcheck disable=SC2206  # deliberate word-split: MEM_CLI is a command line
  MEM_CMD=($MEM_CLI)
elif command -v node >/dev/null 2>&1 && [ -f "$FM_ROOT/memory/bin/mem.mjs" ]; then
  MEM_CMD=(node "$FM_ROOT/memory/bin/mem.mjs")
else
  debug "no memory CLI available (need node + memory/bin/mem.mjs, or MEM_CLI); brief unchanged"
  exit 0
fi

args=(inject-brief --brief "$BRIEF" --task "$TASK" --project "$PROJECT" --kind "$KIND")
[ -n "$PROOF_OUT" ] && args+=(--proof-out "$PROOF_OUT")
args+=(${PASS[@]+"${PASS[@]}"})

# Never fail the spawn: capture the outcome, print one line, always exit 0.
if out=$("${MEM_CMD[@]}" "${args[@]}" 2>&1); then
  [ -n "$out" ] && printf '%s\n' "$out"
else
  debug "mem inject-brief exited non-zero (treated as no-injection): $out"
fi
exit 0

#!/usr/bin/env bash
# Spawn-time governed memory injection (Memory PR-4, milestone B).
#
# Thin, fail-open wrapper that fm-spawn.sh calls for a ship/scout task just before
# it creates any backend window, leases a worktree, or launches the agent. It asks
# the memory CLI (`mem inject-brief`) to recall governed fleet memory for the task
# and inject a bounded, POINTER-ONLY `## Fleet memory` block into the finalized
# brief, leaving a spawn-time proof at data/<id>/memory-proof.json.
#
# Three layers keep this safe:
#   1. Recall at every dispatch (Compounding Fleet stage B). Injection is ON by
#      default: every ship/scout dispatch recalls governed fleet memory for the
#      brief so last night's failure classes and prior solutions ride into the
#      crew's brief, cited. An operator can still force it OFF - env
#      FM_MEMORY_INJECT=0, or a config/memory-inject.enabled file whose first
#      non-empty line is a disable token (0/false/no/off).
#   2. Fail-open, never fail-wrong. Even on, `mem inject-brief` mutates the brief
#      ONLY when there is proven memory to inject: an empty/unavailable registry, a
#      proven zero-hit, a recall failure, a stale/missing index, an unresolved
#      {TASK}, or a missing memory CLI all leave the brief byte-for-byte unchanged.
#      So the wiring is inert until the registry actually holds relevant memory.
#   3. Bounded on the critical path. Recall now sits on the latency-critical spawn
#      path, so the CLI call is wrapped in a PORTABLE hard deadline that a slow,
#      hung, or missing tool cannot defeat, failing open to no-injection when it
#      hits (failure-class FC-006). This wrapper NEVER fails the spawn - every path
#      exits 0 - and NEVER blocks it past the deadline.
#
# Usage: fm-memory-inject.sh --task <id> --brief <path> --project <name> --kind <ship|scout>
#          [--max-pointers N] [--max-bytes N] [--candidate-cap N] [--proof-out <path>]
#
# Env:
#   FM_MEMORY_INJECT          1 = force enable, 0 = force disable, unset = on unless a config disable token.
#   FM_MEMORY_INJECT_TIMEOUT  hard deadline in seconds for the recall/inject call (default 8).
#   MEM_CLI                   override the memory CLI command (default: node <root>/memory/bin/mem.mjs).
#   MEM_REGISTRY_DIR          registry to recall from (default: the memory package default).
#   FM_MEMORY_DEBUG           when set, print skip reasons to stderr instead of staying silent.
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

# --- enablement gate --------------------------------------------------------
# Default ON: recall runs on every ship/scout dispatch. An explicit env value wins;
# absent an env value, a config/memory-inject.enabled file whose first non-empty
# line is a disable token forces it off (the only way to opt a home out).
enabled=1
case "${FM_MEMORY_INJECT:-}" in
  1|true|yes|on) enabled=1 ;;
  0|false|no|off) enabled=0 ;;
  "")
    gate_file="$CONFIG/memory-inject.enabled"
    if [ -f "$gate_file" ]; then
      first=$(grep -m1 '[^[:space:]]' "$gate_file" 2>/dev/null | tr -d '[:space:]' || true)
      case "$first" in
        0|false|no|off) enabled=0 ;;
        *) enabled=1 ;;
      esac
    fi
    ;;
  *) enabled=1 ;;
esac

if [ "$enabled" -ne 1 ]; then
  debug "disabled (FM_MEMORY_INJECT='${FM_MEMORY_INJECT:-}' or config disable token); brief unchanged"
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

# --- portable spawn-safe deadline -------------------------------------------
# Recall sits on the latency-critical spawn path, so the CLI call MUST be bounded
# by a portable hard deadline that a slow/hung/missing tool cannot defeat, and MUST
# fail open to no-injection when it hits - never block the spawn (FC-006). Prefer
# GNU timeout / gtimeout; fall back to a perl fork+alarm that signals the whole
# child process group (perl ships on macOS where GNU timeout does not). This is the
# same portable-deadline idiom bin/fm-watch-checkpoint.sh uses on the primary path.
BUDGET="${FM_MEMORY_INJECT_TIMEOUT:-8}"
run_with_deadline() {  # runs "$@" under BUDGET seconds; exit 124 == deadline hit
  if command -v timeout >/dev/null 2>&1; then
    timeout "$BUDGET" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$BUDGET" "$@"
  else
    perl -e '
      my $seconds = shift;
      my $pid = fork;
      die "fork failed\n" unless defined $pid;
      if (!$pid) { setpgrp(0, 0); exec @ARGV; die "exec failed: $!\n"; }
      local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124; };
      alarm $seconds;
      waitpid $pid, 0;
      exit($? >> 8);
    ' "$BUDGET" "$@"
  fi
}

# Never fail the spawn: capture the outcome, print one line, always exit 0. Any
# non-zero exit (including 124 = deadline) is treated as no-injection. injection.mjs
# writes via same-dir temp + fsync + atomic rename + read-back, so a child killed
# mid-write leaves the brief byte-for-byte intact rather than partially rewritten.
if out=$(run_with_deadline "${MEM_CMD[@]}" "${args[@]}" 2>&1); then
  [ -n "$out" ] && printf '%s\n' "$out"
else
  rc=$?
  if [ "$rc" -eq 124 ]; then
    debug "mem inject-brief exceeded ${BUDGET}s deadline (treated as no-injection); brief unchanged"
  else
    debug "mem inject-brief exited $rc (treated as no-injection): $out"
  fi
fi
exit 0

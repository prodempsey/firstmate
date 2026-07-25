#!/usr/bin/env bash
# fm-qa-dispatch.sh - the QA-dispatch chokepoint: gate a codex QA scout on the
# Gauntlet evidence bundle before it is ever spawned.
#
# WHY THIS EXISTS
# ---------------
# QA round 1 has become the fleet's de-facto linter: the QA scout is spent
# rediscovering mechanically-detectable defects that bin/fm-verify.sh (the
# Gauntlet) already proves or refutes. This wrapper is the single sanctioned path
# for dispatching a QA scout. It refuses to spawn one unless a FRESH, PASSING
# verify bundle exists for the EXACT candidate SHA under review, and it scaffolds
# the QA brief so it auto-references that bundle - so the reviewer starts from
# executed evidence and spends its whole budget on semantics. Design authority:
# data/kl-improve2-scout-f6/report.md improvement 1 (4) (in firstmate-runtime).
#
# Bundle freshness is bound to the EXACT SHA (FC-002/FC-003 discipline): a bundle
# whose candidate.head_sha does not equal the SHA under review is stale and
# refused, so a passing bundle for an older commit can never wave through code it
# never saw. The refusal is fail-closed, the same idiom as fm_backend_validate_spawn.
#
# The escape hatch is explicit and never silent: --no-gauntlet <reason> waives the
# gate for a genuine NON-CODE scout (a docs audit, a research question), and the
# waiver is appended to state/gauntlet-dispatch.log AND written into the brief.
#
# Usage:
#   fm-qa-dispatch.sh <qa-task-id> <repo> --sha <candidate-sha> [options]
#     <qa-task-id>         The QA scout's own task id (the one that gets spawned).
#     <repo>               Project dir (e.g. projects/foo), passed to brief + spawn.
#     --sha <sha>          REQUIRED unless --no-gauntlet. The exact candidate HEAD
#                          the QA scout will review; the bundle MUST be bound to it.
#     --branch <name>      Candidate branch (echoed into the fm-verify remedy line).
#     --bundle <path>      Verify bundle to gate on.
#                          Default: data/<qa-task-id>/verify-bundle.json.
#     --no-gauntlet <why>  Escape hatch for a NON-CODE scout: skip the gate. The
#                          reason is REQUIRED and the waiver is logged (never silent).
#     --no-spawn           Run the gate + brief scaffold only; do not spawn.
#     --harness <name>     Forwarded to fm-spawn (required when crew-dispatch.json exists).
#     --model <name>       Forwarded to fm-spawn.
#     --effort <level>     Forwarded to fm-spawn.
#     --backend <name>     Forwarded to fm-spawn.
#     --kd-review          Forwarded to fm-brief (visual-review contract).
#     -h, --help           This help.
#
# EXIT
#   0  gate passed (or waived); brief ready; scout spawned unless --no-spawn or the
#      brief still carries an unfilled {TASK} (author it, then re-run to spawn)
#   2  usage error
#   3  gate REFUSED - bundle missing, stale (SHA mismatch), invalidated, or failing
#
# Environment:
#   FM_QA_SPAWN   spawn helper exec'd for the final launch (default bin/fm-spawn.sh);
#                 an override seam for tests.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() { sed -n '/^# Usage:/,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//;$d'; }

case "${1:-}" in -h|--help) usage; exit 0 ;; esac

ID=""
REPO=""
SHA=""
BRANCH=""
BUNDLE=""
NO_GAUNTLET=0
WAIVER_REASON=""
NO_SPAWN=0
SPAWN_ARGS=()
BRIEF_ARGS=()
POS=()

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --sha) SHA=${2:-}; shift ;;
    --branch) BRANCH=${2:-}; shift ;;
    --bundle) BUNDLE=${2:-}; shift ;;
    --no-gauntlet) NO_GAUNTLET=1; WAIVER_REASON=${2:-}; shift ;;
    --no-spawn) NO_SPAWN=1 ;;
    --harness) SPAWN_ARGS+=(--harness "${2:-}"); shift ;;
    --model)   SPAWN_ARGS+=(--model "${2:-}"); shift ;;
    --effort)  SPAWN_ARGS+=(--effort "${2:-}"); shift ;;
    --backend) SPAWN_ARGS+=(--backend "${2:-}"); shift ;;
    --kd-review|--visual-review) BRIEF_ARGS+=("$1") ;;
    --scout) : ;;  # always implied for a QA dispatch; tolerate an explicit one
    --) shift; break ;;
    -*) echo "error: unknown option: $1" >&2; exit 2 ;;
    *) POS+=("$1") ;;
  esac
  shift
done

ID=${POS[0]:-}
REPO=${POS[1]:-}
[ -n "$ID" ] || { echo "error: <qa-task-id> is required" >&2; exit 2; }
[ -n "$REPO" ] || { echo "error: <repo> is required" >&2; exit 2; }
[ "${#POS[@]}" -le 2 ] || { echo "error: unexpected extra arguments: ${POS[*]:2}" >&2; exit 2; }

[ -n "$BUNDLE" ] || BUNDLE="$DATA/$ID/verify-bundle.json"

# One durable, greppable line per QA dispatch decision - the waiver is never silent.
log_dispatch() {
  local verb=$1; shift
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "-")
  mkdir -p "$STATE" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\n' "$ts" "$verb" "$ID" "$*" >> "$STATE/gauntlet-dispatch.log" 2>/dev/null || true
}

# A refusal always names the one-line remedy (run fm-verify) so the operator's
# next action is unambiguous.
remedy() {
  printf 'remedy: run bin/fm-verify.sh --worktree <candidate-worktree> --sha %s%s --task %s so a fresh PASSING bundle exists at %s\n' \
    "${SHA:-<candidate-sha>}" "${BRANCH:+ --branch $BRANCH}" "$ID" "$BUNDLE" >&2
}
refuse_gate() {
  echo "fm-qa-dispatch: QA dispatch REFUSED - $1" >&2
  remedy
  exit 3
}

if [ "$NO_GAUNTLET" = 1 ]; then
  case "$WAIVER_REASON" in
    ""|--*) echo "error: --no-gauntlet requires a non-empty reason (the non-code-scout justification)" >&2; exit 2 ;;
  esac
  log_dispatch WAIVED "reason=$WAIVER_REASON"
  echo "fm-qa-dispatch: Gauntlet gate WAIVED for $ID (reason: $WAIVER_REASON); waiver logged to $STATE/gauntlet-dispatch.log" >&2
else
  [ -n "$SHA" ] || { echo "error: --sha <candidate-sha> is required (the exact SHA under review); use --no-gauntlet <reason> only for a non-code scout" >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || refuse_gate "jq is required to read the verify bundle but is not installed"
  [ -f "$BUNDLE" ] || refuse_gate "no verify bundle at $BUNDLE (the Gauntlet has not run for this candidate)"

  schema=$(jq -r '.schema // ""' "$BUNDLE" 2>/dev/null || echo "")
  [ "$schema" = "firstmate/verify-bundle/1" ] || refuse_gate "$BUNDLE is not a readable Gauntlet bundle (schema '$schema')"

  verdict=$(jq -r '.verdict // ""' "$BUNDLE" 2>/dev/null || echo "")
  head_sha=$(jq -r '.candidate.head_sha // ""' "$BUNDLE" 2>/dev/null || echo "")
  case "$verdict" in
    invalidated) refuse_gate "verify bundle is invalidated (verification incomplete or refused)" ;;
    pass) : ;;
    *) refuse_gate "verify bundle verdict is '$verdict' (findings unresolved)" ;;
  esac
  [ "$head_sha" = "$SHA" ] || refuse_gate "verify bundle is stale: bundle SHA ${head_sha:-<none>} does not match candidate $SHA"

  log_dispatch PASS "sha=$SHA bundle=$BUNDLE"
  echo "fm-qa-dispatch: Gauntlet gate PASSED for $ID @ ${SHA:0:12} (bundle $BUNDLE)" >&2
fi

# --- brief: auto-reference the bundle (or record the waiver) ------------------
BRIEF="$DATA/$ID/brief.md"
if [ ! -f "$BRIEF" ]; then
  if [ "$NO_GAUNTLET" = 1 ]; then
    "$FM_ROOT/bin/fm-brief.sh" "$ID" "$REPO" --scout --gauntlet-waived "$WAIVER_REASON" ${BRIEF_ARGS[@]+"${BRIEF_ARGS[@]}"} \
      || { echo "error: failed to scaffold QA brief" >&2; exit 2; }
  else
    "$FM_ROOT/bin/fm-brief.sh" "$ID" "$REPO" --scout --gauntlet-bundle "$BUNDLE" ${BRIEF_ARGS[@]+"${BRIEF_ARGS[@]}"} \
      || { echo "error: failed to scaffold QA brief" >&2; exit 2; }
  fi
  if [ "$NO_GAUNTLET" = 1 ]; then
    echo "fm-qa-dispatch: scaffolded QA brief at $BRIEF (records the Gauntlet waiver); replace {TASK} with the QA charge, then re-run to spawn." >&2
  else
    echo "fm-qa-dispatch: scaffolded QA brief at $BRIEF (references the evidence bundle); replace {TASK} with the QA charge, then re-run to spawn." >&2
  fi
elif [ "$NO_GAUNTLET" != 1 ] && ! grep -Fq "$BUNDLE" "$BRIEF"; then
  echo "warning: existing brief $BRIEF does not reference the evidence bundle ($BUNDLE); re-scaffold with fm-brief --scout --gauntlet-bundle to embed it." >&2
fi

# --- spawn --------------------------------------------------------------------
if [ "$NO_SPAWN" = 1 ]; then
  echo "fm-qa-dispatch: gate cleared; brief ready at $BRIEF; spawn skipped (--no-spawn)."
  exit 0
fi
if grep -q '{TASK}' "$BRIEF"; then
  echo "fm-qa-dispatch: brief $BRIEF still carries {TASK}; author the QA charge, then re-run to spawn." >&2
  exit 0
fi

SPAWN=${FM_QA_SPAWN:-$FM_ROOT/bin/fm-spawn.sh}
exec "$SPAWN" "$ID" "$REPO" --scout ${SPAWN_ARGS[@]+"${SPAWN_ARGS[@]}"}

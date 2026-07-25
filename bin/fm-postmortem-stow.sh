#!/usr/bin/env bash
# fm-postmortem-stow.sh - the thin, optional, gate-controlled HOOK POINT that distills a
# finished task's closeout into a STRUCTURED POSTMORTEM MEMORY RECORD, fire-and-forget, in
# parallel with the legacy closeout (ORD-274 Seasoning stage A - postmortem capture).
#
# INERT BY DEFAULT. This hook is a no-op unless FM_POSTMORTEM_STOW=1 is set in the environment
# (or in the file gate below). Shipping the hook is the template's job; ENABLING it in a runtime
# home is firstmate's OPERATIONAL act, deliberately not done here - the same inert-until-opted-in
# posture as cp-shadow (bin/fm-cp-shadow.sh) and spawn-time memory injection
# (bin/fm-memory-inject.sh). The memory registry stays untouched until an operator turns it on.
#
# NEVER BLOCKS OR FAILS THE CLOSEOUT. Two guarantees stack, exactly as cp-shadow's do: the write
# is backgrounded and fully detached, so a slow or wedged memory write cannot delay teardown; and
# this script ALWAYS exits 0, so a closeout script that calls it is never failed by a postmortem
# problem. A missing memory CLI, an unreadable gate file, an unwritable registry, or a `mem`
# non-zero exit are all silent no-ops from the caller's point of view.
#
# INERT WHEN MEMORY IS UNAVAILABLE. If neither an explicit MEM_CLI nor `node` + the shipped
# memory/bin/mem.mjs can be resolved, the hook exits 0 without writing anything.
#
# LIFECYCLE: PROPOSE, NEVER ACTIVATE. The postmortem lands as a CANDIDATE via `mem propose`. It
# is never auto-activated: activation policy stays curated (a candidate is inert to governed
# recall until a captain-authorized `mem activate`). This preserves the memory package's
# propose-not-auto-activate contract and its canonical registry location (resolved by the CLI
# from MEM_REGISTRY_DIR or its default - this hook never redirects it except from the gate file).
#
# PROVENANCE. Every record carries source_type=task-postmortem plus task/SHA/PR/report provenance
# as structured evidence entries, so a later recall/curation pass can filter postmortems and trace
# each claim to its closing task. source_type=task-postmortem is deliberately NOT a managed
# migration source, so a corpus re-seed never tombstones a postmortem.
#
# Intended chokepoint (firstmate wires this at the universal task closeout):
#   fm-teardown.sh, after the durable visibility closeout, once per ship/scout task.
#
# Usage:
#   fm-postmortem-stow.sh --task <id> --kind <ship|scout> [--project <name>] [--mode <mode>]
#     [--outcome <text>] [--report <path>] [--brief <path>] [--sha <sha>] [--pr <url>]
#     [--evidence <closure-evidence>]
#
# FILE GATE (FM_HOME/config/postmortem-stow.env). Env-only gating is fragile: a closeout script
# invoked from a non-interactive shell that never sourced a bashrc sees FM_POSTMORTEM_STOW unset
# and silently no-ops, so a whole run of closeouts can go uncaptured without a trace. So when
# FM_POSTMORTEM_STOW is UNSET in the environment this hook reads the optional LOCAL config file
# FM_HOME/config/postmortem-stow.env (gitignored class, firstmate's own operational act, never
# shipped) for KEY=VALUE lines and exports them:
#   FM_POSTMORTEM_STOW=1     turn postmortem capture on (any other value stays inert)
#   MEM_REGISTRY_DIR=<path>  registry override (else the memory package default)
#   MEM_CLI=<command>        memory CLI override (else node <root>/memory/bin/mem.mjs)
# Only those three keys are honoured, and the value is the LITERAL rest of the line: no shell
# evaluation and no inline-comment trimming, so a comment must be its own line. Every other line
# - a #-comment, a blank, an unknown key, anything malformed - is ignored, and a malformed OR
# UNREADABLE file can never fail the caller (an open error is treated as inert, exit 0). Explicit
# ambient env always wins: a variable already set in the environment is left untouched, and if
# FM_POSTMORTEM_STOW is set ambiently the file is not consulted at all. An absent file is inert.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}"

# Export a config-file value only when its key is unset in the environment, so an explicit
# ambient value always wins. Restricted to the three honoured keys by its callers.
fm_pm_apply() { # <key> <value>
  case "$1" in
    FM_POSTMORTEM_STOW) [ -z "${FM_POSTMORTEM_STOW+x}" ] && export FM_POSTMORTEM_STOW="$2" ;;
    MEM_REGISTRY_DIR)   [ -z "${MEM_REGISTRY_DIR+x}" ]   && export MEM_REGISTRY_DIR="$2" ;;
    MEM_CLI)            [ -z "${MEM_CLI+x}" ]            && export MEM_CLI="$2" ;;
  esac
  return 0
}

# File gate: only consulted when FM_POSTMORTEM_STOW is entirely unset in the environment (ambient
# FM_POSTMORTEM_STOW, even "0" or empty, wins outright). Parse defensively - accept only the three
# honoured KEY=VALUE lines, ignore everything else - so a malformed file never fails us.
if [ -z "${FM_POSTMORTEM_STOW+x}" ]; then
  FM_PM_ENV_FILE="$FM_HOME/config/postmortem-stow.env"
  if [ -f "$FM_PM_ENV_FILE" ]; then
    # Slurp with a masked read: an unreadable or otherwise unopenable file yields empty content
    # and a clean exit, never a set -e abort mid-hook. Reading the content once here (rather than
    # redirecting the loop straight from the file) also closes the TOCTOU window between the -f
    # test and the open, and iterating a here-string can never fail to open. tr drops any NUL
    # bytes so a pathological file cannot spill a warning onto the caller's stderr; the cat masks
    # the open error so an unreadable file stays inert.
    fm_pm_content=$(cat "$FM_PM_ENV_FILE" 2>/dev/null | tr -d '\000') || fm_pm_content=""
    while IFS= read -r fm_pm_line || [ -n "$fm_pm_line" ]; do
      case "$fm_pm_line" in
        FM_POSTMORTEM_STOW=*|MEM_REGISTRY_DIR=*|MEM_CLI=*)
          fm_pm_key=${fm_pm_line%%=*}
          fm_pm_val=${fm_pm_line#*=}
          fm_pm_val=${fm_pm_val%$'\r'}   # tolerate a CRLF file
          fm_pm_apply "$fm_pm_key" "$fm_pm_val"
          ;;
        *) : ;;
      esac
    done <<< "$fm_pm_content"
    unset fm_pm_content fm_pm_line fm_pm_key fm_pm_val
  fi
fi

# Gate: absent or any value other than exactly "1" -> silent no-op success.
if [ "${FM_POSTMORTEM_STOW:-0}" != "1" ]; then
  exit 0
fi

# --- parse args -------------------------------------------------------------
TASK="" KIND="" PROJECT="" MODE="" OUTCOME="" REPORT="" BRIEF="" SHA="" PR="" EVIDENCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --task)     TASK=${2:-}; shift 2 ;;
    --kind)     KIND=${2:-}; shift 2 ;;
    --project)  PROJECT=${2:-}; shift 2 ;;
    --mode)     MODE=${2:-}; shift 2 ;;
    --outcome)  OUTCOME=${2:-}; shift 2 ;;
    --report)   REPORT=${2:-}; shift 2 ;;
    --brief)    BRIEF=${2:-}; shift 2 ;;
    --sha)      SHA=${2:-}; shift 2 ;;
    --pr)       PR=${2:-}; shift 2 ;;
    --evidence) EVIDENCE=${2:-}; shift 2 ;;
    *) shift ;;
  esac
done

# A task id is the minimum needed to attribute a postmortem; without it, stay inert.
[ -n "$TASK" ] || exit 0
[ -n "$KIND" ] || KIND=ship

# --- resolve the memory CLI (inert when unavailable) ------------------------
# Prefer an explicit MEM_CLI (tests / custom installs). Otherwise node against the package that
# ships in this repo. If neither resolves, capture is a silent no-op (memory unavailable).
if [ -n "${MEM_CLI:-}" ]; then
  # shellcheck disable=SC2206  # deliberate word-split: MEM_CLI is a command line
  MEM_CMD=($MEM_CLI)
elif command -v node >/dev/null 2>&1 && [ -f "$ROOT/memory/bin/mem.mjs" ]; then
  MEM_CMD=(node "$ROOT/memory/bin/mem.mjs")
else
  exit 0
fi

# --- distill the closeout into a structured record --------------------------
[ -n "$OUTCOME" ] || OUTCOME="closed out"

# Summary is bounded by the registry schema (<=240 chars); build it, then hard-cap.
proj_label=${PROJECT:-fleet}
summary="Postmortem: $TASK ($KIND/$proj_label) - $OUTCOME"
summary=${summary:0:240}

# The raw material for the what-worked / what-failed / sharp-edges distillation: prefer the
# scout report, else the task brief's task text. Bounded to the first lines so the record stays a
# distillation, not a copy, and so a byte cap can never split a multibyte character.
excerpt=""
excerpt_src=""
if [ -n "$REPORT" ] && [ -f "$REPORT" ]; then
  excerpt=$(head -n 60 "$REPORT" 2>/dev/null || true)
  excerpt_src="$REPORT"
elif [ -n "$BRIEF" ] && [ -f "$BRIEF" ]; then
  # From a brief, the useful signal is the task description; fall back to the head.
  excerpt=$(awk '/^# Task/{f=1;next} /^# /{if(f)exit} f' "$BRIEF" 2>/dev/null | head -n 40 || true)
  [ -n "$excerpt" ] || excerpt=$(head -n 40 "$BRIEF" 2>/dev/null || true)
  excerpt_src="$BRIEF"
fi
[ -n "$excerpt" ] || excerpt="(no report or brief was available at closeout; closure evidence below is the record.)"

# Closure-evidence lines, deterministic and provenance-bearing.
close_lines="- task: $TASK"
[ -n "$SHA" ]      && close_lines="$close_lines"$'\n'"- sha: $SHA"
[ -n "$PR" ]       && close_lines="$close_lines"$'\n'"- pr: $PR"
[ -n "$REPORT" ]   && close_lines="$close_lines"$'\n'"- report: $REPORT"
[ -n "$EVIDENCE" ] && [ "$EVIDENCE" != "$SHA" ] && [ "$EVIDENCE" != "$REPORT" ] \
  && close_lines="$close_lines"$'\n'"- closure: $EVIDENCE"

body="## Task postmortem: $TASK

- Task: $TASK
- Kind: $KIND
- Project: $proj_label
- Delivery mode: ${MODE:-unknown}
- Outcome: $OUTCOME

## Closure evidence
$close_lines

## What worked / what failed / sharp edges${excerpt_src:+ (distilled from $excerpt_src)}
$excerpt

## Provenance
source_type: task-postmortem
task: $TASK${SHA:+
sha: $SHA}${PR:+
pr: $PR}${REPORT:+
report: $REPORT}
captured-at: closeout"

# --- build the propose invocation (candidate, never activated) --------------
# Scope a project-attributed lesson to the project; a project-less closeout is a fleet lesson.
scope=fleet
[ -n "$PROJECT" ] && scope=project

args=(propose
  --summary "$summary"
  --body "$body"
  --memory-type procedural
  --scope "$scope"
  --kind "$KIND"
  --keyword postmortem --keyword task-postmortem --keyword "$TASK"
  --confidence unverified
  --evidence source-type:task-postmortem
  --evidence "task:$TASK"
  --reason "task-postmortem capture at closeout for $TASK"
  --actor-kind firstmate --actor fm-postmortem)
[ -n "$PROJECT" ] && args+=(--project "$PROJECT")
[ -n "$PROJECT" ] && args+=(--keyword "$PROJECT")
[ -n "$SHA" ]     && args+=(--evidence "sha:$SHA")
[ -n "$PR" ]      && args+=(--evidence "pr:$PR")
[ -n "$REPORT" ]  && args+=(--evidence "report:$REPORT")

# Background and detach the write; discard its output. The subshell isolates the launch so a
# missing `node`, a wedged registry lock, or any spawn failure cannot escape to fail this hook or
# its caller. Mirrors bin/fm-cp-shadow.sh's fire-and-forget contract.
( "${MEM_CMD[@]}" "${args[@]}" >/dev/null 2>&1 & ) || true

exit 0

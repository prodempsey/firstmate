#!/usr/bin/env bash
# fm-verify.sh - the Gauntlet: a deterministic, LLM-free pre-QA verifier.
#
# WHY THIS EXISTS
# ---------------
# QA round 1 has become the fleet's de-facto linter: the codex QA scout is spent
# rediscovering mechanically-detectable defects (a SKIPped test that never ran, a
# stale base, a SHA/label mismatch, a greppable failure-class cue) instead of
# semantics. This verifier runs BEFORE a QA scout is dispatched and produces a
# machine-checked evidence bundle so the reviewer can spend its whole budget on
# judgement, not on things a script can prove. Design authority:
# data/kl-improve2-scout-f6/report.md improvement 1 (in firstmate-runtime).
#
# A verifier must itself obey the failure-class ledger it lints with. The five
# invariants that shape this script:
#   FC-002  completeness is positive per-item proof; absence from a partial
#           discovery is NOT discharge - every declared suite is executed and
#           recorded, never a first-match ladder that silently omits one.
#   FC-004  a missing prerequisite tool is a refusal, never a skipped check.
#   FC-005  the proof must be ATOMIC with the attestation it authorizes - every
#           mutable git fact is read once AFTER execution and revalidated against
#           a pre-execution snapshot; any drift fails the run.
#   FC-006  every call on this latency-critical path is bounded by a PORTABLE
#           hard deadline (timeout/gtimeout, else a PID-watchdog) that a missing
#           tool cannot defeat; a wedged suite is a finding, never a hang.
#   FC-007  the authoritative output is INVALIDATED before work begins, so no
#           refusal or crash can leave a stale passing bundle to be read as fresh.
#
# THE GATES (each recorded in the bundle with pass/fail and findings)
#   identity        HEAD SHA + branch bound to the DECLARED candidate (mandatory
#                   --sha/--branch); tree clean - read post-execution
#   base_currency   the candidate contains the current canonical trunk tip
#                   (bin/fm-trunk-check.sh integration when --project is given)
#   tests           EVERY discovered suite ACTUALLY EXECUTED under a hard
#                   deadline; PASS/FAIL/SKIP/TIMEOUT parsed; SKIP, timeout, and
#                   no-tests are findings, never passes
#   cue_lint        failure-class detection cues sourced from the ledger's
#                   machine-readable `detection` field (built-in patterns are a
#                   labeled fallback) grepped against the candidate DIFF
#   brief_contract  the dispatch contract echoed from the mandatory brief plus
#                   the mechanically-checkable items (committed work, branch)
#   revalidation    the pre-execution git snapshot equals the post-execution one
#                   (FC-005): HEAD, branch, porcelain, and base did not move
#
# THE BUNDLE lands at data/<task>/verify-bundle.json (JSON) with a sibling
# verify-summary.md; a human summary also prints to stdout. The path is
# invalidated first (FC-007) and the final result is published atomically.
#
# EXIT
#   0  clean pass: every gate passed with zero findings
#   1  findings: at least one gate failed or produced a finding
#   2  refuse: a prerequisite tool is missing, a mandatory binding is absent or
#      unreadable, or an input could not be read (fail closed; the output path is
#      left carrying a non-authoritative "invalidated" marker, never a stale pass)
#
# Usage:
#   fm-verify.sh --worktree <path> --sha <sha> --branch <name> --task <id> [options]
#     --worktree <path>   REQUIRED. The candidate worktree to verify.
#     --sha <sha>         REQUIRED. The declared HEAD sha the candidate must be at.
#     --branch <name>     REQUIRED. The declared branch the candidate must be on.
#     --task <id>         REQUIRED. Task id: locates the brief and default --out.
#     --base <ref>        Explicit base ref for currency + diff (skips trunk-check).
#     --project <name>    Resolve the canonical trunk via bin/fm-trunk-check.sh.
#     --tests-cmd <cmd>   Explicit closed test command run in the worktree.
#     --brief <file>      Brief file to echo + check (default data/<task>/brief.md).
#     --out <file>        Bundle path (default data/<task>/verify-bundle.json).
#     --format json|text  Human summary format on stdout (default text).
#     -h, --help          This help.
#
# Environment:
#   FM_VERIFY_TEST_TIMEOUT       per-suite hard deadline in seconds (default 600).
#   FM_VERIFY_FORCE_PID_WATCHDOG =1 forces the portable PID-watchdog deadline even
#                                when timeout(1) exists, to regression-test the
#                                no-timeout path required by FC-006.
#   FM_FAILURE_LEDGER            override the failure-class ledger path.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LEDGER="${FM_FAILURE_LEDGER:-$FM_ROOT/docs/failure-classes/ledger.jsonl}"
TEST_TIMEOUT="${FM_VERIFY_TEST_TIMEOUT:-600}"

usage() { sed -n '/^# Usage:/,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//;$d'; }

# refuse() aborts with exit 2. Once OUT is known it is left carrying the
# invalidation marker written by invalidate_output (FC-007), never a stale pass.
refuse() { echo "fm-verify: $1" >&2; exit 2; }

# --- arguments (pure bash; parsed before any external-tool dependency) --------
WORKTREE=""
EXPECT_SHA=""
EXPECT_BRANCH=""
BASE_REF=""
PROJECT=""
TESTS_CMD=""
TESTS_CMD_SET=no
BRIEF=""
TASK=""
OUT=""
FORMAT=text
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --worktree) WORKTREE=${2:-}; shift ;;
    --sha) EXPECT_SHA=${2:-}; shift ;;
    --branch) EXPECT_BRANCH=${2:-}; shift ;;
    --base) BASE_REF=${2:-}; shift ;;
    --project) PROJECT=${2:-}; shift ;;
    --tests-cmd) TESTS_CMD=${2:-}; TESTS_CMD_SET=yes; shift ;;
    --brief) BRIEF=${2:-}; shift ;;
    --task) TASK=${2:-}; shift ;;
    --out) OUT=${2:-}; shift ;;
    --format) FORMAT=${2:-}; shift ;;
    -*) refuse "unknown option $1" ;;
    *) refuse "unexpected argument $1" ;;
  esac
  shift
done

case "$FORMAT" in json|text) ;; *) refuse "--format must be json or text" ;; esac

# The output path must be resolvable before anything else so it can be
# invalidated (FC-007). --task alone is enough (it fixes the default path).
if [ -z "$OUT" ]; then
  [ -n "$TASK" ] || refuse "--out or --task is required to place (and invalidate) the bundle"
  OUT="$DATA/$TASK/verify-bundle.json"
fi
OUT_DIR=$(dirname "$OUT")

# --- FC-007: invalidate the authoritative output as the FIRST durable action --
# A non-authoritative marker overwrites any prior bundle before a single
# tool-dependent or execution step runs, so NO refusal or crash below can leave a
# stale passing bundle at OUT. The marker is written with printf (no jq), so it
# does not depend on the prerequisite tools checked next. A failed invalidation
# fails the run rather than proceeding over stale authority.
invalidate_output() {
  mkdir -p "$OUT_DIR" || refuse "cannot create output dir: $OUT_DIR (stale output NOT invalidated)"
  local tmp="$OUT.invalidating.$$"
  printf '%s\n' '{"schema":"firstmate/verify-bundle/1","verdict":"invalidated","reason":"verification started or refused; no authoritative result at this path","gates":[],"findings":[]}' > "$tmp" \
    || refuse "cannot stage invalidation marker at $tmp"
  mv -f "$tmp" "$OUT" || { rm -f "$tmp"; refuse "cannot invalidate stale output at $OUT"; }
}
invalidate_output

# --- prerequisites (FC-004: a missing tool is a refusal, not a skipped check) --
for tool in git jq awk grep sed; do
  command -v "$tool" >/dev/null 2>&1 || refuse "missing prerequisite tool: $tool (fail closed, FC-004)"
done

# --- mandatory bindings (F1: identity is proven, never merely observed) -------
[ -n "$WORKTREE" ] || refuse "--worktree is required"
[ -d "$WORKTREE" ] || refuse "worktree does not exist: $WORKTREE"
git -C "$WORKTREE" rev-parse --git-dir >/dev/null 2>&1 || refuse "worktree is not a git repository: $WORKTREE"
[ -n "$EXPECT_SHA" ] || refuse "--sha is required: an authoritative bundle must be bound to a declared SHA"
[ -n "$EXPECT_BRANCH" ] || refuse "--branch is required: an authoritative bundle must be bound to a declared branch"
[ -n "$TASK" ] || refuse "--task is required: an authoritative bundle must be bound to a task"
[ -z "$BRIEF" ] && BRIEF="$DATA/$TASK/brief.md"
[ -f "$BRIEF" ] || refuse "brief not found or unreadable: $BRIEF (the dispatch contract must be present)"
case "$TEST_TIMEOUT" in ''|*[!0-9]*) refuse "FM_VERIFY_TEST_TIMEOUT must be a positive integer: $TEST_TIMEOUT" ;; esac
[ "$TEST_TIMEOUT" -gt 0 ] || refuse "FM_VERIFY_TEST_TIMEOUT must be a positive integer: $TEST_TIMEOUT"

# --- scratch ----------------------------------------------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-verify.XXXXXX") || refuse "cannot create scratch dir"
# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

GATES="$WORK/gates.jsonl"
FINDINGS="$WORK/findings.jsonl"
: > "$GATES"
: > "$FINDINGS"

FINDING_COUNT=0
# emit_finding <gate> <code> <severity> <message> [file] [line]
emit_finding() {
  local gate=$1 code=$2 severity=$3 message=$4 file=${5:-} line=${6:-}
  jq -nc \
    --arg gate "$gate" --arg code "$code" --arg sev "$severity" \
    --arg msg "$message" --arg file "$file" --arg line "$line" \
    '{gate:$gate,code:$code,severity:$sev,message:$msg,
      file:(if $file=="" then null else $file end),
      line:(if $line=="" then null else ($line|tonumber?) end)}' >> "$FINDINGS"
  FINDING_COUNT=$((FINDING_COUNT + 1))
}
# emit_gate <name> <status> <details-json>
emit_gate() {
  local name=$1 status=$2 details=$3
  jq -nc --arg name "$name" --arg status "$status" --argjson details "$details" \
    '{gate:$name,status:$status,details:$details}' >> "$GATES"
}

# ============================================================================
# Base resolution (the ref the candidate must be current with; drives the diff)
# ============================================================================
BASE_SHA=""
BASE_LABEL=""
BASE_SOURCE=""
base_status=pass

resolve_local_default() {
  local ref b
  ref=$(git -C "$WORKTREE" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then printf '%s\n' "${ref#origin/}"; return 0; fi
  for b in main master; do
    git -C "$WORKTREE" show-ref --verify --quiet "refs/heads/$b" && { printf '%s\n' "$b"; return 0; }
  done
  return 1
}

# base_tip_now echoes the base's current commit, so a test that moved a local
# base ref is caught by revalidation (FC-005). A trunk-check base lives in an
# external checkout and cannot be moved by the candidate's tests.
base_tip_now() {
  case "$BASE_SOURCE" in
    explicit) git -C "$WORKTREE" rev-parse --verify "$BASE_REF^{commit}" 2>/dev/null || true ;;
    local-default) git -C "$WORKTREE" rev-parse --verify "refs/heads/$BASE_LABEL^{commit}" 2>/dev/null || true ;;
    *) printf '%s\n' "$BASE_SHA" ;;
  esac
}

if [ -n "$BASE_REF" ]; then
  BASE_SOURCE=explicit
  BASE_LABEL=$BASE_REF
  BASE_SHA=$(git -C "$WORKTREE" rev-parse --verify "$BASE_REF^{commit}" 2>/dev/null || true)
  if [ -z "$BASE_SHA" ]; then
    emit_finding base_currency base-unresolved fail "explicit --base ref cannot be resolved in candidate repo: $BASE_REF"
    base_status=fail
  fi
elif [ -n "$PROJECT" ]; then
  BASE_SOURCE=trunk-check
  TRUNK_JSON="$WORK/trunk.json"
  "$FM_ROOT/bin/fm-trunk-check.sh" "$PROJECT" --json > "$TRUNK_JSON" 2>"$WORK/trunk.err"
  TRUNK_RC=$?
  if ! jq -e . "$TRUNK_JSON" >/dev/null 2>&1; then
    emit_finding base_currency trunk-check-error fail "fm-trunk-check produced no readable report for project $PROJECT (rc=$TRUNK_RC)"
    base_status=fail
  else
    proj_status=$(jq -r --arg p "$PROJECT" '.projects[]|select(.project==$p)|(.status // "ok")' "$TRUNK_JSON" 2>/dev/null | head -1)
    declared=$(jq -r --arg p "$PROJECT" '.projects[]|select(.project==$p)|(.declared // false)' "$TRUNK_JSON" 2>/dev/null | head -1)
    overall=$(jq -r '.status // "ok"' "$TRUNK_JSON" 2>/dev/null)
    if [ "$proj_status" = error ] || [ "$declared" != true ] || [ "$overall" = error ]; then
      emit_finding base_currency trunk-declaration-error fail "canonical-trunk declaration is missing or in error for project $PROJECT (fail closed)"
      base_status=fail
    elif [ "$overall" = drift ]; then
      emit_finding base_currency trunk-drift fail "canonical trunk for $PROJECT is drifted; the base cannot be trusted"
      base_status=fail
    else
      BASE_SHA=$(jq -r --arg p "$PROJECT" '.projects[]|select(.project==$p)|.trunk.sha // ""' "$TRUNK_JSON" 2>/dev/null | head -1)
      BASE_LABEL=$(jq -r --arg p "$PROJECT" '.projects[]|select(.project==$p)|.trunk.branch // ""' "$TRUNK_JSON" 2>/dev/null | head -1)
      if [ -z "$BASE_SHA" ]; then
        emit_finding base_currency trunk-sha-unresolved fail "canonical trunk SHA for $PROJECT could not be read from fm-trunk-check"
        base_status=fail
      fi
    fi
  fi
else
  if BASE_LABEL=$(resolve_local_default); then
    BASE_SOURCE=local-default
    BASE_SHA=$(git -C "$WORKTREE" rev-parse --verify "refs/heads/$BASE_LABEL^{commit}" 2>/dev/null || true)
    emit_finding base_currency trunk-not-consulted note "canonical trunk not consulted (no --project/--base); measured currency against local default branch $BASE_LABEL"
  else
    emit_finding base_currency base-undeterminable fail "no base ref could be determined (no --base, no --project, no local default branch)"
    base_status=fail
    BASE_SOURCE=none
  fi
fi

# ============================================================================
# PRE-execution snapshot (FC-005 baseline)
# ============================================================================
SHA0=$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || true)
BRANCH0=$(git -C "$WORKTREE" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
DIRTY0=no; [ -n "$(git -C "$WORKTREE" status --porcelain 2>/dev/null || true)" ] && DIRTY0=yes
BASE0=$(base_tip_now)

# ============================================================================
# GATE: tests - EVERY discovered suite executed under a hard deadline
# ============================================================================
tests_status=pass
TOTAL_OK=0
TOTAL_NOTOK=0
TOTAL_SKIP=0
SUITE_JSONL="$WORK/suites.jsonl"
DETECTED_FILE="$WORK/detected.txt"
EXECUTED_FILE="$WORK/executed.txt"
: > "$SUITE_JSONL"; : > "$DETECTED_FILE"; : > "$EXECUTED_FILE"

TIMEOUT_BIN=""
for t in timeout gtimeout; do command -v "$t" >/dev/null 2>&1 && { TIMEOUT_BIN=$t; break; }; done

# run_bounded <budget> <outfile> <cmd...>: run cmd in the worktree under a hard
# deadline (FC-006). Sets BOUNDED_TIMEOUT=yes and returns 124 on deadline. Falls
# back to a PID-watchdog that kills ONLY the exact child PID when no
# timeout/gtimeout is available, so a missing tool cannot defeat the deadline.
BOUNDED_TIMEOUT=no
run_bounded() {
  local budget=$1 outfile=$2; shift 2
  BOUNDED_TIMEOUT=no
  if [ -n "$TIMEOUT_BIN" ] && [ "${FM_VERIFY_FORCE_PID_WATCHDOG:-}" != 1 ]; then
    ( cd "$WORKTREE" && exec "$TIMEOUT_BIN" -k 5 "$budget" "$@" ) > "$outfile" 2>&1
    local rc=$?
    [ "$rc" -eq 124 ] && BOUNDED_TIMEOUT=yes
    return "$rc"
  fi
  local flag="$WORK/timedout.$RANDOM"
  rm -f "$flag"
  ( cd "$WORKTREE" && exec "$@" ) > "$outfile" 2>&1 &
  local child=$!
  ( sleep "$budget"; touch "$flag"; kill -TERM "$child" 2>/dev/null; sleep 5; kill -KILL "$child" 2>/dev/null ) &
  local watcher=$!
  wait "$child" 2>/dev/null; local rc=$?
  kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
  if [ -f "$flag" ]; then BOUNDED_TIMEOUT=yes; rc=124; fi
  rm -f "$flag"
  return "$rc"
}

# run_one <label> <interp> <cmd...>
run_one() {
  local label=$1 interp=$2; shift 2
  printf '%s\n' "$label" >> "$DETECTED_FILE"
  if [ -n "$interp" ] && ! command -v "$interp" >/dev/null 2>&1; then
    refuse "test runner '$interp' for suite '$label' is not installed (fail closed, FC-004)"
  fi
  local tout="$WORK/transcript.$RANDOM.txt" rc ok notok skip timedout=no
  run_bounded "$TEST_TIMEOUT" "$tout" "$@"
  rc=$?
  [ "$BOUNDED_TIMEOUT" = yes ] && timedout=yes
  ok=$(grep -cE '^ok([[:space:]]|$)' "$tout" 2>/dev/null || true)
  notok=$(grep -cE '^not ok([[:space:]]|$)' "$tout" 2>/dev/null || true)
  skip=$(grep -cE '(^[[:space:]]*skip:)|(^[[:space:]]*SKIP([[:space:]]|$))|(#[[:space:]]*(skip|SKIP))' "$tout" 2>/dev/null || true)
  ok=${ok:-0}; notok=${notok:-0}; skip=${skip:-0}
  TOTAL_OK=$((TOTAL_OK + ok)); TOTAL_NOTOK=$((TOTAL_NOTOK + notok)); TOTAL_SKIP=$((TOTAL_SKIP + skip))
  printf '%s\n' "$label" >> "$EXECUTED_FILE"
  jq -nc --arg label "$label" --arg rc "$rc" --arg ok "$ok" --arg notok "$notok" \
    --arg skip "$skip" --arg timedout "$timedout" \
    --rawfile tail <(tail -c 4000 "$tout") \
    '{suite:$label,exit:($rc|tonumber),timed_out:($timedout=="yes"),
      ok:($ok|tonumber),not_ok:($notok|tonumber),skip:($skip|tonumber),
      transcript_tail:$tail}' >> "$SUITE_JSONL"
  if [ "$timedout" = yes ]; then
    emit_finding tests suite-timeout fail "test suite '$label' exceeded the ${TEST_TIMEOUT}s hard deadline and was killed; an unbounded wait is a finding, never a pass (FC-006)"
    tests_status=fail
  elif [ "$rc" -ne 0 ]; then
    emit_finding tests suite-failed fail "test suite '$label' exited $rc"
    tests_status=fail
  fi
  if [ "$notok" -gt 0 ]; then
    emit_finding tests assertions-failed fail "test suite '$label' reported $notok failing assertion(s)"
    tests_status=fail
  fi
  if [ "$skip" -gt 0 ]; then
    emit_finding tests skipped fail "test suite '$label' SKIPPED $skip check(s); a SKIP is a finding, never a pass"
    tests_status=fail
  fi
  if [ "$timedout" = no ] && [ "$rc" -eq 0 ] && [ "$ok" -eq 0 ] && [ "$notok" -eq 0 ]; then
    emit_finding tests no-assertions fail "test suite '$label' produced no PASS/FAIL assertions; execution proved nothing"
    tests_status=fail
  fi
  rm -f "$tout"
}

# Suite discovery is a CLOSED set, not a first-match ladder (FC-002): an explicit
# --tests-cmd is the closed manifest; otherwise EVERY supported suite present is
# executed, so an available failing suite can never be silently omitted.
RUNNERS=()
if [ "$TESTS_CMD_SET" = yes ]; then
  RUNNERS+=(explicit)
  # shellcheck disable=SC2086
  run_one "explicit" "$(set -- $TESTS_CMD; echo "$1")" bash -c "$TESTS_CMD"
else
  if compgen -G "$WORKTREE/tests/*.test.sh" >/dev/null 2>&1; then
    RUNNERS+=(shell-tests)
    for t in "$WORKTREE"/tests/*.test.sh; do
      run_one "shell:$(basename "$t")" bash bash "$t"
    done
  fi
  if [ -f "$WORKTREE/package.json" ] && jq -e '.scripts.test' "$WORKTREE/package.json" >/dev/null 2>&1; then
    RUNNERS+=(npm)
    run_one "npm test" npm npm test --silent
  fi
  if [ -f "$WORKTREE/Makefile" ] && grep -qE '^test:' "$WORKTREE/Makefile" 2>/dev/null; then
    RUNNERS+=(make)
    run_one "make test" make make test
  fi
fi

DETECTED_N=$(grep -c . "$DETECTED_FILE" 2>/dev/null || true); DETECTED_N=${DETECTED_N:-0}
EXECUTED_N=$(grep -c . "$EXECUTED_FILE" 2>/dev/null || true); EXECUTED_N=${EXECUTED_N:-0}
if [ "$DETECTED_N" -eq 0 ]; then
  emit_finding tests no-tests fail "no test suite was discovered or executed; nothing was proven (never a pass)"
  tests_status=fail
fi
# Completeness is machine-checkable: every detected suite has an execution record.
if [ "$DETECTED_N" -ne "$EXECUTED_N" ]; then
  emit_finding tests incomplete-execution fail "detected $DETECTED_N suite(s) but executed $EXECUTED_N; a discovered suite was not run (FC-002)"
  tests_status=fail
fi
RUNNERS_JSON=$(printf '%s\n' "${RUNNERS[@]:-}" | jq -Rn '[inputs|select(length>0)]')
emit_gate tests "$tests_status" "$(jq -nc \
  --argjson runners "$RUNNERS_JSON" \
  --arg detected "$DETECTED_N" --arg executed "$EXECUTED_N" \
  --arg ok "$TOTAL_OK" --arg notok "$TOTAL_NOTOK" --arg skip "$TOTAL_SKIP" \
  --arg budget "$TEST_TIMEOUT" \
  --slurpfile suites "$SUITE_JSONL" \
  '{runners:$runners,executed:($detected|tonumber>0),
    suites_detected:($detected|tonumber),suites_executed:($executed|tonumber),
    per_suite_timeout_s:($budget|tonumber),
    totals:{ok:($ok|tonumber),not_ok:($notok|tonumber),skip:($skip|tonumber)},
    suites:$suites}')"

# ============================================================================
# POST-execution snapshot + FC-005 revalidation
# ============================================================================
SHA1=$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || true)
BRANCH1=$(git -C "$WORKTREE" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
DIRTY1=no; [ -n "$(git -C "$WORKTREE" status --porcelain 2>/dev/null || true)" ] && DIRTY1=yes
BASE1=$(base_tip_now)

# Every attestation below is computed from the SINGLE post-execution snapshot, so
# the published claims describe the tree AS IT IS at publish time, not a stale
# pre-test observation. Revalidation proves that snapshot did not move during
# execution; any drift fails the run (the proof is atomic with the attestation).
revalidation_status=pass
drift=""
[ "$SHA0" = "$SHA1" ] || drift="$drift HEAD($SHA0->$SHA1)"
[ "$BRANCH0" = "$BRANCH1" ] || drift="$drift branch($BRANCH0->$BRANCH1)"
[ "$DIRTY0" = "$DIRTY1" ] || drift="$drift dirty($DIRTY0->$DIRTY1)"
[ "$BASE0" = "$BASE1" ] || drift="$drift base($BASE0->$BASE1)"
if [ -n "$drift" ]; then
  emit_finding revalidation identity-drift fail "git state changed during verification (FC-005: proof not atomic with attestation):$drift"
  revalidation_status=fail
fi
emit_gate revalidation "$revalidation_status" "$(jq -nc \
  --arg s0 "$SHA0" --arg s1 "$SHA1" --arg b0 "$BRANCH0" --arg b1 "$BRANCH1" \
  --arg d0 "$DIRTY0" --arg d1 "$DIRTY1" --arg bs0 "$BASE0" --arg bs1 "$BASE1" \
  '{before:{head_sha:$s0,branch:$b0,tree_dirty:($d0=="yes"),base_sha:(if $bs0=="" then null else $bs0 end)},
    after:{head_sha:$s1,branch:$b1,tree_dirty:($d1=="yes"),base_sha:(if $bs1=="" then null else $bs1 end)}}')"

# Authoritative post-execution values used by every remaining attestation gate.
ACTUAL_SHA=$SHA1
ACTUAL_BRANCH=$BRANCH1
DIRTY=$DIRTY1

# ============================================================================
# GATE: identity - the post-execution snapshot matches the declared binding
# ============================================================================
identity_status=pass
if [ -z "$ACTUAL_SHA" ]; then
  emit_finding identity no-head fail "candidate worktree has no HEAD commit"
  identity_status=fail
fi
if [ "$EXPECT_SHA" != "$ACTUAL_SHA" ]; then
  emit_finding identity sha-mismatch fail "declared SHA $EXPECT_SHA does not match candidate HEAD $ACTUAL_SHA"
  identity_status=fail
fi
if [ "$ACTUAL_BRANCH" = "HEAD" ]; then
  emit_finding identity detached-head fail "candidate is in detached HEAD, not on the declared branch"
  identity_status=fail
elif [ "$EXPECT_BRANCH" != "$ACTUAL_BRANCH" ]; then
  emit_finding identity branch-mismatch fail "declared branch $EXPECT_BRANCH does not match candidate branch $ACTUAL_BRANCH"
  identity_status=fail
fi
if [ "$DIRTY" = yes ]; then
  emit_finding identity tree-dirty fail "candidate worktree has uncommitted changes at publish time"
  identity_status=fail
fi
emit_gate identity "$identity_status" "$(jq -nc \
  --arg sha "$ACTUAL_SHA" --arg branch "$ACTUAL_BRANCH" \
  --arg esha "$EXPECT_SHA" --arg ebranch "$EXPECT_BRANCH" --arg dirty "$DIRTY" \
  '{head_sha:$sha,branch:$branch,expected_sha:$esha,expected_branch:$ebranch,
    tree_dirty:($dirty=="yes")}')"

# ============================================================================
# GATE: base_currency - the candidate contains the current base tip
# ============================================================================
BASE_RELATION=unknown
if [ -n "$BASE_SHA" ] && [ -n "$ACTUAL_SHA" ]; then
  if ! git -C "$WORKTREE" cat-file -e "$BASE_SHA^{commit}" 2>/dev/null; then
    emit_finding base_currency base-absent fail "base commit $BASE_SHA is not present in the candidate repo; base currency cannot be proven"
    base_status=fail
  elif git -C "$WORKTREE" merge-base --is-ancestor "$BASE_SHA" "$ACTUAL_SHA" 2>/dev/null; then
    BASE_RELATION=current
  else
    BASE_RELATION=behind
    emit_finding base_currency base-stale fail "candidate does not contain the current base ($BASE_LABEL $BASE_SHA); rebase before QA so the eventual merge stays a fast-forward"
    base_status=fail
  fi
fi
emit_gate base_currency "$base_status" "$(jq -nc \
  --arg src "$BASE_SOURCE" --arg label "$BASE_LABEL" --arg sha "$BASE_SHA" --arg rel "$BASE_RELATION" \
  '{source:$src,base_branch:(if $label=="" then null else $label end),
    base_sha:(if $sha=="" then null else $sha end),relation:$rel}')"

# ============================================================================
# Candidate diff (post-execution HEAD vs base); shared by cue_lint + brief
# ============================================================================
DIFF_FILE="$WORK/candidate.diff"
ADDED_FILE="$WORK/added.tsv"
: > "$DIFF_FILE"; : > "$ADDED_FILE"
DIFF_BASE=""
if [ -n "$BASE_SHA" ] && git -C "$WORKTREE" cat-file -e "$BASE_SHA^{commit}" 2>/dev/null; then
  DIFF_BASE=$BASE_SHA
fi
if [ -n "$DIFF_BASE" ] && [ -n "$ACTUAL_SHA" ]; then
  git -C "$WORKTREE" diff "$DIFF_BASE...$ACTUAL_SHA" > "$DIFF_FILE" 2>/dev/null || true
fi
awk '
  /^\+\+\+ /   { f=$2; sub(/^b\//,"",f); next }
  /^--- /      { next }
  /^@@ /       { if (match($0, /\+[0-9]+/)) { ln=substr($0,RSTART+1,RLENGTH-1)+0 } ; next }
  /^\+/        { print f "\t" ln "\t" substr($0,2); ln++; next }
  /^-/         { next }
  /^ /         { ln++; next }
  { next }
' "$DIFF_FILE" > "$ADDED_FILE"

# ============================================================================
# GATE: cue_lint - detection cues SOURCED FROM THE LEDGER, applied to the diff
# ============================================================================
# The ledger owns which cues are executable: each class MAY carry a
# machine-readable `detection` array of {engine:"awk-ere", pattern, cue_ref}.
# When present, those patterns drive the lint, so changing the ledger changes what
# is enforced. The built-in table below is a LABELLED FALLBACK for the three
# historically grep-shaped classes, used only for a class the ledger gives no
# detection for; classes with neither are reported advisory-only, never silently
# clean. (Adding `detection` to the production ledger is the captain-gated
# Stage-E step; the verifier already consumes it.)
builtin_detection() {
  # <id> -> awk-ERE pattern; a literal pipe is [|] (awk reads \| as alternation).
  case "$1" in
    FC-004) printf '%s' 'command -v .*[|][|][[:space:]]*(true|:|return 0|continue)([[:space:]#]|$)' ;;
    FC-006) printf '%s' '(curl|wget|nc|ssh|wait|sleep)([[:space:]][^|]*)?[|][|][[:space:]]*true([[:space:]#]|$)' ;;
    FC-007) printf '%s' 'rm[[:space:]].*2>/dev/null.*[|][|][[:space:]]*true' ;;
    *) return 1 ;;
  esac
}

cue_status=pass
LEDGER_OK=no
if [ -f "$LEDGER" ] && grep -q '"event":"class-defined"' "$LEDGER" 2>/dev/null; then
  LEDGER_OK=yes
fi
if [ "$LEDGER_OK" != yes ]; then
  emit_finding cue_lint ledger-unreadable fail "failure-class ledger is missing or unreadable: $LEDGER (fail closed)"
  cue_status=fail
fi

# Build the effective detection set (id<TAB>engine<TAB>pattern<TAB>cue_ref<TAB>source).
EFFECTIVE="$WORK/detections.tsv"
LINTED_FILE="$WORK/linted.txt"
ADVISORY_FILE="$WORK/advisory.txt"
: > "$EFFECTIVE"; : > "$LINTED_FILE"; : > "$ADVISORY_FILE"
if [ "$LEDGER_OK" = yes ]; then
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    got=no
    while IFS=$'\t' read -r engine pattern cueref; do
      [ -n "$pattern" ] || continue
      if [ "$engine" != "awk-ere" ]; then continue; fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$cid" "$engine" "$pattern" "$cueref" ledger >> "$EFFECTIVE"
      got=yes
    done < <(jq -r --arg id "$cid" '
      select(.event=="class-defined" and .id==$id) | (.detection // [])[]
      | [ (.engine // "awk-ere"), (.pattern // ""), (.cue_ref // "") ] | @tsv' "$LEDGER" 2>/dev/null)
    if [ "$got" = no ]; then
      if bp=$(builtin_detection "$cid"); then
        printf '%s\t%s\t%s\t%s\t%s\n' "$cid" awk-ere "$bp" "built-in fallback detection" builtin >> "$EFFECTIVE"
        got=yes
      fi
    fi
    if [ "$got" = yes ]; then printf '%s\n' "$cid" >> "$LINTED_FILE"; else printf '%s\n' "$cid" >> "$ADVISORY_FILE"; fi
  done < <(jq -r 'select(.event=="class-defined")|.id' "$LEDGER" 2>/dev/null)
fi

CUE_HITS=0
if [ "$LEDGER_OK" = yes ] && [ -s "$ADDED_FILE" ] && [ -s "$EFFECTIVE" ]; then
  while IFS=$'\t' read -r cid engine pattern cueref source; do
    [ -n "$cid" ] || continue
    class_name=$(jq -r --arg id "$cid" 'select(.event=="class-defined" and .id==$id)|.name' "$LEDGER" 2>/dev/null | head -1)
    while IFS=$'\t' read -r hfile hline _; do
      emit_finding cue_lint "$cid" finding \
        "$cid ($class_name) [$source]: ${cueref:-detection cue}" "$hfile" "$hline"
      CUE_HITS=$((CUE_HITS + 1))
    done < <(awk -F'\t' -v ere="$pattern" '$3 ~ ere { print }' "$ADDED_FILE")
  done < "$EFFECTIVE"
  [ "$CUE_HITS" -gt 0 ] && cue_status=fail
fi

LINTED_ARR=$(jq -Rn '[inputs|select(length>0)]|unique' "$LINTED_FILE" 2>/dev/null || echo '[]')
ADVISORY_ARR=$(jq -Rn '[inputs|select(length>0)]|unique' "$ADVISORY_FILE" 2>/dev/null || echo '[]')
SOURCES_ARR=$(jq -Rn '[inputs|select(length>0)|split("\t")|{fc:.[0],source:.[4],cue_ref:.[3]}]' "$EFFECTIVE" 2>/dev/null || echo '[]')
emit_gate cue_lint "$cue_status" "$(jq -nc \
  --arg hits "$CUE_HITS" --arg diffbase "$DIFF_BASE" \
  --argjson linted "$LINTED_ARR" --argjson advisory "$ADVISORY_ARR" --argjson detections "$SOURCES_ARR" \
  '{hits:($hits|tonumber),diff_base:(if $diffbase=="" then null else $diffbase end),
    mechanically_linted:$linted,advisory_only:$advisory,detections:$detections}')"

# ============================================================================
# GATE: brief_contract - echo the mandatory brief + mechanical checks
# ============================================================================
brief_status=pass
CONTRACT_FILE="$WORK/contract.txt"
: > "$CONTRACT_FILE"
awk '
  /^# (Rules|Definition of done|Setup)/ { grab=1; print; next }
  /^# / && grab { grab=0 }
  grab { print }
' "$BRIEF" | sed '/^[[:space:]]*$/d' > "$CONTRACT_FILE"

COMMITS=0
if [ -n "$DIFF_BASE" ] && [ -n "$ACTUAL_SHA" ]; then
  COMMITS=$(git -C "$WORKTREE" rev-list --count "$DIFF_BASE..$ACTUAL_SHA" 2>/dev/null || echo 0)
fi
COMMITS=${COMMITS:-0}
if [ "$COMMITS" -eq 0 ]; then
  emit_finding brief_contract no-commits fail "no commits on the candidate over its base; the contract requires committed work"
  brief_status=fail
fi
BRANCH_OK=yes
if [ "$ACTUAL_BRANCH" != "fm/$TASK" ]; then
  BRANCH_OK=no
  emit_finding brief_contract branch-name fail "candidate branch is '$ACTUAL_BRANCH'; the contract expected 'fm/$TASK'"
  brief_status=fail
fi
emit_gate brief_contract "$brief_status" "$(jq -nc \
  --arg present true --arg commits "$COMMITS" --arg branchok "$BRANCH_OK" \
  --arg clean "$([ "$DIRTY" = no ] && echo true || echo false)" \
  --rawfile echo "$CONTRACT_FILE" \
  '{brief_present:($present=="true"),commits_on_branch:($commits|tonumber),
    branch_matches_task:$branchok,tree_clean:($clean=="true"),contract_echo:$echo}')"

# ============================================================================
# Assemble the bundle and verdict
# ============================================================================
VERDICT=pass
EXIT=0
if grep -q '"status":"fail"' "$GATES" 2>/dev/null; then VERDICT=fail; fi
if [ "$(jq -s '[.[]|select(.severity!="note")]|length' "$FINDINGS" 2>/dev/null)" -gt 0 ]; then VERDICT=fail; fi
[ "$VERDICT" = fail ] && EXIT=1

STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
BUNDLE="$WORK/bundle.json"
jq -n \
  --arg schema "firstmate/verify-bundle/1" \
  --arg verdict "$VERDICT" \
  --arg task "$TASK" \
  --arg worktree "$WORKTREE" \
  --arg sha "$ACTUAL_SHA" \
  --arg branch "$ACTUAL_BRANCH" \
  --arg esha "$EXPECT_SHA" \
  --arg ebranch "$EXPECT_BRANCH" \
  --arg stamp "$STAMP" \
  --arg findings_n "$FINDING_COUNT" \
  --slurpfile gates "$GATES" \
  --slurpfile findings "$FINDINGS" \
  '{schema:$schema,verdict:$verdict,task:$task,
    candidate:{worktree:$worktree,head_sha:$sha,branch:$branch,
               declared_sha:$esha,declared_branch:$ebranch},
    generated_at:(if $stamp=="" then null else $stamp end),
    finding_count:($findings_n|tonumber),
    gates:$gates,findings:$findings}' > "$BUNDLE" || refuse "failed to assemble bundle JSON"

# Atomic publish: replace the invalidation marker with the final result.
TMP_OUT="$OUT.tmp.$$"
cp "$BUNDLE" "$TMP_OUT" || refuse "cannot stage bundle at $TMP_OUT"
mv -f "$TMP_OUT" "$OUT" || { rm -f "$TMP_OUT"; refuse "cannot publish bundle to $OUT"; }

# --- human summary ----------------------------------------------------------
SUMMARY="$WORK/summary.md"
{
  printf '# Gauntlet verify - %s\n\n' "$VERDICT"
  printf -- '- candidate: %s @ %s (%s)\n' "$ACTUAL_BRANCH" "${ACTUAL_SHA:0:12}" "$WORKTREE"
  printf -- '- task: %s\n' "$TASK"
  printf -- '- bundle: %s\n' "$OUT"
  printf '\n## Gates\n'
  jq -r '.gate + ": " + (.status|ascii_upcase)' "$GATES"
  printf '\n## Findings (%s)\n' "$FINDING_COUNT"
  if [ "$FINDING_COUNT" -eq 0 ]; then
    printf 'none\n'
  else
    jq -r '"- [" + .severity + "] " + .gate + " / " + .code + ": " + .message
           + (if .file then " (" + .file + (if .line then ":" + (.line|tostring) else "" end) + ")" else "" end)' "$FINDINGS"
  fi
} > "$SUMMARY"
cp "$SUMMARY" "$OUT_DIR/verify-summary.md" 2>/dev/null || true

if [ "$FORMAT" = json ]; then
  cat "$OUT"
else
  cat "$SUMMARY"
fi

exit "$EXIT"

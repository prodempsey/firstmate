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
# A verifier must itself obey the failure-class ledger it lints with. The
# invariants that shape this script (each proven by an adversarial fixture):
#   FC-002  completeness is positive per-item proof; absence from a partial
#           discovery is NOT discharge. Suites are enumerated INDEPENDENTLY of
#           execution from authoritative structures (a filesystem glob, Make's
#           own parsed target database, package.json), recorded as a declared
#           manifest, and matched one-to-one to execution records.
#   FC-004  a missing prerequisite tool is a refusal, never a skipped check.
#   FC-005  the proof must be ATOMIC with the attestation. Tests NEVER run in the
#           authority-bearing worktree: they run in a disposable checkout of the
#           exact HEAD tree, so no test - synchronous or a delayed background
#           child - can dirty the tree whose cleanliness the bundle attests. The
#           authoritative worktree is only ever read.
#   FC-006  every suite runs under a PORTABLE hard deadline (timeout/gtimeout,
#           else a PID-watchdog killing only the exact child) a missing tool
#           cannot defeat; a wedged suite is a finding, never a hang.
#   FC-007  the authoritative outputs (bundle JSON and its summary sibling) are
#           INVALIDATED before any refusable check or tool-dependent work runs, so
#           NO refusal (unknown option, bad format, missing tool/binding) can
#           leave a stale passing artifact to be read as fresh.
#
# THE GATES (each recorded in the bundle with pass/fail and findings)
#   identity        HEAD SHA + branch bound to the DECLARED candidate (mandatory
#                   --sha/--branch); tree clean
#   base_currency   the candidate contains the current canonical trunk tip
#                   (bin/fm-trunk-check.sh integration when --project is given)
#   tests           EVERY independently-enumerated suite ACTUALLY EXECUTED in an
#                   isolated checkout under a hard deadline; PASS/FAIL/SKIP/TIMEOUT
#                   parsed; SKIP, timeout, no-tests, and any declared!=executed
#                   mismatch are findings, never passes
#   cue_lint        failure-class detection cues read LIVE from the ledger's
#                   machine-readable `detection` field (docs/failure-classes/
#                   ledger.jsonl) - no hardcoded patterns - grepped against the diff
#   brief_contract  the dispatch contract echoed from the mandatory brief plus the
#                   mechanically-checkable items (committed work, branch)
#   revalidation    the authority-bearing worktree did not change during
#                   verification (defence in depth atop isolated execution)
#
# EXIT
#   0  clean pass: every gate passed with zero findings
#   1  findings: at least one gate failed or produced a finding
#   2  refuse: a prerequisite tool is missing, a mandatory binding is absent or
#      unreadable, or an input could not be read (fail closed; the outputs are left
#      carrying a non-authoritative "invalidated" marker, never a stale pass)
#
# Usage:
#   fm-verify.sh --worktree <path> --sha <sha> --branch <name> --task <id> [options]
#     --worktree <path>   REQUIRED. The candidate worktree to verify.
#     --sha <sha>         REQUIRED. The declared HEAD sha the candidate must be at.
#     --branch <name>     REQUIRED. The declared branch the candidate must be on.
#     --task <id>         REQUIRED. Task id: locates the brief and default --out.
#     --base <ref>        Explicit base ref for currency + diff (skips trunk-check).
#     --project <name>    Resolve the canonical trunk via bin/fm-trunk-check.sh.
#     --tests-cmd <cmd>   Explicit closed test command run in the isolated checkout.
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

# refuse() aborts with exit 2. Once the outputs are known they have already been
# overwritten with the invalidation marker (FC-007), never a stale pass.
refuse() { echo "fm-verify: $1" >&2; exit 2; }

# ============================================================================
# FC-007: resolve and INVALIDATE the outputs before any refusable/tool-dependent
# work. A side-effect-free lenient scan finds --out/--task without validating
# anything, so an unknown option or a bad --format below cannot preserve a stale
# pass. Both the JSON bundle AND its advertised summary sibling are invalidated.
# ============================================================================
scan_output_target() {
  local out="" task=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) out=${2:-}; if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
      --task) task=${2:-}; if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
      *) shift ;;
    esac
  done
  if [ -n "$out" ]; then printf '%s\n' "$out"
  elif [ -n "$task" ]; then printf '%s\n' "$DATA/$task/verify-bundle.json"; fi
}
OUT=$(scan_output_target "$@")
OUT_DIR=""
SUMMARY_OUT=""
if [ -n "$OUT" ]; then
  OUT_DIR=$(dirname "$OUT")
  SUMMARY_OUT="$OUT_DIR/verify-summary.md"
  mkdir -p "$OUT_DIR" || refuse "cannot create output dir: $OUT_DIR (stale output NOT invalidated)"
  tmp="$OUT.invalidating.$$"
  printf '%s\n' '{"schema":"firstmate/verify-bundle/1","verdict":"invalidated","reason":"verification started or refused; no authoritative result at this path","gates":[],"findings":[]}' > "$tmp" \
    || refuse "cannot stage bundle invalidation marker"
  mv -f "$tmp" "$OUT" || { rm -f "$tmp"; refuse "cannot invalidate stale bundle at $OUT"; }
  stmp="$SUMMARY_OUT.invalidating.$$"
  printf '%s\n' '# Gauntlet verify - invalidated' '' 'Verification started or refused; there is no authoritative result at this path.' > "$stmp" \
    || refuse "cannot stage summary invalidation marker"
  mv -f "$stmp" "$SUMMARY_OUT" || { rm -f "$stmp"; refuse "cannot invalidate stale summary at $SUMMARY_OUT"; }
fi

# ============================================================================
# Strict parse (may refuse; the outputs above are already invalidated)
# ============================================================================
WORKTREE=""
EXPECT_SHA=""
EXPECT_BRANCH=""
BASE_REF=""
PROJECT=""
TESTS_CMD=""
TESTS_CMD_SET=no
BRIEF=""
TASK=""
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
    --out) shift ;;
    --format) FORMAT=${2:-}; shift ;;
    -*) refuse "unknown option $1" ;;
    *) refuse "unexpected argument $1" ;;
  esac
  shift
done

case "$FORMAT" in json|text) ;; *) refuse "--format must be json or text" ;; esac
[ -n "$OUT" ] || refuse "--out or --task is required to place (and invalidate) the bundle"

# --- prerequisites (FC-004: a missing tool is a refusal, not a skipped check) --
for tool in git jq awk grep sed; do
  command -v "$tool" >/dev/null 2>&1 || refuse "missing prerequisite tool: $tool (fail closed, FC-004)"
done

# --- mandatory bindings (identity is proven, never merely observed) -----------
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

# --- scratch + guaranteed teardown of the disposable checkout -----------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-verify.XXXXXX") || refuse "cannot create scratch dir"
SANDBOX=""
# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() {
  if [ -n "$SANDBOX" ]; then
    git -C "$WORKTREE" worktree remove --force "$SANDBOX" >/dev/null 2>&1 || true
    git -C "$WORKTREE" worktree prune >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

GATES="$WORK/gates.jsonl"
FINDINGS="$WORK/findings.jsonl"
: > "$GATES"
: > "$FINDINGS"

FINDING_COUNT=0
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
# PRE-execution snapshot of the AUTHORITATIVE worktree (revalidation baseline)
# ============================================================================
SHA0=$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || true)
BRANCH0=$(git -C "$WORKTREE" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
DIRTY0=no; [ -n "$(git -C "$WORKTREE" status --porcelain 2>/dev/null || true)" ] && DIRTY0=yes
BASE0=$(base_tip_now)

# ============================================================================
# FC-005: build a DISPOSABLE isolated checkout of the exact HEAD tree. All test
# execution happens here, never in the authority-bearing worktree, so no test
# (even a delayed background child) can dirty the tree the bundle attests.
# ============================================================================
EXEC_DIR=""
if [ -n "$SHA0" ]; then
  SANDBOX="$WORK/sandbox"
  if git -C "$WORKTREE" worktree add --detach --quiet "$SANDBOX" "$SHA0" 2>"$WORK/wt.err"; then
    EXEC_DIR="$SANDBOX"
  else
    SANDBOX=""
    emit_finding tests sandbox-failed fail "could not create an isolated test checkout at $SHA0: $(head -1 "$WORK/wt.err" 2>/dev/null)"
  fi
fi

# ============================================================================
# GATE: tests - independently enumerated, isolated, bounded execution
# ============================================================================
tests_status=pass
TOTAL_OK=0
TOTAL_NOTOK=0
TOTAL_SKIP=0
SUITE_JSONL="$WORK/suites.jsonl"
DECLARED_FILE="$WORK/declared.tsv"    # <label>\t<kind>\t<arg>  - built BEFORE execution
EXECUTED_FILE="$WORK/executed.txt"
: > "$SUITE_JSONL"; : > "$DECLARED_FILE"; : > "$EXECUTED_FILE"

# --- independent discovery (FC-002): enumerate from authoritative structures ---
if [ -n "$EXEC_DIR" ]; then
  if [ "$TESTS_CMD_SET" = yes ]; then
    printf 'explicit\texplicit\t\n' >> "$DECLARED_FILE"
  else
    if compgen -G "$EXEC_DIR/tests/*.test.sh" >/dev/null 2>&1; then
      for t in "$EXEC_DIR"/tests/*.test.sh; do
        printf 'shell:%s\tshell\t%s\n' "$(basename "$t")" "$t" >> "$DECLARED_FILE"
      done
    fi
    if [ -f "$EXEC_DIR/package.json" ] && jq -e '.scripts.test' "$EXEC_DIR/package.json" >/dev/null 2>&1; then
      printf 'npm test\tnpm\t\n' >> "$DECLARED_FILE"
    fi
    if [ -f "$EXEC_DIR/Makefile" ] || [ -f "$EXEC_DIR/makefile" ] || [ -f "$EXEC_DIR/GNUmakefile" ]; then
      # Query Make's OWN parsed target database, not a single source spelling, so
      # `test :`, `.PHONY: test`, and pattern rules are all seen. A Makefile with
      # no tool to parse it is ambiguous discovery => fail closed (FC-004/FC-002).
      if ! command -v make >/dev/null 2>&1; then
        refuse "a Makefile is present but make is unavailable to enumerate its targets (fail closed, FC-004)"
      fi
      if make -C "$EXEC_DIR" -pn 2>/dev/null | grep -qE '^test:'; then
        printf 'make test\tmake\t\n' >> "$DECLARED_FILE"
      fi
    fi
  fi
fi
DECLARED_N=$(grep -c . "$DECLARED_FILE" 2>/dev/null || true); DECLARED_N=${DECLARED_N:-0}

TIMEOUT_BIN=""
for tb in timeout gtimeout; do command -v "$tb" >/dev/null 2>&1 && { TIMEOUT_BIN=$tb; break; }; done

# run_bounded <budget> <outfile> <cmd...>: run cmd in EXEC_DIR under a hard
# deadline (FC-006). Sets BOUNDED_TIMEOUT=yes and returns 124 on deadline; the
# PID-watchdog fallback kills ONLY the exact child PID so a missing tool cannot
# defeat the deadline.
BOUNDED_TIMEOUT=no
run_bounded() {
  local budget=$1 outfile=$2; shift 2
  BOUNDED_TIMEOUT=no
  if [ -n "$TIMEOUT_BIN" ] && [ "${FM_VERIFY_FORCE_PID_WATCHDOG:-}" != 1 ]; then
    ( cd "$EXEC_DIR" && exec "$TIMEOUT_BIN" -k 5 "$budget" "$@" ) > "$outfile" 2>&1
    local rc=$?
    [ "$rc" -eq 124 ] && BOUNDED_TIMEOUT=yes
    return "$rc"
  fi
  local flag="$WORK/timedout.$RANDOM"
  rm -f "$flag"
  ( cd "$EXEC_DIR" && exec "$@" ) > "$outfile" 2>&1 &
  local child=$!
  ( sleep "$budget"; touch "$flag"; kill -TERM "$child" 2>/dev/null; sleep 5; kill -KILL "$child" 2>/dev/null ) &
  local watcher=$!
  wait "$child" 2>/dev/null; local rc=$?
  kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
  if [ -f "$flag" ]; then BOUNDED_TIMEOUT=yes; rc=124; fi
  rm -f "$flag"
  return "$rc"
}

# run_one <label> <interp> <cmd...>: execute one declared suite and record it.
run_one() {
  local label=$1 interp=$2; shift 2
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
  [ "$notok" -gt 0 ] && { emit_finding tests assertions-failed fail "test suite '$label' reported $notok failing assertion(s)"; tests_status=fail; }
  [ "$skip" -gt 0 ] && { emit_finding tests skipped fail "test suite '$label' SKIPPED $skip check(s); a SKIP is a finding, never a pass"; tests_status=fail; }
  if [ "$timedout" = no ] && [ "$rc" -eq 0 ] && [ "$ok" -eq 0 ] && [ "$notok" -eq 0 ]; then
    emit_finding tests no-assertions fail "test suite '$label' produced no PASS/FAIL assertions; execution proved nothing"
    tests_status=fail
  fi
  rm -f "$tout"
}

# The interpreter to probe for an explicit command is its first word.
EXPLICIT_INTERP=""
if [ "$TESTS_CMD_SET" = yes ]; then
  # shellcheck disable=SC2086  # intentional word-split: the first token is the interp
  set -- $TESTS_CMD
  EXPLICIT_INTERP=${1:-}
fi

# --- execute EVERY declared suite (the declared manifest drives execution) ----
while IFS=$'\t' read -r label kind arg; do
  [ -n "$label" ] || continue
  case "$kind" in
    explicit) run_one "$label" "$EXPLICIT_INTERP" bash -c "$TESTS_CMD" ;;
    shell) run_one "$label" bash bash "$arg" ;;
    npm) run_one "$label" npm npm test --silent ;;
    make) run_one "$label" make make test ;;
  esac
done < "$DECLARED_FILE"

EXECUTED_N=$(grep -c . "$EXECUTED_FILE" 2>/dev/null || true); EXECUTED_N=${EXECUTED_N:-0}
if [ "$DECLARED_N" -eq 0 ]; then
  emit_finding tests no-tests fail "no test suite was discovered or executed; nothing was proven (never a pass)"
  tests_status=fail
fi
# FC-002: completeness is machine-checkable - every declared suite has a record.
if [ "$DECLARED_N" -ne "$EXECUTED_N" ]; then
  emit_finding tests incomplete-execution fail "declared $DECLARED_N suite(s) but executed $EXECUTED_N; a discovered suite was not run (FC-002)"
  tests_status=fail
fi
DECLARED_ARR=$(cut -f1 "$DECLARED_FILE" | jq -Rn '[inputs|select(length>0)]')
emit_gate tests "$tests_status" "$(jq -nc \
  --argjson declared "$DECLARED_ARR" \
  --arg dn "$DECLARED_N" --arg en "$EXECUTED_N" \
  --arg ok "$TOTAL_OK" --arg notok "$TOTAL_NOTOK" --arg skip "$TOTAL_SKIP" \
  --arg budget "$TEST_TIMEOUT" --arg isolated "$([ -n "$EXEC_DIR" ] && echo true || echo false)" \
  --slurpfile suites "$SUITE_JSONL" \
  '{isolated_checkout:($isolated=="true"),
    declared_suites:$declared,suites_declared:($dn|tonumber),suites_executed:($en|tonumber),
    executed:($dn|tonumber>0),per_suite_timeout_s:($budget|tonumber),
    totals:{ok:($ok|tonumber),not_ok:($notok|tonumber),skip:($skip|tonumber)},
    suites:$suites}')"

# ============================================================================
# POST-execution snapshot of the AUTHORITATIVE worktree + revalidation (FC-005)
# ============================================================================
SHA1=$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || true)
BRANCH1=$(git -C "$WORKTREE" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
DIRTY1=no; [ -n "$(git -C "$WORKTREE" status --porcelain 2>/dev/null || true)" ] && DIRTY1=yes
BASE1=$(base_tip_now)

revalidation_status=pass
drift=""
[ "$SHA0" = "$SHA1" ] || drift="$drift HEAD($SHA0->$SHA1)"
[ "$BRANCH0" = "$BRANCH1" ] || drift="$drift branch($BRANCH0->$BRANCH1)"
[ "$DIRTY0" = "$DIRTY1" ] || drift="$drift dirty($DIRTY0->$DIRTY1)"
[ "$BASE0" = "$BASE1" ] || drift="$drift base($BASE0->$BASE1)"
if [ -n "$drift" ]; then
  emit_finding revalidation identity-drift fail "the authority-bearing worktree changed during verification (FC-005):$drift"
  revalidation_status=fail
fi
emit_gate revalidation "$revalidation_status" "$(jq -nc \
  --arg s0 "$SHA0" --arg s1 "$SHA1" --arg b0 "$BRANCH0" --arg b1 "$BRANCH1" \
  --arg d0 "$DIRTY0" --arg d1 "$DIRTY1" --arg bs0 "$BASE0" --arg bs1 "$BASE1" \
  '{before:{head_sha:$s0,branch:$b0,tree_dirty:($d0=="yes"),base_sha:(if $bs0=="" then null else $bs0 end)},
    after:{head_sha:$s1,branch:$b1,tree_dirty:($d1=="yes"),base_sha:(if $bs1=="" then null else $bs1 end)}}')"

ACTUAL_SHA=$SHA1
ACTUAL_BRANCH=$BRANCH1
DIRTY=$DIRTY1

# ============================================================================
# GATE: identity
# ============================================================================
identity_status=pass
if [ -z "$ACTUAL_SHA" ]; then
  emit_finding identity no-head fail "candidate worktree has no HEAD commit"; identity_status=fail
fi
if [ "$EXPECT_SHA" != "$ACTUAL_SHA" ]; then
  emit_finding identity sha-mismatch fail "declared SHA $EXPECT_SHA does not match candidate HEAD $ACTUAL_SHA"; identity_status=fail
fi
if [ "$ACTUAL_BRANCH" = "HEAD" ]; then
  emit_finding identity detached-head fail "candidate is in detached HEAD, not on the declared branch"; identity_status=fail
elif [ "$EXPECT_BRANCH" != "$ACTUAL_BRANCH" ]; then
  emit_finding identity branch-mismatch fail "declared branch $EXPECT_BRANCH does not match candidate branch $ACTUAL_BRANCH"; identity_status=fail
fi
if [ "$DIRTY" = yes ]; then
  emit_finding identity tree-dirty fail "candidate worktree has uncommitted changes at publish time"; identity_status=fail
fi
emit_gate identity "$identity_status" "$(jq -nc \
  --arg sha "$ACTUAL_SHA" --arg branch "$ACTUAL_BRANCH" \
  --arg esha "$EXPECT_SHA" --arg ebranch "$EXPECT_BRANCH" --arg dirty "$DIRTY" \
  '{head_sha:$sha,branch:$branch,expected_sha:$esha,expected_branch:$ebranch,tree_dirty:($dirty=="yes")}')"

# ============================================================================
# GATE: base_currency
# ============================================================================
BASE_RELATION=unknown
if [ -n "$BASE_SHA" ] && [ -n "$ACTUAL_SHA" ]; then
  if ! git -C "$WORKTREE" cat-file -e "$BASE_SHA^{commit}" 2>/dev/null; then
    emit_finding base_currency base-absent fail "base commit $BASE_SHA is not present in the candidate repo; base currency cannot be proven"; base_status=fail
  elif git -C "$WORKTREE" merge-base --is-ancestor "$BASE_SHA" "$ACTUAL_SHA" 2>/dev/null; then
    BASE_RELATION=current
  else
    BASE_RELATION=behind
    emit_finding base_currency base-stale fail "candidate does not contain the current base ($BASE_LABEL $BASE_SHA); rebase before QA so the eventual merge stays a fast-forward"; base_status=fail
  fi
fi
emit_gate base_currency "$base_status" "$(jq -nc \
  --arg src "$BASE_SOURCE" --arg label "$BASE_LABEL" --arg sha "$BASE_SHA" --arg rel "$BASE_RELATION" \
  '{source:$src,base_branch:(if $label=="" then null else $label end),
    base_sha:(if $sha=="" then null else $sha end),relation:$rel}')"

# ============================================================================
# Candidate diff (authoritative HEAD vs base); shared by cue_lint + brief
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
# GATE: cue_lint - detections read LIVE from the ledger; no hardcoded patterns
# ============================================================================
# The single authority for executable cues is docs/failure-classes/ledger.jsonl:
# each class-defined event MAY carry a machine-readable `detection` array of
# {engine:"awk-ere", pattern, cue_ref}. The verifier reads it live and lints from
# it. There is no built-in fallback table - a class the ledger gives no detection
# for is reported advisory-only, never silently enforced from a duplicate source.
cue_status=pass
LEDGER_OK=no
if [ -f "$LEDGER" ] && grep -q '"event":"class-defined"' "$LEDGER" 2>/dev/null; then
  LEDGER_OK=yes
fi
if [ "$LEDGER_OK" != yes ]; then
  emit_finding cue_lint ledger-unreadable fail "failure-class ledger is missing or unreadable: $LEDGER (fail closed)"
  cue_status=fail
fi

EFFECTIVE="$WORK/detections.tsv"   # <id>\t<pattern>\t<cue_ref>
LINTED_FILE="$WORK/linted.txt"
ADVISORY_FILE="$WORK/advisory.txt"
: > "$EFFECTIVE"; : > "$LINTED_FILE"; : > "$ADVISORY_FILE"
if [ "$LEDGER_OK" = yes ]; then
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    got=no
    while IFS=$'\t' read -r engine pattern cueref; do
      [ -n "$pattern" ] || continue
      [ "$engine" = "awk-ere" ] || continue
      printf '%s\t%s\t%s\n' "$cid" "$pattern" "$cueref" >> "$EFFECTIVE"
      got=yes
    done < <(jq -r --arg id "$cid" '
      select(.event=="class-defined" and .id==$id) | (.detection // [])[]
      | [ (.engine // "awk-ere"), (.pattern // ""), (.cue_ref // "") ] | @tsv' "$LEDGER" 2>/dev/null)
    if [ "$got" = yes ]; then printf '%s\n' "$cid" >> "$LINTED_FILE"; else printf '%s\n' "$cid" >> "$ADVISORY_FILE"; fi
  done < <(jq -r 'select(.event=="class-defined")|.id' "$LEDGER" 2>/dev/null)
fi

CUE_HITS=0
if [ "$LEDGER_OK" = yes ] && [ -s "$ADDED_FILE" ] && [ -s "$EFFECTIVE" ]; then
  while IFS=$'\t' read -r cid pattern cueref; do
    [ -n "$cid" ] || continue
    class_name=$(jq -r --arg id "$cid" 'select(.event=="class-defined" and .id==$id)|.name' "$LEDGER" 2>/dev/null | head -1)
    while IFS=$'\t' read -r hfile hline _; do
      emit_finding cue_lint "$cid" finding "$cid ($class_name): ${cueref:-detection cue}" "$hfile" "$hline"
      CUE_HITS=$((CUE_HITS + 1))
    done < <(awk -F'\t' -v ere="$pattern" '$3 ~ ere { print }' "$ADDED_FILE")
  done < "$EFFECTIVE"
  [ "$CUE_HITS" -gt 0 ] && cue_status=fail
fi

LINTED_ARR=$(jq -Rn '[inputs|select(length>0)]|unique' "$LINTED_FILE" 2>/dev/null || echo '[]')
ADVISORY_ARR=$(jq -Rn '[inputs|select(length>0)]|unique' "$ADVISORY_FILE" 2>/dev/null || echo '[]')
DETECT_ARR=$(jq -Rn '[inputs|select(length>0)|split("\t")|{fc:.[0],cue_ref:.[2],source:"ledger"}]' "$EFFECTIVE" 2>/dev/null || echo '[]')
emit_gate cue_lint "$cue_status" "$(jq -nc \
  --arg hits "$CUE_HITS" --arg diffbase "$DIFF_BASE" --arg ledger "$LEDGER" \
  --argjson linted "$LINTED_ARR" --argjson advisory "$ADVISORY_ARR" --argjson detections "$DETECT_ARR" \
  '{hits:($hits|tonumber),ledger:$ledger,diff_base:(if $diffbase=="" then null else $diffbase end),
    mechanically_linted:$linted,advisory_only:$advisory,detections:$detections}')"

# ============================================================================
# GATE: brief_contract
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
  emit_finding brief_contract no-commits fail "no commits on the candidate over its base; the contract requires committed work"; brief_status=fail
fi
BRANCH_OK=yes
if [ "$ACTUAL_BRANCH" != "fm/$TASK" ]; then
  BRANCH_OK=no
  emit_finding brief_contract branch-name fail "candidate branch is '$ACTUAL_BRANCH'; the contract expected 'fm/$TASK'"; brief_status=fail
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
  --arg schema "firstmate/verify-bundle/1" --arg verdict "$VERDICT" --arg task "$TASK" \
  --arg worktree "$WORKTREE" --arg sha "$ACTUAL_SHA" --arg branch "$ACTUAL_BRANCH" \
  --arg esha "$EXPECT_SHA" --arg ebranch "$EXPECT_BRANCH" \
  --arg stamp "$STAMP" --arg findings_n "$FINDING_COUNT" \
  --slurpfile gates "$GATES" --slurpfile findings "$FINDINGS" \
  '{schema:$schema,verdict:$verdict,task:$task,
    candidate:{worktree:$worktree,head_sha:$sha,branch:$branch,declared_sha:$esha,declared_branch:$ebranch},
    generated_at:(if $stamp=="" then null else $stamp end),
    finding_count:($findings_n|tonumber),gates:$gates,findings:$findings}' > "$BUNDLE" \
  || refuse "failed to assemble bundle JSON"

# Atomic publish: replace the invalidation marker with the final result.
TMP_OUT="$OUT.tmp.$$"
cp "$BUNDLE" "$TMP_OUT" || refuse "cannot stage bundle at $TMP_OUT"
mv -f "$TMP_OUT" "$OUT" || { rm -f "$TMP_OUT"; refuse "cannot publish bundle to $OUT"; }

# --- human summary (replaces the invalidated summary marker) ------------------
SUMMARY="$WORK/summary.md"
{
  printf '# Gauntlet verify - %s\n\n' "$VERDICT"
  printf -- '- candidate: %s @ %s (%s)\n' "$ACTUAL_BRANCH" "${ACTUAL_SHA:0:12}" "$WORKTREE"
  printf -- '- task: %s\n' "$TASK"
  printf -- '- bundle: %s\n' "$OUT"
  printf '\n## Gates\n'
  jq -r '.gate + ": " + (.status|ascii_upcase)' "$GATES"
  printf '\n## Findings (%s)\n' "$FINDING_COUNT"
  if [ "$FINDING_COUNT" -eq 0 ]; then printf 'none\n'; else
    jq -r '"- [" + .severity + "] " + .gate + " / " + .code + ": " + .message
           + (if .file then " (" + .file + (if .line then ":" + (.line|tostring) else "" end) + ")" else "" end)' "$FINDINGS"
  fi
} > "$SUMMARY"
cp "$SUMMARY" "$SUMMARY_OUT" 2>/dev/null || true

if [ "$FORMAT" = json ]; then cat "$OUT"; else cat "$SUMMARY"; fi
exit "$EXIT"

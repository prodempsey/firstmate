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
# It is execution-backed, never LLM-interpreted: it RUNS the repo's test suites
# rather than parsing for their names, and it fails closed. A SKIP is a finding,
# never a pass; a missing prerequisite tool is a refusal (FC-004), never a silent
# skip of the check it gates.
#
# THE FIVE GATES (each recorded in the bundle with pass/fail and findings)
#   identity        HEAD SHA + branch bound to the declared candidate; tree clean
#   base_currency   the candidate contains the current canonical trunk tip
#                   (bin/fm-trunk-check.sh integration when --project is given)
#   tests           the repo's suites ACTUALLY EXECUTED; PASS/FAIL/SKIP parsed;
#                   SKIP and no-tests are findings, never passes
#   cue_lint        failure-class detection cues (docs/failure-classes/ledger.jsonl)
#                   grepped against the candidate DIFF; a hit is a finding
#   brief_contract  the dispatch contract echoed from the brief plus the
#                   mechanically-checkable items (committed work, branch, clean)
#
# THE BUNDLE lands at data/<task>/verify-bundle.json (JSON) with a sibling
# verify-summary.md; a human summary also prints to stdout. Written atomically
# (temp + rename); a run that cannot complete leaves no partial bundle (FC-007).
#
# EXIT
#   0  clean pass: every gate passed with zero findings
#   1  findings: at least one gate failed or produced a finding (the QA brief
#      carries these, or slice-2's dispatch gate refuses / records an explicit
#      waiver - never silent)
#   2  refuse: a prerequisite tool is missing, an argument is invalid, or an
#      input could not be read (fail closed; never reported as health)
#
# Usage:
#   fm-verify.sh --worktree <path> [options]
#     --worktree <path>   REQUIRED. The candidate worktree to verify.
#     --sha <sha>         Expected HEAD sha; a mismatch fails the identity gate.
#     --branch <name>     Expected branch; a mismatch fails the identity gate.
#     --base <ref>        Explicit base ref for currency + diff (skips trunk-check).
#     --project <name>    Resolve the canonical trunk via bin/fm-trunk-check.sh.
#     --tests-cmd <cmd>   Explicit test command run in the worktree (skips detect).
#     --brief <file>      Brief file to echo + check (default data/<task>/brief.md).
#     --task <id>         Task id: locates the brief and the default --out path.
#     --out <file>        Bundle path (default data/<task>/verify-bundle.json).
#     --format json|text  Human summary format on stdout (default text).
#     -h, --help          This help.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LEDGER="${FM_FAILURE_LEDGER:-$FM_ROOT/docs/failure-classes/ledger.jsonl}"

refuse() { echo "fm-verify: $1" >&2; exit 2; }

usage() { sed -n '/^# Usage:/,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//;$d'; }

# --- prerequisites (FC-004: a missing tool is a refusal, not a skipped check) --
for tool in git jq awk grep sed; do
  command -v "$tool" >/dev/null 2>&1 || refuse "missing prerequisite tool: $tool (fail closed, FC-004)"
done

# --- arguments --------------------------------------------------------------
WORKTREE=""
EXPECT_SHA=""
EXPECT_BRANCH=""
BASE_REF=""
PROJECT=""
TESTS_CMD=""
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
    --tests-cmd) TESTS_CMD=${2:-}; shift ;;
    --brief) BRIEF=${2:-}; shift ;;
    --task) TASK=${2:-}; shift ;;
    --out) OUT=${2:-}; shift ;;
    --format) FORMAT=${2:-}; shift ;;
    -*) refuse "unknown option $1" ;;
    *) refuse "unexpected argument $1" ;;
  esac
  shift
done

[ -n "$WORKTREE" ] || refuse "--worktree is required"
[ -d "$WORKTREE" ] || refuse "worktree does not exist: $WORKTREE"
git -C "$WORKTREE" rev-parse --git-dir >/dev/null 2>&1 || refuse "worktree is not a git repository: $WORKTREE"
case "$FORMAT" in json|text) ;; *) refuse "--format must be json or text" ;; esac

if [ -z "$OUT" ]; then
  [ -n "$TASK" ] || refuse "--out or --task is required to place the bundle"
  OUT="$DATA/$TASK/verify-bundle.json"
fi
if [ -z "$BRIEF" ] && [ -n "$TASK" ]; then
  BRIEF="$DATA/$TASK/brief.md"
fi

# --- scratch (cleaned unconditionally; a partial run leaves no artifact) ------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-verify.XXXXXX") || refuse "cannot create scratch dir"
# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

GATES="$WORK/gates.jsonl"
FINDINGS="$WORK/findings.jsonl"
: > "$GATES"
: > "$FINDINGS"

FINDING_COUNT=0
# emit_finding <gate> <fc-or-code> <severity> <message> [file] [line]
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
# GATE 1: identity - SHA/branch bound, tree clean
# ============================================================================
ACTUAL_SHA=$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || true)
ACTUAL_BRANCH=$(git -C "$WORKTREE" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
PORCELAIN=$(git -C "$WORKTREE" status --porcelain 2>/dev/null || true)
DIRTY=no
[ -n "$PORCELAIN" ] && DIRTY=yes
identity_status=pass

if [ -z "$ACTUAL_SHA" ]; then
  emit_finding identity no-head fail "candidate worktree has no HEAD commit"
  identity_status=fail
fi
if [ -n "$EXPECT_SHA" ] && [ "$EXPECT_SHA" != "$ACTUAL_SHA" ]; then
  emit_finding identity sha-mismatch fail "declared SHA $EXPECT_SHA does not match candidate HEAD $ACTUAL_SHA"
  identity_status=fail
fi
if [ "$ACTUAL_BRANCH" = "HEAD" ]; then
  emit_finding identity detached-head fail "candidate is in detached HEAD, not on a branch"
  identity_status=fail
elif [ -n "$EXPECT_BRANCH" ] && [ "$EXPECT_BRANCH" != "$ACTUAL_BRANCH" ]; then
  emit_finding identity branch-mismatch fail "declared branch $EXPECT_BRANCH does not match candidate branch $ACTUAL_BRANCH"
  identity_status=fail
fi
if [ "$DIRTY" = yes ]; then
  emit_finding identity tree-dirty fail "candidate worktree has uncommitted changes"
  identity_status=fail
fi
emit_gate identity "$identity_status" "$(jq -nc \
  --arg sha "$ACTUAL_SHA" --arg branch "$ACTUAL_BRANCH" \
  --arg esha "$EXPECT_SHA" --arg ebranch "$EXPECT_BRANCH" --arg dirty "$DIRTY" \
  '{head_sha:$sha,branch:$branch,
    expected_sha:(if $esha=="" then null else $esha end),
    expected_branch:(if $ebranch=="" then null else $ebranch end),
    tree_dirty:($dirty=="yes")}')"

# ============================================================================
# GATE 2: base_currency - candidate contains the current canonical trunk tip
# ============================================================================
# Resolve the base ref the candidate must be current with, then diff against it.
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

if [ -n "$BASE_REF" ]; then
  BASE_SHA=$(git -C "$WORKTREE" rev-parse --verify "$BASE_REF^{commit}" 2>/dev/null || true)
  BASE_LABEL=$BASE_REF
  BASE_SOURCE=explicit
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
    BASE_SHA=$(git -C "$WORKTREE" rev-parse --verify "refs/heads/$BASE_LABEL^{commit}" 2>/dev/null || true)
    BASE_SOURCE=local-default
    emit_finding base_currency trunk-not-consulted note "canonical trunk not consulted (no --project/--base); measured currency against local default branch $BASE_LABEL"
  else
    emit_finding base_currency base-undeterminable fail "no base ref could be determined (no --base, no --project, no local default branch)"
    base_status=fail
    BASE_SOURCE=none
  fi
fi

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
# Compute the candidate diff (shared by cue_lint and brief_contract)
# ============================================================================
DIFF_FILE="$WORK/candidate.diff"
ADDED_FILE="$WORK/added.tsv"
: > "$DIFF_FILE"
: > "$ADDED_FILE"
DIFF_BASE=""
if [ -n "$BASE_SHA" ] && git -C "$WORKTREE" cat-file -e "$BASE_SHA^{commit}" 2>/dev/null; then
  DIFF_BASE=$BASE_SHA
fi
if [ -n "$DIFF_BASE" ] && [ -n "$ACTUAL_SHA" ]; then
  git -C "$WORKTREE" diff "$DIFF_BASE...$ACTUAL_SHA" > "$DIFF_FILE" 2>/dev/null || true
fi
# Normalize added lines to <file>\t<new-lineno>\t<content>.
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
# GATE 3: cue_lint - failure-class detection cues grepped against the diff
# ============================================================================
# Mechanical detections graduate specific ledger cues from advice to enforcement.
# Precision over recall: each pattern maps to one FC id and one concrete cue and
# is applied only to lines the candidate ADDED. Classes without a mechanical
# detection are reported advisory-only - never silently treated as clean.
detections() {
  # FC-id<TAB>ERE<TAB>label
  # Patterns are awk EREs (used via `$3 ~ ere`); a literal pipe is [|], never \|
  # (awk reads \| as alternation, which would match everything).
  printf '%s\n' \
    'FC-004	command -v .*[|][|][[:space:]]*(true|:|return 0|continue)([[:space:]#]|$)	fail-open on a missing prerequisite tool (command -v guard degrades instead of refusing)' \
    'FC-006	(curl|wget|nc|ssh|wait|sleep)([[:space:]][^|]*)?[|][|][[:space:]]*true([[:space:]#]|$)	unbounded/synchronous wait or network call on a critical path guarded only by || true' \
    'FC-007	rm[[:space:]].*2>/dev/null.*[|][|][[:space:]]*true	stale artifact cleanup failure ignored (rm ... 2>/dev/null || true)'
}

cue_status=pass
LEDGER_OK=no
LINTED_FILE="$WORK/linted.txt"
: > "$LINTED_FILE"
# The ledger is JSONL (one event per line); a whole-file jq parse never applies.
# Presence of a class-defined event is the readable-ledger signal.
if [ -f "$LEDGER" ] && grep -q '"event":"class-defined"' "$LEDGER" 2>/dev/null; then
  LEDGER_OK=yes
fi
if [ "$LEDGER_OK" != yes ]; then
  emit_finding cue_lint ledger-unreadable fail "failure-class ledger is missing or unreadable: $LEDGER (fail closed)"
  cue_status=fail
fi

CUE_HITS=0
if [ "$LEDGER_OK" = yes ] && [ -s "$ADDED_FILE" ]; then
  while IFS=$'\t' read -r fcid ere label; do
    [ -n "$fcid" ] || continue
    # Bind the detection to the ledger: the class must still exist.
    class_name=$(jq -r --arg id "$fcid" 'select(.event=="class-defined" and .id==$id)|.name' "$LEDGER" 2>/dev/null | head -1)
    if [ -z "$class_name" ]; then
      emit_finding cue_lint detection-orphaned note "detection references $fcid which is not in the ledger; cue not applied"
      continue
    fi
    printf '%s\n' "$fcid" >> "$LINTED_FILE"
    while IFS=$'\t' read -r hfile hline _; do
      emit_finding cue_lint "$fcid" finding \
        "$fcid ($class_name): $label" "$hfile" "$hline"
      CUE_HITS=$((CUE_HITS + 1))
    done < <(awk -F'\t' -v ere="$ere" '$3 ~ ere { print }' "$ADDED_FILE")
  done < <(detections)
  [ "$CUE_HITS" -gt 0 ] && cue_status=fail
fi

# Report every ledger class as mechanically-linted or advisory-only.
ADVISORY_FILE="$WORK/advisory.txt"
: > "$ADVISORY_FILE"
if [ "$LEDGER_OK" = yes ]; then
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    if ! grep -qxF "$cid" "$LINTED_FILE" 2>/dev/null; then
      printf '%s\n' "$cid" >> "$ADVISORY_FILE"
    fi
  done < <(jq -r 'select(.event=="class-defined")|.id' "$LEDGER" 2>/dev/null)
fi
LINTED_ARR=$(jq -Rn '[inputs|select(length>0)]' "$LINTED_FILE" 2>/dev/null || echo '[]')
ADVISORY_ARR=$(jq -Rn '[inputs|select(length>0)]' "$ADVISORY_FILE" 2>/dev/null || echo '[]')
emit_gate cue_lint "$cue_status" "$(jq -nc \
  --arg hits "$CUE_HITS" --arg diffbase "$DIFF_BASE" \
  --argjson linted "$LINTED_ARR" --argjson advisory "$ADVISORY_ARR" \
  '{hits:($hits|tonumber),diff_base:(if $diffbase=="" then null else $diffbase end),
    mechanically_linted:$linted,advisory_only:$advisory}')"

# ============================================================================
# GATE 4: tests - the repo's suites ACTUALLY EXECUTED; SKIP is a finding
# ============================================================================
tests_status=pass
TESTS_RAN=no
TOTAL_OK=0
TOTAL_NOTOK=0
TOTAL_SKIP=0
SUITE_JSONL="$WORK/suites.jsonl"
: > "$SUITE_JSONL"
RUNNER=none

# run_one <label> <interp> <cmd...>
run_one() {
  local label=$1 interp=$2; shift 2
  if [ -n "$interp" ] && ! command -v "$interp" >/dev/null 2>&1; then
    refuse "test runner '$interp' for suite '$label' is not installed (fail closed, FC-004)"
  fi
  local tout="$WORK/transcript.$$.$RANDOM.txt" rc ok notok skip
  ( cd "$WORKTREE" && "$@" ) > "$tout" 2>&1
  rc=$?
  ok=$(grep -cE '^ok([[:space:]]|$)' "$tout" 2>/dev/null || true)
  notok=$(grep -cE '^not ok([[:space:]]|$)' "$tout" 2>/dev/null || true)
  skip=$(grep -cE '(^[[:space:]]*skip:)|(^[[:space:]]*SKIP([[:space:]]|$))|(#[[:space:]]*(skip|SKIP))' "$tout" 2>/dev/null || true)
  ok=${ok:-0}; notok=${notok:-0}; skip=${skip:-0}
  TOTAL_OK=$((TOTAL_OK + ok))
  TOTAL_NOTOK=$((TOTAL_NOTOK + notok))
  TOTAL_SKIP=$((TOTAL_SKIP + skip))
  TESTS_RAN=yes
  jq -nc --arg label "$label" --arg rc "$rc" --arg ok "$ok" --arg notok "$notok" --arg skip "$skip" \
    --rawfile tail <(tail -c 4000 "$tout") \
    '{suite:$label,exit:($rc|tonumber),ok:($ok|tonumber),not_ok:($notok|tonumber),
      skip:($skip|tonumber),transcript_tail:$tail}' >> "$SUITE_JSONL"
  if [ "$rc" -ne 0 ]; then
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
  if [ "$rc" -eq 0 ] && [ "$ok" -eq 0 ] && [ "$notok" -eq 0 ]; then
    emit_finding tests no-assertions fail "test suite '$label' produced no PASS/FAIL assertions; execution proved nothing"
    tests_status=fail
  fi
  rm -f "$tout"
}

if [ -n "$TESTS_CMD" ]; then
  RUNNER=explicit
  # shellcheck disable=SC2086
  run_one "explicit" "$(set -- $TESTS_CMD; echo "$1")" bash -c "$TESTS_CMD"
elif compgen -G "$WORKTREE/tests/*.test.sh" >/dev/null 2>&1; then
  RUNNER=shell-tests
  for t in "$WORKTREE"/tests/*.test.sh; do
    run_one "$(basename "$t")" bash bash "$t"
  done
elif [ -f "$WORKTREE/package.json" ] && jq -e '.scripts.test' "$WORKTREE/package.json" >/dev/null 2>&1; then
  RUNNER="npm"
  run_one "npm test" npm npm test --silent
elif [ -f "$WORKTREE/Makefile" ] && grep -qE '^test:' "$WORKTREE/Makefile" 2>/dev/null; then
  RUNNER="make"
  run_one "make test" make make test
fi

if [ "$TESTS_RAN" != yes ]; then
  emit_finding tests no-tests fail "no test suite was discovered or executed; nothing was proven (never a pass)"
  tests_status=fail
fi
emit_gate tests "$tests_status" "$(jq -nc \
  --arg runner "$RUNNER" --arg ok "$TOTAL_OK" --arg notok "$TOTAL_NOTOK" --arg skip "$TOTAL_SKIP" \
  --slurpfile suites "$SUITE_JSONL" \
  '{runner:$runner,executed:($runner!="none"),
    totals:{ok:($ok|tonumber),not_ok:($notok|tonumber),skip:($skip|tonumber)},
    suites:$suites}')"

# ============================================================================
# GATE 5: brief_contract - echo the dispatch contract + mechanical checks
# ============================================================================
brief_status=pass
BRIEF_PRESENT=no
CONTRACT_FILE="$WORK/contract.txt"
: > "$CONTRACT_FILE"
if [ -n "$BRIEF" ] && [ -f "$BRIEF" ]; then
  BRIEF_PRESENT=yes
  # Echo the mechanically-relevant contract lines (Rules + Definition of done).
  awk '
    /^# (Rules|Definition of done|Setup)/ { grab=1; print; next }
    /^# / && grab { grab=0 }
    grab { print }
  ' "$BRIEF" | sed '/^[[:space:]]*$/d' > "$CONTRACT_FILE"
else
  emit_finding brief_contract brief-missing note "no brief found to echo the dispatch contract (looked at: ${BRIEF:-none})"
fi

# Mechanical checks that a brief-shaped contract implies.
COMMITS=0
if [ -n "$DIFF_BASE" ] && [ -n "$ACTUAL_SHA" ]; then
  COMMITS=$(git -C "$WORKTREE" rev-list --count "$DIFF_BASE..$ACTUAL_SHA" 2>/dev/null || echo 0)
fi
COMMITS=${COMMITS:-0}
if [ "$COMMITS" -eq 0 ]; then
  emit_finding brief_contract no-commits fail "no commits on the candidate over its base; the contract requires committed work"
  brief_status=fail
fi
BRANCH_OK=na
if [ -n "$TASK" ]; then
  if [ "$ACTUAL_BRANCH" = "fm/$TASK" ]; then BRANCH_OK=yes; else
    BRANCH_OK=no
    emit_finding brief_contract branch-name fail "candidate branch is '$ACTUAL_BRANCH'; the contract expected 'fm/$TASK'"
    brief_status=fail
  fi
fi
emit_gate brief_contract "$brief_status" "$(jq -nc \
  --arg present "$BRIEF_PRESENT" --arg commits "$COMMITS" --arg branchok "$BRANCH_OK" \
  --arg clean "$([ "$DIRTY" = no ] && echo true || echo false)" \
  --rawfile echo "$CONTRACT_FILE" \
  '{brief_present:($present=="yes"),commits_on_branch:($commits|tonumber),
    branch_matches_task:$branchok,tree_clean:($clean=="true"),
    contract_echo:$echo}')"

# ============================================================================
# Assemble the bundle and verdict
# ============================================================================
VERDICT=pass
EXIT=0
# Any hard gate failure OR any non-note finding => fail.
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
  --arg stamp "$STAMP" \
  --arg findings_n "$FINDING_COUNT" \
  --slurpfile gates "$GATES" \
  --slurpfile findings "$FINDINGS" \
  '{schema:$schema,verdict:$verdict,
    task:(if $task=="" then null else $task end),
    candidate:{worktree:$worktree,head_sha:$sha,branch:$branch},
    generated_at:(if $stamp=="" then null else $stamp end),
    finding_count:($findings_n|tonumber),
    gates:$gates,findings:$findings}' > "$BUNDLE" || refuse "failed to assemble bundle JSON"

# Atomic publish (FC-007: no partial bundle on failure).
OUT_DIR=$(dirname "$OUT")
mkdir -p "$OUT_DIR" || refuse "cannot create output dir: $OUT_DIR"
TMP_OUT="$OUT.tmp.$$"
cp "$BUNDLE" "$TMP_OUT" || refuse "cannot stage bundle at $TMP_OUT"
mv -f "$TMP_OUT" "$OUT" || { rm -f "$TMP_OUT"; refuse "cannot publish bundle to $OUT"; }

# --- human summary ----------------------------------------------------------
SUMMARY="$WORK/summary.md"
{
  printf '# Gauntlet verify - %s\n\n' "$VERDICT"
  printf -- '- candidate: %s @ %s (%s)\n' "$ACTUAL_BRANCH" "${ACTUAL_SHA:0:12}" "$WORKTREE"
  [ -n "$TASK" ] && printf -- '- task: %s\n' "$TASK"
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

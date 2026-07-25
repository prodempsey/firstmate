#!/usr/bin/env bash
# fm-scanner.sh - deterministic, offline, baseline-attributed scanner battery.
#
# The runner scans immutable checkouts of one candidate SHA and, when available,
# one base SHA. Every scheduled tool call has a portable hard deadline. Tool
# output is normalized to firstmate/scanner-raw-finding/1, then classified by
# bin/fm-findings-attribute.sh. A missing, wrong-version, timed-out, crashed, or
# malformed-output scanner produces exactly one blocking scanner-unavailable
# finding (FC-004); it is never a skip.
#
# No scanner invocation may use a network. OSV-Scanner is always passed --offline
# and must find a pre-provisioned database under FM_SCANNER_OSV_DB.
#
# Usage:
#   fm-scanner.sh --repo <git-repo> --candidate <sha> [--base <sha>] --out <json>
#
# Environment:
#   FM_SCANNER_DIR              pinned tool installation (default: $FM_HOME/tools/scanners)
#   FM_SCANNER_OSV_DB           offline OSV DB cache root (default: $FM_SCANNER_DIR/osv-db)
#   FM_VERIFY_SCANNER_TIMEOUT   per external scanner call, seconds (default 8)
#   FM_VERIFY_SCANNER_BUDGET    whole battery budget, seconds (default 30)
#   FM_VERIFY_FORCE_PID_WATCHDOG=1 forces the portable watchdog path in tests
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
SCANNER_DIR="${FM_SCANNER_DIR:-$FM_HOME/tools/scanners}"
OSV_DB="${FM_SCANNER_OSV_DB:-$SCANNER_DIR/osv-db}"
CALL_TIMEOUT="${FM_VERIFY_SCANNER_TIMEOUT:-8}"
TOTAL_BUDGET="${FM_VERIFY_SCANNER_BUDGET:-30}"

usage() { sed -n '/^# Usage:/,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//;$d'; }
refuse() { printf 'fm-scanner: %s\n' "$1" >&2; exit 2; }

REPO=""
CANDIDATE=""
BASE=""
OUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPO=${2:-}; shift ;;
    --candidate) CANDIDATE=${2:-}; shift ;;
    --base) BASE=${2:-}; shift ;;
    --out) OUT=${2:-}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) refuse "unknown argument: $1" ;;
  esac
  shift
done

for n in "$CALL_TIMEOUT" "$TOTAL_BUDGET"; do
  case "$n" in ''|*[!0-9]*) refuse "scanner deadlines must be positive integers" ;; esac
  [ "$n" -gt 0 ] || refuse "scanner deadlines must be positive integers"
done
for tool in git jq awk sed grep sha256sum mktemp date; do
  command -v "$tool" >/dev/null 2>&1 || refuse "required orchestrator tool unavailable: $tool"
done
if [ -z "$REPO" ] || ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  refuse "--repo must name a git repository"
fi
if [ -z "$CANDIDATE" ] || ! git -C "$REPO" cat-file -e "$CANDIDATE^{commit}" 2>/dev/null; then
  refuse "--candidate must resolve to a commit"
fi
[ -n "$OUT" ] || refuse "--out is required"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-scanner.XXXXXX") || refuse "cannot create scratch directory"
BASE_DIR=""
CANDIDATE_DIR=""
cleanup() {
  if [ -n "$BASE_DIR" ]; then git -C "$REPO" worktree remove --force "$BASE_DIR" >/dev/null 2>&1 || true; fi
  if [ -n "$CANDIDATE_DIR" ]; then git -C "$REPO" worktree remove --force "$CANDIDATE_DIR" >/dev/null 2>&1 || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

CANDIDATE_DIR="$TMP/candidate"
git -C "$REPO" worktree add --detach --quiet "$CANDIDATE_DIR" "$CANDIDATE" 2>"$TMP/candidate-worktree.err" ||
  refuse "cannot create immutable candidate checkout"
BASELINE_AVAILABLE=false
if [ -n "$BASE" ] && git -C "$REPO" cat-file -e "$BASE^{commit}" 2>/dev/null; then
  BASE_DIR="$TMP/base"
  if git -C "$REPO" worktree add --detach --quiet "$BASE_DIR" "$BASE" 2>"$TMP/base-worktree.err"; then
    BASELINE_AVAILABLE=true
  else
    BASE_DIR=""
  fi
fi

RAW_BASE="$TMP/raw-base.jsonl"
RAW_CANDIDATE="$TMP/raw-candidate.jsonl"
TIMINGS="$TMP/timings.jsonl"
CHANGED="$TMP/changed.txt"
: > "$RAW_BASE"
: > "$RAW_CANDIDATE"
: > "$TIMINGS"
: > "$CHANGED"

if [ "$BASELINE_AVAILABLE" = true ]; then
  git -C "$REPO" diff --name-only --diff-filter=ACMR "$BASE...$CANDIDATE" > "$CHANGED" ||
    BASELINE_AVAILABLE=false
fi
if [ "$BASELINE_AVAILABLE" != true ]; then
  git -C "$CANDIDATE_DIR" ls-files > "$CHANGED"
fi

TIMEOUT_BIN=""
for tb in timeout gtimeout; do
  if command -v "$tb" >/dev/null 2>&1; then TIMEOUT_BIN=$tb; break; fi
done
BATTERY_STARTED=$(date +%s)
BOUNDED_TIMEOUT=no
RUN_RC=0
run_bounded() {
  local budget=$1 cwd=$2 outfile=$3
  shift 3
  BOUNDED_TIMEOUT=no
  local elapsed global_remaining
  elapsed=$(($(date +%s) - BATTERY_STARTED))
  global_remaining=$((TOTAL_BUDGET - elapsed))
  if [ "$global_remaining" -lt 1 ]; then
    : > "$outfile"
    BOUNDED_TIMEOUT=yes
    RUN_RC=124
    return
  fi
  [ "$budget" -gt "$global_remaining" ] && budget=$global_remaining
  if [ -n "$TIMEOUT_BIN" ] && [ "${FM_VERIFY_FORCE_PID_WATCHDOG:-}" != 1 ]; then
    (cd "$cwd" && exec "$TIMEOUT_BIN" -k 2 "$budget" "$@") > "$outfile" 2>&1
    RUN_RC=$?
    [ "$RUN_RC" -eq 124 ] && BOUNDED_TIMEOUT=yes
    return
  fi
  local flag="$TMP/scanner-timeout.$RANDOM"
  rm -f "$flag"
  (cd "$cwd" && exec "$@") > "$outfile" 2>&1 &
  local child=$!
  (sleep "$budget"; touch "$flag"; kill -TERM "$child" 2>/dev/null; sleep 2; kill -KILL "$child" 2>/dev/null) &
  local watcher=$!
  wait "$child" 2>/dev/null
  RUN_RC=$?
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  if [ -f "$flag" ]; then BOUNDED_TIMEOUT=yes; RUN_RC=124; fi
  rm -f "$flag"
}

remaining_budget() {
  local elapsed remaining
  elapsed=$(($(date +%s) - BATTERY_STARTED))
  remaining=$((TOTAL_BUDGET - elapsed))
  [ "$remaining" -gt "$CALL_TIMEOUT" ] && remaining=$CALL_TIMEOUT
  [ "$remaining" -lt 1 ] && remaining=1
  printf '%s\n' "$remaining"
}

scanner_started=0
scanner_begin() { scanner_started=$(date +%s); }
scanner_end() {
  local scanner=$1 status=$2 duration
  duration=$((($(date +%s) - scanner_started) * 1000))
  jq -nc --arg scanner "$scanner" --arg status "$status" --arg duration "$duration" \
    '{scanner:$scanner,status:$status,duration_ms:($duration|tonumber)}' >> "$TIMINGS"
}
not_applicable() {
  local scanner=$1 reason=$2
  jq -nc --arg scanner "$scanner" --arg reason "$reason" \
    '{scanner:$scanner,status:"not-applicable",duration_ms:0,reason:$reason}' >> "$TIMINGS"
}

emit_unavailable() {
  local scanner=$1 reason=$2
  jq -nc --arg scanner "$scanner" --arg message "$reason" '
    {
      schema:"firstmate/scanner-raw-finding/1",
      scanner:$scanner,
      rule_id:"scanner-unavailable",
      severity:"error",
      path:null,
      line:null,
      message:("SCANNER_UNAVAILABLE ["+$scanner+"]: "+$message+" (fail closed, FC-004)"),
      content:("SCANNER_UNAVAILABLE "+$scanner)
    }
  ' >> "$RAW_CANDIDATE"
}

resolve_tool() {
  local name=$1
  if [ -x "$SCANNER_DIR/bin/$name" ]; then
    printf '%s\n' "$SCANNER_DIR/bin/$name"
  fi
}

# Node is a host runtime for the committed wrappers, not a scanner resolved from
# PATH. The scanner implementations and their package graphs remain pinned under
# SCANNER_DIR and every standalone scanner resolves only from SCANNER_DIR/bin.
resolve_node_runtime() {
  command -v node 2>/dev/null || true
}

tool_ready() {
  local scanner=$1 executable=$2 expected=$3
  if [ -z "$executable" ] || [ ! -x "$executable" ]; then
    emit_unavailable "$scanner" "pinned executable is missing; run bin/fm-install-scanners.sh $SCANNER_DIR"
    return 1
  fi
  local version_out="$TMP/version-$scanner.out"
  run_bounded "$(remaining_budget)" "$CANDIDATE_DIR" "$version_out" "$executable" --version
  if [ "$BOUNDED_TIMEOUT" = yes ]; then
    emit_unavailable "$scanner" "version probe exceeded its hard deadline (FC-006)"
    return 1
  fi
  if [ "$RUN_RC" -ne 0 ] || ! grep -Fq "$expected" "$version_out"; then
    emit_unavailable "$scanner" "expected pinned version $expected; version probe failed or reported another version"
    return 1
  fi
  return 0
}

raw_from_sarif() {
  local scanner=$1 sarif=$2 root=$3 destination=$4 severity=${5:-error}
  jq -e '(.runs|type)=="array"' "$sarif" >/dev/null 2>&1 || return 1
  jq -c --arg scanner "$scanner" --arg root "$root/" --arg severity "$severity" '
    .runs[]?.results[]? |
    (.locations[0]?.physicalLocation // {}) as $physical |
    ($physical.artifactLocation.uri // null) as $uri |
    {
      schema:"firstmate/scanner-raw-finding/1",
      scanner:$scanner,
      rule_id:(.ruleId // "unknown-rule"),
      severity:$severity,
      path:(if $uri == null then null
            else ($uri|sub("^file://";"")|if startswith($root) then .[($root|length):] else . end)
            end),
      line:($physical.region.startLine // null),
      message:(.message.text // .message.markdown // "scanner finding"),
      content:null
    }
  ' "$sarif" >> "$destination"
}

raw_from_eslint() {
  local scanner=$1 report=$2 root=$3 destination=$4
  jq -e 'type=="array"' "$report" >/dev/null 2>&1 || return 1
  jq -c --arg scanner "$scanner" --arg root "$root/" '
    .[] | .filePath as $file | .messages[]? |
    {
      schema:"firstmate/scanner-raw-finding/1",
      scanner:$scanner,
      rule_id:(.ruleId // "parse-error"),
      severity:(if (.severity // 2) >= 2 then "error" else "warning" end),
      path:($file|if startswith($root) then .[($root|length):] else . end),
      line:(.line // 1),
      message:(.message // "eslint finding"),
      content:null
    }
  ' "$report" >> "$destination"
}

raw_from_actionlint() {
  local report=$1 root=$2 destination=$3
  jq -e 'type=="array"' "$report" >/dev/null 2>&1 || return 1
  jq -c --arg root "$root/" '
    .[] | {
      schema:"firstmate/scanner-raw-finding/1",
      scanner:"actionlint",
      rule_id:(.kind // "workflow"),
      severity:"error",
      path:((.filepath // "")|if startswith($root) then .[($root|length):] else . end),
      line:(.line // 1),
      message:(.message // "actionlint finding"),
      content:null
    }
  ' "$report" >> "$destination"
}

raw_from_shellcheck() {
  local report=$1 root=$2 destination=$3
  jq -e 'type=="array"' "$report" >/dev/null 2>&1 || return 1
  jq -c --arg root "$root/" '
    .[] | {
      schema:"firstmate/scanner-raw-finding/1",
      scanner:"shellcheck",
      rule_id:("SC"+(.code|tostring)),
      severity:(if .level == "error" then "error" else "warning" end),
      path:(.file|if startswith($root) then .[($root|length):] else . end),
      line:(.line // 1),
      message:(.message // "shellcheck finding"),
      content:null
    }
  ' "$report" >> "$destination"
}

raw_from_schema() {
  local report=$1 root=$2 destination=$3
  jq -e 'type=="array" and all(.[]; (keys==["message","path"]) and (.message|type)=="string" and (.path|type)=="string")' \
    "$report" >/dev/null 2>&1 || return 1
  jq -c --arg root "$root/" '
    .[] | {
      schema:"firstmate/scanner-raw-finding/1",
      scanner:"jq",
      rule_id:"declared-schema",
      severity:"error",
      path:(.path|if startswith($root) then .[($root|length):] else . end),
      line:1,
      message:.message,
      content:.message
    }
  ' "$report" >> "$destination"
}

raw_from_gitleaks() {
  local report=$1 root=$2 destination=$3
  jq -e 'type=="array"' "$report" >/dev/null 2>&1 || return 1
  jq -c --arg root "$root/" '
    .[] | {
      schema:"firstmate/scanner-raw-finding/1",
      scanner:"gitleaks",
      rule_id:(.RuleID // "secret"),
      severity:"error",
      path:((.File // "")|if startswith($root) then .[($root|length):] else . end),
      line:(.StartLine // 1),
      message:(.Description // "potential secret"),
      content:(.Line // .Match // .Description // "potential secret")
    }
  ' "$report" >> "$destination"
}

enrich_content() {
  local source=$1 root=$2 destination=$3 record path line content_file
  content_file="$TMP/content.$RANDOM"
  : > "$destination"
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    path=$(printf '%s\n' "$record" | jq -r '.path // ""')
    line=$(printf '%s\n' "$record" | jq -r '.line // ""')
    : > "$content_file"
    if [ -n "$path" ] && [ -n "$line" ] && [ -f "$root/$path" ]; then
      sed -n "${line}p" "$root/$path" > "$content_file"
    fi
    if [ ! -s "$content_file" ]; then
      printf '%s\n' "$record" | jq -r '.message' > "$content_file"
    fi
    printf '%s\n' "$record" | jq -c --rawfile content "$content_file" '.content=($content|sub("\n$";""))' \
      >> "$destination"
  done < "$source"
  rm -f "$content_file"
}

changed_matches() { grep -Eq "$1" "$CHANGED" 2>/dev/null; }
list_changed() { grep -E "$1" "$CHANGED" 2>/dev/null || true; }

run_sarif_scan() {
  local scanner=$1 executable=$2 root=$3 output=$4
  shift 4
  run_bounded "$(remaining_budget)" "$root" "$output" "$executable" "$@"
  if [ "$BOUNDED_TIMEOUT" = yes ]; then
    SCAN_ERROR="$scanner exceeded its hard deadline (FC-006)"
    return 1
  fi
  if [ "$RUN_RC" -gt 1 ]; then
    SCAN_ERROR="$scanner crashed with exit $RUN_RC"
    return 1
  fi
  if ! jq -e '(.runs|type)=="array"' "$output" >/dev/null 2>&1; then
    SCAN_ERROR="$scanner returned malformed SARIF"
    return 1
  fi
  return 0
}

# Gitleaks runs raw against both snapshots.
# The generic attributor is the only mechanism allowed to separate inherited
# and candidate-new findings, so native baseline filtering is deliberately absent.
scanner_begin
GITLEAKS=$(resolve_tool gitleaks)
if tool_ready gitleaks "$GITLEAKS" 8.30.1; then
  GITLEAKS_OK=true
  BASELINE_REPORT="$TMP/gitleaks-baseline.json"
  printf '[]\n' > "$BASELINE_REPORT"
  if [ "$BASELINE_AVAILABLE" = true ]; then
    run_bounded "$(remaining_budget)" "$BASE_DIR" "$TMP/gitleaks-base-history.log" \
      "$GITLEAKS" git --no-banner --redact --exit-code 0 --report-format json \
      --report-path "$TMP/gitleaks-base-history.json" --log-opts="$BASE"
    if [ "$BOUNDED_TIMEOUT" = yes ] || [ "$RUN_RC" -ne 0 ]; then GITLEAKS_OK=false; fi
    run_bounded "$(remaining_budget)" "$BASE_DIR" "$TMP/gitleaks-base-dir.log" \
      "$GITLEAKS" dir --no-banner --redact --exit-code 0 --report-format json \
      --report-path "$TMP/gitleaks-base-dir.json" .
    if [ "$BOUNDED_TIMEOUT" = yes ] || [ "$RUN_RC" -ne 0 ]; then GITLEAKS_OK=false; fi
    if [ "$GITLEAKS_OK" = true ] &&
      jq -s 'add' "$TMP/gitleaks-base-history.json" "$TMP/gitleaks-base-dir.json" > "$BASELINE_REPORT" &&
      raw_from_gitleaks "$BASELINE_REPORT" "$BASE_DIR" "$RAW_BASE"; then :; else GITLEAKS_OK=false; fi
  fi
  if [ "$GITLEAKS_OK" = true ]; then
    log_opts=$CANDIDATE
    [ "$BASELINE_AVAILABLE" = true ] && log_opts="$BASE..$CANDIDATE"
    run_bounded "$(remaining_budget)" "$CANDIDATE_DIR" "$TMP/gitleaks-candidate-history.log" \
      "$GITLEAKS" git --no-banner --redact --exit-code 0 --report-format json \
      --report-path "$TMP/gitleaks-candidate-history.json" --log-opts="$log_opts"
    if [ "$BOUNDED_TIMEOUT" = yes ] || [ "$RUN_RC" -ne 0 ]; then GITLEAKS_OK=false; fi
    run_bounded "$(remaining_budget)" "$CANDIDATE_DIR" "$TMP/gitleaks-candidate-dir.log" \
      "$GITLEAKS" dir --no-banner --redact --exit-code 0 --report-format json \
      --report-path "$TMP/gitleaks-candidate-dir.json" .
    if [ "$BOUNDED_TIMEOUT" = yes ] || [ "$RUN_RC" -ne 0 ]; then GITLEAKS_OK=false; fi
  fi
  if [ "$GITLEAKS_OK" = true ] &&
    jq -s 'add' "$TMP/gitleaks-candidate-history.json" "$TMP/gitleaks-candidate-dir.json" > "$TMP/gitleaks-candidate.json" &&
    raw_from_gitleaks "$TMP/gitleaks-candidate.json" "$CANDIDATE_DIR" "$RAW_CANDIDATE"; then
    scanner_end gitleaks ok
  else
    emit_unavailable gitleaks "scan timed out, crashed, or returned malformed JSON"
    scanner_end gitleaks unavailable
  fi
else
  scanner_end gitleaks unavailable
fi

# oxlint: whole-repository JS scan at base and candidate.
if git -C "$CANDIDATE_DIR" ls-files '*.js' '*.mjs' '*.cjs' | grep -q .; then
  scanner_begin
  OXLINT=$(resolve_tool oxlint)
  if tool_ready oxlint "$OXLINT" 1.75.0; then
    OXLINT_OK=true
    if [ "$BASELINE_AVAILABLE" = true ]; then
      if run_sarif_scan oxlint "$OXLINT" "$BASE_DIR" "$TMP/oxlint-base.sarif" \
        -f sarif --deny-warnings --no-error-on-unmatched-pattern . &&
        raw_from_sarif oxlint "$TMP/oxlint-base.sarif" "$BASE_DIR" "$RAW_BASE"; then :;
      else OXLINT_OK=false; fi
    fi
    if [ "$OXLINT_OK" = true ]; then
      if run_sarif_scan oxlint "$OXLINT" "$CANDIDATE_DIR" "$TMP/oxlint-candidate.sarif" \
        -f sarif --deny-warnings --no-error-on-unmatched-pattern . &&
        raw_from_sarif oxlint "$TMP/oxlint-candidate.sarif" "$CANDIDATE_DIR" "$RAW_CANDIDATE"; then :;
      else OXLINT_OK=false; fi
    fi
    if [ "$OXLINT_OK" = true ]; then scanner_end oxlint ok
    else emit_unavailable oxlint "${SCAN_ERROR:-malformed output}"; scanner_end oxlint unavailable; fi
  else
    scanner_end oxlint unavailable
  fi
else
  not_applicable oxlint "repository has no tracked JavaScript"
fi

# eslint 9 + sonarjs/n/security: candidate-diff JavaScript only.
if changed_matches '\.(js|mjs|cjs)$'; then
  scanner_begin
  ESLINT_EXECUTABLE=$(resolve_tool eslint-scanner)
  NODE=$(resolve_node_runtime)
  ESLINT_WRAPPER="$SCRIPT_DIR/fm-eslint-scanner.mjs"
  ESLINT_OK=true
  if [ -n "$ESLINT_EXECUTABLE" ] && [ -x "$ESLINT_EXECUTABLE" ]; then
    ESLINT_COMMAND=("$ESLINT_EXECUTABLE")
  elif [ -n "$NODE" ] && [ -x "$NODE" ] && [ -f "$ESLINT_WRAPPER" ] &&
    [ -d "$SCANNER_DIR/node/node_modules/eslint" ]; then
    ESLINT_COMMAND=(env FM_SCANNER_NODE_DIR="$SCANNER_DIR/node" "$NODE" "$ESLINT_WRAPPER")
  else
    emit_unavailable eslint "pinned ESLint 9 scanner bundle is missing; run bin/fm-install-scanners.sh $SCANNER_DIR"
    ESLINT_OK=false
    ESLINT_COMMAND=()
  fi
  if [ "$ESLINT_OK" = true ]; then
    run_bounded "$(remaining_budget)" "$CANDIDATE_DIR" "$TMP/eslint-version.out" \
      "${ESLINT_COMMAND[@]}" --version
    if [ "$BOUNDED_TIMEOUT" = yes ] || [ "$RUN_RC" -ne 0 ] ||
      ! grep -Fq 9.39.5 "$TMP/eslint-version.out"; then
      emit_unavailable eslint "expected pinned ESLint 9.39.5 bundle; version probe failed"
      ESLINT_OK=false
    fi
  fi
  if [ "$ESLINT_OK" = true ]; then
    mapfile -t JS_FILES < <(list_changed '\.(js|mjs|cjs)$')
    BASE_JS=()
    CANDIDATE_JS=()
    for file in "${JS_FILES[@]}"; do
      [ "$BASELINE_AVAILABLE" = true ] && [ -f "$BASE_DIR/$file" ] && BASE_JS+=("$file")
      [ -f "$CANDIDATE_DIR/$file" ] && CANDIDATE_JS+=("$file")
    done
    if [ "${#BASE_JS[@]}" -gt 0 ]; then
      run_bounded "$(remaining_budget)" "$BASE_DIR" "$TMP/eslint-base.json" \
        "${ESLINT_COMMAND[@]}" "${BASE_JS[@]}"
      if [ "$BOUNDED_TIMEOUT" = yes ] || [ "$RUN_RC" -gt 1 ] ||
        ! raw_from_eslint eslint "$TMP/eslint-base.json" "$BASE_DIR" "$RAW_BASE"; then ESLINT_OK=false; fi
    fi
    if [ "${#CANDIDATE_JS[@]}" -gt 0 ] && [ "$ESLINT_OK" = true ]; then
      run_bounded "$(remaining_budget)" "$CANDIDATE_DIR" "$TMP/eslint-candidate.json" \
        "${ESLINT_COMMAND[@]}" "${CANDIDATE_JS[@]}"
      if [ "$BOUNDED_TIMEOUT" = yes ] || [ "$RUN_RC" -gt 1 ] ||
        ! raw_from_eslint eslint "$TMP/eslint-candidate.json" "$CANDIDATE_DIR" "$RAW_CANDIDATE"; then ESLINT_OK=false; fi
    fi
  fi
  if [ "$ESLINT_OK" = true ]; then scanner_end eslint ok
  else
    if ! grep -q '"scanner":"eslint".*"rule_id":"scanner-unavailable"' "$RAW_CANDIDATE"; then
      emit_unavailable eslint "scan timed out, crashed, or returned malformed JSON"
    fi
    scanner_end eslint unavailable
  fi
else
  not_applicable eslint "candidate diff has no JavaScript"
fi

# osv-scanner: lockfile-touching diffs only, with the fully-offline flag.
LOCK_RE='(^|/)(package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|Cargo\.lock|go\.sum|poetry\.lock|Pipfile\.lock|composer\.lock|Gemfile\.lock)$'
if changed_matches "$LOCK_RE"; then
  scanner_begin
  OSV=$(resolve_tool osv-scanner)
  if tool_ready osv-scanner "$OSV" 2.4.0; then
    OSV_OK=true
    mapfile -t LOCK_FILES < <(list_changed "$LOCK_RE")
    BASE_LOCKS=()
    CANDIDATE_LOCKS=()
    for file in "${LOCK_FILES[@]}"; do
      [ "$BASELINE_AVAILABLE" = true ] && [ -f "$BASE_DIR/$file" ] && BASE_LOCKS+=("$file")
      [ -f "$CANDIDATE_DIR/$file" ] && CANDIDATE_LOCKS+=("$file")
    done
    if [ ! -d "$OSV_DB/osv-scanner" ]; then
      emit_unavailable osv-scanner "offline database is missing at $OSV_DB; runtime download is forbidden"
      OSV_OK=false
    fi
    if [ "$OSV_OK" = true ] && [ "${#BASE_LOCKS[@]}" -gt 0 ]; then
      OSV_ARGS=(--offline scan source --format sarif)
      for file in "${BASE_LOCKS[@]}"; do OSV_ARGS+=(-L "$file"); done
      if run_sarif_scan osv-scanner env "$BASE_DIR" "$TMP/osv-base.sarif" \
        OSV_SCANNER_LOCAL_DB_CACHE_DIRECTORY="$OSV_DB" "$OSV" "${OSV_ARGS[@]}" &&
        raw_from_sarif osv-scanner "$TMP/osv-base.sarif" "$BASE_DIR" "$RAW_BASE"; then :;
      else OSV_OK=false; fi
    fi
    if [ "$OSV_OK" = true ] && [ "${#CANDIDATE_LOCKS[@]}" -gt 0 ]; then
      OSV_ARGS=(--offline scan source --format sarif)
      for file in "${CANDIDATE_LOCKS[@]}"; do OSV_ARGS+=(-L "$file"); done
      if run_sarif_scan osv-scanner env "$CANDIDATE_DIR" "$TMP/osv-candidate.sarif" \
        OSV_SCANNER_LOCAL_DB_CACHE_DIRECTORY="$OSV_DB" "$OSV" "${OSV_ARGS[@]}" &&
        raw_from_sarif osv-scanner "$TMP/osv-candidate.sarif" "$CANDIDATE_DIR" "$RAW_CANDIDATE"; then :;
      else OSV_OK=false; fi
    fi
    if [ "$OSV_OK" = true ]; then scanner_end osv-scanner ok
    else
      if ! grep -q '"scanner":"osv-scanner".*"rule_id":"scanner-unavailable"' "$RAW_CANDIDATE"; then
        emit_unavailable osv-scanner "${SCAN_ERROR:-offline scan failed}"
      fi
      scanner_end osv-scanner unavailable
    fi
  else
    scanner_end osv-scanner unavailable
  fi
else
  not_applicable osv-scanner "candidate diff has no supported lockfile"
fi

# actionlint: changed GitHub workflow files only.
WORKFLOW_RE='^\.github/workflows/.*\.(yml|yaml)$'
if changed_matches "$WORKFLOW_RE"; then
  scanner_begin
  ACTIONLINT=$(resolve_tool actionlint)
  if tool_ready actionlint "$ACTIONLINT" 1.7.12; then
    ACTIONLINT_OK=true
    mapfile -t WORKFLOW_FILES < <(list_changed "$WORKFLOW_RE")
    BASE_WORKFLOWS=()
    CANDIDATE_WORKFLOWS=()
    for file in "${WORKFLOW_FILES[@]}"; do
      [ "$BASELINE_AVAILABLE" = true ] && [ -f "$BASE_DIR/$file" ] && BASE_WORKFLOWS+=("$file")
      [ -f "$CANDIDATE_DIR/$file" ] && CANDIDATE_WORKFLOWS+=("$file")
    done
    if [ "${#BASE_WORKFLOWS[@]}" -gt 0 ]; then
      run_bounded "$(remaining_budget)" "$BASE_DIR" "$TMP/actionlint-base.json" \
        "$ACTIONLINT" -format '{{json .}}' -shellcheck= -pyflakes= "${BASE_WORKFLOWS[@]}"
      if [ "$BOUNDED_TIMEOUT" = yes ] || [ "$RUN_RC" -gt 1 ] ||
        ! raw_from_actionlint "$TMP/actionlint-base.json" "$BASE_DIR" "$RAW_BASE"; then ACTIONLINT_OK=false; fi
    fi
    if [ "${#CANDIDATE_WORKFLOWS[@]}" -gt 0 ] && [ "$ACTIONLINT_OK" = true ]; then
      run_bounded "$(remaining_budget)" "$CANDIDATE_DIR" "$TMP/actionlint-candidate.json" \
        "$ACTIONLINT" -format '{{json .}}' -shellcheck= -pyflakes= "${CANDIDATE_WORKFLOWS[@]}"
      if [ "$BOUNDED_TIMEOUT" = yes ] || [ "$RUN_RC" -gt 1 ] ||
        ! raw_from_actionlint "$TMP/actionlint-candidate.json" "$CANDIDATE_DIR" "$RAW_CANDIDATE"; then ACTIONLINT_OK=false; fi
    fi
    if [ "$ACTIONLINT_OK" = true ]; then scanner_end actionlint ok
    else emit_unavailable actionlint "scan timed out, crashed, or returned malformed JSON"; scanner_end actionlint unavailable; fi
  else
    scanner_end actionlint unavailable
  fi
else
  not_applicable actionlint "candidate diff has no GitHub workflow"
fi

# jq: changed JSON and JSONL; optional local JSON Schema map is fail-closed.
JSON_RE='\.(json|jsonl)$'
if changed_matches "$JSON_RE"; then
  scanner_begin
  JQ=$(resolve_tool jq)
  if tool_ready jq "$JQ" jq-1.7.1; then
    JQ_OK=true
    mapfile -t JSON_FILES < <(list_changed "$JSON_RE")
    for snapshot in base candidate; do
      root=$CANDIDATE_DIR
      destination=$RAW_CANDIDATE
      [ "$snapshot" = base ] && root=$BASE_DIR && destination=$RAW_BASE
      [ "$snapshot" = base ] && [ "$BASELINE_AVAILABLE" != true ] && continue
      for file in "${JSON_FILES[@]}"; do
        [ -f "$root/$file" ] || continue
        run_bounded "$(remaining_budget)" "$root" "$TMP/jq-$snapshot.out" "$JQ" empty "$file"
        if [ "$BOUNDED_TIMEOUT" = yes ]; then JQ_OK=false; break; fi
        if [ "$RUN_RC" -ne 0 ]; then
          jq -nc --arg path "$file" --arg message "JSON/JSONL is not well formed" \
            '{schema:"firstmate/scanner-raw-finding/1",scanner:"jq",rule_id:"well-formedness",
              severity:"error",path:$path,line:1,message:$message,content:$message}' >> "$destination"
        fi
      done
      [ "$JQ_OK" = true ] || break
    done
    SCHEMA_COMMAND=()
    SCHEMA_PROBED=false
    for snapshot in base candidate; do
      root=$CANDIDATE_DIR
      destination=$RAW_CANDIDATE
      [ "$snapshot" = base ] && root=$BASE_DIR && destination=$RAW_BASE
      [ "$snapshot" = base ] && [ "$BASELINE_AVAILABLE" != true ] && continue
      SCHEMA_MAP="$root/.fm-scanner-schemas.json"
      [ -f "$SCHEMA_MAP" ] || continue
      if ! "$JQ" -e '
        keys == ["mappings","schema"]
        and .schema == "firstmate/scanner-schema-map/1"
        and (.mappings|type) == "array"
        and all(.mappings[];
          keys == ["path","schema_path"]
          and (.path|type) == "string" and (.path|length)>0
          and (.schema_path|type) == "string" and (.schema_path|length)>0)
      ' "$SCHEMA_MAP" >/dev/null 2>&1; then
        jq -nc \
          '{schema:"firstmate/scanner-raw-finding/1",scanner:"jq",rule_id:"schema-map",
            severity:"error",path:".fm-scanner-schemas.json",line:1,
            message:"schema declaration map is outside firstmate/scanner-schema-map/1",
            content:"invalid scanner schema declaration map"}' >> "$destination"
        continue
      fi
      while IFS=$'\t' read -r document schema_path; do
        [ -n "$document" ] || continue
        grep -Fqx "$document" "$CHANGED" || continue
        [ -f "$root/$document" ] || continue
        if [ ! -f "$root/$schema_path" ]; then
          jq -nc --arg path "$document" --arg schema_path "$schema_path" \
            '{schema:"firstmate/scanner-raw-finding/1",scanner:"jq",rule_id:"declared-schema-missing",
              severity:"error",path:$path,line:1,
              message:("declared schema is missing: "+$schema_path),content:$schema_path}' >> "$destination"
          continue
        fi
        if [ "$SCHEMA_PROBED" = false ]; then
          SCHEMA_EXECUTABLE=$(resolve_tool json-schema-scanner)
          NODE=$(resolve_node_runtime)
          if [ -n "$SCHEMA_EXECUTABLE" ] && [ -x "$SCHEMA_EXECUTABLE" ]; then
            SCHEMA_COMMAND=("$SCHEMA_EXECUTABLE")
          elif [ -n "$NODE" ] && [ -x "$NODE" ] &&
            [ -d "$SCANNER_DIR/node/node_modules/ajv" ]; then
            SCHEMA_COMMAND=(env FM_SCANNER_NODE_DIR="$SCANNER_DIR/node" "$NODE" "$SCRIPT_DIR/fm-json-schema-scanner.mjs")
          fi
          SCHEMA_PROBED=true
          if [ "${#SCHEMA_COMMAND[@]}" -eq 0 ]; then
            emit_unavailable jq "declared JSON schemas exist but the pinned Ajv 8.17.1 bundle is missing"
            JQ_OK=false
            break
          fi
          run_bounded "$(remaining_budget)" "$root" "$TMP/schema-version.out" \
            "${SCHEMA_COMMAND[@]}" --version
          if [ "$BOUNDED_TIMEOUT" = yes ] || [ "$RUN_RC" -ne 0 ] ||
            ! grep -Fq 'ajv 8.17.1' "$TMP/schema-version.out"; then
            emit_unavailable jq "declared-schema validator version probe failed or timed out"
            JQ_OK=false
            break
          fi
        fi
        run_bounded "$(remaining_budget)" "$root" "$TMP/schema-$snapshot.json" \
          "${SCHEMA_COMMAND[@]}" "$schema_path" "$document"
        if [ "$BOUNDED_TIMEOUT" = yes ] || [ "$RUN_RC" -gt 1 ] ||
          ! raw_from_schema "$TMP/schema-$snapshot.json" "$root" "$destination"; then
          emit_unavailable jq "declared-schema validation timed out, crashed, or returned malformed JSON"
          JQ_OK=false
          break
        fi
      done < <("$JQ" -r '.mappings[]|[.path,.schema_path]|@tsv' "$SCHEMA_MAP")
      [ "$JQ_OK" = true ] || break
    done
    if [ "$JQ_OK" = true ]; then scanner_end jq ok
    else
      if ! grep -q '"scanner":"jq".*"rule_id":"scanner-unavailable"' "$RAW_CANDIDATE"; then
        emit_unavailable jq "well-formedness or declared-schema scan failed"
      fi
      scanner_end jq unavailable
    fi
  else
    scanner_end jq unavailable
  fi
else
  not_applicable jq "candidate diff has no JSON or JSONL"
fi

# ShellCheck scanner: all changed shell scripts, including scripts outside bin/.
SHELL_RE='\.sh$'
if changed_matches "$SHELL_RE"; then
  scanner_begin
  SHELLCHECK=$(resolve_tool shellcheck)
  if tool_ready shellcheck "$SHELLCHECK" 0.11.0; then
    SHELLCHECK_OK=true
    mapfile -t SHELL_FILES < <(list_changed "$SHELL_RE")
    BASE_SHELL=()
    CANDIDATE_SHELL=()
    for file in "${SHELL_FILES[@]}"; do
      [ "$BASELINE_AVAILABLE" = true ] && [ -f "$BASE_DIR/$file" ] && BASE_SHELL+=("$file")
      [ -f "$CANDIDATE_DIR/$file" ] && CANDIDATE_SHELL+=("$file")
    done
    if [ "${#BASE_SHELL[@]}" -gt 0 ]; then
      run_bounded "$(remaining_budget)" "$BASE_DIR" "$TMP/shellcheck-base.json" \
        "$SHELLCHECK" --norc -f json "${BASE_SHELL[@]}"
      if [ "$BOUNDED_TIMEOUT" = yes ] || [ "$RUN_RC" -gt 1 ] ||
        ! raw_from_shellcheck "$TMP/shellcheck-base.json" "$BASE_DIR" "$RAW_BASE"; then SHELLCHECK_OK=false; fi
    fi
    if [ "${#CANDIDATE_SHELL[@]}" -gt 0 ] && [ "$SHELLCHECK_OK" = true ]; then
      run_bounded "$(remaining_budget)" "$CANDIDATE_DIR" "$TMP/shellcheck-candidate.json" \
        "$SHELLCHECK" --norc -f json "${CANDIDATE_SHELL[@]}"
      if [ "$BOUNDED_TIMEOUT" = yes ] || [ "$RUN_RC" -gt 1 ] ||
        ! raw_from_shellcheck "$TMP/shellcheck-candidate.json" "$CANDIDATE_DIR" "$RAW_CANDIDATE"; then SHELLCHECK_OK=false; fi
    fi
    if [ "$SHELLCHECK_OK" = true ]; then scanner_end shellcheck ok
    else emit_unavailable shellcheck "scan timed out, crashed, or returned malformed JSON"; scanner_end shellcheck unavailable; fi
  else
    scanner_end shellcheck unavailable
  fi
else
  not_applicable shellcheck "candidate diff has no shell script"
fi

# ruff: changed Python only.
PYTHON_RE='\.py$'
if changed_matches "$PYTHON_RE"; then
  scanner_begin
  RUFF=$(resolve_tool ruff)
  if tool_ready ruff "$RUFF" 0.16.0; then
    RUFF_OK=true
    mapfile -t PYTHON_FILES < <(list_changed "$PYTHON_RE")
    BASE_PYTHON=()
    CANDIDATE_PYTHON=()
    for file in "${PYTHON_FILES[@]}"; do
      [ "$BASELINE_AVAILABLE" = true ] && [ -f "$BASE_DIR/$file" ] && BASE_PYTHON+=("$file")
      [ -f "$CANDIDATE_DIR/$file" ] && CANDIDATE_PYTHON+=("$file")
    done
    if [ "${#BASE_PYTHON[@]}" -gt 0 ]; then
      if run_sarif_scan ruff "$RUFF" "$BASE_DIR" "$TMP/ruff-base.sarif" \
        check --no-cache --output-format sarif "${BASE_PYTHON[@]}" &&
        raw_from_sarif ruff "$TMP/ruff-base.sarif" "$BASE_DIR" "$RAW_BASE"; then :;
      else RUFF_OK=false; fi
    fi
    if [ "$RUFF_OK" = true ] && [ "${#CANDIDATE_PYTHON[@]}" -gt 0 ]; then
      if run_sarif_scan ruff "$RUFF" "$CANDIDATE_DIR" "$TMP/ruff-candidate.sarif" \
        check --no-cache --output-format sarif "${CANDIDATE_PYTHON[@]}" &&
        raw_from_sarif ruff "$TMP/ruff-candidate.sarif" "$CANDIDATE_DIR" "$RAW_CANDIDATE"; then :;
      else RUFF_OK=false; fi
    fi
    if [ "$RUFF_OK" = true ]; then scanner_end ruff ok
    else emit_unavailable ruff "${SCAN_ERROR:-malformed output}"; scanner_end ruff unavailable; fi
  else
    scanner_end ruff unavailable
  fi
else
  not_applicable ruff "candidate diff has no Python"
fi

# Add source-line content before fingerprinting. Gitleaks already supplies its
# redacted matched line; this pass only fills null content from immutable files.
enrich_content "$RAW_BASE" "${BASE_DIR:-$CANDIDATE_DIR}" "$TMP/raw-base-enriched.jsonl"
enrich_content "$RAW_CANDIDATE" "$CANDIDATE_DIR" "$TMP/raw-candidate-enriched.jsonl"
mv "$TMP/raw-base-enriched.jsonl" "$RAW_BASE"
mv "$TMP/raw-candidate-enriched.jsonl" "$RAW_CANDIDATE"

ATTRIBUTION="$TMP/attribution.json"
if [ "$BASELINE_AVAILABLE" = true ]; then
  "$SCRIPT_DIR/fm-findings-attribute.sh" --base "$RAW_BASE" --candidate "$RAW_CANDIDATE" --out "$ATTRIBUTION" ||
    refuse "baseline attributor failed"
else
  "$SCRIPT_DIR/fm-findings-attribute.sh" --candidate "$RAW_CANDIDATE" --out "$ATTRIBUTION" ||
    refuse "baseline attributor failed"
fi

REPORT="$TMP/report.json"
jq -n --arg base "$BASE" --arg candidate "$CANDIDATE" \
  --arg budget "$TOTAL_BUDGET" --slurpfile attribution "$ATTRIBUTION" \
  --slurpfile timings "$TIMINGS" '
  {
    schema:"firstmate/scanner-report/1",
    base_sha:(if $base=="" then null else $base end),
    candidate_sha:$candidate,
    baseline:$attribution[0].baseline,
    budget_s:($budget|tonumber),
    duration_ms:([$timings[].duration_ms]|add // 0),
    timings:$timings,
    findings:$attribution[0].findings
  }
' > "$REPORT" || refuse "failed to assemble scanner report"

jq -e '
  keys == ["base_sha","baseline","budget_s","candidate_sha","duration_ms","findings","schema","timings"]
  and .schema == "firstmate/scanner-report/1"
  and (.base_sha == null or (.base_sha|type) == "string")
  and (.candidate_sha|type) == "string"
  and (.baseline|keys) == ["available","warning"]
  and (.budget_s|type) == "number"
  and (.duration_ms|type) == "number"
  and (.timings|type) == "array"
  and all(.timings[];
    ((keys - ["reason"]) == ["duration_ms","scanner","status"])
    and (.scanner|type) == "string"
    and (.status == "ok" or .status == "unavailable" or .status == "not-applicable")
    and (.duration_ms|type) == "number")
  and (.findings|type) == "array"
' "$REPORT" >/dev/null || refuse "scanner report failed its closed-schema proof (FC-001)"

mkdir -p "$(dirname "$OUT")" || refuse "cannot create output directory"
TMP_OUT="$OUT.tmp.$$"
cp "$REPORT" "$TMP_OUT" || refuse "cannot stage scanner report"
mv -f "$TMP_OUT" "$OUT" || { rm -f "$TMP_OUT"; refuse "cannot publish scanner report"; }

BLOCKING=$(jq '[.findings[]|select(.blocking)]|length' "$OUT")
[ "$BLOCKING" -eq 0 ]

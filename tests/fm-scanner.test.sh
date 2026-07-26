#!/usr/bin/env bash
# Per-scanner fixtures for the Phase 1 deterministic battery.
#
# One synthetic diff carries an inherited and candidate-new finding for every
# scanner. Further loops independently replace each pinned tool with a wrong
# version and a wedging implementation, proving FC-004 and FC-006 per scanner.
#
# Set FM_TEST_REAL_GITLEAKS=1 to run the linked-worktree regression with
# $FM_SCANNER_DIR/bin/gitleaks, or set it to an explicit pinned executable path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCANNER="$ROOT/bin/fm-scanner.sh"
TMP=$(fm_test_tmproot fm-scanner)
TOOLS="$TMP/tools"
mkdir -p "$TOOLS/bin" "$TOOLS/osv-db/osv-scanner"
REAL_JQ=$(command -v jq)
export REAL_JQ

cat > "$TOOLS/bin/fake-scanner" <<'SH'
#!/usr/bin/env bash
set -u
name=$(basename "$0")
version=false
[ "${1:-}" = "--version" ] && version=true
case "$name" in
  gitleaks)
    if [ "$version" = true ]; then echo 'gitleaks version 8.30.1'; exit 0; fi
    report=""
    baseline=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --report-path) report=${2:-}; shift ;;
        --report-path=*) report=${1#*=} ;;
        --baseline-path) baseline=${2:-}; shift ;;
        --baseline-path=*) baseline=${1#*=} ;;
      esac
      shift
    done
    [ -n "$report" ] || exit 2
    full_report="$report.full"
    {
      printf '['
      comma=""
      for file in inherited-secret.txt new-secret.txt; do
        [ -f "$file" ] || continue
        if grep -q 'GITLEAKS' "$file"; then
          if [ -n "${FM_TEST_FLAKY_GITLEAKS_MARKER:-}" ] &&
            [ "$file" = new-secret.txt ]; then
            if [ -e "$FM_TEST_FLAKY_GITLEAKS_MARKER" ]; then
              continue
            fi
            : > "$FM_TEST_FLAKY_GITLEAKS_MARKER"
          fi
          printf '%s' "$comma"
          "$REAL_JQ" -nc --arg file "$file" --arg line "$(sed -n '1p' "$file")" \
            '{RuleID:"generic-api-key",File:$file,StartLine:1,Description:"potential secret",Line:$line}'
          comma=","
        fi
      done
      printf ']\n'
    } > "$full_report"
    if [ -n "$baseline" ]; then
      "$REAL_JQ" --slurpfile baseline "$baseline" '
        map(. as $candidate |
          select(any($baseline[0][]?;
            .RuleID==$candidate.RuleID
            and .File==$candidate.File
            and .Line==$candidate.Line
          )|not))
      ' "$full_report" > "$report"
    else
      mv "$full_report" "$report"
    fi
    if "$REAL_JQ" -e 'length > 0' "$report" >/dev/null; then
      exit 1
    fi
    exit 0
    ;;
  oxlint)
    if [ "$version" = true ]; then echo 'oxlint 1.75.0'; exit 0; fi
    "$REAL_JQ" -Rn '
      {runs:[{results:
        ([inputs] | map(
          {ruleId:"oxc/no-debugger",message:{text:"oxlint finding"},
           locations:[{physicalLocation:{artifactLocation:{uri:.},region:{startLine:1}}}]}))
      }]}' < <(printf '%s\n' inherited.js new.js | while read -r f; do [ -f "$f" ] && grep -q OXLINT "$f" && echo "$f"; done)
    ;;
  eslint-scanner)
    if [ "$version" = true ]; then echo '9.39.5'; exit 0; fi
    "$REAL_JQ" -n --args '$ARGS.positional | map(select(test("\\.js$")) |
      {filePath:(input_filename|sub("/dev/null";""))})' </dev/null >/dev/null 2>&1 || true
    printf '['
    comma=""
    for file in "$@"; do
      [ -f "$file" ] && grep -q ESLINT "$file" || continue
      printf '%s' "$comma"
      "$REAL_JQ" -nc --arg file "$PWD/$file" \
        '{filePath:$file,messages:[
          {ruleId:"security/detect-eval-with-expression",severity:2,line:1,message:"high-FP security heuristic"},
          {ruleId:"sonarjs/no-identical-functions",severity:2,line:1,message:"deterministic eslint error"}
        ]}'
      comma=","
    done
    printf ']\n'
    ;;
  osv-scanner)
    if [ "$version" = true ]; then echo 'osv-scanner version: 2.4.0'; exit 0; fi
    packages='[]'
    [ -f package-lock.json ] && packages='[
      {
        "package":{"name":"inherited-dep","version":"1.0.0","ecosystem":"npm"},
        "vulnerabilities":[{"id":"CVE-INHERITED"}]
      }
    ]'
    if [ -f package-lock.json ] && grep -q NEW_OSV package-lock.json; then
      packages=$("$REAL_JQ" -nc --argjson old "$packages" '$old + [
        {
          package:{name:"new-prod",version:"1.0.0",ecosystem:"npm"},
          vulnerabilities:[{id:"CVE-NEW"}]
        },
        {
          package:{name:"dev-vuln",version:"1.0.0",ecosystem:"npm"},
          vulnerabilities:[{id:"GHSA-DEV"}]
        }
      ]')
    fi
    "$REAL_JQ" -nc --arg path "$PWD/package-lock.json" --argjson packages "$packages" \
      '{results:[{source:{path:$path,type:"lockfile"},packages:$packages}]}'
    ;;
  actionlint)
    if [ "$version" = true ]; then echo '1.7.12'; exit 0; fi
    printf '['
    comma=""
    for file in "$@"; do
      case "$file" in -*) continue ;; esac
      [ -f "$file" ] && grep -q ACTIONLINT "$file" || continue
      printf '%s' "$comma"
      "$REAL_JQ" -nc --arg file "$file" \
        '{kind:"syntax-check",filepath:$file,line:1,message:"actionlint finding"}'
      comma=","
    done
    printf ']\n'
    ;;
  jq)
    if [ "$version" = true ]; then echo 'jq-1.7.1'; exit 0; fi
    file=${@: -1}
    if grep -q JQ_FINDING "$file" 2>/dev/null; then echo 'parse error' >&2; exit 1; fi
    exec "$REAL_JQ" "$@"
    ;;
  json-schema-scanner)
    if [ "$version" = true ]; then echo 'ajv 8.17.1'; exit 0; fi
    document=${2:-}
    if grep -q INVALID_SCHEMA "$document" 2>/dev/null; then
      "$REAL_JQ" -nc --arg path "$document" '[{path:$path,message:"/value must be an integer"}]'
      exit 1
    fi
    printf '[]\n'
    ;;
  shellcheck)
    if [ "$version" = true ]; then
      printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
      exit 0
    fi
    printf '['
    comma=""
    for file in "$@"; do
      case "$file" in -*) continue ;; esac
      [ -f "$file" ] && grep -q SHELLCHECK "$file" || continue
      printf '%s' "$comma"
      "$REAL_JQ" -nc --arg file "$file" \
        '{file:$file,line:1,code:2086,level:"error",message:"shellcheck finding"}'
      comma=","
    done
    printf ']\n'
    ;;
  ruff)
    if [ "$version" = true ]; then echo 'ruff 0.16.0'; exit 0; fi
    printf '{"runs":[{"results":['
    comma=""
    for file in "$@"; do
      case "$file" in -*) continue ;; esac
      [ -f "$file" ] && grep -q RUFF "$file" || continue
      printf '%s' "$comma"
      "$REAL_JQ" -nc --arg file "$file" \
        '{ruleId:"F821",message:{text:"ruff finding"},
          locations:[{physicalLocation:{artifactLocation:{uri:$file},region:{startLine:1}}}]}'
      comma=","
    done
    printf ']}]}\n'
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$TOOLS/bin/fake-scanner"
for scanner in gitleaks oxlint eslint-scanner osv-scanner actionlint jq json-schema-scanner shellcheck ruff; do
  ln -s fake-scanner "$TOOLS/bin/$scanner"
done
cat > "$TOOLS/bin/claude" <<'SH'
#!/usr/bin/env bash
set -u
prompt=$(mktemp)
sed -n '2,$p' | sed '$d' > "$prompt"
"$REAL_JQ" '{
  structured_output:{
    results:[
      .untrusted_clusters[].findings[] |
      if .scanner=="osv-scanner" then
        {
          fingerprint,verdict:"demote-to-report",reason_code:"dev-only-package",
          reason:"The cited package is positively marked dev-only.",
          evidence:{source:"hunk",quote:"\"dev\":true"}
        }
      else
        {
          fingerprint,verdict:"confirm",reason_code:null,reason:null,evidence:null
        }
      end
    ]
  }
}' "$prompt"
rm -f "$prompt"
SH
chmod +x "$TOOLS/bin/claude"

REPO="$TMP/repo"
git init -q "$REPO"
git -C "$REPO" checkout -q -b main
mkdir -p "$REPO/.github/workflows"
printf 'INHERITED_GITLEAKS\n' > "$REPO/inherited-secret.txt"
printf 'INHERITED_OXLINT ESLINT\n' > "$REPO/inherited.js"
printf '# ACTIONLINT inherited\nname: inherited\non: push\njobs: {}\n' > "$REPO/.github/workflows/inherited.yml"
printf '{"marker":"JQ_FINDING"}\n' > "$REPO/inherited.json"
printf '# SHELLCHECK inherited\ntrue\n' > "$REPO/inherited.sh"
printf '# RUFF inherited\nvalue = 1\n' > "$REPO/inherited.py"
printf '{"lockfileVersion":3,"marker":"INHERITED_OSV"}\n' > "$REPO/package-lock.json"
git -C "$REPO" add -A
git -C "$REPO" commit -qm base
BASE=$(git -C "$REPO" rev-parse HEAD)

git -C "$REPO" checkout -q -b fm/scanner
printf '// candidate edit\n' >> "$REPO/inherited.js"
printf '# candidate edit\n' >> "$REPO/.github/workflows/inherited.yml"
printf ' ' >> "$REPO/inherited.json"
printf '# candidate edit\n' >> "$REPO/inherited.sh"
printf '# candidate edit\n' >> "$REPO/inherited.py"
printf '{"lockfileVersion":3,"marker":"INHERITED_OSV NEW_OSV","packages":{"node_modules/dev-vuln":{"dev":true}}}\n' > "$REPO/package-lock.json"
printf 'NEW_GITLEAKS\n' > "$REPO/new-secret.txt"
printf 'const command = "SAFE_COMMAND"; // NEW_OXLINT ESLINT\n' > "$REPO/new.js"
printf '# ACTIONLINT new\nname: new\non: push\njobs: {}\n' > "$REPO/.github/workflows/new.yml"
printf '{"marker":"JQ_FINDING"}\n' > "$REPO/new.json"
printf '# SHELLCHECK new\ntrue\n' > "$REPO/new.sh"
printf '# RUFF new\nvalue = 2\n' > "$REPO/new.py"
git -C "$REPO" add -A
git -C "$REPO" commit -qm candidate
CANDIDATE=$(git -C "$REPO" rev-parse HEAD)

run_scanner() {
  local tool_dir=$1 out=$2
  shift 2
  FM_SCANNER_DIR="$tool_dir" FM_VERIFY_SCANNER_TIMEOUT="${FM_VERIFY_SCANNER_TIMEOUT:-2}" \
    FM_VERIFY_SCANNER_BUDGET="${FM_VERIFY_SCANNER_BUDGET:-30}" \
    FM_SCANNER_ADJUDICATOR_CLI="$tool_dir/bin/claude" \
    FM_SCANNER_ADJUDICATOR_AUDIT_SEED=scanner-fixture \
    "$SCANNER" --repo "$REPO" --base "$BASE" --candidate "$CANDIDATE" --out "$out" "$@" >/dev/null 2>&1
}

OUT="$TMP/report.json"
run_scanner "$TOOLS" "$OUT"
expect_code 1 "$?" "synthetic diff with candidate-new findings fails"
[ "$(jq '.timings|length' "$OUT")" -eq 8 ] || fail "scanner report did not time all eight battery members"
[ "$(jq '[.timings[].budget_s]|add' "$OUT")" -lt 30 ] ||
  fail "committed per-scanner budgets leave no reserve inside the 30s battery budget"
[ "$(jq '[.timings[].budget_s]|unique|length' "$OUT")" -gt 1 ] ||
  fail "scanner timings do not expose distinct per-scanner budgets"
[ "$(jq '.duration_ms' "$OUT")" -lt 30000 ] || fail "scanner fixture exceeded the 30s gate budget"
for scanner in gitleaks oxlint eslint osv-scanner actionlint jq shellcheck ruff; do
  [ "$(jq --arg scanner "$scanner" '[.findings[]|select(.scanner==$scanner and .attribution=="candidate-new" and .blocking)]|length' "$OUT")" -gt 0 ] ||
    fail "$scanner did not fire on its real candidate fixture"
  [ "$(jq --arg scanner "$scanner" '[.findings[]|select(.scanner==$scanner and .attribution=="inherited" and (.blocking|not))]|length' "$OUT")" -gt 0 ] ||
    fail "$scanner did not exclude its inherited fixture"
done
[ "$(jq '[.findings[]|select(
    .scanner=="eslint"
    and (.rule_id|startswith("security/"))
    and .adjudication.verdict=="confirm"
    and .policy_decision=="block"
    and .blocking
  )]|length' "$OUT")" -gt 0 ] ||
  fail "uncorroborated eslint-plugin-security finding did not retain its block"
pass "severity policy: uncorroborated security findings remain blocking"
[ "$(jq '[.findings[]|select(
    .scanner=="osv-scanner"
    and (.rule_id|startswith("dev-dependency/"))
    and .adjudication.verdict=="demote-to-report"
    and .policy_decision=="report-only"
    and (.blocking|not)
    and .adjudication.corroboration.kind=="candidate-package-lock-dev-scope"
    and .subject.name=="dev-vuln"
    and .subject.advisory_id=="GHSA-DEV"
    and .adjudication.corroboration.subject==.subject
    and .adjudication.corroboration.finding_fingerprint==.fingerprint
  )]|length' "$OUT")" -eq 1 ] ||
  fail "positively proven OSV dev dependency lacked machine-owned corroboration"
pass "OSV dev-dependency scope is proven from package-lock before demotion"
pass "every Phase 1 scanner fires on a real fixture and excludes its inherited baseline finding"

run_scanner "$TOOLS" "$TMP/full-report.json" --scope full
expect_code 1 "$?" "full-scope scan with the same findings fails"
jq -S '[.findings[]|{
  scanner,rule_id,path,line,attribution,blocking,policy_decision,stability
}]|sort_by(.scanner,.rule_id,.path,.line)' "$OUT" > "$TMP/diff-findings.json"
jq -S '[.findings[]|{
  scanner,rule_id,path,line,attribution,blocking,policy_decision,stability
}]|sort_by(.scanner,.rule_id,.path,.line)' "$TMP/full-report.json" > "$TMP/full-findings.json"
cmp -s "$TMP/diff-findings.json" "$TMP/full-findings.json" ||
  fail "diff-scoped findings diverged from full-scope findings on touched surfaces"
pass "incremental equivalence: diff and full scope produce the same touched-surface findings"

FM_TEST_FLAKY_GITLEAKS_MARKER="$TMP/flaky-gitleaks-observed"
export FM_TEST_FLAKY_GITLEAKS_MARKER
rm -f "$FM_TEST_FLAKY_GITLEAKS_MARKER"
run_scanner "$TOOLS" "$TMP/flaky-report.json"
expect_code 1 "$?" "other stable blocking findings still fail the flaky fixture"
[ "$(jq '[.findings[]|select(
    .scanner=="gitleaks"
    and .path=="new-secret.txt"
    and .policy_decision=="report-only"
    and .stability=="unconfirmed"
    and (.policy_reason|contains("nondeterministic"))
  )]|length' "$TMP/flaky-report.json")" -eq 1 ] ||
  fail "a one-run-only blocking-tier finding was not downgraded with a nondeterminism note"
unset FM_TEST_FLAKY_GITLEAKS_MARKER
pass "nondeterminism: blocking-tier findings require a repeat-run confirmation"

MAIN_REPO=$REPO
MAIN_BASE=$BASE
MAIN_CANDIDATE=$CANDIDATE
REPO="$TMP/schema-repo"
git init -q "$REPO"
git -C "$REPO" checkout -q -b main
cat > "$REPO/.fm-scanner-schemas.json" <<'JSON'
{"schema":"firstmate/scanner-schema-map/1","mappings":[{"path":"document.json","schema_path":"schema.json"}]}
JSON
cat > "$REPO/schema.json" <<'JSON'
{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","properties":{"value":{"type":"integer"}},"required":["value"],"additionalProperties":false}
JSON
printf '{"value":1}\n' > "$REPO/document.json"
git -C "$REPO" add -A
git -C "$REPO" commit -qm base
BASE=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q -b fm/schema
printf '{"value":"INVALID_SCHEMA"}\n' > "$REPO/document.json"
git -C "$REPO" commit -qam invalid
CANDIDATE=$(git -C "$REPO" rev-parse HEAD)
run_scanner "$TOOLS" "$TMP/schema-report.json"
expect_code 1 "$?" "declared schema violation fails"
[ "$(jq '[.findings[]|select(.scanner=="jq" and .rule_id=="declared-schema" and .attribution=="candidate-new" and .blocking)]|length' "$TMP/schema-report.json")" -eq 1 ] ||
  fail "jq scanner did not validate a changed document against its declared schema"
pass "jq scanner enforces changed documents against closed schema declarations"

REPO="$TMP/json-values-repo"
git init -q "$REPO"
git -C "$REPO" checkout -q -b main
printf 'base\n' > "$REPO/seed.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm base
BASE=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q -b fm/json-values
printf '{"ok":true}\n' > "$REPO/object.json"
printf '[1,2,3]\n' > "$REPO/array.json"
printf '"scalar"\n' > "$REPO/scalar.json"
printf 'false\n' > "$REPO/false.json"
printf 'null\n' > "$REPO/null.json"
printf 'false\nnull\n{"ok":true}\n' > "$REPO/records.jsonl"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "add valid JSON values"
CANDIDATE=$(git -C "$REPO" rev-parse HEAD)
run_scanner "$TOOLS" "$TMP/json-values-report.json"
expect_code 0 "$?" "every valid JSON top-level value passes parse-only validation"
[ "$(jq '[.findings[]|select(.scanner=="jq" and .rule_id=="well-formedness")]|length' \
  "$TMP/json-values-report.json")" -eq 0 ] ||
  fail "valid false, null, scalar, collection, or JSONL values were reported malformed"
pass "jq parse-only validation accepts false, null, scalars, collections, and JSONL records"

REPO=$MAIN_REPO
BASE=$MAIN_BASE
CANDIDATE=$MAIN_CANDIDATE

for scanner in gitleaks oxlint eslint-scanner osv-scanner actionlint jq shellcheck ruff; do
  broken="$TMP/missing-$scanner"
  cp -R "$TOOLS" "$broken"
  target=$scanner
  report_name=$scanner
  [ "$scanner" = eslint-scanner ] && report_name=eslint
  rm -f "$broken/bin/$target"
  printf '#!/usr/bin/env bash\necho wrong-version\n' > "$broken/bin/$target"
  chmod +x "$broken/bin/$target"
  run_scanner "$broken" "$TMP/missing-$scanner.json"
  expect_code 1 "$?" "$report_name missing/wrong pin fails closed"
  [ "$(jq --arg scanner "$report_name" '[.findings[]|select(.scanner==$scanner and .rule_id=="scanner-unavailable")]|length' "$TMP/missing-$scanner.json")" -eq 1 ] ||
    fail "$report_name missing/wrong pin did not yield exactly one scanner-unavailable finding"
done
pass "FC-004: every scanner independently fails closed with one unavailable finding"

crashed="$TMP/crashed-gitleaks"
cp -R "$TOOLS" "$crashed"
rm -f "$crashed/bin/gitleaks"
cat > "$crashed/bin/gitleaks" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'gitleaks version 8.30.1\n'
  exit 0
fi
exit 2
SH
chmod +x "$crashed/bin/gitleaks"
run_scanner "$crashed" "$TMP/crashed-gitleaks.json"
expect_code 1 "$?" "a genuine gitleaks crash fails closed"
[ "$(jq '[.findings[]|select(.scanner=="gitleaks" and .rule_id=="scanner-unavailable")]|length' \
  "$TMP/crashed-gitleaks.json")" -eq 1 ] ||
  fail "a genuine gitleaks crash did not yield scanner-unavailable"
pass "FC-004: a genuine gitleaks crash remains fail-closed"

for scanner in gitleaks oxlint eslint-scanner osv-scanner actionlint jq shellcheck ruff; do
  wedged="$TMP/wedged-$scanner"
  cp -R "$TOOLS" "$wedged"
  target=$scanner
  report_name=$scanner
  [ "$scanner" = eslint-scanner ] && report_name=eslint
  rm -f "$wedged/bin/$target"
  case "$scanner" in
    gitleaks) version='gitleaks version 8.30.1' ;;
    oxlint) version='oxlint 1.75.0' ;;
    eslint-scanner) version='9.39.5' ;;
    osv-scanner) version='osv-scanner version: 2.4.0' ;;
    actionlint) version='1.7.12' ;;
    jq) version='jq-1.7.1' ;;
    shellcheck) version='version: 0.11.0' ;;
    ruff) version='ruff 0.16.0' ;;
  esac
  {
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016  # writes a literal positional-parameter probe
    printf 'if [ "${1:-}" = "--version" ]; then printf "%%s\\\\n" %q; exit 0; fi\n' "$version"
    printf 'sleep 5\n'
  } > "$wedged/bin/$target"
  chmod +x "$wedged/bin/$target"
  start=$SECONDS
  FM_VERIFY_SCANNER_TIMEOUT=1 FM_VERIFY_SCANNER_BUDGET=30 run_scanner "$wedged" "$TMP/wedged-$scanner.json"
  expect_code 1 "$?" "$report_name timeout fails closed"
  elapsed=$((SECONDS - start))
  [ "$elapsed" -lt 12 ] || fail "$report_name exceeded its portable deadline (${elapsed}s)"
  [ "$(jq --arg scanner "$report_name" '[.findings[]|select(.scanner==$scanner and .rule_id=="scanner-unavailable")]|length' "$TMP/wedged-$scanner.json")" -eq 1 ] ||
    fail "$report_name timeout did not yield exactly one scanner-unavailable finding"
  [ "$(jq --arg scanner "$report_name" '[.timings[]|select(.scanner!=$scanner and .status=="unavailable")]|length' "$TMP/wedged-$scanner.json")" -eq 0 ] ||
    fail "$report_name exhausted another scanner's reserved time slice"
done
pass "FC-006/G9: each scanner has a reserved budget and exhaustion stays local and loud"

real_gitleaks=${FM_TEST_REAL_GITLEAKS:-}
if [ "$real_gitleaks" = 1 ]; then
  [ -n "${FM_SCANNER_DIR:-}" ] ||
    fail "FM_TEST_REAL_GITLEAKS=1 requires FM_SCANNER_DIR"
  real_gitleaks="$FM_SCANNER_DIR/bin/gitleaks"
fi
if [ -n "$real_gitleaks" ]; then
  [ -x "$real_gitleaks" ] ||
    fail "FM_TEST_REAL_GITLEAKS does not name an executable"
  "$real_gitleaks" --version | grep -Fq '8.30.1' ||
    fail "FM_TEST_REAL_GITLEAKS is not the pinned gitleaks 8.30.1"

  real_tools="$TMP/real-gitleaks-tools"
  cp -R "$TOOLS" "$real_tools"
  rm -f "$real_tools/bin/gitleaks"
  ln -s "$real_gitleaks" "$real_tools/bin/gitleaks"

  real_origin="$TMP/real-gitleaks-origin"
  real_worktree="$TMP/real-gitleaks-worktree"
  git init -q "$real_origin"
  git -C "$real_origin" checkout -q -b main
  fm_git_identity
  printf 'clean baseline\n' > "$real_origin/fixture.txt"
  git -C "$real_origin" add fixture.txt
  git -C "$real_origin" commit -qm "clean baseline"
  git -C "$real_origin" worktree add --detach --quiet "$real_worktree" HEAD
  [ -f "$real_worktree/.git" ] ||
    fail "real gitleaks sandbox is not a linked worktree with a gitdir pointer"

  REPO=$real_worktree
  BASE=$(git -C "$REPO" rev-parse HEAD)
  printf 'clean candidate\n' >> "$REPO/fixture.txt"
  git -C "$REPO" commit -qam "clean candidate"
  CANDIDATE=$(git -C "$REPO" rev-parse HEAD)
  FM_VERIFY_SCANNER_TIMEOUT=8 run_scanner "$real_tools" "$TMP/real-gitleaks-clean.json"
  expect_code 0 "$?" "real pinned gitleaks accepts the clean linked-worktree candidate"
  [ "$(jq '[.findings[]|select(.scanner=="gitleaks")]|length' \
    "$TMP/real-gitleaks-clean.json")" -eq 0 ] ||
    fail "real pinned gitleaks clean linked-worktree fixture produced a finding"
  [ "$(jq '[.findings[]|select(.scanner=="gitleaks" and .rule_id=="scanner-unavailable")]|length' \
    "$TMP/real-gitleaks-clean.json")" -eq 0 ] ||
    fail "real pinned gitleaks was unavailable in the clean linked-worktree fixture"

  fixture_left='aB3dE5fG7hI9jK1mN3pQ5rS7'
  fixture_right='tU9vW1xY'
  printf 'api_key = "%s%s"\n' "$fixture_left" "$fixture_right" > "$REPO/seeded-secret.txt"
  git -C "$REPO" add seeded-secret.txt
  git -C "$REPO" commit -qm "seed gitleaks fixture"
  BASE=$CANDIDATE
  CANDIDATE=$(git -C "$REPO" rev-parse HEAD)
  FM_VERIFY_SCANNER_TIMEOUT=8 run_scanner "$real_tools" "$TMP/real-gitleaks-secret.json"
  expect_code 1 "$?" "real pinned gitleaks finding blocks the linked-worktree candidate"
  [ "$(jq '[.findings[]|select(
      .scanner=="gitleaks"
      and .rule_id!="scanner-unavailable"
      and .path=="seeded-secret.txt"
      and .attribution=="candidate-new"
      and .blocking
    )]|length' "$TMP/real-gitleaks-secret.json")" -eq 1 ] ||
    fail "real pinned gitleaks did not normalize the seeded linked-worktree secret"
  [ "$(jq '[.findings[]|select(.scanner=="gitleaks" and .rule_id=="scanner-unavailable")]|length' \
    "$TMP/real-gitleaks-secret.json")" -eq 0 ] ||
    fail "real pinned gitleaks finding was inverted into scanner-unavailable"
  pass "FC-001: real pinned gitleaks maps linked-worktree clean/finding exit semantics"
else
  echo "skip: set FM_TEST_REAL_GITLEAKS to run the pinned linked-worktree regression"
fi

echo "# all fm-scanner tests passed"

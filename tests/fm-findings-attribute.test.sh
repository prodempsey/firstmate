#!/usr/bin/env bash
# Closed-schema and missing-baseline tests for the generic Shakedown attributor.
#
# FC-001 (closed-schema positive proof): A conclusion may be drawn only from ONE atomic pass that positively proves conformance to a single declared, closed schema; authority defaults to none and is NEVER inferred from the absence of a failing check.
# FC-002 (absence is never discharge): An obligation is cleared ONLY by positive proof from a fresh, structurally-complete, authoritative snapshot that provably enumerates that obligation's status; absent/stale/corrupt/partial coverage RETAINS the prior fact unchanged (fail-open when CREATING a block, fail-closed when DISCHARGING one).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ATTRIBUTOR="$ROOT/bin/fm-findings-attribute.sh"
TMP=$(fm_test_tmproot fm-findings-attribute)
BASE="$TMP/base.jsonl"
CANDIDATE="$TMP/candidate.jsonl"
OUT="$TMP/report.json"

raw() {
  jq -nc --arg scanner "$1" --arg rule "$2" --arg path "$3" --arg content "$4" '
    {schema:"firstmate/scanner-raw-finding/1",scanner:$scanner,rule_id:$rule,
     severity:"error",path:$path,line:1,message:("finding "+$rule),content:$content}'
}

raw shellcheck SC1007 script.sh 'local a= b=' > "$BASE"
raw shellcheck SC1007 script.sh 'local a= b=' > "$CANDIDATE"
raw shellcheck SC2086 new.sh 'echo unquoted-value' >> "$CANDIDATE"
cp "$CANDIDATE" "$TMP/confirmation.jsonl"
"$ATTRIBUTOR" --base "$BASE" --candidate "$CANDIDATE" \
  --confirmation "$TMP/confirmation.jsonl" --out "$OUT"

[ "$(jq -r '.schema' "$OUT")" = firstmate/scanner-attribution/1 ] ||
  fail "attributor report schema is not closed and declared"
[ "$(jq '[.findings[]|select(.attribution=="inherited" and .blocking==false)]|length' "$OUT")" -eq 1 ] ||
  fail "normalized inherited finding was not excluded from blocking"
[ "$(jq '[.findings[]|select(.attribution=="candidate-new" and .blocking==true)]|length' "$OUT")" -eq 1 ] ||
  fail "candidate-new finding did not remain blocking"
pass "generic attribution separates inherited from candidate-new findings"

# A fingerprint is closed over scanner identity as well as rule, path, and
# normalized content.
raw base-scanner same-rule same.txt 'same source' > "$TMP/cross-scanner-base.jsonl"
raw candidate-scanner same-rule same.txt 'same source' > "$TMP/cross-scanner-candidate.jsonl"
"$ATTRIBUTOR" --base "$TMP/cross-scanner-base.jsonl" \
  --candidate "$TMP/cross-scanner-candidate.jsonl" \
  --confirmation "$TMP/cross-scanner-candidate.jsonl" --out "$TMP/cross-scanner.json"
[ "$(jq '[.findings[]|select(
    .scanner=="candidate-scanner"
    and .attribution=="candidate-new"
    and .blocking==true
  )]|length' "$TMP/cross-scanner.json")" -eq 1 ] ||
  fail "a base finding from another scanner suppressed a candidate-new finding"
pass "FC-001: scanner identity is part of every attribution fingerprint"

raw gitleaks duplicate-secret secrets.txt 'same secret line' > "$TMP/duplicates.jsonl"
raw gitleaks duplicate-secret secrets.txt 'same secret line' |
  jq '.line=9' >> "$TMP/duplicates.jsonl"
"$ATTRIBUTOR" --candidate "$TMP/duplicates.jsonl" \
  --confirmation "$TMP/duplicates.jsonl" --out "$TMP/duplicates-report.json"
[ "$(jq '[.findings[]|select(.scanner=="gitleaks" and .rule_id=="duplicate-secret")]|length' \
  "$TMP/duplicates-report.json")" -eq 2 ] ||
  fail "distinct identical-content occurrences collapsed into one finding"
[ "$(jq '[.findings[].occurrence]|unique|length' "$TMP/duplicates-report.json")" -eq 2 ] ||
  fail "identical-content occurrences did not receive distinct occurrence identities"
pass "G6: occurrence identity preserves distinct identical-content findings"

GOLDEN="$ROOT/tests/fixtures/scanner-golden.json"
jq -e '
  keys==["cases","schema"]
  and .schema=="firstmate/scanner-golden/1"
  and (.cases|length)==30
  and (([.cases[].id]|length)==([.cases[].id]|unique|length))
' "$GOLDEN" >/dev/null || fail "minimal scanner golden set is not closed, unique, and exactly 30 cases"
jq -c '.cases[]|{
  schema:"firstmate/scanner-raw-finding/1",
  scanner,rule_id,severity,path,line,message:.id,content
}' "$GOLDEN" > "$TMP/golden-candidate.jsonl"
jq -c '.cases[]|select(.base_content!=null)|{
  schema:"firstmate/scanner-raw-finding/1",
  scanner,rule_id,severity,path,line,message:.id,content:.base_content
}' "$GOLDEN" > "$TMP/golden-base.jsonl"
jq -c '.cases[]|select(.confirm)|{
  schema:"firstmate/scanner-raw-finding/1",
  scanner,rule_id,severity,path,line,message:.id,content
}' "$GOLDEN" > "$TMP/golden-confirmation.jsonl"
"$ATTRIBUTOR" --base "$TMP/golden-base.jsonl" \
  --candidate "$TMP/golden-candidate.jsonl" \
  --confirmation "$TMP/golden-confirmation.jsonl" --out "$TMP/golden-report.json"
jq -e --slurpfile golden "$GOLDEN" '
  . as $report
  |
  (.findings|length)==30
  and all($golden[0].cases[];
    . as $case
    | any($report.findings[];
      .message==$case.id
      and .attribution==$case.expected_attribution
      and .policy_decision==$case.expected_decision
      and .blocking==$case.expected_blocking))
' "$TMP/golden-report.json" >/dev/null ||
  fail "minimal golden set disposition diverged from its 30 human labels"
pass "Phase 1 golden set: all 30 labeled findings retain blocking/report/inherited disposition"

"$ATTRIBUTOR" --candidate "$CANDIDATE" --confirmation "$TMP/confirmation.jsonl" \
  --out "$TMP/unattributed.json"
[ "$(jq -r '.baseline.available' "$TMP/unattributed.json")" = false ] ||
  fail "missing baseline was incorrectly treated as available"
[ "$(jq '[.findings[]|select(.attribution=="unattributed" and .blocking==true)]|length' "$TMP/unattributed.json")" -eq 2 ] ||
  fail "missing baseline suppressed candidate findings instead of retaining them"
jq -e '.baseline.warning|contains("FC-002")' "$TMP/unattributed.json" >/dev/null ||
  fail "missing baseline did not produce the FC-002 warning"
pass "FC-002: missing baseline keeps every candidate finding unattributed and blocking"

jq '.unexpected=true' "$CANDIDATE" > "$TMP/open-schema.jsonl"
"$ATTRIBUTOR" --candidate "$TMP/open-schema.jsonl" \
  --confirmation "$TMP/confirmation.jsonl" --out "$TMP/invalid.json" >/dev/null 2>&1
expect_code 2 "$?" "open-schema candidate input refuses"
pass "FC-001: an undeclared finding field is refused before attribution"

echo "# all fm-findings-attribute tests passed"

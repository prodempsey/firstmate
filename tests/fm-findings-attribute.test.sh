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
raw shellcheck SC1007 script.sh 'local   a=    b=' > "$CANDIDATE"
raw shellcheck SC2086 new.sh 'echo unquoted-value' >> "$CANDIDATE"
"$ATTRIBUTOR" --base "$BASE" --candidate "$CANDIDATE" --out "$OUT"

[ "$(jq -r '.schema' "$OUT")" = firstmate/scanner-attribution/1 ] ||
  fail "attributor report schema is not closed and declared"
[ "$(jq '[.findings[]|select(.attribution=="inherited" and .blocking==false)]|length' "$OUT")" -eq 1 ] ||
  fail "normalized inherited finding was not excluded from blocking"
[ "$(jq '[.findings[]|select(.attribution=="candidate-new" and .blocking==true)]|length' "$OUT")" -eq 1 ] ||
  fail "candidate-new finding did not remain blocking"
pass "generic attribution separates inherited from candidate-new findings"

"$ATTRIBUTOR" --candidate "$CANDIDATE" --out "$TMP/unattributed.json"
[ "$(jq -r '.baseline.available' "$TMP/unattributed.json")" = false ] ||
  fail "missing baseline was incorrectly treated as available"
[ "$(jq '[.findings[]|select(.attribution=="unattributed" and .blocking==true)]|length' "$TMP/unattributed.json")" -eq 2 ] ||
  fail "missing baseline suppressed candidate findings instead of retaining them"
jq -e '.baseline.warning|contains("FC-002")' "$TMP/unattributed.json" >/dev/null ||
  fail "missing baseline did not produce the FC-002 warning"
pass "FC-002: missing baseline keeps every candidate finding unattributed and blocking"

jq '.unexpected=true' "$CANDIDATE" > "$TMP/open-schema.jsonl"
"$ATTRIBUTOR" --candidate "$TMP/open-schema.jsonl" --out "$TMP/invalid.json" >/dev/null 2>&1
expect_code 2 "$?" "open-schema candidate input refuses"
pass "FC-001: an undeclared finding field is refused before attribution"

echo "# all fm-findings-attribute tests passed"

#!/usr/bin/env bash
# Closed-ledger, captain dismissal, and Seasoning graduation tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LEARNING="$ROOT/bin/fm-scanner-learning.sh"
VALIDATOR="$ROOT/bin/fm-dismissal-validate.sh"
# shellcheck source=bin/fm-dismissal-lib.sh
. "$ROOT/bin/fm-dismissal-lib.sh"
TMP=$(fm_test_tmproot fm-scanner-learning)
REPO="$TMP/repo"
LEDGER="$TMP/dismissals.jsonl"
mkdir -p "$REPO/src"
git init -q "$REPO"
git -C "$REPO" checkout -q -b main
printf 'one\ntwo\nthree\n' > "$REPO/src/example.js"
git -C "$REPO" add -A
git -C "$REPO" commit -qm seed
CANDIDATE=$(git -C "$REPO" rev-parse HEAD)

ln -s "$ROOT" "$TMP/root-alias"
[ "$(fm_scanner_stack_fingerprint "$ROOT")" = \
  "$(fm_scanner_stack_fingerprint "$TMP/root-alias")" ] ||
  fail "scanner-stack fingerprint changed across checkout paths"
pass "scanner-stack provenance is content-bound and checkout-path independent"

finding() {
  local fingerprint=$1 line=$2 verdict=$3
  jq -nc --arg fingerprint "$fingerprint" --arg line "$line" --arg verdict "$verdict" '{
    schema:"firstmate/scanner-raw-finding/1",
    scanner:"eslint",
    rule_id:"security/repeated-sink",
    severity:"error",
    path:"src/example.js",
    line:($line|tonumber),
    message:"scanner-owned display text",
    subject:null,
    occurrence:($line|tonumber),
    fingerprint:$fingerprint,
    attribution:"candidate-new",
    blocking:true,
    policy_decision:"block",
    policy_reason:"test policy",
    stability:"confirmed",
    adjudication:{
      status:"adjudicated",
      verdict:$verdict,
      reason_code:null,
      reason:null,
      evidence:null,
      corroboration:null,
      audit_sampled:false,
      cluster_id:null,
      dismissal_id:null,
      pre_blocking:true,
      pre_policy_decision:"block"
    }
  }'
}

{
  finding "$(printf one | sha256sum | awk '{print $1}')" 1 confirm
  finding "$(printf two | sha256sum | awk '{print $1}')" 2 confirm
  finding "$(printf three | sha256sum | awk '{print $1}')" 3 confirm
} | jq -s --arg candidate "$CANDIDATE" '{
  schema:"firstmate/scanner-report/3",
  candidate_sha:$candidate,
  findings:.
}' > "$TMP/bundle.json"

: > "$LEDGER"
FIRST_FP=$(jq -r '.findings[0].fingerprint' "$TMP/bundle.json")
REVIEW_AFTER=$(python3 -c '
import datetime
print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=90))
      .strftime("%Y-%m-%dT%H:%M:%SZ"))
')
"$LEARNING" dismiss --bundle "$TMP/bundle.json" --fingerprint "$FIRST_FP" \
  --scope rule --path-prefix src/ --reason accepted-risk --by captain \
  --actor captain --evidence captain-order:ORD-301 \
  --review-after "$REVIEW_AFTER" --repo "$REPO" --ledger "$LEDGER" \
  > "$TMP/captain-event.json"
"$VALIDATOR" prove "$LEDGER" > "$TMP/proven.json" ||
  fail "captain dismissal did not pass the shared validator"
jq -e --arg fingerprint "$FIRST_FP" --arg review_after "$REVIEW_AFTER" '
  length==1
  and .[0].finding_fingerprint==$fingerprint
  and .[0].scope=={kind:"rule",path_prefix:"src/"}
  and .[0].reason_code=="accepted-risk"
  and .[0].dismissed_by=={kind:"captain",actor:"captain"}
  and .[0].review_after==$review_after
' "$TMP/proven.json" >/dev/null ||
  fail "captain-facing dismiss surface lost scope, taxonomy, actor, or expiry"
pass "captain dismiss records a narrow, expiring, fingerprint-keyed event"

BEFORE=$(sha256sum "$LEDGER" | awk '{print $1}')
"$LEARNING" dismiss --bundle "$TMP/bundle.json" --fingerprint "$FIRST_FP" \
  --scope path --reason accepted-risk --review-after 2999-01-01T00:00:00Z \
  --repo "$REPO" --ledger "$LEDGER" >/dev/null 2>&1
expect_code 1 "$?" "writer refuses dismissal beyond the 180-day review ceiling"
AFTER=$(sha256sum "$LEDGER" | awk '{print $1}')
[ "$BEFORE" = "$AFTER" ] || fail "failed dismissal changed the ledger"
pass "overlong dismissal is refused and leaves the ledger byte-identical"

printf '%s\n' '{"schema":"firstmate/scanner-dismissal-event/1","id":"x","id":"y"}' \
  > "$TMP/duplicate.jsonl"
"$VALIDATOR" prove "$TMP/duplicate.jsonl" > "$TMP/dup.out" 2> "$TMP/dup.err"
expect_code 1 "$?" "raw duplicate member is refused"
assert_grep "DISMISSAL_LEDGER_INVALID" "$TMP/dup.err" \
  "duplicate-member refusal marker"

NO_JSONSCHEMA=$(fm_test_pythonpath_no_jsonschema "$TMP/no-jsonschema")
PYTHONPATH="$NO_JSONSCHEMA" "$VALIDATOR" prove "$LEDGER" \
  > "$TMP/no-schema.out" 2> "$TMP/no-schema.err"
expect_code 1 "$?" "missing jsonschema refuses"
assert_grep "DISMISSAL_VALIDATOR_UNAVAILABLE" "$TMP/no-schema.err" \
  "missing-validator refusal marker"
pass "dismissal validator rejects duplicate members and missing jsonschema"

"$LEARNING" propose --bundle "$TMP/bundle.json" \
  --scanner eslint --rule security/repeated-sink \
  --id FC-999 --name "Repeated scanner sink" \
  --invariant "Every repeated confirmed sink is governed by one structural rule." \
  --fix "Add a sound executable detection cue after captain approval." \
  --cue "scanner eslint repeatedly confirms security/repeated-sink" \
  --out "$TMP/seasoning-proposal.jsonl" > "$TMP/propose.out"
FM_FC_LEDGER="$TMP/seasoning-proposal.jsonl" \
  "$ROOT/bin/fm-failure-class.sh" validate >/dev/null ||
  fail "graduation path did not emit a valid Seasoning class-defined event"
jq -e '
  .event=="class-defined"
  and .id=="FC-999"
  and (.provenance|length)==3
  and all(.provenance[]; .type=="scanner-confirmation")
' "$TMP/seasoning-proposal.jsonl" >/dev/null ||
  fail "Seasoning proposal lost its three independent confirmation proofs"
pass "three unique confirmed findings graduate into a captain-gated Seasoning proposal"

echo "# all fm-scanner-learning tests passed"

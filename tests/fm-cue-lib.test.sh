#!/usr/bin/env bash
# tests/fm-cue-lib.test.sh - the ONE detection-cue validator (bin/fm-cue-lib.sh) that both the
# sanctioned writer (bin/fm-failure-class.sh) and the live reader (bin/fm-verify.sh) share.
# fm_validate_cue_row proves, in one atomic pass, that a row (a) is a JSON object, (b) conforms
# to the closed schema (engine in the supported set, non-empty string pattern and cue_ref), and
# (c) actually COMPILES under the engine that will execute it. Anything else is one fail-closed
# verdict - never a silently-skipped row (unsupported engine) or an empty hit stream (invalid ERE).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP fm-cue-lib: jq not available" >&2; exit 0; }

# shellcheck source=bin/fm-cue-lib.sh
. "$ROOT/bin/fm-cue-lib.sh"

ok_row() {  # <row-json> <msg>
  if fm_validate_cue_row "$1" 2>/dev/null; then pass "$2"; else fail "$2 (expected VALID)"; fi
}
bad_row() { # <row-json> <msg>
  if fm_validate_cue_row "$1" 2>/dev/null; then fail "$2 (expected INVALID)"; else pass "$2"; fi
}

# (a) JSON object
bad_row '{broken json'                                              "not valid JSON -> invalid"
bad_row '"just-a-string"'                                           "a JSON string is not an object -> invalid"
bad_row '["array"]'                                                 "a JSON array is not an object -> invalid"

# (b) closed schema (additionalProperties:false): exact key set {engine, pattern, cue_ref}
bad_row '{"engine":"regex-pcre","pattern":"x","cue_ref":"c"}'      "unsupported engine -> invalid (F2)"
bad_row '{"pattern":"x","cue_ref":"c"}'                            "missing engine -> invalid"
bad_row '{"engine":"awk-ere","pattern":"","cue_ref":"c"}'         "empty pattern -> invalid"
bad_row '{"engine":"awk-ere","pattern":"x"}'                       "missing cue_ref -> invalid"
bad_row '{"engine":"awk-ere","pattern":123,"cue_ref":"c"}'        "non-string pattern -> invalid"
bad_row '{"engine":"awk-ere","pattern":"x","cue_ref":"c","unexpected":true}' "one undeclared property -> invalid (r3: additionalProperties:false)"
bad_row '{"engine":"awk-ere","pattern":"x","cue_ref":"c","a":1,"b":2}' "multiple undeclared properties -> invalid"

# (c) pattern must COMPILE under the engine
bad_row '{"engine":"awk-ere","pattern":"[","cue_ref":"c"}'        "unclosed bracket ERE does not compile -> invalid (F1)"
bad_row '{"engine":"awk-ere","pattern":"(unclosed","cue_ref":"c"}' "unbalanced paren ERE does not compile -> invalid (F1)"

# Valid rows: the real committed tripwires (schema + compile) must pass.
ok_row '{"engine":"awk-ere","pattern":"feature","cue_ref":"ok"}'   "a simple valid ERE -> valid"
ok_row '{"engine":"awk-ere","pattern":"\"additionalProperties\"[[:space:]]*:[[:space:]]*true","cue_ref":"FC-001"}' "the committed FC-001 pattern -> valid"
ok_row '{"engine":"awk-ere","pattern":"mv[[:space:]][^;&|]*&&[[:space:]]*mv[[:space:]]","cue_ref":"FC-005"}' "the committed FC-005 pattern -> valid"

# Every detection row in the committed production ledger must pass the shared validator, so the
# authority the live lint executes is self-consistent with its own gate.
BADCOUNT=0
while IFS= read -r row; do
  [ -n "$row" ] || continue
  fm_validate_cue_row "$row" 2>/dev/null || BADCOUNT=$((BADCOUNT + 1))
done < <(jq -c 'select(.detection)|.detection[]' "$ROOT/docs/failure-classes/ledger.jsonl")
if [ "$BADCOUNT" -eq 0 ]; then
  pass "every detection row in the committed ledger passes the shared validator"
else
  fail "$BADCOUNT committed detection row(s) fail the shared validator"
fi

echo "# all fm-cue-lib tests passed"

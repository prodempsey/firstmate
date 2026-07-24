#!/usr/bin/env bash
# The failure-class ledger CLI (Compounding Fleet stage C, ORD-274). Covers the
# sanctioned-writer discipline (append-only, provenance-required, duplicate/unknown
# refusals, fail-closed on a corrupt ledger), the committed seed ledger's integrity,
# and the register flow (dry-run writes nothing; --live activates records against an
# ISOLATED fixture registry only). The production ledger and the production memory
# registry are never read or written: FM_FC_LEDGER always points at a temp file, and
# MEM_REGISTRY_DIR always points at a temp dir.
set -u

# shellcheck disable=SC1091 # Dynamic test-library path is resolved from BASH_SOURCE.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FC="$ROOT/bin/fm-failure-class.sh"
TMP_ROOT=$(fm_test_tmproot fm-failure-class)

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP fm-failure-class: jq not available" >&2
  exit 0
fi

# --- helper: a fresh isolated ledger with one defined class -----------------
seed_one() { # <ledger-path>
  FM_FC_LEDGER="$1" "$FC" add --id FC-001 \
    --name "Test class" \
    --invariant "always prove positively" \
    --fix "prove conformance to a closed schema" \
    --cue "a growing ladder of per-property checks" \
    --provenance "ruling:data/x/design-ruling.md#1:seed note" >/dev/null
}

# --- add + list + show + validate happy path --------------------------------
L="$TMP_ROOT/happy.jsonl"
seed_one "$L"
if FM_FC_LEDGER="$L" "$FC" validate | grep -q 'FAILURE_CLASSES_OK=1'; then
  pass "validate reports one class"; else fail "validate did not report one class"; fi

out=$(FM_FC_LEDGER="$L" "$FC" list --json)
assert_contains "$out" '"FC-001"' "list --json includes the class id"
assert_contains "$out" '"occurrence_count": 1' "occurrence_count derives from provenance length"

out=$(FM_FC_LEDGER="$L" "$FC" show FC-001)
assert_contains "$out" "always prove positively" "show renders the invariant"
assert_contains "$out" "failure-class" "show renders the reserved marker keyword"

# --- add refuses without required fields ------------------------------------
FM_FC_LEDGER="$TMP_ROOT/x1.jsonl" "$FC" add --id FC-002 --name n --invariant i --fix f --cue c >/dev/null 2>&1
expect_code 1 $? "add refuses a class with no provenance"

FM_FC_LEDGER="$TMP_ROOT/x2.jsonl" "$FC" add --id BOGUS --name n --invariant i --fix f --cue c \
  --provenance "qa:data/y#1" >/dev/null 2>&1
expect_code 1 $? "add refuses a malformed id"

# --- duplicate id refusal (append-only integrity) ---------------------------
FM_FC_LEDGER="$L" "$FC" add --id FC-001 --name dup --invariant i --fix f --cue c \
  --provenance "qa:data/z#1" >/dev/null 2>&1
expect_code 1 $? "add refuses a duplicate class id"

# --- bump: increments the count, requires provenance, append-only -----------
before=$(wc -l < "$L")
firstline_before=$(head -1 "$L")
FM_FC_LEDGER="$L" "$FC" bump FC-001 --provenance "qa:data/qa-new/report.md#5:another occurrence" >/dev/null
after=$(wc -l < "$L")
if [ "$after" -eq $((before + 1)) ]; then
  pass "bump appends exactly one event"; else fail "bump did not append one line"; fi
if [ "$(head -1 "$L")" = "$firstline_before" ]; then
  pass "bump leaves the class-defined line byte-identical (append-only)"
else fail "bump rewrote a prior line"; fi
if FM_FC_LEDGER="$L" "$FC" show FC-001 --json | jq -e '.occurrence_count == 2' >/dev/null; then
  pass "bump raised occurrence_count to 2"; else fail "occurrence_count did not increase"; fi

FM_FC_LEDGER="$L" "$FC" bump FC-001 >/dev/null 2>&1
expect_code 1 $? "bump refuses without --provenance"

FM_FC_LEDGER="$L" "$FC" bump FC-404 --provenance "qa:data/q#1" >/dev/null 2>&1
expect_code 1 $? "bump refuses an unknown class id"

# --- corrupt ledger fails closed --------------------------------------------
C="$TMP_ROOT/corrupt.jsonl"
printf '{"schema":"kraken-failure-class/ledger-event/v1","event":"occurrence","id":"FC-999","provenance":{"type":"qa","ref":"r"}}\n' > "$C"
FM_FC_LEDGER="$C" "$FC" list >/dev/null 2>&1
expect_code 1 $? "list fails closed on an occurrence for an unknown class (corrupt ledger)"

# --- the COMMITTED seed ledger is well-formed and complete ------------------
if "$FC" validate | grep -q 'FAILURE_CLASSES_OK=7'; then
  pass "committed ledger validates with 7 seed classes"; else fail "committed ledger is not 7 valid classes"; fi
committed=$("$FC" list --json)
for id in FC-001 FC-002 FC-003 FC-004 FC-005 FC-006 FC-007; do
  if printf '%s' "$committed" | jq -e --arg id "$id" 'any(.[]; .id==$id and (.provenance|length)>=1 and (.cues|length)>=1)' >/dev/null; then
    pass "seed class $id present with provenance and cues"; else fail "seed class $id missing/incomplete"; fi
done
# Every seed provenance ref is namespaced <type>:... - no unprovenanced rows slipped in.
if printf '%s' "$committed" | jq -e 'all(.[]; all(.provenance[]; (.type|length)>0 and (.ref|length)>0))' >/dev/null; then
  pass "every seed provenance entry carries a type and ref"; else fail "a seed provenance entry is malformed"; fi

# --- register dry-run writes nothing to the registry ------------------------
REG="$TMP_ROOT/reg-dry"
mkdir -p "$REG"
dry=$(MEM_REGISTRY_DIR="$REG" MEM_CLI="true" "$FC" register --id FC-001 2>&1)
assert_contains "$dry" "DRY RUN" "register defaults to a dry run"
assert_contains "$dry" "propose --summary" "dry run prints the propose command"
assert_contains "$dry" "activate MEM-XXXX" "dry run prints the activate command"
if [ -z "$(ls -A "$REG" 2>/dev/null)" ]; then
  pass "dry run wrote nothing to the registry dir"; else fail "dry run mutated the registry dir"; fi

# --- register --live against an ISOLATED fixture registry (node-gated) ------
if command -v node >/dev/null 2>&1; then
  REGL="$TMP_ROOT/reg-live"
  mkdir -p "$REGL"
  MEM_REGISTRY_DIR="$REGL" "$FC" register --live --gate "captain-approved:ORD-274-test" >/dev/null 2>&1
  expect_code 0 $? "register --live succeeds against the fixture registry"
  audit=$(MEM_REGISTRY_DIR="$REGL" node "$ROOT/memory/bin/mem.mjs" audit 2>&1)
  assert_contains "$audit" "7 total, 7 active" "register --live proposed AND activated all 7 classes"
  rec=$(MEM_REGISTRY_DIR="$REGL" node "$ROOT/memory/bin/mem.mjs" show MEM-0001 --json 2>&1)
  if printf '%s' "$rec" | jq -e '.record.keywords | index("failure-class")' >/dev/null; then
    pass "registered record carries the failure-class marker keyword"; else fail "marker keyword missing on record"; fi
  if printf '%s' "$rec" | jq -e '.record.evidence | length >= 1' >/dev/null; then
    pass "registered record carries provenance as evidence"; else fail "evidence missing on record"; fi
  if printf '%s' "$rec" | jq -e '.record.memoryType == "procedural"' >/dev/null; then
    pass "registered record is procedural"; else fail "record memoryType wrong"; fi
else
  echo "SKIP fm-failure-class: node not available for register --live checks" >&2
fi

pass "fm-failure-class: all checks passed"

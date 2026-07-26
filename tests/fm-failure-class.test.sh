#!/usr/bin/env bash
# The failure-class ledger CLI (Seasoning stage C, ORD-274). Covers the
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

# --- amend: append detection cues onto an existing class (class-amended, folded) --
A="$TMP_ROOT/amend.jsonl"
seed_one "$A"
firstline_amend_before=$(head -1 "$A")
det='{"engine":"awk-ere","pattern":"\"additionalProperties\"[[:space:]]*:[[:space:]]*true","cue_ref":"open schema"}'
FM_FC_LEDGER="$A" "$FC" amend FC-001 --detection "$det" >/dev/null
if FM_FC_LEDGER="$A" "$FC" show FC-001 --json | jq -e '(.detection|length)==1 and (.detection[0].pattern|length)>0' >/dev/null; then
  pass "amend folds a detection tripwire onto the class"; else fail "amend did not surface detection on the folded record"; fi
if [ "$(head -1 "$A")" = "$firstline_amend_before" ]; then
  pass "amend leaves the class-defined line byte-identical (append-only)"
else fail "amend rewrote a prior line"; fi
if FM_FC_LEDGER="$A" "$FC" validate | grep -q 'FAILURE_CLASSES_OK=1'; then
  pass "an amended ledger still validates"; else fail "amend broke ledger validation"; fi
# A second amendment accumulates, and natural-language cues append too.
FM_FC_LEDGER="$A" "$FC" amend FC-001 --detection '{"engine":"awk-ere","pattern":"mv .*&& mv ","cue_ref":"nonatomic pair"}' --cue "an extra cue" >/dev/null
if FM_FC_LEDGER="$A" "$FC" show FC-001 --json | jq -e '(.detection|length==2) and (.cues|index("an extra cue")|type=="number")' >/dev/null; then
  pass "amendments accumulate detection and cues at read"; else fail "a second amendment did not accumulate"; fi
FM_FC_LEDGER="$A" "$FC" amend FC-404 --detection "$det" >/dev/null 2>&1
expect_code 1 $? "amend refuses an unknown class id"
FM_FC_LEDGER="$A" "$FC" amend FC-001 >/dev/null 2>&1
expect_code 1 $? "amend refuses when it would add nothing"
FM_FC_LEDGER="$A" "$FC" amend FC-001 --detection '{"engine":"awk-ere","pattern":""}' >/dev/null 2>&1
expect_code 1 $? "amend refuses a detection with an empty pattern (never a silently-inert tripwire)"
# Closed detection schema (qa-scg1-q168 F2): a detection whose engine is outside the supported
# set, or which is missing cue_ref, reads as valid to a naive check yet is inert in the live
# lint - the sanctioned writer must reject it, not accept it.
FM_FC_LEDGER="$A" "$FC" amend FC-001 --detection '{"engine":"not-an-engine","pattern":"synthetic","cue_ref":"bad engine"}' >/dev/null 2>&1
expect_code 1 $? "amend refuses an unsupported detection engine (closed schema)"
FM_FC_LEDGER="$A" "$FC" amend FC-001 --detection '{"engine":"awk-ere","pattern":"synthetic"}' >/dev/null 2>&1
expect_code 1 $? "amend refuses a detection missing cue_ref"
# add/ensure enforce the same closed schema on inline detection.
FM_FC_LEDGER="$TMP_ROOT/badengine-add.jsonl" "$FC" add --id FC-050 --name n --invariant i --fix f --cue c \
  --provenance "qa:data/y#1" --detection '{"engine":"not-an-engine","pattern":"x","cue_ref":"c"}' >/dev/null 2>&1
expect_code 1 $? "add refuses an unsupported inline detection engine"
# validate rejects a hand-injected bad-engine row: a corrupt ledger that a substring grep
# would call valid must still fail closed.
BE="$TMP_ROOT/validate-badengine.jsonl"; seed_one "$BE"
printf '{"schema":"kraken-failure-class/ledger-event/v1","event":"class-amended","id":"FC-001","detection":[{"engine":"regex-pcre","pattern":"x","cue_ref":"c"}]}\n' >> "$BE"
FM_FC_LEDGER="$BE" "$FC" validate >/dev/null 2>&1
expect_code 1 $? "validate refuses a detection row whose engine is outside the supported set"
# The pattern must actually COMPILE under its engine (qa-scg1r2-q173 F1): a syntactically
# invalid ERE that a naive non-empty check accepts would crash awk in the live lint and be
# read as an empty hit stream, so the writer and validate must reject it up front.
FM_FC_LEDGER="$A" "$FC" amend FC-001 --detection '{"engine":"awk-ere","pattern":"[","cue_ref":"invalid ERE"}' >/dev/null 2>&1
expect_code 1 $? "amend refuses a pattern that does not compile as an ERE"
FM_FC_LEDGER="$TMP_ROOT/badere-add.jsonl" "$FC" add --id FC-061 --name n --invariant i --fix f --cue c \
  --provenance "qa:data/y#1" --detection '{"engine":"awk-ere","pattern":"(unclosed","cue_ref":"c"}' >/dev/null 2>&1
expect_code 1 $? "add refuses an inline pattern that does not compile as an ERE"
IE="$TMP_ROOT/validate-badere.jsonl"; seed_one "$IE"
printf '{"schema":"kraken-failure-class/ledger-event/v1","event":"class-amended","id":"FC-001","detection":[{"engine":"awk-ere","pattern":"[","cue_ref":"c"}]}\n' >> "$IE"
FM_FC_LEDGER="$IE" "$FC" validate >/dev/null 2>&1
expect_code 1 $? "validate refuses a detection whose pattern does not compile as an ERE"
# additionalProperties:false (qa-scg1r3-q180 F1): the detection object's key set must be
# EXACTLY {engine, pattern, cue_ref}; an otherwise-valid row with one undeclared key must be
# refused by the writer and by validate, never admitted then executed.
FM_FC_LEDGER="$A" "$FC" amend FC-001 --detection '{"engine":"awk-ere","pattern":"synthetic","cue_ref":"c","unexpected":true}' >/dev/null 2>&1
expect_code 1 $? "amend refuses a detection with an undeclared property (closed schema)"
FM_FC_LEDGER="$TMP_ROOT/badkey-add.jsonl" "$FC" add --id FC-071 --name n --invariant i --fix f --cue c \
  --provenance "qa:data/y#1" --detection '{"engine":"awk-ere","pattern":"x","cue_ref":"c","extra":1}' >/dev/null 2>&1
expect_code 1 $? "add refuses an inline detection with an undeclared property"
XK="$TMP_ROOT/validate-badkey.jsonl"; seed_one "$XK"
printf '{"schema":"kraken-failure-class/ledger-event/v1","event":"class-amended","id":"FC-001","detection":[{"engine":"awk-ere","pattern":"x","cue_ref":"c","unexpected":true}]}\n' >> "$XK"
FM_FC_LEDGER="$XK" "$FC" validate >/dev/null 2>&1
expect_code 1 $? "validate refuses a detection carrying an undeclared property"
pass "closed detection schema (exact key set, engine, compilable pattern, cue_ref) enforced by amend, add, and validate"
# A class-amended event against an id no class-defined ever declared is corrupt: fail closed.
Cam="$TMP_ROOT/corrupt-amend.jsonl"
printf '{"schema":"kraken-failure-class/ledger-event/v1","event":"class-amended","id":"FC-777","detection":[{"engine":"awk-ere","pattern":"x"}]}\n' > "$Cam"
FM_FC_LEDGER="$Cam" "$FC" list >/dev/null 2>&1
expect_code 1 $? "list fails closed on an amendment for an unknown class (corrupt ledger)"

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
# Detection coverage: the committed ledger carries a well-formed detection tripwire on every
# class that HAS one, and every such tripwire is a non-empty-pattern awk-ere object so
# bin/fm-verify.sh's cue lint can execute it. FC-003 deliberately carries no detection - no
# sound single-line ERE tripwire exists for "digest not covering the whole document" without
# false-positiving on legitimate code - so it stays advisory; this guards that decision.
if printf '%s' "$committed" | jq -e 'all(.[]|select(.detection); all(.detection[]; .engine=="awk-ere" and (.pattern|type=="string" and length>0)))' >/dev/null; then
  pass "every committed detection is a well-formed non-empty awk-ere tripwire"; else fail "a committed detection tripwire is malformed or empty"; fi
if printf '%s' "$committed" | jq -e '[.[]|select(.detection|type=="array" and length>0)|.id]|sort == ["FC-001","FC-002","FC-004","FC-005","FC-006","FC-007"]' >/dev/null; then
  pass "committed detection covers every class with a sound tripwire (FC-003 stays advisory)"; else fail "committed detection coverage drifted from the seeded set"; fi

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
  # Finding 1: the DISTINCT TYPED sourceType field is the curation boundary, not
  # merely a keyword. Assert the typed field, per the QA recommendation.
  if printf '%s' "$rec" | jq -e '.record.sourceType == "failure-class"' >/dev/null; then
    pass "registered record carries the typed sourceType == failure-class"; else fail "typed sourceType missing/incorrect on record"; fi
  if printf '%s' "$rec" | jq -e '.record.keywords | index("failure-class")' >/dev/null; then
    pass "registered record also carries the failure-class retrieval keyword"; else fail "marker keyword missing on record"; fi
  if printf '%s' "$rec" | jq -e '.record.evidence | length >= 1' >/dev/null; then
    pass "registered record carries provenance as evidence"; else fail "evidence missing on record"; fi
  if printf '%s' "$rec" | jq -e '.record.memoryType == "procedural"' >/dev/null; then
    pass "registered record is procedural"; else fail "record memoryType wrong"; fi
else
  echo "SKIP fm-failure-class: node not available for register --live checks" >&2
fi

# --- Finding 2: concurrent sanctioned adds cannot corrupt the append-only log ---
# Two writers race to define the same id against an empty fixture ledger. The lock
# must let EXACTLY ONE win; the ledger must validate; there must be one class-defined
# line, not two. Run several rounds because a race does not reproduce every time.
race_ok=1
for _ in 1 2 3 4 5 6 7 8; do
  RL="$TMP_ROOT/race-$RANDOM.jsonl"
  FM_FC_LEDGER="$RL" "$FC" add --id FC-900 --name first --invariant i --fix f --cue c --provenance qa:data/a >/dev/null 2>&1 &
  rp1=$!
  FM_FC_LEDGER="$RL" "$FC" add --id FC-900 --name second --invariant i --fix f --cue c --provenance qa:data/b >/dev/null 2>&1 &
  rp2=$!
  wait "$rp1"; wait "$rp2"
  n=$(grep -c 'class-defined' "$RL" 2>/dev/null || echo 0)
  if [ "$n" != 1 ]; then race_ok=0; break; fi
  if ! FM_FC_LEDGER="$RL" "$FC" validate >/dev/null 2>&1; then race_ok=0; break; fi
done
if [ "$race_ok" = 1 ]; then
  pass "concurrent same-id adds: exactly one wins and the ledger stays valid (lock holds)"
else fail "concurrent adds corrupted the append-only ledger"; fi

# --- Finding 3: no supported command erases a prior appended occurrence ---------
# Copy the committed seed, append a real occurrence via bump, then run the seed
# utility in every mode. The occurrence and its provenance must survive, and no
# class row may be duplicated (idempotent reseed).
RS="$TMP_ROOT/reseed.jsonl"
cp "$ROOT/docs/failure-classes/ledger.jsonl" "$RS"
FM_FC_LEDGER="$RS" "$FC" bump FC-001 --provenance "qa:data/qa-reseed/report.md#1:a real later occurrence" >/dev/null
before_count=$(FM_FC_LEDGER="$RS" "$FC" show FC-001 --json | jq '.occurrence_count')
# --apply is additive/idempotent: it must NOT drop the occurrence and must NOT
# duplicate any class definition.
FM_FC_LEDGER="$RS" "$ROOT/docs/failure-classes/seed.sh" --apply >/dev/null 2>&1
expect_code 0 $? "seed --apply succeeds against a populated ledger"
after_count=$(FM_FC_LEDGER="$RS" "$FC" show FC-001 --json | jq '.occurrence_count')
if [ "$after_count" = "$before_count" ]; then
  pass "reseed --apply preserved the appended occurrence (never drops rows)"; else fail "reseed dropped an occurrence: $before_count -> $after_count"; fi
if FM_FC_LEDGER="$RS" "$FC" show FC-001 --json | jq -e '[.provenance[] | select(.ref|test("qa-reseed"))] | length == 1' >/dev/null; then
  pass "the appended occurrence survives reseed exactly once"; else fail "the appended occurrence was lost or duplicated"; fi
# No class-defined id is duplicated after reseed.
if FM_FC_LEDGER="$RS" "$FC" validate >/dev/null 2>&1; then
  pass "reseeded ledger still validates (no duplicated class rows)"; else fail "reseed corrupted the ledger"; fi
# The default seed mode writes nothing durable: a --check leaves the file byte-identical.
before_hash=$(cksum "$RS" | awk '{print $1}')
FM_FC_LEDGER="$RS" "$ROOT/docs/failure-classes/seed.sh" >/dev/null 2>&1 || true
after_hash=$(cksum "$RS" | awk '{print $1}')
if [ "$before_hash" = "$after_hash" ]; then
  pass "seed --check writes nothing to the target ledger"; else fail "seed --check mutated the ledger"; fi

# --- stage E: captain-gated refinement banner + refinements verb ------------
# The bump (occurrence) path fires a bordered REFINEMENT DUE banner on stderr ONLY on
# the bump that crosses the threshold, exactly once, and never blocks the bump. The
# threshold is configurable via FM_FC_REFINE_THRESHOLD. The refinements verb lists
# every class at/over threshold with its provenance so a draft's citations are ready.
E="$TMP_ROOT/refine.jsonl"
FM_FC_LEDGER="$E" "$FC" add --id FC-100 \
  --name "Auth positive proof" \
  --invariant "authority = positive proof, fail closed" \
  --fix "prove conformance to a closed schema" \
  --cue "a growing ladder of per-property checks" \
  --provenance "ruling:data/x/design-ruling.md#1:seed" >/dev/null

# Bump to count 2 (below the default threshold of 3): NO banner.
below_err=$(FM_FC_LEDGER="$E" "$FC" bump FC-100 --provenance "qa:data/qa-a/report.md#1:occ2" 2>&1 >/dev/null)
assert_not_contains "$below_err" "REFINEMENT DUE" "no refinement banner below the threshold"

# Bump to count 3 (crosses the default threshold of 3): banner fires EXACTLY once, on stderr.
FM_FC_LEDGER="$E" "$FC" bump FC-100 --provenance "qa:data/qa-b/report.md#2:occ3" 2>"$TMP_ROOT/cross.err" >"$TMP_ROOT/cross.out"
cross_err=$(cat "$TMP_ROOT/cross.err")
cross_count=$(grep -c 'REFINEMENT DUE' "$TMP_ROOT/cross.err" || true)
if [ "$cross_count" = 1 ]; then
  pass "crossing bump fires the REFINEMENT DUE banner exactly once"
else fail "crossing bump fired the banner $cross_count times (want 1)"; fi
# The banner is stderr-only: stdout still carries just the ordinary bump line.
assert_not_contains "$(cat "$TMP_ROOT/cross.out")" "REFINEMENT DUE" "the banner goes to stderr, not stdout"
# Banner content: the class id, its invariant, Seasoning program name, and the captain-approval instruction.
assert_contains "$cross_err" "FC-100" "banner names the class id"
assert_contains "$cross_err" "authority = positive proof, fail closed" "banner names the invariant"
assert_contains "$cross_err" "Seasoning" "banner names the Seasoning program (ORD-285 rename)"
assert_contains "$cross_err" "CAPTAIN" "banner instructs to draft an amendment for CAPTAIN approval"
assert_contains "$cross_err" "data/qa-b/report.md#2" "banner lists the provenance for the draft's citations"

# The crossing bump still exits 0: the banner is pull-based and never blocks.
FM_FC_LEDGER="$E" "$FC" bump FC-100 --provenance "qa:data/qa-x/report.md#9:extra" >/dev/null 2>&1
expect_code 0 $? "the bump exits 0 even when it fires the refinement banner"

# Now at count 5 (already well over threshold): further bumps stay silent - fires ONCE per crossing.
over_err=$(FM_FC_LEDGER="$E" "$FC" bump FC-100 --provenance "qa:data/qa-c/report.md#3:occ6" 2>&1 >/dev/null)
assert_not_contains "$over_err" "REFINEMENT DUE" "an already-over class does not re-fire the banner on later bumps"

# Configurable threshold: FM_FC_REFINE_THRESHOLD lowers the crossing point.
E2="$TMP_ROOT/refine-thr.jsonl"
FM_FC_LEDGER="$E2" "$FC" add --id FC-101 --name low --invariant "keep it closed" --fix f --cue c \
  --provenance "ruling:data/y#1" >/dev/null
thr_err=$(FM_FC_REFINE_THRESHOLD=2 FM_FC_LEDGER="$E2" "$FC" bump FC-101 --provenance "qa:data/y#2" 2>&1 >/dev/null)
assert_contains "$thr_err" "REFINEMENT DUE" "a configured threshold of 2 fires on the second occurrence"
assert_contains "$thr_err" "threshold (2)" "banner reports the configured threshold"

# refinements verb: lists only classes at/over threshold, with provenance.
ref=$(FM_FC_LEDGER="$E" "$FC" refinements)
assert_contains "$ref" "FC-100" "refinements lists the over-threshold class"
assert_contains "$ref" "data/qa-b/report.md#2" "refinements includes the class's provenance"
# A below-threshold class is absent from the default-threshold listing.
E3="$TMP_ROOT/refine-mixed.jsonl"
FM_FC_LEDGER="$E3" "$FC" add --id FC-200 --name over --invariant i --fix f --cue c --provenance "r:r#1" >/dev/null
FM_FC_LEDGER="$E3" "$FC" bump FC-200 --provenance "q:q#1" >/dev/null 2>&1
FM_FC_LEDGER="$E3" "$FC" bump FC-200 --provenance "q:q#2" >/dev/null 2>&1
FM_FC_LEDGER="$E3" "$FC" add --id FC-201 --name under --invariant i --fix f --cue c --provenance "r:r#2" >/dev/null
ref_json=$(FM_FC_LEDGER="$E3" "$FC" refinements --json)
if printf '%s' "$ref_json" | jq -e '.threshold == 3 and ([.classes[].id] == ["FC-200"])' >/dev/null; then
  pass "refinements --json returns only over-threshold classes with the active threshold"
else fail "refinements --json listing/threshold incorrect: $ref_json"; fi
# refinements respects the configured threshold too.
ref_json2=$(FM_FC_REFINE_THRESHOLD=2 FM_FC_LEDGER="$E3" "$FC" refinements --json)
if printf '%s' "$ref_json2" | jq -e '.threshold == 2 and ([.classes[].id] | sort == ["FC-200"])' >/dev/null; then
  pass "refinements honors the configured threshold"
else fail "refinements ignored the configured threshold: $ref_json2"; fi
# An empty over-threshold set is a clean, non-error message.
E4="$TMP_ROOT/refine-empty.jsonl"
FM_FC_LEDGER="$E4" "$FC" add --id FC-300 --name lone --invariant i --fix f --cue c --provenance "r:r#1" >/dev/null
empty=$(FM_FC_LEDGER="$E4" "$FC" refinements)
assert_contains "$empty" "no classes at/over the refinement threshold" "refinements reports an empty set cleanly"
# A non-positive-integer threshold falls back to the default rather than disabling the ratchet.
if FM_FC_REFINE_THRESHOLD=bogus FM_FC_LEDGER="$E4" "$FC" refinements --json | jq -e '.threshold == 3' >/dev/null; then
  pass "an invalid FM_FC_REFINE_THRESHOLD falls back to the default"; else fail "invalid threshold did not fall back to default"; fi

# ============================================================================
# The binding ruling's WRITE-path matrix (data/seasoning-cues-g1/design-ruling.md sec 4): every
# writer proves the ENTIRE existing ledger valid before any append, refusing byte-identically on
# failure; the round-5 canaries APPEND-to-malformed and DUP-engine-toplevel both reject; the engine
# is a hard prerequisite. Each mutation asserts BOTH rc!=0 AND the ledger byte-identical.
# ============================================================================
if command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' 2>/dev/null; then
  VALID_LINE='{"schema":"kraken-failure-class/ledger-event/v1","event":"class-defined","id":"FC-001","name":"n","invariant":"i","cues":["c"],"fix":"f","provenance":[{"type":"qa","ref":"r"}],"registry":{"memory_type":"procedural","scope":"fleet","confidence":"guarded","keywords":["k"]}}'
  # refuses_byte_identical <ledger-file> <label> -- run every writer verb; each must exit !=0 and
  # leave the ledger byte-identical. (register reads the ledger to distil it; it too must refuse.)
  refuses_byte_identical() {
    local led=$1 label=$2 before ok=1
    before=$(md5sum "$led" | cut -d' ' -f1)
    _try() {  # each writer verb must refuse (a success is a contract failure) and never mutate the ledger
      if MEM_CLI="true" FM_FC_LEDGER="$led" "$FC" "$@" >/dev/null 2>&1; then ok=0; fi
      [ "$before" = "$(md5sum "$led" | cut -d' ' -f1)" ] || ok=0
    }
    _try add --id FC-050 --name n --invariant i --fix f --cue c --provenance qa:d#1
    _try ensure --id FC-050 --name n --invariant i --fix f --cue c --provenance qa:d#1
    _try amend FC-001 --detection '{"engine":"awk-ere","pattern":"x","cue_ref":"c"}'
    _try bump FC-001 --provenance qa:d#9
    _try register --id FC-001
    if [ "$ok" = 1 ]; then pass "$label: every writer verb refuses, ledger byte-identical"
    else fail "$label: a writer verb either succeeded or mutated the ledger"; fi
  }
  VALID_LINE2='{"schema":"kraken-failure-class/ledger-event/v1","event":"class-defined","id":"FC-002","name":"n","invariant":"i","cues":["c"],"fix":"f","provenance":[{"type":"qa","ref":"r"}],"registry":{"memory_type":"procedural","scope":"fleet","confidence":"guarded","keywords":["k"]}}'
  # CANARY APPEND-to-malformed plus the full lexical/structural set: every writer verb refuses
  # byte-identically against each already-invalid ledger.
  MAL="$TMP_ROOT/mal-append.jsonl"; { printf '{broken-json\n'; printf '%s\n' "$VALID_LINE"; } > "$MAL"
  refuses_byte_identical "$MAL" "APPEND-to-malformed canary (broken JSON first line)"
  L="$TMP_ROOT/mal-bom1.jsonl"; printf '\xef\xbb\xbf%s\n' "$VALID_LINE" > "$L"; refuses_byte_identical "$L" "append to a leading-BOM ledger"
  L="$TMP_ROOT/mal-bom2.jsonl"; printf '%s\n\xef\xbb\xbf%s\n' "$VALID_LINE" "$VALID_LINE2" > "$L"; refuses_byte_identical "$L" "append to a BOM-on-a-non-initial-line ledger"
  L="$TMP_ROOT/mal-ctl.jsonl"; printf '%s\x07\n' "$VALID_LINE" > "$L"; refuses_byte_identical "$L" "append to a control-byte ledger"
  L="$TMP_ROOT/mal-nul.jsonl"; printf '%s\x00\n' "$VALID_LINE" > "$L"; refuses_byte_identical "$L" "append to a NUL-byte ledger"
  L="$TMP_ROOT/mal-trail.jsonl"; printf '%s trailing-garbage\n' "$VALID_LINE" > "$L"; refuses_byte_identical "$L" "append to a trailing-garbage ledger"
  L="$TMP_ROOT/mal-empty.jsonl"; printf '\n%s\n' "$VALID_LINE" > "$L"; refuses_byte_identical "$L" "append to a ledger with an empty line"
  L="$TMP_ROOT/mal-ws.jsonl"; printf '   \n%s\n' "$VALID_LINE" > "$L"; refuses_byte_identical "$L" "append to a ledger with a whitespace-only line"
  L="$TMP_ROOT/mal-nonl.jsonl"; printf '%s' "$VALID_LINE" > "$L"; refuses_byte_identical "$L" "append to a ledger with no final newline"
  L="$TMP_ROOT/mal-dupid.jsonl"; printf '%s\n%s\n' "$VALID_LINE" "$VALID_LINE" > "$L"; refuses_byte_identical "$L" "append to a duplicate-class-id ledger"
  L="$TMP_ROOT/mal-after.jsonl"; printf '%s\n{broken-json\n' "$VALID_LINE" > "$L"; refuses_byte_identical "$L" "append to a ledger with malformed JSON AFTER a valid line"
  # A nested undeclared property (registry.rogue) makes the existing ledger invalid -> every verb refuses.
  L="$TMP_ROOT/mal-nestundecl.jsonl"; printf '%s\n' '{"schema":"kraken-failure-class/ledger-event/v1","event":"class-defined","id":"FC-001","name":"n","invariant":"i","cues":["c"],"fix":"f","provenance":[{"type":"qa","ref":"r"}],"registry":{"memory_type":"procedural","scope":"fleet","confidence":"guarded","keywords":["k"],"rogue":1}}' > "$L"; refuses_byte_identical "$L" "append to a ledger with a nested undeclared property"
  # A nested duplicate member (provenance.ref twice) - jq would collapse it, python's parser cannot.
  L="$TMP_ROOT/mal-nestdup.jsonl"; printf '%s\n' '{"schema":"kraken-failure-class/ledger-event/v1","event":"class-defined","id":"FC-001","name":"n","invariant":"i","cues":["c"],"fix":"f","provenance":[{"type":"qa","ref":"r","ref":"r2"}],"registry":{"memory_type":"procedural","scope":"fleet","confidence":"guarded","keywords":["k"]}}' > "$L"; refuses_byte_identical "$L" "append to a ledger with a nested duplicate member"
  # A duplicate member on the event envelope itself (id twice).
  L="$TMP_ROOT/mal-envdup.jsonl"; { printf '%s\n' "$VALID_LINE"; printf '%s\n' '{"schema":"kraken-failure-class/ledger-event/v1","event":"occurrence","id":"FC-001","id":"FC-002","provenance":{"type":"q","ref":"r"}}'; } > "$L"; refuses_byte_identical "$L" "append to a ledger with a duplicate envelope member"

  # Duplicate detection members via the writer, ALL THREE members in BOTH orderings, via add (the
  # ledger must not be created) AND via amend (byte-identical against an existing valid class). A
  # duplicate must never be jq-collapsed into a valid-looking row and written (F1 kill shot).
  DUP_ROWS=(
    '{"engine":"awk-ere","engine":"regex-pcre","pattern":"x","cue_ref":"c"}'
    '{"engine":"regex-pcre","engine":"awk-ere","pattern":"x","cue_ref":"c"}'
    '{"engine":"awk-ere","pattern":"feature","pattern":"[","cue_ref":"c"}'
    '{"engine":"awk-ere","pattern":"[","pattern":"feature","cue_ref":"c"}'
    '{"engine":"awk-ere","pattern":"a","cue_ref":"ok","cue_ref":""}'
    '{"engine":"awk-ere","pattern":"a","cue_ref":"","cue_ref":"ok"}'
  )
  AL="$TMP_ROOT/dupamend.jsonl"; FM_FC_LEDGER="$AL" "$FC" add --id FC-001 --name n --invariant i --fix f --cue c --provenance qa:d#1 >/dev/null
  amend_base=$(md5sum "$AL"|cut -d' ' -f1)
  for row in "${DUP_ROWS[@]}"; do
    DL="$TMP_ROOT/dupwrite.$RANDOM.jsonl"
    if FM_FC_LEDGER="$DL" "$FC" add --id FC-060 --name n --invariant i --fix f --cue c --provenance qa:d#1 --detection "$row" >/dev/null 2>&1; then
      fail "a duplicate-member detection was written via add: $row"
    elif [ ! -f "$DL" ]; then pass "DUP detection via add rejects (ledger not created): $row"
    else fail "add refused but left a ledger: $row"; fi
    if FM_FC_LEDGER="$AL" "$FC" amend FC-001 --detection "$row" >/dev/null 2>&1; then
      fail "a duplicate-member detection was written via amend: $row"
    elif [ "$amend_base" = "$(md5sum "$AL"|cut -d' ' -f1)" ]; then pass "DUP detection via amend rejects, byte-identical: $row"
    else fail "amend refused but mutated the ledger: $row"; fi
  done

  # Both engines are HARD prerequisites on the write path: absent -> CUE_VALIDATOR_UNAVAILABLE, refuse.
  # The missing-engine simulation engages ONLY through the fixture-gated sandbox marker in the ledger's
  # own directory (a dedicated dir so it cannot leak); the write's temp file lives in that same dir, so
  # the temp proof sees the marker too.
  EA_DIR="$TMP_ROOT/engabsent"; mkdir -p "$EA_DIR"; EL="$EA_DIR/l.jsonl"
  FM_FC_LEDGER="$EL" "$FC" add --id FC-001 --name n --invariant i --fix f --cue c --provenance qa:d#1 >/dev/null
  el_base=$(md5sum "$EL"|cut -d' ' -f1)
  for miss in python3 jsonschema; do
    printf '%s\n' "$miss" > "$EA_DIR/.fm-cue-test-sandbox"
    if FM_FC_LEDGER="$EL" "$FC" bump FC-001 --provenance qa:d#2 >/dev/null 2>"$TMP_ROOT/ea.err"; then
      fail "$miss-absent write must refuse"
    elif [ "$el_base" = "$(md5sum "$EL"|cut -d' ' -f1)" ] && grep -q CUE_VALIDATOR_UNAVAILABLE "$TMP_ROOT/ea.err"; then
      pass "$miss absent (sandbox marker) on the write path -> CUE_VALIDATOR_UNAVAILABLE, ledger byte-identical"
    else fail "$miss-absent write must refuse byte-identically with CUE_VALIDATOR_UNAVAILABLE"; fi
  done
  rm -f "$EA_DIR/.fm-cue-test-sandbox"

  # PLAIN-SHELL BYPASS (qa-scg1r6-q187 F1): a bare ambient FM_CUE_SIMULATE_MISSING must NOT engage the
  # seam - with no marker present, the write proceeds normally.
  if FM_CUE_SIMULATE_MISSING=python3 FM_FC_LEDGER="$EL" "$FC" bump FC-001 --provenance qa:d#3 >/dev/null 2>&1; then
    pass "a bare ambient FM_CUE_SIMULATE_MISSING cannot engage the write-path seam (plain-shell bypass)"
  else fail "a bare FM_CUE_SIMULATE_MISSING must not engage the seam on the write path"; fi

  # REGRESSION (qa-scg1r5-q185 F1): ambient FM_CUE_VALIDATOR / FM_CUE_SCHEMAS_DIR (and the now-dead
  # FM_CUE_SIMULATE_MISSING) cannot substitute the authority. A success-always validator + permissive
  # schema dir must STILL refuse to append to a malformed ledger, byte-identical - all are ignored.
  OV="$TMP_ROOT/override-mal.jsonl"; printf '{broken-json\n' > "$OV"; ov_base=$(md5sum "$OV"|cut -d' ' -f1)
  if FM_CUE_VALIDATOR=true FM_CUE_SCHEMAS_DIR=/tmp FM_CUE_SIMULATE_MISSING=python3 FM_FC_LEDGER="$OV" \
       "$FC" add --id FC-901 --name n --invariant i --fix f --cue c --provenance qa:r#1 >/dev/null 2>&1; then
    fail "ambient FM_CUE_VALIDATOR override authorized a write to a malformed ledger (F1)"
  elif [ "$ov_base" = "$(md5sum "$OV"|cut -d' ' -f1)" ]; then
    pass "ambient FM_CUE_VALIDATOR/FM_CUE_SCHEMAS_DIR cannot authorize a write (F1 regression)"
  else fail "override write refused but mutated the ledger"; fi
else
  echo "SKIP fm-failure-class: python3+jsonschema absent - write-path matrix not exercised" >&2
fi

pass "fm-failure-class: all checks passed"

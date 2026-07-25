#!/usr/bin/env bash
# tests/fm-cue-lib.test.sh - the thin shared shell seam (bin/fm-cue-lib.sh) every cue-ledger consumer
# proves validity through. The exhaustive validation matrix lives in tests/fm-cue-validate.test.sh
# (the authority itself); this proves the seam delegates faithfully: fm_cue_ledger_prove returns the
# proven folded snapshot or fails closed, and fm_cue_check_raw_row rejects a raw duplicate-member row
# before any jq shaping. The validator is resolved by the library's own directory, so FM_ROOT_OVERRIDE
# cannot redirect the authority.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP fm-cue-lib: jq not available" >&2; exit 0; }
if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import jsonschema' 2>/dev/null; then
  echo "SKIP fm-cue-lib: python3+jsonschema not available" >&2; exit 0
fi

# shellcheck source=bin/fm-cue-lib.sh
. "$ROOT/bin/fm-cue-lib.sh"

TMP=$(fm_test_tmproot fm-cue-lib)
CD='{"schema":"kraken-failure-class/ledger-event/v1","event":"class-defined","id":"FC-001","name":"n","invariant":"i","cues":["c"],"fix":"f","provenance":[{"type":"qa","ref":"r"}],"registry":{"memory_type":"procedural","scope":"fleet","confidence":"guarded","keywords":["k"]},"detection":[{"engine":"awk-ere","pattern":"feature","cue_ref":"ok"}]}'

# fm_cue_ledger_prove returns the proven folded snapshot on a valid ledger.
led="$TMP/ok.jsonl"; printf '%s\n' "$CD" > "$led"
if snap=$(fm_cue_ledger_prove "$led" 2>/dev/null) && [ "$(printf '%s' "$snap" | jq -r '.[0].id')" = FC-001 ]; then
  pass "fm_cue_ledger_prove returns the proven folded snapshot for a valid ledger"
else
  fail "fm_cue_ledger_prove must return the snapshot for a valid ledger"
fi

# ...and fails closed (non-zero, marker on stderr) for a corrupt ledger.
bad="$TMP/bad.jsonl"; printf '{broken\n%s\n' "$CD" > "$bad"
if fm_cue_ledger_prove "$bad" >/dev/null 2>"$TMP/e"; then
  fail "fm_cue_ledger_prove must fail closed on a corrupt ledger"
elif [ "$(sed -n 1p "$TMP/e")" = CUE_LEDGER_INVALID ]; then
  pass "fm_cue_ledger_prove fails closed with CUE_LEDGER_INVALID on a corrupt ledger"
else
  fail "fm_cue_ledger_prove refusal must carry the marker"
fi

# A missing ledger is a distinct refusal, never a silent valid-empty.
if fm_cue_ledger_prove "$TMP/missing.jsonl" >/dev/null 2>"$TMP/e"; then
  fail "fm_cue_ledger_prove must fail closed on a missing ledger"
elif [ "$(sed -n 1p "$TMP/e")" = CUE_LEDGER_MISSING ]; then
  pass "fm_cue_ledger_prove distinguishes a MISSING ledger (never valid-empty)"
else
  fail "missing ledger must carry CUE_LEDGER_MISSING"
fi

# fm_cue_check_raw_row proves a single raw row - and rejects a duplicate member jq would collapse.
if fm_cue_check_raw_row '{"engine":"awk-ere","pattern":"feature","cue_ref":"ok"}' 2>/dev/null; then
  pass "fm_cue_check_raw_row accepts a valid raw detection row"
else
  fail "fm_cue_check_raw_row must accept a valid row"
fi
if fm_cue_check_raw_row '{"engine":"regex-pcre","engine":"awk-ere","pattern":"x","cue_ref":"c"}' 2>/dev/null; then
  fail "fm_cue_check_raw_row must reject a duplicate member (raw bytes, jq cannot)"
else
  pass "fm_cue_check_raw_row rejects a duplicate member on raw bytes before jq can collapse it"
fi

# The validator is resolved by the library's own dir, immune to FM_ROOT_OVERRIDE.
if ( FM_ROOT_OVERRIDE="$TMP/poison"; export FM_ROOT_OVERRIDE; fm_cue_ledger_prove "$led" >/dev/null 2>&1 ); then
  pass "the authority is resolved override-proof (FM_ROOT_OVERRIDE cannot redirect it)"
else
  fail "FM_ROOT_OVERRIDE must not break authority resolution"
fi

echo "# all fm-cue-lib tests passed"

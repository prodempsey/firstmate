#!/usr/bin/env bash
# tests/fm-cue-validate.test.sh - the closed matrix for bin/fm-cue-validate.sh, the ONE cue-ledger
# validation authority (python3 + jsonschema over RAW bytes; jq disqualified because it collapses
# duplicate member names). Per the binding ruling (data/seasoning-cues-g1/design-ruling.md) this
# proves - at the authority itself - every schema property, uniqueness rule, closed-set rule, the
# duplicate-member family jq cannot see (top-level AND nested, on rows AND envelopes, both orderings),
# duplicate class ids, encoding/lexical tricks (BOM, control byte, trailing garbage, blank lines), the
# missing-vs-empty distinction, and the engine-absent fail-closed contract. Every prior QA repro is a
# permanent regression here; the round-5 canaries DUP-engine-toplevel and APPEND-to-malformed reject.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP fm-cue-validate: jq not available" >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP fm-cue-validate: python3 not available" >&2; exit 0; }
python3 -c 'import jsonschema' 2>/dev/null || { echo "SKIP fm-cue-validate: jsonschema not available" >&2; exit 0; }

V="$ROOT/bin/fm-cue-validate.sh"
TMP=$(fm_test_tmproot fm-cue-validate)

# A committed-shaped valid class-defined event with one valid detection row.
CD='{"schema":"kraken-failure-class/ledger-event/v1","event":"class-defined","id":"FC-001","name":"n","invariant":"i","cues":["c"],"fix":"f","provenance":[{"type":"qa","ref":"r"}],"registry":{"memory_type":"procedural","scope":"fleet","confidence":"guarded","keywords":["k"]},"detection":[{"engine":"awk-ere","pattern":"feature","cue_ref":"ok"}]}'

# prove_marker <ledger-file> : echo the stderr marker (first line), or "OK" on success.
prove_marker() {
  local out err rc
  err="$TMP/e.$$"
  out=$("$V" prove "$1" 2>"$err"); rc=$?
  if [ "$rc" = 0 ]; then echo "OK"; else sed -n 1p "$err"; fi
  rm -f "$err"
}

# refuse_content <ledger-content> <expected-marker> <msg>
refuse_content() {
  local led="$TMP/led.$$"
  printf '%s\n' "$1" > "$led"
  if [ "$(prove_marker "$led")" = "$2" ]; then pass "$3"; else fail "$3 (expected $2)"; fi
  rm -f "$led"
}
# refuse_file <ledger-file> <expected-marker> <msg>  (for byte-crafted fixtures)
refuse_file() {
  if [ "$(prove_marker "$1")" = "$2" ]; then pass "$3"; else fail "$3 (expected $2)"; fi
}
# ok_content <ledger-content> <expected-len> <msg>
ok_content() {
  local led="$TMP/led.$$" out
  printf '%s\n' "$1" > "$led"
  if out=$("$V" prove "$led" 2>/dev/null) && [ "$(printf '%s' "$out" | jq 'length')" = "$2" ]; then
    pass "$3"
  else
    fail "$3 (expected valid, length $2)"
  fi
  rm -f "$led"
}

# --- positive control -------------------------------------------------------
ok_content "$CD" 1 "positive control: one valid class-defined proves valid"
refuse_file "$ROOT/docs/failure-classes/ledger.jsonl" OK "positive control: the committed production ledger proves valid"

# --- prior repros (permanent regressions) -----------------------------------
refuse_content "$(printf '{broken-json\n%s' "$CD")" CUE_LEDGER_INVALID "R1: malformed JSON before a valid class line"
refuse_content "$(printf '%s\n{broken-json' "$CD")" CUE_LEDGER_INVALID "R1: malformed JSON after a valid class line"
refuse_content "$(printf '%s' "$CD" | sed 's/awk-ere/regex-pcre/')" CUE_LEDGER_INVALID "R1: unsupported detection engine"
refuse_content "$(printf '%s' "$CD" | sed 's/"feature"/"["/')" CUE_LEDGER_INVALID "R2: invalid ERE pattern"
refuse_content "$(printf '%s' "$CD" | sed 's/"cue_ref":"ok"/"cue_ref":"ok","unexpected":true/')" CUE_LEDGER_INVALID "R3: undeclared property on a detection row"
refuse_content '{"schema":"kraken-failure-class/ledger-event/v1","event":"class-defined","id":"FC-001","name":"n","invariant":"i","cues":["c"],"fix":"f","provenance":[{"type":"qa","ref":"r"}],"registry":{"memory_type":"procedural","scope":"fleet","confidence":"guarded","keywords":["k"],"rogue":1},"detection":[{"engine":"awk-ere","pattern":"x","cue_ref":"c"}]}' CUE_LEDGER_INVALID "R3: undeclared property nested in a value object"

# --- duplicate members (the jq-cannot-detect class - the kill shot) ---------
DR() { printf '{"schema":"kraken-failure-class/ledger-event/v1","event":"class-defined","id":"FC-001","name":"n","invariant":"i","cues":["c"],"fix":"f","provenance":[{"type":"qa","ref":"r"}],"registry":{"memory_type":"procedural","scope":"fleet","confidence":"guarded","keywords":["k"]},"detection":[%s]}' "$1"; }
refuse_content "$(DR '{"engine":"awk-ere","engine":"regex-pcre","pattern":"x","cue_ref":"c"}')" CUE_LEDGER_INVALID "CANARY DUP-engine-toplevel (first-valid/last-invalid)"
refuse_content "$(DR '{"engine":"regex-pcre","engine":"awk-ere","pattern":"x","cue_ref":"c"}')" CUE_LEDGER_INVALID "DUP engine (first-invalid/last-valid)"
refuse_content "$(DR '{"engine":"awk-ere","pattern":"feature","pattern":"[","cue_ref":"c"}')" CUE_LEDGER_INVALID "DUP pattern (first-valid/last-invalid)"
refuse_content "$(DR '{"engine":"awk-ere","pattern":"[","pattern":"feature","cue_ref":"c"}')" CUE_LEDGER_INVALID "DUP pattern (first-invalid/last-valid)"
refuse_content "$(DR '{"engine":"awk-ere","pattern":"a","cue_ref":"ok","cue_ref":""}')" CUE_LEDGER_INVALID "DUP cue_ref (first-valid/last-invalid)"
refuse_content "$(DR '{"engine":"awk-ere","pattern":"a","cue_ref":"","cue_ref":"ok"}')" CUE_LEDGER_INVALID "DUP cue_ref (first-invalid/last-valid)"
refuse_content '{"schema":"kraken-failure-class/ledger-event/v1","event":"class-defined","id":"FC-001","name":"n","invariant":"i","cues":["c"],"fix":"f","provenance":[{"type":"qa","ref":"r","ref":"r2"}],"registry":{"memory_type":"procedural","scope":"fleet","confidence":"guarded","keywords":["k"]}}' CUE_LEDGER_INVALID "DUP member nested in a value object (provenance.ref)"
refuse_content '{"schema":"kraken-failure-class/ledger-event/v1","event":"occurrence","id":"FC-001","id":"FC-002","provenance":{"type":"q","ref":"r"}}' CUE_LEDGER_INVALID "DUP member on the ledger envelope (id)"

# --- duplicate class ids ----------------------------------------------------
refuse_content "$(printf '%s\n%s' "$CD" "$CD")" CUE_LEDGER_INVALID "duplicate class-defined id"

# --- encoding / lexical tricks ----------------------------------------------
led="$TMP/bom.jsonl"; printf '\xef\xbb\xbf%s\n' "$CD" > "$led"; refuse_file "$led" CUE_LEDGER_INVALID "leading UTF-8 BOM on the ledger"
led="$TMP/nul.jsonl"; printf '%s\x00\n' "$CD" > "$led"; refuse_file "$led" CUE_LEDGER_INVALID "NUL byte in a line"
led="$TMP/ctl.jsonl"; printf '%s\x07\n' "$CD" > "$led"; refuse_file "$led" CUE_LEDGER_INVALID "control byte in a line"
refuse_content "$(printf '%s trailing-garbage' "$CD")" CUE_LEDGER_INVALID "trailing garbage after a valid object"
refuse_content "$(printf '%s\n\n%s' "$CD" "$CD" | sed '3s/FC-001/FC-002/')" CUE_LEDGER_INVALID "interior blank line"
led="$TMP/ws.jsonl"; printf '%s\n   \n' "$CD" > "$led"; refuse_file "$led" CUE_LEDGER_INVALID "whitespace-only line"
led="$TMP/nonl.jsonl"; printf '%s' "$CD" > "$led"; refuse_file "$led" CUE_LEDGER_INVALID "final line without a trailing newline"

# --- missing vs empty (distinct explicit states) ----------------------------
refuse_file "$TMP/does-not-exist.jsonl" CUE_LEDGER_MISSING "a MISSING ledger is a distinct refusal, never valid-empty"
led="$TMP/empty.jsonl"; : > "$led"
if out=$("$V" prove "$led" 2>/dev/null) && [ "$out" = "[]" ]; then
  pass "an EMPTY-but-present ledger is valid-empty ([])"
else
  fail "empty-present ledger must be valid-empty"
fi

# --- engine fail-closed via the FIXTURE-GATED sandbox marker (never an ambient variable) ----
# The simulation engages only when the marker file sits in the validated ledger's OWN directory, so
# the fixture owns it entirely. It is placed in a dedicated sub-directory so it cannot leak into any
# other fixture's proof.
SIMDIR="$TMP/sim"; mkdir -p "$SIMDIR"; printf '%s\n' "$CD" > "$SIMDIR/l.jsonl"
printf 'python3\n' > "$SIMDIR/.fm-cue-test-sandbox"
"$V" prove "$SIMDIR/l.jsonl" >/dev/null 2>"$TMP/e"
if [ "$(sed -n 1p "$TMP/e")" = CUE_VALIDATOR_UNAVAILABLE ]; then pass "python3 absent (sandbox marker) -> CUE_VALIDATOR_UNAVAILABLE (fail closed)"; else fail "python3 absent must refuse"; fi
printf 'jsonschema\n' > "$SIMDIR/.fm-cue-test-sandbox"
"$V" prove "$SIMDIR/l.jsonl" >/dev/null 2>"$TMP/e"
if [ "$(sed -n 1p "$TMP/e")" = CUE_VALIDATOR_UNAVAILABLE ]; then pass "jsonschema absent (sandbox marker) -> CUE_VALIDATOR_UNAVAILABLE (fail closed)"; else fail "jsonschema absent must refuse"; fi
rm -f "$SIMDIR/.fm-cue-test-sandbox"

# --- PLAIN-SHELL BYPASS (qa-scg1r6-q187 F1): the seam is un-engageable outside its fixture --------
# A bare ambient variable must NOT engage the seam, and a marker in a DIFFERENT directory must NOT
# engage it: only a marker co-located with the validated ledger does.
if FM_CUE_SIMULATE_MISSING=python3 "$V" prove "$SIMDIR/l.jsonl" >/dev/null 2>&1; then
  pass "a bare ambient FM_CUE_SIMULATE_MISSING cannot engage the seam (plain-shell bypass)"
else
  fail "the injection seam must NOT be engageable from a bare env var"
fi
mkdir -p "$TMP/stray"; printf 'python3\n' > "$TMP/stray/.fm-cue-test-sandbox"
if "$V" prove "$SIMDIR/l.jsonl" >/dev/null 2>&1; then
  pass "a sandbox marker in a different directory cannot engage the seam"
else
  fail "a stray marker outside the validated ledger's directory must NOT engage the seam"
fi

# --- check-row: the raw single-row entrypoint (write path uses this pre-jq) --
check_row() { printf '%s' "$1" > "$TMP/row.json"; "$V" check-row "$TMP/row.json" >/dev/null 2>&1; }
if check_row '{"engine":"awk-ere","pattern":"feature","cue_ref":"ok"}'; then pass "check-row: a valid detection row passes"; else fail "check-row valid must pass"; fi
if check_row '{"engine":"awk-ere","engine":"awk-ere","pattern":"x","cue_ref":"c"}'; then fail "check-row must reject a duplicate member"; else pass "check-row: a duplicate member is rejected on raw bytes (jq cannot)"; fi
if check_row '{"engine":"regex-pcre","pattern":"x","cue_ref":"c"}'; then fail "check-row must reject an unsupported engine"; else pass "check-row: unsupported engine rejected"; fi
if check_row '{"engine":"awk-ere","pattern":"[","cue_ref":"c"}'; then fail "check-row must reject an uncompilable ERE"; else pass "check-row: uncompilable ERE rejected"; fi
if check_row '{"engine":"awk-ere","pattern":"x","cue_ref":"c","extra":1}'; then fail "check-row must reject an undeclared property"; else pass "check-row: undeclared property rejected"; fi

echo "# all fm-cue-validate tests passed"

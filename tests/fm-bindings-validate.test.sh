#!/usr/bin/env bash
# Behavior tests for bin/fm-bindings-validate.sh (the fail-closed bindings
# validator + semantic fingerprint) and the fail-closed wiring it drives in
# bin/fm-profile.sh.
#
# Fully sandboxed: every fixture is generated in a mktemp root via
# FM_STATE_OVERRIDE / FM_CONFIG_OVERRIDE, and no live runtime path is ever read
# or touched. Ported from the runtime's 22-case suite
# (data/model-economy/tests/run-bindings-tests.sh). The two runtime-only cases
# there - T2 (pre-slice backup checksum) and T21 (live-resolution parity) - stay
# runtime-side; here they are replaced with fixture-based equivalents: the
# --write-sidecar fingerprint record (T2), and the missing-file legacy fallback
# that proves the wiring leaves the missing-bindings path unchanged (T21).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

V="$ROOT/bin/fm-bindings-validate.sh"
PROFILE="$ROOT/bin/fm-profile.sh"
TMP_ROOT=$(fm_test_tmproot fm-bindings-validate)

command -v jq >/dev/null 2>&1 || fail "test host must provide jq"
command -v python3 >/dev/null 2>&1 || fail "test host must provide python3 (raw duplicate-key check)"

SB="$TMP_ROOT/sandbox"
SBCONFIG="$SB/config"
mkdir -p "$SB" "$SBCONFIG"

# Sandbox crew-profiles.json: the known-profile universe the validator checks
# bindings keys against. Self-contained; never the live config.
cat > "$SBCONFIG/crew-profiles.json" <<'JSON'
{
  "version": 1,
  "default_profile": "implementer_balanced",
  "task_classes": {
    "normal_code_change": "implementer_balanced",
    "file_discovery": "scout_fast",
    "docs": "scout_balanced",
    "architecture_review": "reviewer_deep",
    "final_governance_review": "reviewer_independent"
  },
  "constraints": {
    "final_governance_review": { "provider_independent_of_implementer": true }
  },
  "providers": {
    "claude": "anthropic", "codex": "openai", "grok": "xai",
    "opencode": "mixed", "pi": "unknown", "gemini": "google"
  }
}
JSON

# A valid bindings file. Every routing value is legal under the captain
# constraints: opus at high (not max), codex at xhigh (legal for a non-Anthropic
# harness), no haiku, no fable, model strings within the allowed charset. The
# model strings are placeholders, never real model IDs.
BASE="$SB/base.json"
cat > "$BASE" <<'JSON'
{
  "_comment": "sandbox bindings for validator behavior checks (not the live file)",
  "scout_fast":     { "harness": "codex", "model": "gpt-model-a", "effort": "high" },
  "scout_balanced": { "harness": "grok",  "model": "grok-model-a", "effort": "high" },
  "implementer_balanced": {
    "harness": "claude", "model": "claude-opus-model", "effort": "high",
    "backups": [ { "harness": "codex", "model": "gpt-model-b", "effort": "xhigh" } ]
  },
  "reviewer_deep": { "harness": "claude", "model": "claude-opus-model", "effort": "high" },
  "reviewer_independent": {
    "counterpart": {
      "anthropic": { "harness": "codex",  "model": "gpt-model-c" },
      "openai":    { "harness": "claude", "model": "claude-opus-model", "effort": "high" }
    }
  }
}
JSON

# The metadata sidecar the validator requires beside any present bindings file.
# Its description must not identify the file as a test fixture (the validator
# rejects a live file that self-labels that way).
BASEMETA="$SB/base.meta.json"
cat > "$BASEMETA" <<'JSON'
{
  "schema_version": 1,
  "config_role": "crew-profile-bindings-live",
  "environment": "sandbox",
  "authority": "firstmate bindings validator behavior tests",
  "owner": "sandbox test home",
  "source_example": "docs/examples/crew-profile-bindings.json",
  "commit_policy": "never committed",
  "description": "sandbox bindings for validator behavior checks"
}
JSON

# run_v <args...>: invoke the validator with the sandbox config in scope.
run_v() {
  FM_CONFIG_OVERRIDE="$SBCONFIG" "$V" "$@"
}

# mkfix <name> <jq-filter-on-base>: write a fixture derived from BASE, with the
# valid meta sidecar copied beside it.
mkfix() {
  jq "$2" "$BASE" > "$SB/$1.json"
  cp "$BASEMETA" "$SB/$1.meta.json"
}

# expect_fail_code <label> <fixture> <CODE> [extra validator args...]: the
# validator must exit nonzero AND print the stable code line to stderr.
expect_fail_code() {
  local label=$1 fx=$2 code=$3
  shift 3
  local out rc
  out=$(FM_CONFIG_OVERRIDE="$SBCONFIG" "$V" "$fx" "$@" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "$label: expected nonzero exit, got 0"$'\n'"$out"
  grep -q "^$code:" <<<"$out" || fail "$label: expected code $code"$'\n'"$out"
  pass "$label"
}

# T1 - valid bindings + meta validate and emit a fingerprint.
out=$(run_v "$BASE" 2>&1) || fail "T1 valid file rejected"$'\n'"$out"
grep -q '^FINGERPRINT=' <<<"$out" || fail "T1 no fingerprint printed"$'\n'"$out"
grep -q '^SCHEMA_VERSION=1' <<<"$out" || fail "T1 schema version not echoed"$'\n'"$out"
BASE_FP=$(grep '^FINGERPRINT=' <<<"$out" | cut -d= -f2)
[ -n "$BASE_FP" ] || fail "T1 empty fingerprint"
pass "T1 valid bindings + meta validate and emit a fingerprint"

# T2 (fixture equivalent of the runtime backup-checksum case) - --write-sidecar
# records the semantic fingerprint in the sidecar file.
mkfix t2 '.'
run_v "$SB/t2.json" --quiet --write-sidecar || fail "T2 --write-sidecar run failed"
[ -f "$SB/t2.fingerprint" ] || fail "T2 fingerprint sidecar not written"
side_fp=$(jq -r '.fingerprint' "$SB/t2.fingerprint")
only_fp=$(run_v "$SB/t2.json" --fingerprint-only)
{ [ "$side_fp" = "$only_fp" ] && [ "$side_fp" = "$BASE_FP" ]; } \
  || fail "T2 sidecar fingerprint mismatch (side=$side_fp only=$only_fp base=$BASE_FP)"
pass "T2 --write-sidecar records the semantic fingerprint in the sidecar"

# T3 - unsupported schema_version.
mkfix t3 '.'
jq '.schema_version = 99' "$BASEMETA" > "$SB/t3.meta.json"
expect_fail_code "T3 unsupported schema_version" "$SB/t3.json" BINDINGS_SCHEMA_UNSUPPORTED

# T4a - missing metadata sidecar. T4b - a required metadata field missing.
mkfix t4a '.'
rm -f "$SB/t4a.meta.json"
expect_fail_code "T4a metadata sidecar missing" "$SB/t4a.json" BINDINGS_METADATA_INVALID
mkfix t4b '.'
jq 'del(.owner)' "$BASEMETA" > "$SB/t4b.meta.json"
expect_fail_code "T4b required metadata field missing" "$SB/t4b.json" BINDINGS_METADATA_INVALID

# T5 - duplicate profile key (raw JSON; jq keeps the last, so a raw parse is
# what catches it).
printf '%s' '{"scout_fast":{"harness":"codex","model":"gpt-model-a"},"scout_fast":{"harness":"grok","model":"grok-model-a"}}' > "$SB/t5.json"
cp "$BASEMETA" "$SB/t5.meta.json"
expect_fail_code "T5 duplicate profile key" "$SB/t5.json" BINDINGS_PROFILE_DUPLICATE

# T6 - empty model. T7 - malformed model string. T8 - styling/control characters
# in the model (the historical corruption shape).
mkfix t6 '.scout_fast.model = ""'
expect_fail_code "T6 empty model" "$SB/t6.json" BINDINGS_MODEL_INVALID
mkfix t7 '.scout_fast.model = "claude fable!!"'
expect_fail_code "T7 malformed model" "$SB/t7.json" BINDINGS_MODEL_INVALID
mkfix t8 '.scout_fast.model = "claude-fable-5[1m]"'
expect_fail_code "T8 styled model chars" "$SB/t8.json" BINDINGS_MODEL_INVALID

# T9 - Haiku with any effort. T10 - Opus max. T11 - Fable xhigh. T12 - Fable max.
mkfix t9 '.scout_fast = {harness:"claude", model:"claude-haiku-4-5", effort:"high"}'
expect_fail_code "T9 haiku effort prohibited" "$SB/t9.json" BINDINGS_MODEL_EFFORT_PROHIBITED
mkfix t10 '.implementer_balanced.effort = "max"'
expect_fail_code "T10 opus max prohibited" "$SB/t10.json" BINDINGS_MODEL_EFFORT_PROHIBITED
mkfix t11 '.implementer_balanced = {harness:"claude", model:"claude-fable-5", effort:"xhigh"}'
expect_fail_code "T11 fable xhigh prohibited" "$SB/t11.json" BINDINGS_MODEL_EFFORT_PROHIBITED
mkfix t12 '.implementer_balanced = {harness:"claude", model:"claude-fable-5", effort:"max"}'
expect_fail_code "T12 fable max prohibited" "$SB/t12.json" BINDINGS_MODEL_EFFORT_PROHIBITED

# T13 - unknown effort value. T14 - unknown profile name. T15 - unknown harness.
mkfix t13 '.scout_fast.effort = "ultra"'
expect_fail_code "T13 unknown effort" "$SB/t13.json" BINDINGS_EFFORT_INVALID
mkfix t14 '. + {mystery_profile: {harness:"codex", model:"gpt-model-a"}}'
expect_fail_code "T14 unknown profile" "$SB/t14.json" BINDINGS_PROFILE_UNKNOWN
mkfix t15 '.scout_fast.harness = "hermes"'
expect_fail_code "T15 unknown harness" "$SB/t15.json" BINDINGS_MODEL_INVALID

# T16 - the fingerprint is semantic: reordering keys, and changing only the
# provenance _comment, both leave it unchanged.
mkfix t16 'to_entries | reverse | from_entries'
fp16=$(run_v "$SB/t16.json" --fingerprint-only 2>/dev/null)
[ "$fp16" = "$BASE_FP" ] || fail "T16 reorder changed fingerprint (got $fp16 want $BASE_FP)"
mkfix t16c '._comment = "different provenance wording entirely"'
fp16c=$(run_v "$SB/t16c.json" --fingerprint-only 2>/dev/null)
[ "$fp16c" = "$BASE_FP" ] || fail "T16 _comment change altered fingerprint (got $fp16c want $BASE_FP)"
pass "T16 key reordering and _comment-only changes keep the same fingerprint"

# T17 - a routing-value change always changes the fingerprint.
mkfix t17 '.scout_fast.model = "gpt-model-z"'
fp17=$(run_v "$SB/t17.json" --fingerprint-only 2>/dev/null)
{ [ -n "$fp17" ] && [ "$fp17" != "$BASE_FP" ]; } \
  || fail "T17 routing-value change did not change fingerprint (got $fp17)"
pass "T17 a routing-value change changes the fingerprint"

# T18 - --expect-fingerprint mismatch fails with the stable code.
mkfix t18 '.'
expect_fail_code "T18 expected-fingerprint mismatch" "$SB/t18.json" BINDINGS_FINGERPRINT_MISMATCH \
  --expect-fingerprint 0000000000000000000000000000000000000000000000000000000000000000

# T19 - fail-closed integration: a present-but-invalid bindings file stops
# fm-profile resolution entirely (no HARNESS output, the validator's code
# surfaces).
S19="$SB/state19"
mkdir -p "$S19"
jq '.implementer_balanced.effort = "max"' "$BASE" > "$S19/crew-profile-bindings.json"
cp "$BASEMETA" "$S19/crew-profile-bindings.meta.json"
out19=$(FM_ROOT_OVERRIDE='' FM_HOME="$SB" FM_CONFIG_OVERRIDE="$SBCONFIG" \
  FM_STATE_OVERRIDE="$S19" "$PROFILE" implementer_balanced 2>&1)
rc19=$?
{ [ "$rc19" -ne 0 ] && ! grep -q '^HARNESS=' <<<"$out19" && grep -q 'BINDINGS_MODEL_EFFORT_PROHIBITED' <<<"$out19"; } \
  || fail "T19 invalid bindings did not block resolution (rc=$rc19)"$'\n'"$out19"
pass "T19 a present-but-invalid bindings file blocks fm-profile resolution entirely"

# T20 - the failure path never falls back to a default model (or Fable).
{ ! grep -qi 'fable' <<<"$out19" && ! grep -q '^MODEL=' <<<"$out19"; } \
  || fail "T20 failure path leaked a fallback model"$'\n'"$out19"
pass "T20 validation failure never falls back to a default model (or Fable)"

# T21 (fixture equivalent of the runtime live-parity case) - a MISSING bindings
# file keeps the documented legacy fallback: fm-profile resolves to the crew
# harness with an empty model, never Fable, unchanged by the wiring.
H21="$SB/home21"
mkdir -p "$H21/config" "$H21/state" "$H21/fakebin"
fm_fake_exit0 "$H21/fakebin" claude
cp "$SBCONFIG/crew-profiles.json" "$H21/config/crew-profiles.json"
printf 'claude\n' > "$H21/config/crew-harness"
out21=$(FM_ROOT_OVERRIDE='' FM_HOME="$H21" FM_CONFIG_OVERRIDE="$H21/config" \
  FM_STATE_OVERRIDE="$H21/state" PATH="$H21/fakebin:$PATH" "$PROFILE" implementer_balanced 2>&1)
rc21=$?
[ "$rc21" -eq 0 ] || fail "T21 missing bindings should still resolve via legacy fallback (rc=$rc21)"$'\n'"$out21"
grep -q '^BINDING_SOURCE=legacy-fallback' <<<"$out21" || fail "T21 missing bindings did not use legacy fallback"$'\n'"$out21"
grep -q '^HARNESS=claude' <<<"$out21" || fail "T21 legacy fallback harness wrong"$'\n'"$out21"
grep -q '^MODEL=$' <<<"$out21" || fail "T21 legacy fallback must have an empty model"$'\n'"$out21"
! grep -qi 'fable' <<<"$out21" || fail "T21 legacy fallback must never select Fable"$'\n'"$out21"
pass "T21 a missing bindings file keeps the legacy fallback (crew harness, empty model, never Fable)"

echo "# all fm-bindings-validate tests passed"

#!/usr/bin/env bash
# Behavior tests for bin/fm-profile-matrix-check.sh — the fail-closed validator
# for the governed agent-profile matrix (model-economy program, ORD-224 slice
# S3). Implements test group T.2 (profile definitions) from
# data/model-economy/ord-223-report.md in full: the static rules of the group,
# with per-rule negative cases proving each drift fails closed with its own
# stable code. The T.2 runtime probes (a live dispatch cut off at maxTurns, a
# real Agent call on a non-nesting profile) are deliberately out of scope for
# this additive definitions-only slice, which forces no dispatch through the
# profiles yet; those probes belong to the S4/S5 slices that wire the profiles
# into an actual dispatch path.
#
# Fully sandboxed: every fixture is a copy of the committed manifest and agent
# files into a mktemp root, mutated one axis at a time. The positive parity
# check runs the validator against the real committed files under $ROOT.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

V="$ROOT/bin/fm-profile-matrix-check.sh"
MANIFEST_SRC="$ROOT/docs/model-economy/governed-profiles.manifest.json"
AGENTS_SRC="$ROOT/.claude/agents"
TMP_ROOT=$(fm_test_tmproot fm-profile-matrix-check)

command -v jq >/dev/null 2>&1 || fail "test host must provide jq"

SB="$TMP_ROOT/sandbox"
M="$SB/manifest.json"
D="$SB/agents"

# fresh: reset the sandbox manifest + agent dir to the committed originals.
fresh() {
  rm -rf "$SB"
  mkdir -p "$D"
  cp "$MANIFEST_SRC" "$M"
  cp "$AGENTS_SRC"/*.md "$D"/
}

# runc: run the validator over the sandbox; capture combined stdout+stderr into
# OUT (PROFILES_OK on stdout, stable codes on stderr), exit code into RC.
runc() {
  OUT=$("$V" --manifest "$M" --agents-dir "$D" "$@" 2>&1)
  RC=$?
}

# jq_manifest <jq-expr>: rewrite the sandbox manifest in place.
jq_manifest() {
  local tmp="$M.tmp"
  jq "$1" "$M" > "$tmp" && mv "$tmp" "$M"
}

# --- positive parity --------------------------------------------------------

test_real_repo_is_coherent() {
  out=$("$V" 2>&1) || fail "committed profile matrix must validate clean"$'\n'"$out"
  assert_contains "$out" "PROFILES_OK=11" "all 11 governed profiles must validate"
  pass "committed manifest + .claude/agents matrix is coherent (11 profiles)"
}

test_sandbox_copy_is_coherent() {
  fresh
  runc
  expect_code 0 "$RC" "an untouched sandbox copy must validate"
  assert_contains "$OUT" "PROFILES_OK=11" "sandbox copy validates all 11"
  pass "sandbox copy of the committed files validates clean"
}

# --- T.2 rule: Haiku profiles carry no effort field -------------------------

test_haiku_has_no_effort_field() {
  # The committed haiku files must not carry an EFFORT key at all.
  grep -Eq '^EFFORT:' "$AGENTS_SRC/haiku-evidence.md" && fail "haiku-evidence must have no EFFORT key"
  grep -Eq '^EFFORT:' "$AGENTS_SRC/haiku-log-compressor.md" && fail "haiku-log-compressor must have no EFFORT key"
  pass "committed haiku profiles carry no EFFORT key"
}

test_haiku_with_effort_rejected() {
  fresh
  # Inject an effort field into a Haiku profile → must be rejected.
  sed -i '/^model: haiku$/a EFFORT: high' "$D/haiku-evidence.md"
  runc
  expect_code 1 "$RC" "a Haiku profile carrying EFFORT must be rejected"
  assert_contains "$OUT" "PROFILE_EFFORT_MISMATCH" "effort-on-haiku is a PROFILE_EFFORT_MISMATCH"
  pass "setting an effort field on a Haiku profile fails closed"
}

# --- T.2 rule: Sonnet profiles fixed at high --------------------------------

test_sonnet_fixed_high() {
  for p in sonnet-high-engineer sonnet-high-reviewer; do
    grep -Eqx 'EFFORT: high' "$AGENTS_SRC/$p.md" || fail "$p must be EFFORT: high exactly"
  done
  pass "committed sonnet profiles are fixed at high"
}

test_sonnet_non_high_rejected() {
  fresh
  sed -i 's/^EFFORT: high$/EFFORT: medium/' "$D/sonnet-high-engineer.md"
  runc
  expect_code 1 "$RC" "a non-high sonnet profile must be rejected"
  assert_contains "$OUT" "PROFILE_EFFORT_MISMATCH" "non-high sonnet is a PROFILE_EFFORT_MISMATCH"
  pass "a non-high Sonnet profile fails closed"
}

# --- T.2 rule: no opus-max / fable-xhigh / fable-max profile exists ---------

test_no_prohibited_profiles_committed() {
  for bad in opus-max fable-xhigh fable-max; do
    assert_absent "$AGENTS_SRC/$bad.md" "prohibited profile file must not exist: $bad.md"
  done
  # And the manifest names them as prohibited.
  for bad in opus-max fable-xhigh fable-max; do
    jq -e --arg b "$bad" '.prohibited_profile_names | index($b)' "$MANIFEST_SRC" >/dev/null \
      || fail "manifest must list $bad as prohibited"
  done
  pass "no opus-max/fable-xhigh/fable-max profile exists; manifest names them prohibited"
}

test_prohibited_profile_file_rejected() {
  for bad in opus-max fable-xhigh fable-max; do
    fresh
    cp "$D/opus-high.md" "$D/$bad.md"
    sed -i "s/^name: opus-high$/name: $bad/" "$D/$bad.md"
    runc
    expect_code 1 "$RC" "a $bad profile file must be rejected"
    assert_contains "$OUT" "PROFILE_PROHIBITED_PRESENT" "$bad is a PROFILE_PROHIBITED_PRESENT"
  done
  pass "adding a prohibited-name profile file fails closed"
}

# --- T.2 rule: non-nesting profiles lack the Agent tool ---------------------

test_nonnesting_profiles_lack_agent() {
  # Every non-fable committed profile must exclude Agent from tools and disallow it.
  for p in haiku-evidence haiku-log-compressor sonnet-high-engineer sonnet-high-reviewer \
           opus-low opus-medium opus-high opus-xhigh; do
    grep -E '^tools:' "$AGENTS_SRC/$p.md" | grep -q 'Agent' && fail "$p must not list the Agent tool"
    grep -Eq '^disallowedTools: \[Agent\]' "$AGENTS_SRC/$p.md" || fail "$p must disallow Agent"
  done
  pass "non-nesting profiles exclude and disallow the Agent tool"
}

test_nonnesting_with_agent_tool_rejected() {
  fresh
  # Accidentally include Agent in a non-nesting tool list.
  sed -i 's/^tools: \[Read, Write, Edit, Bash, Grep, Glob\]$/tools: [Read, Write, Edit, Bash, Grep, Glob, Agent]/' "$D/opus-high.md"
  runc
  expect_code 1 "$RC" "a non-nesting profile listing Agent must be rejected"
  case "$OUT" in
    *PROFILE_TOOLS_MISMATCH*|*PROFILE_NESTING_MISMATCH*) : ;;
    *) fail "expected a tools/nesting rejection, got: $OUT" ;;
  esac
  pass "a non-nesting profile that lists Agent fails closed"
}

test_nonnesting_without_disallow_rejected() {
  fresh
  # Drop the disallowedTools guard from a non-nesting profile.
  sed -i '/^disallowedTools: \[Agent\]$/d' "$D/opus-low.md"
  runc
  expect_code 1 "$RC" "a non-nesting profile that fails to disallow Agent must be rejected"
  assert_contains "$OUT" "PROFILE_NESTING_MISMATCH" "missing disallow is a PROFILE_NESTING_MISMATCH"
  pass "a non-nesting profile that does not disallow Agent fails closed"
}

test_nesting_profile_has_agent() {
  for p in fable-low fable-medium fable-high; do
    grep -E '^tools:' "$AGENTS_SRC/$p.md" | grep -q 'Agent' || fail "$p must list the Agent tool"
    grep -Eq '^disallowedTools:' "$AGENTS_SRC/$p.md" && fail "$p (nesting) must not carry disallowedTools"
  done
  pass "fable profiles list Agent and never disallow it"
}

test_nesting_profile_disallowing_agent_rejected() {
  fresh
  # A nesting profile must not disallow Agent.
  sed -i '/^maxTurns: 20$/i disallowedTools: [Agent]' "$D/fable-low.md"
  runc
  expect_code 1 "$RC" "a fable profile disallowing Agent must be rejected"
  assert_contains "$OUT" "PROFILE_NESTING_MISMATCH" "disallowing Agent on fable is a PROFILE_NESTING_MISMATCH"
  pass "a nesting profile that disallows Agent fails closed"
}

# --- T.2 rule: tool/write restrictions match the committed matrix -----------

test_tool_drift_rejected() {
  fresh
  # Drop Edit from a writing profile's tool list.
  sed -i 's/^tools: \[Read, Write, Edit, Bash, Grep, Glob\]$/tools: [Read, Write, Bash, Grep, Glob]/' "$D/opus-high.md"
  runc
  expect_code 1 "$RC" "tool-list drift from the matrix must be rejected"
  assert_contains "$OUT" "PROFILE_TOOLS_MISMATCH" "tool drift is a PROFILE_TOOLS_MISMATCH"
  pass "a profile whose tools drift from the matrix fails closed"
}

test_write_flag_drift_rejected() {
  fresh
  # Manifest says opus-high writes:false while the file still lists Write/Edit.
  jq_manifest '.profiles["opus-high"].writes = false'
  runc
  expect_code 1 "$RC" "a writes-flag drift must be rejected"
  assert_contains "$OUT" "PROFILE_WRITES_MISMATCH" "writes drift is a PROFILE_WRITES_MISMATCH"
  pass "a manifest/file writes-flag disagreement fails closed"
}

# --- T.2 rule: maxTurns applied ---------------------------------------------

test_maxturns_present_and_in_range() {
  # Every committed profile carries an integer maxTurns inside its matrix range.
  for name in $(jq -r '.profiles | keys[]' "$MANIFEST_SRC"); do
    turns=$(sed -n 's/^maxTurns:[[:space:]]*//p' "$AGENTS_SRC/$name.md" | head -n1)
    case "$turns" in ''|*[!0-9]*) fail "$name maxTurns must be an integer, got '$turns'" ;; esac
    lo=$(jq -r --arg n "$name" '.profiles[$n].maxTurns.min' "$MANIFEST_SRC")
    hi=$(jq -r --arg n "$name" '.profiles[$n].maxTurns.max' "$MANIFEST_SRC")
    { [ "$turns" -ge "$lo" ] && [ "$turns" -le "$hi" ]; } || fail "$name maxTurns $turns outside [$lo,$hi]"
  done
  pass "every committed profile carries an in-range integer maxTurns"
}

test_maxturns_out_of_range_rejected() {
  fresh
  sed -i 's/^maxTurns: 24$/maxTurns: 99/' "$D/opus-high.md"
  runc
  expect_code 1 "$RC" "an out-of-range maxTurns must be rejected"
  assert_contains "$OUT" "PROFILE_MAXTURNS_OUT_OF_RANGE" "out-of-range maxTurns has its own code"
  pass "a maxTurns outside the matrix range fails closed"
}

test_maxturns_non_integer_rejected() {
  fresh
  sed -i 's/^maxTurns: 24$/maxTurns: lots/' "$D/opus-high.md"
  runc
  expect_code 1 "$RC" "a non-integer maxTurns must be rejected"
  assert_contains "$OUT" "PROFILE_MAXTURNS_OUT_OF_RANGE" "non-integer maxTurns is a range error"
  pass "a non-integer maxTurns fails closed"
}

# --- schema-versioned definitions: profile_version --------------------------

test_profile_version_present() {
  for name in $(jq -r '.profiles | keys[]' "$MANIFEST_SRC"); do
    grep -Eqx 'profile_version: 1' "$AGENTS_SRC/$name.md" || fail "$name must carry profile_version: 1"
  done
  pass "every committed profile carries profile_version"
}

test_profile_version_drift_rejected() {
  fresh
  sed -i 's/^profile_version: 1$/profile_version: 2/' "$D/opus-high.md"
  runc
  expect_code 1 "$RC" "a profile_version drift must be rejected"
  assert_contains "$OUT" "PROFILE_VERSION_MISMATCH" "version drift has its own code"
  pass "a profile_version disagreement fails closed"
}

# --- name / model agreement -------------------------------------------------

test_name_mismatch_rejected() {
  fresh
  sed -i 's/^name: opus-high$/name: opus-highest/' "$D/opus-high.md"
  runc
  expect_code 1 "$RC" "a frontmatter name not matching the manifest key must be rejected"
  assert_contains "$OUT" "PROFILE_NAME_MISMATCH" "name mismatch has its own code"
  pass "a name/key disagreement fails closed"
}

test_model_mismatch_rejected() {
  fresh
  sed -i 's/^model: opus$/model: sonnet/' "$D/opus-high.md"
  runc
  expect_code 1 "$RC" "a model not matching the manifest must be rejected"
  assert_contains "$OUT" "PROFILE_MODEL_MISMATCH" "model mismatch has its own code"
  pass "a model disagreement fails closed"
}

# --- directory / file set ---------------------------------------------------

test_missing_profile_file_rejected() {
  fresh
  rm -f "$D/opus-high.md"
  runc
  expect_code 1 "$RC" "a manifest profile with no file must be rejected"
  assert_contains "$OUT" "PROFILE_FILE_MISSING" "missing file has its own code"
  pass "a manifest profile missing its file fails closed"
}

test_unknown_profile_file_rejected() {
  fresh
  cp "$D/opus-high.md" "$D/rogue-profile.md"
  sed -i 's/^name: opus-high$/name: rogue-profile/' "$D/rogue-profile.md"
  runc
  expect_code 1 "$RC" "an agent file with no manifest entry must be rejected"
  assert_contains "$OUT" "PROFILE_FILE_UNKNOWN" "unknown file has its own code"
  pass "an ungoverned agent file fails closed"
}

# --- manifest integrity -----------------------------------------------------

test_manifest_missing_rejected() {
  fresh
  OUT=$("$V" --manifest "$SB/nope.json" --agents-dir "$D" 2>&1); RC=$?
  expect_code 1 "$RC" "a missing manifest must be rejected"
  assert_contains "$OUT" "PROFILE_MANIFEST_MISSING" "missing manifest has its own code"
  pass "a missing manifest fails closed"
}

test_manifest_invalid_json_rejected() {
  fresh
  printf '{ not json' > "$M"
  runc
  expect_code 1 "$RC" "a malformed manifest must be rejected"
  assert_contains "$OUT" "PROFILE_MANIFEST_INVALID" "invalid manifest JSON has its own code"
  pass "a malformed manifest fails closed"
}

test_manifest_bad_schema_rejected() {
  fresh
  jq_manifest '.schema_version = "firstmate/governed-profiles/v99"'
  runc
  expect_code 1 "$RC" "an unsupported schema_version must be rejected"
  assert_contains "$OUT" "PROFILE_MANIFEST_SCHEMA_UNSUPPORTED" "bad schema has its own code"
  pass "an unsupported manifest schema fails closed"
}

test_manifest_inconsistent_rejected() {
  fresh
  # Give a haiku profile a non-null effort in the manifest itself.
  jq_manifest '.profiles["haiku-evidence"].effort = "high"'
  runc
  expect_code 1 "$RC" "an internally inconsistent manifest must be rejected"
  assert_contains "$OUT" "PROFILE_MANIFEST_INCONSISTENT" "manifest inconsistency has its own code"
  pass "an internally inconsistent manifest fails closed"
}

# --- optional SHELL-CREW bindings cross-check -------------------------------

test_bindings_agreement_passes() {
  fresh
  cat > "$SB/bindings.json" <<'JSON'
{
  "_comment": "sandbox",
  "schema_version": "firstmate/crew-profile-bindings/v1",
  "opus-high": {"harness": "claude", "model": "claude-opus-4-8", "effort": "high", "backups": []}
}
JSON
  runc --bindings "$SB/bindings.json"
  expect_code 0 "$RC" "a governed bindings entry that agrees must pass"$'\n'"$OUT"
  pass "a bindings entry agreeing with the manifest passes the cross-check"
}

test_bindings_legacy_only_is_noop() {
  fresh
  cat > "$SB/bindings.json" <<'JSON'
{
  "_comment": "legacy crew-dispatch bindings, no governed names",
  "schema_version": "firstmate/crew-profile-bindings/v1",
  "implementer_balanced": {"harness": "claude", "model": "claude-sonnet-5", "effort": "high", "backups": []},
  "scout_fast": {"harness": "claude", "model": "claude-haiku-4-5", "effort": "", "backups": []}
}
JSON
  runc --bindings "$SB/bindings.json"
  expect_code 0 "$RC" "legacy-only bindings must be a clean no-op"$'\n'"$OUT"
  assert_contains "$OUT" "PROFILES_OK=11" "legacy-only bindings still validate the matrix"
  pass "a bindings file with only legacy names is a clean no-op"
}

test_bindings_effort_mismatch_rejected() {
  fresh
  cat > "$SB/bindings.json" <<'JSON'
{
  "opus-high": {"harness": "claude", "model": "claude-opus-4-8", "effort": "low", "backups": []}
}
JSON
  runc --bindings "$SB/bindings.json"
  expect_code 1 "$RC" "a governed bindings effort disagreement must be rejected"
  assert_contains "$OUT" "PROFILE_BINDINGS_MISMATCH" "bindings effort drift has its own code"
  pass "a bindings effort disagreement fails closed"
}

test_bindings_model_mismatch_rejected() {
  fresh
  cat > "$SB/bindings.json" <<'JSON'
{
  "opus-high": {"harness": "claude", "model": "claude-sonnet-5", "effort": "high", "backups": []}
}
JSON
  runc --bindings "$SB/bindings.json"
  expect_code 1 "$RC" "a governed bindings model disagreement must be rejected"
  assert_contains "$OUT" "PROFILE_BINDINGS_MISMATCH" "bindings model drift has its own code"
  pass "a bindings model disagreement fails closed"
}

# --- usage ------------------------------------------------------------------

test_unknown_flag_is_usage_error() {
  OUT=$("$V" --bogus 2>&1); RC=$?
  expect_code 2 "$RC" "an unknown flag must be a usage error (exit 2)"
  pass "an unknown flag exits 2"
}

test_real_repo_is_coherent
test_sandbox_copy_is_coherent
test_haiku_has_no_effort_field
test_haiku_with_effort_rejected
test_sonnet_fixed_high
test_sonnet_non_high_rejected
test_no_prohibited_profiles_committed
test_prohibited_profile_file_rejected
test_nonnesting_profiles_lack_agent
test_nonnesting_with_agent_tool_rejected
test_nonnesting_without_disallow_rejected
test_nesting_profile_has_agent
test_nesting_profile_disallowing_agent_rejected
test_tool_drift_rejected
test_write_flag_drift_rejected
test_maxturns_present_and_in_range
test_maxturns_out_of_range_rejected
test_maxturns_non_integer_rejected
test_profile_version_present
test_profile_version_drift_rejected
test_name_mismatch_rejected
test_model_mismatch_rejected
test_missing_profile_file_rejected
test_unknown_profile_file_rejected
test_manifest_missing_rejected
test_manifest_invalid_json_rejected
test_manifest_bad_schema_rejected
test_manifest_inconsistent_rejected
test_bindings_agreement_passes
test_bindings_legacy_only_is_noop
test_bindings_effort_mismatch_rejected
test_bindings_model_mismatch_rejected
test_unknown_flag_is_usage_error

pass "fm-profile-matrix-check: all T.2 profile-definition cases passed"

#!/usr/bin/env bash
# Behavior tests for bin/fm-profile-matrix-check.sh — the fail-closed authority
# validator for the governed agent-profile matrix (model-economy program, ORD-224
# slice S3). Authority pattern: data/me-s3-profiles/design-ruling.md §4 (the
# exhaustive invalid-fixture matrix) and its class precedent
# data/dj-orders-s2/design-ruling.md.
#
# The validator proves authority by conformance to three committed CLOSED JSON
# Schemas plus whole-object projection equality, with python3+PyYAML+jsonschema as
# hard prerequisites that refuse rather than degrade. This suite pairs EVERY
# schema property, uniqueness/enum/closed-set rule, cross-property policy, and
# projection field with a one-property-at-a-time invalid fixture built by copying
# the committed valid artifacts and mutating exactly one thing, plus valid-document
# positive controls. The two canaries (M-extra-root, F-permissionMode-list) are
# the ruling's proof: both must reject.
#
# Fully sandboxed: fixtures are copies of the committed manifest and agent files
# in a mktemp root; the committed schemas are always the real authority.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

V="$ROOT/bin/fm-profile-matrix-check.sh"
MANIFEST_SRC="$ROOT/docs/model-economy/governed-profiles.manifest.json"
AGENTS_SRC="$ROOT/.claude/agents"
SDIR="$ROOT/docs/model-economy/schemas"
TMP_ROOT=$(fm_test_tmproot fm-profile-matrix-check)

command -v jq >/dev/null 2>&1 || fail "test host must provide jq"
command -v python3 >/dev/null 2>&1 || fail "test host must provide python3"

SB="$TMP_ROOT/sandbox"
M="$SB/manifest.json"
D="$SB/agents"

fresh() {
  rm -rf "$SB"
  mkdir -p "$D"
  cp "$MANIFEST_SRC" "$M"
  cp "$AGENTS_SRC"/*.md "$D"/
}

# runc: run over the sandbox against the REAL committed schemas; combined output
# into OUT (PROFILES_OK/MATRIX_FINGERPRINT on stdout, stable code on stderr).
runc() {
  OUT=$("$V" --manifest "$M" --agents-dir "$D" --schemas-dir "$SDIR" "$@" 2>&1)
  RC=$?
}

jq_manifest() {  # rewrite the sandbox manifest in place
  local tmp="$M.tmp"
  jq "$1" "$M" > "$tmp" && mv "$tmp" "$M"
}

# dup_line <file> <exact-line>: insert a duplicate of the first matching line.
dup_line() {
  awk -v L="$2" '{print} $0==L && !d {print L; d=1}' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# expect: run the sandbox and assert exit 1 + a stable code substring.
expect_reject() {  # expect_reject <code> <label>
  runc --quiet
  expect_code 1 "$RC" "$2 must be rejected"
  assert_contains "$OUT" "$1" "$2 -> $1"
}

# --- positive controls ------------------------------------------------------

test_real_repo_is_coherent() {
  out=$("$V" 2>&1) || fail "committed matrix must validate clean"$'\n'"$out"
  assert_contains "$out" "PROFILES_OK=11" "all 11 governed profiles validate"
  assert_contains "$out" "MATRIX_FINGERPRINT=" "a stable fingerprint is emitted"
  pass "committed manifest + schemas + .claude/agents matrix is coherent (11 profiles)"
}

test_sandbox_copy_is_coherent() {
  fresh
  runc
  expect_code 0 "$RC" "an untouched sandbox copy must validate"
  assert_contains "$OUT" "PROFILES_OK=11" "sandbox copy validates all 11"
  assert_contains "$OUT" "MATRIX_FINGERPRINT=" "sandbox copy emits a fingerprint"
  pass "sandbox copy of the committed files validates clean"
}

# --- CANARIES (the ruling's proof of the whole contract) --------------------

test_canary_M_extra_root() {
  fresh
  jq_manifest '.bogus = 1'
  expect_reject "PROFILE_MANIFEST_SCHEMA_INVALID" "M-extra-root canary (unknown root key)"
  pass "CANARY M-extra-root: an unknown manifest root key fails closed"
}

test_canary_F_permissionMode_list() {
  fresh
  sed -i 's/^permissionMode: default$/permissionMode: [default]/' "$D/opus-high.md"
  expect_reject "PROFILE_FRONTMATTER_SCHEMA_INVALID" "F-permissionMode-list canary"
  pass "CANARY F-permissionMode-list: permissionMode as a list fails closed"
}

# --- engine / fail-closed (no degradation) ----------------------------------

test_missing_python3_refuses() {
  fresh
  local nopy="$SB/nopy"
  mkdir -p "$nopy"
  ln -sf "$(command -v bash)" "$nopy/bash"
  OUT=$(PATH="$nopy" bash "$V" --manifest "$M" --agents-dir "$D" --schemas-dir "$SDIR" --quiet 2>&1); RC=$?
  expect_code 1 "$RC" "an absent python3 must fail closed"
  assert_contains "$OUT" "PROFILE_VALIDATOR_UNAVAILABLE" "missing python3 refuses"
  assert_not_contains "$OUT" "PROFILES_OK" "no success without the engine"
  pass "a missing python3 refuses rather than degrading"
}

test_missing_pyyaml_refuses() {
  fresh
  OUT=$(FM_PROFILE_SIMULATE_MISSING=yaml "$V" --manifest "$M" --agents-dir "$D" --schemas-dir "$SDIR" --quiet 2>&1); RC=$?
  expect_code 1 "$RC" "an absent PyYAML must fail closed"
  assert_contains "$OUT" "PROFILE_VALIDATOR_UNAVAILABLE" "missing PyYAML refuses"
  pass "a missing PyYAML (independent) refuses rather than degrading"
}

test_missing_jsonschema_refuses() {
  fresh
  OUT=$(FM_PROFILE_SIMULATE_MISSING=jsonschema "$V" --manifest "$M" --agents-dir "$D" --schemas-dir "$SDIR" --quiet 2>&1); RC=$?
  expect_code 1 "$RC" "an absent jsonschema must fail closed"
  assert_contains "$OUT" "PROFILE_VALIDATOR_UNAVAILABLE" "missing jsonschema refuses"
  pass "a missing jsonschema (independent) refuses rather than degrading"
}

test_missing_committed_schema_refuses() {
  fresh
  mkdir -p "$SB/emptyschemas"
  OUT=$("$V" --manifest "$M" --agents-dir "$D" --schemas-dir "$SB/emptyschemas" --quiet 2>&1); RC=$?
  expect_code 1 "$RC" "an absent committed schema must fail closed"
  assert_contains "$OUT" "PROFILE_VALIDATOR_UNAVAILABLE" "a missing committed schema refuses"
  pass "an absent committed schema refuses rather than degrading"
}

# --- manifest: missing / parse / duplicate ----------------------------------

test_manifest_missing_rejected() {
  fresh
  OUT=$("$V" --manifest "$SB/nope.json" --agents-dir "$D" --schemas-dir "$SDIR" 2>&1); RC=$?
  expect_code 1 "$RC" "a missing manifest must be rejected"
  assert_contains "$OUT" "PROFILE_MANIFEST_MISSING" "missing manifest has its own code"
  pass "a missing manifest fails closed"
}

test_manifest_invalid_json_rejected() {
  fresh
  printf '{ not json' > "$M"
  expect_reject "PROFILE_MANIFEST_INVALID" "malformed manifest JSON"
  pass "a malformed manifest fails closed"
}

test_manifest_duplicate_key_rejected() {
  fresh
  python3 - "$M" > "$M.tmp" <<'PY'
import sys
s = open(sys.argv[1]).read()
s = s.replace('{\n', '{\n  "schema_version": "firstmate/governed-profiles/v1",\n', 1)
sys.stdout.write(s)
PY
  mv "$M.tmp" "$M"
  expect_reject "PROFILE_MANIFEST_DUPLICATE_KEY" "top-level duplicate manifest key"
  pass "a duplicate manifest JSON key fails closed"
}

test_manifest_duplicate_nested_key_rejected() {
  fresh
  python3 - "$M" > "$M.tmp" <<'PY'
import sys
s = open(sys.argv[1]).read()
s = s.replace('"opus-high": {\n', '"opus-high": {\n      "model": "fable",\n', 1)
sys.stdout.write(s)
PY
  mv "$M.tmp" "$M"
  expect_reject "PROFILE_MANIFEST_DUPLICATE_KEY" "nested duplicate manifest key"
  pass "a duplicate key nested in a manifest profile fails closed"
}

# --- manifest: schema-expressible violations (one fixture per property) ------

test_manifest_schema_violations_rejected() {
  # <jq-expr>|<label>  — each is a single-property mutation that the manifest
  # JSON Schema must reject (type / enum / additionalProperties / uniqueItems /
  # required / minItems).
  local cases=(
    '.schema_version = "firstmate/governed-profiles/v99"|schema_version-enum'
    '.profile_version = "1"|M-root-version-string'
    '.source_authority = 5|source_authority-number'
    '.description = true|description-boolean'
    '.models_allowed = "opus"|models_allowed-not-a-list'
    '.models_allowed = []|models_allowed-empty'
    '.models_allowed += [5]|models_allowed-nonstring-element'
    '.models_allowed += ["opus"]|models_allowed-duplicate'
    '.efforts_allowed = "high"|efforts_allowed-not-a-list'
    '.efforts_allowed = []|efforts_allowed-empty'
    '.efforts_allowed += [5]|efforts_allowed-nonstring-element'
    '.efforts_allowed += ["high"]|efforts_allowed-duplicate'
    '.prohibited_profile_names = "opus-max"|prohibited-not-a-list'
    '.prohibited_profile_names += [5]|prohibited-nonstring-element'
    '.prohibited_profile_names += ["opus-max"]|prohibited-duplicate'
    '.profiles["opus-high"].maxTurns_bounds = 5|bounds-not-an-object'
    '.effort_constraints = null|effort_constraints-null'
    'del(.effort_constraints.fable)|effort_constraints-missing-tier'
    '.effort_constraints.haiku.bogus = 1|effort_constraints-extra-key'
    '.profiles["opus-high"].bogus = 1|profile-unknown-key'
    'del(.profiles["opus-high"].writes)|profile-missing-key'
    '.profiles["opus-high"].writes = "true"|writes-as-string'
    '.profiles["opus-high"].nesting = "false"|nesting-as-string'
    '.profiles["opus-high"].version = "1"|version-as-string'
    '.profiles["opus-high"].version = true|version-as-boolean'
    '.profiles["opus-high"].maxTurns = "24"|maxTurns-as-string'
    'del(.profiles["opus-high"].maxTurns_bounds.min)|bounds-missing-min'
    '.profiles["opus-high"].tools = "Read"|tools-not-a-list'
    '.profiles["opus-high"].tools = []|tools-empty'
    '.profiles["opus-high"].tools += ["Read"]|tools-not-unique'
    '.profiles["opus-high"].model = "gpt"|model-not-in-enum'
    '.profiles["opus-high"].effort = "ultra"|effort-not-in-enum'
    '.profiles.rogue = .profiles["opus-high"]|unauthorized-twelfth-profile'
    '.profiles["opus-max"] = .profiles["opus-high"]|prohibited-name-as-profile'
    'del(.profiles["opus-high"])|missing-required-profile'
  )
  local entry expr label
  for entry in "${cases[@]}"; do
    expr=${entry%%|*}; label=${entry##*|}
    fresh; jq_manifest "$expr"
    expect_reject "PROFILE_MANIFEST_SCHEMA_INVALID" "manifest schema: $label"
  done
  pass "every manifest schema/type/enum/uniqueness/closed-set violation fails closed"
}

# --- manifest: cross-property policy violations (jsonschema cannot express) --

test_manifest_cross_property_violations_rejected() {
  local cases=(
    '.effort_constraints.sonnet.fixed = "low"|ec-sonnet-fixed-contradicts-profile'
    '.effort_constraints.haiku.effort_present = true|ec-haiku-requires-effort-contradicts'
    '.effort_constraints.opus.prohibited = ["xhigh"]|ec-opus-prohibits-xhigh-hits-opus-xhigh'
    '.effort_constraints.fable.ceiling = "low"|ec-fable-ceiling-below-profile-effort'
    '.profiles["opus-high"].maxTurns = 99|concrete-maxTurns-out-of-bounds'
    '.profiles["opus-high"].maxTurns_bounds = {"min":30,"max":16}|bounds-min-gt-max'
    'del(.models_allowed[2])|profile-model-not-in-models_allowed'
    'del(.efforts_allowed[2])|profile-effort-not-in-efforts_allowed'
  )
  local entry expr label
  for entry in "${cases[@]}"; do
    expr=${entry%%|*}; label=${entry##*|}
    fresh; jq_manifest "$expr"
    expect_reject "PROFILE_MANIFEST_INCONSISTENT" "manifest policy: $label"
  done
  pass "every cross-property manifest policy violation fails closed"
}

# --- frontmatter: delimiters, duplicates, parse -----------------------------

test_frontmatter_bad_opening_rejected() {
  fresh
  printf 'oops\n%s' "$(cat "$D/opus-high.md")" > "$D/opus-high.md.tmp" && mv "$D/opus-high.md.tmp" "$D/opus-high.md"
  expect_reject "PROFILE_FRONTMATTER_INVALID" "frontmatter not opening with ---"
  pass "a profile file not opening with a frontmatter delimiter fails closed"
}

test_frontmatter_unterminated_rejected() {
  fresh
  awk 'BEGIN{c=0} /^---[[:space:]]*$/{c++; if(c==2) next} {print}' "$D/opus-high.md" > "$D/opus-high.md.tmp" \
    && mv "$D/opus-high.md.tmp" "$D/opus-high.md"
  expect_reject "PROFILE_FRONTMATTER_INVALID" "unterminated frontmatter"
  pass "an unterminated frontmatter block fails closed"
}

test_frontmatter_malformed_yaml_rejected() {
  fresh
  sed -i 's/^permissionMode: default$/permissionMode: [/' "$D/opus-high.md"
  expect_reject "PROFILE_FRONTMATTER_INVALID" "malformed YAML (unterminated flow)"
  pass "syntactically invalid frontmatter YAML fails closed"
}

test_frontmatter_duplicate_key_rejected() {
  local lines=(
    "name: opus-high"
    "model: opus"
    "EFFORT: high"
    "tools: [Read, Write, Edit, Bash, Grep, Glob]"
    "disallowedTools: [Agent]"
    "maxTurns: 24"
    "permissionMode: default"
    "profile_version: 1"
  )
  local line key
  for line in "${lines[@]}"; do
    key=${line%%:*}
    fresh
    dup_line "$D/opus-high.md" "$line"
    expect_reject "PROFILE_FRONTMATTER_DUPLICATE_KEY" "duplicate frontmatter key '$key'"
  done
  pass "a duplicate of any frontmatter key fails closed"
}

# --- frontmatter: schema-expressible violations (one per admitted key) -------

test_frontmatter_schema_violations_rejected() {
  # <sed-expr>|<label> — one-property mutations the frontmatter JSON Schema rejects.
  local cases=(
    's/^permissionMode: default$/permissionMode: [default]/|permissionMode-list'
    's/^permissionMode: default$/permissionMode: acceptEdits/|permissionMode-non-default'
    's/^description: .*/description: 12345/|description-number'
    's/^description: .*/description: true/|description-boolean'
    's/^profile_version: 1$/profile_version: true/|profile_version-boolean'
    's/^tools: \[Read, Write, Edit, Bash, Grep, Glob\]$/tools: Read/|tools-not-a-list'
    's/^disallowedTools: \[Agent\]$/disallowedTools: [Agent, Agent]/|disallowedTools-duplicate'
    's/^tools: \[Read, Write, Edit, Bash, Grep, Glob\]$/tools: [Read, Read]/|tools-duplicate'
    's/^permissionMode: default$/mcpServers: []/|unknown-admitted-key-mcpServers'
  )
  local entry expr label
  for entry in "${cases[@]}"; do
    expr=${entry%%|*}; label=${entry##*|}
    fresh; sed -i "$expr" "$D/opus-high.md"
    expect_reject "PROFILE_FRONTMATTER_SCHEMA_INVALID" "frontmatter schema: $label"
  done
  pass "every frontmatter schema/type/enum/uniqueness/closed-set violation fails closed"
}

# --- frontmatter: conditional-schema totality (presence proven by the schema) --
# EFFORT and disallowedTools presence/absence is proven declaratively by the
# closed frontmatter schema's conditional variants, BEFORE projection — so these
# fail at the schema layer, demonstrating the schema itself is total.

test_frontmatter_conditional_schema_rejected() {
  # non-haiku missing EFFORT
  fresh; sed -i '/^EFFORT: high$/d' "$D/opus-high.md"
  expect_reject "PROFILE_FRONTMATTER_SCHEMA_INVALID" "conditional: EFFORT-absent-on-non-haiku"
  # haiku carrying EFFORT
  fresh; sed -i '/^model: haiku$/a EFFORT: high' "$D/haiku-evidence.md"
  expect_reject "PROFILE_FRONTMATTER_SCHEMA_INVALID" "conditional: EFFORT-present-on-haiku"
  # non-nesting missing disallowedTools
  fresh; sed -i '/^disallowedTools: \[Agent\]$/d' "$D/opus-high.md"
  expect_reject "PROFILE_FRONTMATTER_SCHEMA_INVALID" "conditional: disallowedTools-absent-on-non-nesting"
  # nesting carrying disallowedTools
  fresh; sed -i '/^permissionMode: default$/i disallowedTools: [Agent]' "$D/fable-low.md"
  expect_reject "PROFILE_FRONTMATTER_SCHEMA_INVALID" "conditional: disallowedTools-present-on-nesting"
  # non-nesting disallowedTools not exactly [Agent]
  fresh; sed -i 's/^disallowedTools: \[Agent\]$/disallowedTools: [Read]/' "$D/opus-high.md"
  expect_reject "PROFILE_FRONTMATTER_SCHEMA_INVALID" "conditional: disallowedTools-not-Agent"
  pass "the frontmatter conditional variants are total and fail closed"
}

# --- frontmatter: whole-object projection divergence (VALUE differences) -----

test_frontmatter_projection_divergence_rejected() {
  # opus-high (non-haiku, non-nesting): value differences the schema admits but
  # the manifest projection rejects.
  local cases=(
    's/^name: opus-high$/name: opus-highest/|name'
    's/^model: opus$/model: sonnet/|model'
    's/^EFFORT: high$/EFFORT: low/|EFFORT-value'
    's/^maxTurns: 24$/maxTurns: 20/|maxTurns'
    's/^profile_version: 1$/profile_version: 9/|profile_version'
    's/^description: .*/description: Governed profile — a plausible but wrong description here./|description'
    's/^tools: \[Read, Write, Edit, Bash, Grep, Glob\]$/tools: [Read, Write, Edit, Bash, Glob, Grep]/|tools-order'
  )
  local entry expr label
  for entry in "${cases[@]}"; do
    expr=${entry%%|*}; label=${entry##*|}
    fresh; sed -i "$expr" "$D/opus-high.md"
    expect_reject "PROFILE_PROJECTION_MISMATCH" "projection field: $label"
  done
  pass "every frontmatter value divergence fails closed"
}

# --- directory / file set ---------------------------------------------------

test_missing_profile_file_rejected() {
  fresh; rm -f "$D/opus-high.md"
  expect_reject "PROFILE_FILE_MISSING" "manifest profile with no file"
  pass "a manifest profile missing its file fails closed"
}

test_unknown_profile_file_rejected() {
  fresh
  cp "$D/opus-high.md" "$D/rogue-profile.md"
  sed -i 's/^name: opus-high$/name: rogue-profile/' "$D/rogue-profile.md"
  expect_reject "PROFILE_FILE_UNKNOWN" "agent file with no manifest entry"
  pass "an ungoverned agent file fails closed"
}

test_prohibited_profile_file_rejected() {
  local bad
  for bad in opus-max fable-xhigh fable-max; do
    fresh
    cp "$D/opus-high.md" "$D/$bad.md"
    sed -i "s/^name: opus-high$/name: $bad/" "$D/$bad.md"
    expect_reject "PROFILE_PROHIBITED_PRESENT" "prohibited profile file $bad.md"
  done
  pass "adding a prohibited-name profile file fails closed"
}

# --- bindings: type-before-compare and agreement ----------------------------

bindings_run() {  # bindings_run <json> ; sets OUT/RC (not --quiet: pass cases assert PROFILES_OK)
  printf '%s' "$1" > "$SB/bindings.json"
  OUT=$("$V" --manifest "$M" --agents-dir "$D" --schemas-dir "$SDIR" --bindings "$SB/bindings.json" 2>&1)
  RC=$?
}

test_bindings_agreement_passes() {
  fresh
  bindings_run '{"opus-high":{"harness":"claude","model":"claude-opus-4-8","effort":"high","backups":[]}}'
  expect_code 0 "$RC" "an agreeing governed bindings entry must pass"$'\n'"$OUT"
  # positive control: a fully-typed backup (harness+model, effort optional) passes
  bindings_run '{"opus-high":{"harness":"claude","model":"claude-opus-4-8","effort":"high","backups":[{"harness":"codex","model":"gpt-5.5","effort":"high"}]}}'
  expect_code 0 "$RC" "a complete backup entry must pass"$'\n'"$OUT"
  pass "a bindings entry agreeing with the manifest (incl. a complete backup) passes"
}

test_bindings_legacy_only_is_noop() {
  fresh
  bindings_run '{"_comment":"legacy","implementer_balanced":{"model":"claude-sonnet-5"}}'
  expect_code 0 "$RC" "legacy-only bindings must be a clean no-op"$'\n'"$OUT"
  assert_contains "$OUT" "PROFILES_OK=11" "legacy-only bindings still validate the matrix"
  pass "a bindings file with only legacy names is a clean no-op"
}

test_bindings_type_and_agreement_rejected() {
  # <json>|<label> — a complete valid governed entry with exactly one property
  # broken, so each case isolates its own violation. Base opus-high entry:
  # {"harness":"claude","model":"claude-opus-4-8","effort":"high","backups":[]}.
  local cases=(
    '{"opus-high":{"harness":"claude","model":["claude-opus-4-8"],"effort":"high","backups":[]}}|B-model-list'
    '{"opus-high":{"harness":"claude","model":5,"effort":"high","backups":[]}}|model-number'
    '{"opus-high":{"harness":"claude","model":{"x":1},"effort":"high","backups":[]}}|model-object'
    '{"opus-high":{"harness":"claude","model":"claude-opus-4-8","effort":5,"backups":[]}}|effort-number'
    '{"opus-high":{"harness":"claude","model":"claude-opus-4-8","effort":"","backups":[]}}|effort-empty-string'
    '{"opus-high":{"harness":"claude","model":"claude-opus-4-8","effort":"low","backups":[]}}|effort-disagrees'
    '{"opus-high":{"harness":"claude","model":"claude-sonnet-5","effort":"high","backups":[]}}|model-tier-disagrees'
    '{"opus-high":{"harness":"claude","model":"claude-opus-4-8","effort":"high","backups":[],"bogus":1}}|unknown-entry-key'
    '{"opus-high":{"model":"claude-opus-4-8","effort":"high","backups":[]}}|missing-harness'
    '{"opus-high":{"harness":"claude","model":"claude-opus-4-8","effort":"high"}}|missing-backups'
    '{"opus-high":{"harness":"claude","model":"claude-opus-4-8","effort":"high","backups":[null]}}|backups-null-item'
    '{"opus-high":{"harness":"claude","model":"claude-opus-4-8","effort":"high","backups":[{"harness":"c","model":"x"},{"harness":"c","model":"x"}]}}|backups-duplicate'
    '{"opus-high":{"harness":"claude","model":"claude-opus-4-8","effort":"high","backups":[{"harness":"c","model":"x","bogus":1}]}}|backups-unknown-key'
    '{"opus-high":{"harness":"claude","model":"claude-opus-4-8","effort":"high","backups":[{"harness":"c"}]}}|backups-missing-model'
    '{"opus-high":{"harness":"claude","model":"claude-opus-4-8","effort":"high","backups":[{"model":"x"}]}}|backups-missing-harness'
    '{"opus-high":{"harness":"claude","model":"claude-opus-4-8","effort":"high","backups":[{"harness":"c","model":"x","effort":""}]}}|backups-empty-effort'
    '{"haiku-evidence":{"harness":"claude","model":"claude-haiku-4-5","effort":"","backups":[]}}|haiku-empty-effort'
    '{"haiku-evidence":{"harness":"claude","model":"claude-haiku-4-5","effort":"low","backups":[]}}|haiku-effort-present-but-tier-has-none'
  )
  local entry json label
  for entry in "${cases[@]}"; do
    json=${entry%%|*}; label=${entry##*|}
    fresh; bindings_run "$json"
    expect_code 1 "$RC" "bindings $label must be rejected"
    assert_contains "$OUT" "PROFILE_BINDINGS_MISMATCH" "bindings $label -> PROFILE_BINDINGS_MISMATCH"
  done
  pass "bindings type violations, missing keys, bad backups, and disagreements all fail closed"
}

# --- provenance: fingerprint pin + sidecar ----------------------------------

test_fingerprint_pin_and_sidecar() {
  fresh
  local fp
  fp=$("$V" --manifest "$M" --agents-dir "$D" --schemas-dir "$SDIR" 2>/dev/null | sed -n 's/^MATRIX_FINGERPRINT=//p')
  [ -n "$fp" ] || fail "validator must emit MATRIX_FINGERPRINT on success"
  runc --expect-fingerprint "$fp"
  expect_code 0 "$RC" "the correct fingerprint must pin"
  runc --expect-fingerprint "deadbeefdeadbeef"
  expect_code 1 "$RC" "a wrong fingerprint must be rejected"
  assert_contains "$OUT" "PROFILE_FINGERPRINT_MISMATCH" "a wrong pin has its own code"
  # sidecar is written on success
  "$V" --manifest "$M" --agents-dir "$D" --schemas-dir "$SDIR" --write-sidecar --quiet
  assert_present "$SB/manifest.fingerprint" "--write-sidecar writes the fingerprint sidecar on success"
  assert_grep "$fp" "$SB/manifest.fingerprint" "sidecar records the fingerprint"
  pass "fingerprint pinning and sidecar-on-success mirror the bindings-validate provenance surface"
}

test_sidecar_not_written_on_failure() {
  # A failed validation must NOT leave a valid-looking attestation. The sidecar
  # is written only after the whole atomic pass proves the matrix, so a failure
  # AFTER the fingerprint is computed (a late frontmatter/projection/bindings
  # failure) must still leave no sidecar.
  # (a) frontmatter schema failure (late, after fingerprint)
  fresh
  sed -i 's/^permissionMode: default$/permissionMode: [default]/' "$D/opus-high.md"
  "$V" --manifest "$M" --agents-dir "$D" --schemas-dir "$SDIR" --write-sidecar --quiet 2>/dev/null
  assert_absent "$SB/manifest.fingerprint" "no sidecar after a frontmatter-schema failure"
  # (b) projection failure (latest per-profile stage)
  fresh
  sed -i 's/^maxTurns: 24$/maxTurns: 20/' "$D/opus-high.md"
  "$V" --manifest "$M" --agents-dir "$D" --schemas-dir "$SDIR" --write-sidecar --quiet 2>/dev/null
  assert_absent "$SB/manifest.fingerprint" "no sidecar after a projection failure"
  # (c) bindings failure (last stage of all)
  fresh
  printf '%s' '{"opus-high":{"harness":"claude","model":"claude-opus-4-8","effort":"low","backups":[]}}' > "$SB/bindings.json"
  "$V" --manifest "$M" --agents-dir "$D" --schemas-dir "$SDIR" --bindings "$SB/bindings.json" --write-sidecar --quiet 2>/dev/null
  assert_absent "$SB/manifest.fingerprint" "no sidecar after a bindings failure"
  pass "a failed validation leaves no attestation sidecar"
}

test_preexisting_sidecar_invalidated_on_failure() {
  # The stale-authority invariant (DJ stale-audit class): a failed --write-sidecar
  # run must leave NO usable sidecar EVEN WHEN one already existed from a prior
  # successful run. No `fresh` between the two runs — the sandbox (and its sidecar)
  # persists across the mutation, exactly the scenario the round-4 test missed.
  fresh
  "$V" --manifest "$M" --agents-dir "$D" --schemas-dir "$SDIR" --write-sidecar --quiet
  assert_present "$SB/manifest.fingerprint" "a valid run first establishes a sidecar"
  # Now invalidate the matrix and re-run with --write-sidecar; the prior sidecar
  # must be gone, not left standing beside a now-invalid matrix.
  sed -i 's/^permissionMode: default$/permissionMode: [default]/' "$D/opus-high.md"
  "$V" --manifest "$M" --agents-dir "$D" --schemas-dir "$SDIR" --write-sidecar --quiet 2>/dev/null
  assert_absent "$SB/manifest.fingerprint" "a failed run removes the pre-existing sidecar"
  # And a subsequent successful run re-establishes it.
  sed -i 's/^permissionMode: \[default\]$/permissionMode: default/' "$D/opus-high.md"
  "$V" --manifest "$M" --agents-dir "$D" --schemas-dir "$SDIR" --write-sidecar --quiet
  assert_present "$SB/manifest.fingerprint" "a later valid run re-establishes the sidecar"
  pass "a failed validation invalidates any pre-existing attestation sidecar"
}

# --- usage ------------------------------------------------------------------

test_unknown_flag_is_usage_error() {
  OUT=$("$V" --bogus 2>&1); RC=$?
  expect_code 2 "$RC" "an unknown flag must be a usage error (exit 2)"
  pass "an unknown flag exits 2"
}

test_real_repo_is_coherent
test_sandbox_copy_is_coherent
test_canary_M_extra_root
test_canary_F_permissionMode_list
test_missing_python3_refuses
test_missing_pyyaml_refuses
test_missing_jsonschema_refuses
test_missing_committed_schema_refuses
test_manifest_missing_rejected
test_manifest_invalid_json_rejected
test_manifest_duplicate_key_rejected
test_manifest_duplicate_nested_key_rejected
test_manifest_schema_violations_rejected
test_manifest_cross_property_violations_rejected
test_frontmatter_bad_opening_rejected
test_frontmatter_unterminated_rejected
test_frontmatter_malformed_yaml_rejected
test_frontmatter_duplicate_key_rejected
test_frontmatter_schema_violations_rejected
test_frontmatter_conditional_schema_rejected
test_frontmatter_projection_divergence_rejected
test_missing_profile_file_rejected
test_unknown_profile_file_rejected
test_prohibited_profile_file_rejected
test_bindings_agreement_passes
test_bindings_legacy_only_is_noop
test_bindings_type_and_agreement_rejected
test_fingerprint_pin_and_sidecar
test_sidecar_not_written_on_failure
test_preexisting_sidecar_invalidated_on_failure
test_unknown_flag_is_usage_error

pass "fm-profile-matrix-check: all authority-pattern cases passed"

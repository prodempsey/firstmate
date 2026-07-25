#!/usr/bin/env bash
# Behavior tests for bin/fm-agent-dispatch-pretool.sh — the PERMANENT anti-
# inheritance PreToolUse guard (model-economy program, ORD-224 slice S5). Design
# authority: data/model-economy/ord-223-report.md §J (the 8 pinned denial codes,
# the 12 test cases, the fail-closed authority model), §U "S5", line 39 (manifest-
# driven governed identification; "any call with model containing fable that is
# NOT a manifest fable-profile is denied"), T.3 (the PreToolUse test group:
# "sample PreToolUse payloads for each denial code (8 codes), plus one native-
# exception-type payload"). Authority pattern: data/me-s3-profiles/design-ruling.md.
#
# Every case drives the guard exactly as the harness does: a PreToolUse JSON
# payload on stdin. ALLOW = exit 0, silent. DENY = exit 2, one "CODE: reason" line
# on stderr, empty stdout. The committed S3 manifest and S4 request schema are the
# real authority for the happy-path cases (they are the single source of truth the
# guard consumes); fail-closed engine/artifact cases use sandbox copies mutated to
# be missing/corrupt so no committed file is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

G="$ROOT/bin/fm-agent-dispatch-pretool.sh"
MANIFEST="$ROOT/docs/model-economy/governed-profiles.manifest.json"
SCHEMA="$ROOT/docs/model-economy/schemas/governed-dispatch-request.schema.json"
TMP_ROOT=$(fm_test_tmproot fm-agent-dispatch-pretool)

command -v jq >/dev/null 2>&1 || fail "test host must provide jq"
command -v python3 >/dev/null 2>&1 || fail "test host must provide python3 (the guard delegates matrix proof to the S3 validator)"

# A well-formed justification marker: a real UUIDv4 in the exact form the S4
# request schema pins for dispatch_request_id.
MK='[governed:dispatch_request_id=1b4e28ba-2fa1-4d1e-9f2a-abcabcabcabc]'

# run_case <label> <expected-exit> <expected-code-or-empty> <payload-json>
# Feeds the payload on stdin, asserts exit code, asserts the stderr denial code
# (when given), and asserts the ALLOW/ DENY stdout+stderr shape.
run_case() {
  local label=$1 want_exit=$2 want_code=$3 payload=$4
  local out err rc
  out=$(printf '%s' "$payload" | "$G" 2>"$TMP_ROOT/err"); rc=$?
  err=$(cat "$TMP_ROOT/err")
  expect_code "$want_exit" "$rc" "$label"
  if [ "$want_exit" = 0 ]; then
    [ -z "$out" ] || fail "$label: ALLOW must be silent on stdout, got: $out"
    [ -z "$err" ] || fail "$label: ALLOW must be silent on stderr, got: $err"
  else
    [ -z "$out" ] || fail "$label: DENY must keep stdout empty, got: $out"
    assert_contains "$err" "$want_code" "$label: expected denial code $want_code"
  fi
  pass "$label"
}

# ---------------------------------------------------------------------------
# §J's 12 pinned test cases (the design's own acceptance matrix).
# ---------------------------------------------------------------------------
run_case "J01 opus-high, model omitted -> MODEL_REQUIRED" \
  2 MODEL_REQUIRED '{"tool_input":{"subagent_type":"opus-high"}}'
run_case "J02 opus-high, opus -> allow" \
  0 "" '{"tool_input":{"subagent_type":"opus-high","model":"opus"}}'
run_case "J03 opus-high, sonnet -> MODEL_PROFILE_MISMATCH" \
  2 MODEL_PROFILE_MISMATCH '{"tool_input":{"subagent_type":"opus-high","model":"sonnet"}}'
run_case "J04 opus-max, opus -> PROFILE_NOT_GOVERNED" \
  2 PROFILE_NOT_GOVERNED '{"tool_input":{"subagent_type":"opus-max","model":"opus"}}'
run_case "J05 fable-medium, fable, no marker -> FABLE_JUSTIFICATION_MISSING" \
  2 FABLE_JUSTIFICATION_MISSING '{"tool_input":{"subagent_type":"fable-medium","model":"fable"}}'
run_case "J06 fable-medium, fable, marker -> allow" \
  0 "" "{\"tool_input\":{\"subagent_type\":\"fable-medium\",\"model\":\"fable\",\"description\":\"$MK\"}}"
run_case "J07 opus-xhigh, opus, no marker -> OPUS_XHIGH_JUSTIFICATION_MISSING" \
  2 OPUS_XHIGH_JUSTIFICATION_MISSING '{"tool_input":{"subagent_type":"opus-xhigh","model":"opus"}}'
run_case "J08 fork, model omitted -> allow (native exception)" \
  0 "" '{"tool_input":{"subagent_type":"fork"}}'
run_case "J09 fork, opus -> NATIVE_INHERITANCE_EXCEPTION_INVALID" \
  2 NATIVE_INHERITANCE_EXCEPTION_INVALID '{"tool_input":{"subagent_type":"fork","model":"opus"}}'
run_case "J10 general-purpose, haiku -> allow (ungoverned, model present)" \
  0 "" '{"tool_input":{"subagent_type":"general-purpose","model":"haiku"}}'
run_case "J11 empty subagent_type, fable -> PROFILE_REQUIRED" \
  2 PROFILE_REQUIRED '{"tool_input":{"subagent_type":"","model":"fable"}}'
run_case "J12 opus-high nested under sonnet-high-engineer -> NESTING_PROHIBITED" \
  2 NESTING_PROHIBITED '{"tool_input":{"subagent_type":"opus-high","model":"opus"},"agent_type":"sonnet-high-engineer"}'

# ---------------------------------------------------------------------------
# One positive control per governed profile (model-profile agreement, projected
# from the committed matrix — the single source of truth). Opus-xhigh and every
# fable-* carry the marker; the rest need none.
# ---------------------------------------------------------------------------
positive_case() {
  local profile=$1 model desc
  model=$(jq -r --arg p "$profile" '.profiles[$p].model' "$MANIFEST")
  desc=""
  case "$profile" in opus-xhigh|fable-*) desc=$MK ;; esac
  run_case "POS $profile, $model -> allow" 0 "" \
    "{\"tool_input\":{\"subagent_type\":\"$profile\",\"model\":\"$model\",\"description\":\"$desc\"}}"
}
while IFS= read -r profile; do
  positive_case "$profile"
done < <(jq -r '.profiles | keys[]' "$MANIFEST")

# ---------------------------------------------------------------------------
# S3 Fable-ceiling interplay: every prohibited_profile_names entry matches a
# governed prefix but is not pinned, so the ceiling is enforced structurally as
# PROFILE_NOT_GOVERNED (fable's high ceiling; opus's high-is-top-governed ceiling).
# ---------------------------------------------------------------------------
while IFS= read -r bad; do
  model=${bad%%-*}
  run_case "CEIL $bad, $model -> PROFILE_NOT_GOVERNED" \
    2 PROFILE_NOT_GOVERNED "{\"tool_input\":{\"subagent_type\":\"$bad\",\"model\":\"$model\"}}"
done < <(jq -r '.prohibited_profile_names[]' "$MANIFEST")

# ---------------------------------------------------------------------------
# Line-39 refinement: an explicit Fable model on a non-empty ungoverned type is a
# Fable child smuggled past the fable-* justification gate -> FABLE_MODEL_UNGOVERNED.
# §J's sketch would default-allow this; the design-decision table (line 39) denies.
# ---------------------------------------------------------------------------
run_case "L39a general-purpose, fable -> FABLE_MODEL_UNGOVERNED" \
  2 FABLE_MODEL_UNGOVERNED '{"tool_input":{"subagent_type":"general-purpose","model":"fable"}}'
run_case "L39b general-purpose, claude-fable-5[1m] -> FABLE_MODEL_UNGOVERNED" \
  2 FABLE_MODEL_UNGOVERNED '{"tool_input":{"subagent_type":"general-purpose","model":"claude-fable-5[1m]"}}'
run_case "L39c Explore, opus -> allow (explicit non-Fable on ungoverned)" \
  0 "" '{"tool_input":{"subagent_type":"Explore","model":"opus"}}'

# ---------------------------------------------------------------------------
# Universal model-omission is truly universal: even an ungoverned built-in type
# must name a model.
# ---------------------------------------------------------------------------
run_case "UNI general-purpose, model omitted -> MODEL_REQUIRED" \
  2 MODEL_REQUIRED '{"tool_input":{"subagent_type":"general-purpose"}}'
run_case "UNI empty type, opus -> PROFILE_REQUIRED (any governed alias)" \
  2 PROFILE_REQUIRED '{"tool_input":{"subagent_type":"","model":"opus"}}'

# ---------------------------------------------------------------------------
# Native-exception narrowness (T.3): a NON-allowlisted type with no model is still
# denied — the carve-out is fork ONLY.
# ---------------------------------------------------------------------------
run_case "NAT non-fork ungoverned, no model -> MODEL_REQUIRED (narrow)" \
  2 MODEL_REQUIRED '{"tool_input":{"subagent_type":"claude","description":"anything"}}'
run_case "NAT fork with fable -> NATIVE_INHERITANCE_EXCEPTION_INVALID" \
  2 NATIVE_INHERITANCE_EXCEPTION_INVALID '{"tool_input":{"subagent_type":"fork","model":"fable"}}'

# ---------------------------------------------------------------------------
# Nesting authority (the caller), settled before the target: a nesting-permitted
# fable parent may dispatch; a nesting-barred caller is denied regardless of what
# it dispatches (including an otherwise-valid target and a fork).
# ---------------------------------------------------------------------------
run_case "NEST fable-high parent dispatching fable-low+marker -> allow" \
  0 "" "{\"tool_input\":{\"subagent_type\":\"fable-low\",\"model\":\"fable\",\"description\":\"$MK\"},\"agent_type\":\"fable-high\"}"
run_case "NEST sonnet parent dispatching general-purpose -> NESTING_PROHIBITED" \
  2 NESTING_PROHIBITED '{"tool_input":{"subagent_type":"general-purpose","model":"haiku"},"agent_type":"opus-medium"}'
run_case "NEST barred caller dispatching fork -> NESTING_PROHIBITED" \
  2 NESTING_PROHIBITED '{"tool_input":{"subagent_type":"fork"},"agent_type":"sonnet-high-reviewer"}'
run_case "NEST ungoverned caller (not in matrix) -> not nesting-constrained" \
  0 "" '{"tool_input":{"subagent_type":"general-purpose","model":"haiku"},"agent_type":"general-purpose"}'

# ---------------------------------------------------------------------------
# Justification marker rigor: presence AND a well-formed S4 dispatch_request_id.
# ---------------------------------------------------------------------------
run_case "MARK opus-xhigh, empty request-id -> OPUS_XHIGH_JUSTIFICATION_MISSING" \
  2 OPUS_XHIGH_JUSTIFICATION_MISSING '{"tool_input":{"subagent_type":"opus-xhigh","model":"opus","description":"[governed:dispatch_request_id=]"}}'
run_case "MARK fable-high, malformed request-id -> FABLE_JUSTIFICATION_MISSING" \
  2 FABLE_JUSTIFICATION_MISSING '{"tool_input":{"subagent_type":"fable-high","model":"fable","description":"[governed:dispatch_request_id=not-a-uuid]"}}'
run_case "MARK opus-xhigh, marker amid other text -> allow" \
  0 "" "{\"tool_input\":{\"subagent_type\":\"opus-xhigh\",\"model\":\"opus\",\"description\":\"why: opus insufficient. $MK done.\"}}"

# ---------------------------------------------------------------------------
# The matcher scopes to Agent: a non-Agent tool_name is passed through untouched.
# ---------------------------------------------------------------------------
run_case "SCOPE tool_name=Bash -> allow (not our matcher)" \
  0 "" '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}'
run_case "SCOPE tool_name=Agent explicit, omitted model -> MODEL_REQUIRED" \
  2 MODEL_REQUIRED '{"tool_name":"Agent","tool_input":{"subagent_type":"opus-high"}}'

# ---------------------------------------------------------------------------
# Fail-closed artifact-AUTHORITY paths (FC-002/FC-004: an invalid/corrupt policy
# artifact must DENY, never fall through to allow — QA qa-me-s5-q163). The guard
# proves each artifact through its own landed validator/authority cross-check
# BEFORE reading a value, so a corrupt-but-shallowly-plausible artifact cannot
# create a false allow. Sandbox copies only — no committed file is touched.
# ---------------------------------------------------------------------------

# Empty / unparseable payload.
run_case "FC empty payload -> GUARD_PAYLOAD_UNREADABLE" \
  2 GUARD_PAYLOAD_UNREADABLE ''
run_case "FC non-JSON payload -> GUARD_PAYLOAD_UNREADABLE" \
  2 GUARD_PAYLOAD_UNREADABLE 'not json at all'

# --- S3 matrix authority (QA finding 1). The guard delegates to the landed S3
#     validator, so ANY manifest that validator rejects is a fail-closed deny, never
#     a false allow. Fixtures project from the committed matrix and mutate one thing.
guard_manifest_case() {  # <label> <jq-mutation>
  local label=$1 prog=$2 bad="$TMP_ROOT/m.$RANDOM.json" out rc
  jq "$prog" "$MANIFEST" > "$bad"
  out=$(printf '%s' '{"tool_input":{"subagent_type":"opus-high","model":"opus"}}' \
    | "$G" --manifest "$bad" 2>"$TMP_ROOT/err"); rc=$?
  expect_code 2 "$rc" "$label exit"
  assert_contains "$(cat "$TMP_ROOT/err")" GUARD_MANIFEST_UNVERIFIED "$label code"
  [ -z "$out" ] || fail "$label leaked stdout on a deny: $out"
  pass "$label"
}
# The exact finding-1 repro: a prohibited profile inserted into .profiles would
# bypass the ceiling under a shallow check; the landed validator rejects it.
guard_manifest_case "FC injected fable-xhigh profile -> GUARD_MANIFEST_UNVERIFIED" \
  '.profiles["fable-xhigh"] = (.profiles["fable-high"] | .effort = "xhigh")'
guard_manifest_case "FC wrong field type (models_allowed as string) -> GUARD_MANIFEST_UNVERIFIED" \
  '.models_allowed = "haiku"'
guard_manifest_case "FC tampered pin (opus-high model->fable) -> GUARD_MANIFEST_UNVERIFIED" \
  '.profiles["opus-high"].model = "fable"'
guard_manifest_case "FC wrong schema_version -> GUARD_MANIFEST_UNVERIFIED" \
  '.schema_version = "bogus/v9"'

# Duplicate profile key (raw text — jq would dedupe; the validator has a duplicate-key
# guard). Inject a second top-level "profile_version" after the opening brace.
dupe="$TMP_ROOT/dupe-manifest.json"
awk 'NR==1{print; print "  \"profile_version\": 2,"; next} 1' "$MANIFEST" > "$dupe"
out=$(printf '%s' '{"tool_input":{"subagent_type":"opus-high","model":"opus"}}' \
  | "$G" --manifest "$dupe" 2>"$TMP_ROOT/err"); rc=$?
expect_code 2 "$rc" "FC duplicate manifest key exit"
assert_contains "$(cat "$TMP_ROOT/err")" GUARD_MANIFEST_UNVERIFIED "FC duplicate manifest key code"
pass "FC duplicate manifest key -> GUARD_MANIFEST_UNVERIFIED"

# Missing manifest file.
out=$(printf '%s' '{"tool_input":{"subagent_type":"opus-high","model":"opus"}}' \
  | "$G" --manifest "$TMP_ROOT/nope.json" 2>"$TMP_ROOT/err"); rc=$?
expect_code 2 "$rc" "FC missing manifest exit"
assert_contains "$(cat "$TMP_ROOT/err")" GUARD_MANIFEST_UNVERIFIED "FC missing manifest code"
pass "FC missing manifest -> GUARD_MANIFEST_UNVERIFIED"

# --- S4 request-schema authority (QA finding 2). A gated dispatch with a VALID
#     marker is used, so the ONLY possible denial is the schema-authority check —
#     proving it fires before (and independent of) the marker match.
guard_schema_case() {  # <label> <jq-mutation>
  local label=$1 prog=$2 bad="$TMP_ROOT/s.$RANDOM.json" out rc
  jq "$prog" "$SCHEMA" > "$bad"
  out=$(printf '%s' "{\"tool_input\":{\"subagent_type\":\"fable-high\",\"model\":\"fable\",\"description\":\"$MK\"}}" \
    | "$G" --request-schema "$bad" 2>"$TMP_ROOT/err"); rc=$?
  expect_code 2 "$rc" "$label exit"
  assert_contains "$(cat "$TMP_ROOT/err")" GUARD_SCHEMA_UNVERIFIED "$label code"
  [ -z "$out" ] || fail "$label leaked stdout on a deny: $out"
  pass "$label"
}
# The exact finding-2 repro: a permissive pattern would turn the Fable gate into an
# allow under a shallow check; the canonical cross-check rejects it.
guard_schema_case "FC permissive request-id pattern -> GUARD_SCHEMA_UNVERIFIED" \
  '.properties.dispatch_request_id.pattern = "^.*$"'
# shellcheck disable=SC2016  # single quotes are intentional: this is a jq program, and $id is jq's field-name literal, not a shell variable
guard_schema_case "FC wrong schema \$id -> GUARD_SCHEMA_UNVERIFIED" \
  '.["$id"] = "firstmate/not-the-request/v9"'
guard_schema_case "FC removed request-id pattern -> GUARD_SCHEMA_UNVERIFIED" \
  'del(.properties.dispatch_request_id.pattern)'

# Missing request schema — but ONLY a justification-gated profile consults it, so a
# non-gated dispatch still passes (the schema is proven lazily, inside require_marker).
out=$(printf '%s' '{"tool_input":{"subagent_type":"fable-low","model":"fable","description":"'"$MK"'"}}' \
  | "$G" --request-schema "$TMP_ROOT/nope-schema.json" 2>"$TMP_ROOT/err"); rc=$?
expect_code 2 "$rc" "FC missing schema (gated) exit"
assert_contains "$(cat "$TMP_ROOT/err")" GUARD_SCHEMA_UNVERIFIED "FC missing schema (gated) code"
pass "FC missing schema on gated profile -> GUARD_SCHEMA_UNVERIFIED"

out=$(printf '%s' '{"tool_input":{"subagent_type":"opus-high","model":"opus"}}' \
  | "$G" --request-schema "$TMP_ROOT/nope-schema.json" 2>"$TMP_ROOT/err"); rc=$?
expect_code 0 "$rc" "FC missing schema (ungated) allow"
pass "FC missing schema on non-gated profile -> allow (schema proven lazily, only when gated)"

# jq absent -> fail closed. Shadow PATH so jq cannot be found.
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
for t in cat sed grep tr printf env cut; do
  real=$(command -v "$t" 2>/dev/null) && ln -sf "$real" "$FAKEBIN/$t"
done
real_bash=$(command -v bash); ln -sf "$real_bash" "$FAKEBIN/bash"
out=$(printf '%s' '{"tool_input":{"subagent_type":"opus-high"}}' \
  | PATH="$FAKEBIN" "$G" 2>"$TMP_ROOT/err"); rc=$?
expect_code 2 "$rc" "FC jq-absent exit"
assert_contains "$(cat "$TMP_ROOT/err")" GUARD_ENGINE_UNAVAILABLE "FC jq-absent code"
pass "FC jq absent -> GUARD_ENGINE_UNAVAILABLE (fail closed, unlike the maintenance guard)"

# Usage error is exit 64, never confused with a policy verdict.
"$G" --bogus-flag </dev/null 2>"$TMP_ROOT/err"; rc=$?
expect_code 64 "$rc" "USAGE bad flag exit"
pass "USAGE unknown flag -> exit 64"

pass "all fm-agent-dispatch-pretool cases passed"

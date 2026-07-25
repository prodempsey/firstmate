#!/usr/bin/env bash
# Behavior tests for bin/fm-dispatch-validate.sh — the fail-closed validator for a
# governed dispatch request (model-economy program, ORD-224 slice S4). Design
# authority: data/model-economy/ord-223-report.md §F (dispatch request schema,
# cross-field rules 1-13, the one valid + two denied examples), §H (the enumerated
# Opus-insufficiency denylist), §T.1 (dispatch schema rejections); brief §6 (the
# must-reject list). Authority pattern (binding precedent):
# data/me-s3-profiles/design-ruling.md §4 (the exhaustive invalid-fixture matrix)
# and its class precedent data/dj-orders-s2/design-ruling.md.
#
# The validator proves a request by structural conformance to committed CLOSED
# JSON Schemas (request + policy + the landed S3 manifest) plus the §F named
# cross-field/cross-artifact rules (profile projection, task-class membership,
# the justification gates, parent linkage, live repo-state agreement), with
# python3+jsonschema hard prerequisites that refuse rather than degrade. This
# suite pairs every T.1 rule, every dedicated §F denial code, the structural
# closed-schema properties, and the fail-closed engine/artifact paths with a
# one-property-at-a-time fixture built by projecting a valid base request from the
# committed manifest and mutating exactly one thing, plus valid-document positive
# controls (one per governed profile).
#
# Fully sandboxed: base requests are projected from the committed manifest into a
# mktemp root; the committed schemas/policy/manifest are always the real authority.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

V="$ROOT/bin/fm-dispatch-validate.sh"
MANIFEST_SRC="$ROOT/docs/model-economy/governed-profiles.manifest.json"
POLICY_SRC="$ROOT/docs/model-economy/governed-dispatch-policy.json"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-validate)

command -v jq >/dev/null 2>&1 || fail "test host must provide jq"
command -v python3 >/dev/null 2>&1 || fail "test host must provide python3"
command -v git >/dev/null 2>&1 || fail "test host must provide git"

SB="$TMP_ROOT/sandbox"
REQ="$SB/request.json"     # the mutated request under test
mkdir -p "$SB"

# The current in-session id every base request's parent_task_id resolves to, so
# parent-linkage (§F rule 8) passes unless a test deliberately breaks it.
SID="parent-in-session-s4"

# base_request <profile> > file : project a valid dispatch request from the
# committed manifest for <profile>. Derives every immutable-profile field from the
# matrix (single source of truth) and fills the conditionally-required fields
# (next_lower_model + its justification for non-haiku; opus_xhigh_justification for
# opus-xhigh; evidence_packet_id for every opus-*/fable-* per §F; why_opus_is_insufficient
# for fable).
base_request() {
  python3 - "$MANIFEST_SRC" "$1" "$SID" <<'PY'
import json, sys
manifest, profile, sid = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
p = manifest["profiles"][profile]
model = p["model"]
effort = p["effort"] if p["effort"] is not None else "none"
tiers = ["haiku", "sonnet", "opus", "fable"]
req = {
    "schema_version": "firstmate/governed-dispatch-request/v1",
    "dispatch_request_id": "8f2c1e4a-6b3d-4a91-9c7e-2d5f8a1b3c60",
    "parent_task_id": sid,
    "parent_decision_id": None,
    "task_type": "scout",
    "task_class": "routine_investigation",
    "requested_role": "worker",
    "selected_profile": profile,
    "requested_model": model,
    "configured_effort": effort,
    "repository": "firstmate",
    "scope": "bounded scope for the base fixture",
    "exclusions": [],
    "write_allowed": p["writes"],
    "allowed_tools": list(p["tools"]),
    "max_turns": p["maxTurns"],
    "nesting_allowed": p["nesting"],
    "evidence_packet_id": None,
    "session_continuation_candidate": False,
    "routing_reason": "bounded work suited to this profile",
    "policy_version": "routing-policy v1",
}
if model != "haiku":
    req["next_lower_model"] = tiers[tiers.index(model) - 1]
    req["why_next_lower_model_is_insufficient"] = (
        "the lower tier's prior bounded attempt left the reasoning unresolved (see report)")
if profile == "opus-xhigh":
    req["opus_xhigh_justification"] = (
        "opus-high dispatch task-q6 stalled on the cross-file state machine; remaining work bounded "
        "with explicit stop conditions")
if model in ("opus", "fable"):
    # §F field table: evidence_packet_id required for every opus-* or fable-* profile.
    req["evidence_packet_id"] = "pkt-base"
if model == "fable":
    req["why_opus_is_insufficient"] = (
        "a prior opus-high dispatch (task-n1) could not span the three-runtime state machine within its "
        "turn budget; the remaining synthesis is long-horizon across two repos")
json.dump(req, sys.stdout, indent=2)
PY
}

PROFILES=(haiku-evidence haiku-log-compressor sonnet-high-engineer sonnet-high-reviewer \
          opus-low opus-medium opus-high opus-xhigh fable-low fable-medium fable-high)

# run: validate $REQ against the REAL committed artifacts; --session-id resolves
# the base parent linkage. OUT gets combined output, RC the exit code.
run() {
  OUT=$("$V" "$REQ" --session-id "$SID" "$@" 2>&1)
  RC=$?
}

# expect_reject <code> <label>: run and assert exit 1 + a stable code substring.
expect_reject() {
  run --quiet
  expect_code 1 "$RC" "$2 must be rejected"
  assert_contains "$OUT" "$1" "$2 -> $1"
}

# mut <profile> <jq-expr>: write a base request for <profile> mutated by one jq
# expression into $REQ.
mut() {
  base_request "$1" | jq "$2" > "$REQ"
}

# --- positive controls ------------------------------------------------------

test_committed_artifacts_are_coherent() {
  # The committed policy and manifest validate against their own committed schemas
  # (proven implicitly: any base request passing means both loaded and schema-checked).
  local prof
  for prof in "${PROFILES[@]}"; do
    base_request "$prof" > "$REQ"
    run
    expect_code 0 "$RC" "a projected base request for $prof must validate"$'\n'"$OUT"
    assert_contains "$OUT" "DISPATCH_OK=$prof" "$prof base request is authoritative"
    assert_contains "$OUT" "REQUEST_FINGERPRINT=" "$prof base request emits a fingerprint"
  done
  pass "a valid base request projected from the committed matrix validates for every governed profile"
}

test_parent_linkage_via_state_meta() {
  base_request opus-high > "$REQ"
  local state="$SB/state"
  mkdir -p "$state"
  echo "window=fm-x" > "$state/$SID.meta"
  # No --session-id: linkage must resolve through state/<id>.meta instead.
  OUT=$("$V" "$REQ" --state-dir "$state" 2>&1); RC=$?
  expect_code 0 "$RC" "parent_task_id must resolve via state/<id>.meta"$'\n'"$OUT"
  pass "parent linkage resolves through a tracked state/<id>.meta (§F rule 8)"
}

# --- the two §F canonical examples ------------------------------------------

test_report_example_denial_1_missing_model() {
  # §F "Denial 1 — omitted model": requested_model null → MODEL_REQUIRED, ahead of
  # every other missing-field complaint.
  mut haiku-evidence '.requested_model=null'
  expect_reject "MODEL_REQUIRED" "report denial-1 (omitted model)"
  pass "§F denial-1: an omitted model is MODEL_REQUIRED before any structural error"
}

test_report_example_denial_2_fable_without_justification() {
  # §F "Denial 2 — Fable dispatch without Opus-insufficiency justification":
  # why_opus empty AND lazy phrasing in routing_reason → FABLE_JUSTIFICATION_MISSING,
  # even though max_turns 32 is a valid in-bounds choice (not the concrete 30).
  mut fable-medium '.why_opus_is_insufficient=""|.why_next_lower_model_is_insufficient=""|.max_turns=32|.routing_reason="this task is important and affects architecture across two repos"'
  expect_reject "FABLE_JUSTIFICATION_MISSING" "report denial-2 (fable w/o justification)"
  pass "§F denial-2: a Fable dispatch with no Opus-insufficiency reasoning fails closed"
}

# --- engine / fail-closed (no degradation) ----------------------------------

test_missing_python3_refuses() {
  base_request opus-high > "$REQ"
  local nopy="$SB/nopy"
  mkdir -p "$nopy"
  ln -sf "$(command -v bash)" "$nopy/bash"
  OUT=$(PATH="$nopy" bash "$V" "$REQ" --session-id "$SID" --quiet 2>&1); RC=$?
  expect_code 1 "$RC" "an absent python3 must fail closed"
  assert_contains "$OUT" "DISPATCH_VALIDATOR_UNAVAILABLE" "missing python3 refuses"
  assert_not_contains "$OUT" "DISPATCH_OK" "no success without the engine"
  pass "a missing python3 refuses rather than degrading"
}

test_missing_jsonschema_refuses() {
  base_request opus-high > "$REQ"
  OUT=$(FM_DISPATCH_SIMULATE_MISSING=jsonschema "$V" "$REQ" --session-id "$SID" --quiet 2>&1); RC=$?
  expect_code 1 "$RC" "an absent jsonschema must fail closed"
  assert_contains "$OUT" "DISPATCH_VALIDATOR_UNAVAILABLE" "missing jsonschema refuses"
  assert_not_contains "$OUT" "DISPATCH_OK" "no success without the schema engine"
  pass "a missing jsonschema refuses rather than degrading"
}

test_missing_committed_schema_refuses() {
  base_request opus-high > "$REQ"
  local emptydir="$SB/noschemas"
  mkdir -p "$emptydir"
  OUT=$("$V" "$REQ" --session-id "$SID" --schemas-dir "$emptydir" --quiet 2>&1); RC=$?
  expect_code 1 "$RC" "an absent committed schema must fail closed"
  assert_contains "$OUT" "DISPATCH_VALIDATOR_UNAVAILABLE" "missing committed schema refuses"
  pass "a missing committed schema refuses (schemas are the declarative authority)"
}

test_policy_and_manifest_absence_refuses() {
  base_request opus-high > "$REQ"
  run --quiet --policy "$SB/no-policy.json"
  expect_code 1 "$RC" "an absent policy must fail closed"
  assert_contains "$OUT" "DISPATCH_POLICY_MISSING" "missing policy refuses"
  run --quiet --manifest "$SB/no-manifest.json"
  expect_code 1 "$RC" "an absent manifest must fail closed"
  assert_contains "$OUT" "DISPATCH_MANIFEST_MISSING" "missing manifest refuses"
  pass "an absent policy or profile-matrix artifact fails closed"
}

test_policy_and_manifest_malformed_refuses() {
  base_request opus-high > "$REQ"
  # A policy missing a required key must fail its own closed schema.
  jq 'del(.task_classes)' "$POLICY_SRC" > "$SB/bad-policy.json"
  run --quiet --policy "$SB/bad-policy.json"
  expect_code 1 "$RC" "a schema-invalid policy must fail closed"
  assert_contains "$OUT" "DISPATCH_POLICY_INVALID" "malformed policy refuses"
  # A manifest with an unknown root key must fail the S3 manifest schema.
  jq '.bogus=1' "$MANIFEST_SRC" > "$SB/bad-manifest.json"
  run --quiet --manifest "$SB/bad-manifest.json"
  expect_code 1 "$RC" "a schema-invalid manifest must fail closed"
  assert_contains "$OUT" "DISPATCH_MANIFEST_INVALID" "malformed manifest refuses"
  pass "a malformed policy or manifest fails closed before any projection is trusted"
}

test_request_missing_and_unparseable() {
  OUT=$("$V" "$SB/nonexistent.json" --session-id "$SID" --quiet 2>&1); RC=$?
  expect_code 1 "$RC" "an absent request file must fail closed"
  assert_contains "$OUT" "DISPATCH_REQUEST_MISSING" "missing request refuses"
  printf '{ not json' > "$REQ"
  expect_reject "DISPATCH_INVALID" "unparseable request JSON"
  printf '{"schema_version":"a","schema_version":"b"}' > "$REQ"
  expect_reject "DISPATCH_INVALID" "duplicate top-level key"
  pass "a missing, unparseable, or duplicate-keyed request fails closed"
}

# --- structural closed-schema violations (DISPATCH_SCHEMA_INVALID) -----------

test_structural_schema_violations_rejected() {
  # <jq-expr>|<label> — one-property mutations the closed request schema rejects.
  # Built on opus-high (a non-haiku, non-nesting, writing profile) unless noted.
  local cases=(
    '.bogus=1|unknown-property'
    '.dispatch_request_id="not-a-uuid"|dispatch_request_id-bad-uuid'
    '.task_type="deploy"|task_type-not-in-enum'
    '.requested_model="gpt"|requested_model-not-in-enum'
    '.configured_effort="max"|configured_effort-max-excluded'
    '.next_lower_model="gpt"|next_lower_model-not-in-enum'
    '.HEAD="xyz"|HEAD-not-40-hex'
    '.runtime_state_fingerprint="deadbeef"|runtime_state_fingerprint-bad-format'
    '.worktree="relative/path"|worktree-not-absolute'
    '.allowed_tools=[]|allowed_tools-empty'
    '.allowed_tools=(.allowed_tools + [.allowed_tools[0]])|allowed_tools-not-unique'
    '.max_turns="24"|max_turns-not-integer'
    '.write_allowed="true"|write_allowed-not-boolean'
    '.nesting_allowed="false"|nesting_allowed-not-boolean'
    '.session_continuation_candidate=1|session_continuation_candidate-not-boolean'
    '.exclusions=(.exclusions + ["a","a"])|exclusions-not-unique'
    '.policy_version="routing-policy v2"|policy_version-wrong-const'
    'del(.routing_reason)|routing_reason-missing-required'
    'del(.repository)|repository-missing-required'
    '.scope=[]|scope-empty-array'
  )
  local entry expr label
  for entry in "${cases[@]}"; do
    expr=${entry%%|*}; label=${entry##*|}
    mut opus-high "$expr"
    expect_reject "DISPATCH_SCHEMA_INVALID" "structural: $label"
  done
  pass "every structural schema/type/enum/format/uniqueness/closed-set violation fails closed"
}

test_every_root_property_wrong_type() {
  # One wrong-TYPE mutation for EVERY one of the 31 admitted root properties, built
  # on the opus-high base and asserting the specific code. This makes the "one
  # invalid fixture per closed-schema property" claim literally true (QA
  # fixture-discipline finding). Boolean properties get a string; every other
  # property gets `false`; schema_version keeps its dedicated gate code.
  # <property>|<jq-wrong-type>|<code>
  local cases=(
    'schema_version|.schema_version=false|SCHEMA_VERSION_UNSUPPORTED'
    'dispatch_request_id|.dispatch_request_id=false|DISPATCH_SCHEMA_INVALID'
    'parent_task_id|.parent_task_id=false|DISPATCH_SCHEMA_INVALID'
    'parent_decision_id|.parent_decision_id=false|DISPATCH_SCHEMA_INVALID'
    'task_type|.task_type=false|DISPATCH_SCHEMA_INVALID'
    'task_class|.task_class=false|DISPATCH_SCHEMA_INVALID'
    'requested_role|.requested_role=false|DISPATCH_SCHEMA_INVALID'
    'selected_profile|.selected_profile=false|DISPATCH_SCHEMA_INVALID'
    'requested_model|.requested_model=false|DISPATCH_SCHEMA_INVALID'
    'configured_effort|.configured_effort=false|DISPATCH_SCHEMA_INVALID'
    'repository|.repository=false|DISPATCH_SCHEMA_INVALID'
    'worktree|.worktree=false|DISPATCH_SCHEMA_INVALID'
    'branch|.branch=false|DISPATCH_SCHEMA_INVALID'
    'HEAD|.HEAD=false|DISPATCH_SCHEMA_INVALID'
    'runtime_state_fingerprint|.runtime_state_fingerprint=false|DISPATCH_SCHEMA_INVALID'
    'scope|.scope=false|DISPATCH_SCHEMA_INVALID'
    'exclusions|.exclusions=false|DISPATCH_SCHEMA_INVALID'
    'write_allowed|.write_allowed="x"|DISPATCH_SCHEMA_INVALID'
    'allowed_tools|.allowed_tools=false|DISPATCH_SCHEMA_INVALID'
    'max_turns|.max_turns="x"|DISPATCH_SCHEMA_INVALID'
    'nesting_allowed|.nesting_allowed="x"|DISPATCH_SCHEMA_INVALID'
    'evidence_packet_id|.evidence_packet_id=false|DISPATCH_SCHEMA_INVALID'
    'session_continuation_candidate|.session_continuation_candidate="x"|DISPATCH_SCHEMA_INVALID'
    'routing_reason|.routing_reason=false|DISPATCH_SCHEMA_INVALID'
    'next_lower_model|.next_lower_model=false|DISPATCH_SCHEMA_INVALID'
    'why_next_lower_model_is_insufficient|.why_next_lower_model_is_insufficient=false|DISPATCH_SCHEMA_INVALID'
    'opus_xhigh_justification|.opus_xhigh_justification=false|DISPATCH_SCHEMA_INVALID'
    'why_opus_is_insufficient|.why_opus_is_insufficient=false|DISPATCH_SCHEMA_INVALID'
    'captain_exception_id|.captain_exception_id=false|DISPATCH_SCHEMA_INVALID'
    'policy_version|.policy_version=false|DISPATCH_SCHEMA_INVALID'
    'binding_fingerprint|.binding_fingerprint=false|DISPATCH_SCHEMA_INVALID'
  )
  local entry prop expr code seen=0
  for entry in "${cases[@]}"; do
    prop=${entry%%|*}; expr=${entry#*|}; code=${expr##*|}; expr=${expr%|*}
    mut opus-high "$expr"
    expect_reject "$code" "wrong-type $prop"
    seen=$((seen + 1))
  done
  [ "$seen" -eq 31 ] || fail "expected 31 root-property fixtures, ran $seen"
  pass "every one of the 31 admitted root properties has a wrong-type fixture that fails closed"
}

test_required_field_absence() {
  # Deleting each ALWAYS-required field fails closed; the three with a dedicated
  # presence code (schema_version/model/profile) report it, the rest are structural.
  local cases=(
    'schema_version|SCHEMA_VERSION_UNSUPPORTED'
    'requested_model|MODEL_REQUIRED'
    'selected_profile|PROFILE_REQUIRED'
    'dispatch_request_id|DISPATCH_SCHEMA_INVALID'
    'parent_task_id|DISPATCH_SCHEMA_INVALID'
    'task_type|DISPATCH_SCHEMA_INVALID'
    'task_class|DISPATCH_SCHEMA_INVALID'
    'requested_role|DISPATCH_SCHEMA_INVALID'
    'configured_effort|DISPATCH_SCHEMA_INVALID'
    'repository|DISPATCH_SCHEMA_INVALID'
    'scope|DISPATCH_SCHEMA_INVALID'
    'write_allowed|DISPATCH_SCHEMA_INVALID'
    'allowed_tools|DISPATCH_SCHEMA_INVALID'
    'max_turns|DISPATCH_SCHEMA_INVALID'
    'nesting_allowed|DISPATCH_SCHEMA_INVALID'
    'session_continuation_candidate|DISPATCH_SCHEMA_INVALID'
    'routing_reason|DISPATCH_SCHEMA_INVALID'
    'policy_version|DISPATCH_SCHEMA_INVALID'
  )
  local entry field code
  for entry in "${cases[@]}"; do
    field=${entry%%|*}; code=${entry##*|}
    mut opus-high "del(.$field)"
    expect_reject "$code" "missing required $field"
  done
  pass "every always-required field, when absent, fails closed with its expected code"
}

# --- §F dedicated denial codes (the T.1 must-reject list) --------------------

test_schema_version_gate() {
  mut opus-high '.schema_version="firstmate/governed-dispatch-request/v2"'
  expect_reject "SCHEMA_VERSION_UNSUPPORTED" "schema_version v2"
  mut opus-high 'del(.schema_version)'
  expect_reject "SCHEMA_VERSION_UNSUPPORTED" "schema_version absent"
  mut opus-high '.schema_version=5'
  expect_reject "SCHEMA_VERSION_UNSUPPORTED" "schema_version mistyped"
  pass "an unsupported/absent/mistyped schema_version fails closed ahead of structural errors"
}

test_model_and_profile_required() {
  mut opus-high '.requested_model=null'
  expect_reject "MODEL_REQUIRED" "requested_model null"
  mut opus-high 'del(.requested_model)'
  expect_reject "MODEL_REQUIRED" "requested_model absent"
  mut opus-high '.selected_profile=null'
  expect_reject "PROFILE_REQUIRED" "selected_profile null"
  mut opus-high 'del(.selected_profile)'
  expect_reject "PROFILE_REQUIRED" "selected_profile absent"
  pass "a null/absent model or profile gets its specific shared-with-hook code"
}

test_profile_not_governed() {
  mut opus-high '.selected_profile="not-a-real-profile"'
  expect_reject "PROFILE_NOT_GOVERNED" "unknown profile"
  # The prohibited names are never in the matrix, so they resolve here too.
  local bad
  for bad in opus-max fable-xhigh fable-max; do
    mut opus-high ".selected_profile=\"$bad\""
    expect_reject "PROFILE_NOT_GOVERNED" "prohibited profile $bad"
  done
  pass "an unknown or prohibited profile name fails closed (§F rule 5)"
}

test_task_class_unknown() {
  mut opus-high '.task_class="made_up_class"'
  expect_reject "TASK_CLASS_UNKNOWN" "task_class outside taxonomy"
  pass "a task_class outside the committed governed taxonomy fails closed (§F rule 12)"
}

test_model_profile_mismatch() {
  # A valid tier that disagrees with the profile's pinned model.
  mut haiku-evidence '.requested_model="opus"'
  expect_reject "MODEL_PROFILE_MISMATCH" "haiku profile + opus model"
  mut opus-high '.requested_model="sonnet"'
  expect_reject "MODEL_PROFILE_MISMATCH" "opus profile + sonnet model"
  pass "requested_model disagreeing with the profile's pinned model fails closed (§F rule 1)"
}

test_profile_effort_mismatch() {
  # generic effort mismatch (a valid enum value, wrong for the profile)
  mut opus-high '.configured_effort="low"'
  expect_reject "PROFILE_EFFORT_MISMATCH" "opus-high + low effort"
  # rule 3: any sonnet-* not high
  mut sonnet-high-engineer '.configured_effort="medium"'
  expect_reject "PROFILE_EFFORT_MISMATCH" "sonnet profile not high"
  # haiku must be "none": setting an effort disagrees with the null-tier projection
  mut haiku-evidence '.configured_effort="low"'
  expect_reject "PROFILE_EFFORT_MISMATCH" "haiku profile carrying an effort"
  pass "configured_effort disagreeing with the profile's pinned effort fails closed (§F rules 2/3)"
}

test_opus_max_and_fable_ceiling_rejected() {
  # Opus max: 'max' is excluded from the governed effort enum by construction, so
  # it fails at the closed schema — the strongest fail-closed layer (§F field table).
  mut opus-high '.configured_effort="max"'
  expect_reject "DISPATCH_SCHEMA_INVALID" "opus max (enum-excluded)"
  mut fable-medium '.configured_effort="max"'
  expect_reject "DISPATCH_SCHEMA_INVALID" "fable max (enum-excluded)"
  # Fable xhigh: xhigh is a real enum member (opus-xhigh uses it) but wrong for a
  # fable profile, so it is caught by the effort projection.
  mut fable-medium '.configured_effort="xhigh"'
  expect_reject "PROFILE_EFFORT_MISMATCH" "fable xhigh (over the fable ceiling)"
  mut fable-high '.configured_effort="xhigh"'
  expect_reject "PROFILE_EFFORT_MISMATCH" "fable-high xhigh"
  pass "Opus max and Fable xhigh/max all fail closed (enum-excluded or projection-caught)"
}

test_opus_xhigh_justification_required() {
  mut opus-xhigh '.opus_xhigh_justification=""'
  expect_reject "OPUS_XHIGH_JUSTIFICATION_MISSING" "opus-xhigh empty justification"
  mut opus-xhigh '.opus_xhigh_justification=null'
  expect_reject "OPUS_XHIGH_JUSTIFICATION_MISSING" "opus-xhigh null justification"
  pass "opus-xhigh without a non-empty justification fails closed (§F rule 4)"
}

test_fable_justification_required() {
  mut fable-medium '.why_opus_is_insufficient=""'
  expect_reject "FABLE_JUSTIFICATION_MISSING" "fable empty why_opus"
  mut fable-medium '.why_opus_is_insufficient=null'
  expect_reject "FABLE_JUSTIFICATION_MISSING" "fable null why_opus"
  # denylist phrase directly in the justification
  mut fable-high '.why_opus_is_insufficient="this is important and high blast radius"'
  expect_reject "FABLE_JUSTIFICATION_MISSING" "fable denylist phrase in why_opus"
  # denylist phrase dodged into routing_reason (§F: denies regardless of field)
  mut fable-low '.routing_reason="fable is the strongest model for this"'
  expect_reject "FABLE_JUSTIFICATION_MISSING" "fable denylist phrase in routing_reason"
  pass "a Fable dispatch missing or using an enumerated-insufficient justification fails closed (§F rule 6/§H)"
}

test_nesting_prohibited() {
  # a non-nesting profile claiming nesting
  mut opus-high '.nesting_allowed=true'
  expect_reject "NESTING_PROHIBITED" "opus-high claiming nesting"
  mut sonnet-high-engineer '.nesting_allowed=true'
  expect_reject "NESTING_PROHIBITED" "sonnet-engineer claiming nesting"
  # a fable (nesting-capable) profile falsely claiming non-nesting is also a
  # projection divergence on the immutable nesting field.
  mut fable-medium '.nesting_allowed=false'
  expect_reject "NESTING_PROHIBITED" "fable-medium denying its nesting"
  pass "a nesting_allowed value diverging from the profile's nesting capability fails closed (§F rule 7)"
}

test_immutable_profile_projection() {
  mut opus-high '.write_allowed=false'
  expect_reject "PROFILE_IMMUTABLE_MISMATCH" "write_allowed diverging from profile"
  mut opus-high '.allowed_tools=["Read"]'
  expect_reject "PROFILE_IMMUTABLE_MISMATCH" "allowed_tools diverging from profile"
  mut opus-high '.allowed_tools=["Read","Write","Edit","Bash","Glob","Grep"]'
  expect_reject "PROFILE_IMMUTABLE_MISMATCH" "allowed_tools order diverging from profile"
  mut opus-high '.max_turns=999'
  expect_reject "PROFILE_IMMUTABLE_MISMATCH" "max_turns above profile bounds"
  mut opus-high '.max_turns=1'
  expect_reject "PROFILE_IMMUTABLE_MISMATCH" "max_turns below profile bounds"
  pass "write/tools/max_turns diverging from the immutable-profile projection fails closed"
}

test_next_lower_model_rules() {
  mut opus-high '.next_lower_model="haiku"'
  expect_reject "NEXT_LOWER_MODEL_INVALID" "next_lower_model not one tier below"
  mut opus-high 'del(.next_lower_model)'
  expect_reject "NEXT_LOWER_MODEL_INVALID" "next_lower_model absent on non-haiku"
  mut opus-high '.why_next_lower_model_is_insufficient=""'
  expect_reject "NEXT_LOWER_MODEL_INVALID" "next_lower justification empty"
  pass "a wrong/absent next_lower_model or empty justification fails closed (§F field table)"
}

test_evidence_packet_rules() {
  # §F field table: evidence_packet_id required for EVERY opus-* and fable-* profile.
  local prof
  for prof in opus-low opus-medium opus-high opus-xhigh fable-low fable-medium fable-high; do
    mut "$prof" '.evidence_packet_id=null'
    expect_reject "EVIDENCE_PACKET_MISSING" "$prof without evidence packet"
  done
  # a haiku/sonnet dispatch is NOT decision-class and needs no packet (positive control)
  base_request sonnet-high-engineer > "$REQ"
  run
  expect_code 0 "$RC" "a non-decision-class profile needs no evidence packet"$'\n'"$OUT"
  # a present packet id that does not resolve under a supplied packets dir
  local pkts="$SB/pkts"
  mkdir -p "$pkts"
  base_request opus-high > "$REQ"
  run --quiet --packets-dir "$pkts"
  expect_code 1 "$RC" "a dangling packet reference must fail closed"
  assert_contains "$OUT" "EVIDENCE_PACKET_MISSING" "dangling packet reference refuses"
  # once the packet exists, it resolves (deep §M validation is deferred to S7)
  echo '{}' > "$pkts/pkt-base.json"
  run --packets-dir "$pkts"
  expect_code 0 "$RC" "a resolvable packet reference passes"$'\n'"$OUT"
  pass "every Opus/Fable dispatch requires a present, resolvable evidence packet (§F rule 10 / field table)"
}

test_binding_fingerprint_format() {
  # §F: binding_fingerprint is a sha256 fingerprint (bare 64-hex, as its producer
  # bin/fm-bindings-validate.sh emits). A non-fingerprint string is a structural
  # false pass the round-1 schema admitted (QA FC-003); it must fail closed now.
  mut opus-high '.binding_fingerprint="x"'
  expect_reject "DISPATCH_SCHEMA_INVALID" "binding_fingerprint non-fingerprint string"
  mut opus-high '.binding_fingerprint="sha256:'"$(printf '0%.0s' {1..64})"'"'
  expect_reject "DISPATCH_SCHEMA_INVALID" "binding_fingerprint with a sha256: prefix (producer emits bare hex)"
  mut opus-high '.binding_fingerprint="ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789"'
  expect_reject "DISPATCH_SCHEMA_INVALID" "binding_fingerprint uppercase hex"
  mut opus-high '.binding_fingerprint=false'
  expect_reject "DISPATCH_SCHEMA_INVALID" "binding_fingerprint wrong type"
  # a well-formed bare 64-hex fingerprint is accepted (positive control)
  mut opus-high '.binding_fingerprint="'"$(printf 'a%.0s' {1..64})"'"'
  run
  expect_code 0 "$RC" "a well-formed binding_fingerprint is accepted"$'\n'"$OUT"
  pass "binding_fingerprint is enforced as a real sha256 fingerprint, not merely present (§F / QA FC-003)"
}

test_captain_exception_resolution() {
  # present exception id, no orders source available -> unverifiable -> refuse
  mut opus-high '.captain_exception_id="cap-override-7"'
  expect_reject "CAPTAIN_EXCEPTION_INVALID" "captain exception with no orders source"
  # present but absent from the supplied orders file -> refuse
  echo "an unrelated captain instruction" > "$SB/orders.md"
  run --quiet --captain-orders "$SB/orders.md"
  expect_code 1 "$RC" "an unattributable exception id must fail closed"
  assert_contains "$OUT" "CAPTAIN_EXCEPTION_INVALID" "exception not in orders refuses"
  # present and found in the orders file -> accepted
  echo "captain order cap-override-7 authorized the override" > "$SB/orders.md"
  run --captain-orders "$SB/orders.md"
  expect_code 0 "$RC" "an attributable exception id is accepted"$'\n'"$OUT"
  pass "a captain_exception_id is accepted only when attributable to a captured instruction (§F rule 11)"
}

test_parent_linkage_missing() {
  # a parent_task_id that is neither the in-session id nor a tracked meta
  base_request opus-high | jq '.parent_task_id="ghost-task-zz"' > "$REQ"
  OUT=$("$V" "$REQ" --session-id "$SID" --state-dir "$SB/empty-state" --quiet 2>&1); RC=$?
  expect_code 1 "$RC" "an unresolvable parent must fail closed"
  assert_contains "$OUT" "PARENT_LINKAGE_MISSING" "unresolvable parent refuses"
  pass "a parent_task_id resolving to no tracked task and not the in-session id fails closed (§F rule 8)"
}

# --- §F rule 9: live repo-state agreement (harmless git probe) ---------------

# make_repo: a real temp git repo; echoes "HEAD BRANCH FINGERPRINT".
make_repo() {
  local rd="$SB/repo"
  rm -rf "$rd"
  mkdir -p "$rd"
  git -C "$rd" init -q
  git -C "$rd" config user.email t@example.com
  git -C "$rd" config user.name t
  echo hello > "$rd/f"
  git -C "$rd" add f
  git -C "$rd" commit -qm init
  local head branch fp
  head=$(git -C "$rd" rev-parse HEAD)
  branch=$(git -C "$rd" rev-parse --abbrev-ref HEAD)
  fp="sha256:$(python3 -c "import hashlib;print(hashlib.sha256(('firstmate\n%s\n%s\nclean'%('$branch','$head')).encode()).hexdigest())")"
  echo "$head $branch $fp"
}

# ship_request > $REQ : a ship-type opus-high request bound to the live temp repo.
ship_request() {
  read -r H B F < <(make_repo)
  base_request opus-high \
    | jq --arg h "$H" --arg b "$B" --arg w "$SB/repo" --arg f "$F" \
        '.task_type="ship"|.worktree=$w|.branch=$b|.HEAD=$h|.runtime_state_fingerprint=$f' \
    > "$REQ"
}

test_repo_state_agreement() {
  ship_request
  run
  expect_code 0 "$RC" "a ship request matching live repo state must validate"$'\n'"$OUT"
  pass "an exact-state (ship) request matching the live worktree passes (§F rule 9)"
}

test_repo_state_stale_rejected() {
  ship_request
  jq '.HEAD="0123456789abcdef0123456789abcdef01234567"' "$REQ" > "$REQ.tmp" && mv "$REQ.tmp" "$REQ"
  expect_reject "REPO_STATE_STALE" "stale claimed HEAD"
  ship_request
  jq '.branch="fm/some-other-branch"' "$REQ" > "$REQ.tmp" && mv "$REQ.tmp" "$REQ"
  expect_reject "REPO_STATE_STALE" "stale claimed branch"
  ship_request
  jq '.runtime_state_fingerprint="sha256:'"$(printf '0%.0s' {1..64})"'"' "$REQ" > "$REQ.tmp" && mv "$REQ.tmp" "$REQ"
  expect_reject "REPO_STATE_STALE" "mismatched runtime_state_fingerprint"
  ship_request
  jq 'del(.worktree)' "$REQ" > "$REQ.tmp" && mv "$REQ.tmp" "$REQ"
  expect_reject "REPO_STATE_STALE" "ship request missing required worktree"
  pass "a stale/mismatched/incomplete exact-repo-state claim fails closed (§F rule 9)"
}

# --- provenance: request fingerprint pin ------------------------------------

test_fingerprint_pin() {
  base_request opus-high > "$REQ"
  local fp
  fp=$("$V" "$REQ" --session-id "$SID" 2>/dev/null | sed -n 's/^REQUEST_FINGERPRINT=//p')
  [ -n "$fp" ] || fail "validator must emit REQUEST_FINGERPRINT on success"
  run --expect-fingerprint "$fp"
  expect_code 0 "$RC" "the correct fingerprint must pin"
  run --expect-fingerprint "deadbeefdeadbeef"
  expect_code 1 "$RC" "a wrong fingerprint must be rejected"
  assert_contains "$OUT" "DISPATCH_FINGERPRINT_MISMATCH" "a wrong pin has its own code"
  pass "request fingerprint pinning mirrors the S3 provenance surface"
}

# --- provenance: sidecar lifecycle (mirrors the S3 stale-authority contract) --

SIDE() { echo "${REQ%.json}.fingerprint"; }

test_sidecar_written_after_proof() {
  base_request opus-high > "$REQ"
  rm -f "$(SIDE)"
  "$V" "$REQ" --session-id "$SID" --write-sidecar --quiet
  assert_present "$(SIDE)" "--write-sidecar writes the attestation on success"
  local fp
  fp=$("$V" "$REQ" --session-id "$SID" 2>/dev/null | sed -n 's/^REQUEST_FINGERPRINT=//p')
  assert_grep "$fp" "$(SIDE)" "the sidecar records the request fingerprint"
  pass "a proven request writes its attestation sidecar (write-last)"
}

test_sidecar_not_written_on_failure() {
  # A failed validation must leave NO attestation. Cover both an EARLY failure
  # (before the fingerprint is computed) and a LATE one (after it).
  # (a) early: a structural schema failure
  base_request opus-high | jq '.bogus=1' > "$REQ"
  rm -f "$(SIDE)"
  "$V" "$REQ" --session-id "$SID" --write-sidecar --quiet 2>/dev/null
  assert_absent "$(SIDE)" "no sidecar after an early (structural) failure"
  # (b) late: a projection failure, which happens after the fingerprint is computed
  base_request opus-high | jq '.max_turns=999' > "$REQ"
  rm -f "$(SIDE)"
  "$V" "$REQ" --session-id "$SID" --write-sidecar --quiet 2>/dev/null
  assert_absent "$(SIDE)" "no sidecar after a late (projection) failure"
  pass "a failed validation leaves no attestation sidecar (write-last, early and late)"
}

test_preexisting_sidecar_invalidated_on_failure() {
  # The stale-authority invariant: a failed --write-sidecar run must leave NO usable
  # sidecar EVEN WHEN one already existed from a prior successful run. No regenerate
  # of $REQ between the two runs — the request file (and its sidecar) persists.
  base_request opus-high > "$REQ"
  "$V" "$REQ" --session-id "$SID" --write-sidecar --quiet
  assert_present "$(SIDE)" "a valid run first establishes a sidecar"
  # invalidate the request in place, then re-run with --write-sidecar
  jq '.max_turns=999' "$REQ" > "$REQ.tmp" && mv "$REQ.tmp" "$REQ"
  "$V" "$REQ" --session-id "$SID" --write-sidecar --quiet 2>/dev/null
  assert_absent "$(SIDE)" "a failed run removes the pre-existing sidecar"
  # a subsequent valid run re-establishes it
  base_request opus-high > "$REQ"
  "$V" "$REQ" --session-id "$SID" --write-sidecar --quiet
  assert_present "$(SIDE)" "a later valid run re-establishes the sidecar"
  pass "a failed validation invalidates any pre-existing attestation sidecar"
}

test_sidecar_invalidation_failure_refuses() {
  # If the pre-existing sidecar cannot be removed (read-only dir), the validator
  # must refuse loudly BEFORE validation rather than proceed under stale authority.
  # Root bypasses directory permissions, so skip there.
  if [ "$(id -u)" = "0" ]; then
    pass "sidecar-invalidation-failure refusal (skipped: root cannot be denied unlink)"
    return
  fi
  local mdir="$SB/mdir-inval"
  rm -rf "$mdir"; mkdir -p "$mdir"
  base_request opus-high > "$mdir/request.json"
  "$V" "$mdir/request.json" --session-id "$SID" --write-sidecar --quiet
  assert_present "$mdir/request.fingerprint" "a valid run first establishes the sidecar"
  # invalidate the request, then deny unlink by making the dir read-only
  jq '.max_turns=999' "$mdir/request.json" > "$mdir/request.json.tmp" && mv "$mdir/request.json.tmp" "$mdir/request.json"
  chmod 0555 "$mdir"
  OUT=$("$V" "$mdir/request.json" --session-id "$SID" --write-sidecar --quiet 2>&1); RC=$?
  chmod 0755 "$mdir"   # restore BEFORE asserting so cleanup always succeeds
  expect_code 1 "$RC" "an unlink-refused invalidation must fail closed"
  assert_contains "$OUT" "DISPATCH_SIDECAR_INVALIDATION_FAILED" "a proven-failed invalidation refuses with its own code"
  assert_not_contains "$OUT" "PROFILE_IMMUTABLE_MISMATCH" "the refusal precedes validation, not after it"
  pass "a sidecar that cannot be invalidated makes the validator refuse (no silent stale authority)"
}

test_sidecar_write_failure_refuses() {
  # Symmetric hygiene: a proven request whose attestation cannot be written
  # (read-only dir, no pre-existing sidecar) is a clean typed refusal, never a
  # traceback or a partial temp file. Root bypasses permissions, so skip.
  if [ "$(id -u)" = "0" ]; then
    pass "sidecar-write-failure refusal (skipped: root cannot be denied write)"
    return
  fi
  local mdir="$SB/mdir-write"
  rm -rf "$mdir"; mkdir -p "$mdir"
  base_request opus-high > "$mdir/request.json"
  chmod 0555 "$mdir"
  OUT=$("$V" "$mdir/request.json" --session-id "$SID" --write-sidecar --quiet 2>&1); RC=$?
  chmod 0755 "$mdir"
  expect_code 1 "$RC" "an unwritable sidecar on an otherwise-valid request must fail closed"
  assert_contains "$OUT" "DISPATCH_SIDECAR_WRITE_FAILED" "an unwritable attestation refuses with its own code"
  assert_absent "$mdir/request.fingerprint.tmp" "no partial temp sidecar is left behind"
  pass "an attestation that cannot be written makes the validator refuse cleanly"
}

# --- usage ------------------------------------------------------------------

test_usage_errors() {
  OUT=$("$V" --bogus 2>&1); RC=$?
  expect_code 2 "$RC" "an unknown flag is a usage error"
  OUT=$("$V" 2>&1); RC=$?
  expect_code 2 "$RC" "a missing request path is a usage error"
  pass "unknown flags and a missing request path exit 2"
}

test_committed_artifacts_are_coherent
test_parent_linkage_via_state_meta
test_report_example_denial_1_missing_model
test_report_example_denial_2_fable_without_justification
test_missing_python3_refuses
test_missing_jsonschema_refuses
test_missing_committed_schema_refuses
test_policy_and_manifest_absence_refuses
test_policy_and_manifest_malformed_refuses
test_request_missing_and_unparseable
test_structural_schema_violations_rejected
test_every_root_property_wrong_type
test_required_field_absence
test_binding_fingerprint_format
test_schema_version_gate
test_model_and_profile_required
test_profile_not_governed
test_task_class_unknown
test_model_profile_mismatch
test_profile_effort_mismatch
test_opus_max_and_fable_ceiling_rejected
test_opus_xhigh_justification_required
test_fable_justification_required
test_nesting_prohibited
test_immutable_profile_projection
test_next_lower_model_rules
test_evidence_packet_rules
test_captain_exception_resolution
test_parent_linkage_missing
test_repo_state_agreement
test_repo_state_stale_rejected
test_fingerprint_pin
test_sidecar_written_after_proof
test_sidecar_not_written_on_failure
test_preexisting_sidecar_invalidated_on_failure
test_sidecar_invalidation_failure_refuses
test_sidecar_write_failure_refuses
test_usage_errors

#!/usr/bin/env bash
# bin/fm-agent-dispatch-pretool.sh — the PERMANENT anti-inheritance PreToolUse
# guard for Agent dispatch (model-economy program, ORD-224 slice S5). This is the
# standing, fleet-wide structural backstop that closes the silent-model-inheritance
# gap: it fires on every Agent tool call (registered PreToolUse, matcher "Agent")
# and DENIES fail-closed any dispatch that omits a model, names a governed profile
# with a contradicting model, invents an ungoverned profile name, reaches an
# Opus-xhigh / Fable tier without a justification marker, nests from a profile
# barred from nesting, or misuses the one native-inheritance carve-out (fork).
#
# It PERMANENTLY REPLACES the temporary ORD-227 maintenance guard
# (~/.claude/skills/krakenloop-fable-maintenance/hooks/agent-guard.sh, matcher
# "Agent|Task"). The two must NEVER run side by side — never-two-competing-policy-
# systems. The cutover/stand-down is a separate, captain-gated act, DESIGNED (not
# performed) here; see docs/model-economy/slice5-notes.md "Cutover".
#
# Design authority (pinned): data/model-economy/ord-223-report.md §J (PreToolUse
# design: hook-input K-matrix, validation sequence, the 8 pinned denial codes,
# the bash+jq sketch, the 12 test cases), §U "S5" (slice contract, rollback,
# highest-risk note), line 39 (governed-profile identification: manifest-driven,
# "any call with model containing fable that is NOT a manifest fable-profile is
# denied"), T.3 (test group). Consumes the LANDED S3 profile matrix
# (docs/model-economy/governed-profiles.manifest.json — the single source of truth
# for the governed set, per-profile pinned model, and per-profile nesting flag)
# and the S4 request schema (docs/model-economy/schemas/governed-dispatch-request.
# schema.json — the pinned dispatch_request_id form the justification marker must
# carry). Authority pattern: data/me-s3-profiles/design-ruling.md; consume-the-
# landed-manifest precedent: bin/fm-dispatch-validate.sh (S4).
#
# AUTHORITY MODEL (FC-001 / FC-002, the program's ruling architecture). A dispatch
# is allowed ONLY when this one pass positively proves, against the landed matrix,
# that: (fork) it is the allowlisted native carve-out with no smuggled model; or
# (non-fork) it carries an explicit model AND, if it names a governed profile, that
# profile is pinned, its model equals the matrix pin, its Opus-xhigh/Fable tier
# carries a well-formed justification marker, and the calling agent (if any) is
# permitted to nest. In EVERY other state — no model, an unpinned governed-prefix
# name, a Fable model on a non-Fable profile, a missing marker, a nesting-barred
# caller, or an engine/matrix/schema this pass cannot PROVE authoritative — authority
# defaults to NONE and the dispatch is DENIED. Authority is never inferred from the
# absence of a failing check; an artifact we cannot positively prove authoritative is
# a refusal-to-discharge (deny), never a warn-and-pass.
#
# Artifacts are proven through their OWN landed validators before any value is read
# from them (QA qa-me-s5-q163): the S3 matrix through bin/fm-profile-matrix-check.sh
# (closed schema + eleven-profile set + duplicate keys + prohibited-name rule +
# frontmatter projection), and the S4 request schema through an identity ($id) and
# canonical-pattern cross-check against the guard's own pinned root of trust. A shallow
# field check is NOT proof and would let a corrupt-but-plausible artifact create a
# false allow (an injected profile past the ceiling, or a weakened request-id pattern).
#
# Engine: jq is a hard prerequisite of the guard; python3+jsonschema are hard
# prerequisites of the S3 validator the guard delegates to. Any absent → fail closed
# (deny). This is a DELIBERATE difference from the maintenance guard, which fails OPEN
# on absent tooling because it is narrowly maintenance-scoped; the permanent guard is
# the fleet-wide policy floor and fails closed, matching S3/S4's "refuse if the engine
# is absent".
#
# I/O contract (matches the repo's PreToolUse convention — bin/fm-arm-pretool-
# check.sh, and the temp guard this replaces):
#   ALLOW  exit 0, no output.
#   DENY   exit 2, one "CODE: reason" line on stderr, stdout empty (Claude blocks
#          on exit 2 and surfaces stderr as the reason; empty stdout is required).
#   USAGE  exit 64 on a bad invocation flag (never confused with a policy verdict).
# The guard writes NO state and no ledger event: post-dispatch telemetry and the
# routing ledger are slice S6's owned surface (§K); S5 stays a pure gate so a hot
# hook path has no state coupling. Denials are visible via the stderr reason the
# harness already captures.
#
# Denial codes:
#   §J pinned (8):
#     MODEL_REQUIRED                         non-fork Agent call with no model
#     PROFILE_REQUIRED                       governed-tier model, subagent_type empty
#     MODEL_PROFILE_MISMATCH                 pinned profile, model != its matrix pin
#     PROFILE_NOT_GOVERNED                   reserved prefix but not one of the pinned
#                                            profiles (typo/invented/prohibited name —
#                                            the Fable ceiling: fable-xhigh/fable-max
#                                            and opus-max land here)
#     FABLE_JUSTIFICATION_MISSING            fable-* profile, no [governed:...] marker
#     OPUS_XHIGH_JUSTIFICATION_MISSING       opus-xhigh, no [governed:...] marker
#     NESTING_PROHIBITED                     calling agent's profile forbids nesting
#     NATIVE_INHERITANCE_EXCEPTION_INVALID   fork call with an explicit model
#   Line-39 refinement (beyond §J's default-allow; documented, tested):
#     FABLE_MODEL_UNGOVERNED                 model contains "fable" on a non-empty
#                                            ungoverned subagent_type — an explicit
#                                            Fable child smuggled past the fable-*
#                                            justification gate
#   Fail-closed engine/artifact refusals (honest infra codes, never a fabricated
#   policy verdict — FC-002/FC-004: refuse-to-discharge, do not invent a block):
#     GUARD_ENGINE_UNAVAILABLE               jq missing
#     GUARD_PAYLOAD_UNREADABLE               empty/unparseable PreToolUse payload
#     GUARD_MANIFEST_UNVERIFIED              the S3 matrix did not pass its landed
#                                            validator (missing/corrupt/schema-invalid/
#                                            injected profile/projection drift/validator
#                                            engine unavailable) — carries its reason
#     GUARD_SCHEMA_UNVERIFIED                the S4 request schema is not the authoritative
#                                            committed one (missing/non-object/wrong $id/
#                                            non-canonical request-id pattern); checked
#                                            only when a justification gate needs it
set -u

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

PAYLOAD_FILE=""
MANIFEST=""
REQUEST_SCHEMA=""
want=
for a in "$@"; do
  if [ -n "$want" ]; then
    case "$want" in
      payload) PAYLOAD_FILE=$a ;;
      manifest) MANIFEST=$a ;;
      schema) REQUEST_SCHEMA=$a ;;
    esac
    want=
    continue
  fi
  case "$a" in
    --payload) want=payload ;;
    --payload=*) PAYLOAD_FILE=${a#--payload=} ;;
    --manifest) want=manifest ;;
    --manifest=*) MANIFEST=${a#--manifest=} ;;
    --request-schema) want=schema ;;
    --request-schema=*) REQUEST_SCHEMA=${a#--request-schema=} ;;
    -h|--help)
      sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "fm-agent-dispatch-pretool: unknown argument '$a'" >&2
      exit 64
      ;;
  esac
done
if [ -n "$want" ]; then
  echo "fm-agent-dispatch-pretool: option --$want requires a value" >&2
  exit 64
fi

[ -n "$MANIFEST" ] || MANIFEST="$FM_ROOT/docs/model-economy/governed-profiles.manifest.json"
[ -n "$REQUEST_SCHEMA" ] || REQUEST_SCHEMA="$FM_ROOT/docs/model-economy/schemas/governed-dispatch-request.schema.json"

# The canonical dispatch_request_id form (S4 request schema, §F), pinned here as the
# guard's OWN root of trust. The guard proves the S4 request schema is authoritative
# by cross-checking its identity and this exact pattern before honoring a justification
# marker, and matches the marker against THIS pinned value — never the mutable file —
# so a schema altered to a permissive pattern cannot weaken the gate (QA qa-me-s5-q163
# #2). Keep byte-identical to .properties.dispatch_request_id.pattern in the committed
# governed-dispatch-request.schema.json; the guard fails closed if the two diverge.
CANONICAL_REQUEST_ID_PATTERN='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'

# --- allow / deny transports ------------------------------------------------
# deny: one stable "CODE: reason" line to stderr, exit 2, stdout untouched.
deny() {
  printf '%s: %s\n' "$1" "$2" >&2
  exit 2
}
allow() { exit 0; }

# --- engine (fail closed) ---------------------------------------------------
command -v jq >/dev/null 2>&1 || deny GUARD_ENGINE_UNAVAILABLE "jq is a hard prerequisite for the anti-inheritance guard; refusing rather than degrading to a weaker check"

# --- payload ----------------------------------------------------------------
if [ -n "$PAYLOAD_FILE" ]; then
  [ -f "$PAYLOAD_FILE" ] || deny GUARD_PAYLOAD_UNREADABLE "payload file not found: $PAYLOAD_FILE"
  payload=$(cat "$PAYLOAD_FILE")
else
  payload=$(cat)
fi
[ -n "$payload" ] || deny GUARD_PAYLOAD_UNREADABLE "empty PreToolUse payload"
jq -e . >/dev/null 2>&1 <<<"$payload" || deny GUARD_PAYLOAD_UNREADABLE "unparseable PreToolUse payload"

# The matcher already scopes this hook to the Agent tool; if a tool_name is present
# and is anything else, this is not our concern — allow untouched.
tool_name=$(jq -r '.tool_name // .toolName // empty' <<<"$payload")
case "$tool_name" in
  ""|Agent) : ;;
  *) allow ;;
esac

subagent_type=$(jq -r '.tool_input.subagent_type // empty' <<<"$payload")
model=$(jq -r '.tool_input.model // empty' <<<"$payload")
description=$(jq -r '.tool_input.description // empty' <<<"$payload")
# calling agent's profile — present ONLY when this hook fires inside a subagent
# session (§J K-matrix). This is how the caller's nesting authority is read.
calling_agent=$(jq -r '.agent_type // empty' <<<"$payload")
lcmodel=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')

# --- matrix authority (fail closed via the LANDED S3 validator) -------------
# The guard consumes the S3 matrix as its authority for the governed set, each
# profile's pinned model, and each nesting flag, so it must POSITIVELY PROVE the
# matrix is authoritative before reading a single value. A shallow field check is
# not proof: an artifact that keeps schema_version/profiles/models_allowed but
# injects an extra profile (e.g. a fable-xhigh past the ceiling), duplicates a key,
# or corrupts a field would pass a shallow check and produce a FALSE ALLOW (QA
# qa-me-s5-q163 #1). So the guard delegates to the LANDED S3 validator
# bin/fm-profile-matrix-check.sh, which proves the manifest against its closed
# schema, the eleven-profile set, duplicate keys, the prohibited-name rule, and the
# frontmatter projection. Any non-zero exit — missing file, corrupt JSON, schema
# violation, projection drift, or the validator's own engine (python3/jsonschema)
# being unavailable — means authority is NOT proven, which is a refusal-to-discharge:
# the dispatch is DENIED fail-closed (FC-002/FC-004), never allowed by fall-through.
MATRIX_CHECK="$SCRIPT_DIR/fm-profile-matrix-check.sh"
[ -x "$MATRIX_CHECK" ] || deny GUARD_MANIFEST_UNVERIFIED "S3 matrix validator not found or not executable: $MATRIX_CHECK"
if ! matrix_err=$("$MATRIX_CHECK" --manifest "$MANIFEST" --quiet 2>&1 >/dev/null); then
  deny GUARD_MANIFEST_UNVERIFIED "S3 profile matrix failed its landed validator: ${matrix_err:-non-zero exit from $MATRIX_CHECK}"
fi
# Proven authoritative: now it is safe to read values out of the same file.
manifest=$(cat "$MANIFEST")

# manifest accessors (the matrix is the authority for every one of these)
is_pinned() { jq -e --arg p "$1" '.profiles | has($p)' >/dev/null 2>&1 <<<"$manifest"; }
profile_model() { jq -r --arg p "$1" '.profiles[$p].model // empty' <<<"$manifest"; }
profile_nesting() { jq -r --arg p "$1" '.profiles[$p].nesting // false' <<<"$manifest"; }
is_prohibited_name() { jq -e --arg p "$1" '(.prohibited_profile_names // []) | index($p) != null' >/dev/null 2>&1 <<<"$manifest"; }
# a subagent_type that begins "<tier>-" for some models_allowed tier is in the
# reserved governed namespace (whether or not it is a pinned profile).
has_reserved_prefix() {
  jq -e --arg p "$1" '.models_allowed | any(. as $m | ($p | startswith($m + "-")))' >/dev/null 2>&1 <<<"$manifest"
}
# model (lowercased) is a bare governed-tier alias (haiku/sonnet/opus/fable).
is_governed_tier_alias() {
  jq -e --arg m "$1" '.models_allowed | index($m) != null' >/dev/null 2>&1 <<<"$manifest"
}

# --- justification marker (S4 schema authority proven before use) ------------
# The dispatcher injects [governed:dispatch_request_id=<uuid>] into the Agent call's
# description for every Opus-xhigh and Fable dispatch, referencing a request that
# already passed S4 schema validation (§J step 8/9). Before honoring a marker the
# guard PROVES the S4 request schema is authoritative — otherwise an artifact that
# keeps a plausible shape but weakens .properties.dispatch_request_id.pattern (e.g.
# to ^.*$) would silently turn the Fable/Opus-xhigh denial into an ALLOW (QA
# qa-me-s5-q163 #2). Proof: the file parses as a JSON object, its $id is the pinned
# firstmate/governed-dispatch-request/v1, and its dispatch_request_id pattern is
# BYTE-EQUAL to the guard's own pinned CANONICAL_REQUEST_ID_PATTERN. The marker is
# then matched against that PINNED canonical form, never the mutable file. Any
# divergence — missing file, non-object, wrong $id, non-canonical pattern — is a
# refusal-to-discharge and the dispatch is DENIED fail-closed. The guard does not
# (and cannot) re-validate the referenced request's content; that is S4's owned pass.
require_marker() {
  local gate_code="$1" sid pat core
  [ -f "$REQUEST_SCHEMA" ] || deny GUARD_SCHEMA_UNVERIFIED "S4 request schema not found; cannot prove the justification marker for '$subagent_type': $REQUEST_SCHEMA"
  jq -e 'type == "object"' >/dev/null 2>&1 <"$REQUEST_SCHEMA" \
    || deny GUARD_SCHEMA_UNVERIFIED "S4 request schema is not a parseable JSON object: $REQUEST_SCHEMA"
  sid=$(jq -r '."$id" // empty' "$REQUEST_SCHEMA" 2>/dev/null)
  [ "$sid" = "firstmate/governed-dispatch-request/v1" ] \
    || deny GUARD_SCHEMA_UNVERIFIED "S4 request schema \$id is '${sid:-<absent>}', not the pinned firstmate/governed-dispatch-request/v1 (schema not authoritative)"
  pat=$(jq -r '.properties.dispatch_request_id.pattern // empty' "$REQUEST_SCHEMA" 2>/dev/null)
  [ "$pat" = "$CANONICAL_REQUEST_ID_PATTERN" ] \
    || deny GUARD_SCHEMA_UNVERIFIED "S4 request schema dispatch_request_id.pattern diverges from the canonical committed form (schema altered/weakened?)"
  # Proven authoritative: match the marker against the PINNED canonical pattern
  # (byte-equal to the schema's). Strip the ^…$ anchors so the id form embeds inside
  # the marker literal.
  core=${CANONICAL_REQUEST_ID_PATTERN#^}
  core=${core%$}
  printf '%s' "$description" | grep -Eq "\[governed:dispatch_request_id=${core}\]" \
    || deny "$gate_code" "profile '$subagent_type' requires a well-formed [governed:dispatch_request_id=<uuid>] justification marker in the Agent call description"
}

# ===========================================================================
# Decision sequence. Order rationale: the CALLER's nesting authority is settled
# first — §J step 10's "deny the nested call outright regardless of what it is
# trying to dispatch" is a property of the caller, so it gates before the target
# is evaluated at all (a deliberate hardening of §J's sketch ordering, which
# early-exits ungoverned targets before its own step 10; documented in slice5-
# notes.md). All 12 §J test cases still yield their pinned codes.
# ===========================================================================

# 1. Nesting: a calling agent whose OWN governed profile forbids nesting may not
#    dispatch anything. (Only relevant when firing inside a subagent session.)
if [ -n "$calling_agent" ] && is_pinned "$calling_agent"; then
  [ "$(profile_nesting "$calling_agent")" = "true" ] \
    || deny NESTING_PROHIBITED "calling agent profile '$calling_agent' is not permitted to nest"
fi

# 2. Native-inheritance exception: fork is the ONLY allowlisted native-inheritance
#    type. A bare fork inherits the parent model by design — allowed. An explicit
#    model on a fork call is misuse of the carve-out (fork ignores model overrides).
if [ "$subagent_type" = "fork" ]; then
  [ -z "$model" ] || deny NATIVE_INHERITANCE_EXCEPTION_INVALID "explicit model on a fork call, which ignores model overrides by design"
  allow
fi

# 3. Universal model-omission: EVERY non-fork Agent call must name a model. This
#    is the structural close of silent Fable inheritance (a model-omitting call in
#    a Fable parent session silently produces a Fable child), and it applies to
#    every dispatch, governed-namespace or not.
[ -n "$model" ] || deny MODEL_REQUIRED "no model on a non-fork Agent call; omission inherits the parent session model (silent-inheritance risk) — name an explicit model"

# 4. Governed-namespace classification.
if has_reserved_prefix "$subagent_type"; then
  # Reserved governed prefix (haiku-/sonnet-/opus-/fable-…).
  if ! is_pinned "$subagent_type"; then
    if is_prohibited_name "$subagent_type"; then
      deny PROFILE_NOT_GOVERNED "profile '$subagent_type' is an explicitly prohibited name (matrix ceiling); it is not one of the governed profiles"
    fi
    deny PROFILE_NOT_GOVERNED "subagent_type '$subagent_type' matches a governed prefix but is not one of the pinned profiles"
  fi
  # Pinned profile: model must equal its matrix pin.
  expected=$(profile_model "$subagent_type")
  [ "$lcmodel" = "$expected" ] || deny MODEL_PROFILE_MISMATCH "profile '$subagent_type' pins model '$expected', got '$model'"
  # Tier justification gates.
  case "$subagent_type" in
    opus-xhigh) require_marker OPUS_XHIGH_JUSTIFICATION_MISSING ;;
    fable-*)    require_marker FABLE_JUSTIFICATION_MISSING ;;
  esac
  allow
elif [ -z "$subagent_type" ]; then
  # Empty subagent_type with a governed-tier model named: no profile to justify the
  # tools/effort/turns that model will run with.
  if is_governed_tier_alias "$lcmodel"; then
    deny PROFILE_REQUIRED "governed-tier model '$model' named with no profile to justify its tools/effort/turns"
  fi
  allow
else
  # Ungoverned subagent_type (general-purpose, claude, Explore, Plan, …). It passed
  # the universal model check. Line-39 refinement: a Fable model here is an explicit
  # Fable child routed around the fable-* justification gate — denied. A non-Fable
  # explicit model is allowed (this design does not mechanically classify ungoverned
  # work as governed).
  case "$lcmodel" in
    *fable*) deny FABLE_MODEL_UNGOVERNED "model '$model' resolves to Fable on ungoverned subagent_type '$subagent_type'; Fable is reachable only through a governed fable-* profile with a justification marker" ;;
  esac
  allow
fi

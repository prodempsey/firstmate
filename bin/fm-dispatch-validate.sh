#!/usr/bin/env bash
# Fail-closed validator for a governed dispatch request (model-economy program,
# ORD-224 slice S4). This is THE validator the governed dispatch path consults
# before an Agent dispatch: it proves a dispatch-request JSON conforms to
# firstmate/governed-dispatch-request/v1 and satisfies every §F cross-field rule,
# or it refuses with the exact §F denial code and runs nothing downstream.
#
# Design authority: data/model-economy/ord-223-report.md §F (dispatch request
# schema: field table, cross-field rules 1-13, fail-closed outcomes, versioning,
# the one valid + two denied examples), §H (the enumerated Opus-insufficiency
# denylist §F rule 6 defers to); brief §6 (the must-reject list). Dependency: S3
# — the profile axis is projected from the LANDED governed-profiles.manifest.json,
# never re-authored here (the matrix stays the single source of truth). Authority
# pattern (binding precedent): data/me-s3-profiles/design-ruling.md and its
# class precedent data/dj-orders-s2/design-ruling.md. Provenance pattern:
# bin/fm-bindings-validate.sh / bin/fm-profile-matrix-check.sh.
#
# AUTHORITY MODEL (same shape as S3). A dispatch request is authoritative to
# dispatch ONLY if one atomic pass positively proves, against explicit CLOSED
# JSON Schemas plus the §F cross-field/cross-artifact rules, that: the request is
# structurally exhaustive (every field admitted+typed, no unadmitted property);
# its immutable-profile fields equal the deterministic projection of the S3
# manifest for selected_profile; its task_class is in the committed governed
# taxonomy; the Opus-xhigh / Fable / next-lower justifications are present where
# §F requires; its parent links to a real task; and, where exact repo state is
# required, its claimed state equals the LIVE worktree. In every other state — a
# missing engine, a parse ambiguity, an unproven/extra property, a projection
# divergence, an unresolvable link, a stale claim — the request is NON-authoritative
# and the validator REFUSES with one stable code. Authority defaults to none; it is
# granted only by that one total pass; it is never inferred from the absence of a
# check. There is no enumerated ladder of hand-written per-property TYPE predicates:
# the committed schemas prove structure; the named checks are only the residue
# JSON Schema cannot express (relations between fields, projection against the
# manifest, live-environment agreement) — the S3 ruling's permitted residue.
#
# Engines: python3 and jsonschema (Draft 2020-12) are BOTH hard prerequisites. If
# either is absent the validator prints DISPATCH_VALIDATOR_UNAVAILABLE and exits 1
# — never a weaker best-effort check, never a warn-and-pass. (No YAML here: a
# dispatch request is JSON, so PyYAML is not required.)
#
# Usage: fm-dispatch-validate.sh <request.json> [options]
#        fm-dispatch-validate.sh --request <request.json> [options]
#   Options:
#     --manifest <file>       S3 governed-profiles manifest (profile projection source)
#     --policy <file>         governed-dispatch-policy.json (taxonomy + denylist + pins)
#     --schemas-dir <dir>     committed JSON Schemas dir
#     --state-dir <dir>       where state/<id>.meta lives (§F rule 8 parent linkage)
#     --session-id <id>       the current in-session id a parent_task_id may equal (rule 8)
#     --packets-dir <dir>     evidence-packet dir (§F rule 10 reference resolution)
#     --captain-orders <file> captain-order inbox file (§F rule 11 exception resolution)
#     --expect-fingerprint <sha256>   pin the request fingerprint (DISPATCH_FINGERPRINT_MISMATCH)
#     --write-sidecar         write a provenance attestation ONLY after full proof
#     --quiet                 suppress the success lines
#   Defaults: manifest    = $FM_ROOT/docs/model-economy/governed-profiles.manifest.json
#             policy      = $FM_ROOT/docs/model-economy/governed-dispatch-policy.json
#             schemas-dir = $FM_ROOT/docs/model-economy/schemas
#             state-dir   = $FM_STATE_OVERRIDE, else $FM_HOME/state, else $FM_ROOT/state
#
# Exit 0: the request is authoritative to dispatch. Prints "DISPATCH_OK=<profile>"
#   and "REQUEST_FINGERPRINT=<sha256>" (canonical sha256 of the request) unless --quiet.
# Exit 1: denied OR the validator could not run authoritatively. Prints exactly one
#   stable code line to stderr. Engine/artifact codes:
#     DISPATCH_VALIDATOR_UNAVAILABLE | DISPATCH_POLICY_MISSING | DISPATCH_POLICY_INVALID |
#     DISPATCH_MANIFEST_MISSING | DISPATCH_MANIFEST_INVALID | DISPATCH_REQUEST_MISSING |
#     DISPATCH_INVALID | DISPATCH_SCHEMA_INVALID |
#     DISPATCH_SIDECAR_INVALIDATION_FAILED | DISPATCH_SIDECAR_WRITE_FAILED
#   §F denial codes (schema-layer + shared-with-hook):
#     SCHEMA_VERSION_UNSUPPORTED | MODEL_REQUIRED | PROFILE_REQUIRED | PROFILE_NOT_GOVERNED |
#     TASK_CLASS_UNKNOWN | MODEL_PROFILE_MISMATCH | PROFILE_EFFORT_MISMATCH | NESTING_PROHIBITED |
#     PROFILE_IMMUTABLE_MISMATCH | OPUS_XHIGH_JUSTIFICATION_MISSING | FABLE_JUSTIFICATION_MISSING |
#     NEXT_LOWER_MODEL_INVALID | EVIDENCE_PACKET_MISSING | CAPTAIN_EXCEPTION_INVALID |
#     PARENT_LINKAGE_MISSING | REPO_STATE_STALE | DISPATCH_FINGERPRINT_MISMATCH
# Exit 2: usage error.
#
# Provenance sidecar (--write-sidecar): mirrors bin/fm-profile-matrix-check.sh's
# stale-authority-safe contract. The sidecar path is <request minus .json>.fingerprint.
# Remove-first / write-last: any pre-existing attestation is INVALIDATED before any
# validation runs (so a failed run never leaves a valid-looking sidecar beside a
# now-invalid request), and the invalidation is PROVEN — if the unlink is refused
# (read-only dir, immutable file) the validator refuses loudly
# (DISPATCH_SIDECAR_INVALIDATION_FAILED) rather than proceed under stale authority.
# The fresh attestation is written (temp file + atomic rename) ONLY after the whole
# pass proves the request; a write that cannot complete is a clean typed refusal
# (DISPATCH_SIDECAR_WRITE_FAILED), never a traceback or a partial temp file.
#
# Fail-closed everywhere: every code above denies; there is no "warn and proceed".
# A captain override is the only path that changes a would-be-denied outcome, and
# it does so by supplying a resolvable captain_exception_id (§F rule 11), never by
# suppressing a check.
set -u

# SCRIPT_DIR / FM_ROOT via shell builtins only, so the sole external dependency is
# the validation engine itself (python3): "refuse if the engine is absent" stays a
# clean single check, not one masked by a missing coreutil.
SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

REQUEST=""
MANIFEST=""
POLICY=""
SCHEMAS_DIR=""
STATE_DIR=""
SESSION_ID=""
PACKETS_DIR=""
CAPTAIN_ORDERS=""
EXPECT_FP=""
WRITE_SIDECAR=0
QUIET=0
want=
for a in "$@"; do
  if [ -n "$want" ]; then
    case "$want" in
      request) REQUEST=$a ;;
      manifest) MANIFEST=$a ;;
      policy) POLICY=$a ;;
      schemas) SCHEMAS_DIR=$a ;;
      state) STATE_DIR=$a ;;
      session) SESSION_ID=$a ;;
      packets) PACKETS_DIR=$a ;;
      orders) CAPTAIN_ORDERS=$a ;;
      fp) EXPECT_FP=$a ;;
    esac
    want=
    continue
  fi
  case "$a" in
    --request) want=request ;;
    --manifest) want=manifest ;;
    --policy) want=policy ;;
    --schemas-dir) want=schemas ;;
    --state-dir) want=state ;;
    --session-id) want=session ;;
    --packets-dir) want=packets ;;
    --captain-orders) want=orders ;;
    --expect-fingerprint) want=fp ;;
    --write-sidecar) WRITE_SIDECAR=1 ;;
    --quiet) QUIET=1 ;;
    --*) echo "fm-dispatch-validate: unknown flag $a" >&2; exit 2 ;;
    *)
      if [ -z "$REQUEST" ]; then REQUEST=$a
      else echo "fm-dispatch-validate: unexpected argument $a" >&2; exit 2; fi
      ;;
  esac
done
if [ -n "$want" ]; then echo "fm-dispatch-validate: --$want requires a value" >&2; exit 2; fi
if [ -z "$REQUEST" ]; then echo "fm-dispatch-validate: a dispatch-request JSON path is required" >&2; exit 2; fi
[ -n "$MANIFEST" ] || MANIFEST="$FM_ROOT/docs/model-economy/governed-profiles.manifest.json"
[ -n "$POLICY" ] || POLICY="$FM_ROOT/docs/model-economy/governed-dispatch-policy.json"
[ -n "$SCHEMAS_DIR" ] || SCHEMAS_DIR="$FM_ROOT/docs/model-economy/schemas"
if [ -z "$STATE_DIR" ]; then
  if [ -n "${FM_STATE_OVERRIDE:-}" ]; then STATE_DIR="$FM_STATE_OVERRIDE"
  elif [ -n "${FM_HOME:-}" ]; then STATE_DIR="$FM_HOME/state"
  else STATE_DIR="$FM_ROOT/state"; fi
fi

# Provenance stale-authority guard (same class as the DJ stale-audit ruling, per
# bin/fm-profile-matrix-check.sh): when --write-sidecar is requested, INVALIDATE any
# pre-existing attestation BEFORE any validation step (or engine-availability
# refusal) can fail, so a failed run never leaves a valid-looking sidecar standing
# beside a now-invalid request. The fresh attestation is re-created only after the
# whole pass succeeds (inside the python pass: temp file + atomic rename).
# Remove-first / write-last. The invalidation itself must be PROVEN: if the unlink
# is refused (read-only dir, immutable file) the old attestation would silently
# persist, so removal failure is itself fail-closed — refuse loudly rather than
# proceed under a still-present, now-unverifiable attestation.
if [ "$WRITE_SIDECAR" = "1" ]; then
  SIDECAR="${REQUEST%.json}.fingerprint"
  if [ -e "$SIDECAR" ]; then
    rm -f "$SIDECAR" 2>/dev/null || true
    if [ -e "$SIDECAR" ]; then
      echo "DISPATCH_SIDECAR_INVALIDATION_FAILED" >&2
      echo "fm-dispatch-validate: could not invalidate the pre-existing attestation sidecar $SIDECAR before validation; refusing rather than risk leaving stale authority" >&2
      exit 1
    fi
  fi
fi

# Hard prerequisite: the strict validation engine must be present. Absence is
# NON-AUTHORITATIVE and fails closed (never a weaker fallback).
if ! command -v python3 >/dev/null 2>&1; then
  echo "DISPATCH_VALIDATOR_UNAVAILABLE" >&2
  echo "fm-dispatch-validate: python3 is a hard prerequisite; refusing rather than degrading to a weaker check" >&2
  exit 1
fi

python3 - "$REQUEST" "$MANIFEST" "$POLICY" "$SCHEMAS_DIR" "$STATE_DIR" "$SESSION_ID" "$PACKETS_DIR" "$CAPTAIN_ORDERS" "$EXPECT_FP" "$WRITE_SIDECAR" "$QUIET" <<'PYEOF'
import hashlib, json, os, subprocess, sys

(REQUEST, MANIFEST, POLICY, SCHEMAS_DIR, STATE_DIR, SESSION_ID,
 PACKETS_DIR, CAPTAIN_ORDERS, EXPECT_FP, WRITE_SIDECAR, QUIET) = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5],
    sys.argv[6], sys.argv[7], sys.argv[8], sys.argv[9],
    sys.argv[10] == "1", sys.argv[11] == "1",
)

# A test-only fault-injection seam. It can ONLY force a refusal (never a false
# pass), so it proves the fail-closed contract for a missing engine without
# uninstalling a real dependency.
_SIMULATE_MISSING = set(
    m for m in os.environ.get("FM_DISPATCH_SIMULATE_MISSING", "").split(",") if m
)


def refuse(msg):
    sys.stderr.write("DISPATCH_VALIDATOR_UNAVAILABLE\n")
    sys.stderr.write("fm-dispatch-validate: " + msg + "\n")
    sys.exit(1)


# jsonschema joins python3 as a hard prerequisite: without a real schema engine we
# cannot POSITIVELY prove conformance (the r3 bool-as-int / list-as-string holes
# the S3 ruling closed are exactly what the engine excludes by construction).
if "jsonschema" in _SIMULATE_MISSING:
    refuse("jsonschema unavailable (simulated); refusing")
try:
    from jsonschema import Draft202012Validator
except Exception:
    refuse("jsonschema is required to prove schema conformance; refusing rather than degrading")


def die(code, msg):
    sys.stderr.write(code + "\n")
    sys.stderr.write("fm-dispatch-validate: " + msg + "\n")
    sys.exit(1)


class DupKey(Exception):
    def __init__(self, key):
        self.key = key


def _json_no_dupes(pairs):
    seen = set()
    for k, _ in pairs:
        if k in seen:
            raise DupKey(k)
        seen.add(k)
    return dict(pairs)


def load_schema(basename):
    path = os.path.join(SCHEMAS_DIR, basename)
    if not os.path.isfile(path):
        refuse("committed schema missing: %s" % path)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            schema = json.load(fh)
        Draft202012Validator.check_schema(schema)
        return Draft202012Validator(schema)
    except Exception as e:
        refuse("committed schema invalid (%s): %s" % (basename, e))


def schema_check(validator, instance, code, where):
    errs = sorted(validator.iter_errors(instance), key=lambda e: [str(p) for p in e.absolute_path])
    if errs:
        e = errs[0]
        loc = "/".join(str(p) for p in e.absolute_path) or "<root>"
        die(code, "%s: schema violation at %s: %s" % (where, loc, e.message))


REQUEST_V = load_schema("governed-dispatch-request.schema.json")
POLICY_V = load_schema("governed-dispatch-policy.schema.json")
MANIFEST_V = load_schema("governed-profiles-manifest.schema.json")


def load_json(path, missing_code, invalid_code, label):
    if not os.path.isfile(path):
        die(missing_code, "%s not found: %s" % (label, path))
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    try:
        return json.loads(text, object_pairs_hook=_json_no_dupes)
    except DupKey as e:
        die(invalid_code, "duplicate key in %s JSON (any depth): %s" % (label, e.key))
    except Exception as e:
        die(invalid_code, "%s is not valid JSON: %s" % (label, e))


# --- policy artifact: proven against its own closed schema before it is trusted -
policy = load_json(POLICY, "DISPATCH_POLICY_MISSING", "DISPATCH_POLICY_INVALID", "policy")
schema_check(POLICY_V, policy, "DISPATCH_POLICY_INVALID", "policy")
SUPPORTED_VERSION = policy["supported_request_schema_version"]
TIER_ORDER = policy["model_tier_order"]
TASK_CLASSES = set(policy["task_classes"])
DENYLIST = [p.lower() for p in policy["insufficient_reason_phrases"]]

# --- S3 manifest: the profile-projection source, proven before we project from it
manifest = load_json(MANIFEST, "DISPATCH_MANIFEST_MISSING", "DISPATCH_MANIFEST_INVALID", "manifest")
schema_check(MANIFEST_V, manifest, "DISPATCH_MANIFEST_INVALID", "manifest")
PROFILES = manifest["profiles"]

# --- request: parse -> duplicate-reject -------------------------------------
req = load_json(REQUEST, "DISPATCH_REQUEST_MISSING", "DISPATCH_INVALID", "request")
if not isinstance(req, dict):
    die("DISPATCH_INVALID", "request top level must be a JSON object")


def nonempty(v):
    return isinstance(v, str) and v.strip() != ""


# (§F rule 13) schema_version gate FIRST: any value other than the supported
# version fails closed as SCHEMA_VERSION_UNSUPPORTED, never coerced and never
# drowned in structural errors. Handles absent/null/mistyped/mismatched uniformly.
if req.get("schema_version") != SUPPORTED_VERSION:
    die("SCHEMA_VERSION_UNSUPPORTED",
        "schema_version %r != supported %r" % (req.get("schema_version"), SUPPORTED_VERSION))

# MODEL_REQUIRED / PROFILE_REQUIRED before the structural schema, so a null/absent
# model or profile gets its specific shared-with-hook code, not a generic one.
if req.get("requested_model") is None:
    die("MODEL_REQUIRED", "requested_model is absent/null; the dispatcher never infers a model")
if req.get("selected_profile") is None:
    die("PROFILE_REQUIRED", "selected_profile is absent/null")

# --- structural conformance: the closed request schema is the enumeration ----
# After this, every present field is type-proven; the named checks below never
# compare-before-type (S3 ruling §5.7).
schema_check(REQUEST_V, req, "DISPATCH_SCHEMA_INVALID", "request")

profile = req["selected_profile"]

# (§F rule 5) PROFILE_NOT_GOVERNED — the manifest closes the profile set to the 11
# governed names, so a prohibited name (opus-max/fable-xhigh/fable-max) or any
# other unknown profile simply is not present.
if profile not in PROFILES:
    die("PROFILE_NOT_GOVERNED", "selected_profile %r is not one of the governed profiles" % profile)

# (§F rule 12) TASK_CLASS_UNKNOWN — a class outside the committed taxonomy is never
# silently coerced to a nearby one.
if req["task_class"] not in TASK_CLASSES:
    die("TASK_CLASS_UNKNOWN", "task_class %r is not in the committed governed taxonomy" % req["task_class"])

p = PROFILES[profile]
exp_model = p["model"]
exp_effort = p["effort"] if p["effort"] is not None else "none"
exp_tools = list(p["tools"])
bounds = p["maxTurns_bounds"]

# --- immutable-profile projection against the single-source S3 manifest -------
# requested_model / configured_effort / nesting_allowed carry their own §F codes;
# write_allowed / allowed_tools / max_turns-bounds are the remaining immutable-
# profile fields (§F "immutable-profile" source class), projection-equal or bounded.
if req["requested_model"] != exp_model:  # rule 1
    die("MODEL_PROFILE_MISMATCH", "requested_model %r != profile %s pinned model %r"
        % (req["requested_model"], profile, exp_model))
if req["configured_effort"] != exp_effort:  # rule 2 (and rule 3 for sonnet, same code)
    die("PROFILE_EFFORT_MISMATCH", "configured_effort %r != profile %s pinned effort %r"
        % (req["configured_effort"], profile, exp_effort))
# rule 3 restated as its own captain-pinned invariant (same code): any sonnet-*
# governed effort must be high.
if profile.startswith("sonnet-") and req["configured_effort"] != "high":
    die("PROFILE_EFFORT_MISMATCH", "%s must be configured at effort high (captain policy)" % profile)
if req["nesting_allowed"] != p["nesting"]:  # rule 7
    die("NESTING_PROHIBITED",
        "nesting_allowed=%s but profile %s is %s-nesting; only fable-low/medium/high may nest"
        % (req["nesting_allowed"], profile, "" if p["nesting"] else "non"))
if req["write_allowed"] != p["writes"]:
    die("PROFILE_IMMUTABLE_MISMATCH", "write_allowed=%s != profile %s writes=%s"
        % (req["write_allowed"], profile, p["writes"]))
if req["allowed_tools"] != exp_tools:
    die("PROFILE_IMMUTABLE_MISMATCH", "allowed_tools %r != profile %s tools %r"
        % (req["allowed_tools"], profile, exp_tools))
if not (bounds["min"] <= req["max_turns"] <= bounds["max"]):
    die("PROFILE_IMMUTABLE_MISMATCH", "max_turns %d outside profile %s bounds [%d,%d]"
        % (req["max_turns"], profile, bounds["min"], bounds["max"]))

# (§F rule 4) OPUS_XHIGH_JUSTIFICATION_MISSING
if profile == "opus-xhigh" and not nonempty(req.get("opus_xhigh_justification")):
    die("OPUS_XHIGH_JUSTIFICATION_MISSING",
        "opus-xhigh requires a non-empty opus_xhigh_justification recorded before dispatch")

# (§F rule 6) FABLE_JUSTIFICATION_MISSING — every Fable dispatch. why_opus must be
# present, non-empty, and free of the enumerated insufficient-reason phrases (§H).
# The denylist screens the union of the reasoning-bearing fields, because §F is
# explicit that the denial is about the reasoning offered, not which schema field
# it was typed into ("denies regardless of which field carried the disallowed
# phrasing"). Best-effort text screen per §F rule 6 / §H caveat; calibration (§R)
# is the real backstop.
if req["requested_model"] == "fable":
    if not nonempty(req.get("why_opus_is_insufficient")):
        die("FABLE_JUSTIFICATION_MISSING",
            "every Fable dispatch requires a non-empty why_opus_is_insufficient")
    reasoning = " ".join(
        str(req.get(k) or "")
        for k in ("why_opus_is_insufficient", "why_next_lower_model_is_insufficient", "routing_reason")
    ).lower()
    hit = next((phrase for phrase in DENYLIST if phrase in reasoning), None)
    if hit is not None:
        die("FABLE_JUSTIFICATION_MISSING",
            "Fable justification relies on an enumerated insufficient reason (%r); name the specific "
            "reasoning limitation Opus cannot meet" % hit)

# (§F rule 10) EVIDENCE_PACKET_MISSING — the §F field table requires evidence_packet_id
# for EVERY opus-* or fable-* profile (Opus/Fable is decision-class work, brief §7/§15).
# This enforces the binding field-table requirement; the §F prose valid example's
# null-packet opus-high is superseded by the field table under the QA contract (see
# slice4-notes.md). Deep §M packet-schema validation is deferred to S7; here the
# reference must be present and, when a packets dir is given, resolve to a packet file.
pkt = req.get("evidence_packet_id")
if (profile.startswith("opus-") or profile.startswith("fable-")) and pkt is None:
    die("EVIDENCE_PACKET_MISSING",
        "profile %s is decision-class; §F requires a non-null evidence_packet_id" % profile)
if pkt is not None and PACKETS_DIR:
    if not os.path.isfile(os.path.join(PACKETS_DIR, pkt + ".json")):
        die("EVIDENCE_PACKET_MISSING", "evidence_packet_id %r resolves to no packet under %s"
            % (pkt, PACKETS_DIR))

# next_lower_model (§F field table): required for any non-haiku dispatch, and must
# be exactly one tier below requested_model; its justification must be non-empty.
# Ordered AFTER the Fable justification check so a Fable request with an empty
# why_opus reports FABLE_JUSTIFICATION_MISSING (the §F denial-2 example), not this.
if req["requested_model"] != "haiku":
    rm = req["requested_model"]
    idx = TIER_ORDER.index(rm) if rm in TIER_ORDER else -1
    expected_lower = TIER_ORDER[idx - 1] if idx > 0 else None
    if req.get("next_lower_model") != expected_lower:
        die("NEXT_LOWER_MODEL_INVALID",
            "next_lower_model %r must be exactly one tier below %r (%r)"
            % (req.get("next_lower_model"), rm, expected_lower))
    if not nonempty(req.get("why_next_lower_model_is_insufficient")):
        die("NEXT_LOWER_MODEL_INVALID",
            "why_next_lower_model_is_insufficient must be present and non-empty when next_lower_model is set")

# (§F rule 11) CAPTAIN_EXCEPTION_INVALID — a present exception id must be
# attributable to a real captured captain instruction, else it is not accepted as
# a bypass credential. Fail closed when no orders source is available to attribute
# it against (an unverifiable exception is not a valid one).
cx = req.get("captain_exception_id")
if cx is not None:
    ok = False
    if CAPTAIN_ORDERS and os.path.isfile(CAPTAIN_ORDERS):
        with open(CAPTAIN_ORDERS, "r", encoding="utf-8") as fh:
            ok = cx in fh.read()
    if not ok:
        die("CAPTAIN_EXCEPTION_INVALID",
            "captain_exception_id %r is not attributable to a captured captain instruction" % cx)

# (§F rule 8) PARENT_LINKAGE_MISSING — parent_task_id must resolve to a tracked
# task (state/<id>.meta) or be the current in-session id.
ptid = req["parent_task_id"]
resolved = (SESSION_ID and ptid == SESSION_ID) or os.path.isfile(os.path.join(STATE_DIR, ptid + ".meta"))
if not resolved:
    die("PARENT_LINKAGE_MISSING",
        "parent_task_id %r resolves to no tracked task (no %s/%s.meta) and is not the in-session id"
        % (ptid, STATE_DIR, ptid))

# (§F rule 9) REPO_STATE_STALE — where exact repo state is required (a ship/review
# dispatch, or any dispatch that supplied a claimed HEAD/worktree/branch/fingerprint),
# re-read the LIVE worktree and compare rather than trust a possibly-stale snapshot.
# A harmless git probe, no model call (T.1).
state_fields = ("worktree", "branch", "HEAD", "runtime_state_fingerprint")
exact_required = req["task_type"] in ("ship", "review") or any(req.get(f) is not None for f in state_fields)
if exact_required:
    for f in state_fields:
        if req.get(f) is None:
            die("REPO_STATE_STALE",
                "exact repo state is required for this dispatch but %s is absent" % f)
    wt = req["worktree"]
    if not os.path.isdir(os.path.join(wt, ".git")) and not os.path.isdir(wt):
        die("REPO_STATE_STALE", "claimed worktree %r is not a readable git worktree" % wt)

    def git(*args):
        return subprocess.run(["git", "-C", wt, *args],
                              capture_output=True, text=True)

    r = git("rev-parse", "HEAD")
    if r.returncode != 0:
        die("REPO_STATE_STALE", "could not read live HEAD of %r: %s" % (wt, r.stderr.strip()))
    live_head = r.stdout.strip()
    r = git("rev-parse", "--abbrev-ref", "HEAD")
    live_branch = r.stdout.strip() if r.returncode == 0 else ""
    r = git("status", "--porcelain")
    live_clean = (r.returncode == 0 and r.stdout.strip() == "")
    if req["HEAD"] != live_head:
        die("REPO_STATE_STALE", "claimed HEAD %s != live HEAD %s" % (req["HEAD"], live_head))
    if req["branch"] != live_branch:
        die("REPO_STATE_STALE", "claimed branch %r != live branch %r" % (req["branch"], live_branch))
    payload = "%s\n%s\n%s\n%s" % (req["repository"], live_branch, live_head, "clean" if live_clean else "dirty")
    expected_fp = "sha256:" + hashlib.sha256(payload.encode("utf-8")).hexdigest()
    if req["runtime_state_fingerprint"] != expected_fp:
        die("REPO_STATE_STALE",
            "runtime_state_fingerprint %r != recomputed %r (repo state changed since the claim)"
            % (req["runtime_state_fingerprint"], expected_fp))

# --- provenance: canonical request fingerprint the dispatch path can record ----
fingerprint = hashlib.sha256(
    json.dumps(req, sort_keys=True, separators=(",", ":")).encode("utf-8")
).hexdigest()
if EXPECT_FP and EXPECT_FP != fingerprint:
    die("DISPATCH_FINGERPRINT_MISMATCH", "request fingerprint %s != expected %s" % (fingerprint, EXPECT_FP))

# --- provenance attestation: written ONLY after the full pass proves the request
# (never before), so a failed validation never leaves a valid-looking sidecar. The
# bash preamble already invalidated any pre-existing attestation (and refused if it
# could not). Written via a temp file + atomic rename, mirroring
# bin/fm-profile-matrix-check.sh; a write that cannot complete is a clean typed
# refusal, never a traceback and never a partially-written attestation.
if WRITE_SIDECAR:
    side = (REQUEST[:-5] if REQUEST.endswith(".json") else REQUEST) + ".fingerprint"
    tmp = side + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(fingerprint + "\n")
        os.replace(tmp, side)
    except OSError as e:
        try:
            os.remove(tmp)
        except OSError:
            pass
        die("DISPATCH_SIDECAR_WRITE_FAILED", "could not write attestation sidecar %s: %s" % (side, e))

if not QUIET:
    sys.stdout.write("DISPATCH_OK=%s\n" % profile)
    sys.stdout.write("REQUEST_FINGERPRINT=%s\n" % fingerprint)
sys.exit(0)
PYEOF
exit $?

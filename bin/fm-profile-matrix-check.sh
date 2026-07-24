#!/usr/bin/env bash
# Fail-closed validator for the governed agent-profile matrix (model-economy
# program, ORD-224 slice S3). Design authority:
# data/model-economy/ord-223-report.md §G (matrix), §H (model policy),
# §I (effort policy); B.1 #1 (committed manifest) and #15 (tracked-material home).
# Authority-pattern authority: data/me-s3-profiles/design-ruling.md (and its
# class precedent data/dj-orders-s2/design-ruling.md). Provenance pattern:
# bin/fm-bindings-validate.sh (landed, ORD-225).
#
# AUTHORITY MODEL. The profile matrix is authoritative ONLY if one atomic pass
# positively proves, against explicit CLOSED JSON Schemas, that (i) the canonical
# manifest conforms exhaustively — every property present, exactly typed,
# enum-constrained, and unique where required, with no property the schema does
# not admit; and (ii) every other surface (each .claude/agents/<profile>.md
# frontmatter, and any supplied bindings entry) equals a deterministic projection
# of that manifest by WHOLE-OBJECT equality. In every other state — a missing
# engine, a parse ambiguity, an unproven/extra property, a surface that is not an
# exact projection — the matrix is non-authoritative and the validator REFUSES.
# Authority defaults to none; it is granted only by that one total pass; it is
# never inferred from the absence of a check. There is no enumerated ladder of
# hand-written per-property predicates: the committed schemas ARE the enumeration.
#
# Engines: python3, PyYAML, and jsonschema (Draft 2020-12) are ALL hard
# prerequisites. If any is absent the validator prints PROFILE_VALIDATOR_UNAVAILABLE
# and exits 1 — never a weaker best-effort check, never a warn-and-pass.
#
# Usage: fm-profile-matrix-check.sh [--manifest <file>] [--agents-dir <dir>]
#                                   [--schemas-dir <dir>] [--bindings <file>]
#                                   [--expect-fingerprint <sha256>] [--write-sidecar]
#                                   [--quiet]
#   Defaults: manifest    = $FM_ROOT/docs/model-economy/governed-profiles.manifest.json
#             agents-dir  = $FM_ROOT/.claude/agents
#             schemas-dir = $FM_ROOT/docs/model-economy/schemas
#             bindings    = (none) — cross-check runs only when --bindings is given
#                           and that file carries at least one governed profile key.
#
# Exit 0: coherent. Prints "PROFILES_OK=<n>" and "MATRIX_FINGERPRINT=<sha256>"
#   unless --quiet.
# Exit 1: incoherent OR the validator could not run authoritatively. Prints
#   exactly one stable code line to stderr:
#   PROFILE_VALIDATOR_UNAVAILABLE | PROFILE_MANIFEST_MISSING | PROFILE_MANIFEST_INVALID |
#   PROFILE_MANIFEST_DUPLICATE_KEY | PROFILE_MANIFEST_SCHEMA_INVALID |
#   PROFILE_MANIFEST_INCONSISTENT | PROFILE_PROHIBITED_PRESENT | PROFILE_FILE_MISSING |
#   PROFILE_FILE_UNKNOWN | PROFILE_FRONTMATTER_INVALID | PROFILE_FRONTMATTER_DUPLICATE_KEY |
#   PROFILE_FRONTMATTER_SCHEMA_INVALID | PROFILE_PROJECTION_MISMATCH |
#   PROFILE_BINDINGS_MISMATCH | PROFILE_FINGERPRINT_MISMATCH
# Exit 2: usage error.
#
# The semantic fingerprint (MATRIX_FINGERPRINT) is sha256 over the canonical
# serialization of the manifest object — json.dumps(sort_keys, compact) — the
# direct analogue of fm-bindings-validate.sh's FINGERPRINT, pinnable by S4 via
# --expect-fingerprint and recordable via --write-sidecar (<manifest>.fingerprint).
set -u

# SCRIPT_DIR / FM_ROOT via shell builtins only, so the sole external dependency
# is the validation engine itself (python3) — that keeps "refuse if the engine is
# absent" a clean, single check rather than one masked by a missing coreutil.
SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

MANIFEST=""
AGENTS_DIR=""
SCHEMAS_DIR=""
BINDINGS=""
EXPECT_FP=""
WRITE_SIDECAR=0
QUIET=0
want=
for a in "$@"; do
  if [ -n "$want" ]; then
    case "$want" in
      manifest) MANIFEST=$a ;;
      agents) AGENTS_DIR=$a ;;
      schemas) SCHEMAS_DIR=$a ;;
      bindings) BINDINGS=$a ;;
      fp) EXPECT_FP=$a ;;
    esac
    want=
    continue
  fi
  case "$a" in
    --manifest) want=manifest ;;
    --agents-dir) want=agents ;;
    --schemas-dir) want=schemas ;;
    --bindings) want=bindings ;;
    --expect-fingerprint) want=fp ;;
    --write-sidecar) WRITE_SIDECAR=1 ;;
    --quiet) QUIET=1 ;;
    --*) echo "fm-profile-matrix-check: unknown flag $a" >&2; exit 2 ;;
    *) echo "fm-profile-matrix-check: unexpected argument $a" >&2; exit 2 ;;
  esac
done
if [ -n "$want" ]; then echo "fm-profile-matrix-check: --$want requires a value" >&2; exit 2; fi
[ -n "$MANIFEST" ] || MANIFEST="$FM_ROOT/docs/model-economy/governed-profiles.manifest.json"
[ -n "$AGENTS_DIR" ] || AGENTS_DIR="$FM_ROOT/.claude/agents"
[ -n "$SCHEMAS_DIR" ] || SCHEMAS_DIR="$FM_ROOT/docs/model-economy/schemas"

# Provenance stale-authority guard (same class as the DJ stale-audit ruling):
# when --write-sidecar is requested, INVALIDATE any pre-existing attestation
# BEFORE any validation step (or engine-availability refusal) can fail, so a
# failed run never leaves a valid-looking sidecar standing beside a now-invalid
# matrix. The fresh attestation is re-created only after the whole pass succeeds
# (inside the python pass, temp file + atomic rename). Remove-first / write-last.
if [ "$WRITE_SIDECAR" = "1" ]; then
  rm -f "${MANIFEST%.json}.fingerprint" 2>/dev/null || true
fi

# Hard prerequisite: the strict validation engine must be present. Absence is
# NON-AUTHORITATIVE and fails closed (never a weaker fallback).
if ! command -v python3 >/dev/null 2>&1; then
  echo "PROFILE_VALIDATOR_UNAVAILABLE" >&2
  echo "fm-profile-matrix-check: python3 is a hard prerequisite; refusing rather than degrading to a weaker check" >&2
  exit 1
fi

python3 - "$MANIFEST" "$AGENTS_DIR" "$SCHEMAS_DIR" "$BINDINGS" "$EXPECT_FP" "$WRITE_SIDECAR" "$QUIET" <<'PYEOF'
import hashlib, json, os, sys

MANIFEST, AGENTS_DIR, SCHEMAS_DIR, BINDINGS, EXPECT_FP, WRITE_SIDECAR, QUIET = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5],
    sys.argv[6] == "1", sys.argv[7] == "1",
)

# A test-only fault-injection seam. It can ONLY force a refusal (never a false
# pass), so it proves the fail-closed contract for a missing engine without
# uninstalling a real dependency. Comma-separated module names.
_SIMULATE_MISSING = set(
    m for m in os.environ.get("FM_PROFILE_SIMULATE_MISSING", "").split(",") if m
)


def refuse(msg):
    sys.stderr.write("PROFILE_VALIDATOR_UNAVAILABLE\n")
    sys.stderr.write("fm-profile-matrix-check: " + msg + "\n")
    sys.exit(1)


# PyYAML and jsonschema join python3 as hard prerequisites: without a real YAML
# parser and a real schema engine we cannot POSITIVELY prove conformance.
if "yaml" in _SIMULATE_MISSING:
    refuse("PyYAML unavailable (simulated); refusing")
try:
    import yaml
except Exception:
    refuse("PyYAML is required to parse frontmatter; refusing rather than degrading")

if "jsonschema" in _SIMULATE_MISSING:
    refuse("jsonschema unavailable (simulated); refusing")
try:
    import jsonschema
    from jsonschema import Draft202012Validator
except Exception:
    refuse("jsonschema is required to prove schema conformance; refusing rather than degrading")


def die(code, msg):
    sys.stderr.write(code + "\n")
    sys.stderr.write("fm-profile-matrix-check: " + msg + "\n")
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


class StrictLoader(yaml.SafeLoader):
    pass


def _yaml_no_dupes(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise DupKey(key)
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


StrictLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _yaml_no_dupes)


# --- committed schemas (data artifacts; the declarative authority) ----------
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


MANIFEST_V = load_schema("governed-profiles-manifest.schema.json")
FRONTMATTER_V = load_schema("governed-profile-frontmatter.schema.json")
BINDINGS_V = load_schema("governed-bindings-entry.schema.json")


def schema_check(validator, instance, code, where):
    # Stringify path components in the sort key: absolute_path mixes str object
    # keys and int array indices, which are not order-comparable in Python 3, so
    # a raw list key could raise TypeError on a multi-error instance.
    errs = sorted(validator.iter_errors(instance), key=lambda e: [str(p) for p in e.absolute_path])
    if errs:
        e = errs[0]
        loc = "/".join(str(p) for p in e.absolute_path) or "<root>"
        die(code, "%s: schema violation at %s: %s" % (where, loc, e.message))


# --- manifest: parse -> duplicate-reject -> jsonschema ----------------------
if not os.path.isfile(MANIFEST):
    die("PROFILE_MANIFEST_MISSING", "manifest not found: %s" % MANIFEST)
with open(MANIFEST, "r", encoding="utf-8") as fh:
    manifest_text = fh.read()
try:
    manifest = json.loads(manifest_text, object_pairs_hook=_json_no_dupes)
except DupKey as e:
    die("PROFILE_MANIFEST_DUPLICATE_KEY", "duplicate key in manifest JSON (any depth): %s" % e.key)
except Exception as e:
    die("PROFILE_MANIFEST_INVALID", "manifest is not valid JSON: %s" % e)

schema_check(MANIFEST_V, manifest, "PROFILE_MANIFEST_SCHEMA_INVALID", "manifest")

profiles = manifest["profiles"]
efforts_allowed = manifest["efforts_allowed"]
models_allowed = manifest["models_allowed"]
prohibited = set(manifest["prohibited_profile_names"])
ec = manifest["effort_constraints"]

# --- manifest cross-property policy (what JSON Schema cannot express) --------
# Tier policy is read from effort_constraints ONLY (single source), never a
# second hard-coded copy. The effort ORDER used by the ceiling rule is derived
# from the (schema-validated) efforts_allowed list, so every declared operator —
# effort_present, fixed, prohibited, AND ceiling — is enforced generically.
effort_rank = {e: i for i, e in enumerate(efforts_allowed)}
for name, p in profiles.items():
    where = "manifest profile '%s'" % name
    # A prohibited name can never appear here: the manifest schema closes the
    # profiles object to exactly the 11 governed names (additionalProperties:false
    # + required), so an unauthorized/prohibited name fails at PROFILE_MANIFEST_SCHEMA_INVALID.
    if p["model"] not in models_allowed:
        die("PROFILE_MANIFEST_INCONSISTENT", "%s model not in models_allowed" % where)
    if p["effort"] is not None and p["effort"] not in efforts_allowed:
        die("PROFILE_MANIFEST_INCONSISTENT", "%s effort not in efforts_allowed" % where)

    b = p["maxTurns_bounds"]
    if b["min"] > b["max"]:
        die("PROFILE_MANIFEST_INCONSISTENT", "%s maxTurns_bounds min>max" % where)
    if not (b["min"] <= p["maxTurns"] <= b["max"]):
        die("PROFILE_MANIFEST_INCONSISTENT",
            "%s maxTurns %d outside bounds [%d,%d]" % (where, p["maxTurns"], b["min"], b["max"]))

    rule = ec.get(p["model"])
    if rule is None:
        die("PROFILE_MANIFEST_INCONSISTENT", "%s has no effort_constraints rule for tier %s" % (where, p["model"]))
    if "effort_present" in rule:
        if rule["effort_present"] and p["effort"] is None:
            die("PROFILE_MANIFEST_INCONSISTENT", "%s must carry an effort per effort_constraints" % where)
        if not rule["effort_present"] and p["effort"] is not None:
            die("PROFILE_MANIFEST_INCONSISTENT", "%s must carry no effort per effort_constraints" % where)
    if "fixed" in rule and p["effort"] != rule["fixed"]:
        die("PROFILE_MANIFEST_INCONSISTENT", "%s effort must be fixed at %s per effort_constraints" % (where, rule["fixed"]))
    if "prohibited" in rule and p["effort"] in rule["prohibited"]:
        die("PROFILE_MANIFEST_INCONSISTENT", "%s effort %s is prohibited for tier per effort_constraints" % (where, p["effort"]))
    if "ceiling" in rule and p["effort"] is not None:
        ceil = rule["ceiling"]
        if ceil not in effort_rank:
            die("PROFILE_MANIFEST_INCONSISTENT", "%s effort_constraints ceiling '%s' not in efforts_allowed" % (where, ceil))
        if effort_rank[p["effort"]] > effort_rank[ceil]:
            die("PROFILE_MANIFEST_INCONSISTENT",
                "%s effort %s exceeds the tier ceiling %s per effort_constraints" % (where, p["effort"], ceil))

# --- fingerprint (semantic; canonical serialization of the manifest) --------
# Computed now so --expect-fingerprint can fail early, but the sidecar
# ATTESTATION is written only after the whole atomic pass proves the matrix
# (see the end): a failed validation must never leave a valid-looking sidecar.
fingerprint = hashlib.sha256(
    json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode("utf-8")
).hexdigest()
if EXPECT_FP and EXPECT_FP != fingerprint:
    die("PROFILE_FINGERPRINT_MISMATCH", "manifest fingerprint %s != expected %s" % (fingerprint, EXPECT_FP))

# --- directory: exactly the manifest profiles, no prohibited, no unknown ----
if os.path.isdir(AGENTS_DIR):
    for fn in sorted(os.listdir(AGENTS_DIR)):
        if not fn.endswith(".md") or not os.path.isfile(os.path.join(AGENTS_DIR, fn)):
            continue
        stem = fn[:-3]
        if stem in prohibited:
            die("PROFILE_PROHIBITED_PRESENT", "prohibited profile file exists: %s" % fn)
        if stem not in profiles:
            die("PROFILE_FILE_UNKNOWN", "agent file has no manifest entry: %s" % fn)


def load_frontmatter(path, name):
    with open(path, "r", encoding="utf-8") as fh:
        lines = fh.read().split("\n")
    if not lines or lines[0].strip() != "---":
        die("PROFILE_FRONTMATTER_INVALID", "%s.md must open with a --- delimiter on line 1" % name)
    body, closed = [], False
    for ln in lines[1:]:
        if ln.strip() == "---":
            closed = True
            break
        body.append(ln)
    if not closed:
        die("PROFILE_FRONTMATTER_INVALID", "%s.md frontmatter block is never closed" % name)
    try:
        data = yaml.load("\n".join(body), Loader=StrictLoader)
    except DupKey as e:
        die("PROFILE_FRONTMATTER_DUPLICATE_KEY", "%s.md duplicate frontmatter key: %s" % (name, e.key))
    except Exception as e:
        die("PROFILE_FRONTMATTER_INVALID", "%s.md frontmatter is not valid YAML: %s" % (name, e))
    if not isinstance(data, dict) or not data:
        die("PROFILE_FRONTMATTER_INVALID", "%s.md frontmatter must be a non-empty mapping" % name)
    return data


def project(name, p):
    """Deterministic expected frontmatter object derived wholly from the manifest."""
    fm = {
        "name": name,
        "description": p["description"],
        "model": p["model"],
        "tools": list(p["tools"]),
        "maxTurns": p["maxTurns"],
        "permissionMode": "default",
        "profile_version": p["version"],
    }
    if p["effort"] is not None:
        fm["EFFORT"] = p["effort"]
    if not p["nesting"]:
        fm["disallowedTools"] = ["Agent"]
    return fm


# --- per-profile: schema-valid frontmatter == manifest projection -----------
count = 0
for name in sorted(profiles.keys()):
    p = profiles[name]
    path = os.path.join(AGENTS_DIR, name + ".md")
    if not os.path.isfile(path):
        die("PROFILE_FILE_MISSING", "missing agent file for profile: %s.md" % name)
    fm = load_frontmatter(path, name)
    schema_check(FRONTMATTER_V, fm, "PROFILE_FRONTMATTER_SCHEMA_INVALID", "%s.md" % name)

    expected = project(name, p)
    if fm != expected:
        keys = set(fm) | set(expected)
        diffs = [k for k in sorted(keys) if fm.get(k) != expected.get(k)]
        detail = ", ".join(
            "%s: got %r want %r" % (k, fm.get(k), expected.get(k)) for k in diffs
        )
        die("PROFILE_PROJECTION_MISMATCH",
            "%s.md is not the manifest projection (%s)" % (name, detail))
    count += 1

# --- optional SHELL-CREW bindings cross-check -------------------------------
# For each governed profile name a bindings file carries, the entry is proven
# against the governed-bindings-entry schema FIRST (model must be a string, effort
# is enum-constrained so an empty string is rejected, backups are typed/unique),
# so every value is type-proven before comparison. Then agreement: effort presence
# and value match the manifest tier exactly, and the bindings model carries the
# tier token.
if BINDINGS:
    if not os.path.isfile(BINDINGS):
        die("PROFILE_BINDINGS_MISMATCH", "bindings file not found: %s" % BINDINGS)
    with open(BINDINGS, "r", encoding="utf-8") as fh:
        btext = fh.read()
    try:
        b = json.loads(btext, object_pairs_hook=_json_no_dupes)
    except DupKey as e:
        die("PROFILE_BINDINGS_MISMATCH", "duplicate key in bindings JSON: %s" % e.key)
    except Exception as e:
        die("PROFILE_BINDINGS_MISMATCH", "bindings is not valid JSON: %s" % e)
    if not isinstance(b, dict):
        die("PROFILE_BINDINGS_MISMATCH", "bindings top level must be an object")
    for name in sorted(profiles.keys()):
        if name not in b:
            continue
        entry = b[name]
        schema_check(BINDINGS_V, entry, "PROFILE_BINDINGS_MISMATCH", "bindings %s" % name)
        m_effort = profiles[name]["effort"]  # None for haiku-tier, else an enum string
        has_effort = "effort" in entry
        if m_effort is None:
            if has_effort:
                die("PROFILE_BINDINGS_MISMATCH", "bindings %s must carry no effort (manifest tier has none)" % name)
        else:
            if not has_effort:
                die("PROFILE_BINDINGS_MISMATCH", "bindings %s missing effort (manifest '%s')" % (name, m_effort))
            if entry["effort"] != m_effort:
                die("PROFILE_BINDINGS_MISMATCH", "bindings %s effort '%s' != manifest '%s'" % (name, entry["effort"], m_effort))
        if profiles[name]["model"] not in entry["model"]:
            die("PROFILE_BINDINGS_MISMATCH", "bindings %s model '%s' does not carry tier '%s'" % (name, entry["model"], profiles[name]["model"]))

# --- provenance attestation: written ONLY after the full pass proves the matrix
# (Finding 3): a failed validation must never leave a valid-looking sidecar.
# Written via a temp file + atomic rename, mirroring bin/fm-bindings-validate.sh.
if WRITE_SIDECAR:
    side = (MANIFEST[:-5] if MANIFEST.endswith(".json") else MANIFEST) + ".fingerprint"
    tmp = side + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(fingerprint + "\n")
    os.replace(tmp, side)

if not QUIET:
    sys.stdout.write("PROFILES_OK=%d\n" % count)
    sys.stdout.write("MATRIX_FINGERPRINT=%s\n" % fingerprint)
sys.exit(0)
PYEOF
exit $?

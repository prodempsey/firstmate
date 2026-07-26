#!/usr/bin/env bash
# fm-cue-validate.sh - the ONE authority that proves failure-class cue data valid.
#
# Per the binding ruling (data/seasoning-cues-g1/design-ruling.md; precedents me-s3-profiles and
# dj-orders-s2): validation is a single atomic fail-closed pass over the RAW bytes, enforced by
# python3 + jsonschema (Draft 2020-12) as HARD prerequisites. jq is DISQUALIFIED as the validation
# parser because it collapses duplicate JSON member names (last-wins) before any check can see them;
# duplicate members are rejected on the raw bytes by python's object_pairs_hook, at any depth, before
# any normalizing parse. There is no degradation: if python3 or jsonschema is absent, this refuses
# with CUE_VALIDATOR_UNAVAILABLE and exits non-zero, on every path.
#
# Usage:
#   fm-cue-validate.sh prove <ledger-path>
#     Prove the WHOLE ledger valid (every raw line: one JSON object, no duplicate member at any depth,
#     conforms to the committed ledger-event schema; every detection row conforms to the committed
#     detection-row schema and its pattern compiles; no duplicate class-defined id; the fold succeeds).
#     On success prints the proven folded snapshot (a JSON array, one record per class id, the same
#     shape the old `list --json` fold produced) to stdout, exit 0. On failure prints exactly one
#     marker + reason to stderr, exit 1. Consumers execute ONLY rows from this snapshot.
#   fm-cue-validate.sh check-row <row-file>
#     Prove a SINGLE raw detection-row JSON (the bytes in <row-file>) valid the same way - raw
#     duplicate-member rejection BEFORE any normalizing parse, then the detection-row schema, then the
#     compile probe. Used by the sanctioned writer to reject a raw --detection argument before jq can
#     collapse a duplicate. Exit 0 valid, exit 1 refusal (marker + reason on stderr).
#
# Refusal markers (stderr, exit 1):
#   CUE_VALIDATOR_UNAVAILABLE  python3 or jsonschema absent (never a weaker check)
#   CUE_LEDGER_MISSING         the ledger file does not exist (a distinct state, never valid-empty)
#   CUE_LEDGER_INVALID         a parse/schema/duplicate/fold failure, naming the offending line/row
#
# An empty-but-present ledger (zero events) is valid-empty: `prove` prints "[]" and exits 0.
#
# Test seam (fixture-gated, NOT an ambient variable): a missing-prerequisite simulation engages ONLY
# when BOTH hold - a sandbox marker file `.fm-cue-test-sandbox` exists in the fixture's own directory
# AND the target being validated lives in that same directory (the marker is looked up in the
# target's own directory, so the target is inside the fixture dir by construction). The marker's
# content lists the engine(s) to simulate absent (`python3` and/or `jsonschema`). No environment
# variable can engage it, and no stray marker in a production home can either, because a production
# ledger's directory (the committed docs/failure-classes/) carries no such marker. It can ONLY force
# a refusal, never a false pass.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The committed schemas are bound UNCONDITIONALLY to this repo, resolved by the validator's own
# directory. No ambient variable may substitute a permissive schema directory for the closed ones.
SCHEMAS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/docs/failure-classes/schema"

SUBCMD="${1:-}"
TARGET="${2:-}"
case "$SUBCMD" in
  prove|check-row) ;;
  *) echo "fm-cue-validate: usage: fm-cue-validate.sh {prove <ledger>|check-row <row-file>}" >&2; exit 2 ;;
esac
[ -n "$TARGET" ] || { echo "fm-cue-validate: a target path is required" >&2; exit 2; }

# Read the fixture-gated simulation marker from the TARGET's own directory (both conditions: the
# marker exists in that directory, and the target is inside it). Absent marker => no simulation.
SIMULATE_MISSING=""
_target_dir=$(dirname "$TARGET")
if [ -d "$_target_dir" ]; then
  _marker="$(cd "$_target_dir" && pwd)/.fm-cue-test-sandbox"
  [ -f "$_marker" ] && SIMULATE_MISSING=$(tr '\n' ',' < "$_marker" 2>/dev/null)
fi

# python3 is a HARD prerequisite. Absence is non-authoritative and fails closed.
case ",$SIMULATE_MISSING," in
  *,python3,*)
    echo "CUE_VALIDATOR_UNAVAILABLE" >&2
    echo "fm-cue-validate: python3 unavailable (test sandbox); refusing rather than degrading" >&2
    exit 1 ;;
esac
if ! command -v python3 >/dev/null 2>&1; then
  echo "CUE_VALIDATOR_UNAVAILABLE" >&2
  echo "fm-cue-validate: python3 is a hard prerequisite; refusing rather than degrading to a weaker check" >&2
  exit 1
fi

python3 - "$SUBCMD" "$TARGET" "$SCHEMAS_DIR" "$SIMULATE_MISSING" <<'PYEOF'
import json, os, subprocess, sys

MODE, TARGET, SCHEMAS_DIR, SIMULATE_MISSING = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

_SIMULATE_MISSING = set(m for m in SIMULATE_MISSING.split(",") if m)


def unavailable(msg):
    sys.stderr.write("CUE_VALIDATOR_UNAVAILABLE\n")
    sys.stderr.write("fm-cue-validate: " + msg + "\n")
    sys.exit(1)


# jsonschema joins python3 as a hard prerequisite: without a real schema engine we cannot POSITIVELY
# prove additionalProperties:false / enum / type conformance, so we refuse rather than degrade.
if "jsonschema" in _SIMULATE_MISSING:
    unavailable("jsonschema unavailable (simulated); refusing")
try:
    from jsonschema import Draft202012Validator
except Exception:
    unavailable("jsonschema is required to prove schema conformance; refusing rather than degrading")


def invalid(msg):
    sys.stderr.write("CUE_LEDGER_INVALID\n")
    sys.stderr.write("fm-cue-validate: " + msg + "\n")
    sys.exit(1)


def missing(msg):
    sys.stderr.write("CUE_LEDGER_MISSING\n")
    sys.stderr.write("fm-cue-validate: " + msg + "\n")
    sys.exit(1)


class DupKey(Exception):
    def __init__(self, key):
        self.key = key


def _no_dupes(pairs):
    seen = set()
    for k, _ in pairs:
        if k in seen:
            raise DupKey(k)
        seen.add(k)
    return dict(pairs)


def load_schema(basename):
    path = os.path.join(SCHEMAS_DIR, basename)
    if not os.path.isfile(path):
        unavailable("committed schema missing: %s" % path)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            schema = json.load(fh)
        Draft202012Validator.check_schema(schema)
        return Draft202012Validator(schema)
    except Exception as e:
        unavailable("committed schema invalid (%s): %s" % (basename, e))


EVENT_V = load_schema("ledger-event.schema.json")
DETECTION_V = load_schema("detection-row.schema.json")


def schema_first_error(validator, instance):
    errs = sorted(validator.iter_errors(instance),
                  key=lambda e: [str(p) for p in e.absolute_path])
    if not errs:
        return None
    e = errs[0]
    loc = "/".join(str(p) for p in e.absolute_path) or "<root>"
    return "%s: %s" % (loc, e.message)


def pattern_compiles(engine, pattern):
    # Defence-in-depth AFTER schema conformance: the pattern must actually COMPILE under the engine
    # that will execute it. An awk-ere pattern is probed with grep -E against empty input: exit 0/1 is
    # a valid regex (match / no match), >=2 is a syntactically invalid one.
    if engine == "awk-ere":
        try:
            rc = subprocess.run(["grep", "-E", "-e", pattern, "/dev/null"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
        except Exception as e:
            invalid("cannot run the grep -E compile probe: %s" % e)
        return rc < 2
    return False


def raw_line_checks(bline, where):
    # Reject BOM, control bytes, and non-UTF-8 on the RAW bytes before any parse.
    if b"\xef\xbb\xbf" in bline:
        invalid("%s contains a UTF-8 BOM" % where)
    for b in bline:
        if b < 0x20 or b == 0x7F:
            invalid("%s contains a control byte (0x%02x)" % (where, b))
    try:
        return bline.decode("utf-8")
    except Exception as e:
        invalid("%s is not valid UTF-8: %s" % (where, e))


def parse_object(text, where):
    # object_pairs_hook rejects a duplicate member at ANY depth before the object materializes; jq
    # cannot do this. json.loads also rejects trailing garbage after a valid object.
    try:
        obj = json.loads(text, object_pairs_hook=_no_dupes)
    except DupKey as e:
        invalid("%s has a duplicate member name at some depth: %s" % (where, e.key))
    except Exception as e:
        invalid("%s is not one valid JSON object: %s" % (where, e))
    if not isinstance(obj, dict):
        invalid("%s is not a JSON object" % where)
    return obj


def check_detection(drow, where):
    derr = schema_first_error(DETECTION_V, drow)
    if derr is not None:
        invalid("%s violates the detection-row schema at %s" % (where, derr))
    if not pattern_compiles(drow["engine"], drow["pattern"]):
        invalid("%s pattern does not compile under %s: %s" % (where, drow["engine"], drow["pattern"]))


# =========================== check-row: a single raw detection row ===========================
if MODE == "check-row":
    if not os.path.isfile(TARGET):
        invalid("detection row file not found: %s" % TARGET)
    with open(TARGET, "rb") as fh:
        raw = fh.read()
    # A row is one line's worth of bytes; a trailing newline is tolerated, nothing else.
    if raw.endswith(b"\n"):
        raw = raw[:-1]
    if raw == b"" or raw.strip() == b"":
        invalid("detection row is empty")
    text = raw_line_checks(raw, "detection row")
    drow = parse_object(text, "detection row")
    check_detection(drow, "detection row")
    sys.exit(0)

# =============================== prove: the whole ledger =====================================
if not os.path.exists(TARGET):
    missing("ledger file does not exist: %s (a missing ledger is never valid-empty)" % TARGET)
try:
    with open(TARGET, "rb") as fh:
        raw = fh.read()
except Exception as e:
    invalid("cannot read ledger %s: %s" % (TARGET, e))

if raw == b"":
    sys.stdout.write("[]\n")   # empty-but-present ledger: valid-empty (zero events)
    sys.exit(0)

if raw.startswith(b"\xef\xbb\xbf"):
    invalid("ledger begins with a UTF-8 BOM")

parts = raw.split(b"\n")
if parts and parts[-1] == b"":
    parts = parts[:-1]   # drop the final trailing newline's empty element only
else:
    invalid("ledger does not end with a newline (possible truncated/half-written final line)")

events = []
for lineno, bline in enumerate(parts, start=1):
    where = "line %d" % lineno
    if bline == b"":
        invalid("%s is empty (no blank lines permitted)" % where)
    if bline.strip() == b"":
        invalid("%s is whitespace-only" % where)
    text = raw_line_checks(bline, where)
    obj = parse_object(text, where)
    err = schema_first_error(EVENT_V, obj)
    if err is not None:
        invalid("%s violates the ledger-event schema at %s" % (where, err))
    if obj.get("event") in ("class-defined", "class-amended"):
        for di, drow in enumerate(obj.get("detection", []) or []):
            check_detection(drow, "%s detection[%d]" % (where, di))
    events.append((lineno, obj))

# fold: no duplicate class id; occurrence/amendment refers only to a defined id.
defs = {}
order = []
for lineno, e in events:
    kind = e["event"]
    cid = e["id"]
    if kind == "class-defined":
        if cid in defs:
            invalid("line %d duplicate class-defined id: %s" % (lineno, cid))
        rec = {k: v for k, v in e.items() if k != "event"}
        rec.setdefault("detection", [])
        rec["cues"] = list(rec.get("cues", []))
        defs[cid] = rec
        order.append(cid)
    elif kind == "occurrence":
        if cid not in defs:
            invalid("line %d occurrence for an undefined class id: %s" % (lineno, cid))
        defs[cid]["provenance"].append(e["provenance"])
    elif kind == "class-amended":
        if cid not in defs:
            invalid("line %d amendment for an undefined class id: %s" % (lineno, cid))
        if e.get("detection"):
            defs[cid].setdefault("detection", [])
            defs[cid]["detection"].extend(e["detection"])
        if e.get("cues"):
            defs[cid].setdefault("cues", [])
            defs[cid]["cues"].extend(e["cues"])

snapshot = []
for cid in order:
    rec = defs[cid]
    rec["occurrence_count"] = len(rec.get("provenance", []))
    if not rec.get("detection"):
        rec.pop("detection", None)
    snapshot.append(rec)

json.dump(snapshot, sys.stdout)
sys.stdout.write("\n")
sys.exit(0)
PYEOF

#!/usr/bin/env bash
# fm-dismissal-validate.sh - the sole dismissal-ledger validation authority.
#
# Validation is one atomic pass over the raw JSONL bytes using python3 and
# jsonschema Draft 2020-12 as hard prerequisites.
# Duplicate members are rejected before JSON materialization.
# Every event must conform to the committed closed schema, every timestamp must
# be a real UTC instant, review_after must be later than created_at, ids must be
# unique, and every scope must remain repository-relative and non-global.
#
# Usage:
#   fm-dismissal-validate.sh prove <ledger-path>
#
# Success prints the proven event array.
# Failure prints one marker followed by one diagnostic and exits nonzero:
#   DISMISSAL_VALIDATOR_UNAVAILABLE
#   DISMISSAL_LEDGER_MISSING
#   DISMISSAL_LEDGER_INVALID
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA="$SCRIPT_DIR/../docs/scanner/schema/dismissal-event.schema.json"

[ "${1:-}" = prove ] && [ "$#" -eq 2 ] || {
  echo "fm-dismissal-validate: usage: fm-dismissal-validate.sh prove <ledger-path>" >&2
  exit 2
}
TARGET=$2

if ! command -v python3 >/dev/null 2>&1; then
  echo "DISMISSAL_VALIDATOR_UNAVAILABLE" >&2
  echo "fm-dismissal-validate: python3 is a hard prerequisite; refusing" >&2
  exit 1
fi

python3 - "$TARGET" "$SCHEMA" <<'PYEOF'
import datetime
import json
import os
import sys

TARGET, SCHEMA = sys.argv[1], sys.argv[2]


def unavailable(message):
    sys.stderr.write("DISMISSAL_VALIDATOR_UNAVAILABLE\n")
    sys.stderr.write("fm-dismissal-validate: %s\n" % message)
    sys.exit(1)


def missing(message):
    sys.stderr.write("DISMISSAL_LEDGER_MISSING\n")
    sys.stderr.write("fm-dismissal-validate: %s\n" % message)
    sys.exit(1)


def invalid(message):
    sys.stderr.write("DISMISSAL_LEDGER_INVALID\n")
    sys.stderr.write("fm-dismissal-validate: %s\n" % message)
    sys.exit(1)


try:
    from jsonschema import Draft202012Validator
except Exception:
    unavailable("jsonschema is required to prove schema conformance; refusing")


class DuplicateKey(Exception):
    def __init__(self, key):
        self.key = key


def no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateKey(key)
        result[key] = value
    return result


if not os.path.isfile(SCHEMA):
    unavailable("committed schema missing: %s" % SCHEMA)
try:
    with open(SCHEMA, "r", encoding="utf-8") as handle:
        schema = json.load(handle, object_pairs_hook=no_duplicates)
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema)
except Exception as exc:
    unavailable("committed schema invalid: %s" % exc)

if not os.path.exists(TARGET):
    missing("ledger file does not exist: %s" % TARGET)
try:
    with open(TARGET, "rb") as handle:
        raw = handle.read()
except Exception as exc:
    invalid("cannot read ledger %s: %s" % (TARGET, exc))

if raw == b"":
    sys.stdout.write("[]\n")
    sys.exit(0)
if raw.startswith(b"\xef\xbb\xbf"):
    invalid("ledger begins with a UTF-8 BOM")

lines = raw.split(b"\n")
if lines[-1] != b"":
    invalid("ledger does not end with a newline")
lines = lines[:-1]

events = []
ids = set()
for number, raw_line in enumerate(lines, start=1):
    where = "line %d" % number
    if not raw_line or not raw_line.strip():
        invalid("%s is blank" % where)
    for byte in raw_line:
        if byte < 0x20 or byte == 0x7f:
            invalid("%s contains a control byte" % where)
    try:
        text = raw_line.decode("utf-8")
        event = json.loads(text, object_pairs_hook=no_duplicates)
    except DuplicateKey as exc:
        invalid("%s has duplicate member: %s" % (where, exc.key))
    except Exception as exc:
        invalid("%s is not one valid UTF-8 JSON object: %s" % (where, exc))
    if not isinstance(event, dict):
        invalid("%s is not a JSON object" % where)
    errors = sorted(
        validator.iter_errors(event),
        key=lambda item: [str(part) for part in item.absolute_path],
    )
    if errors:
        error = errors[0]
        location = "/".join(str(part) for part in error.absolute_path) or "<root>"
        invalid("%s violates the schema at %s: %s" % (where, location, error.message))
    if event["id"] in ids:
        invalid("%s repeats dismissal id %s" % (where, event["id"]))
    ids.add(event["id"])
    try:
        created = datetime.datetime.strptime(
            event["created_at"], "%Y-%m-%dT%H:%M:%SZ"
        ).replace(tzinfo=datetime.timezone.utc)
        review = datetime.datetime.strptime(
            event["review_after"], "%Y-%m-%dT%H:%M:%SZ"
        ).replace(tzinfo=datetime.timezone.utc)
    except ValueError as exc:
        invalid("%s carries an impossible timestamp: %s" % (where, exc))
    if review <= created:
        invalid("%s review_after must be later than created_at" % where)
    if review - created > datetime.timedelta(days=180):
        invalid("%s review_after exceeds the 180-day re-review ceiling" % where)
    scope = event["scope"]
    scoped_path = scope.get("path", scope.get("path_prefix"))
    if (
        scoped_path.startswith("/")
        or scoped_path in (".", "./", "*", "**", "*/", "**/")
        or any(part == ".." for part in scoped_path.split("/"))
        or any(marker in scoped_path for marker in ("*", "?", "[", "]"))
    ):
        invalid("%s scope is global, absolute, or escapes the repository" % where)
    if scope["kind"] == "rule" and not scoped_path.endswith("/"):
        invalid("%s rule scope must be a directory prefix ending in /" % where)
    if scope["kind"] == "rule" and event["scanner"] == "gitleaks":
        invalid("%s secrets-class dismissals must use exact path scope" % where)
    events.append(event)

json.dump(events, sys.stdout, separators=(",", ":"))
sys.stdout.write("\n")
PYEOF

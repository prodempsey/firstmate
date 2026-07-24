#!/usr/bin/env bash
# Fail-closed validator for the governed agent-profile matrix (model-economy
# program, ORD-224 slice S3). Design authority:
# data/model-economy/ord-223-report.md §G (profile matrix), §H (model policy),
# §I (effort policy); B.1 #1 (committed manifest) and #15 (tracked-material home).
# Authority-pattern authority: data/dj-orders-s2/design-ruling.md.
#
# The manifest docs/model-economy/governed-profiles.manifest.json is the single
# committed source of truth for all 11 governed profiles. This script asserts
# that the IN-SESSION surface (.claude/agents/<profile>.md frontmatter) agrees
# with the manifest per profile, and — when a SHELL-CREW bindings file that
# carries governed entries is present — that its model/effort agree too.
#
# AUTHORITY MODEL (per the DJ ruling): the matrix is authoritative ONLY if ONE
# strict validation pass POSITIVELY PROVES every property — JSON/YAML parses
# cleanly, every key is unique at every depth, every value has exactly the
# required type, and every cross-surface value agrees. There is no weaker
# fallback: any parse ambiguity, type violation, missing required key, or absent
# host tool is non-authoritative and fails closed. The parser (python3 with
# PyYAML + json) is a HARD prerequisite; if it is unavailable the validator
# REFUSES rather than degrading to a weaker check. Regex line-scraping of YAML is
# deliberately gone — it could not prove a whole-document parse and silently
# accepted schema-invalid frontmatter and mistyped manifest values.
#
# Usage: fm-profile-matrix-check.sh [--manifest <file>] [--agents-dir <dir>]
#                                   [--bindings <file>] [--quiet]
#   Defaults: manifest  = $FM_ROOT/docs/model-economy/governed-profiles.manifest.json
#             agents-dir = $FM_ROOT/.claude/agents
#             bindings   = (none) — cross-check runs only when --bindings is given
#                          and that file carries at least one governed profile key.
#
# Exit 0: the matrix is coherent. Prints "PROFILES_OK=<n>" unless --quiet.
# Exit 1: incoherent OR the validator could not run authoritatively. Prints
#   exactly one stable code line to stderr:
#   PROFILE_VALIDATOR_UNAVAILABLE | PROFILE_MANIFEST_MISSING | PROFILE_MANIFEST_INVALID |
#   PROFILE_MANIFEST_DUPLICATE_KEY | PROFILE_MANIFEST_SCHEMA_UNSUPPORTED |
#   PROFILE_MANIFEST_INCONSISTENT | PROFILE_PROHIBITED_PRESENT | PROFILE_FILE_MISSING |
#   PROFILE_FILE_UNKNOWN | PROFILE_FRONTMATTER_INVALID | PROFILE_FRONTMATTER_DUPLICATE_KEY |
#   PROFILE_NAME_MISMATCH | PROFILE_MODEL_MISMATCH | PROFILE_EFFORT_MISMATCH |
#   PROFILE_TOOLS_MISMATCH | PROFILE_WRITES_MISMATCH | PROFILE_NESTING_MISMATCH |
#   PROFILE_MAXTURNS_OUT_OF_RANGE | PROFILE_VERSION_MISMATCH | PROFILE_BINDINGS_MISMATCH
# Exit 2: usage error.
set -u

# SCRIPT_DIR / FM_ROOT via shell builtins only, so the sole external dependency
# is the validation engine itself (python3) — that keeps "refuse if the engine is
# absent" a clean, single check rather than one masked by a missing coreutil.
SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

MANIFEST=""
AGENTS_DIR=""
BINDINGS=""
QUIET=0
want=
for a in "$@"; do
  if [ -n "$want" ]; then
    case "$want" in
      manifest) MANIFEST=$a ;;
      agents) AGENTS_DIR=$a ;;
      bindings) BINDINGS=$a ;;
    esac
    want=
    continue
  fi
  case "$a" in
    --manifest) want=manifest ;;
    --agents-dir) want=agents ;;
    --bindings) want=bindings ;;
    --quiet) QUIET=1 ;;
    --*) echo "fm-profile-matrix-check: unknown flag $a" >&2; exit 2 ;;
    *) echo "fm-profile-matrix-check: unexpected argument $a" >&2; exit 2 ;;
  esac
done
if [ -n "$want" ]; then echo "fm-profile-matrix-check: --$want requires a value" >&2; exit 2; fi
[ -n "$MANIFEST" ] || MANIFEST="$FM_ROOT/docs/model-economy/governed-profiles.manifest.json"
[ -n "$AGENTS_DIR" ] || AGENTS_DIR="$FM_ROOT/.claude/agents"

# Hard prerequisite: the strict validation engine must be present. Absence is
# NON-AUTHORITATIVE and fails closed (never a weaker fallback), per the DJ ruling.
if ! command -v python3 >/dev/null 2>&1; then
  echo "PROFILE_VALIDATOR_UNAVAILABLE" >&2
  echo "fm-profile-matrix-check: python3 is a hard prerequisite; refusing rather than degrading to a weaker check" >&2
  exit 1
fi

python3 - "$MANIFEST" "$AGENTS_DIR" "$BINDINGS" "$QUIET" <<'PYEOF'
import json, os, sys

MANIFEST, AGENTS_DIR, BINDINGS, QUIET = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"

# PyYAML is part of the hard prerequisite: without a real YAML parser we cannot
# POSITIVELY prove a frontmatter document is well-formed, so we refuse.
try:
    import yaml
except Exception:
    sys.stderr.write("PROFILE_VALIDATOR_UNAVAILABLE\n")
    sys.stderr.write("fm-profile-matrix-check: PyYAML is required to prove frontmatter validity; refusing\n")
    sys.exit(1)

SCHEMA = "firstmate/governed-profiles/v1"
# The full confirmed frontmatter field set (ord-223-report.md §G sketch) plus the
# slice's profile_version. Any key outside this set is an unrecognized field and
# fails closed rather than being ignored.
ALLOWED_FM_KEYS = {
    "name", "description", "tools", "disallowedTools", "model", "permissionMode",
    "maxTurns", "mcpServers", "hooks", "skills", "initialPrompt", "memory",
    "EFFORT", "background", "isolation", "color", "profile_version",
}
PROFILE_KEYS = {"model", "effort", "writes", "nesting", "tools", "maxTurns", "version"}


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


def load_json_strict(path, missing_code, invalid_code, dup_code):
    if not os.path.isfile(path):
        die(missing_code, "file not found: %s" % path)
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    try:
        return json.loads(text, object_pairs_hook=_json_no_dupes)
    except DupKey as e:
        die(dup_code, "duplicate key in JSON (any depth): %s (%s)" % (e.key, path))
    except Exception as e:
        die(invalid_code, "not valid JSON: %s (%s)" % (e, path))


# --- strict YAML mapping loader: reject duplicate keys ----------------------
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


StrictLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _yaml_no_dupes
)


def is_bool(v):
    return type(v) is bool


def is_int(v):
    # bool is a subclass of int in Python; exclude it explicitly.
    return type(v) is int


def is_str(v):
    return isinstance(v, str)


# --- manifest: one strict pass, positively prove every property -------------
manifest = load_json_strict(
    MANIFEST, "PROFILE_MANIFEST_MISSING", "PROFILE_MANIFEST_INVALID",
    "PROFILE_MANIFEST_DUPLICATE_KEY",
)
if not isinstance(manifest, dict):
    die("PROFILE_MANIFEST_INVALID", "manifest top level must be an object")

if manifest.get("schema_version") != SCHEMA:
    die("PROFILE_MANIFEST_SCHEMA_UNSUPPORTED",
        "schema_version must be exactly '%s'" % SCHEMA)


def require_str_list(obj, field):
    v = obj.get(field)
    if not isinstance(v, list) or not all(is_str(x) and x for x in v):
        die("PROFILE_MANIFEST_INCONSISTENT",
            "%s must be a list of non-empty strings" % field)
    return v


models_allowed = require_str_list(manifest, "models_allowed")
efforts_allowed = require_str_list(manifest, "efforts_allowed")
prohibited = manifest.get("prohibited_profile_names")
if not isinstance(prohibited, list) or not all(is_str(x) and x for x in prohibited):
    die("PROFILE_MANIFEST_INCONSISTENT",
        "prohibited_profile_names must be a list of non-empty strings")
prohibited = set(prohibited)

profiles = manifest.get("profiles")
if not isinstance(profiles, dict) or not profiles:
    die("PROFILE_MANIFEST_INCONSISTENT", "profiles must be a non-empty object")

norm = {}  # validated per-profile record consumed by the frontmatter checks
for name, p in profiles.items():
    where = "manifest profile '%s'" % name
    if not (is_str(name) and name):
        die("PROFILE_MANIFEST_INCONSISTENT", "profile name must be a non-empty string")
    if name in prohibited:
        die("PROFILE_MANIFEST_INCONSISTENT", "prohibited name defined as a profile: %s" % name)
    if not isinstance(p, dict):
        die("PROFILE_MANIFEST_INCONSISTENT", "%s must be an object" % where)
    extra = set(p.keys()) - PROFILE_KEYS
    if extra:
        die("PROFILE_MANIFEST_INCONSISTENT", "%s has unknown key(s): %s" % (where, ",".join(sorted(extra))))
    missing = PROFILE_KEYS - set(p.keys())
    if missing:
        die("PROFILE_MANIFEST_INCONSISTENT", "%s missing key(s): %s" % (where, ",".join(sorted(missing))))

    model = p["model"]
    if not (is_str(model) and model in models_allowed):
        die("PROFILE_MANIFEST_INCONSISTENT", "%s model must be a string in models_allowed" % where)

    effort = p["effort"]
    if effort is not None and not (is_str(effort) and effort in efforts_allowed):
        die("PROFILE_MANIFEST_INCONSISTENT", "%s effort must be null or a string in efforts_allowed" % where)

    if not is_bool(p["writes"]):
        die("PROFILE_MANIFEST_INCONSISTENT", "%s writes must be a boolean" % where)
    if not is_bool(p["nesting"]):
        die("PROFILE_MANIFEST_INCONSISTENT", "%s nesting must be a boolean" % where)

    tools = p["tools"]
    if not isinstance(tools, list) or not tools or not all(is_str(x) and x for x in tools):
        die("PROFILE_MANIFEST_INCONSISTENT", "%s tools must be a non-empty list of non-empty strings" % where)
    if len(set(tools)) != len(tools):
        die("PROFILE_MANIFEST_INCONSISTENT", "%s tools must be unique" % where)

    mt = p["maxTurns"]
    if not isinstance(mt, dict) or set(mt.keys()) != {"min", "max"}:
        die("PROFILE_MANIFEST_INCONSISTENT", "%s maxTurns must be an object with exactly min,max" % where)
    if not (is_int(mt["min"]) and is_int(mt["max"])):
        die("PROFILE_MANIFEST_INCONSISTENT", "%s maxTurns.min/max must be integers" % where)
    if mt["min"] < 1 or mt["min"] > mt["max"]:
        die("PROFILE_MANIFEST_INCONSISTENT", "%s maxTurns range invalid (1<=min<=max)" % where)

    if not is_int(p["version"]):
        die("PROFILE_MANIFEST_INCONSISTENT", "%s version must be an integer" % where)

    # Effort-tier constraints (captain policy, §G/§H/§I).
    if model == "haiku" and effort is not None:
        die("PROFILE_MANIFEST_INCONSISTENT", "%s (haiku) must have null effort" % where)
    if model == "sonnet" and effort != "high":
        die("PROFILE_MANIFEST_INCONSISTENT", "%s (sonnet) must be fixed at high" % where)
    if model == "opus" and effort == "max":
        die("PROFILE_MANIFEST_INCONSISTENT", "%s (opus) must not be max" % where)
    if model == "fable" and effort in ("xhigh", "max"):
        die("PROFILE_MANIFEST_INCONSISTENT", "%s (fable) must not be %s" % (where, effort))

    norm[name] = {
        "model": model, "effort": effort, "writes": p["writes"],
        "nesting": p["nesting"], "tools": sorted(tools),
        "min": mt["min"], "max": mt["max"], "version": p["version"],
    }

# --- directory: exactly the manifest profiles, no prohibited, no unknown ----
if os.path.isdir(AGENTS_DIR):
    for fn in sorted(os.listdir(AGENTS_DIR)):
        if not fn.endswith(".md"):
            continue
        if not os.path.isfile(os.path.join(AGENTS_DIR, fn)):
            continue
        stem = fn[:-3]
        if stem in prohibited:
            die("PROFILE_PROHIBITED_PRESENT", "prohibited profile file exists: %s" % fn)
        if stem not in norm:
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
    block = "\n".join(body)
    try:
        data = yaml.load(block, Loader=StrictLoader)
    except DupKey as e:
        die("PROFILE_FRONTMATTER_DUPLICATE_KEY", "%s.md duplicate frontmatter key: %s" % (name, e.key))
    except Exception as e:
        die("PROFILE_FRONTMATTER_INVALID", "%s.md frontmatter is not valid YAML: %s" % (name, e))
    if not isinstance(data, dict) or not data:
        die("PROFILE_FRONTMATTER_INVALID", "%s.md frontmatter must be a non-empty mapping" % name)
    unknown = set(data.keys()) - ALLOWED_FM_KEYS
    if unknown:
        die("PROFILE_FRONTMATTER_INVALID", "%s.md has unrecognized frontmatter key(s): %s"
            % (name, ",".join(sorted(str(k) for k in unknown))))
    return data


# --- per-profile frontmatter agreement --------------------------------------
count = 0
for name in sorted(norm.keys()):
    m = norm[name]
    path = os.path.join(AGENTS_DIR, name + ".md")
    if not os.path.isfile(path):
        die("PROFILE_FILE_MISSING", "missing agent file for profile: %s.md" % name)
    fm = load_frontmatter(path, name)

    if fm.get("name") != name:
        die("PROFILE_NAME_MISMATCH", "%s.md frontmatter name must equal '%s'" % (name, name))
    if fm.get("model") != m["model"]:
        die("PROFILE_MODEL_MISMATCH", "%s.md model must be '%s'" % (name, m["model"]))

    if m["effort"] is None:
        if "EFFORT" in fm:
            die("PROFILE_EFFORT_MISMATCH", "%s.md (haiku) must carry no EFFORT key" % name)
    else:
        if fm.get("EFFORT") != m["effort"]:
            die("PROFILE_EFFORT_MISMATCH", "%s.md EFFORT must be '%s'" % (name, m["effort"]))

    tools = fm.get("tools")
    if not isinstance(tools, list) or not all(is_str(x) for x in tools):
        die("PROFILE_FRONTMATTER_INVALID", "%s.md tools must be a YAML list of strings" % name)
    if len(set(tools)) != len(tools):
        die("PROFILE_TOOLS_MISMATCH", "%s.md tools must be unique" % name)
    if sorted(tools) != m["tools"]:
        die("PROFILE_TOOLS_MISMATCH", "%s.md tools must be %s, got %s" % (name, m["tools"], sorted(tools)))

    has_write = any(t in ("Write", "Edit") for t in tools)
    if m["writes"] and not has_write:
        die("PROFILE_WRITES_MISMATCH", "%s.md a writing profile must list Write/Edit tools" % name)
    if not m["writes"] and has_write:
        die("PROFILE_WRITES_MISMATCH", "%s.md a non-writing profile must not list Write/Edit tools" % name)

    has_agent = "Agent" in tools
    disallowed = fm.get("disallowedTools", [])
    if disallowed is None:
        disallowed = []
    if not isinstance(disallowed, list) or not all(is_str(x) for x in disallowed):
        die("PROFILE_FRONTMATTER_INVALID", "%s.md disallowedTools must be a YAML list of strings" % name)
    disallow_agent = "Agent" in disallowed
    if m["nesting"]:
        if not has_agent:
            die("PROFILE_NESTING_MISMATCH", "%s.md nesting profile must list the Agent tool" % name)
        if disallow_agent:
            die("PROFILE_NESTING_MISMATCH", "%s.md nesting profile must not disallow Agent" % name)
    else:
        if has_agent:
            die("PROFILE_NESTING_MISMATCH", "%s.md non-nesting profile must not list the Agent tool" % name)
        if not disallow_agent:
            die("PROFILE_NESTING_MISMATCH", "%s.md non-nesting profile must disallow the Agent tool" % name)

    turns = fm.get("maxTurns")
    if not is_int(turns):
        die("PROFILE_FRONTMATTER_INVALID", "%s.md maxTurns must be an integer, got %r" % (name, turns))
    if turns < m["min"] or turns > m["max"]:
        die("PROFILE_MAXTURNS_OUT_OF_RANGE", "%s.md maxTurns %d outside [%d,%d]" % (name, turns, m["min"], m["max"]))

    if fm.get("profile_version") != m["version"]:
        die("PROFILE_VERSION_MISMATCH", "%s.md profile_version must be %r" % (name, m["version"]))

    count += 1

# --- optional SHELL-CREW bindings cross-check -------------------------------
# Runs only when a bindings file is provided. For each governed profile name it
# carries, the bindings effort must equal the manifest effort (empty == null) and
# the bindings model string must contain the manifest model token. A bindings
# file that carries only legacy crew-dispatch names is a clean no-op.
if BINDINGS:
    b = load_json_strict(
        BINDINGS, "PROFILE_BINDINGS_MISMATCH", "PROFILE_BINDINGS_MISMATCH",
        "PROFILE_BINDINGS_MISMATCH",
    )
    if not isinstance(b, dict):
        die("PROFILE_BINDINGS_MISMATCH", "bindings top level must be an object")
    for name in sorted(norm.keys()):
        if name not in b:
            continue
        entry = b[name]
        if not isinstance(entry, dict):
            die("PROFILE_BINDINGS_MISMATCH", "bindings %s must be an object" % name)
        b_model = entry.get("model") or ""
        b_effort = entry.get("effort") or ""
        m_effort = norm[name]["effort"] or ""
        if b_effort != m_effort:
            die("PROFILE_BINDINGS_MISMATCH", "bindings %s effort '%s' != manifest '%s'" % (name, b_effort, m_effort))
        if norm[name]["model"] not in b_model:
            die("PROFILE_BINDINGS_MISMATCH", "bindings %s model '%s' does not carry tier '%s'"
                % (name, b_model, norm[name]["model"]))

if not QUIET:
    sys.stdout.write("PROFILES_OK=%d\n" % count)
sys.exit(0)
PYEOF
exit $?

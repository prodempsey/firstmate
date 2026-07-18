#!/usr/bin/env bash
# Fail-closed validator + fingerprint for the live crew-profile bindings file
# (state/crew-profile-bindings.json). Added by the model-economy program
# (ORD-225, Phase 2); design authority: data/model-economy/ord-223-report.md sections K/P.
#
# Usage: fm-bindings-validate.sh [<bindings-file>] [--quiet] [--fingerprint-only]
#                                [--expect-fingerprint <sha256>] [--write-sidecar]
#   Default file: $STATE/crew-profile-bindings.json (FM_HOME / FM_STATE_OVERRIDE
#   respected exactly like bin/fm-profile.sh).
#   Metadata sidecar: <file minus .json>.meta.json - REQUIRED when the bindings
#   file exists. Metadata lives in a sidecar, not inside the bindings JSON,
#   because Fleet Bridge's crew-profile-store accepts only `_comment` plus
#   profile objects at top level (verified 2026-07-18); an in-file `_meta`
#   object would be read as a profile and rejected by the Bridge writer.
#
# Exit 0: valid. Prints "FINGERPRINT=<sha256>" and "SCHEMA_VERSION=<n>" unless
#   --quiet ( --fingerprint-only prints just the bare fingerprint).
# Exit 1: invalid. Prints exactly one stable error code line to stderr:
#   BINDINGS_FILE_MISSING | BINDINGS_JSON_INVALID | BINDINGS_SCHEMA_UNSUPPORTED |
#   BINDINGS_METADATA_INVALID | BINDINGS_PROFILE_DUPLICATE | BINDINGS_PROFILE_UNKNOWN |
#   BINDINGS_MODEL_INVALID | BINDINGS_EFFORT_INVALID | BINDINGS_MODEL_EFFORT_PROHIBITED |
#   BINDINGS_FINGERPRINT_MISMATCH
# On failure the invalid file is left untouched for investigation; callers must
# NOT fall back to any default model (and never to Fable) - no dispatch.
#
# Fingerprint (deterministic, semantic): sha256 of `jq -S -c 'del(._comment)'`
# over the bindings file. Key order is canonicalized (jq -S); array order (e.g.
# backups[]) is semantic and preserved. `_comment` and the sidecar metadata are
# excluded, so provenance wording changes never alter the fingerprint while any
# routing-value change always does. Stored on demand in the sidecar
# <file minus .json>.fingerprint via --write-sidecar (avoids a self-referential
# hash: the fingerprint is never part of the hashed content).
#
# Captain model constraints enforced here (ORD-225):
#   - model containing "opus"  : effort "max" prohibited
#   - model containing "fable" : effort "xhigh"/"max" prohibited
#   - model containing "haiku" : any effort field prohibited (no effort exists)
#   - effort must be one of low|medium|high|xhigh|max when present
#   - model must be non-empty, printable, no styling/control characters
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

FILE=""
QUIET=0
FP_ONLY=0
EXPECT_FP=""
WRITE_SIDECAR=0
want=
for a in "$@"; do
  if [ -n "$want" ]; then EXPECT_FP=$a; want=; continue; fi
  case "$a" in
    --quiet) QUIET=1 ;;
    --fingerprint-only) FP_ONLY=1 ;;
    --expect-fingerprint) want=1 ;;
    --write-sidecar) WRITE_SIDECAR=1 ;;
    --*) echo "fm-bindings-validate: unknown flag $a" >&2; exit 2 ;;
    *) FILE=$a ;;
  esac
done
[ -z "$want" ] || { echo "fm-bindings-validate: --expect-fingerprint requires a value" >&2; exit 2; }
[ -n "$FILE" ] || FILE="$STATE/crew-profile-bindings.json"
META="${FILE%.json}.meta.json"
FPSIDE="${FILE%.json}.fingerprint"

fail() { # fail <CODE> <message>
  echo "$1: $2" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail BINDINGS_JSON_INVALID "jq not found (repo JSON dependency)"

[ -f "$FILE" ] || fail BINDINGS_FILE_MISSING "$FILE does not exist"

jq -e . "$FILE" >/dev/null 2>&1 || fail BINDINGS_JSON_INVALID "$FILE is not valid JSON"
[ "$(jq -r 'type' "$FILE")" = object ] || fail BINDINGS_JSON_INVALID "top level must be an object"

# Duplicate keys (any depth): jq's parse silently keeps the last occurrence, so a
# raw parse with duplicate detection is required. python3's object_pairs_hook sees
# every raw pair; jq --stream cannot reliably expose duplicate object-valued keys
# (verified empirically 2026-07-18). Degrades to a no-op with a warning if python3
# is ever absent (it is present on this platform; jq remains the primary dependency).
if command -v python3 >/dev/null 2>&1; then
  dupout=$(python3 - "$FILE" <<'PYEOF' 2>&1
import json, sys
dups = []
def hook(pairs):
    ks = [k for k, _ in pairs]
    for k in sorted(set(k for k in ks if ks.count(k) > 1)):
        dups.append(k)
    return dict(pairs)
json.load(open(sys.argv[1]), object_pairs_hook=hook)
if dups:
    print(",".join(dups)); sys.exit(3)
PYEOF
) || { rc=$?; [ "$rc" -eq 3 ] && fail BINDINGS_PROFILE_DUPLICATE "duplicate key(s) in raw JSON: $dupout"; fail BINDINGS_JSON_INVALID "raw-parse failed: $dupout"; }
else
  echo "fm-bindings-validate: warning: python3 absent - duplicate-key check skipped" >&2
fi

# Metadata sidecar
[ -f "$META" ] || fail BINDINGS_METADATA_INVALID "metadata sidecar $META missing"
jq -e . "$META" >/dev/null 2>&1 || fail BINDINGS_METADATA_INVALID "$META is not valid JSON"
for f in schema_version config_role environment authority owner source_example commit_policy description; do
  jq -e --arg f "$f" 'has($f)' "$META" >/dev/null 2>&1 || fail BINDINGS_METADATA_INVALID "metadata missing required field: $f"
done
SCHEMA_VERSION=$(jq -r '.schema_version' "$META")
[ "$SCHEMA_VERSION" = "1" ] || fail BINDINGS_SCHEMA_UNSUPPORTED "schema_version '$SCHEMA_VERSION' not supported (supported: 1)"
[ "$(jq -r '.config_role' "$META")" = "crew-profile-bindings-live" ] || fail BINDINGS_METADATA_INVALID "config_role must be crew-profile-bindings-live"
if jq -r '.description' "$META" | grep -qi 'test fixture'; then
  fail BINDINGS_METADATA_INVALID "description must not identify the live file as a test fixture"
fi

# Known profile names: default_profile + task_classes values from crew-profiles.json
PROFILES_JSON="$CONFIG/crew-profiles.json"
[ -f "$PROFILES_JSON" ] || PROFILES_JSON="$FM_ROOT/docs/examples/crew-profiles.json"
if [ -f "$PROFILES_JSON" ] && jq -e . "$PROFILES_JSON" >/dev/null 2>&1; then
  known=$(jq -r '([.default_profile] + ([.task_classes[]])) | map(select(type == "string")) | unique | .[]' "$PROFILES_JSON")
  unknown=$(jq -r 'keys[] | select(. != "_comment")' "$FILE" | while read -r k; do
    echo "$known" | grep -qxF "$k" || echo "$k"
  done)
  [ -z "$unknown" ] || fail BINDINGS_PROFILE_UNKNOWN "not referenced by crew-profiles.json: $(echo "$unknown" | tr '\n' ' ')"
fi

# _comment, if present, must be a string
if jq -e 'has("_comment")' "$FILE" >/dev/null; then
  [ "$(jq -r '._comment | type' "$FILE")" = string ] || fail BINDINGS_JSON_INVALID "_comment must be a string"
fi

# Per-binding shape / model / effort / prohibitions.
# Candidates = every direct binding + backups[] + counterpart entries + their backups.
CANDIDATES=$(jq -c '
  [ to_entries[] | select(.key != "_comment") |
    .key as $p |
    ( if (.value | has("counterpart")) then
        (.value.counterpart | to_entries[] |
          [ {profile: $p, via: ("counterpart." + .key), b: .value} ] +
          [ (.value.backups // [])[] | {profile: $p, via: ("counterpart." + .key + ".backup"), b: .} ] )
      else
        [ {profile: $p, via: "primary", b: .value} ] +
        [ (.value.backups // [])[] | {profile: $p, via: "backup", b: .} ]
      end ) | .[]
  ]' "$FILE" 2>/dev/null) || fail BINDINGS_JSON_INVALID "binding entries must be objects"

n=$(jq 'length' <<<"$CANDIDATES")
i=0
while [ "$i" -lt "$n" ]; do
  c=$(jq -c ".[$i]" <<<"$CANDIDATES")
  prof=$(jq -r '.profile' <<<"$c"); via=$(jq -r '.via' <<<"$c")
  btype=$(jq -r '.b | type' <<<"$c")
  [ "$btype" = object ] || fail BINDINGS_JSON_INVALID "$prof ($via): binding must be an object"
  harness=$(jq -r '.b.harness // empty' <<<"$c")
  model=$(jq -r '.b.model // empty' <<<"$c")
  effort=$(jq -r '.b.effort // empty' <<<"$c")
  has_effort=$(jq -r '.b | has("effort")' <<<"$c")
  case "$harness" in
    claude|codex|opencode|pi|grok|gemini) ;;
    *) fail BINDINGS_MODEL_INVALID "$prof ($via): unknown harness '$harness' (verified: claude codex opencode pi grok gemini)" ;;
  esac
  [ -n "$model" ] || fail BINDINGS_MODEL_INVALID "$prof ($via): empty or missing model"
  if ! printf '%s' "$model" | LC_ALL=C grep -qE '^[A-Za-z0-9][A-Za-z0-9._/:-]*$'; then
    fail BINDINGS_MODEL_INVALID "$prof ($via): malformed model value (styling/control/illegal characters)"
  fi
  if [ "$has_effort" = true ]; then
    case "$effort" in
      low|medium|high|xhigh|max) ;;
      *) fail BINDINGS_EFFORT_INVALID "$prof ($via): unknown effort '$effort' (allowed: low medium high xhigh max)" ;;
    esac
    lcmodel=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')
    case "$lcmodel" in
      *haiku*) fail BINDINGS_MODEL_EFFORT_PROHIBITED "$prof ($via): Haiku has no configurable effort (found effort=$effort)" ;;
      *opus*)  [ "$effort" != max ] || fail BINDINGS_MODEL_EFFORT_PROHIBITED "$prof ($via): Opus max is prohibited" ;;
      *fable*) case "$effort" in xhigh|max) fail BINDINGS_MODEL_EFFORT_PROHIBITED "$prof ($via): Fable $effort is prohibited (ceiling: high)";; esac ;;
    esac
  fi
  i=$((i+1))
done

# Fingerprint: canonical semantic serialization (sorted keys, _comment excluded)
FP=$(jq -S -c 'del(._comment)' "$FILE" | sha256sum | awk '{print $1}')
if [ -n "$EXPECT_FP" ] && [ "$FP" != "$EXPECT_FP" ]; then
  fail BINDINGS_FINGERPRINT_MISMATCH "expected $EXPECT_FP got $FP"
fi
if [ "$WRITE_SIDECAR" -eq 1 ]; then
  printf '{"fingerprint":"%s","schema_version":%s,"validated_at":"%s"}\n' \
    "$FP" "$SCHEMA_VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$FPSIDE"
fi
if [ "$FP_ONLY" -eq 1 ]; then
  echo "$FP"
elif [ "$QUIET" -eq 0 ]; then
  echo "FINGERPRINT=$FP"
  echo "SCHEMA_VERSION=$SCHEMA_VERSION"
fi
exit 0

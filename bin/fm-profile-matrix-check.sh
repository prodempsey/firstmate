#!/usr/bin/env bash
# Fail-closed validator for the governed agent-profile matrix (model-economy
# program, ORD-224 slice S3). Design authority:
# data/model-economy/ord-223-report.md §G (profile matrix), §H (model policy),
# §I (effort policy); B.1 #1 (committed manifest) and #15 (tracked-material home).
#
# The manifest docs/model-economy/governed-profiles.manifest.json is the single
# committed source of truth for all 11 governed profiles. This script asserts
# that the IN-SESSION surface (.claude/agents/<profile>.md frontmatter) agrees
# with the manifest per profile, and — when a SHELL-CREW bindings file that
# carries governed entries is present — that its model/effort agree too. Nothing
# is hand-maintained in two places; drift fails closed here.
#
# Usage: fm-profile-matrix-check.sh [--manifest <file>] [--agents-dir <dir>]
#                                   [--bindings <file>] [--quiet]
#   Defaults: manifest  = $FM_ROOT/docs/model-economy/governed-profiles.manifest.json
#             agents-dir = $FM_ROOT/.claude/agents
#             bindings   = (none) — cross-check runs only when --bindings is given
#                          and that file carries at least one governed profile key.
#
# Exit 0: the matrix is coherent. Prints "PROFILES_OK=<n>" unless --quiet.
# Exit 1: incoherent. Prints exactly one stable code line to stderr:
#   PROFILE_MANIFEST_MISSING | PROFILE_MANIFEST_INVALID | PROFILE_MANIFEST_DUPLICATE_KEY |
#   PROFILE_MANIFEST_SCHEMA_UNSUPPORTED | PROFILE_MANIFEST_INCONSISTENT |
#   PROFILE_PROHIBITED_PRESENT | PROFILE_FILE_MISSING | PROFILE_FILE_UNKNOWN |
#   PROFILE_FRONTMATTER_INVALID | PROFILE_FRONTMATTER_DUPLICATE_KEY | PROFILE_NAME_MISMATCH |
#   PROFILE_MODEL_MISMATCH | PROFILE_EFFORT_MISMATCH | PROFILE_TOOLS_MISMATCH |
#   PROFILE_WRITES_MISMATCH | PROFILE_NESTING_MISMATCH | PROFILE_MAXTURNS_OUT_OF_RANGE |
#   PROFILE_VERSION_MISMATCH | PROFILE_BINDINGS_MISMATCH
# Exit 2: usage error.
#
# Fail-closed parsing: duplicate object keys in the manifest JSON (jq silently
# keeps the last, so a raw python3 parse detects them, matching the pattern in
# bin/fm-bindings-validate.sh), and in the agent frontmatter an unterminated
# block or any duplicate governed key, are all rejected before any parsed value
# is trusted - an ambiguous key is unsafe because this validator and the runtime
# loader need not resolve it to the same occurrence.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

command -v jq >/dev/null 2>&1 || { echo "fm-profile-matrix-check: jq is required" >&2; exit 2; }

die() { # die <CODE> <message>
  echo "$1" >&2
  [ -n "${2:-}" ] && echo "fm-profile-matrix-check: $2" >&2
  exit 1
}

# raw_dup_keys <json-file>: echo any duplicate object keys (any depth), one per
# line. jq keeps only the last occurrence, so a raw parse is required to see the
# ambiguity. Mirrors bin/fm-bindings-validate.sh's detection; degrades to a
# warning (no false pass) only if python3 is genuinely absent.
raw_dup_keys() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$1" <<'PYEOF'
import json, sys
dups = []
def hook(pairs):
    ks = [k for k, _ in pairs]
    for k in sorted(set(k for k in ks if ks.count(k) > 1)):
        dups.append(k)
    return dict(pairs)
try:
    json.load(open(sys.argv[1]), object_pairs_hook=hook)
except Exception as e:
    print("RAWPARSE_ERROR:%s" % e); sys.exit(4)
if dups:
    print("\n".join(dups)); sys.exit(3)
PYEOF
    return $?
  fi
  echo "fm-profile-matrix-check: warning: python3 absent - JSON duplicate-key check skipped" >&2
  return 0
}

# --- manifest load + self-consistency --------------------------------------
[ -f "$MANIFEST" ] || die PROFILE_MANIFEST_MISSING "manifest not found: $MANIFEST"
jq -e . "$MANIFEST" >/dev/null 2>&1 || die PROFILE_MANIFEST_INVALID "manifest is not valid JSON: $MANIFEST"
dupout=$(raw_dup_keys "$MANIFEST"); rc=$?
case "$rc" in
  0) : ;;
  3) die PROFILE_MANIFEST_DUPLICATE_KEY "duplicate key(s) in manifest JSON: $(echo "$dupout" | tr '\n' ' ')" ;;
  *) die PROFILE_MANIFEST_INVALID "manifest raw-parse failed: $dupout" ;;
esac

SCHEMA=$(jq -r '.schema_version // ""' "$MANIFEST")
[ "$SCHEMA" = "firstmate/governed-profiles/v1" ] || die PROFILE_MANIFEST_SCHEMA_UNSUPPORTED "unsupported schema_version: '$SCHEMA'"

# Profile names (sorted), and the prohibited-name list.
mapfile -t PROFILES < <(jq -r '.profiles | keys[]' "$MANIFEST" | sort)
[ "${#PROFILES[@]}" -gt 0 ] || die PROFILE_MANIFEST_INCONSISTENT "manifest defines no profiles"
mapfile -t PROHIBITED < <(jq -r '.prohibited_profile_names[]?' "$MANIFEST")

# Manifest self-consistency: model in models_allowed; effort legal for the tier.
for name in "${PROFILES[@]}"; do
  read -r model effort <<<"$(jq -r --arg n "$name" '.profiles[$n] | "\(.model) \(.effort // "null")"' "$MANIFEST")"
  jq -e --arg m "$model" '.models_allowed | index($m)' "$MANIFEST" >/dev/null \
    || die PROFILE_MANIFEST_INCONSISTENT "profile $name has model '$model' not in models_allowed"
  case "$model" in
    haiku)
      [ "$effort" = "null" ] || die PROFILE_MANIFEST_INCONSISTENT "haiku profile $name must have null effort" ;;
    sonnet)
      [ "$effort" = "high" ] || die PROFILE_MANIFEST_INCONSISTENT "sonnet profile $name must be fixed at high" ;;
    opus)
      [ "$effort" != "max" ] || die PROFILE_MANIFEST_INCONSISTENT "opus profile $name must not be max" ;;
    fable)
      case "$effort" in xhigh|max) die PROFILE_MANIFEST_INCONSISTENT "fable profile $name must not be $effort" ;; esac ;;
  esac
  # A prohibited name must never appear as a defined profile.
  for p in "${PROHIBITED[@]}"; do
    [ "$name" = "$p" ] && die PROFILE_MANIFEST_INCONSISTENT "prohibited name defined in manifest: $name"
  done
done

# --- frontmatter helpers ----------------------------------------------------
# frontmatter <file>: print the body of the first --- ... --- block. Fails
# closed (non-zero, no output trusted) when the file does not open with --- on
# line 1 (exit 2) or the block is never closed before EOF (exit 3). An
# unterminated block must never be accepted as valid frontmatter.
frontmatter() {
  awk '
    NR==1 && $0 !~ /^---[[:space:]]*$/ { exit 2 }
    NR==1 { next }
    /^---[[:space:]]*$/ { closed=1; exit 0 }
    { print }
    END { if (!closed) exit 3 }
  ' "$1"
}
fm_has() { # fm_has <fm-text> <key>
  printf '%s\n' "$1" | grep -Eq "^$2:[[:space:]]"
}
fm_scalar() { # fm_scalar <fm-text> <key> -> trimmed value (first match)
  printf '%s\n' "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -n1 \
    | sed 's/[[:space:]]*$//'
}
fm_list_sorted() { # fm_list_sorted <fm-text> <key> -> newline tokens, sorted
  local raw
  raw=$(fm_scalar "$1" "$2")
  raw=${raw#[}
  raw=${raw%]}
  printf '%s\n' "$raw" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | grep -v '^$' | sort
}

# --- exact agent-file set vs manifest ---------------------------------------
# Every manifest profile has a file; no extra .md files; no prohibited-name file.
for p in "${PROHIBITED[@]}"; do
  [ -e "$AGENTS_DIR/$p.md" ] && die PROFILE_PROHIBITED_PRESENT "prohibited profile file exists: $p.md"
done
if [ -d "$AGENTS_DIR" ]; then
  while IFS= read -r f; do
    stem=$(basename "$f" .md)
    found=0
    for name in "${PROFILES[@]}"; do [ "$stem" = "$name" ] && found=1 && break; done
    [ "$found" = 1 ] || die PROFILE_FILE_UNKNOWN "agent file has no manifest entry: $stem.md"
  done < <(find "$AGENTS_DIR" -maxdepth 1 -type f -name '*.md' | sort)
fi

# --- per-profile frontmatter agreement --------------------------------------
count=0
for name in "${PROFILES[@]}"; do
  file="$AGENTS_DIR/$name.md"
  [ -f "$file" ] || die PROFILE_FILE_MISSING "missing agent file for profile: $name.md"

  fm=$(frontmatter "$file") || die PROFILE_FRONTMATTER_INVALID "$name.md frontmatter is missing, malformed, or unterminated"
  [ -n "$fm" ] || die PROFILE_FRONTMATTER_INVALID "$name.md has an empty frontmatter block"

  # No governed key may appear twice: a duplicate is ambiguous, and fm_scalar
  # (first-match) and the runtime YAML loader need not resolve it identically.
  dupkeys=$(printf '%s\n' "$fm" | grep -oE '^[A-Za-z_]+:' | sort | uniq -d | tr -d ':' | tr '\n' ' ')
  [ -z "${dupkeys// /}" ] || die PROFILE_FRONTMATTER_DUPLICATE_KEY "$name.md: duplicate frontmatter key(s): $dupkeys"

  # manifest expectations
  m_model=$(jq -r --arg n "$name" '.profiles[$n].model' "$MANIFEST")
  m_effort=$(jq -r --arg n "$name" '.profiles[$n].effort // "null"' "$MANIFEST")
  m_writes=$(jq -r --arg n "$name" '.profiles[$n].writes' "$MANIFEST")
  m_nesting=$(jq -r --arg n "$name" '.profiles[$n].nesting' "$MANIFEST")
  m_min=$(jq -r --arg n "$name" '.profiles[$n].maxTurns.min' "$MANIFEST")
  m_max=$(jq -r --arg n "$name" '.profiles[$n].maxTurns.max' "$MANIFEST")
  m_ver=$(jq -r --arg n "$name" '.profiles[$n].version' "$MANIFEST")
  mapfile -t m_tools < <(jq -r --arg n "$name" '.profiles[$n].tools[]' "$MANIFEST" | sort)

  # name
  [ "$(fm_scalar "$fm" name)" = "$name" ] || die PROFILE_NAME_MISMATCH "$name.md: frontmatter name must equal '$name'"

  # model
  [ "$(fm_scalar "$fm" model)" = "$m_model" ] || die PROFILE_MODEL_MISMATCH "$name.md: model must be '$m_model'"

  # effort: haiku (null) -> key must be ABSENT; else EFFORT must equal manifest.
  if [ "$m_effort" = "null" ]; then
    fm_has "$fm" EFFORT && die PROFILE_EFFORT_MISMATCH "$name.md: haiku profile must carry no EFFORT key"
  else
    fm_has "$fm" EFFORT || die PROFILE_EFFORT_MISMATCH "$name.md: missing EFFORT key (expected '$m_effort')"
    [ "$(fm_scalar "$fm" EFFORT)" = "$m_effort" ] || die PROFILE_EFFORT_MISMATCH "$name.md: EFFORT must be '$m_effort'"
  fi

  # tools set
  mapfile -t f_tools < <(fm_list_sorted "$fm" tools)
  if [ "${m_tools[*]}" != "${f_tools[*]}" ]; then
    die PROFILE_TOOLS_MISMATCH "$name.md: tools must be [${m_tools[*]}], got [${f_tools[*]}]"
  fi

  # writes: Write and Edit present in tools iff manifest.writes == true
  has_write=0
  for t in "${f_tools[@]}"; do case "$t" in Write|Edit) has_write=1 ;; esac; done
  if [ "$m_writes" = "true" ]; then
    [ "$has_write" = 1 ] || die PROFILE_WRITES_MISMATCH "$name.md: a writing profile must list Write/Edit tools"
  else
    [ "$has_write" = 0 ] || die PROFILE_WRITES_MISMATCH "$name.md: a non-writing profile must not list Write/Edit tools"
  fi

  # nesting: Agent in tools iff manifest.nesting; disallowedTools must include
  # Agent for a non-nesting profile and must never include Agent for a nesting one.
  has_agent=0
  for t in "${f_tools[@]}"; do [ "$t" = "Agent" ] && has_agent=1; done
  mapfile -t f_disallowed < <(fm_list_sorted "$fm" disallowedTools)
  disallow_agent=0
  for t in "${f_disallowed[@]}"; do [ "$t" = "Agent" ] && disallow_agent=1; done
  if [ "$m_nesting" = "true" ]; then
    [ "$has_agent" = 1 ] || die PROFILE_NESTING_MISMATCH "$name.md: nesting profile must list the Agent tool"
    [ "$disallow_agent" = 0 ] || die PROFILE_NESTING_MISMATCH "$name.md: nesting profile must not disallow Agent"
  else
    [ "$has_agent" = 0 ] || die PROFILE_NESTING_MISMATCH "$name.md: non-nesting profile must not list the Agent tool"
    [ "$disallow_agent" = 1 ] || die PROFILE_NESTING_MISMATCH "$name.md: non-nesting profile must disallow the Agent tool"
  fi

  # maxTurns within the manifest range
  turns=$(fm_scalar "$fm" maxTurns)
  case "$turns" in
    ''|*[!0-9]*) die PROFILE_MAXTURNS_OUT_OF_RANGE "$name.md: maxTurns must be an integer, got '$turns'" ;;
  esac
  if [ "$turns" -lt "$m_min" ] || [ "$turns" -gt "$m_max" ]; then
    die PROFILE_MAXTURNS_OUT_OF_RANGE "$name.md: maxTurns $turns outside [$m_min,$m_max]"
  fi

  # profile_version
  [ "$(fm_scalar "$fm" profile_version)" = "$m_ver" ] || die PROFILE_VERSION_MISMATCH "$name.md: profile_version must be '$m_ver'"

  count=$((count + 1))
done

# --- optional SHELL-CREW bindings cross-check -------------------------------
# Runs only when a bindings file is provided and it carries at least one governed
# profile name as a top-level key. For each such entry, the bindings effort must
# equal the manifest effort (empty == null) and the bindings model string must
# contain the manifest model token. Bindings that carry only the legacy
# crew-dispatch profile names (implementer_balanced, scout_fast, ...) are a clean
# no-op here, exactly as the runtime file is today.
if [ -n "$BINDINGS" ]; then
  [ -f "$BINDINGS" ] || die PROFILE_BINDINGS_MISMATCH "bindings file not found: $BINDINGS"
  jq -e . "$BINDINGS" >/dev/null 2>&1 || die PROFILE_BINDINGS_MISMATCH "bindings file is not valid JSON: $BINDINGS"
  for name in "${PROFILES[@]}"; do
    present=$(jq -r --arg n "$name" 'has($n)' "$BINDINGS")
    [ "$present" = "true" ] || continue
    b_model=$(jq -r --arg n "$name" '.[$n].model // ""' "$BINDINGS")
    b_effort=$(jq -r --arg n "$name" '.[$n].effort // ""' "$BINDINGS")
    m_model=$(jq -r --arg n "$name" '.profiles[$n].model' "$MANIFEST")
    m_effort=$(jq -r --arg n "$name" '.profiles[$n].effort // ""' "$MANIFEST")
    [ "$b_effort" = "$m_effort" ] || die PROFILE_BINDINGS_MISMATCH "bindings $name: effort '$b_effort' != manifest '$m_effort'"
    case "$b_model" in
      *"$m_model"*) : ;;
      *) die PROFILE_BINDINGS_MISMATCH "bindings $name: model '$b_model' does not carry manifest tier '$m_model'" ;;
    esac
  done
fi

[ "$QUIET" = 1 ] || echo "PROFILES_OK=$count"
exit 0

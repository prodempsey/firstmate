#!/usr/bin/env bash
# fm-findings-attribute.sh - classify candidate findings against a base snapshot.
#
# This is the one generic baseline-attribution mechanism for Shakedown gates.
# Producers write closed-schema raw findings for the base and candidate snapshots.
# This helper fingerprints scanner identity + rule id + path + normalized
# source-line content, then labels every candidate finding candidate-new,
# inherited, or unattributed.
#
# FC-001 (closed-schema positive proof): A conclusion may be drawn only from ONE atomic pass that positively proves conformance to a single declared, closed schema; authority defaults to none and is NEVER inferred from the absence of a failing check.
# FC-002 (absence is never discharge): An obligation is cleared ONLY by positive proof from a fresh, structurally-complete, authoritative snapshot that provably enumerates that obligation's status; absent/stale/corrupt/partial coverage RETAINS the prior fact unchanged (fail-open when CREATING a block, fail-closed when DISCHARGING one).
#
# Usage:
#   fm-findings-attribute.sh --candidate <raw.jsonl> [--base <raw.jsonl>] --out <report.json>
#
# Raw finding schema firstmate/scanner-raw-finding/1 has exactly:
#   schema, scanner, rule_id, severity, path, line, message, content
#
# Report schema firstmate/scanner-attribution/1 has exactly:
#   schema, baseline, findings
set -u

usage() { sed -n '/^# Usage:/,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//;$d'; }
refuse() { printf 'fm-findings-attribute: %s\n' "$1" >&2; exit 2; }

CANDIDATE=""
BASE=""
OUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --candidate) CANDIDATE=${2:-}; shift ;;
    --base) BASE=${2:-}; shift ;;
    --out) OUT=${2:-}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) refuse "unknown argument: $1" ;;
  esac
  shift
done

for tool in jq sha256sum mktemp; do
  command -v "$tool" >/dev/null 2>&1 || refuse "required tool unavailable: $tool"
done
[ -n "$CANDIDATE" ] && [ -f "$CANDIDATE" ] || refuse "--candidate must name a readable JSONL file"
[ -n "$OUT" ] || refuse "--out is required"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-attribution.XXXXXX") || refuse "cannot create scratch directory"
trap 'rm -rf "$TMP"' EXIT

validate_raw() {
  jq -s -e '
    all(.[];
      (keys == ["content","line","message","path","rule_id","scanner","schema","severity"])
      and .schema == "firstmate/scanner-raw-finding/1"
      and (.scanner|type) == "string" and (.scanner|length) > 0
      and (.rule_id|type) == "string" and (.rule_id|length) > 0
      and (.severity == "error" or .severity == "warning" or .severity == "note")
      and (.path == null or (.path|type) == "string")
      and (.line == null or ((.line|type) == "number" and .line >= 1 and .line == (.line|floor)))
      and (.message|type) == "string" and (.message|length) > 0
      and (.content == null or (.content|type) == "string"))
  ' "$1" >/dev/null 2>&1
}

validate_raw "$CANDIDATE" || refuse "candidate findings do not conform to firstmate/scanner-raw-finding/1"

BASELINE_AVAILABLE=false
BASELINE_WARNING=null
BASE_FINGERPRINTS="$TMP/base-fingerprints.txt"
: > "$BASE_FINGERPRINTS"
if [ -n "$BASE" ] && [ -f "$BASE" ] && validate_raw "$BASE"; then
  BASELINE_AVAILABLE=true
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    printf '%s\n' "$record" |
      jq -r '[.scanner,.rule_id,.path // "",((.content // "")|gsub("[[:space:]]+";" ")|ascii_downcase)]|@tsv' |
      sha256sum | awk '{print $1}' >> "$BASE_FINGERPRINTS"
  done < "$BASE"
  sort -u -o "$BASE_FINGERPRINTS" "$BASE_FINGERPRINTS"
else
  BASELINE_WARNING='"baseline snapshot is missing or invalid; candidate findings are unattributed and remain blocking (FC-002)"'
fi

ATTRIBUTED="$TMP/attributed.jsonl"
: > "$ATTRIBUTED"
while IFS= read -r record; do
  [ -n "$record" ] || continue
  fingerprint=$(
    printf '%s\n' "$record" |
      jq -r '[.scanner,.rule_id,.path // "",((.content // "")|gsub("[[:space:]]+";" ")|ascii_downcase)]|@tsv' |
      sha256sum | awk '{print $1}'
  )
  attribution=unattributed
  if [ "$BASELINE_AVAILABLE" = true ]; then
    if grep -Fqx "$fingerprint" "$BASE_FINGERPRINTS"; then
      attribution=inherited
    else
      attribution=candidate-new
    fi
  fi
  blocking=true
  [ "$attribution" = inherited ] && blocking=false
  printf '%s\n' "$record" |
    jq -c --arg fingerprint "$fingerprint" --arg attribution "$attribution" \
      --argjson blocking "$blocking" \
      'del(.content) + {fingerprint:$fingerprint,attribution:$attribution,blocking:$blocking}' \
      >> "$ATTRIBUTED" || refuse "failed to construct attributed finding"
done < "$CANDIDATE"

BASELINE="$TMP/baseline.json"
jq -n --argjson available "$BASELINE_AVAILABLE" --argjson warning "$BASELINE_WARNING" \
  '{available:$available,warning:$warning}' > "$BASELINE" ||
  refuse "failed to construct baseline status"

REPORT="$TMP/report.json"
jq -n --slurpfile baseline "$BASELINE" --slurpfile findings "$ATTRIBUTED" '
  {
    schema:"firstmate/scanner-attribution/1",
    baseline:$baseline[0],
    findings:($findings|unique_by(.fingerprint))
  }
' > "$REPORT" || refuse "failed to assemble attribution report"

jq -e '
  keys == ["baseline","findings","schema"]
  and .schema == "firstmate/scanner-attribution/1"
  and (.baseline|keys) == ["available","warning"]
  and (.baseline.available|type) == "boolean"
  and (.baseline.warning == null or (.baseline.warning|type) == "string")
  and all(.findings[];
    (keys == ["attribution","blocking","fingerprint","line","message","path","rule_id","scanner","schema","severity"])
    and .schema == "firstmate/scanner-raw-finding/1"
    and (.attribution == "candidate-new" or .attribution == "inherited" or .attribution == "unattributed")
    and (.blocking|type) == "boolean"
    and (.fingerprint|test("^[0-9a-f]{64}$")))
' "$REPORT" >/dev/null || refuse "assembled report failed its closed-schema proof (FC-001)"

mkdir -p "$(dirname "$OUT")" || refuse "cannot create output directory"
TMP_OUT="$OUT.tmp.$$"
cp "$REPORT" "$TMP_OUT" || refuse "cannot stage output"
mv -f "$TMP_OUT" "$OUT" || { rm -f "$TMP_OUT"; refuse "cannot publish output"; }

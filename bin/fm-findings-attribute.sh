#!/usr/bin/env bash
# fm-findings-attribute.sh - classify candidate findings against a base snapshot.
#
# This is the one generic baseline-attribution mechanism for Shakedown gates.
# Producers write closed-schema raw findings for the base and candidate snapshots.
# This helper fingerprints scanner identity + rule id + path + exact source-line
# content + its ordered occurrence, then labels every candidate finding
# candidate-new, inherited, or unattributed.
#
# FC-001 (closed-schema positive proof): A conclusion may be drawn only from ONE atomic pass that positively proves conformance to a single declared, closed schema; authority defaults to none and is NEVER inferred from the absence of a failing check.
# FC-002 (absence is never discharge): An obligation is cleared ONLY by positive proof from a fresh, structurally-complete, authoritative snapshot that provably enumerates that obligation's status; absent/stale/corrupt/partial coverage RETAINS the prior fact unchanged (fail-open when CREATING a block, fail-closed when DISCHARGING one).
#
# Usage:
#   fm-findings-attribute.sh --candidate <raw.jsonl> --confirmation <raw.jsonl>
#     [--base <raw.jsonl>] [--policy <json>] --out <report.json>
#
# Raw finding schema firstmate/scanner-raw-finding/1 has exactly:
#   schema, scanner, rule_id, severity, path, line, message, content
#
# Report schema firstmate/scanner-attribution/1 has exactly:
#   schema, baseline, findings
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_POLICY="$(cd "$SCRIPT_DIR/.." && pwd)/docs/scanner/blocking-policy.json"
usage() { sed -n '/^# Usage:/,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//;$d'; }
refuse() { printf 'fm-findings-attribute: %s\n' "$1" >&2; exit 2; }

CANDIDATE=""
CONFIRMATION=""
BASE=""
POLICY="$DEFAULT_POLICY"
OUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --candidate) CANDIDATE=${2:-}; shift ;;
    --confirmation) CONFIRMATION=${2:-}; shift ;;
    --base) BASE=${2:-}; shift ;;
    --policy) POLICY=${2:-}; shift ;;
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
[ -n "$CONFIRMATION" ] && [ -f "$CONFIRMATION" ] || refuse "--confirmation must name a readable JSONL file"
[ -f "$POLICY" ] || refuse "--policy must name a readable policy file"
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
validate_raw "$CONFIRMATION" || refuse "confirmation findings do not conform to firstmate/scanner-raw-finding/1"
jq -e '
  keys == ["default","scanners","schema"]
  and .schema == "firstmate/scanner-blocking-policy/1"
  and (.default|keys) == ["blocking_severities","report_only_rule_prefixes"]
  and (.default.blocking_severities|type) == "array"
  and all(.default.blocking_severities[]; .=="error" or .=="warning" or .=="note")
  and (.default.report_only_rule_prefixes|type) == "array"
  and all(.default.report_only_rule_prefixes[]; (type=="string") and length>0)
  and (.scanners|type) == "array"
  and (([.scanners[].scanner]|length) == ([.scanners[].scanner]|unique|length))
  and all(.scanners[];
    keys == ["blocking_severities","budget_s","report_only_rule_prefixes","scanner"]
    and (.scanner|type)=="string" and (.scanner|length)>0
    and (.budget_s|type)=="number" and .budget_s>=1 and .budget_s==(.budget_s|floor)
    and (.blocking_severities|type)=="array"
    and all(.blocking_severities[]; .=="error" or .=="warning" or .=="note")
    and (.report_only_rule_prefixes|type)=="array"
    and all(.report_only_rule_prefixes[]; (type=="string") and length>0))
' "$POLICY" >/dev/null 2>&1 ||
  refuse "blocking policy does not conform to firstmate/scanner-blocking-policy/1"

prepare_records() {
  jq -s -c '
    sort_by(.scanner,.rule_id,.path // "",.content // "",.line // 0,.message)
    | unique_by([.scanner,.rule_id,.path // "",.content // "",.line,.message,.severity])
    | group_by([.scanner,.rule_id,.path // "",.content // ""])[]
    | sort_by(.line // 0)
    | to_entries[]
    | .key as $occurrence
    | .value + {occurrence:($occurrence+1)}
  ' "$1" > "$2"
}

fingerprint_records() {
  local source=$1 destination=$2 record fingerprint
  : > "$destination"
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    fingerprint=$(
      printf '%s\n' "$record" |
        jq -r '[.scanner,.rule_id,.path // "",.content // "",.occurrence]|@tsv' |
        sha256sum | awk '{print $1}'
    )
    printf '%s\n' "$record" |
      jq -c --arg fingerprint "$fingerprint" '. + {fingerprint:$fingerprint}' >> "$destination"
  done < "$source"
}

prepare_records "$CANDIDATE" "$TMP/candidate-prepared.jsonl"
prepare_records "$CONFIRMATION" "$TMP/confirmation-prepared.jsonl"
fingerprint_records "$TMP/candidate-prepared.jsonl" "$TMP/candidate-fingerprinted.jsonl"
fingerprint_records "$TMP/confirmation-prepared.jsonl" "$TMP/confirmation-fingerprinted.jsonl"

BASELINE_AVAILABLE=false
BASELINE_WARNING=null
BASE_FINGERPRINTS="$TMP/base-fingerprints.txt"
: > "$BASE_FINGERPRINTS"
if [ -n "$BASE" ] && [ -f "$BASE" ] && validate_raw "$BASE"; then
  BASELINE_AVAILABLE=true
  prepare_records "$BASE" "$TMP/base-prepared.jsonl"
  fingerprint_records "$TMP/base-prepared.jsonl" "$TMP/base-fingerprinted.jsonl"
  jq -r '.fingerprint' "$TMP/base-fingerprinted.jsonl" >> "$BASE_FINGERPRINTS"
  sort -u -o "$BASE_FINGERPRINTS" "$BASE_FINGERPRINTS"
else
  BASELINE_WARNING='"baseline snapshot is missing or invalid; all candidate findings are unattributed and none are suppressed as inherited (FC-002)"'
fi

ATTRIBUTED="$TMP/attributed.jsonl"
CONFIRMATION_FINGERPRINTS="$TMP/confirmation-fingerprints.txt"
: > "$ATTRIBUTED"
: > "$CONFIRMATION_FINGERPRINTS"
jq -r '.fingerprint' "$TMP/confirmation-fingerprinted.jsonl" |
  sort -u > "$CONFIRMATION_FINGERPRINTS"
while IFS= read -r record; do
  [ -n "$record" ] || continue
  fingerprint=$(printf '%s\n' "$record" | jq -r '.fingerprint')
  attribution=unattributed
  if [ "$BASELINE_AVAILABLE" = true ]; then
    if grep -Fqx "$fingerprint" "$BASE_FINGERPRINTS"; then
      attribution=inherited
    else
      attribution=candidate-new
    fi
  fi
  policy_eval=$(
    printf '%s\n' "$record" | jq -r --slurpfile policy "$POLICY" '
      . as $finding
      | (($policy[0].scanners[]?|select(.scanner==$finding.scanner)) // $policy[0].default) as $rule
      | if $finding.rule_id=="scanner-unavailable" then
          ["eligible","scanner-unavailable always fails closed"]
        elif any($rule.report_only_rule_prefixes[]?;
          . as $prefix | $finding.rule_id|startswith($prefix)) then
          ["report-only","rule prefix is report-only by committed policy"]
        elif any($rule.blocking_severities[]?;
          . as $severity | $severity==$finding.severity) then
          ["eligible","scanner and severity are blocking-tier by committed policy"]
        else
          ["report-only","scanner and severity are report-only by committed policy"]
        end
      | @tsv
    '
  )
  IFS=$'\t' read -r eligibility policy_reason <<< "$policy_eval"
  blocking=false
  policy_decision=report-only
  stability=not-required
  if [ "$attribution" = inherited ]; then
    policy_decision=inherited
    policy_reason="finding is present in the authoritative baseline"
  elif [ "$eligibility" = eligible ] && [ "$(printf '%s\n' "$record" | jq -r '.rule_id')" = scanner-unavailable ]; then
    blocking=true
    policy_decision=block
  elif [ "$eligibility" = eligible ] && grep -Fqx "$fingerprint" "$CONFIRMATION_FINGERPRINTS"; then
    blocking=true
    policy_decision=block
    stability=confirmed
  elif [ "$eligibility" = eligible ]; then
    stability=unconfirmed
    policy_reason="blocking-tier finding was absent from the repeat run; report-only as nondeterministic"
  fi
  printf '%s\n' "$record" |
    jq -c --arg attribution "$attribution" --arg decision "$policy_decision" \
      --arg reason "$policy_reason" --arg stability "$stability" \
      --argjson blocking "$blocking" '
        del(.content) + {
          attribution:$attribution,
          blocking:$blocking,
          policy_decision:$decision,
          policy_reason:$reason,
          stability:$stability
        }
      ' \
      >> "$ATTRIBUTED" || refuse "failed to construct attributed finding"
done < "$TMP/candidate-fingerprinted.jsonl"

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
    (keys == ["attribution","blocking","fingerprint","line","message","occurrence","path","policy_decision","policy_reason","rule_id","scanner","schema","severity","stability"])
    and .schema == "firstmate/scanner-raw-finding/1"
    and (.attribution == "candidate-new" or .attribution == "inherited" or .attribution == "unattributed")
    and (.blocking|type) == "boolean"
    and (.occurrence|type) == "number" and .occurrence>=1 and .occurrence==(.occurrence|floor)
    and (.policy_decision=="block" or .policy_decision=="report-only" or .policy_decision=="inherited")
    and (.policy_reason|type)=="string" and (.policy_reason|length)>0
    and (.stability=="confirmed" or .stability=="unconfirmed" or .stability=="not-required")
    and (.fingerprint|test("^[0-9a-f]{64}$")))
' "$REPORT" >/dev/null || refuse "assembled report failed its closed-schema proof (FC-001)"

mkdir -p "$(dirname "$OUT")" || refuse "cannot create output directory"
TMP_OUT="$OUT.tmp.$$"
cp "$REPORT" "$TMP_OUT" || refuse "cannot stage output"
mv -f "$TMP_OUT" "$OUT" || { rm -f "$TMP_OUT"; refuse "cannot publish output"; }

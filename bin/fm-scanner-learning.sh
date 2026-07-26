#!/usr/bin/env bash
# fm-scanner-learning.sh - scanner dismissal and Seasoning proposal surface.
#
# `dismiss` records one captain, firstmate, or adjudicator decision against an
# exact application-computed finding fingerprint.
# The selected finding identity is copied from a closed scanner bundle; scanner
# message text never selects or broadens the dismissal.
# Every dismissal is repository-bound, stack-version-bound, severity-bound,
# narrowly scoped, and expires at REVIEW_AFTER.
# Writes use prove-existing, stage, prove-result, atomic-rename under the shared
# portable ledger lock.
#
# `propose` requires at least three unique model-confirmed occurrences of one
# scanner/rule class across closed scanner bundles.
# It emits a validated class-defined Seasoning event to a proposal file and
# never mutates the failure-class ledger; captain approval remains the gate.
#
# Usage:
#   fm-scanner-learning.sh dismiss --bundle <scanner-report.json>
#     --fingerprint <sha256> --scope path|rule|ast
#     --review-after <YYYY-MM-DDTHH:MM:SSZ>
#     [--reason <reason-code>] [--by captain|firstmate|adjudicator]
#     [--actor <identity>] [--evidence <reference>]
#     [--path-prefix <repository-relative-prefix>]
#     [--ast-anchor <sha256>] [--repo <git-repo>] [--ledger <jsonl>]
#
#   fm-scanner-learning.sh propose --bundle <scanner-report.json>
#     [--bundle <scanner-report.json> ...] --scanner <name> --rule <rule-id>
#     --id <FC-NNN> --name <text> --invariant <text> --fix <text>
#     --cue <text> [--cue <text> ...] --out <proposal.json>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_LEDGER="$ROOT/docs/scanner/dismissals.jsonl"

# shellcheck source=bin/fm-dismissal-lib.sh
. "$SCRIPT_DIR/fm-dismissal-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

FM_SCANNER_DISMISSAL_LOCK_HELD=""
FM_SCANNER_PROPOSAL_TMP=""
cleanup() {
  if [ -n "$FM_SCANNER_DISMISSAL_LOCK_HELD" ]; then
    fm_lock_release "$FM_SCANNER_DISMISSAL_LOCK_HELD" 2>/dev/null || true
    FM_SCANNER_DISMISSAL_LOCK_HELD=""
  fi
  [ -z "$FM_SCANNER_PROPOSAL_TMP" ] || rm -rf "$FM_SCANNER_PROPOSAL_TMP"
}
trap cleanup EXIT

die() {
  echo "fm-scanner-learning: $*" >&2
  exit 1
}

usage() {
  sed -n '/^# Usage:/,/^set -eu$/p' "$0" | sed 's/^# \{0,1\}//;$d'
}

validate_bundle() {
  jq -e '
    ((.schema=="firstmate/scanner-report/3" and (.candidate_sha|test("^[0-9a-f]{40}$")))
      or .schema=="firstmate/scanner-adjudication/2")
    and (.findings|type)=="array"
    and all(.findings[];
      (keys==["adjudication","attribution","blocking","fingerprint","line","message",
              "occurrence","path","policy_decision","policy_reason","rule_id",
              "scanner","schema","severity","stability","subject"])
      and .schema=="firstmate/scanner-raw-finding/1"
      and (.fingerprint|test("^[0-9a-f]{64}$"))
      and (.scanner|type)=="string" and (.scanner|length)>0
      and (.rule_id|type)=="string" and (.rule_id|length)>0
      and (.severity=="error" or .severity=="warning" or .severity=="note")
      and (.occurrence|type)=="number" and .occurrence>=1
      and (.path==null or ((.path|type)=="string" and (.path|length)>0))
      and (.adjudication|type)=="object")
  ' "$1" >/dev/null 2>&1 ||
    die "bundle failed its closed scanner finding proof"
}

append_dismissal() {
  local ledger=$1 event=$2 lock="$1.lock" snapshot dir tmp err
  dir=$(dirname "$ledger")
  mkdir -p "$dir"
  fm_lock_acquire_wait "$lock"
  FM_SCANNER_DISMISSAL_LOCK_HELD=$lock
  if ! snapshot=$(fm_dismissal_ledger_prove "$ledger" 2>"$ledger.prove.err"); then
    rm -f "$ledger.prove.err"
    fm_lock_release "$lock"
    FM_SCANNER_DISMISSAL_LOCK_HELD=""
    die "existing dismissal ledger is unavailable or invalid; refusing to append"
  fi
  rm -f "$ledger.prove.err"
  printf '%s\n' "$snapshot" | jq -e --arg id "$(printf '%s\n' "$event" | jq -r .id)" \
    'all(.[]; .id!=$id)' >/dev/null ||
    {
      fm_lock_release "$lock"
      FM_SCANNER_DISMISSAL_LOCK_HELD=""
      die "dismissal id already exists"
    }
  tmp=$(mktemp "$ledger.wip.XXXXXX") || {
    fm_lock_release "$lock"
    FM_SCANNER_DISMISSAL_LOCK_HELD=""
    die "cannot create staged dismissal ledger"
  }
  err="$tmp.err"
  if [ -f "$ledger" ]; then
    cp "$ledger" "$tmp" || {
      rm -f "$tmp" "$err"
      fm_lock_release "$lock"
      FM_SCANNER_DISMISSAL_LOCK_HELD=""
      die "cannot stage existing dismissal ledger"
    }
  fi
  printf '%s\n' "$event" >> "$tmp" || {
    rm -f "$tmp" "$err"
    fm_lock_release "$lock"
    FM_SCANNER_DISMISSAL_LOCK_HELD=""
    die "cannot stage dismissal event"
  }
  if ! fm_dismissal_ledger_prove "$tmp" >/dev/null 2>"$err"; then
    rm -f "$tmp" "$err"
    fm_lock_release "$lock"
    FM_SCANNER_DISMISSAL_LOCK_HELD=""
    die "resulting dismissal ledger failed its closed-schema proof"
  fi
  rm -f "$err"
  mv -f "$tmp" "$ledger" || {
    rm -f "$tmp"
    fm_lock_release "$lock"
    FM_SCANNER_DISMISSAL_LOCK_HELD=""
    die "atomic dismissal-ledger publication failed"
  }
  fm_lock_release "$lock"
  FM_SCANNER_DISMISSAL_LOCK_HELD=""
}

cmd_dismiss() {
  local bundle="" fingerprint="" scope_kind="" review_after="" reason=""
  local by=captain actor="" evidence="" path_prefix="" ast_anchor=""
  local repo=. ledger="$DEFAULT_LEDGER"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --bundle) bundle=${2:-}; shift 2 ;;
      --fingerprint) fingerprint=${2:-}; shift 2 ;;
      --scope) scope_kind=${2:-}; shift 2 ;;
      --review-after) review_after=${2:-}; shift 2 ;;
      --reason) reason=${2:-}; shift 2 ;;
      --by) by=${2:-}; shift 2 ;;
      --actor) actor=${2:-}; shift 2 ;;
      --evidence) evidence=${2:-}; shift 2 ;;
      --path-prefix) path_prefix=${2:-}; shift 2 ;;
      --ast-anchor) ast_anchor=${2:-}; shift 2 ;;
      --repo) repo=${2:-}; shift 2 ;;
      --ledger) ledger=${2:-}; shift 2 ;;
      *) die "unknown dismiss flag: $1" ;;
    esac
  done
  [ -f "$bundle" ] || die "dismiss requires --bundle"
  printf '%s\n' "$fingerprint" | grep -Eq '^[0-9a-f]{64}$' ||
    die "dismiss requires an application-computed --fingerprint"
  case "$scope_kind" in path|rule|ast) ;; *) die "--scope must be path, rule, or ast" ;; esac
  [ -n "$review_after" ] || die "dismiss requires --review-after"
  case "$by" in captain|firstmate|adjudicator) ;; *) die "--by is outside the closed taxonomy" ;; esac
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die "--repo is not a git repository"
  validate_bundle "$bundle"
  local repo_head bundle_candidate
  repo_head=$(git -C "$repo" rev-parse HEAD) || die "cannot resolve repository HEAD"
  if [ "$(jq -r .schema "$bundle")" = firstmate/scanner-report/3 ]; then
    bundle_candidate=$(jq -r .candidate_sha "$bundle")
    [ "$bundle_candidate" = "$repo_head" ] ||
      die "scanner bundle candidate does not match repository HEAD"
  elif [ "$by" != adjudicator ]; then
    die "captain/firstmate dismissal requires the candidate-bound scanner report"
  fi

  local selected_count finding path scanner rule severity occurrence
  selected_count=$(jq --arg fingerprint "$fingerprint" \
    '[.findings[]|select(.fingerprint==$fingerprint)]|length' "$bundle")
  [ "$selected_count" -eq 1 ] ||
    die "fingerprint must select exactly one finding from the closed bundle"
  finding=$(jq -c --arg fingerprint "$fingerprint" \
    '.findings[]|select(.fingerprint==$fingerprint)' "$bundle")
  path=$(printf '%s\n' "$finding" | jq -r '.path // ""')
  [ -n "$path" ] || die "findings without a repository path cannot be dismissed"
  printf '%s\n' "$path" | grep -Eq '(^|/)\.\.(/|$)|^/' &&
    die "finding path is unsafe"
  scanner=$(printf '%s\n' "$finding" | jq -r .scanner)
  rule=$(printf '%s\n' "$finding" | jq -r .rule_id)
  severity=$(printf '%s\n' "$finding" | jq -r .severity)
  occurrence=$(printf '%s\n' "$finding" | jq -r .occurrence)

  local scope
  case "$scope_kind" in
    path)
      scope=$(jq -nc --arg path "$path" '{kind:"path",path:$path}')
      ;;
    rule)
      [ "$scanner" != gitleaks ] ||
        die "secrets-class dismissals require exact path scope"
      [ -n "$path_prefix" ] || die "rule scope requires a non-global --path-prefix"
      case "$path_prefix" in /*|.|./|\*|\*\*|\*/|\*\*/) die "unsafe or global path prefix" ;; esac
      printf '%s\n' "$path_prefix" | grep -Eq '(^|/)\.\.(/|$)' &&
        die "unsafe or global path prefix"
      case "$path" in "$path_prefix"*) ;; *) die "path prefix does not contain the selected finding" ;; esac
      scope=$(jq -nc --arg path_prefix "$path_prefix" \
        '{kind:"rule",path_prefix:$path_prefix}')
      ;;
    ast)
      printf '%s\n' "$ast_anchor" | grep -Eq '^[0-9a-f]{64}$' ||
        die "AST scope requires --ast-anchor"
      scope=$(jq -nc --arg path "$path" --arg anchor "$ast_anchor" \
        '{kind:"ast",path:$path,anchor_sha256:$anchor}')
      ;;
  esac

  local model proof created repository_id stack_fingerprint evidence_ref
  if [ "$by" = adjudicator ]; then
    printf '%s\n' "$finding" | jq -e '
      .adjudication.verdict=="demote-to-report"
      and (.adjudication.reason_code|type)=="string"
      and (.adjudication.corroboration.proof_id|test("^[0-9a-f]{64}$"))
    ' >/dev/null ||
      die "adjudicator dismissal requires a corroborated demote-to-report finding"
    [ "$(printf '%s\n' "$finding" | jq -r \
      .adjudication.corroboration.candidate_sha)" = "$repo_head" ] ||
      die "adjudicator proof is not bound to repository HEAD"
    reason=$(printf '%s\n' "$finding" | jq -r .adjudication.reason_code)
    model=$(jq -r '
      if .schema=="firstmate/scanner-report/3" then .adjudication.model
      else .model end
    ' "$bundle")
    proof=$(printf '%s\n' "$finding" | jq -r .adjudication.corroboration.proof_id)
    actor=${actor:-$model}
    evidence_ref=${evidence:-"adjudication:$proof"}
  else
    [ -n "$reason" ] || die "captain/firstmate dismissal requires --reason"
    actor=${actor:-$by}
    evidence_ref=${evidence:-"$by-decision:$fingerprint"}
  fi
  created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  repository_id=$(fm_scanner_repository_id "$repo" HEAD) ||
    die "cannot compute repository identity"
  stack_fingerprint=$(fm_scanner_stack_fingerprint "$ROOT") ||
    die "cannot compute scanner-stack identity"

  local draft id event
  draft=$(jq -nc --arg repository_id "$repository_id" \
    --arg finding_fingerprint "$fingerprint" --arg stack "$stack_fingerprint" \
    --arg scanner "$scanner" --arg rule "$rule" --arg severity "$severity" \
    --arg occurrence "$occurrence" --argjson scope "$scope" --arg reason "$reason" \
    --arg by "$by" --arg actor "$actor" --arg evidence "$evidence_ref" \
    --arg created "$created" --arg review_after "$review_after" '{
      schema:"firstmate/scanner-dismissal-event/1",
      repository_id:$repository_id,
      finding_fingerprint:$finding_fingerprint,
      fingerprint_algorithm:"firstmate/scanner-fingerprint/2",
      stack_fingerprint:$stack,
      scanner:$scanner,
      rule_id:$rule,
      severity:$severity,
      occurrence:($occurrence|tonumber),
      scope:$scope,
      reason_code:$reason,
      dismissed_by:{kind:$by,actor:$actor},
      evidence_ref:$evidence,
      created_at:$created,
      review_after:$review_after
    }')
  id="DS-$(printf '%s\n' "$draft" | jq -cS . | sha256sum | awk '{print substr($1,1,32)}')"
  event=$(printf '%s\n' "$draft" | jq -c --arg id "$id" '. + {id:$id}')
  append_dismissal "$ledger" "$event"
  printf '%s\n' "$event" | jq .
}

cmd_propose() {
  local bundles=() scanner="" rule="" id="" name="" invariant="" fix="" out=""
  local cues=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --bundle) bundles+=("${2:-}"); shift 2 ;;
      --scanner) scanner=${2:-}; shift 2 ;;
      --rule) rule=${2:-}; shift 2 ;;
      --id) id=${2:-}; shift 2 ;;
      --name) name=${2:-}; shift 2 ;;
      --invariant) invariant=${2:-}; shift 2 ;;
      --fix) fix=${2:-}; shift 2 ;;
      --cue) cues+=("${2:-}"); shift 2 ;;
      --out) out=${2:-}; shift 2 ;;
      *) die "unknown propose flag: $1" ;;
    esac
  done
  [ "${#bundles[@]}" -gt 0 ] || die "propose requires at least one --bundle"
  [ -n "$scanner" ] && [ -n "$rule" ] && [ -n "$id" ] && [ -n "$name" ] &&
    [ -n "$invariant" ] && [ -n "$fix" ] && [ -n "$out" ] ||
    die "propose requires scanner, rule, id, name, invariant, fix, and out"
  [ "${#cues[@]}" -gt 0 ] || die "propose requires at least one --cue"

  local tmp rows bundle digest count args=()
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-seasoning-proposal.XXXXXX")
  FM_SCANNER_PROPOSAL_TMP=$tmp
  rows="$tmp/confirmed.jsonl"
  : > "$rows"
  for bundle in "${bundles[@]}"; do
    validate_bundle "$bundle"
    digest=$(sha256sum "$bundle" | awk '{print $1}')
    jq -c --arg scanner "$scanner" --arg rule "$rule" --arg digest "$digest" '
      .findings[]
      | select(.scanner==$scanner and .rule_id==$rule
          and .adjudication.verdict=="confirm")
      | {fingerprint,bundle_sha256:$digest}
    ' "$bundle" >> "$rows"
  done
  count=$(jq -s '[unique_by(.fingerprint)[]]|length' "$rows")
  [ "$count" -ge 3 ] ||
    die "Seasoning proposal requires at least three unique confirmed findings (found $count)"
  args=(add --id "$id" --name "$name" --invariant "$invariant" --fix "$fix")
  for bundle in "${cues[@]}"; do
    args+=(--cue "$bundle")
  done
  while IFS=$'\t' read -r digest fingerprint; do
    args+=(--provenance "scanner-confirmation:$digest:$fingerprint")
  done < <(jq -rs 'unique_by(.fingerprint)[]|[.bundle_sha256,.fingerprint]|@tsv' "$rows")
  : > "$tmp/ledger.jsonl"
  FM_FC_LEDGER="$tmp/ledger.jsonl" "$SCRIPT_DIR/fm-failure-class.sh" "${args[@]}" >/dev/null
  mkdir -p "$(dirname "$out")"
  cp "$tmp/ledger.jsonl" "$out.tmp.$$"
  mv -f "$out.tmp.$$" "$out"
  printf 'SEASONING_PROPOSAL_READY=%s confirmations=%s output=%s\n' "$id" "$count" "$out"
}

case "${1:-}" in
  dismiss) shift; cmd_dismiss "$@" ;;
  propose) shift; cmd_propose "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac

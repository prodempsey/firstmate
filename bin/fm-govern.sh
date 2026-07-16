#!/usr/bin/env bash
# fm-govern.sh - the CLI front end for the governance controls. Thin dispatcher over
# bin/fm-governance-lib.sh; the library owns every rule, this script only parses
# subcommands and prints results. See fm-governance-lib.sh for the model.
#
# Subcommands:
#   classify      <scope-text> [path ...]                 -> "governed <0|1> <rules>"
#   delivery-check --mode M [--target ...] [--pr N] ...   -> validate a delivery mode
#   record init   <task> <mode> <repoPath> <ident> <branch> <base> <head> <scopeCsv> <governed>
#   record freeze <task> <sha>
#   record attest <task> <review|qa|captain-auth> <sha> <verdict|ref>
#   record observe <task> [--head SHA] [--base SHA] [--branch B] [--mode M] [--repo-identity I] [--scope CSV]
#   record get    <task> <jq-path>
#   auth-valid    <task> <current-head>                   -> exit 0 valid, 1 invalid
#   status|doctor <task>                                  -> attestation status report
#   preqa-gate    --task T --tree-clean 0|1 --no-mutating-process 0|1 [--tests-recorded 0|1]
#   local-gate    --task T --repo R --base S --candidate S ...
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-governance-lib.sh
. "$SCRIPT_DIR/fm-governance-lib.sh"

cmd=${1:-}
[ -n "$cmd" ] || { echo "usage: fm-govern.sh <classify|delivery-check|record|auth-valid|status|sync-head|preqa-gate|local-gate> ..." >&2; exit 2; }
shift || true

case "$cmd" in
  classify)
    scope=${1:-}; shift || true
    out=$(fm_gov_classify "$scope" "$@")
    governed=${out%%$'\t'*}; rules=${out#*$'\t'}
    echo "governed=$governed rules=$rules"
    [ "$governed" = 1 ] && exit 0 || exit 0
    ;;

  delivery-check)
    if fm_gov_delivery_validate "$@"; then
      echo "delivery-check: OK"
      exit 0
    else
      echo "delivery-check: REFUSED (see conflicts above)" >&2
      exit 1
    fi
    ;;

  record)
    sub=${1:-}; shift || true
    case "$sub" in
      init)    fm_gov_record_init "$@" && echo "record: initialized $1" ;;
      freeze)  fm_gov_record_freeze "$@" && echo "record: frozen $1 at $2" ;;
      attest)  fm_gov_record_attest "$@" && echo "record: attested $2 for $1 at $3" ;;
      observe) fm_gov_record_observe "$@" && echo "record: observed head for $1" ;;
      get)     fm_gov_record_get "$@" ;;
      *) echo "usage: fm-govern.sh record <init|freeze|attest|observe|get> ..." >&2; exit 2 ;;
    esac
    ;;

  auth-valid)
    task=${1:?task}; head=${2:?current-head}
    if fm_gov_auth_valid "$task" "$head"; then
      echo "auth-valid: YES (head $head is Captain-authorized)"
      exit 0
    else
      echo "auth-valid: NO (head $head is not currently authorized)"
      exit 1
    fi
    ;;

  sync-head)
    task=${1:?task}
    fm_gov_sync_head "$task" && echo "sync-head: $task now at $(fm_gov_record_get "$task" headSha)"
    ;;

  status|doctor)
    task=${1:?task}
    fm_gov_require_jq || exit 2
    path=$(fm_gov_record_path "$task")
    [ -f "$path" ] || { echo "error: no governance record for $task" >&2; exit 1; }
    # Re-derive the live branch head first so the doctor view never reports a moved
    # head as still authorized (independent-review finding: invalidation must not
    # depend on an external caller having run `observe`).
    fm_gov_sync_head "$task" || true
    head=$(jq -r '.headSha // "<none>"' "$path")
    frozen=$(jq -r '.frozen.sha // "<none>"' "$path")
    review=$(jq -r '.review.sha // "<none>"' "$path")
    rv=$(jq -r '.review.verdict // "<none>"' "$path")
    qa=$(jq -r '.qa.sha // "<none>"' "$path")
    qv=$(jq -r '.qa.verdict // "<none>"' "$path")
    auth=$(jq -r '.captainAuth.sha // "<none>"' "$path")
    inv=$(jq -r '.invalidation.reason // ""' "$path")
    mode=$(jq -r '.deliveryMode // "<none>"' "$path")
    landing=$(jq -r '.landingReady' "$path")
    valid=no
    fm_gov_auth_valid "$task" "$head" >/dev/null 2>&1 && valid=yes
    echo "governance status: $task"
    echo "  deliveryMode:      $mode"
    echo "  currentHead:       $head"
    echo "  frozenCandidate:   $frozen"
    echo "  reviewedSha:       $review ($rv)"
    echo "  attestedSha (QA):  $qa ($qv)"
    echo "  authorizedSha:     $auth"
    echo "  authorizationValid:$valid"
    echo "  landingReady:      $landing"
    if [ -n "$inv" ]; then
      echo "  invalidationReason:$inv"
    else
      echo "  invalidationReason:<none>"
    fi
    ;;

  preqa-gate)
    if fm_gov_preqa_ready "$@"; then
      echo "preqa-gate: READY (final QA may dispatch)"
      exit 0
    else
      echo "preqa-gate: BLOCKED (see reason above)" >&2
      exit 1
    fi
    ;;

  local-gate)
    if fm_gov_local_gate_ready "$@"; then
      echo "local-gate: READY (local-only landing may proceed)"
      exit 0
    else
      echo "local-gate: BLOCKED (see reason above)" >&2
      exit 1
    fi
    ;;

  *)
    echo "error: unknown command '$cmd'" >&2
    exit 2
    ;;
esac

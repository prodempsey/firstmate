#!/usr/bin/env bash
# fm-hold.sh - durable scoped governance holds (Scope E of the Memory PR-1 incident
# prevention controls).
#
# A hold is a durable, on-disk block that survives FirstMate restart, watcher
# restart, session restart, backlog drain, task reconciliation, and respawn
# processing, because it lives in state/holds/ as a file - not in memory, not in the
# backlog, not in a watcher variable. While a hold is active, the enforcement points
# (dispatch, respawn, governed branch mutation, merge/landing, PR update, follow-on
# milestone dispatch, evidence-destroying cleanup) call `fm-hold.sh check` and refuse
# when it reports a match. Read-only inspection and explicitly-authorized
# incident-recovery work are never blocked - they simply do not call check, or pass
# --recovery.
#
# A hold is scoped by exactly one dimension: project | milestone | task | branch.
# `check` is queried with any subset of those dimensions and matches a hold when the
# hold's dimension/value equals the corresponding query value. Releasing a hold
# REQUIRES an --authorization reference and appends an audit record; there is no
# silent release.
#
# Usage:
#   fm-hold.sh add --kind <project|milestone|task|branch> --value <v> --reason <r>
#   fm-hold.sh list [--json]
#   fm-hold.sh check [--project P] [--milestone M] [--task T] [--branch B] [--recovery]
#   fm-hold.sh release --kind K --value V --authorization <ref> [--reason <r>]
# Exit: check -> 0 clear, 3 held, 2 error; others -> 0 ok, 1/2 error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
HOLDS="$STATE/holds"
AUDIT="$HOLDS/audit.log"
# shellcheck source=bin/fm-role-context-lib.sh
. "$SCRIPT_DIR/fm-role-context-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "error: jq not found; holds cannot be read or written" >&2; exit 2; }

now() { printf '%s' "${FM_GOV_NOW:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"; }

# Deterministic filename for a (kind,value) hold: a readable slug plus a short hash
# of the EXACT kind+value, so distinct values that slug identically (e.g. branch
# fm/x vs fm-x) never collide onto one file and silently overwrite each other.
# check/release resolve the same (kind,value) through this function, so it stays
# deterministic; check additionally reads .value from every file, so enforcement
# never depends on the filename.
hold_file() {  # <kind> <value>
  local slug hash
  slug=$(printf '%s-%s' "$1" "$2" | tr -c 'A-Za-z0-9._-' '-' | sed 's/-\{2,\}/-/g;s/^-//;s/-$//')
  hash=$(printf '%s\0%s' "$1" "$2" | sha256sum | cut -c1-8)
  printf '%s/%s-%s.json' "$HOLDS" "$slug" "$hash"
}

audit() {  # <event> <detail>
  mkdir -p "$HOLDS" 2>/dev/null || true
  printf '%s\t%s\t%s\n' "$(now)" "$1" "$2" >> "$AUDIT" 2>/dev/null || true
}

valid_kind() { case "$1" in project|milestone|task|branch) return 0 ;; *) return 1 ;; esac; }

cmd=${1:-}
[ -n "$cmd" ] || { echo "usage: fm-hold.sh <add|list|check|release> ..." >&2; exit 2; }
shift || true

# add/release mutate durable holds and are primary-only; list/check are read-only and
# stay available to crewmates (a crewmate may inspect whether it is under a hold).
case "$cmd" in
  add|release) fm_require_primary "fm-hold.sh $cmd" || exit 2 ;;
esac

case "$cmd" in
  add)
    kind='' value='' reason=''
    while [ $# -gt 0 ]; do
      case "$1" in
        --kind) kind=$2; shift 2 ;;
        --value) value=$2; shift 2 ;;
        --reason) reason=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    valid_kind "$kind" || { echo "error: --kind must be project|milestone|task|branch" >&2; exit 2; }
    [ -n "$value" ] || { echo "error: --value required" >&2; exit 2; }
    [ -n "$reason" ] || { echo "error: --reason required" >&2; exit 2; }
    mkdir -p "$HOLDS"
    f=$(hold_file "$kind" "$value")
    jq -n --arg k "$kind" --arg v "$value" --arg r "$reason" --arg n "$(now)" \
      '{schemaVersion:"fm-hold/v1", kind:$k, value:$v, reason:$r, active:true, createdAt:$n, releasedAt:null, authorization:null}' > "$f"
    audit add "$kind=$value reason=$reason"
    echo "held $kind=$value ($reason)"
    ;;

  list)
    json=0
    [ "${1:-}" = --json ] && json=1
    if [ ! -d "$HOLDS" ]; then
      [ "$json" = 1 ] && echo '[]' || echo "no holds"
      exit 0
    fi
    if [ "$json" = 1 ]; then
      jq -s '[.[] | select(.active==true)]' "$HOLDS"/*.json 2>/dev/null || echo '[]'
    else
      found=0
      for f in "$HOLDS"/*.json; do
        [ -e "$f" ] || continue
        active=$(jq -r '.active' "$f")
        [ "$active" = true ] || continue
        found=1
        printf 'HELD  %-10s %-28s %s\n' "$(jq -r .kind "$f")" "$(jq -r .value "$f")" "$(jq -r .reason "$f")"
      done
      [ "$found" = 1 ] || echo "no active holds"
    fi
    ;;

  check)
    q_project='' q_milestone='' q_task='' q_branch='' recovery=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --project) q_project=$2; shift 2 ;;
        --milestone) q_milestone=$2; shift 2 ;;
        --task) q_task=$2; shift 2 ;;
        --branch) q_branch=$2; shift 2 ;;
        --recovery) recovery=1; shift ;;
        *) shift ;;
      esac
    done
    # Explicitly-authorized incident-recovery work is never blocked.
    if [ "$recovery" = 1 ]; then
      exit 0
    fi
    [ -d "$HOLDS" ] || exit 0
    matched=0
    for f in "$HOLDS"/*.json; do
      [ -e "$f" ] || continue
      active=$(jq -r '.active' "$f")
      [ "$active" = true ] || continue
      k=$(jq -r '.kind' "$f"); v=$(jq -r '.value' "$f"); r=$(jq -r '.reason' "$f")
      hit=0
      case "$k" in
        project)   [ -n "$q_project" ] && [ "$q_project" = "$v" ] && hit=1 ;;
        milestone) [ -n "$q_milestone" ] && [ "$q_milestone" = "$v" ] && hit=1 ;;
        task)      [ -n "$q_task" ] && [ "$q_task" = "$v" ] && hit=1 ;;
        branch)    [ -n "$q_branch" ] && [ "$q_branch" = "$v" ] && hit=1 ;;
      esac
      if [ "$hit" = 1 ]; then
        matched=1
        echo "HELD: $k=$v - $r" >&2
      fi
    done
    [ "$matched" = 0 ] && exit 0
    exit 3
    ;;

  release)
    kind='' value='' authz='' reason=''
    while [ $# -gt 0 ]; do
      case "$1" in
        --kind) kind=$2; shift 2 ;;
        --value) value=$2; shift 2 ;;
        --authorization) authz=$2; shift 2 ;;
        --reason) reason=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    valid_kind "$kind" || { echo "error: --kind must be project|milestone|task|branch" >&2; exit 2; }
    [ -n "$value" ] || { echo "error: --value required" >&2; exit 2; }
    # A release without an authorization reference is refused - there is no silent release.
    [ -n "$authz" ] || { echo "error: release refused: --authorization <ref> is required to release a hold" >&2; exit 1; }
    f=$(hold_file "$kind" "$value")
    [ -f "$f" ] || { echo "error: no hold for $kind=$value" >&2; exit 1; }
    jq --arg n "$(now)" --arg a "$authz" --arg r "$reason" \
      '.active=false | .releasedAt=$n | .authorization=$a | .releaseReason=$r' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    audit release "$kind=$value authorization=$authz reason=$reason"
    echo "released $kind=$value (authorization $authz)"
    ;;

  *)
    echo "error: unknown command '$cmd'" >&2
    exit 2
    ;;
esac

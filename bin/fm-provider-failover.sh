#!/usr/bin/env bash
# Read and manage the provider failover circuit breaker shared by crew profile
# resolution and FirstMate console boot selection.
#
# Runtime state lives at state/provider-failover.json (or
# $FM_PROVIDER_FAILOVER_FILE). The file is optional. Missing entries are
# enabled. An entry disables its provider or harness only when disabled=true
# and its optional RFC 3339 `until` time is still in the future. Expired entries
# are treated as enabled without rewriting the file.
#
# Usage:
#   fm-provider-failover.sh list
#   fm-provider-failover.sh disable provider|harness <name> [--reason <text>] [--until <RFC3339>]
#   fm-provider-failover.sh enable provider|harness <name>
#
# When sourced, fm_failover_candidate_reason <harness> [provider] prints an
# unavailable reason and returns 0, returns 1 when the candidate is available,
# and returns 2 for invalid failover state. Availability requires the harness
# command in PATH and closed harness/provider circuits.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_FAILOVER_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_FAILOVER_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_FAILOVER_ROOT}}"
FM_FAILOVER_STATE="${FM_STATE_OVERRIDE:-$FM_FAILOVER_HOME/state}"
FM_FAILOVER_FILE="${FM_PROVIDER_FAILOVER_FILE:-$FM_FAILOVER_STATE/provider-failover.json}"

fm_failover_die() {
  echo "fm-provider-failover: $*" >&2
  return 2
}

fm_failover_now_epoch() {
  if [ -n "${FM_FAILOVER_NOW_EPOCH:-}" ]; then
    printf '%s\n' "$FM_FAILOVER_NOW_EPOCH"
  else
    date -u +%s
  fi
}

# fm_failover_disabled provider|harness <name>
# Prints the configured reason and returns 0 when disabled, 1 when enabled, or
# 2 when the state file or an active `until` timestamp is invalid.
fm_failover_disabled() {
  local kind=${1:-} name=${2:-} section entry disabled until until_epoch now reason
  case "$kind" in
    provider) section=providers ;;
    harness) section=harnesses ;;
    *) fm_failover_die "kind must be provider or harness"; return 2 ;;
  esac

  [ -f "$FM_FAILOVER_FILE" ] || return 1
  command -v jq >/dev/null 2>&1 || {
    fm_failover_die "jq is required to read $FM_FAILOVER_FILE"
    return 2
  }
  jq -e . "$FM_FAILOVER_FILE" >/dev/null 2>&1 || {
    fm_failover_die "invalid JSON in $FM_FAILOVER_FILE"
    return 2
  }

  entry=$(jq -c --arg section "$section" --arg name "$name" \
    '.[$section][$name] // empty | objects' "$FM_FAILOVER_FILE")
  [ -n "$entry" ] || return 1
  disabled=$(printf '%s\n' "$entry" | jq -r '.disabled == true')
  [ "$disabled" = true ] || return 1

  until=$(printf '%s\n' "$entry" | jq -r '.until // empty')
  if [ -n "$until" ]; then
    if ! until_epoch=$(date -u -d "$until" +%s 2>/dev/null); then
      fm_failover_die "invalid until timestamp for $kind '$name': $until"
      return 2
    fi
    now=$(fm_failover_now_epoch)
    if [ "$until_epoch" -le "$now" ]; then
      return 1
    fi
  fi

  reason=$(printf '%s\n' "$entry" | jq -r '.reason // "disabled"' | tr '\r\n' '  ')
  printf '%s\n' "$reason"
  return 0
}

fm_failover_candidate_reason() {
  local harness=${1:-} provider=${2:-} reason rc
  if [ -z "$harness" ]; then
    echo "candidate has no harness"
    return 0
  fi
  if ! command -v "$harness" >/dev/null 2>&1; then
    echo "harness command '$harness' not found"
    return 0
  fi

  reason=$(fm_failover_disabled harness "$harness")
  rc=$?
  case "$rc" in
    0) echo "harness '$harness' disabled: $reason"; return 0 ;;
    1) ;;
    *) return 2 ;;
  esac

  if [ -n "$provider" ]; then
    reason=$(fm_failover_disabled provider "$provider")
    rc=$?
    case "$rc" in
      0) echo "provider '$provider' disabled: $reason"; return 0 ;;
      1) ;;
      *) return 2 ;;
    esac
  fi
  return 1
}

fm_failover_usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
}

fm_failover_empty_state() {
  printf '%s\n' '{"version":1,"providers":{},"harnesses":{}}'
}

fm_failover_write() {
  local content=$1 tmp
  mkdir -p "$(dirname "$FM_FAILOVER_FILE")"
  tmp=$(mktemp "${FM_FAILOVER_FILE}.tmp.XXXXXX")
  printf '%s\n' "$content" > "$tmp"
  mv "$tmp" "$FM_FAILOVER_FILE"
}

fm_failover_main() {
  local action=${1:-} kind=${2:-} name=${3:-} section reason='' until='' state updated
  case "$action" in
    -h|--help|'') fm_failover_usage; return 0 ;;
    list)
      if [ -f "$FM_FAILOVER_FILE" ]; then
        jq . "$FM_FAILOVER_FILE"
      else
        fm_failover_empty_state | jq .
      fi
      return
      ;;
    enable|disable) ;;
    *) echo "error: unknown action '$action'" >&2; fm_failover_usage >&2; return 1 ;;
  esac
  case "$kind" in
    provider) section=providers ;;
    harness) section=harnesses ;;
    *) echo "error: kind must be provider or harness" >&2; return 1 ;;
  esac
  [ -n "$name" ] || { echo "error: $action requires a name" >&2; return 1; }
  shift 3

  if [ "$action" = enable ]; then
    [ "$#" -eq 0 ] || { echo "error: enable accepts no extra flags" >&2; return 1; }
  else
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --reason) [ "$#" -ge 2 ] || { echo "error: --reason requires a value" >&2; return 1; }; reason=$2; shift 2 ;;
        --reason=*) reason=${1#--reason=}; shift ;;
        --until) [ "$#" -ge 2 ] || { echo "error: --until requires a value" >&2; return 1; }; until=$2; shift 2 ;;
        --until=*) until=${1#--until=}; shift ;;
        *) echo "error: unknown flag '$1'" >&2; return 1 ;;
      esac
    done
    if [ -n "$until" ] && ! date -u -d "$until" +%s >/dev/null 2>&1; then
      echo "error: invalid --until timestamp '$until'" >&2
      return 1
    fi
  fi

  command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; return 1; }
  if [ -f "$FM_FAILOVER_FILE" ]; then
    jq -e . "$FM_FAILOVER_FILE" >/dev/null 2>&1 || {
      echo "error: invalid JSON in $FM_FAILOVER_FILE" >&2
      return 1
    }
    state=$(cat "$FM_FAILOVER_FILE")
  else
    state=$(fm_failover_empty_state)
  fi

  if [ "$action" = enable ]; then
    updated=$(printf '%s\n' "$state" | jq --arg section "$section" --arg name "$name" \
      'del(.[$section][$name]) | .version = 1 | .providers //= {} | .harnesses //= {}')
  else
    updated=$(printf '%s\n' "$state" | jq --arg section "$section" --arg name "$name" \
      --arg reason "$reason" --arg until "$until" \
      '.version = 1 | .providers //= {} | .harnesses //= {} |
       .[$section][$name] = ({disabled:true}
         + (if $reason == "" then {} else {reason:$reason} end)
         + (if $until == "" then {} else {until:$until} end))')
  fi
  fm_failover_write "$updated" || return 1
  printf '%s %s %s\n' "$action" "$kind" "$name"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_failover_main "$@"
fi

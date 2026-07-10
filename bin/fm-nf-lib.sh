#!/usr/bin/env bash
# Shared local-state classifier and fingerprint helpers for the Needs FirstMate
# reconciler and acknowledgement command.

_FM_NF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091 # Dynamic sibling path is resolved from BASH_SOURCE.
. "$_FM_NF_LIB_DIR/fm-classify-lib.sh"
# shellcheck disable=SC1091 # Dynamic sibling path is resolved from BASH_SOURCE.
. "$_FM_NF_LIB_DIR/fm-backend.sh"

# Print the terminal status verb represented by a status line.
fm_nf_signal_verb() {  # <status-line>
  local line=$1
  case "$line" in
    done:*) printf 'done' ;;
    blocked:*) printf 'blocked' ;;
    failed:*) printf 'failed' ;;
    needs-decision:*) printf 'needs-decision' ;;
    *) return 1 ;;
  esac
}

# Print a portable fingerprint of the complete terminal signal line.
fm_nf_signal_fingerprint() {  # <status-line>
  local line=$1
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$line" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$line" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$line" | cksum | awk '{print "cksum-" $1 "-" $2}'
  fi
}

# Print the current terminal signal fingerprint for one local task.
# A task is eligible only when both meta and status exist, the last non-blank
# status line has an owned terminal verb, and it is not a persistent secondmate.
fm_nf_current_fingerprint() {  # <state-dir> <task-id>
  local state=$1 id=$2 meta status line kind
  meta="$state/$id.meta"
  status="$state/$id.status"
  [ -f "$meta" ] && [ -f "$status" ] || return 1
  kind=$(fm_meta_get "$meta" kind)
  [ "$kind" != secondmate ] || return 1
  line=$(last_status_line "$status")
  fm_nf_signal_verb "$line" >/dev/null || return 1
  fm_nf_signal_fingerprint "$line"
}

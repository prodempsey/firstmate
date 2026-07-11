#!/usr/bin/env bash
# Shared identity, evidence-version, fold, and lock helpers for the fleet-triage
# enumerator (fm-fleet-triage.sh) and its single sanctioned writer
# (fm-fleet-triage-record.sh).
#
# THE LEDGER
# The processing ledger is an append-only JSONL event log at data/fleet-triage.jsonl
# holding firstmate/fleet-triage-item/v1 records. It tracks PROCESSING AND LINEAGE
# ONLY. It is never a source of truth for bugs, tasks, backlog, or code state; those
# stay with their own sanctioned writers (the bug CLI, tasks-axi, the runtime scripts).
#
# Folding follows Fleet Bridge's proven captain-open-item ledger semantics: the latest
# event per item_id wins for state, descriptive fields accumulate so a bare claim keeps
# the surfaced evidence, and a malformed line is skipped rather than fatal.
#
# WHY EVIDENCE VERSION IS NOT A HASH OF THE WHOLE ITEM
# Fingerprinting prose (a report body, a backlog title) mints a new logical item on
# every trivial wording edit, which is how a triage queue silently churns. The evidence
# version therefore hashes only the STRUCTURED extracted fields named per lane in
# fm_triage_evidence_version. Titles and report bodies are deliberately excluded.

_FM_TRIAGE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${_FM_TRIAGE_LIB_DIR:?}"

# Print a portable sha256 of stdin.
fm_triage_hash() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    cksum | awk '{print "cksum-" $1 "-" $2}'
  fi
}

# Print the current UTC timestamp in ISO-8601.
fm_triage_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Print epoch seconds for an ISO-8601 timestamp, or nothing when unparseable.
fm_triage_epoch() {  # <iso-8601>
  local ts=$1
  [ -n "$ts" ] || return 1
  date -u -d "$ts" +%s 2>/dev/null && return 0
  date -u -jf %Y-%m-%dT%H:%M:%SZ "$ts" +%s 2>/dev/null && return 0
  return 1
}

# Print the stable logical identity of a triage item.
# Identity is (lane, source id) so the same evidence keeps one item across scans even
# when its wording, its classification, or its evidence version changes.
fm_triage_item_id() {  # <lane> <source-id>
  printf '%s:%s' "$1" "$2"
}

# Print the evidence version for one enumerated candidate read as JSON on stdin.
# Only structured fields participate, per lane. A prose edit must not change this.
fm_triage_evidence_version() {
  jq -cS '
    {lane, source_id: .id}
    + (if .lane == "needs_firstmate" then {signal: .source_fingerprint}
       elif .lane == "bugs" then {status}
       elif .lane == "scout_reports" then {report: .source}
       elif .lane == "backlog_hygiene" then {status, blocked_by: (.blocked_by // null)}
       elif .lane == "visibility_history" then {status}
       else {status} end)
  ' | fm_triage_hash
}

# Print the ledger path for a home.
fm_triage_ledger_path() {  # <data-dir>
  printf '%s/fleet-triage.jsonl' "$1"
}

# Fold the append-only ledger into current per-item state, as a JSON object keyed by
# item_id. Malformed lines are skipped, never fatal. Missing ledger folds to {}.
#
# The latest event wins per key and descriptive fields accumulate, so a bare claim keeps
# the evidence stamped by the earlier surface. An event carries only the keys it means
# to set, so an explicit null IS the update: `release` sets owner and claimed_at to null
# to clear a claim, and must not be filtered out as if it were an absent field.
fm_triage_fold() {  # <ledger-path>
  local ledger=$1
  [ -f "$ledger" ] || { printf '{}\n'; return 0; }
  jq -Rn '
    reduce inputs as $line ({};
      ($line | try fromjson catch null) as $e
      | if ($e | type) != "object" or ($e.item_id // "") == "" then .
        else .[$e.item_id] = ((.[$e.item_id] // {}) + $e)
        end)
  ' "$ledger"
}

# Print the lineage requirement for a terminal outcome type, or nothing when the
# outcome is unknown. This is the one owner of the terminal-requires-lineage contract.
#   link   - outcome_link must name the successor, resolution, or batch
#   reason - outcome_reason must record why
#   hold   - both a reason and a review_after condition
fm_triage_outcome_requires() {  # <outcome-type>
  case "$1" in
    successor_created|resolved|captain_batch) printf 'link' ;;
    rejected) printf 'reason' ;;
    held) printf 'hold' ;;
    *) return 1 ;;
  esac
}

# True when the fleet-triage kill switch is engaged.
# In enumerate_only mode the system may inspect, classify, and report, but must not
# apply actions or mutate any domain system or the processing ledger.
fm_triage_enumerate_only() {
  [ "${FLEET_TRIAGE_MODE:-}" = enumerate_only ]
}

# Print the current triage mode.
fm_triage_mode() {
  printf '%s' "${FLEET_TRIAGE_MODE:-active}"
}

# True when this session owns the per-home firstmate session lock.
# The lock file holds the harness PID (see bin/fm-lock.sh). This session owns it only
# when that PID is in our own process ancestry, which is what distinguishes the locked
# primary from any other live session sharing the home.
fm_triage_owns_lock() {  # <state-dir>
  local state=$1 lock holder pid
  lock="$state/.lock"
  [ -f "$lock" ] || return 1
  holder=$(cat "$lock" 2>/dev/null) || return 1
  case "$holder" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$holder" 2>/dev/null || return 1
  pid=$$
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    [ "$pid" = "$holder" ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

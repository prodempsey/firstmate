#!/usr/bin/env bash
# fm-cue-lib.sh - the ONE authority on whether a failure-class detection ("cue") row is
# valid. Both the sanctioned writer (bin/fm-failure-class.sh: add/ensure/amend/validate)
# and the live reader (bin/fm-verify.sh's cue lint) consume ONLY rows that pass
# fm_validate_cue_row, so no path ever writes, folds, or EXECUTES a cue row that has not
# been proven - in ONE atomic pass - to:
#   (a) parse as a JSON object,
#   (b) conform to the CLOSED detection schema (additionalProperties:false): its key set is
#       EXACTLY {engine, pattern, cue_ref} - any undeclared key is a failure - with engine in
#       the supported set, a non-empty STRING pattern, and a non-empty STRING cue_ref,
#   (c) actually COMPILE under the engine that will execute it.
# Any failure is a single fail-closed verdict, never a silently-skipped row or an
# empty-hit-stream pass (FC-001 closed-schema positive proof; the me-s3-profiles and
# dj-orders design rulings: prove conformance in ONE pass, never spot-check piecemeal).
#
# This file is a sourced library: it defines a constant and functions and runs nothing.

# The CLOSED set of supported detection engines (space-separated). awk-ere is the only
# engine bin/fm-verify.sh can execute, so it is the only engine a valid cue row may name.
FM_CUE_ENGINES="awk-ere"

# fm_cue_pattern_compiles <engine> <pattern>: 0 iff <pattern> compiles under <engine>.
# For awk-ere the pattern is probed with `grep -E` against EMPTY input (/dev/null): a valid
# ERE exits 0 or 1 (match / no match - and empty input can never match, so we only ever
# exercise the COMPILE, never a match), while a syntactically invalid ERE exits >=2 with a
# diagnostic. An unknown engine never compiles.
fm_cue_pattern_compiles() {
  local engine=$1 pattern=$2 rc
  case "$engine" in
    awk-ere)
      grep -E -e "$pattern" /dev/null >/dev/null 2>&1
      rc=$?
      [ "$rc" -lt 2 ]
      ;;
    *) return 1 ;;
  esac
}

# fm_validate_cue_row <row-json>: 0 iff the single detection row is a JSON object that
# conforms to the closed schema AND whose pattern compiles under its engine. On failure it
# prints a one-line reason to stderr and returns 1. This is the ONLY gate: callers MUST
# refuse (write path) or fail closed with a finding (read path) on a non-zero return, and
# MUST never consult, fold, or execute a row that has not returned 0 here.
fm_validate_cue_row() {
  local row=$1 reason engine pattern
  # (a) JSON object + (b) closed schema, proven in one jq pass. A row that is not valid JSON
  # at all makes jq exit non-zero, which is itself a fail-closed verdict.
  reason=$(printf '%s' "$row" | jq -r --arg engines "$FM_CUE_ENGINES" '
    . as $d | ($engines | split(" ")) as $ok
    | (["cue_ref","engine","pattern"]) as $allowed
    | if ($d|type) != "object" then "not a JSON object"
      elif (($d|keys) - $allowed) != []
        then "undeclared propert\(if ((($d|keys) - $allowed)|length) > 1 then "ies" else "y" end): "
             + ((($d|keys) - $allowed)|join(", ")) + " (allowed exactly: \($allowed|join(", ")))"
      elif ($d.engine|type) != "string" or (($ok | index($d.engine)) | not)
        then "unsupported engine \($d.engine|tojson) (supported: \($ok|join(",")))"
      elif ($d.pattern|type) != "string" or ($d.pattern|length) == 0 then "empty or non-string pattern"
      elif ($d.cue_ref|type) != "string" or ($d.cue_ref|length) == 0 then "empty or missing cue_ref"
      else "OK" end' 2>/dev/null) \
    || { echo "detection row is not valid JSON" >&2; return 1; }
  [ "$reason" = OK ] || { echo "detection row invalid: $reason" >&2; return 1; }
  # (c) the pattern must actually COMPILE under the engine that will execute it.
  engine=$(printf '%s' "$row" | jq -r '.engine')
  pattern=$(printf '%s' "$row" | jq -r '.pattern')
  fm_cue_pattern_compiles "$engine" "$pattern" \
    || { echo "detection pattern does not compile under $engine: $pattern" >&2; return 1; }
  return 0
}

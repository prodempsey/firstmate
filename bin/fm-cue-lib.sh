#!/usr/bin/env bash
# fm-cue-lib.sh - the ONE shared read entrypoint every cue-ledger consumer proves validity through.
#
# Per the binding ruling (data/seasoning-cues-g1/design-ruling.md), validation is NOT a per-row
# shell/jq predicate: it is a single atomic fail-closed pass over the RAW ledger bytes, owned by
# bin/fm-cue-validate.sh (python3 + jsonschema, HARD prerequisites; duplicate-member rejection via
# object_pairs_hook because jq collapses duplicates before any check runs). This library is the thin
# shell seam that every consumer - the sanctioned writer (add/ensure/amend/bump/register/validate/
# list/show/refinements) and the live reader (bin/fm-verify.sh's cue_lint) - calls. No consumer
# re-parses the ledger; all receive ONLY the proven, folded snapshot this entrypoint returns.
#
# fm_cue_ledger_prove <ledger-path>: on success prints the proven folded snapshot (a JSON array, one
# record per class id) to stdout and returns 0. On failure prints exactly one marker + reason
# (CUE_VALIDATOR_UNAVAILABLE | CUE_LEDGER_MISSING | CUE_LEDGER_INVALID) to stderr and returns
# non-zero. There is no degradation and no valid-empty for a MISSING file; an empty-but-present
# ledger returns "[]" with status 0.

FM_CUE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The authority is bound UNCONDITIONALLY to THIS repo's validator, resolved by the library's own
# directory (the real bin/) - no ambient environment variable can substitute a weaker, permissive,
# or success-always authority for it, and no FM_ROOT_OVERRIDE can redirect it. The ONLY test
# injection is the refusal-only, FIXTURE-GATED sandbox-marker seam inside the validator (a marker
# file the fixture creates in the validated ledger's own directory), which can force a refusal but
# never a false pass and cannot be engaged by any ambient variable. There is no override of this path.
_FM_CUE_VALIDATOR="$FM_CUE_LIB_DIR/fm-cue-validate.sh"

fm_cue_ledger_prove() { # <ledger-path>
  "$_FM_CUE_VALIDATOR" prove "$1"
}

# fm_cue_check_raw_row <raw-detection-json>: prove a SINGLE raw detection-row string valid through the
# same authority, on its RAW bytes, BEFORE any jq shaping can collapse a duplicate member. Returns 0
# if valid; on failure the marker + reason are already on stderr and it returns non-zero. The writer
# calls this on each raw --detection argument so a duplicate-key row can never be jq-normalized into a
# valid-looking one and written.
fm_cue_check_raw_row() { # <raw-detection-json>
  local tmp rc
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-cue-row.XXXXXX") || return 1
  printf '%s' "$1" > "$tmp"
  "$_FM_CUE_VALIDATOR" check-row "$tmp"; rc=$?
  rm -f "$tmp"
  return "$rc"
}

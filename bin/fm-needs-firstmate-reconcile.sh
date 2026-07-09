#!/usr/bin/env bash
# fm-needs-firstmate-reconcile.sh - read-only enumerator of FirstMate-owned
# unfinished closeouts (the Needs FirstMate inbox).
#
# Terminal crews with meta still present are incomplete closeout work, not idle
# "done" tasks. This script discovers and classifies them so firstmate can act
# (when policy allows) or package a captain-facing batch before silent
# supervision. It does NOT land, merge, teardown, clear seen-markers, or mutate
# fleet state.
#
# Classification rules and the captain package template live in the
# needs-firstmate-inbox skill; this header owns the CLI and schema only.
#
# Usage:
#   fm-needs-firstmate-reconcile.sh [--digest | --json | --id <task>]
#                                   [--serving <path>]
#                                   [--max-age-warn-hours N]
#
# Flags:
#   (default) / --digest   Human table for session-start / chat prep
#   --json                 Stable machine schema (fm-needs-firstmate-reconcile/v1)
#   --id <task>            Single-task detail (wake path); empty success if not open NF
#   --serving <path>       Override serving worktree for containment checks
#                          (default: env FM_SERVING_WORKTREE; absent = skip)
#   --max-age-warn-hours N Digest-only age highlight threshold (default 24)
#
# Inputs (cheap → expensive):
#   1. state/*.meta + last non-blank state/*.status line (via fm-classify-lib.sh)
#   2. Meta fields: kind, mode, yolo, project, worktree, pr, pr_head, window
#   3. Optional data/backlog.md keywords (SUPERSEDED / HOLD / fold / quiet-window)
#   4. Optional serving git containment when FM_SERVING_WORKTREE or --serving is
#      a git dir (merge-base --is-ancestor tip HEAD)
#
# Exit codes:
#   0  Successful report (including empty queue)
#   2  Usage error
#   1  Hard failure (STATE unreadable)
#
# Does not call Bridge APIs. Board labels are never required.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

MODE=digest
ID_FILTER=""
SERVING_PATH="${FM_SERVING_WORKTREE:-}"
MAX_AGE_WARN_HOURS=24
DIGEST_CAP=30

usage() {
  cat <<'EOF'
usage: fm-needs-firstmate-reconcile.sh [--digest | --json | --id <task>]
                                       [--serving <path>]
                                       [--max-age-warn-hours N]

Read-only Needs FirstMate inbox enumerator.
Does not land, merge, teardown, or clear seen-markers.
Exit 0 on successful empty or non-empty report.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --digest)
      MODE=digest
      shift
      ;;
    --json)
      MODE=json
      shift
      ;;
    --id)
      [ $# -ge 2 ] || { usage >&2; exit 2; }
      ID_FILTER=$2
      shift 2
      ;;
    --serving)
      [ $# -ge 2 ] || { usage >&2; exit 2; }
      SERVING_PATH=$2
      shift 2
      ;;
    --max-age-warn-hours)
      [ $# -ge 2 ] || { usage >&2; exit 2; }
      MAX_AGE_WARN_HOURS=$2
      shift 2
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

case "$MAX_AGE_WARN_HOURS" in
  ''|*[!0-9.]*) MAX_AGE_WARN_HOURS=24 ;;
esac

if [ ! -d "$STATE" ]; then
  printf 'fm-needs-firstmate-reconcile: STATE not a directory: %s\n' "$STATE" >&2
  exit 1
fi

# --- helpers ----------------------------------------------------------------

json_escape() {
  # Escape a string for JSON double-quoted content (no surrounding quotes).
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

json_str() {
  printf '"%s"' "$(json_escape "$1")"
}

json_null_or_str() {
  if [ -z "${1:-}" ]; then
    printf 'null'
  else
    json_str "$1"
  fi
}

json_bool() {
  if [ "${1:-0}" = 1 ] || [ "${1:-}" = true ]; then
    printf 'true'
  else
    printf 'false'
  fi
}

file_mtime_epoch() {
  local f=$1
  if [ ! -e "$f" ]; then
    printf '0'
    return 0
  fi
  if stat -c %Y "$f" >/dev/null 2>&1; then
    stat -c %Y "$f"
  elif stat -f %m "$f" >/dev/null 2>&1; then
    stat -f %m "$f"
  else
    printf '0'
  fi
}

age_hours_of() {
  local f=$1 now mtime
  now=$(date +%s)
  mtime=$(file_mtime_epoch "$f")
  if [ "$mtime" = 0 ]; then
    printf '0.0'
    return 0
  fi
  awk -v n="$now" -v m="$mtime" 'BEGIN {
    d = n - m
    if (d < 0) d = 0
    printf "%.1f", d / 3600
  }'
}

meta_get() {
  fm_meta_get "$1" "$2"
}

extract_tip() {
  local line=$1 tip=""
  # Prefer explicit " @ <sha> " marker from done lines.
  tip=$(printf '%s' "$line" | sed -n 's/.*@ \([0-9a-fA-F]\{7,40\}\).*/\1/p' | head -1)
  printf '%s' "$tip"
}

extract_branch_hint() {
  local line=$1 branch=""
  branch=$(printf '%s' "$line" | sed -n 's/.*ready in branch \([^[:space:]]*\).*/\1/p' | head -1)
  if [ -z "$branch" ]; then
    branch=$(printf '%s' "$line" | sed -n 's/.*branch \([^[:space:]]*\).*/\1/p' | head -1)
  fi
  printf '%s' "$branch"
}

extract_pr_url() {
  local line=$1 url=""
  url=$(printf '%s' "$line" | grep -oE 'https://github\.com/[^[:space:]]+' | head -1 || true)
  printf '%s' "$url"
}

backlog_notes_for() {
  local id=$1 backlog="$DATA/backlog.md"
  [ -f "$backlog" ] || return 0
  # Lines that mention the id (loose match on word-ish boundaries).
  grep -F -- "$id" "$backlog" 2>/dev/null || true
}

notes_match_keyword() {
  local notes=$1
  shift
  local kw
  for kw in "$@"; do
    printf '%s' "$notes" | grep -qiE "$kw" && return 0
  done
  return 1
}

serving_is_git() {
  [ -n "$SERVING_PATH" ] && [ -d "$SERVING_PATH" ] && git -C "$SERVING_PATH" rev-parse --git-dir >/dev/null 2>&1
}

serving_head() {
  if serving_is_git; then
    git -C "$SERVING_PATH" rev-parse --short HEAD 2>/dev/null || true
  fi
}

tip_is_ancestor_of_serving() {
  local tip=$1
  [ -n "$tip" ] || return 1
  serving_is_git || return 1
  # Full or short sha; git accepts both for is-ancestor when unambiguous.
  git -C "$SERVING_PATH" merge-base --is-ancestor "$tip" HEAD 2>/dev/null
}

# Resolve a tip from status, worktree HEAD, or branch hint against common dir.
resolve_tip() {
  local status_last=$1 worktree=$2 branch_hint=$3 tip=""
  tip=$(extract_tip "$status_last")
  if [ -n "$tip" ]; then
    printf '%s' "$tip"
    return 0
  fi
  if [ -n "$worktree" ] && [ -d "$worktree" ] && git -C "$worktree" rev-parse --git-dir >/dev/null 2>&1; then
    tip=$(git -C "$worktree" rev-parse --short HEAD 2>/dev/null || true)
    if [ -n "$tip" ]; then
      printf '%s' "$tip"
      return 0
    fi
  fi
  if [ -n "$branch_hint" ] && serving_is_git; then
    tip=$(git -C "$SERVING_PATH" rev-parse --short "$branch_hint" 2>/dev/null || true)
    if [ -n "$tip" ]; then
      printf '%s' "$tip"
      return 0
    fi
  fi
  printf ''
}

# Classify one terminal task. Prints fields as key=value lines to stdout.
# Uses only status last line + meta + optional backlog/serving.
classify_item() {
  local id=$1 meta=$2 status_file=$3
  local kind mode yolo project worktree pr pr_head window
  local status_last tip branch_hint pr_url age_hours
  local notes class captain_gate=1 gate_reason="" allowed_now="" forbidden_now=""
  local suggested_batch="" notes_out="" endpoint="unknown"
  local line_lc

  kind=$(meta_get "$meta" kind)
  mode=$(meta_get "$meta" mode)
  yolo=$(meta_get "$meta" yolo)
  project=$(meta_get "$meta" project)
  worktree=$(meta_get "$meta" worktree)
  pr=$(meta_get "$meta" pr)
  pr_head=$(meta_get "$meta" pr_head)
  window=$(meta_get "$meta" window)

  [ -n "$kind" ] || kind=ship
  [ -n "$mode" ] || mode=no-mistakes
  [ -n "$yolo" ] || yolo=off

  # Secondmates are persistent supervisors, not closeout inbox items.
  if [ "$kind" = secondmate ]; then
    return 1
  fi

  status_last=$(last_status_line "$status_file")
  status_is_captain_relevant "$status_last" || return 1

  branch_hint=$(extract_branch_hint "$status_last")
  tip=$(resolve_tip "$status_last" "$worktree" "$branch_hint")
  pr_url=$(extract_pr_url "$status_last")
  [ -n "$pr_url" ] || pr_url=$pr
  age_hours=$(age_hours_of "$status_file")
  notes=$(backlog_notes_for "$id")
  notes=$(printf '%s\n%s' "$notes" "$status_last")
  line_lc=$(printf '%s' "$status_last" | tr '[:upper:]' '[:lower:]')

  if [ -n "$window" ]; then
    endpoint="unknown"
  fi

  # Classification priority (first match wins).
  if printf '%s' "$line_lc" | grep -q 'needs-decision:'; then
    class=needs_decision
    captain_gate=1
    gate_reason="needs-decision requires captain choice"
    allowed_now="relay_options package_batch"
    forbidden_now="merge teardown_force"
  elif printf '%s' "$line_lc" | grep -q 'blocked:'; then
    class=blocked
    captain_gate=0
    gate_reason="blocked: triage or steer first"
    allowed_now="triage steer package_batch"
    forbidden_now="merge teardown_force"
  elif printf '%s' "$line_lc" | grep -q 'failed:'; then
    class=failed
    captain_gate=0
    gate_reason="failed: report evidence; may need captain"
    allowed_now="report_evidence package_batch"
    forbidden_now="merge"
  elif notes_match_keyword "$notes" 'SUPERSEDED|superseded by|replaced by'; then
    class=superseded
    captain_gate=1
    gate_reason="superseded: clearout may need captain if force"
    allowed_now="package_clearout review_diff"
    forbidden_now="merge land"
    notes_out="superseded per backlog/status"
  elif notes_match_keyword "$notes" '\bHOLD\b|quiet.?window|fold into|hold_fold|do not land'; then
    class=hold_fold
    captain_gate=1
    gate_reason="hold/fold: needs quiet window or captain fold approval"
    allowed_now="package_batch schedule"
    forbidden_now="merge land teardown_force"
    notes_out="hold/fold per backlog/status"
  elif [ "$kind" = scout ] && printf '%s' "$line_lc" | grep -q 'done:'; then
    class=scout_report
    captain_gate=0
    gate_reason="scout report: relay findings then teardown (no land)"
    allowed_now="read_report relay_summary teardown"
    forbidden_now="merge land"
    if [ -f "$DATA/$id/report.md" ]; then
      notes_out="report present: data/$id/report.md"
    else
      notes_out="report missing: data/$id/report.md"
      captain_gate=1
      gate_reason="scout done but report file missing"
    fi
  elif [ -n "$tip" ] && tip_is_ancestor_of_serving "$tip"; then
    class=already_live
    captain_gate=1
    gate_reason="tip already in serving HEAD; clearout may need force if unlanded default"
    allowed_now="package_clearout review_diff"
    forbidden_now="merge land"
    notes_out="tip ancestor of serving HEAD"
  elif printf '%s' "$line_lc" | grep -qE 'checks green|pr ready'; then
    class=pr_ready
    if [ "$yolo" = on ]; then
      captain_gate=0
      gate_reason="yolo=on: firstmate may merge green PR (not red)"
      allowed_now="fm_pr_check fm_pr_merge package_batch"
      forbidden_now="merge_red teardown_force"
    else
      captain_gate=1
      gate_reason="PR merge requires captain approval (yolo=off)"
      allowed_now="fm_pr_check package_batch relay_summary"
      forbidden_now="merge teardown_force"
    fi
    suggested_batch="pr-ready"
  elif [ -n "$pr_url" ] || printf '%s' "$line_lc" | grep -qE 'done: pr |https://github\.com/.*/pull/'; then
    # Open PR mentioned but not checks-green.
    if printf '%s' "$line_lc" | grep -qE 'checks green'; then
      class=pr_ready
    else
      class=pr_open_unchecked
      captain_gate=0
      gate_reason="PR open but checks not green; do not land"
      allowed_now="wait report_red package_batch"
      forbidden_now="merge land"
    fi
  elif printf '%s' "$line_lc" | grep -q 'ready in branch' || {
       [ "$mode" = "local-only" ] && printf '%s' "$line_lc" | grep -q 'done:'
     }; then
    if serving_is_git; then
      class=ready_to_land_serving
      suggested_batch="serving-land"
      if [ "$yolo" = on ]; then
        captain_gate=0
        gate_reason="yolo=on: serving land allowed after review (still escalate destructive)"
        allowed_now="review_diff package_batch serving_ff_land"
        forbidden_now="teardown_force"
      else
        captain_gate=1
        gate_reason="local-only/serving merge requires captain approval (yolo=off)"
        allowed_now="review_diff package_batch relay_summary"
        forbidden_now="merge land teardown_force"
      fi
    else
      class=ready_to_land_local
      suggested_batch="local-land"
      if [ "$yolo" = on ]; then
        captain_gate=0
        gate_reason="yolo=on: fm-merge-local allowed after review"
        allowed_now="review_diff package_batch fm_merge_local"
        forbidden_now="teardown_force"
      else
        captain_gate=1
        gate_reason="local-only merge requires captain approval (yolo=off)"
        allowed_now="review_diff package_batch relay_summary"
        forbidden_now="merge land teardown_force"
      fi
    fi
  elif printf '%s' "$line_lc" | grep -q 'done:'; then
    # done without more specific shape
    if [ "$kind" = scout ]; then
      class=scout_report
      captain_gate=0
      allowed_now="read_report relay_summary teardown"
      forbidden_now="merge land"
      gate_reason="scout done"
    elif [ -n "$pr_url" ]; then
      class=pr_open_unchecked
      captain_gate=0
      allowed_now="wait package_batch"
      forbidden_now="merge"
      gate_reason="done with PR URL but not checks-green"
    else
      class=unclassifiable
      captain_gate=1
      allowed_now="peek package_batch"
      forbidden_now="merge teardown_force"
      gate_reason="terminal done: rules missed; peek and escalate"
    fi
  else
    class=unclassifiable
    captain_gate=1
    allowed_now="peek package_batch"
    forbidden_now="merge teardown_force"
    gate_reason="terminal but unclassifiable"
  fi

  printf 'id=%s\n' "$id"
  printf 'class=%s\n' "$class"
  printf 'kind=%s\n' "$kind"
  printf 'mode=%s\n' "$mode"
  printf 'yolo=%s\n' "$yolo"
  printf 'project=%s\n' "$project"
  printf 'worktree=%s\n' "$worktree"
  printf 'status_last=%s\n' "$status_last"
  printf 'tip=%s\n' "$tip"
  printf 'branch_hint=%s\n' "$branch_hint"
  printf 'pr_url=%s\n' "$pr_url"
  printf 'pr_head=%s\n' "$pr_head"
  printf 'age_hours=%s\n' "$age_hours"
  printf 'endpoint=%s\n' "$endpoint"
  printf 'captain_gate=%s\n' "$captain_gate"
  printf 'gate_reason=%s\n' "$gate_reason"
  printf 'allowed_now=%s\n' "$allowed_now"
  printf 'forbidden_now=%s\n' "$forbidden_now"
  printf 'suggested_batch=%s\n' "$suggested_batch"
  printf 'notes=%s\n' "$notes_out"
  return 0
}

# --- collect items ----------------------------------------------------------

ITEM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-nf-reconcile.XXXXXX")
# shellcheck disable=SC2317,SC2329 # Invoked by trap handlers below.
cleanup() { rm -rf "$ITEM_DIR"; }
trap cleanup EXIT

ITEM_IDS=()
TOTAL=0
COUNT_GATED=0
COUNT_SELF=0
COUNT_HOLD=0

consider_meta() {
  local meta=$1 id status_file out
  id=$(basename "$meta" .meta)
  if [ -n "$ID_FILTER" ] && [ "$id" != "$ID_FILTER" ]; then
    return 0
  fi
  status_file="$STATE/$id.status"
  out=$(classify_item "$id" "$meta" "$status_file") || return 0
  TOTAL=$((TOTAL + 1))
  ITEM_IDS+=("$id")
  printf '%s\n' "$out" > "$ITEM_DIR/$id.fields"
  # Count buckets from class/captain_gate.
  local class gate
  class=$(printf '%s\n' "$out" | sed -n 's/^class=//p' | head -1)
  gate=$(printf '%s\n' "$out" | sed -n 's/^captain_gate=//p' | head -1)
  case "$class" in
    hold_fold)
      COUNT_HOLD=$((COUNT_HOLD + 1))
      ;;
    *)
      if [ "$gate" = 1 ]; then
        COUNT_GATED=$((COUNT_GATED + 1))
      else
        COUNT_SELF=$((COUNT_SELF + 1))
      fi
      ;;
  esac
}

if [ -n "$ID_FILTER" ]; then
  if [ -f "$STATE/$ID_FILTER.meta" ]; then
    consider_meta "$STATE/$ID_FILTER.meta"
  fi
else
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    consider_meta "$meta"
  done
fi

# Stable id order for output (lexicographic).
if [ "${#ITEM_IDS[@]}" -gt 0 ]; then
  # shellcheck disable=SC2207
  ITEM_IDS=($(printf '%s\n' "${ITEM_IDS[@]}" | LC_ALL=C sort))
fi

field_of() {
  local id=$1 key=$2
  sed -n "s/^${key}=//p" "$ITEM_DIR/$id.fields" 2>/dev/null | head -1
}

gate_label() {
  local class=$1
  case "$class" in
    ready_to_land_local|ready_to_land_serving) printf 'land' ;;
    pr_ready) printf 'merge' ;;
    pr_open_unchecked) printf 'wait-checks' ;;
    scout_report) printf 'relay' ;;
    needs_decision) printf 'decision' ;;
    blocked) printf 'triage' ;;
    failed) printf 'evidence' ;;
    already_live) printf 'clear' ;;
    superseded) printf 'clear' ;;
    hold_fold) printf 'fold' ;;
    *) printf 'inspect' ;;
  esac
}

# --- emit -------------------------------------------------------------------

SERVING_HEAD=$(serving_head)
GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)

if [ "$MODE" = json ]; then
  printf '{\n'
  printf '  "schema": "fm-needs-firstmate-reconcile/v1",\n'
  printf '  "generated_at": %s,\n' "$(json_str "$GENERATED_AT")"
  printf '  "fm_home": %s,\n' "$(json_str "$FM_HOME")"
  printf '  "serving": { "path": %s, "head": %s },\n' \
    "$(json_null_or_str "$SERVING_PATH")" \
    "$(json_null_or_str "$SERVING_HEAD")"
  printf '  "counts": { "total": %s, "captain_gated": %s, "actionable_now": %s, "holds": %s },\n' \
    "$TOTAL" "$COUNT_GATED" "$COUNT_SELF" "$COUNT_HOLD"
  printf '  "items": ['
  first=1
  for id in "${ITEM_IDS[@]:-}"; do
    [ -n "$id" ] || continue
    if [ "$first" -eq 1 ]; then
      first=0
      printf '\n'
    else
      printf ',\n'
    fi
    class=$(field_of "$id" class)
    kind=$(field_of "$id" kind)
    mode=$(field_of "$id" mode)
    yolo=$(field_of "$id" yolo)
    project=$(field_of "$id" project)
    status_last=$(field_of "$id" status_last)
    tip=$(field_of "$id" tip)
    branch_hint=$(field_of "$id" branch_hint)
    age_hours=$(field_of "$id" age_hours)
    endpoint=$(field_of "$id" endpoint)
    captain_gate=$(field_of "$id" captain_gate)
    gate_reason=$(field_of "$id" gate_reason)
    allowed_now=$(field_of "$id" allowed_now)
    forbidden_now=$(field_of "$id" forbidden_now)
    suggested_batch=$(field_of "$id" suggested_batch)
    notes=$(field_of "$id" notes)
    printf '    {\n'
    printf '      "id": %s,\n' "$(json_str "$id")"
    printf '      "class": %s,\n' "$(json_str "$class")"
    printf '      "kind": %s,\n' "$(json_str "$kind")"
    printf '      "mode": %s,\n' "$(json_str "$mode")"
    printf '      "yolo": %s,\n' "$(json_str "$yolo")"
    printf '      "project": %s,\n' "$(json_null_or_str "$project")"
    printf '      "status_last": %s,\n' "$(json_str "$status_last")"
    printf '      "tip": %s,\n' "$(json_null_or_str "$tip")"
    printf '      "branch_hint": %s,\n' "$(json_null_or_str "$branch_hint")"
    printf '      "age_hours": %s,\n' "$age_hours"
    printf '      "endpoint": %s,\n' "$(json_str "$endpoint")"
    printf '      "captain_gate": %s,\n' "$(json_bool "$captain_gate")"
    printf '      "gate_reason": %s,\n' "$(json_str "$gate_reason")"
    # allowed_now / forbidden_now as JSON arrays of tokens
    printf '      "allowed_now": ['
    af=1
    for tok in $allowed_now; do
      [ "$af" -eq 1 ] || printf ', '
      printf '%s' "$(json_str "$tok")"
      af=0
    done
    printf '],\n'
    printf '      "forbidden_now": ['
    af=1
    for tok in $forbidden_now; do
      [ "$af" -eq 1 ] || printf ', '
      printf '%s' "$(json_str "$tok")"
      af=0
    done
    printf '],\n'
    printf '      "suggested_batch": %s,\n' "$(json_null_or_str "$suggested_batch")"
    printf '      "notes": ['
    if [ -n "$notes" ]; then
      printf '%s' "$(json_str "$notes")"
    fi
    printf '],\n'
    printf '      "board_hint": null\n'
    printf '    }'
  done
  if [ "$TOTAL" -gt 0 ]; then
    printf '\n  '
  fi
  printf '],\n'

  # Simple batches: group by suggested_batch when present.
  printf '  "batches": ['
  # Collect unique batch ids
  batch_ids=""
  for id in "${ITEM_IDS[@]:-}"; do
    [ -n "$id" ] || continue
    b=$(field_of "$id" suggested_batch)
    [ -n "$b" ] || continue
    case " $batch_ids " in
      *" $b "*) ;;
      *) batch_ids="$batch_ids $b" ;;
    esac
  done
  bf=1
  for b in $batch_ids; do
    ids_in=""
    for id in "${ITEM_IDS[@]:-}"; do
      [ "$(field_of "$id" suggested_batch)" = "$b" ] || continue
      ids_in="$ids_in $id"
    done
    ids_in=${ids_in# }
    [ -n "$ids_in" ] || continue
    if [ "$bf" -eq 1 ]; then
      bf=0
      printf '\n'
    else
      printf ',\n'
    fi
    title=$b
    case "$b" in
      serving-land) title="Ready-to-land (serving)" ;;
      local-land) title="Ready-to-land (local-only)" ;;
      pr-ready) title="PR ready to merge" ;;
    esac
    printf '    {\n'
    printf '      "id": %s,\n' "$(json_str "$b")"
    printf '      "title": %s,\n' "$(json_str "$title")"
    printf '      "item_ids": ['
    iff=1
    for id in $ids_in; do
      [ "$iff" -eq 1 ] || printf ', '
      printf '%s' "$(json_str "$id")"
      iff=0
    done
    printf '],\n'
    printf '      "captain_prompt": %s\n' \
      "$(json_str "Approve closeout for batch $b ($(echo "$ids_in" | wc -w | tr -d ' ') items)?")"
    printf '    }'
  done
  if [ "$bf" -eq 0 ]; then
    printf '\n  '
  fi
  printf ']\n'
  printf '}\n'
  exit 0
fi

# Digest mode
if [ "$TOTAL" -eq 0 ]; then
  if [ -n "$ID_FILTER" ]; then
    printf 'NEEDS_FIRSTMATE: none (id=%s not an open NF item)\n' "$ID_FILTER"
  else
    printf 'NEEDS_FIRSTMATE: none\n'
  fi
  exit 0
fi

printf 'NEEDS_FIRSTMATE: %s open (%s captain-gated, %s self-act, %s hold)\n' \
  "$TOTAL" "$COUNT_GATED" "$COUNT_SELF" "$COUNT_HOLD"

line_n=0
for id in "${ITEM_IDS[@]:-}"; do
  [ -n "$id" ] || continue
  line_n=$((line_n + 1))
  if [ "$line_n" -gt "$DIGEST_CAP" ]; then
    printf '  … %s more (use --json for full set)\n' "$((TOTAL - DIGEST_CAP))"
    break
  fi
  class=$(field_of "$id" class)
  yolo=$(field_of "$id" yolo)
  tip=$(field_of "$id" tip)
  age_hours=$(field_of "$id" age_hours)
  gate=$(field_of "$id" captain_gate)
  glabel=$(gate_label "$class")
  age_mark=""
  # shellcheck disable=SC2072
  if awk -v a="$age_hours" -v w="$MAX_AGE_WARN_HOURS" 'BEGIN { exit !(a + 0 >= w + 0) }'; then
    age_mark="!"
  fi
  tip_part=""
  [ -n "$tip" ] && tip_part=" tip=$tip"
  printf '  [%-22s] %-28s yolo=%-3s%s age=%sh%s  GATE: %s\n' \
    "$class" "$id" "$yolo" "$tip_part" "$age_hours" "$age_mark" "$glabel"
done

# Batch summary lines (token-bounded)
batch_ids=""
for id in "${ITEM_IDS[@]:-}"; do
  b=$(field_of "$id" suggested_batch)
  [ -n "$b" ] || continue
  case " $batch_ids " in
    *" $b "*) ;;
    *) batch_ids="$batch_ids $b" ;;
  esac
done
for b in $batch_ids; do
  ids_in=""
  for id in "${ITEM_IDS[@]:-}"; do
    [ "$(field_of "$id" suggested_batch)" = "$b" ] || continue
    ids_in="$ids_in $id"
  done
  ids_in=${ids_in# }
  [ -n "$ids_in" ] || continue
  printf 'BATCH %s: %s\n' "$b" "$ids_in"
done

exit 0

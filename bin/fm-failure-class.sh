#!/usr/bin/env bash
# The failure-class ledger: a durable, append-only catalogue of the RECURRING
# failure classes the fleet keeps rediscovering, distilled from binding design
# rulings and QA FAIL reports (Compounding Fleet stage C, ORD-274).
#
# Each class carries a stable id, a name, a one-line INVARIANT (the closed rule
# that makes the class structurally unlikely), DETECTION CUES (what a task brief
# or QA finding looks like when the class applies), a FIX PATTERN, and one or more
# PROVENANCE citations (the rulings / QA reports it was distilled from). The
# occurrence count is DERIVED: it is the number of provenance citations a class has
# accumulated, so every bump is provenance-bearing by construction.
#
# The ledger is an APPEND-ONLY jsonl event log (docs/failure-classes/ledger.jsonl),
# the same fold-at-read idiom as memory-registry.jsonl and the KD comment ledger:
#   * a `class-defined` event declares a class with its seed provenance;
#   * an `occurrence` event appends one more provenance citation to an existing id.
# `list`/`show` fold the log; no verb ever rewrites or deletes a prior line.
#
# This script is the SANCTIONED WRITER. It refuses a duplicate id, an occurrence
# against an unknown id, and any event missing provenance, so the ledger cannot
# drift into an unprovenanced or self-contradictory state.
#
# Retrieval is delegated: `register` distils each class into the LIVE memory
# registry through the activated propose/activate flow (mem propose | mem activate)
# with every provenance citation as `--evidence`, and a reserved `failure-class`
# keyword marker so curation and PR-4 dispatch recall can filter to just these
# classes. Registration mutates the live registry and is therefore DRY-RUN by
# default; it touches the registry ONLY behind the explicit --live flag.
#
# Usage:
#   fm-failure-class.sh list [--json]
#   fm-failure-class.sh show <id> [--json]
#   fm-failure-class.sh validate
#   fm-failure-class.sh add --id <FC-NNN> --name <text> --invariant <text> \
#        --fix <text> --cue <text> [--cue <text> ...] \
#        --provenance <type>:<ref>[:<note>] [--provenance ... ] \
#        [--memory-type procedural|factual] [--scope fleet|project|captain|environment] \
#        [--confidence unverified|observed|reproduced|guarded] [--keyword <kw> ...]
#   fm-failure-class.sh bump <id> --provenance <type>:<ref>[:<note>] [--note <text>]
#   fm-failure-class.sh register [--id <FC-NNN> ...] [--live] [--gate <ref>] [--json]
#
# Env:
#   FM_FC_LEDGER    ledger path override (default docs/failure-classes/ledger.jsonl).
#   MEM_CLI         memory CLI command override (default: node <root>/memory/bin/mem.mjs).
#   MEM_REGISTRY_DIR  registry `register --live` targets (default: memory package default).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
LEDGER="${FM_FC_LEDGER:-$FM_ROOT/docs/failure-classes/ledger.jsonl}"
SCHEMA="kraken-failure-class/ledger-event/v1"
MARKER_KEYWORD="failure-class"

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; }
die() { echo "fm-failure-class: $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required"

# ---- fold -----------------------------------------------------------------
# Fold the append-only event log into one record per class id. class-defined sets
# the base fields; every occurrence event appends its provenance. occurrence_count
# is the length of the merged provenance array. A malformed line, an unknown-schema
# line, an occurrence against an undefined id, or a duplicate class-defined id is a
# hard error, so a corrupt ledger fails closed rather than folding silently.
fold() {
  [ -f "$LEDGER" ] || { echo '[]'; return 0; }
  jq -s '
    reduce .[] as $e ({defs:{}, order:[]};
      ($e.schema // "") as $s
      | if $s != "'"$SCHEMA"'" then error("bad schema on event: \($e)")
        elif $e.event == "class-defined" then
          if (.defs[$e.id] != null) then error("duplicate class id: \($e.id)")
          else .defs[$e.id] = ($e | del(.event)) | .order += [$e.id] end
        elif $e.event == "occurrence" then
          if (.defs[$e.id] == null) then error("occurrence for unknown class id: \($e.id)")
          elif ($e.provenance | type) != "object" then error("occurrence missing provenance: \($e.id)")
          else .defs[$e.id].provenance += [$e.provenance] end
        else error("unknown event: \($e.event)") end)
    | [ .order[] as $id | .defs[$id] | .occurrence_count = (.provenance | length) ]
  ' "$LEDGER"
}

fold_or_die() {
  local out
  out=$(fold) || die "ledger is corrupt (see error above): $LEDGER"
  printf '%s' "$out"
}

# ---- provenance parsing ---------------------------------------------------
# One --provenance argument is <type>:<ref>[:<note>]. type and ref are required;
# the note is the optional remainder (which may itself contain colons).
prov_json() {
  local raw=$1 type ref note
  type=${raw%%:*}
  local rest=${raw#*:}
  [ "$type" != "$raw" ] && [ -n "$type" ] || die "provenance must be <type>:<ref>[:<note>], got '$raw'"
  ref=${rest%%:*}
  [ -n "$ref" ] || die "provenance ref is empty in '$raw'"
  if [ "$ref" != "$rest" ]; then note=${rest#*:}; else note=""; fi
  if [ -n "$note" ]; then
    jq -cn --arg t "$type" --arg r "$ref" --arg n "$note" '{type:$t, ref:$r, note:$n}'
  else
    jq -cn --arg t "$type" --arg r "$ref" '{type:$t, ref:$r}'
  fi
}

append_event() { # <compact-json-object>
  mkdir -p "$(dirname "$LEDGER")"
  printf '%s\n' "$1" >> "$LEDGER"
}

# ---- verbs ----------------------------------------------------------------

cmd_list() {
  local json=0; [ "${1:-}" = "--json" ] && json=1
  local folded; folded=$(fold_or_die)
  if [ "$json" = 1 ]; then printf '%s\n' "$folded"; return 0; fi
  printf '%-8s  %5s  %s\n' "ID" "COUNT" "NAME / INVARIANT"
  printf '%s\n' "$folded" | jq -r '.[] | "\(.id)\t\(.occurrence_count)\t\(.name)\t\(.invariant)"' \
    | while IFS=$'\t' read -r id count name inv; do
        printf '%-8s  %5s  %s\n' "$id" "$count" "$name"
        printf '%-8s  %5s    -> %s\n' "" "" "$inv"
      done
}

cmd_show() {
  local id=${1:-}; shift || true
  [ -n "$id" ] || die "show requires a class id"
  local json=0; [ "${1:-}" = "--json" ] && json=1
  local rec; rec=$(fold_or_die | jq -c --arg id "$id" '.[] | select(.id==$id)')
  [ -n "$rec" ] || die "class not found: $id"
  if [ "$json" = 1 ]; then printf '%s\n' "$rec" | jq .; return 0; fi
  printf '%s\n' "$rec" | jq -r '
    "\(.id) - \(.name)  [occurrences: \(.occurrence_count)]",
    "",
    "  invariant: \(.invariant)",
    "",
    "  detection cues:",
    (.cues[] | "    - \(.)"),
    "",
    "  fix pattern: \(.fix)",
    "",
    "  registry: memory-type=\(.registry.memory_type)  scope=\(.registry.scope)  confidence=\(.registry.confidence)",
    "  keywords: \(.registry.keywords | join(", "))",
    "",
    "  provenance (\(.provenance | length)):",
    (.provenance[] | "    - [\(.type)] \(.ref)\(if .note then "  - \(.note)" else "" end)")
  '
}

cmd_validate() {
  local folded; folded=$(fold_or_die)
  local n; n=$(printf '%s\n' "$folded" | jq 'length')
  # Every class must carry a non-empty name/invariant/fix, at least one cue, and at
  # least one provenance citation. A class that fails any of these is a defect in
  # the ledger, not a soft warning.
  local bad
  bad=$(printf '%s\n' "$folded" | jq -r '.[] | select(
      (.name|type)!="string" or (.name|length)==0 or
      (.invariant|type)!="string" or (.invariant|length)==0 or
      (.fix|type)!="string" or (.fix|length)==0 or
      (.cues|type)!="array" or (.cues|length)==0 or
      (.provenance|type)!="array" or (.provenance|length)==0 or
      (.id|test("^FC-[0-9]{3,}$")|not)
    ) | .id')
  [ -z "$bad" ] || die "invalid class record(s): $bad"
  echo "FAILURE_CLASSES_OK=$n ($LEDGER)"
}

cmd_add() {
  local id="" name="" invariant="" fix="" memtype="procedural" scope="fleet" confidence="guarded"
  local cues=() provs=() keywords=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --id) id=${2:-}; shift 2 ;;
      --name) name=${2:-}; shift 2 ;;
      --invariant) invariant=${2:-}; shift 2 ;;
      --fix) fix=${2:-}; shift 2 ;;
      --cue) cues+=("${2:-}"); shift 2 ;;
      --provenance) provs+=("${2:-}"); shift 2 ;;
      --keyword) keywords+=("${2:-}"); shift 2 ;;
      --memory-type) memtype=${2:-}; shift 2 ;;
      --scope) scope=${2:-}; shift 2 ;;
      --confidence) confidence=${2:-}; shift 2 ;;
      *) die "add: unknown flag '$1'" ;;
    esac
  done
  [ -n "$id" ] || die "add requires --id"
  echo "$id" | grep -Eq '^FC-[0-9]{3,}$' || die "id must match FC-NNN, got '$id'"
  [ -n "$name" ] || die "add requires --name"
  [ -n "$invariant" ] || die "add requires --invariant"
  [ -n "$fix" ] || die "add requires --fix"
  [ "${#cues[@]}" -gt 0 ] || die "add requires at least one --cue"
  [ "${#provs[@]}" -gt 0 ] || die "add requires at least one --provenance (a class with no provenance is not admissible)"
  # Duplicate-id refusal: append-only means we must not shadow an existing class.
  if [ -f "$LEDGER" ] && fold_or_die | jq -e --arg id "$id" 'any(.[]; .id==$id)' >/dev/null; then
    die "class id already defined: $id (append-only; use bump to add provenance)"
  fi
  local cues_json prov_json_arr kw_json
  cues_json=$(printf '%s\n' "${cues[@]}" | jq -R . | jq -s .)
  prov_json_arr="["; local first=1 p
  for p in "${provs[@]}"; do
    [ "$first" = 1 ] && first=0 || prov_json_arr+=","
    prov_json_arr+=$(prov_json "$p")
  done
  prov_json_arr+="]"
  # Reserved marker keyword + the class id + slug make the record filterable in the
  # registry; any operator-supplied keywords are appended.
  local slug; slug=$(echo "$name" | tr '[:upper:] /' '[:lower:]--' | tr -cd 'a-z0-9-' | tr -s '-' | cut -c1-40 | sed 's/-*$//')
  kw_json=$(printf '%s\n' "$MARKER_KEYWORD" "$id" "$slug" "${keywords[@]:-}" \
    | jq -R 'select(length>0)' | jq -s 'unique_by(.)')
  local event
  event=$(jq -cn \
    --arg schema "$SCHEMA" --arg id "$id" --arg name "$name" \
    --arg inv "$invariant" --arg fix "$fix" \
    --arg mt "$memtype" --arg scope "$scope" --arg conf "$confidence" \
    --argjson cues "$cues_json" --argjson prov "$prov_json_arr" --argjson kw "$kw_json" \
    '{schema:$schema, event:"class-defined", id:$id, name:$name, invariant:$inv,
      cues:$cues, fix:$fix, provenance:$prov,
      registry:{memory_type:$mt, scope:$scope, confidence:$conf, keywords:$kw}}')
  append_event "$event"
  echo "added $id ($(echo "$prov_json_arr" | jq length) provenance citation(s))"
}

cmd_bump() {
  local id=${1:-}; shift || true
  [ -n "$id" ] || die "bump requires a class id"
  local prov="" note=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --provenance) prov=${2:-}; shift 2 ;;
      --note) note=${2:-}; shift 2 ;;
      *) die "bump: unknown flag '$1'" ;;
    esac
  done
  [ -n "$prov" ] || die "bump requires --provenance <type>:<ref>[:<note>]"
  fold_or_die | jq -e --arg id "$id" 'any(.[]; .id==$id)' >/dev/null \
    || die "cannot bump unknown class id: $id (define it with add first)"
  local pj; pj=$(prov_json "$prov")
  [ -n "$note" ] && pj=$(printf '%s' "$pj" | jq -c --arg n "$note" '.note = (.note // $n)')
  local event
  event=$(jq -cn --arg schema "$SCHEMA" --arg id "$id" --argjson prov "$pj" \
    '{schema:$schema, event:"occurrence", id:$id, provenance:$prov}')
  append_event "$event"
  local count; count=$(fold_or_die | jq --arg id "$id" '.[] | select(.id==$id) | .occurrence_count')
  echo "bumped $id -> occurrence_count=$count"
}

# register: distil the folded ledger into the LIVE memory registry via the
# activated propose/activate flow. DRY-RUN by default; --live is the explicit flag
# firstmate runs to actually mutate the registry. Every provenance citation becomes
# an `--evidence <type>:<ref>` on both propose and activate; the reserved
# `failure-class` keyword marker lets curation and dispatch recall filter to these.
cmd_register() {
  local live=0 gate="" json=0 only=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --live) live=1; shift ;;
      --gate) gate=${2:-}; shift 2 ;;
      --id) only+=("${2:-}"); shift 2 ;;
      --json) json=1; shift ;;
      *) die "register: unknown flag '$1'" ;;
    esac
  done
  local mem_cli="${MEM_CLI:-node $FM_ROOT/memory/bin/mem.mjs}"
  [ -n "$gate" ] || gate="data/kl-improve-scout-f5/compounding-fleet.kd.html#stage-C"
  local folded; folded=$(fold_or_die)
  if [ "${#only[@]}" -gt 0 ]; then
    local sel; sel=$(printf '%s\n' "${only[@]}" | jq -R . | jq -s .)
    folded=$(printf '%s\n' "$folded" | jq --argjson sel "$sel" '[ .[] | select(.id as $i | $sel|index($i)) ]')
  fi
  local results="[]"
  local n; n=$(printf '%s\n' "$folded" | jq 'length')
  [ "$n" -gt 0 ] || die "register: no matching classes"
  local i=0
  while [ "$i" -lt "$n" ]; do
    local rec; rec=$(printf '%s\n' "$folded" | jq -c ".[$i]")
    i=$((i+1))
    local id name summary body memtype scope conf
    id=$(printf '%s' "$rec" | jq -r .id)
    name=$(printf '%s' "$rec" | jq -r .name)
    memtype=$(printf '%s' "$rec" | jq -r .registry.memory_type)
    scope=$(printf '%s' "$rec" | jq -r .registry.scope)
    conf=$(printf '%s' "$rec" | jq -r .registry.confidence)
    summary=$(printf '%s' "$rec" | jq -r '"[failure-class \(.id)] \(.name)"' | cut -c1-240)
    body=$(printf '%s' "$rec" | jq -r '
      "INVARIANT: \(.invariant)\n\nFIX PATTERN: \(.fix)\n\nDETECTION CUES:\n" +
      (.cues | map("- \(.)") | join("\n")) +
      "\n\nProvenance: " + (.provenance | map("\(.type):\(.ref)") | join("; "))')
    # Build the flag arrays for propose/activate.
    local -a propose_args activate_args
    propose_args=(propose --summary "$summary" --body "$body"
      --memory-type "$memtype" --scope "$scope" --confidence "$conf")
    local kw
    while IFS= read -r kw; do [ -n "$kw" ] && propose_args+=(--keyword "$kw"); done \
      < <(printf '%s' "$rec" | jq -r '.registry.keywords[]')
    activate_args=(activate)  # memId filled after propose
    local ev
    while IFS= read -r ev; do
      [ -n "$ev" ] || continue
      propose_args+=(--evidence "$ev")
      activate_args+=(--evidence "$ev")
    done < <(printf '%s' "$rec" | jq -r '.provenance[] | "\(.type):\(.ref)"')
    activate_args+=(--validation "$gate" --confidence "$conf")

    if [ "$live" = 1 ]; then
      local pout memid
      pout=$($mem_cli "${propose_args[@]}" --json) || die "propose failed for $id"
      memid=$(printf '%s' "$pout" | jq -r .memId)
      [ -n "$memid" ] && [ "$memid" != "null" ] || die "propose returned no memId for $id"
      $mem_cli activate "$memid" "${activate_args[@]:1}" --json >/dev/null \
        || die "activate failed for $id ($memid)"
      results=$(printf '%s' "$results" | jq -c --arg id "$id" --arg m "$memid" '. + [{class:$id, memId:$m, live:true}]')
      [ "$json" = 0 ] && echo "registered $id -> $memid (active)"
    else
      # Dry run: print the exact commands, mutate nothing.
      results=$(printf '%s' "$results" | jq -c --arg id "$id" '. + [{class:$id, live:false}]')
      if [ "$json" = 0 ]; then
        echo "# $id - DRY RUN (pass --live to execute)"
        printf '  %s' "$mem_cli"; printf ' %q' "${propose_args[@]}"; printf '  # -> MEM-XXXX\n'
        printf '  %s activate MEM-XXXX' "$mem_cli"; printf ' %q' "${activate_args[@]:1}"; printf '\n'
      fi
    fi
  done
  if [ "$json" = 1 ]; then printf '%s\n' "$results" | jq .; fi
  if [ "$live" = 0 ]; then
    echo "register: DRY RUN only - no registry writes. Re-run with --live to activate $n class(es)." >&2
  fi
}

main() {
  local verb=${1:-help}; shift || true
  case "$verb" in
    list) cmd_list "$@" ;;
    show) cmd_show "$@" ;;
    validate) cmd_validate "$@" ;;
    add) cmd_add "$@" ;;
    bump) cmd_bump "$@" ;;
    register) cmd_register "$@" ;;
    -h|--help|help) usage ;;
    *) die "unknown verb '$verb' (try --help)" ;;
  esac
}

main "$@"

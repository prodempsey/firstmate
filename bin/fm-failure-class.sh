#!/usr/bin/env bash
# The failure-class ledger: a durable, append-only catalogue of the RECURRING
# failure classes the fleet keeps rediscovering, distilled from binding design
# rulings and QA FAIL reports (Seasoning stage C, ORD-274).
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
#   fm-failure-class.sh ensure --id <FC-NNN> ...   # idempotent-additive add (skip if present)
#   fm-failure-class.sh bump <id> --provenance <type>:<ref>[:<note>] [--note <text>]
#   fm-failure-class.sh refinements [--json]   # classes at/over the refinement threshold, with provenance
#   fm-failure-class.sh register [--id <FC-NNN> ...] [--live] [--gate <ref>] [--json]
#
# Stage E - captain-gated self-refinement (Seasoning, ORD-274). When a
# `bump` (occurrence event) pushes a class's DERIVED occurrence count across the
# refinement threshold, the bump prints a bordered REFINEMENT DUE banner naming the
# Seasoning class, its invariant, and the instruction to draft a brief-template /
# QA-checklist amendment for CAPTAIN approval - the same pull-based stderr banner
# idiom as fm-triage-duty.sh: it never blocks the bump and the verb still exits 0.
# The banner fires exactly ONCE, on the crossing bump; later bumps of an already-over
# class stay silent. The `refinements` verb lists every class at/over threshold with
# its full provenance, so a draft has its citations ready.
#
# register sets a distinct, typed `sourceType=failure-class` (mem propose
# --source-type) on every registered record so curation can filter failure classes
# by a first-class field, not only a keyword.
#
# All ledger mutations (add/ensure/bump) serialize the whole read-check-append
# under a portable, abandoned-owner-aware lock co-located with the ledger, so
# concurrent sanctioned writers cannot corrupt the append-only log.
#
# Env:
#   FM_FC_LEDGER    ledger path override (default docs/failure-classes/ledger.jsonl).
#   MEM_CLI         memory CLI command override (default: node <root>/memory/bin/mem.mjs).
#   MEM_REGISTRY_DIR  registry `register --live` targets (default: memory package default).
#   FM_FC_REFINE_THRESHOLD  occurrence count at/above which a class is DUE for a
#                   captain-gated process amendment (default 3). A value that is not a
#                   positive integer falls back to the default.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
LEDGER="${FM_FC_LEDGER:-$FM_ROOT/docs/failure-classes/ledger.jsonl}"
SCHEMA="kraken-failure-class/ledger-event/v1"
MARKER_KEYWORD="failure-class"
REFINE_THRESHOLD_DEFAULT=3
REFINE_RULE='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; }
die() { echo "fm-failure-class: $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required"

# ---- serialization --------------------------------------------------------
# The ledger is append-only, but "check the id is absent, then append" is only
# durable if the whole read-check-append runs as one serialized transaction: two
# concurrent writers could otherwise both pass the duplicate check and append the
# same id. Reuse the fleet's portable, abandoned-owner-aware lock (fm-wake-lib.sh)
# on a lock co-located with the ledger, so distinct ledgers never contend and a
# dead writer's lock is reclaimed rather than deadlocking.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

LEDGER_LOCK="$LEDGER.lock"
FM_FC_LOCK_HELD=""
release_ledger_lock() {
  [ -n "$FM_FC_LOCK_HELD" ] || return 0
  fm_lock_release "$FM_FC_LOCK_HELD" 2>/dev/null || true
  FM_FC_LOCK_HELD=""
}
# EXIT covers a normal return, a die(), and set -e; the trap guarantees the lock is
# released even if the critical section aborts mid-transaction.
trap release_ledger_lock EXIT
lock_ledger() { mkdir -p "$(dirname "$LEDGER")"; fm_lock_acquire_wait "$LEDGER_LOCK"; FM_FC_LOCK_HELD="$LEDGER_LOCK"; }
unlock_ledger() { fm_lock_release "$LEDGER_LOCK"; FM_FC_LOCK_HELD=""; }

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

# ---- stage E: captain-gated refinement ------------------------------------
# The occurrence count at/above which a class is DUE for a captain-gated process
# amendment. Configurable per repo conventions via the FM_FC_REFINE_THRESHOLD env
# knob (like FM_FC_LEDGER above); a value that is not a positive integer falls back
# to the default rather than disabling the ratchet.
refine_threshold() {
  local t=${FM_FC_REFINE_THRESHOLD:-$REFINE_THRESHOLD_DEFAULT}
  case "$t" in
    ''|*[!0-9]*) t=$REFINE_THRESHOLD_DEFAULT ;;
  esac
  [ "$t" -ge 1 ] 2>/dev/null || t=$REFINE_THRESHOLD_DEFAULT
  printf '%s' "$t"
}

# Print the bordered REFINEMENT DUE banner for a Seasoning class that just crossed
# the threshold. Same pull-based stderr idiom as fm-triage-duty.sh: it names the
# class, its invariant, and the instruction to draft a process amendment for CAPTAIN
# approval, and lists the provenance so the draft's citations are ready. It writes
# only to stderr and returns 0, so it never blocks or fails the bump.
emit_refinement_banner() { # <record-json> <count> <threshold>
  local rec=$1 count=$2 threshold=$3 id name inv provlist
  id=$(printf '%s' "$rec" | jq -r .id)
  name=$(printf '%s' "$rec" | jq -r .name)
  inv=$(printf '%s' "$rec" | jq -r .invariant)
  provlist=$(printf '%s' "$rec" | jq -r '.provenance[] | "[\(.type)] \(.ref)\(if .note then " - \(.note)" else "" end)"')
  {
    printf '●%s\n' "$REFINE_RULE"
    printf '●  REFINEMENT DUE (Seasoning) - %s: %s\n' "$id" "$name"
    printf '●  Occurrence count %s crossed the refinement threshold (%s). This class\n' "$count" "$threshold"
    printf '●  keeps recurring, so the lesson should graduate from recall into the process.\n'
    printf '●  invariant: %s\n' "$inv"
    printf '●  Draft an amendment to the brief template or QA checklist that bakes the\n'
    printf '●  invariant above into the process, and put it on the board for CAPTAIN\n'
    printf '●  approval - do not amend the process unasked.\n'
    printf '●  Provenance (cite these in the draft; the refinements verb lists all):\n'
    printf '%s\n' "$provlist" | sed 's/^/●    - /'
    printf '●%s\n' "$REFINE_RULE"
  } >&2
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

# Parse the class-definition flags shared by `add` and `ensure`, validate them, and
# build the class-defined event. Sets FC_EVENT, FC_ID, FC_PROVCOUNT. Pure: reads no
# ledger and appends nothing, so it is safe to run before taking the lock.
FC_EVENT="" FC_ID="" FC_PROVCOUNT=0
build_class_event() {
  local id="" name="" invariant="" fix="" memtype="procedural" scope="fleet" confidence="guarded"
  local cues=() provs=() keywords=() dets=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --id) id=${2:-}; shift 2 ;;
      --name) name=${2:-}; shift 2 ;;
      --invariant) invariant=${2:-}; shift 2 ;;
      --fix) fix=${2:-}; shift 2 ;;
      --cue) cues+=("${2:-}"); shift 2 ;;
      --detection) dets+=("${2:-}"); shift 2 ;;
      --provenance) provs+=("${2:-}"); shift 2 ;;
      --keyword) keywords+=("${2:-}"); shift 2 ;;
      --memory-type) memtype=${2:-}; shift 2 ;;
      --scope) scope=${2:-}; shift 2 ;;
      --confidence) confidence=${2:-}; shift 2 ;;
      *) die "unknown flag '$1'" ;;
    esac
  done
  [ -n "$id" ] || die "requires --id"
  echo "$id" | grep -Eq '^FC-[0-9]{3,}$' || die "id must match FC-NNN, got '$id'"
  [ -n "$name" ] || die "requires --name"
  [ -n "$invariant" ] || die "requires --invariant"
  [ -n "$fix" ] || die "requires --fix"
  [ "${#cues[@]}" -gt 0 ] || die "requires at least one --cue"
  [ "${#provs[@]}" -gt 0 ] || die "requires at least one --provenance (a class with no provenance is not admissible)"
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
  # Optional machine-readable detection: each --detection is one JSON object
  # ({engine, pattern, cue_ref, ...}) that graduates a natural-language cue into an
  # executable check a verifier can run live from this ledger. The field is emitted
  # only when supplied, so classes without detection stay byte-identical.
  local dets_json="[]"
  if [ "${#dets[@]}" -gt 0 ]; then
    dets_json=$(printf '%s\n' "${dets[@]}" | jq -c . 2>/dev/null | jq -sc .) \
      || die "each --detection must be one valid JSON object"
  fi
  FC_EVENT=$(jq -cn \
    --arg schema "$SCHEMA" --arg id "$id" --arg name "$name" \
    --arg inv "$invariant" --arg fix "$fix" \
    --arg mt "$memtype" --arg scope "$scope" --arg conf "$confidence" \
    --argjson cues "$cues_json" --argjson prov "$prov_json_arr" --argjson kw "$kw_json" \
    --argjson dets "$dets_json" \
    '{schema:$schema, event:"class-defined", id:$id, name:$name, invariant:$inv,
      cues:$cues, fix:$fix, provenance:$prov,
      registry:{memory_type:$mt, scope:$scope, confidence:$conf, keywords:$kw}}
     + (if ($dets|length) > 0 then {detection:$dets} else {} end)')
  FC_ID="$id"
  FC_PROVCOUNT=$(echo "$prov_json_arr" | jq length)
}

# Commit FC_EVENT under the ledger lock. mode=strict refuses a duplicate id;
# mode=ensure treats an existing id as an idempotent no-op (skip). The whole
# read-check-append runs inside one lock so two concurrent writers can never both
# pass the check and append the same id.
commit_class() {
  local mode=$1 exists
  lock_ledger
  exists=0
  if [ -f "$LEDGER" ] && fold_or_die | jq -e --arg id "$FC_ID" 'any(.[]; .id==$id)' >/dev/null; then exists=1; fi
  if [ "$exists" = 1 ]; then
    if [ "$mode" = strict ]; then
      die "class id already defined: $FC_ID (append-only; use bump to add provenance)"
    fi
    unlock_ledger
    echo "present: $FC_ID (unchanged)"
    return 0
  fi
  append_event "$FC_EVENT"
  unlock_ledger
  echo "added $FC_ID ($FC_PROVCOUNT provenance citation(s))"
}

cmd_add() {
  build_class_event "$@"
  commit_class strict
}

# ensure: idempotent-additive add. Appends the class only if its id is absent; an
# already-present id is a skip, never an error and never a rewrite. This is the
# safe reseed primitive - re-running it never drops or duplicates a row.
cmd_ensure() {
  build_class_event "$@"
  commit_class ensure
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
  local pj; pj=$(prov_json "$prov")
  [ -n "$note" ] && pj=$(printf '%s' "$pj" | jq -c --arg n "$note" '.note = (.note // $n)')
  local event
  event=$(jq -cn --arg schema "$SCHEMA" --arg id "$id" --argjson prov "$pj" \
    '{schema:$schema, event:"occurrence", id:$id, provenance:$prov}')
  # The existence check and the occurrence append run under one lock, against one
  # serialized generation, so bump can never append against a stale read.
  lock_ledger
  fold_or_die | jq -e --arg id "$id" 'any(.[]; .id==$id)' >/dev/null \
    || die "cannot bump unknown class id: $id (define it with add first)"
  append_event "$event"
  # Read the post-append record inside the same serialized generation so the count -
  # and therefore the crossing test - reflects exactly this bump, never a stale read.
  local rec; rec=$(fold_or_die | jq -c --arg id "$id" '.[] | select(.id==$id)')
  unlock_ledger
  local count; count=$(printf '%s' "$rec" | jq '.occurrence_count')
  echo "bumped $id -> occurrence_count=$count"
  # Stage E: fire the captain-gated refinement banner exactly on the bump that CROSSES
  # the threshold (prev < threshold <= count). Because each bump appends exactly one
  # provenance, prev == count-1, so a class already at/over threshold never re-fires on
  # subsequent bumps. Pull-based, stderr-only, never blocks: the bump still exits 0.
  local threshold; threshold=$(refine_threshold)
  if [ "$((count - 1))" -lt "$threshold" ] && [ "$count" -ge "$threshold" ]; then
    emit_refinement_banner "$rec" "$count" "$threshold"
  fi
}

# refinements: list every class whose derived occurrence count is at/over the
# refinement threshold, each with its full provenance, so a captain-gated process
# amendment can be drafted with its citations ready. Read-only: it folds the ledger
# and prints, mutating nothing.
cmd_refinements() {
  local json=0; [ "${1:-}" = "--json" ] && json=1
  local threshold; threshold=$(refine_threshold)
  local due
  due=$(fold_or_die | jq -c --argjson t "$threshold" '[ .[] | select(.occurrence_count >= $t) ]')
  if [ "$json" = 1 ]; then
    printf '%s\n' "$due" | jq --argjson t "$threshold" '{threshold:$t, classes:.}'
    return 0
  fi
  local n; n=$(printf '%s\n' "$due" | jq 'length')
  if [ "$n" = 0 ]; then
    echo "no classes at/over the refinement threshold ($threshold)"
    return 0
  fi
  echo "Classes DUE for captain-gated refinement (occurrence_count >= $threshold):"
  echo
  printf '%s\n' "$due" | jq -r '.[] |
    "\(.id) - \(.name)  [occurrences: \(.occurrence_count)]",
    "  invariant: \(.invariant)",
    "  provenance:",
    (.provenance[] | "    - [\(.type)] \(.ref)\(if .note then "  - \(.note)" else "" end)"),
    ""'
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
    # --source-type is the typed, filterable provenance-class marker curation uses;
    # the failure-class keyword is retained as a retrieval alias, but the typed field
    # is the curation boundary.
    propose_args=(propose --summary "$summary" --body "$body" --source-type "$MARKER_KEYWORD"
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
    ensure) cmd_ensure "$@" ;;
    bump) cmd_bump "$@" ;;
    refinements) cmd_refinements "$@" ;;
    register) cmd_register "$@" ;;
    -h|--help|help) usage ;;
    *) die "unknown verb '$verb' (try --help)" ;;
  esac
}

main "$@"

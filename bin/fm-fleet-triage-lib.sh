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
#
# A bug's disposition turns on more than its open/resolved bit: a bug that gains a task
# link, a resolution note, or a reclassified type has materially moved, and a rejection
# decided before that move no longer holds. All four are structured, so hashing them
# invalidates a stale disposition without churning on wording. Its title and sourceText
# stay excluded, per the prose rule above.
#
# A scout report's deliverable IS its body, so the report path alone cannot say whether
# the findings changed. The lane therefore hashes a digest of the file's contents, which
# the enumerator computes; a report rewritten in place re-opens a disposition made
# against the old findings. This is not a prose exception: the body is the evidence.
#
# A captain order's evidence is its disposition, never the captain's wording: the request
# text is preserved verbatim forever and must never mint a new logical item. Its status,
# owner, lineage links, and review condition are what a triage decision was made against,
# so those - and only those - participate.
fm_triage_evidence_version() {
  jq -cS '
    {lane, source_id: .id}
    + (if .lane == "captain_orders" then {status,
                                          owner: (.owner // null),
                                          links: (.links // null),
                                          review_after: (.review_after // null)}
       elif .lane == "needs_firstmate" then {signal: .source_fingerprint}
       elif .lane == "bugs" then {status,
                                  type: (.type // null),
                                  links: (.links // null),
                                  note: (.note // null)}
       elif .lane == "scout_reports" then {report: .source,
                                           digest: (.report_digest // null)}
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

# Print the ledger's structural health as JSON, accounting for every row the fold above
# silently skips. fm_triage_fold survives a malformed row, which is the right availability
# behavior, but a skip that leaves no trace is a defect that can never be repaired: the
# two directions are not symmetric. A malformed TERMINAL row fails safe, reverting its
# item to actionable and costing rework. A malformed SURFACE row fails DANGEROUS: the item
# loses first_seen_at, so it can never age into stale_unprocessed and the self-audit is
# structurally unable to notice it sitting unprocessed forever.
#
# The excerpt is bounded and stripped of non-printable bytes so a corrupt row can be named
# in a digest without pasting arbitrary content into a report. Whitespace-only lines are
# not rows and are neither counted nor reported.
fm_triage_ledger_health() {  # <ledger-path>
  local ledger=$1
  [ -f "$ledger" ] || {
    jq -cn --arg path "$ledger" \
      '{path: $path, present: false, total_rows: 0, malformed_rows: 0, rows: []}'
    return 0
  }
  jq -Rn --arg path "$ledger" '
    reduce inputs as $line
      ({path: $path, present: true, total_rows: 0, malformed_rows: 0, rows: [], _line: 0};
       ._line += 1
       | if ($line | test("^[[:space:]]*$")) then .
         else
           .total_rows += 1
           | ($line | try fromjson catch null) as $e
           | (if ($e | type) != "object" then "unparseable JSON"
              elif (($e.item_id // "") == "") then "missing item_id"
              else null end) as $why
           | if $why == null then .
             else
               .malformed_rows += 1
               | .rows += (if (.rows | length) < 5
                           then [{line: ._line,
                                  reason: $why,
                                  excerpt: ($line
                                            | gsub("[^ -~]"; "?")
                                            | .[0:120])}]
                           else [] end)
             end
         end)
    | del(._line)
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

# Render the fm-fleet-triage/v2 JSON on stdin as the same token-capped digest text
# fm-fleet-triage.sh --digest prints. Shared so a caller that already paid for one
# --json enumeration (bin/fm-triage-duty.sh) never re-runs the whole snapshot/NF/bug/
# ledger pipeline a second time just to get the human-readable rendering; the two
# presentations of one enumeration must never drift apart into two implementations.
fm_triage_render_digest() {  # <max-items>
  local max=${1:-8}
  jq -r --argjson max "$max" '
    def dur($s):
      if $s == null or $s < 60 then "new"
      elif $s < 3600 then ((($s / 60) | floor | tostring) + "m")
      elif $s < 86400 then ((($s / 3600) | floor | tostring) + "h")
      else ((($s / 86400) | floor | tostring) + "d") end;

    .metrics as $m
    | .ledger.path as $ledger_path
    | ["FLEET TRIAGE: " + ($m.actionable | tostring) + " actionable, "
        + ($m.total | tostring) + " total (mode: " + .mode + ")",
       "  ownerless: " + ($m.ownerless | tostring)
        + " | captain-gated: " + ($m.captain_gated | tostring)
        + " | auto-coordination: " + ($m.auto_coordination | tostring)]
    # Captain orders lead the digest when any are waiting: an unanswered captain request
    # outranks the housekeeping in every other lane.
    + (($m.captain_orders // {}) as $co
       | if ($co.actionable // 0) > 0 or ($co.pending_chat_captures // 0) > 0
         then ["  captain orders: " + (($co.actionable // 0) | tostring) + " needing action"
               + " | untriaged: " + (($co.untriaged // 0) | tostring)
               + " | captain decision: " + (($co.captain_decision // 0) | tostring)
               + " | undrained chat captures: " + (($co.pending_chat_captures // 0) | tostring)]
         else [] end)
    + (if $m.ledger_health.malformed_rows > 0
       then ["  ledger health: " + ($m.ledger_health.malformed_rows | tostring)
             + " malformed of " + ($m.ledger_health.total_rows | tostring)
             + " rows in " + $ledger_path
             + " (first at line " + (($m.ledger_health.rows[0].line // 0) | tostring)
             + ": " + ($m.ledger_health.rows[0].reason // "unknown") + ")"]
       else [] end)
    + [ .lanes | to_entries[]
        | .key as $k
        | select($k != "ledger_health" or $m.by_lane[$k].actionable > 0)
        | "  " + ($k | gsub("_"; " ")) + ": " + ($m.by_lane[$k].actionable | tostring)
          + (if .value.available then "" else " (unavailable: " + .value.note + ")" end)
          + (if $m.by_lane[$k].actionable > 0
             then " (oldest " + dur($m.by_lane[$k].oldest_age_seconds) + ")" else "" end) ]
    + [ ([.items[] | select(.actionable)][:$max])[]
        | "  - [" + (.lane | gsub("_"; " ")) + "] " + .source_id
          + (if .health != "ok" then " !" + .health else "" end)
          + ": " + (.title | gsub("[[:space:]]+"; " ")) ]
    + (($m.actionable - $max) as $rest
       | if $rest > 0
         then ["  - and " + ($rest | tostring)
               + " more; run bin/fm-fleet-triage.sh --json for full detail"]
         else [] end)
    | .[]
  ' | cut -c1-200
}

# Print machine-readable pass results for one fm-fleet-triage/v2 JSON blob on stdin:
# actionable, ownerless, unhealthy (actionable but health != ok), and captain_gated
# counts, plus a deterministic fingerprint over the current actionable set. The
# fingerprint changes only when the actionable set's membership or disposition
# changes (item_id, processing_state, health), never on a title or prose edit, so a
# caller can tell "still the same open items" from "something actually moved."
# fm-triage-duty.sh is the primary caller: it exposes this alongside the trigger and
# scope so a duty pass proves what it found instead of only prompting that something
# might be there.
fm_triage_pass_result() {  # <trigger> <scope>
  local trigger=$1 scope=$2 base fp
  base=$(jq -c --arg trigger "$trigger" --arg scope "$scope" '
    .metrics as $m
    | {trigger: $trigger,
       scope: $scope,
       actionable: $m.actionable,
       ownerless: $m.ownerless,
       unhealthy: ($m.actionable - ($m.health.ok // 0)),
       captain_gated: $m.captain_gated,
       fingerprint_input: ([.items[] | select(.actionable)
                            | (.item_id + ":" + .processing_state + ":" + .health)]
                           | sort | join("|"))
      }
  ') || return 1
  fp=$(printf '%s' "$base" | jq -r '.fingerprint_input' | fm_triage_hash) || return 1
  printf '%s' "$base" | jq -c --arg fp "$fp" 'del(.fingerprint_input) + {fingerprint: $fp}'
}

# Print the captain-gate detail bin/fm-guard.sh's dropped-captain-decision alarm reads,
# from one fm-fleet-triage/v2 JSON blob on stdin, as a compact JSON object:
#
#   {orders_total, orders: [{item_id, order_id, title, task}],
#    other_total,  other:  [{item_id, lane, source_id, title}]}
#
# WHY THE TWO GROUPS ARE NOT ONE. The captain is kept in the loop by exactly one durable
# mechanism: a card in the Fleet Bridge's needs_human column, whose sole writer is
# bin/fm-nf-ack.sh --to-captain <open-item-id> <task-id>. A card is therefore keyed to an
# OPEN ITEM, and only the captain_orders lane has one. A captain-gated ORDER with no card
# is a provably dropped decision - the thing the guard alarms on. A captain-gated item in
# any other lane (a visibility umbrella row) has nothing to key a card to, so no card
# contract exists to violate yet; it is carried here as context the guard can name, never
# as a dropped decision. Collapsing the two would make the alarm fire on standing product
# work forever, and an alarm that always fires is one nobody reads.
#
# The lists are capped so the cache this feeds stays small; the totals stay exact, so a
# capped list can never read as a shorter one.
fm_triage_captain_gates() {  # [max-items]
  local max=${1:-10}
  jq -c --argjson max "$max" '
    [.items[] | select(.actionable and .action_class == "CAPTAIN_GATE")] as $gated
    | ($gated | map(select(.lane == "captain_orders"))) as $orders
    | ($gated | map(select(.lane != "captain_orders"))) as $other
    | {orders_total: ($orders | length),
       orders: ($orders[:$max]
                | map({item_id,
                       order_id: .source_id,
                       title: ((.title // "") | gsub("[[:space:]]+"; " ")),
                       task: (((.task_links // []) | first) // null)})),
       other_total: ($other | length),
       other: ($other[:$max]
               | map({item_id, lane, source_id,
                      title: ((.title // "") | gsub("[[:space:]]+"; " "))}))}
  '
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

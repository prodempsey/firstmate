#!/usr/bin/env bash
# The Captain Order Inbox: the durable record of every captain request, and the ONLY
# sanctioned writer of it. Every captain request must be recorded here before firstmate
# does substantive work on it; chat history is not an order store.
#
# Usage:
#   fm-order.sh path                              Print the resolved inbox path.
#   fm-order.sh init                              Create the inbox explicitly.
#   fm-order.sh health                            Report inbox presence and malformed rows.
#
#   fm-order.sh add <request>...                  Record one or more captain requests.
#       [--source chat|bridge|cli|api|other] [--idempotency-key <key>]
#       [--priority <p>] [--priority-source default|captain_explicit|firstmate_recommended]
#       [--project <name>] [--title <short title>] [--received-at <iso8601>]
#       [--from-pending <capture-id>]             Record a spooled chat capture verbatim.
#   fm-order.sh pending [--json]                  List captured chat prompts not yet drained.
#   fm-order.sh dismiss <capture-id> --reason <why>   Durably drop a non-request capture.
#
#   fm-order.sh list [--json] [--actionable] [--status <s>]
#   fm-order.sh show <order-id> [--json] [--history]
#   fm-order.sh ack <order-id>...                 Print the brief receipt acknowledgment.
#   fm-order.sh digest                            Print the consolidated triaged update.
#   fm-order.sh metrics [--json]
#
#   fm-order.sh triage <id> [--title <t>] [--project <p>] [--priority <p>] [--priority-source <s>]
#   fm-order.sh queue <id> [--depends-on <order-id>]... [--reason <note>]
#   fm-order.sh claim <id> --owner <who>          |  fm-order.sh release <id>
#   fm-order.sh link <id> [--task <id>] [--scout <id>] [--bug <id>] [--order <id>]
#   fm-order.sh dispatch <id> [--task <id>] [--scout <id>] [--bug <id>]
#   fm-order.sh block <id> --reason <why> [--depends-on <order-id>]...
#   fm-order.sh hold <id> --reason <why> --review-after <when>
#   fm-order.sh clarify <id> --reason <what is unclear>
#   fm-order.sh decision <id> --reason <the decision the captain owes>
#   fm-order.sh supersede <id> --by <order-id> [--reason <why>]
#   fm-order.sh duplicate <id> --of <order-id>    Shorthand for supersede with a duplicate reason.
#   fm-order.sh reject <id> --reason <why>
#   fm-order.sh complete <id> --link <evidence> [--reason <note>]
#
# ACKNOWLEDGMENT FOLLOWS THE WRITE, NEVER PRECEDES IT. `add` appends, reads the row back,
# and re-folds before it prints a single word of success. A write it cannot verify exits
# non-zero and says which requests were recorded and which were not, because a false
# "recorded" is the one failure this whole mechanism exists to prevent.
#
# STATUS AND LINEAGE. Statuses are received, triaging, queued, dispatched, blocked, held,
# needs_clarification, captain_decision, completed, superseded, rejected. There is no
# `acknowledged` status: an acknowledgment means only that the durable record exists.
# bin/fm-order-lib.sh owns which fields each status requires, and this command refuses a
# write that does not carry them - a dispatch with no linked work, a hold with no review
# condition, and a rejection with no reason are not dispositions.
#
# STORAGE. An append-only JSONL ledger outside any git checkout, folded at read.
# bin/fm-order-lib.sh's header owns the path-resolution and concurrency contract; a
# missing inbox fails loudly on read rather than folding to an empty one, because a
# silently-empty inbox and a genuinely empty one are indistinguishable to a reader and
# only one of them means "no captain is waiting".
#
# Environment:
#   FM_ORDERS_PATH           explicit inbox path (overrides config/orders-path)
#   FM_ORDER_LOCK_TIMEOUT    seconds to wait for the writer lock (default 10)
#   FM_ORDER_STALE_SECS      age at which an unfinished order is stale (default 86400)
#   FM_ORDER_ACTOR           who recorded the event (default firstmate)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-role-context-lib.sh
. "$SCRIPT_DIR/fm-role-context-lib.sh"

# shellcheck disable=SC1091 # Dynamic sibling path is resolved from BASH_SOURCE.
. "$SCRIPT_DIR/fm-order-lib.sh"

STALE_SECS=${FM_ORDER_STALE_SECS:-86400}
case "$STALE_SECS" in ''|*[!0-9]*) STALE_SECS=86400 ;; esac

usage() {
  sed -n '2,58p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'fm-order: %s\n' "$1" >&2
  exit "${2:-1}"
}

command -v jq >/dev/null 2>&1 || die 'jq not found'

INBOX=$(fm_order_inbox_path "$FM_HOME")
PENDING_DIR=$(fm_order_pending_dir "$INBOX")
DISMISSED=$(fm_order_dismissed_path "$INBOX")
ACTOR=${FM_ORDER_ACTOR:-firstmate}

# NOTHING THE INBOX HOLDS EVER TRAVELS THROUGH AN ARGUMENT LIST. The inbox grows without
# bound - it is an append-only ledger of every captain request this home has ever taken -
# so any read that passed the folded inbox, a captain's request text, or the inbox health
# report to jq as an argv value (`--argjson fold "$(fold)"`) would work in every test and
# then die with E2BIG on the real thing once the ledger outgrew the kernel's argument
# limit. It did: a 180KB / 255-record inbox killed every read path at once, and the tools
# downstream could not tell a dead reader from a lost inbox, so they reported the captain's
# own orders as unreadable. Inbox-derived payloads therefore reach jq through a file
# (--slurpfile / --rawfile) or stdin, never argv. Only bounded scalars - an id, a status, a
# timestamp - are passed as arguments, and an argv value that came from the command line
# already fit through execve to get here.
#
# The scratch directory is created here, in the top-level shell, and removed by the one
# EXIT trap below. A read runs inside a command substitution, whose subshell does NOT run
# an EXIT trap, so a lazily-created scratch dir would leak one directory per read; owning
# it in the parent means a subshell can write into it and the parent still cleans it up.
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-order.XXXXXX") || die 'cannot create a scratch directory'

# shellcheck disable=SC2317,SC2329 # Invoked by the EXIT trap below.
order_cleanup() {
  fm_order_unlock
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  SCRATCH=''
}
trap order_cleanup EXIT

# A read of a missing inbox is ambiguous - a fresh home and a lost inbox look identical -
# so it fails visibly instead of reporting zero orders. Writes may create it, and say so.
require_inbox() {
  [ -f "$INBOX" ] && return 0
  die "no captain order inbox at $INBOX
  This is NOT the same as an empty inbox: the orders may be lost, or this home may be
  resolving a different path than the one they were written to. Do not assume no captain
  is waiting. Create one deliberately with: bin/fm-order.sh init" 3
}

# A write may create the inbox - intake must never be blocked by a missing file - but it
# says so, because an inbox appearing from nowhere can also mean this home is resolving a
# path the earlier orders were not written to.
ensure_inbox_for_write() {
  [ -f "$INBOX" ] && return 0
  mkdir -p "$(dirname "$INBOX")" || die "cannot create inbox directory $(dirname "$INBOX")"
  : > "$INBOX" || die "cannot create inbox $INBOX"
  [ "${FM_ORDER_QUIET_INIT:-0}" = 1 ] && return 0
  printf 'fm-order: initialized a new captain order inbox at %s\n' "$INBOX" >&2
}

lock_or_die() {
  fm_order_lock "$INBOX" \
    || die "refused: another writer holds the inbox lock $(fm_order_lock_dir "$INBOX"); NOTHING was recorded" 4
}

# Append one event and verify it landed. The verification is the point: an append that
# silently failed (a full disk, a read-only mount, a truncated write) would otherwise be
# reported to the captain as a durable record.
append_event() {  # <json-object>
  local row=$1 back
  printf '%s\n' "$row" >> "$INBOX" || return 1
  back=$(tail -1 "$INBOX" 2>/dev/null || true)
  [ "$back" = "$row" ] || return 1
  printf '%s' "$back" | jq -e 'type == "object" and (.order_id // "") != ""' >/dev/null 2>&1
}

now_ts() { fm_triage_now; }

# --- folded reads -------------------------------------------------------------------

# TWO FAILURES, TWO MESSAGES. An inbox that cannot be PARSED and a READER that crashed are
# different conditions with different remedies, and a reader that reports them identically
# turns its own defect into a false alarm about the captain's orders. `read_failed` is a
# defect in this script (exit 6): the ledger is intact, nothing is lost, fix the reader.
# `inbox_unreadable` (exit 5) is the one that really may mean lost requests. Callers -
# bin/fm-order-duty.sh and the fleet-triage captain_orders lane - branch on these codes.
FM_ORDER_RC_INBOX_UNREADABLE=5
FM_ORDER_RC_READER_FAILED=6

read_failed() {  # <what> <error-file>
  local what=$1 err=$2
  {
    printf 'fm-order: THE READER FAILED - this is a defect in bin/fm-order.sh, NOT lost orders.\n'
    printf '  %s\n' "$what"
    printf '  error: %s\n' "$(sed -e 's/^[[:space:]]*//' "$err" 2>/dev/null | grep -v '^$' | head -3 | tr '\n' ' ')"
    printf '  The inbox at %s is untouched; every order it holds is still on disk.\n' "$INBOX"
    printf '  Do NOT treat this as an empty inbox and do NOT rewrite the inbox to work around it.\n'
  } >&2
  exit "$FM_ORDER_RC_READER_FAILED"
}

inbox_unreadable() {  # <what> <error-file>
  local what=$1 err=$2
  {
    printf 'fm-order: THE INBOX AT %s COULD NOT BE READ.\n' "$INBOX"
    printf '  %s\n' "$what"
    printf '  error: %s\n' "$(sed -e 's/^[[:space:]]*//' "$err" 2>/dev/null | grep -v '^$' | head -3 | tr '\n' ' ')"
    printf '  Treat this as lost captain requests, not as an empty inbox. Repair it before\n'
    printf '  telling the captain anything about what is or is not recorded.\n'
  } >&2
  exit "$FM_ORDER_RC_INBOX_UNREADABLE"
}

# THESE READERS RETURN A PATH IN A GLOBAL, NOT ON STDOUT, AND MUST BE CALLED AS PLAIN
# COMMANDS - never inside $( ). bash does not carry errexit out of a command substitution:
# a reader that exits 5 inside `x=$(reader)` leaves the enclosing function running with an
# empty result, so the failure re-emerges later as a different, wronger error - which is
# how an unreadable inbox came back reported as a reader crash while this fix was being
# written. Failing in the top-level shell is what makes each failure exit as itself.
FOLD_PATH=''
HEALTH_PATH=''
LIST_PATH=''

# Fold the ledger into a scratch file. The fold reads the inbox as a file, so it streams; a
# single malformed row is skipped and counted by fm_order_health, and only a failure to
# read the file at all is fatal here.
fold_file() {  # sets FOLD_PATH
  [ -n "$FOLD_PATH" ] && return 0
  fm_order_fold "$INBOX" > "$SCRATCH/fold.json" 2> "$SCRATCH/fold.err" \
    || inbox_unreadable 'the append-only ledger could not be folded' "$SCRATCH/fold.err"
  FOLD_PATH=$SCRATCH/fold.json
}

health_file() {  # sets HEALTH_PATH
  [ -n "$HEALTH_PATH" ] && return 0
  fm_order_health "$INBOX" > "$SCRATCH/health.json" 2> "$SCRATCH/health.err" \
    || inbox_unreadable 'the inbox health scan could not read the ledger' "$SCRATCH/health.err"
  HEALTH_PATH=$SCRATCH/health.json
}

# Build the enriched order list into a scratch file: every folded order plus its age, its
# attention state, and the inbox's own health. The attention rules are the operational
# definition of "still waiting on firstmate", and mirror the spec's rule that an order stays
# visible until it has real lineage or a meaningful disposition.
list_file() {  # sets LIST_PATH
  local now
  [ -n "$LIST_PATH" ] && return 0
  now=$(now_ts)
  fold_file
  health_file
  pending_json > "$SCRATCH/pending.json" 2> "$SCRATCH/pending.err" \
    || read_failed 'the pending chat-capture spool could not be listed' "$SCRATCH/pending.err"
  # Every inbox-derived payload arrives by file. --slurpfile wraps each in an array, hence
  # the [0]; the alternative - argv - is what broke every read path on a real inbox.
  jq -n \
    --arg schema 'fm-captain-orders/v1' \
    --arg inbox "$INBOX" \
    --arg now "$now" \
    --argjson stale "$STALE_SECS" \
    --slurpfile pendingf "$SCRATCH/pending.json" \
    --slurpfile healthf "$HEALTH_PATH" \
    --slurpfile foldf "$FOLD_PATH" '
    ($pendingf[0] // []) as $pending
    | ($healthf[0] // {}) as $health
    | ($foldf[0] // {}) as $fold
    |
    # A review condition may be a full timestamp, a plain date, or an English condition
    # ("when the captain approves"). Only the first two can expire on their own; a
    # condition that cannot be parsed as a time never silently expires, it just never
    # ages - which is why a hold ALSO carries a reason a human can act on.
    def age($ts):
      if ($ts // "") == "" then null
      else (($ts | if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") then . + "T00:00:00Z" else . end)
            | try (fromdateiso8601 | ($now | fromdateiso8601) - .) catch null) end;

    # Backstop for a row that reached the ledger without going through this writer.
    def lineage_ok:
      (.status // "received") as $s
      | (((.linked_task_ids // []) + (.linked_scout_ids // [])
          + (.linked_bug_ids // []) + (.related_order_ids // [])) | length > 0) as $linked
      | if $s == "dispatched" then $linked
        elif $s == "completed" or $s == "superseded" then ((.outcome_link // "") != "")
        elif $s == "rejected" then ((.outcome_reason // "") != "")
        elif $s == "blocked" or $s == "needs_clarification" or $s == "captain_decision"
          then ((.hold_reason // "") != "")
        elif $s == "held" then ((.hold_reason // "") != "" and (.review_after // "") != "")
        else true end;

    def terminal: (.status // "received") | . == "completed" or . == "superseded" or . == "rejected";

    ($fold | to_entries | map(.value)) as $orders
    | ($orders | map({key: .order_id, value: (.status // "received")}) | from_entries) as $status_by_id
    | [ $orders[]
        | . as $o
        | age(.received_at) as $a
        # Most actionable first: the leading reason is what the order is waiting on, and
        # what the digest and the triage lane both name.
        | ([ (if ((.status // "received") == "received" or (.status // "") == "triaging")
              then "untriaged" else empty end),
             (if (lineage_ok | not) then "missing_lineage" else empty end),
             # A blocked order whose blocking orders are all finished is free to move, and
             # nothing else will notice that on its behalf.
             (if (.status // "") == "blocked"
                 and ((.dependency_ids // []) | length) > 0
                 and (([ (.dependency_ids // [])[]
                         | $status_by_id[.] // "missing" ]
                       | map(select(. == "completed" or . == "superseded" or . == "rejected"))
                       | length) == ((.dependency_ids // []) | length))
              then "blocker_cleared" else empty end),
             (if (.status // "") == "held"
                 and ((.review_after // "") != "")
                 and (age(.review_after) as $r | $r != null and $r >= 0)
              then "hold_expired" else empty end),
             # Only DISPATCHED work must have an owner. Queued, held, and blocked orders
             # are legitimately unowned - nobody is working them, and that is the point.
             (if (.status // "") == "dispatched" and ((.owner // "") == "")
              then "ownerless" else empty end),
             (if (terminal | not) and $a != null and $a > $stale
              then "stale" else empty end) ]) as $reasons
        | $o + {
            age_seconds: ($a // 0),
            attention_reasons: $reasons,
            attention: ($reasons[0] // "ok"),
            actionable: (($reasons | length) > 0)
          } ]
    | sort_by(.received_at, .order_id) as $all
    | {schema: $schema,
       inbox: $inbox,
       generated_at: $now,
       health: $health,
       pending_chat_captures: ($pending | length),
       metrics: {
         total: ($all | length),
         actionable: ($all | map(select(.actionable)) | length),
         untriaged: ($all | map(select(.attention_reasons | index("untriaged"))) | length),
         oldest_untriaged_age_seconds:
           (($all | map(select(.attention_reasons | index("untriaged")) | .age_seconds) | max) // 0),
         ownerless: ($all | map(select(.attention_reasons | index("ownerless"))) | length),
         queued: ($all | map(select(.status == "queued")) | length),
         dispatched: ($all | map(select(.status == "dispatched")) | length),
         blocked: ($all | map(select(.status == "blocked")) | length),
         held: ($all | map(select(.status == "held")) | length),
         needs_clarification: ($all | map(select(.status == "needs_clarification")) | length),
         captain_decision: ($all | map(select(.status == "captain_decision")) | length),
         completed: ($all | map(select(.status == "completed")) | length),
         rejected: ($all | map(select(.status == "rejected")) | length),
         superseded: ($all | map(select(.status == "superseded")) | length),
         duplicate_deliveries: ($all | map(.duplicate_delivery_count // 0) | add // 0),
         pending_chat_captures: ($pending | length),
         by_attention: ($all | map(select(.actionable) | .attention) | group_by(.)
                        | map({key: .[0], value: length}) | from_entries)
       },
       orders: $all}
  ' > "$SCRATCH/list.json" 2> "$SCRATCH/list.err" \
    || read_failed 'the folded inbox could not be enriched into the order list' "$SCRATCH/list.err"
  LIST_PATH=$SCRATCH/list.json
}

pending_json() {
  local f
  [ -d "$PENDING_DIR" ] || { printf '[]'; return 0; }
  {
    for f in "$PENDING_DIR"/*.json; do
      [ -f "$f" ] || continue
      jq -c --arg id "$(basename "$f" .json)" '. + {capture_id: $id}' "$f" 2>/dev/null || true
    done
  } | jq -sc 'sort_by(.captured_at // "")'
}

# --- verbs ---------------------------------------------------------------------------

VERB=${1:-}
case "$VERB" in
  -h|--help|'') usage; exit 0 ;;
  *) shift ;;
esac

# Reading the captain order inbox stays available to every role; every WRITE verb is a
# primary-only mutation. (bin/fm-role-context-lib.sh is sourced near the top.)
case "$VERB" in
  path|list|show|digest|metrics|pending|health) ;;
  *) fm_require_primary "fm-order.sh $VERB" || exit 2 ;;
esac

case "$VERB" in
  path)
    printf '%s\n' "$INBOX"
    exit 0
    ;;

  init)
    if [ -f "$INBOX" ]; then
      printf 'inbox already exists: %s\n' "$INBOX"
      exit 0
    fi
    mkdir -p "$PENDING_DIR" || die "cannot create $PENDING_DIR"
    FM_ORDER_QUIET_INIT=1 ensure_inbox_for_write
    printf 'initialized: %s\n' "$INBOX"
    exit 0
    ;;

  health)
    fm_order_health "$INBOX" | jq .
    exit 0
    ;;

  add)
    SOURCE=chat
    KEY=''
    PRIORITY=normal
    PRIORITY_SOURCE=default
    PROJECT=''
    TITLE=''
    RECEIVED_AT=''
    FROM_PENDING=''
    REQUESTS=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --source) SOURCE=${2:?missing value for --source}; shift 2 ;;
        --idempotency-key) KEY=${2:?missing value for --idempotency-key}; shift 2 ;;
        --priority) PRIORITY=${2:?missing value for --priority}; shift 2 ;;
        --priority-source) PRIORITY_SOURCE=${2:?missing value for --priority-source}; shift 2 ;;
        --project) PROJECT=${2:?missing value for --project}; shift 2 ;;
        --title) TITLE=${2:?missing value for --title}; shift 2 ;;
        --received-at) RECEIVED_AT=${2:?missing value for --received-at}; shift 2 ;;
        --from-pending) FROM_PENDING=${2:?missing value for --from-pending}; shift 2 ;;
        -*) usage >&2; die "unknown option: $1" 2 ;;
        *) REQUESTS+=("$1"); shift ;;
      esac
    done

    PENDING_FILE=''
    if [ -n "$FROM_PENDING" ]; then
      PENDING_FILE="$PENDING_DIR/$FROM_PENDING.json"
      [ -f "$PENDING_FILE" ] || die "no pending capture $FROM_PENDING in $PENDING_DIR" 2
      [ "${#REQUESTS[@]}" -eq 0 ] \
        || die 'refused: --from-pending records the captured text verbatim; do not also pass a request' 2
      REQUESTS+=("$(jq -r '.text // ""' "$PENDING_FILE")")
      [ -n "${REQUESTS[0]}" ] || die "pending capture $FROM_PENDING has no text" 1
      # The capture id is the idempotency key: re-draining the same capture cannot mint a
      # second order, however many times a restart or a retry replays it.
      [ -n "$KEY" ] || KEY=$FROM_PENDING
      SOURCE=$(jq -r '.source // "chat"' "$PENDING_FILE")
      [ -n "$RECEIVED_AT" ] || RECEIVED_AT=$(jq -r '.captured_at // ""' "$PENDING_FILE")
    fi

    [ "${#REQUESTS[@]}" -gt 0 ] || die 'no request text given' 2
    [ "${#REQUESTS[@]}" -eq 1 ] || [ -z "$KEY" ] \
      || die 'refused: --idempotency-key applies to a single request, not a burst' 2

    ensure_inbox_for_write
    mkdir -p "$PENDING_DIR" 2>/dev/null || true
    lock_or_die

    fold_file
    FOLD=$(cat "$FOLD_PATH")
    # Mint ids above every id the ledger has ever used, including one carried by a row the
    # fold had to skip: reusing an id from a malformed row would fuse two captain requests.
    MAX=$(
      {
        printf '%s' "$FOLD" | jq -r 'keys[]'
        grep -o '"order_id"[[:space:]]*:[[:space:]]*"ORD-[0-9]*"' "$INBOX" 2>/dev/null \
          | grep -o 'ORD-[0-9]*' || true
      } | sed -n 's/^ORD-0*\([0-9][0-9]*\)$/\1/p' | sort -n | tail -1
    )
    [ -n "$MAX" ] || MAX=0

    NOW=$(now_ts)
    FAILED=0
    RECORDED=()
    for req in "${REQUESTS[@]}"; do
      [ -n "$req" ] || { printf 'FAILED (empty request text)\n' >&2; FAILED=1; continue; }
      ikey=$(fm_order_idempotency_key "$SOURCE" "$req" "$KEY")
      existing=$(printf '%s' "$FOLD" \
        | jq -r --arg k "$ikey" 'to_entries[] | select(.value.idempotency_key == $k) | .key' \
        | head -1)
      rts=${RECEIVED_AT:-$NOW}
      # A --from-pending request is FILE content, not a command-line argument: a captain who
      # pastes a long spec into chat produces one, and it is not bounded by anything argv is.
      # It reaches jq by file for the same reason the fold does.
      printf '%s' "$req" > "$SCRATCH/request.txt" \
        || die 'cannot stage the request text; NOTHING was recorded' 1

      if [ -n "$existing" ]; then
        # Duplicate delivery: link to the order that already holds this request and keep
        # the new arrival as evidence. Never mint a second order, never overwrite the first.
        row=$(jq -cn --arg schema "$FM_ORDER_SCHEMA" --arg id "$existing" \
          --arg ts "$NOW" --arg source "$SOURCE" --rawfile req "$SCRATCH/request.txt" --arg by "$ACTOR" \
          '{schema: $schema, order_id: $id, event: "duplicate_delivery", ts: $ts,
            source: $source, original_request: $req, recorded_by: $by}')
        if append_event "$row"; then
          printf 'duplicate: %s (already recorded; new delivery linked, no second order)\n' "$existing"
        else
          printf 'FAILED to record duplicate delivery of %s\n' "$existing" >&2
          FAILED=1
        fi
        continue
      fi

      MAX=$((MAX + 1))
      oid=$(printf 'ORD-%03d' "$MAX")
      row=$(jq -cn \
        --arg schema "$FM_ORDER_SCHEMA" \
        --arg id "$oid" \
        --arg ts "$rts" \
        --arg updated "$NOW" \
        --arg source "$SOURCE" \
        --arg key "$ikey" \
        --rawfile req "$SCRATCH/request.txt" \
        --arg title "$TITLE" \
        --arg project "$PROJECT" \
        --arg priority "$PRIORITY" \
        --arg psource "$PRIORITY_SOURCE" \
        --arg by "$ACTOR" '
        {schema: $schema, order_id: $id, event: "received", ts: $updated,
         schema_version: $schema,
         received_at: $ts, source: $source, source_message_id: null,
         idempotency_key: $key, original_request: $req,
         short_title: (if $title == "" then null else $title end),
         project_or_ship: (if $project == "" then null else $project end),
         priority: $priority, priority_source: $psource,
         status: "received", owner: null,
         related_order_ids: [], dependency_ids: [],
         linked_task_ids: [], linked_scout_ids: [], linked_bug_ids: [],
         hold_reason: null, review_after: null, captain_decision_required: false,
         outcome_type: null, outcome_link: null, outcome_reason: null,
         recorded_by: $by, updated_at: $updated}')
      if append_event "$row"; then
        RECORDED+=("$oid")
        # The row carries the captain's request text, so it is as unbounded as the request
        # is: --argjson here would put a pasted spec into an argument list and kill the
        # intake it just durably recorded. The fold is updated in memory rather than
        # re-folded, so a burst of N requests stays O(N) instead of O(N^2).
        printf '%s\n' "$row" > "$SCRATCH/row.json" \
          || die "recorded $oid but could not stage its row; re-run to re-fold" 1
        FOLD=$(printf '%s' "$FOLD" \
          | jq -c --arg id "$oid" --slurpfile row "$SCRATCH/row.json" '. + {($id): $row[0]}')
        printf 'recorded: %s\n' "$oid"
      else
        printf 'FAILED to record request: %s\n' "$(printf '%s' "$req" | cut -c1-60)" >&2
        FAILED=1
      fi
    done

    # The capture is only drained once its order is durably on disk and verified.
    if [ -n "$PENDING_FILE" ] && [ "$FAILED" -eq 0 ]; then
      rm -f "$PENDING_FILE"
    fi

    fm_order_unlock

    if [ "$FAILED" -ne 0 ]; then
      printf 'fm-order: INTAKE FAILED for at least one request; %d recorded (%s).\n' \
        "${#RECORDED[@]}" "${RECORDED[*]:-none}" >&2
      printf 'fm-order: the failed request(s) are NOT durably recorded - do not acknowledge them.\n' >&2
      exit 1
    fi
    exit 0
    ;;

  pending)
    JSON=false
    [ "${1:-}" = --json ] && JSON=true
    if [ "$JSON" = true ]; then
      pending_json | jq .
      exit 0
    fi
    COUNT=$(pending_json | jq 'length')
    if [ "$COUNT" -eq 0 ]; then
      printf 'no undrained captain chat captures\n'
      exit 0
    fi
    pending_json | jq -r '.[] | "- " + .capture_id + " (" + (.captured_at // "?") + "): "
                          + ((.text // "") | gsub("[[:space:]]+"; " ") | .[0:100])'
    exit 0
    ;;

  dismiss)
    CAPTURE=${1:-}
    [ -n "$CAPTURE" ] || die 'dismiss requires a capture id' 2
    shift
    REASON=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --reason) REASON=${2:?missing value for --reason}; shift 2 ;;
        *) usage >&2; die "unknown option: $1" 2 ;;
      esac
    done
    [ -n "$REASON" ] \
      || die 'refused: dismissing a captured captain message requires --reason; a silent drop is how a request gets lost' 2
    FILE="$PENDING_DIR/$CAPTURE.json"
    [ -f "$FILE" ] || die "no pending capture $CAPTURE in $PENDING_DIR" 2
    mkdir -p "$(dirname "$DISMISSED")"
    row=$(jq -c --arg schema "$FM_ORDER_DISMISS_SCHEMA" --arg id "$CAPTURE" \
      --arg ts "$(now_ts)" --arg reason "$REASON" --arg by "$ACTOR" \
      '{schema: $schema, capture_id: $id, dismissed_at: $ts, reason: $reason,
        dismissed_by: $by, captured_at: (.captured_at // null), source: (.source // null),
        text: (.text // null)}' "$FILE")
    printf '%s\n' "$row" >> "$DISMISSED" || die "cannot write $DISMISSED"
    [ "$(tail -1 "$DISMISSED")" = "$row" ] || die "could not verify the dismissal write in $DISMISSED"
    rm -f "$FILE"
    printf 'dismissed: %s (%s)\n' "$CAPTURE" "$REASON"
    exit 0
    ;;

  list)
    require_inbox
    JSON=false
    ONLY_ACTIONABLE=false
    STATUS=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --json) JSON=true; shift ;;
        --actionable) ONLY_ACTIONABLE=true; shift ;;
        --status) STATUS=${2:?missing value for --status}; shift 2 ;;
        *) usage >&2; die "unknown option: $1" 2 ;;
      esac
    done
    list_file
    # `$act | not or .actionable` parses as `($act | not) or ($act | .actionable)`: the
    # whole pipe body sees $act, so with --actionable the second branch indexed a boolean
    # and the filter died. Without --actionable the first branch was true and short-circuited,
    # so the broken half never ran and the flag looked fine right up until someone used it.
    if [ "$JSON" = true ]; then
      jq --argjson act "$ONLY_ACTIONABLE" --arg status "$STATUS" '
        .orders |= (map(select(($act | not) or .actionable))
                    | map(select($status == "" or .status == $status)))' "$LIST_PATH"
      exit 0
    fi
    jq -r --argjson act "$ONLY_ACTIONABLE" --arg status "$STATUS" '
      .orders[]
      | select(($act | not) or .actionable)
      | select($status == "" or .status == $status)
      | "- " + .order_id + " [" + (.status // "received") + "]"
        + (if .attention != "ok" then " !" + .attention else "" end)
        + " " + ((.short_title // .original_request) | gsub("[[:space:]]+"; " ") | .[0:80])' \
      "$LIST_PATH"
    exit 0
    ;;

  show)
    require_inbox
    ID=${1:-}
    [ -n "$ID" ] || die 'show requires an order id' 2
    shift
    HISTORY=false
    JSON=false
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --history) HISTORY=true; shift ;;
        --json) JSON=true; shift ;;
        *) usage >&2; die "unknown option: $1" 2 ;;
      esac
    done
    # Build the read, then filter it. A `list_json | jq` pipeline would swallow a reader
    # failure into an empty result, and an empty result here means "no such order" - which is
    # how a broken reader gets to say the captain never asked for anything.
    list_file
    REC=$(jq --arg id "$ID" '.orders[] | select(.order_id == $id)' "$LIST_PATH")
    [ -n "$REC" ] || die "no such order: $ID" 2
    if [ "$JSON" = true ]; then
      printf '%s\n' "$REC" | jq .
    else
      printf '%s\n' "$REC" | jq -r '
        "order:    " + .order_id,
        "status:   " + (.status // "received")
          + (if .attention != "ok" then "  (!" + .attention + ")" else "" end),
        "received: " + (.received_at // "?") + "  via " + (.source // "?"),
        "priority: " + (.priority // "normal") + " (" + (.priority_source // "default") + ")",
        "owner:    " + (.owner // "-"),
        "links:    tasks=" + ((.linked_task_ids // []) | join(",") | if . == "" then "-" else . end)
          + " scouts=" + ((.linked_scout_ids // []) | join(",") | if . == "" then "-" else . end)
          + " bugs=" + ((.linked_bug_ids // []) | join(",") | if . == "" then "-" else . end)
          + " orders=" + ((.related_order_ids // []) | join(",") | if . == "" then "-" else . end),
        "outcome:  " + (.outcome_type // "-")
          + (if (.outcome_link // "") != "" then " -> " + .outcome_link else "" end)
          + (if (.outcome_reason // "") != "" then " (" + .outcome_reason + ")" else "" end),
        "",
        "captain original request (verbatim):",
        (.original_request // "")'
    fi
    if [ "$HISTORY" = true ]; then
      printf '\nhistory (append-only, oldest first):\n'
      jq -c --arg id "$ID" 'select(.order_id == $id)' "$INBOX" 2>/dev/null \
        | jq -r '"  " + .ts + "  " + .event
                 + (if (.status // "") != "" then " -> " + .status else "" end)'
    fi
    exit 0
    ;;

  ack)
    require_inbox
    [ "$#" -gt 0 ] || die 'ack requires at least one order id' 2
    list_file
    printf 'Recorded:\n'
    for id in "$@"; do
      line=$(jq -r --arg id "$id" '
        .orders[] | select(.order_id == $id)
        | "- " + .order_id + " - "
          + ((.short_title // .original_request) | gsub("[[:space:]]+"; " ") | .[0:70])
          + " - " + (.status // "received")
          + (if (.priority // "normal") != "normal" then " - " + .priority else "" end)
          + (if .captain_decision_required then " - needs your decision" else "" end)' \
        "$LIST_PATH")
      [ -n "$line" ] || die "cannot acknowledge $id: it is not in the inbox, so it is NOT recorded" 1
      printf '%s\n' "$line"
    done
    exit 0
    ;;

  digest)
    require_inbox
    list_file
    jq -r '
      def dur($s): if $s == null or $s < 60 then "new"
                   elif $s < 3600 then (($s / 60 | floor | tostring) + "m")
                   elif $s < 86400 then (($s / 3600 | floor | tostring) + "h")
                   else (($s / 86400 | floor | tostring) + "d") end;
      .metrics as $m
      | ["CAPTAIN ORDERS: " + ($m.actionable | tostring) + " needing action, "
          + ($m.total | tostring) + " total",
         "  untriaged: " + ($m.untriaged | tostring)
           + (if $m.untriaged > 0
              then " (oldest " + dur($m.oldest_untriaged_age_seconds) + ")" else "" end)
           + " | ownerless: " + ($m.ownerless | tostring)
           + " | captain decision: " + ($m.captain_decision | tostring)
           + " | undrained chat captures: " + ($m.pending_chat_captures | tostring)]
      + (if .health.malformed_rows > 0
         then ["  INBOX HEALTH: " + (.health.malformed_rows | tostring) + " malformed of "
               + (.health.total_rows | tostring) + " rows in " + .inbox
               + " (first at line " + ((.health.rows[0].line // 0) | tostring) + ")"]
         else [] end)
      + [ .orders[]
          | select(.actionable or (.status | IN("queued","dispatched","blocked","held",
                                                "needs_clarification","captain_decision")))
          | "",
            "- " + .order_id + " - "
              + ((.short_title // .original_request) | gsub("[[:space:]]+"; " ") | .[0:70]),
            "  " + (.status // "received") + "; " + (.priority // "normal") + " priority"
              + "; owner " + (.owner // "none")
              + (((.linked_task_ids // []) + (.linked_scout_ids // []) + (.linked_bug_ids // []))
                 as $l | if ($l | length) > 0 then "; linked " + ($l | join(", ")) else "" end)
              + (if (.hold_reason // "") != "" then "; " + .hold_reason else "" end)
              + (if .attention != "ok" then "; NEEDS ATTENTION: " + (.attention_reasons | join(", ")) else "" end)
              + (if .captain_decision_required then "; CAPTAIN INPUT NEEDED" else "" end) ]
      | .[]' "$LIST_PATH"
    exit 0
    ;;

  metrics)
    require_inbox
    list_file
    if [ "${1:-}" = --json ]; then
      jq '{inbox, generated_at, health, metrics}' "$LIST_PATH"
    else
      jq -r '.metrics | to_entries[] | select(.value | type != "object")
             | "  " + .key + ": " + (.value | tostring)' "$LIST_PATH"
    fi
    exit 0
    ;;
esac

# --- lifecycle verbs (everything below mutates one existing order) --------------------

ID=${1:-}
[ -n "$ID" ] || { usage >&2; die "$VERB requires an order id" 2; }
shift

OWNER=''
LINK=''
REASON=''
REVIEW_AFTER=''
TITLE=''
PROJECT=''
PRIORITY=''
PRIORITY_SOURCE=''
BY=''
TASKS=()
SCOUTS=()
BUGS=()
ORDERS=()
DEPS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --owner) OWNER=${2:?missing value for --owner}; shift 2 ;;
    --link) LINK=${2:?missing value for --link}; shift 2 ;;
    --reason) REASON=${2:?missing value for --reason}; shift 2 ;;
    --review-after) REVIEW_AFTER=${2:?missing value for --review-after}; shift 2 ;;
    --title) TITLE=${2:?missing value for --title}; shift 2 ;;
    --project) PROJECT=${2:?missing value for --project}; shift 2 ;;
    --priority) PRIORITY=${2:?missing value for --priority}; shift 2 ;;
    --priority-source) PRIORITY_SOURCE=${2:?missing value for --priority-source}; shift 2 ;;
    --task) TASKS+=("${2:?missing value for --task}"); shift 2 ;;
    --scout) SCOUTS+=("${2:?missing value for --scout}"); shift 2 ;;
    --bug) BUGS+=("${2:?missing value for --bug}"); shift 2 ;;
    --order) ORDERS+=("${2:?missing value for --order}"); shift 2 ;;
    --by) BY=${2:?missing value for --by}; shift 2 ;;
    --of) BY=${2:?missing value for --of}; shift 2 ;;
    --depends-on) DEPS+=("${2:?missing value for --depends-on}"); shift 2 ;;
    -*) usage >&2; die "unknown option: $1" 2 ;;
    *) usage >&2; die "unexpected argument: $1" 2 ;;
  esac
done

require_inbox
fold_file
CURRENT=$(jq -c --arg id "$ID" '.[$id] // empty' "$FOLD_PATH")
[ -n "$CURRENT" ] || die "no such order: $ID" 2

STATUS=''
case "$VERB" in
  triage) STATUS=triaging ;;
  queue) STATUS=queued ;;
  claim) STATUS='' ;;
  release) STATUS='' ;;
  link) STATUS='' ;;
  dispatch) STATUS=dispatched ;;
  block) STATUS=blocked ;;
  hold) STATUS=held ;;
  clarify) STATUS=needs_clarification ;;
  decision) STATUS=captain_decision ;;
  supersede|duplicate) STATUS=superseded ;;
  reject) STATUS=rejected ;;
  complete) STATUS=completed ;;
  *) usage >&2; die "unknown command: $VERB" 2 ;;
esac

# Shorthands and per-verb argument contracts.
case "$VERB" in
  claim) [ -n "$OWNER" ] || die 'refused: claim requires --owner' 2 ;;
  duplicate)
    [ -n "$BY" ] || die 'refused: duplicate requires --of <order-id>' 2
    LINK=$BY
    ORDERS+=("$BY")
    [ -n "$REASON" ] || REASON="duplicate of $BY"
    ;;
  supersede)
    [ -n "$BY" ] || die 'refused: supersede requires --by <order-id>' 2
    LINK=$BY
    ORDERS+=("$BY")
    ;;
  dispatch)
    [ "${#TASKS[@]}" -gt 0 ] || [ "${#SCOUTS[@]}" -gt 0 ] || [ "${#BUGS[@]}" -gt 0 ] \
      || die 'refused: dispatch must name the work it created (--task, --scout, or --bug); an order dispatched to nothing has no lineage' 2
    ;;
  block)
    [ -n "$REASON" ] || die 'refused: block requires --reason' 2
    ;;
esac

# The lineage contract, owned by fm-order-lib.sh. This is what stops an order from being
# "handled" because it was seen: a terminal status with nothing to point at is refused.
if [ -n "$STATUS" ] && REQ=$(fm_order_status_requires "$STATUS"); then
  for field in $REQ; do
    case "$field" in
      lineage) : ;;  # already enforced per verb above
      outcome_link)
        [ -n "$LINK" ] \
          || die "refused: status '$STATUS' requires --link naming its outcome; an outcome without a link is not a disposition" 2
        ;;
      outcome_reason|hold_reason)
        [ -n "$REASON" ] || die "refused: status '$STATUS' requires --reason" 2
        ;;
      review_after)
        [ -n "$REVIEW_AFTER" ] \
          || die 'refused: a hold requires --review-after (a date or an explicit unblock condition); a silent indefinite hold is not a disposition' 2
        ;;
    esac
  done
fi

lock_or_die
NOW=$(now_ts)

ROW=$(printf '%s' "$CURRENT" | jq -c \
  --arg schema "$FM_ORDER_SCHEMA" \
  --arg id "$ID" \
  --arg event "$VERB" \
  --arg ts "$NOW" \
  --arg status "$STATUS" \
  --arg owner "$OWNER" \
  --arg link "$LINK" \
  --arg reason "$REASON" \
  --arg review "$REVIEW_AFTER" \
  --arg title "$TITLE" \
  --arg project "$PROJECT" \
  --arg priority "$PRIORITY" \
  --arg psource "$PRIORITY_SOURCE" \
  --arg by "$ACTOR" \
  --argjson tasks "$(printf '%s\n' "${TASKS[@]:-}" | jq -Rn '[inputs | select(. != "")]')" \
  --argjson scouts "$(printf '%s\n' "${SCOUTS[@]:-}" | jq -Rn '[inputs | select(. != "")]')" \
  --argjson bugs "$(printf '%s\n' "${BUGS[@]:-}" | jq -Rn '[inputs | select(. != "")]')" \
  --argjson orders "$(printf '%s\n' "${ORDERS[@]:-}" | jq -Rn '[inputs | select(. != "")]')" \
  --argjson deps "$(printf '%s\n' "${DEPS[@]:-}" | jq -Rn '[inputs | select(. != "")]')" '
  . as $cur
  | {schema: $schema, order_id: $id, event: $event, ts: $ts,
     recorded_by: $by, updated_at: $ts}
  + (if $status == "" then {} else {status: $status} end)
  # Links accumulate; an event never drops lineage another event established.
  + (if ($tasks | length) > 0
     then {linked_task_ids: (($cur.linked_task_ids // []) + $tasks | unique)} else {} end)
  + (if ($scouts | length) > 0
     then {linked_scout_ids: (($cur.linked_scout_ids // []) + $scouts | unique)} else {} end)
  + (if ($bugs | length) > 0
     then {linked_bug_ids: (($cur.linked_bug_ids // []) + $bugs | unique)} else {} end)
  + (if ($orders | length) > 0
     then {related_order_ids: (($cur.related_order_ids // []) + $orders | unique)} else {} end)
  + (if ($deps | length) > 0
     then {dependency_ids: (($cur.dependency_ids // []) + $deps | unique)} else {} end)
  + (if $title == "" then {} else {short_title: $title} end)
  + (if $project == "" then {} else {project_or_ship: $project} end)
  + (if $priority == "" then {} else {priority: $priority} end)
  + (if $psource == "" then {} else {priority_source: $psource} end)
  + (if $event == "claim" then {owner: $owner, claimed_at: $ts} else {} end)
  # An explicit null IS the update: the fold accumulates, so release must overwrite the
  # owner rather than merely omit it.
  + (if $event == "release" then {owner: null, claimed_at: null} else {} end)
  + (if $event == "hold" then {hold_reason: $reason, review_after: $review}
     elif $event == "block" or $event == "clarify" or $event == "decision"
       then {hold_reason: $reason}
     else {} end)
  + (if $event == "decision" then {captain_decision_required: true} else {} end)
  # A finished order carries its own decision, and stops carrying a live claim.
  + (if $status == "completed" or $status == "superseded" or $status == "rejected"
     then {outcome_type: $status, outcome_link: (if $link == "" then null else $link end),
           outcome_reason: (if $reason == "" then null else $reason end),
           decided_at: $ts, decided_by: $by, owner: null, claimed_at: null,
           captain_decision_required: false}
     else {} end)')

if ! append_event "$ROW"; then
  fm_order_unlock
  die "INTAKE/UPDATE FAILED: could not durably record '$VERB' for $ID; nothing was acknowledged" 1
fi

fm_order_unlock

printf 'recorded: %s %s' "$VERB" "$ID"
[ -n "$STATUS" ] && printf ' -> %s' "$STATUS"
[ -n "$LINK" ] && printf ' (%s)' "$LINK"
printf '\n'
exit 0

#!/usr/bin/env bash
# Shared path, lock, fold, and contract helpers for the Captain Order Inbox: the
# durable record of every captain request, written only by bin/fm-order.sh and read
# by bin/fm-order-duty.sh and the fleet-triage enumerator's captain_orders lane.
#
# THE INBOX
# The inbox is an append-only JSONL event ledger of firstmate/captain-order/v1 records,
# folded at read into one current record per order_id. It is authoritative for whether a
# captain request was received and what became of it. Nothing else is: not chat history,
# not a transcript, not a note.
#
# WHY IT DOES NOT LIVE IN THE REPO
# data/ is gitignored state INSIDE a git checkout, so its lifetime is tied to that
# checkout: a `git clean -xfd`, a re-clone, a worktree teardown, or a home relocation
# takes it with them. That is exactly the class of mistake that put the captain bug
# ledger at risk earlier (it was pinned out to a fleet-level path for the same reason).
# Captain orders are durable operational state, so the inbox defaults OUTSIDE any
# checkout, under the XDG state home, keyed per firstmate installation:
#
#   ${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/<home-tag>/captain-orders.jsonl
#
# The home tag comes from fm-backend-hometag-lib.sh, the repo's existing per-installation
# discriminator, so a primary and its secondmates - and two primaries on one machine -
# never share an inbox. Resolution order, highest first:
#
#   1. FM_ORDERS_PATH            explicit absolute path (tests, and a captain who wants one)
#   2. $FM_HOME/config/orders-path   local, gitignored pointer file holding a path
#   3. the default above
#
# Only the pointer is configurable; the DATA never lives in the repo. A relocated home
# resolves to a new tag and therefore a new path, so the inbox appears missing rather
# than merely empty - which is why every read of a missing inbox fails loudly instead of
# folding to zero orders (bin/fm-order.sh refuses every read of a missing inbox).
#
# CONCURRENCY
# The writer is not the session-lock holder: a captain must be able to record an order
# from any shell without a firstmate turn. Writes therefore serialize on a dedicated
# writer lock beside the inbox (fm_order_lock), which is what protects the id sequence
# from minting duplicates and an update from being lost. Reads take no lock; a fold of a
# partially-written tail simply skips the malformed row and reports it as a defect.

[ -n "${FM_ORDER_LIB_SOURCED:-}" ] && return 0
FM_ORDER_LIB_SOURCED=1

_FM_ORDER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# fm_triage_hash, fm_triage_now, and fm_triage_epoch are generic, already portable, and
# already the repo's one implementation of each. Reusing them is deliberate; a second
# copy would drift.
# shellcheck disable=SC1091 # Dynamic sibling path is resolved from BASH_SOURCE.
. "$_FM_ORDER_LIB_DIR/fm-fleet-triage-lib.sh"

# Consumed by bin/fm-order.sh, which sources this library.
# shellcheck disable=SC2034 # Consumed by sourcing scripts, not by this library.
FM_ORDER_SCHEMA='firstmate/captain-order/v1'
# shellcheck disable=SC2034 # Consumed by sourcing scripts, not by this library.
FM_ORDER_DISMISS_SCHEMA='firstmate/captain-chat-dismissed/v1'

# Print the inbox path for this home, per the resolution order in the header.
fm_order_inbox_path() {  # <fm-home>
  local home=$1 pointer configured state tag
  if [ -n "${FM_ORDERS_PATH:-}" ]; then
    printf '%s' "$FM_ORDERS_PATH"
    return 0
  fi
  pointer="${FM_CONFIG_OVERRIDE:-$home/config}/orders-path"
  if [ -f "$pointer" ]; then
    configured=$(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$pointer" \
      | grep -v '^$' | head -1)
    if [ -n "$configured" ]; then
      # A leading tilde in the pointer file is data, not shell syntax, so expand it here.
      configured=${configured/#\~\//$HOME/}
      printf '%s' "$configured"
      return 0
    fi
  fi
  state=${XDG_STATE_HOME:-$HOME/.local/state}
  tag=$(fm_order_hometag "$home")
  printf '%s/firstmate/%s/captain-orders.jsonl' "$state" "$tag"
}

# Print a home's installation tag, reusing the backend home-tag derivation (a readable
# prefix plus a short hash of the home path) so a primary, its secondmates, and a second
# primary on the same machine never share one inbox. Both FM_HOME and FM_ROOT are pinned
# to the home here, which is what makes the tag identify the HOME rather than the repo
# checkout the scripts happen to be running from.
fm_order_hometag() {  # <fm-home>
  # shellcheck disable=SC2034 # Both are read by fm_backend_hometag through dynamic scope.
  local FM_HOME=$1 FM_ROOT=$1 tag
  # shellcheck disable=SC1091 # Dynamic sibling path is resolved from BASH_SOURCE.
  . "$_FM_ORDER_LIB_DIR/fm-backend-hometag-lib.sh"
  tag=$(fm_backend_hometag 2>/dev/null || true)
  [ -n "$tag" ] || tag=firstmate
  printf '%s' "$tag"
}

# Print the sibling paths derived from the inbox path.
fm_order_pending_dir() {  # <inbox>
  printf '%s/pending' "$(dirname "$1")"
}

fm_order_dismissed_path() {  # <inbox>
  printf '%s/captain-chat-dismissed.jsonl' "$(dirname "$1")"
}

fm_order_lock_dir() {  # <inbox>
  printf '%s.lock' "$1"
}

# Portable file mtime in epoch seconds (GNU `stat -c` vs BSD `stat -f`). Prints
# nothing on any failure, so callers must guard for an empty/non-numeric result.
fm_order_path_mtime() {  # <path>
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# Acquire the dedicated writer lock, waiting up to FM_ORDER_LOCK_TIMEOUT seconds.
# The lock is an atomic mkdir holding the writer's pid; a lock whose holder is gone is
# broken so a killed writer can never wedge intake. Returns 1 when the lock is held by a
# LIVE writer for the whole timeout - a refusal the caller must surface, never swallow,
# because an unrecorded order that was reported as recorded is the failure this whole
# feature exists to prevent.
#
# The pid write is best-effort (it can lose the race, or fail), so a writer can die
# after mkdir but before recording its pid, leaving a PID-LESS lockdir. Reclaiming a
# pid-less lock immediately would race a live writer still inside that mkdir->pid
# window, so it is reclaimed only once the pid-less lockdir has aged past a short grace
# (FM_ORDER_LOCK_PIDLESS_GRACE seconds) - long enough that a live writer would have
# recorded its pid by now. Without this, a pid-less lock nothing ever reclaims wedges
# intake until an operator removes it, contradicting the killed-writer guarantee above.
fm_order_lock() {  # <inbox>
  local lockdir waited=0 timeout grace holder mtime now age
  lockdir=$(fm_order_lock_dir "$1")
  timeout=${FM_ORDER_LOCK_TIMEOUT:-10}
  grace=${FM_ORDER_LOCK_PIDLESS_GRACE:-3}
  while :; do
    if mkdir "$lockdir" 2>/dev/null; then
      printf '%s\n' "$$" > "$lockdir/pid" 2>/dev/null || true
      FM_ORDER_LOCK_HELD=$lockdir
      return 0
    fi
    holder=$(cat "$lockdir/pid" 2>/dev/null || true)
    if [ -n "$holder" ]; then
      if ! kill -0 "$holder" 2>/dev/null; then
        # Recorded holder is gone: the writer died, break the abandoned lock.
        rm -f "$lockdir/pid" 2>/dev/null || true
        rmdir "$lockdir" 2>/dev/null || true
        continue
      fi
    else
      # No pid recorded: a writer that died in the mkdir->pid window, or a live
      # one still inside it. Reclaim only after the pid-less lockdir ages past the
      # grace, so a just-acquired lock is never stolen from a writer about to
      # record its pid. An unreadable mtime falls through to the normal wait.
      mtime=$(fm_order_path_mtime "$lockdir")
      case "$mtime" in
        ''|*[!0-9]*) : ;;
        *)
          now=$(date +%s 2>/dev/null || printf 0)
          case "$now" in ''|*[!0-9]*) now=0 ;; esac
          age=$(( now - mtime ))
          if [ "$age" -ge "$grace" ]; then
            rm -f "$lockdir/pid" 2>/dev/null || true
            rmdir "$lockdir" 2>/dev/null || true
            continue
          fi
          ;;
      esac
    fi
    [ "$waited" -ge "$timeout" ] && return 1
    sleep 1
    waited=$((waited + 1))
  done
}

fm_order_unlock() {
  [ -n "${FM_ORDER_LOCK_HELD:-}" ] || return 0
  rm -f "$FM_ORDER_LOCK_HELD/pid" 2>/dev/null || true
  rmdir "$FM_ORDER_LOCK_HELD" 2>/dev/null || true
  FM_ORDER_LOCK_HELD=
}

# Print the idempotency key for a request: an explicit key when the caller has one
# (a chat capture's spool id, a bridge submission id), otherwise a hash of the source
# plus the whitespace-normalized request text, so the same request delivered twice
# resolves to the same key and therefore to the same order.
fm_order_idempotency_key() {  # <source> <request-text> [<explicit-key>]
  local source=$1 text=$2 explicit=${3:-}
  if [ -n "$explicit" ]; then
    printf '%s' "$explicit"
    return 0
  fi
  printf '%s\n%s' "$source" "$(printf '%s' "$text" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')" \
    | fm_triage_hash
}

# Fold the append-only inbox into current per-order state, keyed by order_id.
# The latest event wins and fields accumulate, so a bare `claim` keeps the request text
# stamped by `received`. An explicit null IS an update (release clears an owner).
# A duplicate_delivery event is the one exception: it must never overwrite the order it
# is a duplicate OF, so it only counts itself and files its evidence.
# A malformed row is skipped rather than fatal, and accounted for by fm_order_health.
fm_order_fold() {  # <inbox>
  local inbox=$1
  [ -f "$inbox" ] || { printf '{}\n'; return 0; }
  jq -Rn '
    reduce inputs as $line ({};
      ($line | try fromjson catch null) as $e
      | if ($e | type) != "object" or ($e.order_id // "") == "" then .
        elif $e.event == "duplicate_delivery" then
          .[$e.order_id] = ((.[$e.order_id] // {})
            | .duplicate_delivery_count = ((.duplicate_delivery_count // 0) + 1)
            | .duplicate_evidence = ((.duplicate_evidence // [])
                                     + [{ts: $e.ts, source: $e.source,
                                         original_request: ($e.original_request // null)}]))
        else .[$e.order_id] = ((.[$e.order_id] // {})
                               + ($e | del(.event))
                               + {last_event: $e.event})
        end)
  ' "$inbox"
}

# Print the inbox's structural health as JSON. A skipped row is survivable but never
# free: a malformed `received` row loses the captain's request text entirely, which is
# the one thing this system exists to keep. Skips are therefore counted, referenced by
# line, and excerpted (bounded, printable bytes only) so they can be repaired.
fm_order_health() {  # <inbox>
  local inbox=$1
  [ -f "$inbox" ] || {
    jq -cn --arg path "$inbox" \
      '{path: $path, present: false, total_rows: 0, malformed_rows: 0, rows: []}'
    return 0
  }
  jq -Rn --arg path "$inbox" '
    reduce inputs as $line
      ({path: $path, present: true, total_rows: 0, malformed_rows: 0, rows: [], _line: 0};
       ._line += 1
       | if ($line | test("^[[:space:]]*$")) then .
         else
           .total_rows += 1
           | ($line | try fromjson catch null) as $e
           | (if ($e | type) != "object" then "unparseable JSON"
              elif (($e.order_id // "") == "") then "missing order_id"
              elif (($e.event // "") == "") then "missing event"
              else null end) as $why
           | if $why == null then .
             else
               .malformed_rows += 1
               | .rows += (if (.rows | length) < 5
                           then [{line: ._line, reason: $why,
                                  excerpt: ($line | gsub("[^ -~]"; "?") | .[0:120])}]
                           else [] end)
             end
         end)
    | del(._line)
  ' "$inbox"
}

# Print the record fields a status requires, space separated, or nothing when it needs
# none. This is the one owner of the captain-order lineage contract, and it mirrors the
# triage ledger's rule: an order is not handled because it was seen or acknowledged.
#   lineage        at least one linked task, scout, bug, or order id
#   outcome_link   the successor, evidence, or superseding order that ended it
#   outcome_reason why it ended
#   hold_reason    why it is parked
#   review_after   when a park must be revisited
#   captain_ack    the captain's receipt for a captain_parked order
# bin/fm-order.sh refuses a write that violates this; its `list` reimplements the check
# in jq purely as a backstop for a row that reached the ledger some other way.
fm_order_status_requires() {  # <status>
  case "$1" in
    dispatched) printf 'lineage' ;;
    completed|superseded) printf 'outcome_link' ;;
    rejected) printf 'outcome_reason' ;;
    captain_parked) printf 'captain_ack' ;;
    blocked|needs_clarification|captain_decision) printf 'hold_reason' ;;
    held) printf 'hold_reason review_after' ;;
    *) return 1 ;;
  esac
}

# True when a status is a terminal disposition of the order itself. captain_parked is
# terminal: the captain explicitly said park it, with a receipt, so the closed-loop audit
# stops re-driving it (ORD-260 slice S1, report section 5.0).
fm_order_status_terminal() {  # <status>
  case "$1" in
    completed|superseded|rejected|captain_parked) return 0 ;;
    *) return 1 ;;
  esac
}

# Classify a hold's --review-after condition. A machine-checkable hold is one a script can
# evaluate on its own, which is what stops a hold from being a permanent silent mute (the
# L3 loss mode in the ORD-237 report): free text nothing can read never expires, so the
# order it parks disappears. Prints exactly one of:
#   date    an ISO-8601 date or instant a clock can read (the one date parser is
#           fm_triage_review_date_ok, shared with the fleet-triage ledger so the two can
#           never disagree about what a review date means)
#   event   a typed terminal-event key: task:<id>:terminal or order:<id>:terminal
#   invalid anything else, including an empty condition or a malformed event key
# The audit predicate (bin/fm-order.sh audit) evaluates a `date` hold against the clock and
# an `order:<id>:terminal` hold against the ledger; a `task:<id>:terminal` hold is
# machine-checkable but evaluated by the control plane (slice S4), not here.
fm_order_review_after_kind() {  # <review-after>
  local ra=$1 body
  case "$ra" in
    task:*:terminal|order:*:terminal)
      # Strip the type prefix and the :terminal suffix, then require a non-empty id made
      # only of id-safe characters - no embedded colon or whitespace - so task::terminal
      # and task:a:b:terminal are both refused rather than passed as machine-checkable.
      body=${ra#*:}
      body=${body%:terminal}
      case "$body" in
        ''|*[!A-Za-z0-9._-]*) printf 'invalid'; return 0 ;;
        *) printf 'event'; return 0 ;;
      esac
      ;;
  esac
  if fm_triage_review_date_ok "$ra"; then
    printf 'date'
  else
    printf 'invalid'
  fi
}

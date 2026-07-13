#!/usr/bin/env bash
# Reconcile recorded fleet-triage dispositions into Fleet Bridge board attention.
#
# Usage:
#   fm-nf-attention.sh apply <task-id>...   Converge those tasks' cards with the ledger.
#   fm-nf-attention.sh sync                 Converge every task in this home. Idempotent.
#   fm-nf-attention.sh show <task-id>...    Print the desired state and why. Writes nothing.
#
# WHY THIS EXISTS
# Recording a triage outcome wrote the ledger and nothing else, so the only thing that ever
# cleared a Needs FirstMate card was a successful teardown. A task firstmate had reviewed,
# dispositioned, and even landed still sat on the captain's Bridge as active attention. This
# command closes that gap, and bin/fm-fleet-triage-record.sh and bin/fm-nf-reconcile.sh both
# drive it, so the reconciliation is automatic rather than a step firstmate must remember.
#
# ATTENTION IS NOT CLOSURE. Nothing here writes closure evidence, closes a TaskRecord, or
# takes a task out of `visibility audit`. A task with no closure evidence stays un-closable
# and stays in the audit; that gate is teardown's, through bin/fm-task-events.sh.
#
# THE OUTCOME TYPE DECIDES WHETHER ATTENTION IS CLEARED, TRANSFERRED, OR HELD
# Every terminal outcome used to clear the card. That is right only for the outcomes meaning
# firstmate is FINISHED with the item, and it silently deleted the ones that are not: a
# captain batch is the outcome that TRANSFERS the decision to the captain, so clearing it
# dropped a decision he still owed off his board. bin/fm-nf-attention-lib.sh maps each outcome
# to one of the states below; this command applies them.
#
# HOW A CARD IS MOVED
# terminal - resolved, rejected, or reworking in a successor. state/<id>.meta gains
#            attentionOwner=none, which the board honors ahead of every derived signal (crew
#            status, turn-end, PR), so the card stops presenting as active FirstMate attention
#            while staying on the board and in the audit. A durable board event follows as the
#            receipt: a successor posts `reworking`, anything else posts `reviewed`.
# captain  - a captain batch. Attention is TRANSFERRED, never cleared: no attentionOwner
#            override is written, and the hand-off goes through bin/fm-nf-ack.sh --to-captain,
#            the one writer of the board's captain-attention column, naming the item's real
#            lane-qualified id as the open item. The card must land in Needs Human with the
#            captain owning it. If that write fails the card stays FirstMate-owned and the
#            next pass retries - a decision the captain owes is never dropped on a bad write.
# held     - the card stays FirstMate-owned and visible, but presents as HELD: a durable
#            `reviewed` board event plus a card note carrying the reason and the review date,
#            so "firstmate parked this until X" reads differently from "nobody has touched
#            this". The hold's own meta keys record the same facts locally.
# open     - every override is removed and the natural signal owns the card again.
#
# The local override, not the board write, is what clears a card, so a disposition recorded
# while the cockpit is down still lands and its receipt is retried on the next pass.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BRIDGE=${FM_BRIDGE_URL:-http://127.0.0.1:8787}
HOME_NAME=$(basename "$FM_HOME")
MARKER="$STATE/.nf-attention"

# shellcheck disable=SC1091 # Dynamic sibling path is resolved from BASH_SOURCE.
. "$SCRIPT_DIR/fm-nf-attention-lib.sh"

usage() {
  sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

warn() {
  printf 'fm-nf-attention: %s\n' "$1" >&2
}

command -v jq >/dev/null 2>&1 || { warn 'jq not found'; exit 1; }

MODE=${1:-}
case "$MODE" in
  -h|--help|'') usage; exit 0 ;;
  apply|show) shift; [ "$#" -ge 1 ] || { usage >&2; exit 2; } ;;
  sync) shift; [ "$#" -eq 0 ] || { usage >&2; exit 2; } ;;
  *) usage >&2; exit 2 ;;
esac

# --- Local meta overrides. ----------------------------------------------------------
# The board reads these keys from state/<id>.meta, which firstmate owns. Writing them needs
# no server, so a dispositioned card clears even while the cockpit is down and converges the
# moment it is back.
meta_set() {  # <meta-file> <key> <value>
  local file=$1 key=$2 value=$3 tmp
  [ -f "$file" ] || return 0
  # A meta file is one key=value per line, so a value's newlines and tabs would corrupt it.
  value=$(printf '%s' "$value" | tr '\n\t\r' '   ')
  if [ "$(fm_meta_get "$file" "$key")" = "$value" ] && grep -q "^$key=" "$file"; then
    return 0
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-nf-attention.XXXXXX")
  grep -v "^$key=" "$file" > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

meta_unset() {  # <meta-file> <key>...
  local file=$1 key tmp changed=false
  shift
  [ -f "$file" ] || return 0
  for key in "$@"; do
    if grep -q "^$key=" "$file"; then changed=true; fi
  done
  [ "$changed" = true ] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-nf-attention.XXXXXX")
  cat "$file" > "$tmp"
  for key in "$@"; do
    grep -v "^$key=" "$tmp" > "$tmp.next" || true
    mv "$tmp.next" "$tmp"
  done
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

# --- Durable board events. ----------------------------------------------------------
# The closure-gated attention API is the board's own record of what firstmate did with a
# card. It is deliberately the same endpoint bin/fm-nf-ack.sh drives.
post_event() {  # <task-id> <event> <fingerprint> [<extra-key> <extra-value>]
  local id=$1 event=$2 fingerprint=$3 key=${4:-} value=${5:-} body
  body=$(jq -nc --arg event "$event" --arg fp "$fingerprint" --arg actor firstmate \
    --arg name "$key" --arg value "$value" \
    '{event: $event, status_fingerprint: $fp, actor: $actor}
     + (if $name == "" then {} else {($name): $value} end)')
  curl -fsS -H 'content-type: application/json' -d "$body" \
    "$BRIDGE/api/card/$HOME_NAME/$id/attention" >/dev/null
}

# Record what firstmate did with a card it is FINISHED with, in the richest form the board
# will take. `reworking` is gated on the task already having a durable TaskRecord, which a
# live crew usually does not have until teardown records one, so it is attempted and not
# required; `reviewed` is accepted for any task and is the receipt that always lands. The card
# is already cleared by its meta override either way - this only decides how much the board
# can say about WHERE the work went.
post_terminal_event() {  # <task-id> <outcome> <fingerprint> <link>
  local id=$1 outcome=$2 fingerprint=$3 link=$4
  case "$outcome" in
    successor_created)
      post_event "$id" reworking "$fingerprint" successor_id "$link" 2>/dev/null && return 0
      ;;
  esac
  post_event "$id" reviewed "$fingerprint"
}

# Hand a captain-batched card to the captain. bin/fm-nf-ack.sh --to-captain is the one writer
# of the board's captain-attention column (AGENTS.md section 9), so this drives that path
# rather than writing the column - or, worse, clearing the card - itself. The open item is the
# item's real lane-qualified triage id, which is what the captain's board opens against; the
# batch the decision was packaged into stays in the triage ledger, where its lineage lives.
#
# Unlike a terminal disposition, this write is not a receipt for something the meta override
# already did: it IS the disposition. A failure must therefore leave the card asking firstmate,
# so the retry on the next pass is what the captain's board is waiting on.
hand_to_captain() {  # <task-id>
  local id=$1
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_BRIDGE_URL="$BRIDGE" \
    "$SCRIPT_DIR/fm-nf-ack.sh" --to-captain "needs_firstmate:$id" "$id" >/dev/null
}

current_event() {  # <task-id>
  curl -fsS "$BRIDGE/api/card/$HOME_NAME/$1/attention" 2>/dev/null \
    | jq -r '(.event // "") + "\t" + (.statusFingerprint // .status_fingerprint // "")' 2>/dev/null
}

# A card note is the only board surface that carries firstmate's own words, which is what a
# hold needs: the reason and the review date, on the card, where the captain reads it.
post_note() {  # <task-id> <text>
  local body
  body=$(jq -nc --arg id "$1" --arg text "$2" \
    '{type: "note", id: $id, payload: {text: $text}}')
  curl -fsS -H 'content-type: application/json' -d "$body" "$BRIDGE/api/overlay" >/dev/null
}

# --- Convergence marker. ------------------------------------------------------------
# Board writes are append-only, so they are made once per change rather than once per poll:
# sync runs on every watcher cycle, and a card must not collect a fresh note each time.
# The marker records only what was already applied; the meta override is enforced every pass
# regardless, because that write is idempotent and is what actually clears the card.
marker_get() {  # <task-id>
  [ -f "$MARKER" ] || return 0
  awk -F '\t' -v id="$1" '$1 == id {print $2}' "$MARKER" | tail -n 1
}

marker_set() {  # <task-id> <signature>
  local tmp
  mkdir -p "$STATE"
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-nf-attention.XXXXXX")
  if [ -f "$MARKER" ]; then
    awk -F '\t' -v id="$1" '$1 != id' "$MARKER" > "$tmp" || true
  fi
  printf '%s\t%s\n' "$1" "$2" >> "$tmp"
  cat "$tmp" > "$MARKER"
  rm -f "$tmp"
}

signature_of() {  # <desired-json>
  printf '%s' "$1" | jq -r '[.state, .evidence_version, .outcome, .link, .reason, .review_after]
                            | map(. // "") | join("|")'
}

# --- Apply one task. ----------------------------------------------------------------
apply_one() {  # <task-id> <fold-json>
  local id=$1 fold=$2 desired state outcome link reason review_after fp signature meta
  local applied last_event last_fp rc=0
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || { warn "no meta for $id"; return 1; }

  desired=$(fm_nf_attention_desired "$STATE" "$DATA" "$id" "$fold")
  state=$(printf '%s' "$desired" | jq -r '.state')
  outcome=$(printf '%s' "$desired" | jq -r '.outcome')
  link=$(printf '%s' "$desired" | jq -r '.link')
  reason=$(printf '%s' "$desired" | jq -r '.reason')
  review_after=$(printf '%s' "$desired" | jq -r '.review_after')
  fp=$(printf '%s' "$desired" | jq -r '.fingerprint')
  signature=$(signature_of "$desired")
  applied=$(marker_get "$id")

  case "$state" in
    terminal)
      # The meta override is what actually clears the card, and it needs no server, so a
      # disposition lands even with the cockpit down. The board event that follows is the
      # durable receipt, and where the board can take a richer one it says where the work
      # went: to the captain, or on to a successor.
      meta_set "$meta" attentionOwner none
      meta_unset "$meta" attention_state attention_hold_reason attention_hold_review_after
      if [ "$signature" != "$applied" ]; then
        post_terminal_event "$id" "$outcome" "$fp" "$link" || rc=1
      fi
      ;;
    captain)
      # Attention TRANSFERS here; it is not cleared. No attentionOwner override is written,
      # because that override is exactly what took the captain's own decision off his board.
      # The card stays visible and the hand-off itself moves it to the captain's column.
      meta_unset "$meta" attentionOwner attention_state attention_hold_reason \
        attention_hold_review_after
      if [ "$signature" != "$applied" ]; then
        hand_to_captain "$id" || {
          warn "$id: hand-off to the captain failed; the card keeps asking firstmate and the next pass retries"
          rc=1
        }
      fi
      ;;
    held)
      # A hold is not terminal, so the card keeps its FirstMate attention and stays visible.
      # What changes is how it PRESENTS: reviewed, with the reason and the review date on it.
      meta_unset "$meta" attentionOwner
      meta_set "$meta" attention_state held
      meta_set "$meta" attention_hold_reason "$reason"
      meta_set "$meta" attention_hold_review_after "$review_after"
      if [ "$signature" != "$applied" ]; then
        post_event "$id" reviewed "$fp" || rc=1
        post_note "$id" "held: $reason - review after $review_after" || rc=1
      fi
      ;;
    open)
      meta_unset "$meta" attentionOwner attention_state attention_hold_reason \
        attention_hold_review_after
      # A re-surfaced item whose signal never changed still carries the board event of the
      # disposition it just reopened, and to_captain/reworking outrank the natural signal
      # there. A `reviewed` event is the board's own neutral "still open, firstmate looked",
      # so posting one hands the card back to its terminal signal.
      if [ -n "$fp" ] && [ "$signature" != "$applied" ]; then
        last_event=''
        last_fp=''
        IFS=$'\t' read -r last_event last_fp <<<"$(current_event "$id")" || true
        case "$last_event" in
          to_captain|reworking)
            if [ "$last_fp" = "$fp" ]; then
              post_event "$id" reviewed "$fp" || rc=1
            fi
            ;;
        esac
      fi
      ;;
  esac

  if [ "$rc" -eq 0 ]; then marker_set "$id" "$signature"; fi
  printf '%s: %s (%s)\n' "$id" "$state" "$(printf '%s' "$desired" | jq -r '.why')"
  return "$rc"
}

FOLD=$(fm_nf_attention_fold "$DATA")

if [ "$MODE" = show ]; then
  for id in "$@"; do
    printf '%s\t%s\n' "$id" "$(fm_nf_attention_desired "$STATE" "$DATA" "$id" "$FOLD")"
  done
  exit 0
fi

RC=0
if [ "$MODE" = apply ]; then
  for id in "$@"; do
    apply_one "$id" "$FOLD" || RC=1
  done
  exit "$RC"
fi

# sync: converge the whole home. A task with neither a ledger entry nor a live override is
# already correct, so the common no-change poll costs one grep per task and no board call.
LEDGERED=$(printf '%s' "$FOLD" \
  | jq -r 'keys[] | select(startswith("needs_firstmate:")) | ltrimstr("needs_firstmate:")')

for meta_file in "$STATE"/*.meta; do
  [ -f "$meta_file" ] || continue
  id=$(basename "$meta_file" .meta)
  case $'\n'"$LEDGERED"$'\n' in
    *$'\n'"$id"$'\n'*) : ;;
    *) grep -q '^attention' "$meta_file" || continue ;;
  esac
  apply_one "$id" "$FOLD" >/dev/null || RC=1
done

# A torn-down task takes its meta with it, so its convergence marker is dead weight; the file
# would otherwise grow one stale line per task the fleet ever ran.
if [ -f "$MARKER" ]; then
  PRUNED=$(mktemp "${TMPDIR:-/tmp}/fm-nf-attention.XXXXXX")
  while IFS=$'\t' read -r id signature; do
    [ -n "$id" ] || continue
    [ -f "$STATE/$id.meta" ] || continue
    printf '%s\t%s\n' "$id" "$signature" >> "$PRUNED"
  done < "$MARKER"
  cat "$PRUNED" > "$MARKER"
  rm -f "$PRUNED"
fi
exit "$RC"

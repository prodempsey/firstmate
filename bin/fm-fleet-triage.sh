#!/usr/bin/env bash
# Enumerate deterministic fleet-triage candidates without changing fleet state.
#
# Usage:
#   fm-fleet-triage.sh --digest
#   fm-fleet-triage.sh --json
#   fm-fleet-triage.sh --check
#   fm-fleet-triage.sh install
#
# The JSON contract is fm-fleet-triage/v2.
#
# THIS COMMAND IS READ-ONLY. It inspects, correlates, normalizes, fingerprints,
# classifies, and reports. It never creates tasks, records or resolves bugs, dispatches
# crews, mutates task state, merges, lands, tears down, or makes captain decisions.
# Processing state and lineage are written only by fm-fleet-triage-record.sh.
#
# PROCESSING AND OUTCOMES
# An item is not handled because it was printed, seen, or acknowledged. It is handled
# only once it carries a terminal outcome with lineage: a linked successor, a resolution
# with evidence, a rejection with a reason, a hold with a review condition, or a captain
# batch. Those outcomes live in the append-only ledger data/fleet-triage.jsonl, folded
# here at read; bin/fm-fleet-triage-lib.sh owns that contract.
#
# The retired state/.fleet-triage-handled ledger recorded a boolean "seen" bit with no
# outcome and no lineage, which is precisely how an item could be marked handled while
# nothing had actually happened to it. It is not read and not migrated.
#
# Environment:
#   FLEET_TRIAGE_MODE=enumerate_only   kill switch; classify and report, apply nothing
#   FM_FLEET_TRIAGE_BUG_CLI            bug CLI path, or `off` to disable bug discovery
#   FM_ORDERS_PATH                     captain order inbox path (bin/fm-order-lib.sh)
#   FM_FLEET_TRIAGE_DIGEST_MAX_ITEMS   digest item cap (default 8)
#   FM_FLEET_TRIAGE_STALE_SECS         age at which an unprocessed item is stale (86400)
#   FM_FLEET_TRIAGE_CLAIM_TTL_SECS     age at which a claim is abandoned (3600)
#   FM_FLEET_TRIAGE_CHECK_INTERVAL      seconds between forced full checks (1800)
#   FM_FLEET_TRIAGE_RESURFACE_SECS      unchanged actionable set re-surface (86400)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
MODE=${1:---digest}
MAX_ITEMS=${FM_FLEET_TRIAGE_DIGEST_MAX_ITEMS:-8}
STALE_SECS=${FM_FLEET_TRIAGE_STALE_SECS:-86400}
CLAIM_TTL=${FM_FLEET_TRIAGE_CLAIM_TTL_SECS:-3600}
CHECK_INTERVAL=${FM_FLEET_TRIAGE_CHECK_INTERVAL:-1800}
RESURFACE_SECS=${FM_FLEET_TRIAGE_RESURFACE_SECS:-86400}

# shellcheck disable=SC1091 # Dynamic sibling path is resolved from BASH_SOURCE.
. "$SCRIPT_DIR/fm-fleet-triage-lib.sh"

usage() {
  cat <<'EOF'
usage: fm-fleet-triage.sh [--digest|--json|--check|install]

Print a token-capped digest or the full fm-fleet-triage/v2 JSON object.
The command is read-only and never records outcomes, merges, tears down, or edits the
backlog. Record a disposition with bin/fm-fleet-triage-record.sh, which is the only
sanctioned writer of the processing ledger.

An item is actionable until it carries a terminal outcome WITH lineage. Being printed,
seen, or acknowledged is not an outcome, so there is no acknowledge verb.

Health values re-surface an item the fleet thought it had finished with:
  evidence_changed   the evidence moved since the outcome was decided
  successor_missing  a linked successor task does not exist
  dangling_outcome   a terminal outcome is missing its required lineage
  hold_expired       a hold's review date has arrived
  claim_abandoned    a claim went stale without an outcome
  owner_missing      a claimed item has no owner
  stale_unprocessed  surfaced long ago and still not dispositioned

The captain_orders lane REFERENCES the captain order inbox through its own sanctioned
reader (bin/fm-order.sh list --json). It never writes an order and never decides an order
status; it surfaces the orders the inbox says still need firstmate - received but
untriaged, ownerless, missing lineage, stale, a hold whose review date arrived, a blocker
that cleared, a linked task that vanished, and a decision the captain owes. An inbox that
exists but cannot be read is reported UNAVAILABLE with the reason, never as zero orders.

The bugs lane uses FM_FLEET_TRIAGE_BUG_CLI when set, then the sanctioned `bug` command
on PATH, through `<cli> list --json`. Set FM_FLEET_TRIAGE_BUG_CLI=off to disable it.

A backlog row joins the visibility lane only by declaring itself, with an explicit marker
in the row's metadata parens beside repo: and kind:
  - [ ] some-id - Title (repo: fleet-bridge, triage: visibility)
  - [ ] some-id - Title (repo: fleet-bridge, triage: visibility-umbrella)
  triage: visibility            an engineering visibility gap  -> FIRSTMATE_JUDGMENT
  triage: visibility-umbrella   standing product semantics     -> CAPTAIN_GATE
Keep the marker inside an existing metadata group so it stays out of the row's title.
Action class follows the item's verb, never its lane, so ordinary engineering defects are
never escalated to the captain just for sharing a lane with product-semantics work.

The ledger_health lane raises exactly ONE item, and only when the append-only ledger holds
rows the fold had to skip. A skipped row is survivable but not free: a malformed `surface`
row loses its item's first_seen_at, so that item can never age into stale_unprocessed.

--check is the watcher-facing path. It fingerprints local evidence with stat/find only and
skips the full enumerator while that proxy is unchanged and its independent cooldown has
not elapsed. The 1800-second default bounds a measured 12.8-second full scan to about 0.7%
worst-case duty while still revisiting external evidence within 30 minutes. Configure it
with FM_FLEET_TRIAGE_CHECK_INTERVAL; configure unchanged-set re-surfacing separately with
FM_FLEET_TRIAGE_RESURFACE_SECS.
EOF
}

case "$MODE" in
  --digest|--json) [ "$#" -eq 1 ] || { usage >&2; exit 2; } ;;
  --check|install) [ "$#" -eq 1 ] || { usage >&2; exit 2; } ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

case "$MAX_ITEMS" in ''|*[!0-9]*) MAX_ITEMS=8 ;; esac
case "$STALE_SECS" in ''|*[!0-9]*) STALE_SECS=86400 ;; esac
case "$CLAIM_TTL" in ''|*[!0-9]*) CLAIM_TTL=3600 ;; esac
case "$CHECK_INTERVAL" in ''|*[!0-9]*) CHECK_INTERVAL=1800 ;; esac
case "$RESURFACE_SECS" in ''|*[!0-9]*) RESURFACE_SECS=86400 ;; esac

write_if_changed() {
  local target=$1 tmp
  tmp=$(mktemp "${target}.tmp.XXXXXX")
  cat > "$tmp"
  if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
  else
    mv "$tmp" "$target"
  fi
}

install_check() {
  local shim="$STATE/fleet-triage.check.sh"
  mkdir -p "$STATE"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'exec env FM_ROOT_OVERRIDE=%q FM_HOME=%q FM_STATE_OVERRIDE=%q FM_DATA_OVERRIDE=%q %q --check\n' \
      "$FM_ROOT" "$FM_HOME" "$STATE" "$DATA" "$SCRIPT_DIR/fm-fleet-triage.sh"
  } | write_if_changed "$shim"
  chmod +x "$shim"
}

stat_signature() {
  local path=$1
  if stat -c '%n\t%s\t%Y' "$path" >/dev/null 2>&1; then
    stat -c '%n\t%s\t%Y' "$path"
  else
    stat -f '%N\t%z\t%m' "$path"
  fi
}

proxy_fingerprint() {
  {
    for path in "$DATA/backlog.md" "$DATA/fleet-triage.jsonl" "$DATA/captain-orders.jsonl"; do
      [ -f "$path" ] && stat_signature "$path"
    done
    find "$STATE" -maxdepth 1 -type f \( -name '*.meta' -o -name '*.status' \) -print 2>/dev/null \
      | LC_ALL=C sort | while IFS= read -r path; do stat_signature "$path"; done
    find "$DATA" -mindepth 2 -maxdepth 2 -type f -name report.md -print 2>/dev/null \
      | LC_ALL=C sort | while IFS= read -r path; do stat_signature "$path"; done
  } | cksum | awk '{print $1 ":" $2}'
}

check_epoch() {
  local file=$1 value=0
  [ -f "$file" ] && read -r value < "$file"
  case "$value" in ''|*[!0-9]*) value=0 ;; esac
  printf '%s\n' "$value"
}

run_check() {
  local proxy_file="$STATE/.fleet-triage-check-proxy"
  local full_file="$STATE/.fleet-triage-check-last-full"
  local summary_file="$STATE/.fleet-triage-check-last-summary"
  local surface_file="$STATE/.fleet-triage-check-last-surface"
  local now last_full last_surface proxy previous_proxy result rc summary old_count count new_count error_file error_detail
  mkdir -p "$STATE"
  now=$(date +%s)
  last_full=$(check_epoch "$full_file")
  proxy=$(proxy_fingerprint)
  previous_proxy=''
  [ -f "$proxy_file" ] && read -r previous_proxy < "$proxy_file"
  if [ "$proxy" = "$previous_proxy" ] && [ $((now - last_full)) -lt "$CHECK_INTERVAL" ]; then
    return 0
  fi

  error_file="$STATE/.fleet-triage-check-error.$$"
  rc=0
  result=$("$SCRIPT_DIR/fm-fleet-triage.sh" --json 2> "$error_file") || rc=$?
  printf '%s\n' "$now" > "$full_file"
  printf '%s\n' "$proxy" > "$proxy_file"
  if [ "$rc" -ne 0 ]; then
    error_detail=$(tail -n 1 "$error_file" 2>/dev/null || true)
    [ -n "$error_detail" ] || error_detail=$(printf '%s' "$result" | tail -n 1)
    rm -f "$error_file"
    printf 'FLEET_TRIAGE: check failed: full scan exited %s: %s\n' "$rc" \
      "$(printf '%s' "$error_detail" | tr '\n' ' ' | cut -c1-160)"
    return 0
  fi
  rm -f "$error_file"
  if ! printf '%s' "$result" | jq -e '.schema == "fm-fleet-triage/v2" and (.items | type == "array")' >/dev/null 2>&1; then
    printf 'FLEET_TRIAGE: check failed: full scan returned invalid JSON\n'
    return 0
  fi

  summary=$(printf '%s' "$result" | jq -r '.items[] | select(.actionable == true) | [.item_id,.evidence_version] | @tsv' | LC_ALL=C sort)
  count=$(printf '%s\n' "$summary" | grep -c . || true)
  old_count=0
  [ -s "$summary_file" ] && old_count=$(grep -c . "$summary_file" || true)
  new_count=$count
  if [ -s "$summary_file" ]; then
    new_count=$(comm -13 "$summary_file" <(printf '%s\n' "$summary") | grep -c . || true)
  fi
  last_surface=$(check_epoch "$surface_file")
  if ! [ -f "$summary_file" ] || ! cmp -s "$summary_file" <(printf '%s\n' "$summary"); then
    printf '%s\n' "$summary" > "$summary_file"
    if [ "$count" -gt 0 ] || [ "$old_count" -gt 0 ]; then
      printf 'FLEET_TRIAGE: check: %s actionable (+%s new)\n' "$count" "$new_count"
      printf '%s\n' "$now" > "$surface_file"
    fi
  elif [ "$count" -gt 0 ] && [ $((now - last_surface)) -ge "$RESURFACE_SECS" ]; then
    printf 'FLEET_TRIAGE: check: %s actionable (+0 new; re-surface)\n' "$count"
    printf '%s\n' "$now" > "$surface_file"
  fi
}

case "$MODE" in
  install) install_check; exit 0 ;;
  --check) run_check; exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || {
  printf 'fm-fleet-triage: jq not found\n' >&2
  exit 1
}

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-fleet-triage.XXXXXX")
# shellcheck disable=SC2317 # Invoked by the EXIT trap below.
# shellcheck disable=SC2317,SC2329 # Invoked by the EXIT trap below.
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

SNAPSHOT_FILE="$TMP_ROOT/snapshot.json"
ORDERS_FILE="$TMP_ROOT/orders.json"
NF_FILE="$TMP_ROOT/nf.json"
BUG_FILE="$TMP_ROOT/bugs.json"
ARCHIVE_IDS_FILE="$TMP_ROOT/archive-ids.json"
RAW_ITEMS="$TMP_ROOT/raw-items.json"
REPORT_DIGEST_TSV="$TMP_ROOT/report-digests.tsv"
REPORT_DIGEST_FILE="$TMP_ROOT/report-digests.json"
FOLD_FILE="$TMP_ROOT/fold.json"
HEALTH_FILE="$TMP_ROOT/ledger-health.json"
VISIBILITY_AUDIT_FILE="$TMP_ROOT/visibility-audit.json"
EV_TSV="$TMP_ROOT/evidence.tsv"
EV_FILE="$TMP_ROOT/evidence.json"

printf '{"ok":true,"diagnostics":[]}\n' > "$VISIBILITY_AUDIT_FILE"
VISIBILITY_CLI=${FM_VISIBILITY_CLI:-}
if [ -z "$VISIBILITY_CLI" ]; then
  for candidate in \
    /home/prode/fleet/.fb-redesign/bin/visibility.mjs \
    /home/prode/fleet/fleet-bridge/bin/visibility.mjs \
    "$FM_HOME/projects/fleet-bridge/bin/visibility.mjs" \
    "$FM_ROOT/projects/fleet-bridge/bin/visibility.mjs"; do
    if [ -f "$candidate" ]; then
      VISIBILITY_CLI=$candidate
      break
    fi
  done
fi
if [ -f "$VISIBILITY_CLI" ]; then
  audit_rc=0
  node "$VISIBILITY_CLI" audit --json > "$VISIBILITY_AUDIT_FILE" || audit_rc=$?
  if ! jq -e '.ok|type=="boolean"' "$VISIBILITY_AUDIT_FILE" >/dev/null 2>&1; then
    jq -nc --arg detail "visibility audit returned invalid JSON (exit $audit_rc)" '{ok:false,diagnostics:[{code:"audit_invalid",message:$detail}]}' > "$VISIBILITY_AUDIT_FILE"
  fi
fi

FM_ROOT_OVERRIDE="$FM_ROOT" \
  FM_HOME="$FM_HOME" \
  FM_STATE_OVERRIDE="$STATE" \
  FM_DATA_OVERRIDE="$DATA" \
  "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json > "$SNAPSHOT_FILE"

# The captain order inbox is its own authoritative store with its own sanctioned writer
# (bin/fm-order.sh). This lane REFERENCES it - it never becomes a second order ledger, and
# it never decides an order's status. It asks the inbox which orders still need firstmate
# and surfaces those, so a captain request cannot go quiet just because it was recorded.
#
# An inbox that cannot be read is reported unavailable with the reason, never folded to
# "no orders": a silently empty inbox and a genuinely empty one look identical, and only
# one of them means no captain is waiting.
ORDERS_AVAILABLE=false
ORDERS_NOTE='no captain order inbox yet (bin/fm-order.sh init)'
ORDERS_METRICS='{}'
printf '[]\n' > "$ORDERS_FILE"
ORDERS_RC=0
if [ ! -x "$SCRIPT_DIR/fm-order.sh" ]; then
  ORDERS_NOTE='bin/fm-order.sh is unavailable'
elif ORDERS_RAW=$(FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" \
  "$SCRIPT_DIR/fm-order.sh" list --json 2>/dev/null); then
  ORDERS_AVAILABLE=true
  ORDERS_NOTE='captain orders still awaiting triage, lineage, an owner, or a review'
  ORDERS_METRICS=$(printf '%s' "$ORDERS_RAW" | jq -c '.metrics // {}')
  # Every LIVE order is projected here, not only the ones the inbox already calls
  # actionable, because one attention rule can only be applied downstream: a linked task
  # that has disappeared is invisible to the inbox and obvious to the enumerator, which
  # knows every id the fleet still has.
  printf '%s' "$ORDERS_RAW" | jq '
    [ .orders[]
      | select((.status // "received") as $s
               | $s != "completed" and $s != "superseded" and $s != "rejected")
      | {lane: "captain_orders",
         id: .order_id,
         title: ((.short_title // .original_request) | gsub("[[:space:]]+"; " ") | .[0:120]),
         status: (.status // "received"),
         owner: (.owner // null),
         links: (((.linked_task_ids // []) + (.linked_scout_ids // [])
                  + (.linked_bug_ids // []) + (.related_order_ids // [])) | sort),
         review_after: (.review_after // null),
         attention: (.attention // "ok"),
         attention_reasons: (.attention_reasons // []),
         inbox_actionable: (.actionable // false),
         captain_decision_required: (.captain_decision_required // false),
         source: "captain-order-inbox",
         source_type: "captain_order"} ]
  ' > "$ORDERS_FILE"
else
  ORDERS_RC=$?
  # rc 3 is a missing inbox, which for a home that has never taken an order is normal.
  # Anything else means the inbox exists and could not be read: that is a defect, and the
  # lane says so loudly rather than pretending the captain has asked for nothing.
  if [ "$ORDERS_RC" -ne 3 ]; then
    ORDERS_NOTE="CAPTAIN ORDER INBOX UNREADABLE (bin/fm-order.sh list --json exited $ORDERS_RC) - treat as lost captain requests, not as an empty inbox"
  fi
fi

NF_AVAILABLE=false
NF_NOTE='bin/fm-nf-reconcile.sh is unavailable'
printf '[]\n' > "$NF_FILE"
if [ -x "$SCRIPT_DIR/fm-nf-reconcile.sh" ]; then
  NF_OUT=$(FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-nf-reconcile.sh" list 2>/dev/null || true)
  if printf '%s\n' "$NF_OUT" | grep -q '^NEEDS FIRSTMATE:'; then
    NF_AVAILABLE=true
    NF_NOTE='terminal signals from fm-nf-reconcile.sh list'
    printf '%s\n' "$NF_OUT" | awk '
      function emit() {
        if (id != "") print id "\t" signal "\t" verb "\t" fingerprint
      }
      /^NEEDS FIRSTMATE:/ { next }
      /^[^[:space:]][^:]*$/ { emit(); id=$0; signal=""; verb=""; fingerprint=""; next }
      /^  signal: / { signal=substr($0, 11); next }
      /^  verb: / { verb=substr($0, 9); next }
      /^  fingerprint: / { fingerprint=substr($0, 16); next }
      END { emit() }
    ' | jq -Rn '
      [inputs | split("\t")
       | {lane:"needs_firstmate",id:.[0],title:.[1],status:.[2],source:"fm-nf-reconcile",
          source_fingerprint:.[3],source_type:"task",action:"review_terminal_signal"}]
    ' > "$NF_FILE"
  fi
fi

BUG_AVAILABLE=false
BUG_NOTE='sanctioned bug CLI is unavailable'
printf '[]\n' > "$BUG_FILE"
BUG_CLI=${FM_FLEET_TRIAGE_BUG_CLI:-}
if [ -z "$BUG_CLI" ] && command -v bug >/dev/null 2>&1; then
  BUG_CLI=$(command -v bug)
fi
if [ "$BUG_CLI" = off ]; then
  BUG_NOTE='bug discovery is disabled by FM_FLEET_TRIAGE_BUG_CLI=off'
elif [ -n "$BUG_CLI" ]; then
  if [ -x "$BUG_CLI" ]; then
    if BUG_RAW=$("$BUG_CLI" list --json 2>/dev/null) \
      && printf '%s' "$BUG_RAW" | jq -e 'type == "array"' >/dev/null 2>&1; then
      BUG_AVAILABLE=true
      BUG_NOTE='open bugs from the configured Fleet Bridge bug CLI'
      # type, links, and note ride along because they are the structured fields a bug's
      # disposition actually turns on: a bug that gains a task link, a resolution note, or
      # a reclassified type has moved, and an outcome decided before that move is stale.
      # Widening the evidence version alone would not see them; the projection has to
      # carry them first.
      printf '%s' "$BUG_RAW" | jq '
        [ .[]
          | select((.status // "open") != "resolved")
          | {lane:"bugs",
             id:(.id // .bug_id // ("bug-" + ((.title // .sourceText // "untitled") | @base64))),
             title:(.title // .sourceText // "Untitled open bug"),
             status:(.status // "open"),
             type:(.type // null),
             links:(.links // null),
             note:(.note // null),
             source:"bug-cli",
             source_type:"bug",
             action:"batch_or_route_bug"} ]
      ' > "$BUG_FILE"
    else
      BUG_NOTE='sanctioned bug CLI did not return a JSON array'
    fi
  else
    BUG_NOTE='sanctioned bug CLI is not executable'
  fi
fi

# A scout report's deliverable is its body, not its path, so the lane digests the file's
# actual contents. A report rewritten in place with different findings must re-open a
# disposition that was decided against the old ones; the path alone can never say so.
# An unreadable or missing report digests to the empty string, which is itself a state
# change the evidence version will see.
: > "$REPORT_DIGEST_TSV"
while IFS=$'\t' read -r report_id report_path; do
  [ -n "$report_id" ] || continue
  report_digest=''
  if [ -n "$report_path" ] && [ -f "$report_path" ]; then
    report_digest=$(fm_triage_hash < "$report_path" 2>/dev/null || true)
  fi
  printf '%s\t%s\n' "$report_id" "$report_digest" >> "$REPORT_DIGEST_TSV"
done < <(jq -r '(.scout_reports // [])[] | [.id, (.path // "")] | @tsv' "$SNAPSHOT_FILE")
jq -Rn '[inputs | split("\t") | {key: .[0], value: (.[1] // "")}] | from_entries' \
  "$REPORT_DIGEST_TSV" > "$REPORT_DIGEST_FILE"

if [ -f "$DATA/done-archive.md" ]; then
  awk '
    /^[-*][[:space:]]+\[[xX]\][[:space:]]+[^[:space:]]+/ {
      line=$0
      sub(/^[-*][[:space:]]+\[[xX]\][[:space:]]+/, "", line)
      sub(/[[:space:]].*$/, "", line)
      print line
    }
  ' "$DATA/done-archive.md" | jq -Rn '[inputs]' > "$ARCHIVE_IDS_FILE"
else
  printf '[]\n' > "$ARCHIVE_IDS_FILE"
fi

# The fold skips a malformed ledger row rather than dying on it, which keeps the fleet
# readable through a corrupt write. Accounting for those skips is what makes them
# repairable instead of merely survivable.
fm_triage_ledger_health "$(fm_triage_ledger_path "$DATA")" > "$HEALTH_FILE"

# --- Enumerate candidates. ----------------------------------------------------------
# Action class is assigned deterministically, and stays deliberately conservative. Only a
# correction that is mechanically known is AUTO_COORDINATION: a backlog row whose blocker
# is proven done, or an active task simply missing its backlog row. Anything that needs
# prose read, evidence matched, or overlap judged is FIRSTMATE_JUDGMENT.
#
# CAPTAIN_GATE is reserved for genuine product semantics, and is chosen by the item's VERB,
# never by its lane. Hard-gating the whole visibility lane escalated ordinary engineering
# defects to the captain - a datetime bug, leaking test files, a scout task missing from
# the backlog - as though each were a product decision. Once the triage duty fires
# automatically, that is a captain-spam loop rather than a mis-labelled report.
jq -s '
  def action_class:
    if .lane == "backlog_hygiene" and .status == "blocker_done" then "AUTO_COORDINATION"
    elif .action == "restore_active_visibility" then "AUTO_COORDINATION"
    elif .action == "review_visibility_umbrella" then "CAPTAIN_GATE"
    elif .action == "prepare_captain_decision" then "CAPTAIN_GATE"
    else "FIRSTMATE_JUDGMENT" end;

  # The verb an order needs next, most urgent first. Recording an order is never launching
  # a crew, so none of these verbs dispatch anything; they say what the order is waiting on.
  def order_action:
    if .captain_decision_required then "prepare_captain_decision"
    elif (.attention_reasons | index("successor_missing")) then "relink_vanished_successor"
    elif (.attention_reasons | index("untriaged")) then "triage_captain_order"
    elif (.attention_reasons | index("missing_lineage")) then "record_order_lineage"
    elif (.attention_reasons | index("blocker_cleared")) then "dispatch_unblocked_order"
    elif (.attention_reasons | index("hold_expired")) then "review_order_hold"
    elif (.attention_reasons | index("ownerless")) then "assign_order_owner"
    else "review_stale_order" end;

  # A backlog row joins the visibility lane only by carrying an explicit triage marker in
  # its metadata parens - the same (key: value) convention the backlog already uses for
  # repo, kind, and priority:
  #   (repo: firstmate, triage: visibility)            an engineering visibility gap
  #   (repo: firstmate, triage: visibility-umbrella)   standing product-semantics work
  # The retired selector matched the words "visibility", "history", or "never drop" as
  # substrings of a row TITLE, so any backlog item merely containing the word "history" was
  # pulled into the lane and escalated. It also hardcoded one captain personal backlog id
  # into what AGENTS.md calls a shared template. A declared marker is durable under both
  # rewording and reuse; a keyword and an id are neither.
  def triage_marker:
    ((.raw // "")
     | capture("(?:^|[(,])[[:space:]]*triage:[[:space:]]*(?<v>[A-Za-z0-9_-]+)"; "i")
     | .v | ascii_downcase) // "";

  .[0] as $snapshot
  | .[1] as $nf
  | .[2] as $bugs
  | .[3] as $archive_ids
  | .[4] as $report_digests
  | .[5] as $ledger_health
  | .[6] as $live_orders
  | .[7] as $visibility_audit
  | ($snapshot.backlog.records // []) as $records
  | ($records | map(select(.structured == true))) as $structured
  | ($snapshot.scout_reports // []) as $reports
  # Every id the fleet can still point at. The captain-order lane needs this BEFORE the
  # items are assembled, because an order whose linked task has vanished is only visible
  # from here: the inbox knows what an order was linked to, not whether that still exists.
  | (($structured | map(.id)) + ($reports | map(.id)) + ($bugs | map(.id))
     + (($snapshot.tasks // []) | map(.id)) + $archive_ids | unique) as $fleet_ids
  | [ $live_orders[]
      | . as $o
      # A vanished successor leads the reasons it is found with: an order pointing at work
      # that no longer exists is not merely ownerless or stale, it is unlinked from the
      # fleet entirely, and that is what to fix first.
      | ((if (($o.links // []) | length) > 0
             and ([ ($o.links // [])[] | select(($fleet_ids | index(.)) == null) ] | length) > 0
          then ["successor_missing"] else [] end)
         + (.attention_reasons // [])) as $reasons
      | select(($reasons | length) > 0 or ($o.captain_decision_required // false))
      | $o + {attention_reasons: $reasons,
              attention: ($reasons[0] // "captain_decision"),
              action: ($o + {attention_reasons: $reasons} | order_action)}
      | del(.inbox_actionable) ] as $order_items
  | ($nf + $bugs + $order_items
     + [ $reports[]
         | . as $report
         | select(($structured | any(.id == $report.id)) | not)
         | select(($archive_ids | index($report.id)) == null)
         | {lane:"scout_reports",id:$report.id,title:("Unreconciled scout report " + $report.id),
            status:"unreconciled",source:$report.path,source_type:"report",
            report_digest:($report_digests[$report.id] // ""),
            action:"review_report_follow_up"} ]
     + [ $records[]
         | select(.state == "queued" and .structured == true and (.blocked_by // null) == null)
         | {lane:"backlog_hygiene",id:.id,title:(.title // .raw),status:"ready",
            blocked_by:null,source:"data/backlog.md",source_type:"backlog",
            action:"consider_dispatch"} ]
     + [ $records[]
         | select(.state == "queued" and .structured == true and (.blocked_by // null) != null)
         | . as $row
         | select($structured | any(.id == $row.blocked_by and .state == "done"))
         | {lane:"backlog_hygiene",id:.id,title:(.title // .raw),status:"blocker_done",
            blocked_by:.blocked_by,source:"data/backlog.md",source_type:"backlog",
            action:"unblock_or_dispatch"} ]
     + [ $records[]
         | select((.state == "in_flight" or .state == "queued") and .structured == false)
         | {lane:"backlog_hygiene",id:("unstructured-" + (.order|tostring)),title:.raw,
            status:"unstructured",blocked_by:null,source:"data/backlog.md",
            source_type:"backlog",action:"normalize_backlog_row"} ]
     + [ $structured
         | group_by(.id)[]
         | select(length > 1 and (map(.state) | unique | length) < length)
         | {lane:"backlog_hygiene",id:.[0].id,
            title:("Duplicate active backlog rows for " + .[0].id),status:"duplicate",
            blocked_by:null,source:"data/backlog.md",source_type:"backlog",
            action:"reconcile_duplicate"} ]
     + [ $records[]
         | select(.structured == true and .state != "done")
         | . as $row
         | ($row | triage_marker) as $marker
         | select($marker == "visibility" or $marker == "visibility-umbrella")
         | {lane:"visibility_history",id:.id,title:(.title // .raw),status:.state,
            source:"data/backlog.md",source_type:"backlog",
            action:(if $marker == "visibility-umbrella" then "review_visibility_umbrella"
                    else "reconcile_visibility_gap" end)} ]
     + [ ($visibility_audit.diagnostics // [])[]
         | {lane:"visibility_history",id:(.fingerprint // .recordId // .code // .type // "visibility-audit"),
            title:(.message // .reason // "Visibility audit finding"),status:(.code // .type // "audit_finding"),
            source:"visibility audit --json",source_type:"visibility_audit",action:"reconcile_visibility_gap"} ]
     + [ $ledger_health
         | select(.malformed_rows > 0)
         | {lane:"ledger_health",
            id:(.path | split("/") | last),
            title:("Malformed rows in the triage ledger: " + (.malformed_rows | tostring)
                   + " of " + (.total_rows | tostring) + " rows, first at line "
                   + ((.rows[0].line // 0) | tostring)),
            status:("malformed_rows:" + (.malformed_rows | tostring)),
            source:.path,
            source_type:"ledger",
            malformed_rows:.malformed_rows,
            malformed_row_refs:.rows,
            action:"repair_ledger_rows"} ]
     + [ ($snapshot.tasks // [])[]
         | . as $task
         | select(.kind != "secondmate")
         | select(($structured | any(.id == $task.id)) | not)
         | {lane:"visibility_history",id:$task.id,
            title:("Active task missing from backlog: " + $task.id),
            status:($task.current_state.state // "unknown"),source:$task.paths.meta.path,
            source_type:"task",action:"restore_active_visibility"} ])
  | unique_by([.lane,.id,.action])
  | sort_by(.lane,.id)
  | map(. + {item_id: (.lane + ":" + .id),
             action_class: action_class,
             reason_codes: [.status],
             proposed_action: {verb: .action, source: .source}})
  # Known ids let the self-audit tell a linked successor that exists from one that does not.
  # Captain order ids join them, so a triage outcome may legitimately link to the order it
  # came from.
  | {items: .,
     known_ids: ($fleet_ids + ($live_orders | map(.id)) | unique)}
' "$SNAPSHOT_FILE" "$NF_FILE" "$BUG_FILE" "$ARCHIVE_IDS_FILE" \
  "$REPORT_DIGEST_FILE" "$HEALTH_FILE" "$ORDERS_FILE" "$VISIBILITY_AUDIT_FILE" > "$RAW_ITEMS"

# --- Evidence versions: structured fields only, never prose. -------------------------
# fm_triage_evidence_version names the participating fields per lane. A title or report
# body edit must not mint a new logical item, so neither takes part in the hash.
: > "$EV_TSV"
while IFS= read -r item; do
  printf '%s\t%s\n' \
    "$(printf '%s' "$item" | jq -r '.item_id')" \
    "$(printf '%s' "$item" | fm_triage_evidence_version)" >> "$EV_TSV"
done < <(jq -c '.items[]' "$RAW_ITEMS")
jq -Rn '[inputs | split("\t") | {key: .[0], value: .[1]}] | from_entries' "$EV_TSV" > "$EV_FILE"

fm_triage_fold "$(fm_triage_ledger_path "$DATA")" > "$FOLD_FILE"

NOW_TS=$(fm_triage_now)
NOW_EPOCH=$(fm_triage_epoch "$NOW_TS")

# --- Merge ledger state, run the self-audit, compute metrics. ------------------------
RESULT=$(jq -n \
  --arg fm_home "$FM_HOME" \
  --arg ledger "$(fm_triage_ledger_path "$DATA")" \
  --arg mode "$(fm_triage_mode)" \
  --arg now "$NOW_TS" \
  --argjson now_epoch "$NOW_EPOCH" \
  --argjson stale_secs "$STALE_SECS" \
  --argjson claim_ttl "$CLAIM_TTL" \
  --argjson nf_available "$NF_AVAILABLE" \
  --arg nf_note "$NF_NOTE" \
  --argjson bug_available "$BUG_AVAILABLE" \
  --arg bug_note "$BUG_NOTE" \
  --argjson orders_available "$ORDERS_AVAILABLE" \
  --arg orders_note "$ORDERS_NOTE" \
  --argjson orders_metrics "$ORDERS_METRICS" \
  --slurpfile raw "$RAW_ITEMS" \
  --slurpfile fold "$FOLD_FILE" \
  --slurpfile health "$HEALTH_FILE" \
  --slurpfile ev "$EV_FILE" '
  # Seconds since an ISO-8601 stamp, or null when absent or unparseable.
  def age($ts; $now_epoch):
    if ($ts // "") == "" then null
    else ($ts | try (fromdateiso8601 | $now_epoch - .) catch null) end;

  # A terminal outcome is only real with its lineage attached. This mirrors the writers
  # refusal, and catches any ledger row that bypassed it (a hand-append, an old format).
  def lineage_ok:
    (.outcome_type // "") as $o
    | if $o == "" then true
      elif $o == "successor_created" or $o == "resolved" or $o == "captain_batch"
        then ((.outcome_link // "") != "")
      elif $o == "rejected" then ((.outcome_reason // "") != "")
      elif $o == "held" then ((.outcome_reason // "") != "" and (.review_after // "") != "")
      else false end;

  ($raw[0].items // []) as $items
  | ($raw[0].known_ids // []) as $known
  | ($fold[0] // {}) as $ledger_state
  | ($health[0] // {}) as $ledger_health
  | ($ev[0] // {}) as $evmap

  | [ $items[]
      | . as $item
      | ($ledger_state[$item.item_id] // {}) as $f
      | ($evmap[$item.item_id] // "") as $cur
      | ($f.processing_state // "new") as $ps
      | ($f.outcome_type // "") as $o
      | (if $o != "" and (($f | lineage_ok) | not) then "dangling_outcome"
         elif $o == "successor_created"
           and (($known | index($f.outcome_link // "")) == null) then "successor_missing"
         elif ($f.evidence_version // "") != "" and $f.evidence_version != $cur
           then "evidence_changed"
         elif $ps == "held"
           and (age($f.review_after; $now_epoch) as $a | $a != null and $a >= 0)
           then "hold_expired"
         elif $ps == "claimed"
           and (age($f.claimed_at; $now_epoch) as $a | $a != null and $a > $claim_ttl)
           then "claim_abandoned"
         elif $ps == "claimed" and (($f.owner // "") == "") then "owner_missing"
         elif ($ps != "terminal" and $ps != "held")
           and (age($f.first_seen_at; $now_epoch) as $a | $a != null and $a > $stale_secs)
           then "stale_unprocessed"
         else "ok" end) as $health
      | $item + {
          schema_version: "fm-fleet-triage/v2",
          source_id: $item.id,
          evidence_refs: [$item.source],
          evidence_version: $cur,
          first_seen_at: ($f.first_seen_at // $now),
          last_seen_at: $now,
          age_seconds: (age($f.first_seen_at; $now_epoch) // 0),
          processing_state: $ps,
          owner: ($f.owner // null),
          outcome_type: ($f.outcome_type // null),
          outcome_link: ($f.outcome_link // null),
          outcome_reason: ($f.outcome_reason // null),
          decided_by: ($f.decided_by // null),
          decided_at: ($f.decided_at // null),
          review_after: ($f.review_after // null),
          health: $health,
          # An item needs attention while it is new or surfaced, and again whenever the
          # self-audit finds its recorded disposition no longer holds. A terminal outcome
          # retires an item only while it stays healthy.
          actionable: (($ps == "new" or $ps == "surfaced") or $health != "ok")
        } ]
  | sort_by(.lane, .item_id) as $all
  | ($all | map(select(.actionable))) as $act

  | {
      schema: "fm-fleet-triage/v2",
      fm_home: $fm_home,
      read_only: true,
      mode: $mode,
      generated_at: $now,
      ledger: {path: $ledger,
               format: "append-only JSONL, firstmate/fleet-triage-item/v1",
               writer: "bin/fm-fleet-triage-record.sh"},
      metrics: {
        # The metrics the captain-order inbox computes for itself, carried verbatim from
        # that authoritative source rather than recomputed here: this lane references the
        # inbox, it does not become a second one.
        captain_orders: $orders_metrics,
        # Rows the fold had to skip. Reported as a count with line references, and as
        # exactly ONE stable item in the ledger_health lane however many rows are bad, so
        # a corrupt ledger can never grow a chain of triage-about-triage items.
        ledger_health: {
          malformed_rows: ($ledger_health.malformed_rows // 0),
          total_rows: ($ledger_health.total_rows // 0),
          rows: ($ledger_health.rows // [])
        },
        total: ($all | length),
        actionable: ($act | length),
        terminal: ($all | map(select(.processing_state == "terminal" and .health == "ok")) | length),
        ownerless: ($act | map(select(.owner == null)) | length),
        captain_gated: ($act | map(select(.action_class == "CAPTAIN_GATE")) | length),
        auto_coordination: ($act | map(select(.action_class == "AUTO_COORDINATION")) | length),
        by_lane: (["captain_orders","needs_firstmate","bugs","scout_reports",
                   "backlog_hygiene","visibility_history","ledger_health"]
                  | map(. as $l
                        | {key: $l,
                           value: (($act | map(select(.lane == $l))) as $in
                                   | {actionable: ($in | length),
                                      oldest_age_seconds: (($in | map(.age_seconds) | max) // 0)})})
                  | from_entries),
        health: ($act | map(.health) | group_by(.)
                 | map({key: .[0], value: length}) | from_entries)
      },
      lanes: {
        captain_orders: {available: $orders_available, note: $orders_note,
                         items: [$all[] | select(.lane == "captain_orders")]},
        needs_firstmate: {available: $nf_available, note: $nf_note,
                          items: [$all[] | select(.lane == "needs_firstmate")]},
        bugs: {available: $bug_available, note: $bug_note,
               items: [$all[] | select(.lane == "bugs")]},
        scout_reports: {available: true, note: "reports without a matching backlog row",
                        items: [$all[] | select(.lane == "scout_reports")]},
        backlog_hygiene: {available: true,
                          note: "ready, newly unblocked, duplicate, and unstructured backlog candidates",
                          items: [$all[] | select(.lane == "backlog_hygiene")]},
        visibility_history: {available: true,
                             note: "backlog rows marked (triage: visibility|visibility-umbrella) and active tasks missing from the backlog",
                             items: [$all[] | select(.lane == "visibility_history")]},
        ledger_health: {available: true,
                        note: "malformed ledger rows the fold had to skip",
                        items: [$all[] | select(.lane == "ledger_health")]}
      },
      items: $all
    }
')

if [ "$MODE" = --json ]; then
  printf '%s\n' "$RESULT"
  exit 0
fi

# --- Digest. ------------------------------------------------------------------------
# Shared with bin/fm-triage-duty.sh (fm_triage_render_digest in fm-fleet-triage-lib.sh)
# so the two presentations of one enumeration never drift into two implementations.
printf '%s' "$RESULT" | fm_triage_render_digest "$MAX_ITEMS"
exit 0

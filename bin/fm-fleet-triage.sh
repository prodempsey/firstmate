#!/usr/bin/env bash
# Enumerate deterministic fleet-triage candidates without changing fleet state.
#
# Usage:
#   fm-fleet-triage.sh --digest
#   fm-fleet-triage.sh --json
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
#   FM_FLEET_TRIAGE_DIGEST_MAX_ITEMS   digest item cap (default 8)
#   FM_FLEET_TRIAGE_STALE_SECS         age at which an unprocessed item is stale (86400)
#   FM_FLEET_TRIAGE_CLAIM_TTL_SECS     age at which a claim is abandoned (3600)
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

# shellcheck disable=SC1091 # Dynamic sibling path is resolved from BASH_SOURCE.
. "$SCRIPT_DIR/fm-fleet-triage-lib.sh"

usage() {
  cat <<'EOF'
usage: fm-fleet-triage.sh [--digest|--json]

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

The bugs lane uses FM_FLEET_TRIAGE_BUG_CLI when set, then the sanctioned `bug` command
on PATH, through `<cli> list --json`. Set FM_FLEET_TRIAGE_BUG_CLI=off to disable it.
EOF
}

case "$MODE" in
  --digest|--json) [ "$#" -eq 1 ] || { usage >&2; exit 2; } ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

case "$MAX_ITEMS" in ''|*[!0-9]*) MAX_ITEMS=8 ;; esac
case "$STALE_SECS" in ''|*[!0-9]*) STALE_SECS=86400 ;; esac
case "$CLAIM_TTL" in ''|*[!0-9]*) CLAIM_TTL=3600 ;; esac

command -v jq >/dev/null 2>&1 || {
  printf 'fm-fleet-triage: jq not found\n' >&2
  exit 1
}

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-fleet-triage.XXXXXX")
# shellcheck disable=SC2317 # Invoked by the EXIT trap below.
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

SNAPSHOT_FILE="$TMP_ROOT/snapshot.json"
NF_FILE="$TMP_ROOT/nf.json"
BUG_FILE="$TMP_ROOT/bugs.json"
ARCHIVE_IDS_FILE="$TMP_ROOT/archive-ids.json"
RAW_ITEMS="$TMP_ROOT/raw-items.json"
FOLD_FILE="$TMP_ROOT/fold.json"
EV_TSV="$TMP_ROOT/evidence.tsv"
EV_FILE="$TMP_ROOT/evidence.json"

FM_ROOT_OVERRIDE="$FM_ROOT" \
  FM_HOME="$FM_HOME" \
  FM_STATE_OVERRIDE="$STATE" \
  FM_DATA_OVERRIDE="$DATA" \
  "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json > "$SNAPSHOT_FILE"

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
      printf '%s' "$BUG_RAW" | jq '
        [ .[]
          | select((.status // "open") != "resolved")
          | {lane:"bugs",
             id:(.id // .bug_id // ("bug-" + ((.title // .sourceText // "untitled") | @base64))),
             title:(.title // .sourceText // "Untitled open bug"),
             status:(.status // "open"),
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

# --- Enumerate candidates. ----------------------------------------------------------
# Action class is assigned deterministically from lane and status, and stays deliberately
# conservative. Only a backlog item whose blocker is mechanically proven done is
# AUTO_COORDINATION. Anything that needs prose read, evidence matched, or overlap judged
# is FIRSTMATE_JUDGMENT, and the visibility lane is CAPTAIN_GATE because it turns on
# product semantics rather than engineering mechanics.
jq -s '
  def action_class:
    if .lane == "backlog_hygiene" and .status == "blocker_done" then "AUTO_COORDINATION"
    elif .lane == "visibility_history" then "CAPTAIN_GATE"
    else "FIRSTMATE_JUDGMENT" end;

  .[0] as $snapshot
  | .[1] as $nf
  | .[2] as $bugs
  | .[3] as $archive_ids
  | ($snapshot.backlog.records // []) as $records
  | ($records | map(select(.structured == true))) as $structured
  | ($snapshot.scout_reports // []) as $reports
  | ($nf + $bugs
     + [ $reports[]
         | . as $report
         | select(($structured | any(.id == $report.id)) | not)
         | select(($archive_ids | index($report.id)) == null)
         | {lane:"scout_reports",id:$report.id,title:("Unreconciled scout report " + $report.id),
            status:"unreconciled",source:$report.path,source_type:"report",
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
         | select(.structured == true and ((.id == "visibility-never-drop-s5") or ((.title // "") | test("visibility|history|never drop"; "i"))))
         | select(.state != "done")
         | {lane:"visibility_history",id:.id,title:(.title // .raw),status:.state,
            source:"data/backlog.md",source_type:"backlog",action:"reconcile_visibility_gap"} ]
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
  | {items: .,
     known_ids: (($structured | map(.id))
                 + ($reports | map(.id))
                 + ($bugs | map(.id))
                 + (($snapshot.tasks // []) | map(.id))
                 + $archive_ids | unique)}
' "$SNAPSHOT_FILE" "$NF_FILE" "$BUG_FILE" "$ARCHIVE_IDS_FILE" > "$RAW_ITEMS"

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
  --slurpfile raw "$RAW_ITEMS" \
  --slurpfile fold "$FOLD_FILE" \
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
        total: ($all | length),
        actionable: ($act | length),
        terminal: ($all | map(select(.processing_state == "terminal" and .health == "ok")) | length),
        ownerless: ($act | map(select(.owner == null)) | length),
        captain_gated: ($act | map(select(.action_class == "CAPTAIN_GATE")) | length),
        auto_coordination: ($act | map(select(.action_class == "AUTO_COORDINATION")) | length),
        by_lane: (["needs_firstmate","bugs","scout_reports","backlog_hygiene","visibility_history"]
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
                             note: "active visibility and history umbrella work",
                             items: [$all[] | select(.lane == "visibility_history")]}
      },
      items: $all
    }
')

if [ "$MODE" = --json ]; then
  printf '%s\n' "$RESULT"
  exit 0
fi

# --- Digest. ------------------------------------------------------------------------
printf '%s' "$RESULT" | jq -r --argjson max "$MAX_ITEMS" '
  def dur($s):
    if $s == null or $s < 60 then "new"
    elif $s < 3600 then ((($s / 60) | floor | tostring) + "m")
    elif $s < 86400 then ((($s / 3600) | floor | tostring) + "h")
    else ((($s / 86400) | floor | tostring) + "d") end;

  .metrics as $m
  | ["FLEET TRIAGE: " + ($m.actionable | tostring) + " actionable, "
      + ($m.total | tostring) + " total (mode: " + .mode + ")",
     "  ownerless: " + ($m.ownerless | tostring)
      + " | captain-gated: " + ($m.captain_gated | tostring)
      + " | auto-coordination: " + ($m.auto_coordination | tostring)]
  + [ .lanes | to_entries[]
      | .key as $k
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
exit 0

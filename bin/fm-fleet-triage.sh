#!/usr/bin/env bash
# Enumerate deterministic fleet-triage candidates without changing fleet state.
#
# Usage:
#   fm-fleet-triage.sh --digest
#   fm-fleet-triage.sh --json
#
# The JSON contract is fm-fleet-triage/v1.
# The acknowledgement ledger is state/.fleet-triage-handled with one
# tab-separated lane, item id, and fingerprint per line.
# This command only reads that ledger.
# An operator records an acknowledgement after disposition by appending the
# exact lane, id, and fingerprint tuple from the JSON output.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LEDGER="$STATE/.fleet-triage-handled"
MODE=${1:---digest}
MAX_ITEMS=${FM_FLEET_TRIAGE_DIGEST_MAX_ITEMS:-8}

usage() {
  cat <<'EOF'
usage: fm-fleet-triage.sh [--digest|--json]

Print a token-capped digest or the full fm-fleet-triage/v1 JSON object.
The command is read-only and never acknowledges, merges, tears down, or edits
the backlog.

Acknowledgement ledger format:
  <lane><TAB><item-id><TAB><fingerprint>

Append a tuple only after the corresponding candidate has been dispositioned.
An unchanged acknowledged candidate remains in JSON with handled=true and is
omitted from the digest until its fingerprint changes.

The bugs lane uses FM_FLEET_TRIAGE_BUG_CLI when set, then the sanctioned `bug`
command on PATH, through `<cli> list --json`.
Set FM_FLEET_TRIAGE_BUG_CLI=off to disable bug discovery explicitly.
EOF
}

case "$MODE" in
  --digest|--json) [ "$#" -eq 1 ] || { usage >&2; exit 2; } ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

case "$MAX_ITEMS" in
  ''|*[!0-9]*) MAX_ITEMS=8 ;;
esac

command -v jq >/dev/null 2>&1 || {
  printf 'fm-fleet-triage: jq not found\n' >&2
  exit 1
}

hash_text() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    cksum | awk '{print "cksum-" $1 "-" $2}'
  fi
}

is_handled() {  # <lane> <id> <fingerprint>
  local lane=$1 id=$2 fingerprint=$3 key
  [ -f "$LEDGER" ] || return 1
  key=$(printf '%s\t%s\t%s' "$lane" "$id" "$fingerprint")
  grep -Fqx -- "$key" "$LEDGER" 2>/dev/null
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
ITEMS_FILE="$TMP_ROOT/items.json"

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
       | {lane:"needs_firstmate",id:.[0],title:.[1],status:.[2],source:"fm-nf-reconcile",source_fingerprint:.[3],action:"review_terminal_signal"}]
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

jq -s '
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
         | {lane:"scout_reports",id:$report.id,title:("Unreconciled scout report " + $report.id),status:"unreconciled",source:$report.path,action:"review_report_follow_up"} ]
     + [ $records[]
         | select(.state == "queued" and .structured == true and (.blocked_by // null) == null)
         | {lane:"backlog_hygiene",id:.id,title:(.title // .raw),status:"ready",source:"data/backlog.md",action:"consider_dispatch"} ]
     + [ $records[]
         | select(.state == "queued" and .structured == true and (.blocked_by // null) != null)
         | . as $row
         | select($structured | any(.id == $row.blocked_by and .state == "done"))
         | {lane:"backlog_hygiene",id:.id,title:(.title // .raw),status:"blocker_done",source:"data/backlog.md",action:"unblock_or_dispatch"} ]
     + [ $records[]
         | select((.state == "in_flight" or .state == "queued") and .structured == false)
         | {lane:"backlog_hygiene",id:("unstructured-" + (.order|tostring)),title:.raw,status:"unstructured",source:"data/backlog.md",action:"normalize_backlog_row"} ]
     + [ $structured
         | group_by(.id)[]
         | select(length > 1 and (map(.state) | unique | length) < length)
         | {lane:"backlog_hygiene",id:.[0].id,title:("Duplicate active backlog rows for " + .[0].id),status:"duplicate",source:"data/backlog.md",action:"reconcile_duplicate"} ]
     + [ $records[]
         | select(.structured == true and ((.id == "visibility-never-drop-s5") or ((.title // "") | test("visibility|history|never drop"; "i"))))
         | select(.state != "done")
         | {lane:"visibility_history",id:.id,title:(.title // .raw),status:.state,source:"data/backlog.md",action:"reconcile_visibility_gap"} ]
     + [ ($snapshot.tasks // [])[]
         | . as $task
         | select(.kind != "secondmate")
         | select(($structured | any(.id == $task.id)) | not)
         | {lane:"visibility_history",id:$task.id,title:("Active task missing from backlog: " + $task.id),status:($task.current_state.state // "unknown"),source:$task.paths.meta.path,action:"restore_active_visibility"} ])
  | unique_by([.lane,.id,.action])
  | sort_by(.lane,.id)
' "$SNAPSHOT_FILE" "$NF_FILE" "$BUG_FILE" "$ARCHIVE_IDS_FILE" > "$RAW_ITEMS"

printf '[]\n' > "$ITEMS_FILE"
while IFS= read -r item; do
  lane=$(printf '%s' "$item" | jq -r '.lane')
  id=$(printf '%s' "$item" | jq -r '.id')
  canonical=$(printf '%s' "$item" | jq -cS 'del(.fingerprint,.handled)')
  fingerprint=$(printf '%s' "$canonical" | hash_text)
  handled=false
  is_handled "$lane" "$id" "$fingerprint" && handled=true
  jq --arg fingerprint "$fingerprint" --argjson handled "$handled" \
    '. + {fingerprint:$fingerprint,handled:$handled}' <<< "$item" \
    | jq -s --slurpfile existing "$ITEMS_FILE" '$existing[0] + .' > "$ITEMS_FILE.next"
  mv "$ITEMS_FILE.next" "$ITEMS_FILE"
done < <(jq -c '.[]' "$RAW_ITEMS")

RESULT=$(jq -n \
  --arg fm_home "$FM_HOME" \
  --arg ledger "$LEDGER" \
  --argjson nf_available "$NF_AVAILABLE" \
  --arg nf_note "$NF_NOTE" \
  --argjson bug_available "$BUG_AVAILABLE" \
  --arg bug_note "$BUG_NOTE" \
  --slurpfile items "$ITEMS_FILE" '
  ($items[0] // []) as $all
  | {
      schema:"fm-fleet-triage/v1",
      fm_home:$fm_home,
      read_only:true,
      handled_ledger:{path:$ledger,format:"lane<TAB>id<TAB>fingerprint"},
      summary:{
        total:($all|length),
        unhandled:([$all[]|select(.handled == false)]|length),
        handled:([$all[]|select(.handled == true)]|length)
      },
      lanes:{
        needs_firstmate:{available:$nf_available,note:$nf_note,items:[$all[]|select(.lane == "needs_firstmate")]},
        bugs:{available:$bug_available,note:$bug_note,items:[$all[]|select(.lane == "bugs")]},
        scout_reports:{available:true,note:"reports without a matching backlog row",items:[$all[]|select(.lane == "scout_reports")]},
        backlog_hygiene:{available:true,note:"ready, newly unblocked, duplicate, and unstructured backlog candidates",items:[$all[]|select(.lane == "backlog_hygiene")]},
        visibility_history:{available:true,note:"active visibility and history umbrella work",items:[$all[]|select(.lane == "visibility_history")]}
      },
      items:$all
    }
')

if [ "$MODE" = --json ]; then
  printf '%s\n' "$RESULT"
  exit 0
fi

unhandled=$(printf '%s' "$RESULT" | jq -r '.summary.unhandled')
total=$(printf '%s' "$RESULT" | jq -r '.summary.total')
printf 'FLEET TRIAGE: %s unhandled candidate(s), %s total\n' "$unhandled" "$total"
printf '%s' "$RESULT" | jq -r '
  .lanes
  | to_entries[]
  | "  " + (.key|gsub("_";" ")) + ": " + (([.value.items[]|select(.handled == false)]|length)|tostring)
    + (if .value.available then "" else " (unavailable: " + .value.note + ")" end)
'
printf '%s' "$RESULT" | jq -r --argjson max "$MAX_ITEMS" '
  [.items[]|select(.handled == false)][:$max][]
  | "  - [" + (.lane|gsub("_";" ")) + "] " + .id + ": " + (.title|gsub("[[:space:]]+";" "))
' | cut -c1-200
remaining=$((unhandled - MAX_ITEMS))
[ "$remaining" -gt 0 ] && printf '  - and %s more; run bin/fm-fleet-triage.sh --json for full detail\n' "$remaining"
exit 0

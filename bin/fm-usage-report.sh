#!/usr/bin/env bash
# fm-usage-report.sh - captain-readable model-economy usage report (Slice M1).
#
# Reads task ROUTING PROVENANCE from a target FM_HOME and writes a model-mix
# report: how many tasks ran on each harness/model/effort, split by kind and by
# repo. This slice (M1) is model-MIX only. It does NOT parse harness session
# files for tokens or spend; the token/spend/counterfactual panels are present
# in the output as labeled, not-yet-implemented scaffolding so the later slices
# (M2 Claude tokens, M3 Codex tokens, M4 pricing/spend, M5 counterfactual) slot
# in without reshaping the report. Design authority:
#   /home/prode/fleet/firstmate-runtime/data/model-economy-measure-s1/report.md
#   sections 2.1 (field inventory), 3.2-3.3 (report shape), 3.5 (confidence).
#
# INPUTS (read-only; this script never mutates its inputs):
#   $STATE/*.meta            live tasks. key=val lines; task id is the filename.
#                            fields used: harness, model, effort, kind, project,
#                            spawned_at, and (when present) profile, class,
#                            provider. Written by bin/fm-spawn.sh /
#                            bin/fm-spawn-profile.sh.
#   $STATE/task-runs.jsonl   closed tasks. schema task_run/1, one JSON row each,
#                            appended at teardown by bin/fm-teardown.sh. Has no
#                            profile/class (report section 2.1.B).
# A task present in BOTH is counted once, preferring the live meta (report 3.3).
#
# OUTPUTS (under --out, default $TARGET/data/model-economy/usage/):
#   latest.md                human report (overwritten each run)
#   latest.json              machine report, same numbers (schema fm-usage-report/1)
#   history/usage-<UTC>.{md,json}   immutable dated archive copy of this run
#   index.jsonl              one appended line per run: {ts,since,until,path,fingerprint}
#
# HOME/STATE/OUT resolution:
#   TARGET = --target DIR, else FM_HOME, else FM_ROOT_OVERRIDE, else repo root.
#   STATE  = FM_STATE_OVERRIDE, else $TARGET/state.
#   OUT    = --out DIR, else $TARGET/data/model-economy/usage.
# So a caller can scope inputs with --target OR FM_STATE_OVERRIDE, and outputs
# with --out; tests use a mktemp sandbox and never touch a live home.
#
# WINDOW: tasks are included when their timestamp (meta spawned_at; task-run
# ended_at then spawned_at) falls in [--since, --until]. Defaults: since = 7 days
# before now, until = now (report 3.1). A task with no parseable timestamp cannot
# be windowed, so it is always included and counted under totals.undated. A
# date-only --since is start-of-day UTC; a date-only --until is end-of-day UTC.
#
# DETERMINISM: given fixed inputs and an explicit window, the mix tables and the
# fingerprint are deterministic (the fingerprint deliberately excludes the wall
# clock). Set FM_USAGE_NOW=<ISO-8601 UTC> to pin "now" for reproducible runs.
#
# Usage:
#   fm-usage-report.sh [--target DIR] [--since DATE] [--until DATE]
#                      [--out DIR] [--json] [-h|--help]
# Exit: 0 on a written report; 2 on a usage/argument error; 3 if jq is missing.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  cat <<'EOF'
fm-usage-report.sh - model-economy usage report (slice M1: model mix only)

Usage:
  fm-usage-report.sh [--target DIR] [--since DATE] [--until DATE]
                     [--out DIR] [--json] [-h|--help]

  --target DIR   FM_HOME to report on (default: resolved home). --home is an alias.
  --since DATE   window start; ISO-8601 or YYYY-MM-DD (default: 7 days before now)
  --until DATE   window end;   ISO-8601 or YYYY-MM-DD (default: now)
  --out DIR      output dir (default: <target>/data/model-economy/usage)
  --json         print the machine report to stdout instead of the summary

Writes latest.{md,json}, a dated history/ archive copy, and an index.jsonl line.
Read-only against its inputs. Set FM_USAGE_NOW=<ISO> to pin the clock.
EOF
}

TARGET=""
OPT_SINCE=""
OPT_UNTIL=""
OPT_OUT=""
EMIT_JSON=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target|--home)
      [ "$#" -ge 2 ] || { echo "fm-usage-report: $1 needs a directory" >&2; exit 2; }
      TARGET="$2"; shift 2 ;;
    --since)
      [ "$#" -ge 2 ] || { echo "fm-usage-report: --since needs a date" >&2; exit 2; }
      OPT_SINCE="$2"; shift 2 ;;
    --until)
      [ "$#" -ge 2 ] || { echo "fm-usage-report: --until needs a date" >&2; exit 2; }
      OPT_UNTIL="$2"; shift 2 ;;
    --out)
      [ "$#" -ge 2 ] || { echo "fm-usage-report: --out needs a directory" >&2; exit 2; }
      OPT_OUT="$2"; shift 2 ;;
    --json) EMIT_JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "fm-usage-report: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "fm-usage-report: jq is required" >&2; exit 3; }

# --- resolve home, state, out ------------------------------------------------
if [ -n "$TARGET" ]; then
  TARGET="$(cd "$TARGET" 2>/dev/null && pwd)" \
    || { echo "fm-usage-report: --target directory not found" >&2; exit 2; }
else
  TARGET="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
fi
STATE="${FM_STATE_OVERRIDE:-$TARGET/state}"
OUT="${OPT_OUT:-$TARGET/data/model-economy/usage}"

# --- clock and window --------------------------------------------------------
# Empty input must NOT parse: GNU `date -d ''` silently returns the current time
# (rc 0), which would misdate every task with a missing timestamp as "now". A
# genuinely malformed timestamp still fails date's parse and prints nothing.
to_epoch() { [ -n "${1:-}" ] || return 0; date -u -d "$1" +%s 2>/dev/null || true; }

NOW_ISO="${FM_USAGE_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
NOW_EPOCH="$(to_epoch "$NOW_ISO")"
[ -n "$NOW_EPOCH" ] || { echo "fm-usage-report: unparseable FM_USAGE_NOW '$NOW_ISO'" >&2; exit 2; }

# Date-only bounds snap to the inclusive edge of the named UTC day.
norm_since() { case "$1" in ????-??-??) printf '%sT00:00:00Z' "$1" ;; *) printf '%s' "$1" ;; esac; }
norm_until() { case "$1" in ????-??-??) printf '%sT23:59:59Z' "$1" ;; *) printf '%s' "$1" ;; esac; }

SINCE_ISO="$(norm_since "${OPT_SINCE:-$(date -u -d "$NOW_ISO - 7 days" +%Y-%m-%dT%H:%M:%SZ)}")"
UNTIL_ISO="$(norm_until "${OPT_UNTIL:-$NOW_ISO}")"
SINCE_EPOCH="$(to_epoch "$SINCE_ISO")"
UNTIL_EPOCH="$(to_epoch "$UNTIL_ISO")"
[ -n "$SINCE_EPOCH" ] || { echo "fm-usage-report: unparseable --since '$SINCE_ISO'" >&2; exit 2; }
[ -n "$UNTIL_EPOCH" ] || { echo "fm-usage-report: unparseable --until '$UNTIL_ISO'" >&2; exit 2; }

# --- collect task records ----------------------------------------------------
# Emit one bounded JSON object per included task to an NDJSON temp file. jq reads
# it from the file (never from argv), so the accumulator cannot hit the argument
# limit as the fleet grows.
REC_FILE="$(mktemp "${TMPDIR:-/tmp}/fm-usage-recs.XXXXXX")"
trap 'rm -f "$REC_FILE"' EXIT

# in_window <epoch-or-empty> -> prints "yes"/"no"/"undated"
in_window() {
  local e="$1"
  [ -n "$e" ] || { printf 'undated'; return; }
  if [ "$e" -ge "$SINCE_EPOCH" ] && [ "$e" -le "$UNTIL_EPOCH" ]; then printf 'yes'; else printf 'no'; fi
}

emit_record() {  # <task> <source> <live-bool> <harness> <model> <effort> <kind> <repo> <profile> <class> <provider> <dated-bool>
  jq -n \
    --arg task "$1" --arg source "$2" --argjson live "$3" \
    --arg harness "${4:-}" --arg model "${5:-}" --arg effort "${6:-}" \
    --arg kind "${7:-}" --arg repo "${8:-}" \
    --arg profile "${9:-}" --arg class "${10:-}" --arg provider "${11:-}" \
    --argjson dated "${12}" '
    def blank(x): if x == "" then null else x end;
    def dflt(x): if x == "" then "default" else x end;
    {
      task: $task, source: $source, live: $live,
      harness: dflt($harness), model: dflt($model), effort: dflt($effort),
      kind: (if $kind == "" then "unknown" else $kind end),
      repo: (if $repo == "" then "unknown" else $repo end),
      profile: blank($profile), class: blank($class), provider: blank($provider),
      dated: $dated
    }' >> "$REC_FILE"
}

# Live metas first, and remember their task ids so a still-live task is not
# double-counted from the historical ledger.
declare -A SEEN=()
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  task="$(basename "$meta" .meta)"
  harness=""; model=""; effort=""; kind=""; project=""; spawned_at=""
  profile=""; class=""; provider=""
  while IFS='=' read -r k v; do
    case "$k" in
      harness) harness="$v" ;;
      model) model="$v" ;;
      effort) effort="$v" ;;
      kind) kind="$v" ;;
      project) project="$v" ;;
      spawned_at) spawned_at="$v" ;;
      profile) profile="$v" ;;
      class) class="$v" ;;
      provider) provider="$v" ;;
    esac
  done < "$meta"
  SEEN["$task"]=1
  repo=""; [ -n "$project" ] && repo="$(basename "$project")"
  ts_epoch="$(to_epoch "$spawned_at")"
  case "$(in_window "$ts_epoch")" in
    no) continue ;;
    undated) dated=false ;;
    *) dated=true ;;
  esac
  emit_record "$task" meta true "$harness" "$model" "$effort" "$kind" "$repo" \
    "$profile" "$class" "$provider" "$dated"
done

# Historical ledger for closed tasks not currently live.
LEDGER="$STATE/task-runs.jsonl"
if [ -f "$LEDGER" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    task="$(printf '%s' "$line" | jq -r '.task // empty' 2>/dev/null || true)"
    [ -n "$task" ] || continue
    [ -z "${SEEN[$task]:-}" ] || continue
    SEEN["$task"]=1
    # Join with the unit separator (0x1f), NOT a tab: with IFS set to a
    # whitespace character, `read` collapses runs of it and drops empty fields
    # (a null provider would then shift ts_iso off the end). 0x1f is
    # non-whitespace, so empty fields are preserved positionally.
    row="$(printf '%s' "$line" | jq -rj '
      [ (.harness // ""), (.model // ""), (.effort // ""), (.kind // ""),
        (.project // ""), (.provider // ""),
        (.ended_at // .spawned_at // "") ] | join("\u001f")' 2>/dev/null || true)"
    [ -n "$row" ] || continue
    IFS=$'\x1f' read -r harness model effort kind project provider ts_iso <<EOF
$row
EOF
    repo=""; [ -n "$project" ] && repo="$(basename "$project")"
    ts_epoch="$(to_epoch "$ts_iso")"
    case "$(in_window "$ts_epoch")" in
      no) continue ;;
      undated) dated=false ;;
      *) dated=true ;;
    esac
    emit_record "$task" task-run false "$harness" "$model" "$effort" "$kind" "$repo" \
      "" "" "$provider" "$dated"
  done < "$LEDGER"
fi

# --- build machine report (latest.json) --------------------------------------
mkdir -p "$OUT/history"
LATEST_JSON="$OUT/latest.json"
LATEST_MD="$OUT/latest.md"

jq -n \
  --slurpfile recs "$REC_FILE" \
  --arg generated_at "$NOW_ISO" \
  --arg since "$SINCE_ISO" \
  --arg until "$UNTIL_ISO" \
  --arg home "$TARGET" '
  ($recs) as $t |
  {
    schema: "fm-usage-report/1",
    slice: "M1",
    generated_at: $generated_at,
    window: { since: $since, until: $until },
    home: $home,
    sources: ["state/*.meta", "state/task-runs.jsonl"],
    totals: {
      tasks: ($t | length),
      live: ([ $t[] | select(.live) ] | length),
      closed: ([ $t[] | select(.live | not) ] | length),
      undated: ([ $t[] | select(.dated | not) ] | length)
    },
    panels: {
      model_mix: {
        confidence: "high",
        by_harness_model_effort: (
          $t | group_by([.harness, .model, .effort])
          | map({ harness: .[0].harness, model: .[0].model, effort: .[0].effort, count: length })
          | sort_by([ (-.count), .harness, .model, .effort ])
        ),
        by_kind: (
          $t | group_by(.kind)
          | map({ kind: .[0].kind, count: length })
          | sort_by([ (-.count), .kind ])
        ),
        by_repo: (
          $t | group_by(.repo)
          | map({ repo: .[0].repo, count: length })
          | sort_by([ (-.count), .repo ])
        ),
        by_profile: (
          [ $t[] | select(.profile != null) ]
          | group_by([.profile, (.class // "")])
          | map({ profile: .[0].profile, class: .[0].class, count: length })
          | sort_by([ (-.count), .profile ])
        ),
        profile_coverage: {
          with_profile: ([ $t[] | select(.profile != null) ] | length),
          total: ($t | length)
        }
      },
      tokens: {
        status: "not_implemented",
        confidence: "none",
        note: "Token join lands in slices M2 (Claude) and M3 (Codex); not part of this slice."
      },
      spend: {
        status: "not_implemented",
        confidence: "none",
        note: "Estimated spend lands in slice M4 (captain-owned pricing table); not part of this slice."
      },
      counterfactual: {
        status: "not_implemented",
        confidence: "none",
        note: "Counterfactual savings land in slice M5; not part of this slice."
      }
    }
  }' > "$LATEST_JSON"

# --- render human report (latest.md) -----------------------------------------
jq -r '
  "# Model economy - usage report (slice \(.slice))",
  "",
  "Generated: \(.generated_at)",
  "Window: \(.window.since) .. \(.window.until)",
  "Home: \(.home)",
  "Sources: \(.sources | join(", "))",
  "",
  "## Panel A - Model mix (confidence: \(.panels.model_mix.confidence))",
  "",
  "Total tasks: \(.totals.tasks) (live: \(.totals.live), closed: \(.totals.closed), undated: \(.totals.undated))",
  "",
  "### By harness / model / effort",
  "",
  "| tasks | harness | model | effort |",
  "| ---: | --- | --- | --- |",
  ( .panels.model_mix.by_harness_model_effort[]
    | "| \(.count) | \(.harness) | \(.model) | \(.effort) |" ),
  "",
  "### By kind",
  "",
  "| tasks | kind |",
  "| ---: | --- |",
  ( .panels.model_mix.by_kind[] | "| \(.count) | \(.kind) |" ),
  "",
  "### By repo",
  "",
  "| tasks | repo |",
  "| ---: | --- |",
  ( .panels.model_mix.by_repo[] | "| \(.count) | \(.repo) |" ),
  "",
  "### Routing profile coverage",
  "",
  "Profile recorded on \(.panels.model_mix.profile_coverage.with_profile)/\(.panels.model_mix.profile_coverage.total) tasks (live meta only).",
  "",
  ( if (.panels.model_mix.by_profile | length) > 0
    then ( "| tasks | profile | class |",
           "| ---: | --- | --- |",
           (.panels.model_mix.by_profile[] | "| \(.count) | \(.profile) | \(.class // "-") |"),
           "" )
    else empty end ),
  "## Panel B - Tokens (\(.panels.tokens.status), confidence: \(.panels.tokens.confidence))",
  "",
  .panels.tokens.note,
  "",
  "## Panel C - Estimated spend (\(.panels.spend.status), confidence: \(.panels.spend.confidence))",
  "",
  .panels.spend.note,
  "",
  "## Panel D - Counterfactual savings (\(.panels.counterfactual.status), confidence: \(.panels.counterfactual.confidence))",
  "",
  .panels.counterfactual.note
' "$LATEST_JSON" > "$LATEST_MD"

# --- dated archive copy + run index ------------------------------------------
STAMP="$(date -u -d "$NOW_ISO" +%Y%m%dT%H%M%SZ)"
cp "$LATEST_JSON" "$OUT/history/usage-$STAMP.json"
cp "$LATEST_MD" "$OUT/history/usage-$STAMP.md"

# Fingerprint the mix content only (window + totals + model_mix), never the wall
# clock, so identical inputs over the same window fingerprint identically.
FINGERPRINT="$(jq -S '{window, totals, model_mix: .panels.model_mix}' "$LATEST_JSON" \
  | sha256sum | cut -d' ' -f1)"
jq -n \
  --arg ts "$NOW_ISO" --arg since "$SINCE_ISO" --arg until "$UNTIL_ISO" \
  --arg path "history/usage-$STAMP.json" --arg fingerprint "$FINGERPRINT" \
  '{ts: $ts, since: $since, until: $until, path: $path, fingerprint: $fingerprint}' \
  >> "$OUT/index.jsonl"

# --- caller-facing summary ---------------------------------------------------
if [ "$EMIT_JSON" -eq 1 ]; then
  cat "$LATEST_JSON"
else
  total="$(jq -r '.totals.tasks' "$LATEST_JSON")"
  mix="$(jq -r '.panels.model_mix.by_harness_model_effort
    | map("\(.harness)/\(.model)/\(.effort)=\(.count)") | join(" ")' "$LATEST_JSON")"
  printf 'usage report: %s tasks in window %s..%s\n' "$total" "$SINCE_ISO" "$UNTIL_ISO"
  [ -n "$mix" ] && printf 'mix: %s\n' "$mix"
  printf 'report: %s\n' "$LATEST_MD"
fi

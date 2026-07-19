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
#
# pipefail is ON so a pipeline fails if ANY stage fails, not just the last. Under
# a bare `set -eu` a broken producer is masked by a succeeding consumer: e.g.
# `sha256sum | cut` returns cut's status, so a failed hash yields an empty result
# and exit 0. The only pipelines that may legitimately fail a stage are the
# ledger row parses, which wrap the whole pipeline in `|| true` to skip a
# malformed row; pipefail does not change that (the `|| true` still absorbs it).
set -euo pipefail

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
# Every run-private temp this process creates is tracked here and removed on any
# exit. rm on the array (not a glob) so a sibling concurrent run's temps in the
# same output dir are never touched.
CLEANUP_FILES=("$REC_FILE")
trap 'rm -f "${CLEANUP_FILES[@]}"' EXIT

# window_decision <start-epoch-or-empty> <end-epoch-or-empty> -> yes|no|undated
# A task occupies the interval [start,end]; it belongs in the report when that
# interval OVERLAPS [SINCE,UNTIL] - i.e. start <= UNTIL and end >= SINCE - not
# when a single collapsed timestamp lands inside the bounds. Reducing a task to
# one point wrongly drops a task that spawned before --since and ended after
# --until (it spans, and overlaps, the whole window). Either bound may be empty
# (absent/unparseable): a single present bound collapses to a point; both absent
# means the task cannot be windowed at all (undated) and is always kept.
window_decision() {
  local s="$1" e="$2" lo hi t
  if [ -z "$s" ] && [ -z "$e" ]; then printf 'undated'; return; fi
  lo="${s:-$e}"; hi="${e:-$s}"
  if [ "$lo" -gt "$hi" ]; then t="$lo"; lo="$hi"; hi="$t"; fi
  if [ "$lo" -le "$UNTIL_EPOCH" ] && [ "$hi" -ge "$SINCE_EPOCH" ]; then printf 'yes'; else printf 'no'; fi
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
  # A live task is still running, so its interval is [spawned_at, now]: it
  # overlaps any window up to the present, including one that opened after it
  # spawned. Undated (no spawned_at) stays always-included.
  sp_epoch="$(to_epoch "$spawned_at")"
  end_epoch=""
  if [ -n "$sp_epoch" ]; then
    end_epoch="$NOW_EPOCH"; [ "$end_epoch" -lt "$sp_epoch" ] && end_epoch="$sp_epoch"
  fi
  case "$(window_decision "$sp_epoch" "$end_epoch")" in
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
    # (a null provider would then shift later fields off the end). 0x1f is
    # non-whitespace, so empty fields are preserved positionally.
    row="$(printf '%s' "$line" | jq -rj '
      [ (.harness // ""), (.model // ""), (.effort // ""), (.kind // ""),
        (.project // ""), (.provider // ""),
        (.spawned_at // ""), (.ended_at // "") ] | join("\u001f")' 2>/dev/null || true)"
    [ -n "$row" ] || continue
    IFS=$'\x1f' read -r harness model effort kind project provider sp_iso en_iso <<EOF
$row
EOF
    repo=""; [ -n "$project" ] && repo="$(basename "$project")"
    # A closed task occupies [spawned_at, ended_at]; keep it when that interval
    # overlaps the window, so a task that spanned the whole window is not dropped.
    sp_epoch="$(to_epoch "$sp_iso")"
    en_epoch="$(to_epoch "$en_iso")"
    case "$(window_decision "$sp_epoch" "$en_epoch")" in
      no) continue ;;
      undated) dated=false ;;
      *) dated=true ;;
    esac
    emit_record "$task" task-run false "$harness" "$model" "$effort" "$kind" "$repo" \
      "" "" "$provider" "$dated"
  done < "$LEDGER"
fi

# --- build machine report into a RUN-PRIVATE temp ----------------------------
# Everything below writes to this run's own temp files, never the shared
# latest.{json,md}. Concurrent same-second runs would otherwise interleave: one
# process's read/copy of the shared latest could capture another's content, so an
# archive would hold the wrong report and its recorded fingerprint would not
# match. Writing private, then renaming into the uniquely-claimed archive, keeps
# every run's snapshot its own. The temps live UNDER $OUT (mktemp there) so the
# later rename into $OUT/history and onto latest is same-filesystem and atomic;
# a temp in $TMPDIR could be a cross-device move (copy+unlink, not atomic).
mkdir -p "$OUT/history" || { echo "fm-usage-report: cannot create output dir $OUT/history" >&2; exit 2; }
TMP_JSON="$(mktemp "$OUT/.usage-report.XXXXXX")" || { echo "fm-usage-report: cannot create a temp file in $OUT" >&2; exit 2; }
CLEANUP_FILES+=("$TMP_JSON")
TMP_MD="$(mktemp "$OUT/.usage-report.XXXXXX")" || { echo "fm-usage-report: cannot create a temp file in $OUT" >&2; exit 2; }
CLEANUP_FILES+=("$TMP_MD")

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
  }' > "$TMP_JSON" || { echo "fm-usage-report: failed to build machine report" >&2; exit 2; }

# --- render human report into the run-private temp ---------------------------
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
' "$TMP_JSON" > "$TMP_MD" || { echo "fm-usage-report: failed to render human report" >&2; exit 2; }

# --- fingerprint this run's own private JSON ---------------------------------
# Computed from THIS run's finalized content (which is byte-identical to what
# gets renamed into the archive), so the fingerprint always matches its archive.
# Canonicalize in a checked step first, so a jq failure is reported on its own.
# The canonical form is bounded (mix only).
CANON="$(jq -S '{window, totals, model_mix: .panels.model_mix}' "$TMP_JSON")" \
  || { echo "fm-usage-report: failed to canonicalize report for fingerprint" >&2; exit 2; }
# printf '%s\n' restores the single trailing newline that $() stripped from jq's
# output, so this digest is byte-identical to a plain
#   jq -S '{window,totals,model_mix:.panels.model_mix}' <archive> | sha256sum
# recompute from the archive - the natural way to re-verify it.
# pipefail makes a sha256sum failure fail the whole pipeline (cut no longer masks
# it into an empty result and exit 0); the explicit guard turns that into a
# named diagnostic, and the non-empty assertion is a final backstop so an empty
# fingerprint can never reach the archive index or a success summary.
FINGERPRINT="$(printf '%s\n' "$CANON" | sha256sum | cut -d' ' -f1)" \
  || { echo "fm-usage-report: failed to compute report fingerprint" >&2; exit 2; }
[ -n "$FINGERPRINT" ] || { echo "fm-usage-report: computed an empty report fingerprint" >&2; exit 2; }

# --- claim a unique immutable archive slot, then rename the private pair in ---
# The archive is an IMMUTABLE per-run snapshot. The stamp has only second
# precision, so two runs in the same second (a pinned test clock, or genuinely
# concurrent invocations) would collide. Claim a unique name with an atomic
# no-clobber create (O_EXCL): the first run at a second gets usage-<STAMP>, the
# next usage-<STAMP>-1, and so on. Because the name is claimed exclusively, the
# rename of this run's private files into it cannot capture another run's content.
STAMP="$(date -u -d "$NOW_ISO" +%Y%m%dT%H%M%SZ)"
BASE=""
i=0
while [ "$i" -lt 100000 ]; do
  if [ "$i" -eq 0 ]; then cand="usage-$STAMP"; else cand="usage-$STAMP-$i"; fi
  if ( set -o noclobber; : > "$OUT/history/$cand.json" ) 2>/dev/null; then BASE="$cand"; break; fi
  i=$((i + 1))
done
[ -n "$BASE" ] || { echo "fm-usage-report: could not allocate a unique archive name in $OUT/history" >&2; exit 2; }
# mv (rename) is atomic and replaces the empty reserved .json; the .md shares the
# exclusively-claimed BASE, so it needs no separate reservation. A failed archive
# rename is fatal - it would leave the claimed slot empty or half-written.
mv -f "$TMP_JSON" "$OUT/history/$BASE.json" || { echo "fm-usage-report: failed to write archive $OUT/history/$BASE.json" >&2; exit 2; }
mv -f "$TMP_MD" "$OUT/history/$BASE.md" || { echo "fm-usage-report: failed to write archive $OUT/history/$BASE.md" >&2; exit 2; }

# --- publish latest.{json,md} as one serialized, fully-checked pair -----------
# Each file rename is atomic on its own, but the PAIR is not: two concurrent
# writers renaming latest.json then latest.md in separate steps can interleave
# (A-json, B-json, B-md, A-md), leaving latest.json from one run beside
# latest.md from another - a machine report and human report that disagree.
# Hold ONE output-scoped exclusive lock across BOTH final renames so the pair is
# published as a unit; whichever writer wins the lock last publishes both of its
# own files. A reader that needs a coherent pair should take the same lock. The
# archive copies happen BEFORE the lock, so only the two renames are serialized.
#
# EVERY step here is checked and fails loud and nonzero BEFORE the index append
# or success summary. The round-4 form ran the renames inside `if ! ( ... ) 9>lock`,
# where set -e is suppressed (condition context) so a failed FIRST rename was
# masked when the second succeeded, and a failed fd-open on the compound redirect
# was silently skipped - both returned 0 with a half-published or unpublished
# pair. The separate checked steps below (fd open, lock acquire, each rename)
# close both false-success paths. Closing fd 9 releases the flock.
LOCK="$OUT/.latest.lock"
PUB_JSON="$(mktemp "$OUT/.usage-latest.XXXXXX")" || { echo "fm-usage-report: cannot create a temp file in $OUT" >&2; exit 2; }
CLEANUP_FILES+=("$PUB_JSON")
PUB_MD="$(mktemp "$OUT/.usage-latest.XXXXXX")" || { echo "fm-usage-report: cannot create a temp file in $OUT" >&2; exit 2; }
CLEANUP_FILES+=("$PUB_MD")
cp "$OUT/history/$BASE.json" "$PUB_JSON" || { echo "fm-usage-report: failed to stage latest.json in $OUT" >&2; exit 2; }
cp "$OUT/history/$BASE.md" "$PUB_MD" || { echo "fm-usage-report: failed to stage latest.md in $OUT" >&2; exit 2; }
if ! exec 9>"$LOCK"; then
  echo "fm-usage-report: cannot open publication lock $LOCK" >&2
  exit 2
fi
if ! flock -x 9; then
  echo "fm-usage-report: cannot acquire publication lock $LOCK" >&2
  exec 9>&-
  exit 2
fi
if ! mv -f "$PUB_JSON" "$OUT/latest.json"; then
  echo "fm-usage-report: failed to publish latest.json to $OUT" >&2
  exec 9>&-
  exit 2
fi
if ! mv -f "$PUB_MD" "$OUT/latest.md"; then
  echo "fm-usage-report: failed to publish latest.md to $OUT (latest.json already updated; pair is inconsistent)" >&2
  exec 9>&-
  exit 2
fi
exec 9>&-

# --- append one robust JSONL index line --------------------------------------
# Only reached after the pair published successfully. -cn: one COMPACT object per
# physical line, so index.jsonl is valid JSON Lines (section 3.2). Build the whole
# line first, then append it with a single printf: one bounded (<PIPE_BUF) write
# to an O_APPEND fd is atomic, so parallel runs never interleave partial lines.
# `path` names this run's own archive.
INDEX_LINE="$(jq -cn \
  --arg ts "$NOW_ISO" --arg since "$SINCE_ISO" --arg until "$UNTIL_ISO" \
  --arg path "history/$BASE.json" --arg fingerprint "$FINGERPRINT" \
  '{ts: $ts, since: $since, until: $until, path: $path, fingerprint: $fingerprint}')" \
  || { echo "fm-usage-report: failed to build index line" >&2; exit 2; }
printf '%s\n' "$INDEX_LINE" >> "$OUT/index.jsonl" || { echo "fm-usage-report: failed to append index line to $OUT/index.jsonl" >&2; exit 2; }

# --- caller-facing summary (from THIS run's archive, not the shared latest) ---
ARCHIVE_JSON="$OUT/history/$BASE.json"
if [ "$EMIT_JSON" -eq 1 ]; then
  cat "$ARCHIVE_JSON"
else
  total="$(jq -r '.totals.tasks' "$ARCHIVE_JSON")"
  mix="$(jq -r '.panels.model_mix.by_harness_model_effort
    | map("\(.harness)/\(.model)/\(.effort)=\(.count)") | join(" ")' "$ARCHIVE_JSON")"
  printf 'usage report: %s tasks in window %s..%s\n' "$total" "$SINCE_ISO" "$UNTIL_ISO"
  [ -n "$mix" ] && printf 'mix: %s\n' "$mix"
  printf 'report: %s\n' "$OUT/history/$BASE.md"
fi

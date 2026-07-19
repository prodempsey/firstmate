#!/usr/bin/env bash
# fm-usage-report.sh - captain-readable model-economy usage report (Slice M2).
#
# Reads task ROUTING PROVENANCE from a target FM_HOME and writes a model-mix
# report: how many tasks ran on each harness/model/effort, split by kind and by
# repo (Slice M1). Slice M2 adds the Claude token joiner: for tasks with
# harness=claude, it joins per-task token usage from that harness's own local
# session transcripts. It does NOT parse Codex/Grok/Gemini session files (those
# tasks report tokens_status=unsupported) and does NOT compute spend or
# counterfactual savings; those panels remain labeled, not-yet-implemented
# scaffolding so the later slices (M3 Codex tokens, M4 pricing/spend, M5
# counterfactual) slot in without reshaping the report. Design authority:
#   /home/prode/fleet/firstmate-runtime/data/model-economy-measure-s1/report.md
#   sections 2.2.1 (Claude session facts), 3.2-3.3 (report shape),
#   3.4 (join algorithm), 3.5 (confidence).
#
# INPUTS (read-only; this script never mutates its inputs):
#   $STATE/*.meta            live tasks. key=val lines; task id is the filename.
#                            fields used: harness, model, effort, kind, project,
#                            worktree, spawned_at, and (when present) profile,
#                            class, provider. Written by bin/fm-spawn.sh /
#                            bin/fm-spawn-profile.sh.
#   $STATE/task-runs.jsonl   closed tasks. schema task_run/1, one JSON row each,
#                            appended at teardown by bin/fm-teardown.sh. Has no
#                            profile/class (report section 2.1.B).
# A task present in BOTH is counted once, preferring the live meta (report 3.3).
#
#   $CLAUDE_PROJECTS/<encoded-worktree>/*.jsonl   Claude Code session transcripts
#                            for harness=claude tasks (report 2.2.1). Encoding:
#                            every '/' and '.' in the absolute worktree path
#                            becomes '-' (encode_claude_dir()). Only TOP-LEVEL
#                            *.jsonl files are read; a session's own
#                            <uuid>/subagents/ subtree is excluded by design (a
#                            separate transcript for spawned subagents, not this
#                            task's own usage). Only top-level events with
#                            "type":"assistant" and a "message.usage" object
#                            contribute (report's Aggregation rule: "Sum every
#                            assistant message.usage"); a session file is
#                            included only when its own [min,max] event
#                            timestamp range overlaps the task's
#                            [spawned_at, window_end + grace] interval (report
#                            3.4). window_end is ended_at for a closed task
#                            (task-runs.jsonl), "now" for a still-live task, and
#                            falls back to spawned_at when no better bound
#                            exists. A task with no parseable spawned_at cannot
#                            be time-filtered at all: every top-level session
#                            under its worktree dir is summed instead, and the
#                            result is labeled tokens_status=ambiguous_join
#                            (report 3.4, 3.5). A malformed/unparsable session
#                            file is skipped (data tolerance, like a malformed
#                            task-runs.jsonl row); a session file that cannot be
#                            READ at all (permissions, I/O) is an operational
#                            failure and aborts the run via run_or_die.
#                            CLAUDE_PROJECTS defaults to $HOME/.claude/projects;
#                            override with FM_CLAUDE_PROJECTS_OVERRIDE (same
#                            override pattern as FM_STATE_OVERRIDE) so tests
#                            never touch a live ~/.claude. Grace defaults to 2
#                            hours; override with FM_USAGE_CLAUDE_GRACE_HOURS
#                            (non-negative integer).
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
# This report-inclusion window is separate from the Claude token-join window
# described above (a task can be report-included via ended_at alone while still
# being ambiguous_join for tokens because spawned_at itself is missing).
#
# DETERMINISM: given fixed inputs and an explicit window, the mix tables and the
# fingerprint are deterministic (the fingerprint deliberately excludes the wall
# clock, and - unchanged from M1 - deliberately excludes the tokens panel too,
# so the concurrency-critical publish/fingerprint path stays exactly as hardened
# in the M1 QA rounds). Claude token sums are deterministic for fixed session
# file content and a fixed FM_USAGE_NOW. Set FM_USAGE_NOW=<ISO-8601 UTC> to pin
# "now" for reproducible runs.
#
# Usage:
#   fm-usage-report.sh [--target DIR] [--since DATE] [--until DATE]
#                      [--out DIR] [--json] [-h|--help]
# Exit: 0 on a written report; 2 on a usage/argument error; 3 if jq is missing.
#
# pipefail is ON so a pipeline fails if ANY stage fails, not just the last. Under
# a bare `set -eu` a broken producer is masked by a succeeding consumer: e.g.
# `sha256sum | cut` returns cut's status, so a failed hash yields an empty result
# and exit 0. All jq/date/find invocations go through run_or_die so operational
# failures abort, while declared data-parse failures stay tolerant.
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

CLEANUP_FILES=()
cleanup_tmp() { rm -f "${CLEANUP_FILES[@]}"; }
trap cleanup_tmp EXIT

print_tool_error() { [ ! -s "$1" ] || cat "$1" >&2; }

JQ_BIN="$(command -v jq 2>/dev/null)" || { echo "fm-usage-report: jq is required" >&2; exit 3; }
DATE_BIN="$(command -v date 2>/dev/null)" || { echo "fm-usage-report: date is required" >&2; exit 2; }
RUN_OUT="$(mktemp "${TMPDIR:-/tmp}/fm-usage-run-out.XXXXXX")" \
  || { echo "fm-usage-report: cannot create command output temp file" >&2; exit 2; }
RUN_ERR="$(mktemp "${TMPDIR:-/tmp}/fm-usage-run-err.XXXXXX")" \
  || { echo "fm-usage-report: cannot create command diagnostic temp file" >&2; exit 2; }
CLEANUP_FILES+=("$RUN_OUT" "$RUN_ERR")

run_or_die() {  # <diagnostic> <allowed-stderr-regex-or-empty> -- <command> [args...]
  local diagnostic=$1 allowed=${2:-} status
  shift 2
  [ "${1:-}" = "--" ] && shift
  if ! : > "$RUN_OUT"; then
    printf 'fm-usage-report: failed to reset command output capture %s\n' "$RUN_OUT" >&2
    exit 2
  fi
  if ! : > "$RUN_ERR"; then
    printf 'fm-usage-report: failed to reset command diagnostic capture %s\n' "$RUN_ERR" >&2
    exit 2
  fi
  if "$@" > "$RUN_OUT" 2> "$RUN_ERR"; then
    return 0
  else
    status=$?
  fi
  if [ -n "$allowed" ] && grep -Eq "$allowed" "$RUN_ERR"; then
    return 1
  fi
  print_tool_error "$RUN_ERR"
  printf 'fm-usage-report: %s (exit %s)\n' "$diagnostic" "$status" >&2
  exit 2
}

# --- resolve home, state, out ------------------------------------------------
if [ -n "$TARGET" ]; then
  TARGET="$(cd "$TARGET" 2>/dev/null && pwd)" \
    || { echo "fm-usage-report: --target directory not found" >&2; exit 2; }
else
  TARGET="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
fi
STATE="${FM_STATE_OVERRIDE:-$TARGET/state}"
OUT="${OPT_OUT:-$TARGET/data/model-economy/usage}"

# --- Claude token joiner config (slice M2) -----------------------------------
# CLAUDE_PROJECTS scopes the Claude session-transcript input the same way
# FM_STATE_OVERRIDE scopes state/: tests point it at a fixture tree and never
# touch a live ~/.claude/projects.
CLAUDE_PROJECTS="${FM_CLAUDE_PROJECTS_OVERRIDE:-${HOME:-}/.claude/projects}"
# Grace window appended past a task's end bound before matching Claude session
# files (report 3.4: "catch post-done validation turns"); must be a
# non-negative integer count of hours.
CLAUDE_GRACE_HOURS="${FM_USAGE_CLAUDE_GRACE_HOURS:-2}"
case "$CLAUDE_GRACE_HOURS" in
  ''|*[!0-9]*)
    echo "fm-usage-report: FM_USAGE_CLAUDE_GRACE_HOURS must be a non-negative integer, got '$CLAUDE_GRACE_HOURS'" >&2
    exit 2 ;;
esac
CLAUDE_GRACE_SECONDS=$((CLAUDE_GRACE_HOURS * 3600))

# encode_claude_dir <absolute-worktree-path> -> Claude projects dir basename.
# Every '/' and '.' becomes '-' (report 2.2.1's verified encoding rule); pure
# bash pattern substitution, no external process needed.
encode_claude_dir() {
  local p="$1"
  printf '%s' "${p//[\/.]/-}"
}

# --- clock and window --------------------------------------------------------
# Empty input must NOT parse: GNU `date -d ''` silently returns the current time
# (rc 0), which would misdate every task with a missing timestamp as "now". A
# genuinely malformed timestamp still fails date's parse and prints nothing.
to_epoch() {
  local input="${1:-}"
  [ -n "$input" ] || return 0
  if run_or_die "failed to convert timestamp with date: $input" '^date: invalid date ' \
    -- "$DATE_BIN" -u -d "$input" +%s; then
    cat "$RUN_OUT"
  fi
}

if [ -n "${FM_USAGE_NOW:-}" ]; then
  NOW_ISO="$FM_USAGE_NOW"
else
  run_or_die "failed to read current time with date" "" -- "$DATE_BIN" -u +%Y-%m-%dT%H:%M:%SZ
  NOW_ISO="$(cat "$RUN_OUT")"
fi
NOW_EPOCH="$(to_epoch "$NOW_ISO")"
[ -n "$NOW_EPOCH" ] || { echo "fm-usage-report: unparseable FM_USAGE_NOW '$NOW_ISO'" >&2; exit 2; }

# Date-only bounds snap to the inclusive edge of the named UTC day.
norm_since() { case "$1" in ????-??-??) printf '%sT00:00:00Z' "$1" ;; *) printf '%s' "$1" ;; esac; }
norm_until() { case "$1" in ????-??-??) printf '%sT23:59:59Z' "$1" ;; *) printf '%s' "$1" ;; esac; }

if [ -n "$OPT_SINCE" ]; then
  SINCE_ISO="$(norm_since "$OPT_SINCE")"
else
  run_or_die "failed to compute default --since with date" "" \
    -- "$DATE_BIN" -u -d "$NOW_ISO - 7 days" +%Y-%m-%dT%H:%M:%SZ
  SINCE_ISO="$(norm_since "$(cat "$RUN_OUT")")"
fi
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
# Every run-private temp this process creates is tracked and removed on any
# exit. rm on the array (not a glob) so a sibling concurrent run's temps in the
# same output dir are never touched.
CLEANUP_FILES+=("$REC_FILE")

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

emit_record() {  # <task> <source> <live-bool> <harness> <model> <effort> <kind> <repo> <profile> <class> <provider> <dated-bool> <worktree> <spawned_at-iso> <window_end-iso>
  # shellcheck disable=SC2016 # jq variables are expanded by jq, not the shell.
  run_or_die "failed to build task record with jq" "" -- "$JQ_BIN" -n \
    --arg task "$1" --arg source "$2" --argjson live "$3" \
    --arg harness "${4:-}" --arg model "${5:-}" --arg effort "${6:-}" \
    --arg kind "${7:-}" --arg repo "${8:-}" \
    --arg profile "${9:-}" --arg class "${10:-}" --arg provider "${11:-}" \
    --argjson dated "${12}" \
    --arg worktree "${13:-}" --arg spawned_at "${14:-}" --arg window_end "${15:-}" '
    def blank(x): if x == "" then null else x end;
    def dflt(x): if x == "" then "default" else x end;
    {
      task: $task, source: $source, live: $live,
      harness: dflt($harness), model: dflt($model), effort: dflt($effort),
      kind: (if $kind == "" then "unknown" else $kind end),
      repo: (if $repo == "" then "unknown" else $repo end),
      profile: blank($profile), class: blank($class), provider: blank($provider),
      dated: $dated,
      worktree: blank($worktree), spawned_at: blank($spawned_at), window_end: blank($window_end)
    }'
  cat "$RUN_OUT" >> "$REC_FILE" || { echo "fm-usage-report: failed to append task record" >&2; exit 2; }
}

# Live metas first, and remember their task ids so a still-live task is not
# double-counted from the historical ledger.
declare -A SEEN=()
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  task="$(basename "$meta" .meta)"
  harness=""; model=""; effort=""; kind=""; project=""; spawned_at=""
  profile=""; class=""; provider=""; worktree=""
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
      worktree) worktree="$v" ;;
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
  # window_end for the Claude token join (report 3.4): a live task's session
  # activity can continue up to "now", regardless of the report's own --until.
  window_end=""; [ -n "$sp_epoch" ] && window_end="$NOW_ISO"
  emit_record "$task" meta true "$harness" "$model" "$effort" "$kind" "$repo" \
    "$profile" "$class" "$provider" "$dated" "$worktree" "$spawned_at" "$window_end"
done

# Historical ledger for closed tasks not currently live.
LEDGER="$STATE/task-runs.jsonl"
if [ -f "$LEDGER" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if ! run_or_die "failed to parse task-runs.jsonl task field with jq" '^jq: parse error:' \
      -- "$JQ_BIN" -r 'if type == "object" then (.task // empty) else empty end' <<< "$line"; then
      continue
    fi
    task="$(cat "$RUN_OUT")"
    [ -n "$task" ] || continue
    [ -z "${SEEN[$task]:-}" ] || continue
    SEEN["$task"]=1
    # Join with the unit separator (0x1f), NOT a tab: with IFS set to a
    # whitespace character, `read` collapses runs of it and drops empty fields
    # (a null provider would then shift later fields off the end). 0x1f is
    # non-whitespace, so empty fields are preserved positionally.
    if ! run_or_die "failed to parse task-runs.jsonl row fields with jq" '^jq: parse error:' \
      -- "$JQ_BIN" -rj '
      if type == "object" then
        [ (.harness // ""), (.model // ""), (.effort // ""), (.kind // ""),
          (.project // ""), (.provider // ""),
          (.spawned_at // ""), (.ended_at // ""), (.worktree // "") ] | join("\u001f")
      else empty end' <<< "$line"; then
      continue
    fi
    row="$(cat "$RUN_OUT")"
    [ -n "$row" ] || continue
    IFS=$'\x1f' read -r harness model effort kind project provider sp_iso en_iso worktree <<EOF
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
    # window_end for the Claude token join (report 3.4): ended_at when present,
    # else fall back to spawned_at so a present spawned_at always yields a usable
    # (if degenerate) join window instead of an empty one.
    window_end="$en_iso"; [ -n "$window_end" ] || window_end="$sp_iso"
    emit_record "$task" task-run false "$harness" "$model" "$effort" "$kind" "$repo" \
      "" "" "$provider" "$dated" "$worktree" "$sp_iso" "$window_end"
  done < "$LEDGER"
fi

# --- Claude token join (slice M2) --------------------------------------------
# Per report 3.4's normative "claude:" case: for every harness=claude record,
# encode its worktree into a Claude projects dir, sum every top-level session
# file's assistant usage, time-filtering by [spawned_at, window_end+grace] when
# spawned_at is parseable, else summing every top-level session unfiltered and
# marking the result ambiguous_join. Non-claude records are not attempted here
# (M3+); they are tallied straight from $REC_FILE in the final jq step below.
#
# One TOKENS_FILE NDJSON record per claude task, built the same run-private-
# accumulator way as REC_FILE: never through argv, so a large claude fleet
# cannot hit the shell argument limit either.
TOKENS_FILE="$(mktemp "${TMPDIR:-/tmp}/fm-usage-tokens.XXXXXX")"
CLEANUP_FILES+=("$TOKENS_FILE")

# Claude task rows to join, extracted from the already-deduplicated REC_FILE.
# jq applied to a file of concatenated JSON values (REC_FILE's NDJSON) streams
# each value as a separate input; -r (not -j) so jq's own per-result newline
# separates rows, since this single invocation emits MANY rows, unlike the
# single-line ledger-row extraction above. Fields are unit-separator joined,
# same rationale as the ledger row extraction: preserves empty fields
# positionally under IFS-based `read`.
run_or_die "failed to extract claude task rows with jq" "" -- "$JQ_BIN" -r '
  select(.harness == "claude") |
  [ .task, (.worktree // ""), (.model // ""), (.spawned_at // ""), (.window_end // "") ]
  | join("\u001f")
' "$REC_FILE"
CLAUDE_TASKS_FILE="$(mktemp "${TMPDIR:-/tmp}/fm-usage-claude-tasks.XXXXXX")"
CLEANUP_FILES+=("$CLAUDE_TASKS_FILE")
cat "$RUN_OUT" > "$CLAUDE_TASKS_FILE" \
  || { echo "fm-usage-report: failed to write claude task extraction temp" >&2; exit 2; }

# emit_token_record <task> <model> <join_method> <status> <confidence> <input> <output> <cache_read> <cache_write> <total> <sessions_matched>
emit_token_record() {
  # shellcheck disable=SC2016 # jq variables are expanded by jq, not the shell.
  run_or_die "failed to build claude token record with jq" "" -- "$JQ_BIN" -n \
    --arg task "$1" --arg model "$2" --arg join_method "$3" \
    --arg status "$4" --arg confidence "$5" \
    --argjson input "$6" --argjson output "$7" \
    --argjson cache_read "$8" --argjson cache_write "$9" \
    --argjson total "${10}" --argjson sessions "${11}" '
    { task: $task, model: $model, join_method: $join_method,
      tokens_status: $status, confidence: $confidence,
      input_tokens: $input, output_tokens: $output,
      cache_read_tokens: $cache_read, cache_write_tokens: $cache_write,
      reasoning_tokens: null, total_tokens: $total, sessions_matched: $sessions }'
  cat "$RUN_OUT" >> "$TOKENS_FILE" \
    || { echo "fm-usage-report: failed to append claude token record" >&2; exit 2; }
}

SESSION_LIST_FILE="$(mktemp "${TMPDIR:-/tmp}/fm-usage-sessions.XXXXXX")"
CLEANUP_FILES+=("$SESSION_LIST_FILE")

while IFS=$'\x1f' read -r ctask cworktree cmodel cspawned cwindow_end; do
  [ -n "$ctask" ] || continue
  in_tok=0; out_tok=0; cr_tok=0; cw_tok=0; sessions_matched=0
  join_method="claude_project_dir"
  if [ -z "$cworktree" ]; then
    status="absent"; confidence="none"; join_method="none"
  else
    cdir="$CLAUDE_PROJECTS/$(encode_claude_dir "$cworktree")"
    if [ ! -d "$cdir" ]; then
      status="absent"; confidence="none"
    else
      # Top-level session files only: a session's own <uuid>/subagents/ subtree
      # is a separate transcript for spawned subagents, excluded by design.
      run_or_die "failed to list claude session files in $cdir with find" "" \
        -- find "$cdir" -maxdepth 1 -type f -name '*.jsonl' -print0
      cp "$RUN_OUT" "$SESSION_LIST_FILE" \
        || { echo "fm-usage-report: failed to stage claude session file list" >&2; exit 2; }

      sp_epoch=""; [ -n "$cspawned" ] && sp_epoch="$(to_epoch "$cspawned")"
      we_epoch=""; [ -n "$cwindow_end" ] && we_epoch="$(to_epoch "$cwindow_end")"
      task_hi_epoch=""
      [ -n "$we_epoch" ] && task_hi_epoch=$((we_epoch + CLAUDE_GRACE_SECONDS))
      # A time filter is only possible when BOTH the task's own spawned_at AND
      # its window_end parsed to a real epoch; report 3.4: "If spawned_at
      # missing, mark ambiguous_join" - sum every session unfiltered instead.
      dated_join=0
      if [ -n "$sp_epoch" ] && [ -n "$task_hi_epoch" ]; then dated_join=1; fi

      while IFS= read -r -d '' sfile; do
        # A malformed session file is data tolerance (skip, keep scanning); jq
        # failing to even open/read the file is operational and aborts loudly.
        if ! run_or_die "failed to parse claude session file with jq: $sfile" '^jq: parse error:' \
          -- "$JQ_BIN" -rs '{
            ts_min: ([ .[] | .timestamp? // empty ] | map(select(type=="string")) | if length>0 then min else null end),
            ts_max: ([ .[] | .timestamp? // empty ] | map(select(type=="string")) | if length>0 then max else null end),
            input_tokens: ([ .[] | select(.type=="assistant") | (.message.usage.input_tokens? // 0) ] | add // 0),
            output_tokens: ([ .[] | select(.type=="assistant") | (.message.usage.output_tokens? // 0) ] | add // 0),
            cache_read_tokens: ([ .[] | select(.type=="assistant") | (.message.usage.cache_read_input_tokens? // 0) ] | add // 0),
            cache_write_tokens: ([ .[] | select(.type=="assistant") | (.message.usage.cache_creation_input_tokens? // 0) ] | add // 0)
          } | [.ts_min, .ts_max, .input_tokens, .output_tokens, .cache_read_tokens, .cache_write_tokens] | @tsv' \
          "$sfile"; then
          continue
        fi
        sess_row="$(cat "$RUN_OUT")"
        [ -n "$sess_row" ] || continue
        IFS=$'\t' read -r ts_min ts_max s_in s_out s_cr s_cw <<EOF
$sess_row
EOF
        include=0
        if [ "$dated_join" -eq 1 ]; then
          slo=""; shi=""
          [ -n "$ts_min" ] && slo="$(to_epoch "$ts_min")"
          [ -n "$ts_max" ] && shi="$(to_epoch "$ts_max")"
          if [ -n "$slo" ] && [ -n "$shi" ]; then
            lo="$slo"; hi="$shi"
            if [ "$lo" -gt "$hi" ]; then local_t="$lo"; lo="$hi"; hi="$local_t"; fi
            if [ "$lo" -le "$task_hi_epoch" ] && [ "$hi" -ge "$sp_epoch" ]; then include=1; fi
          fi
        else
          # No time filter possible: every readable top-level session counts.
          include=1
        fi
        if [ "$include" -eq 1 ]; then
          sessions_matched=$((sessions_matched + 1))
          in_tok=$((in_tok + s_in)); out_tok=$((out_tok + s_out))
          cr_tok=$((cr_tok + s_cr)); cw_tok=$((cw_tok + s_cw))
        fi
      done < "$SESSION_LIST_FILE"

      if [ "$dated_join" -eq 1 ]; then
        if [ "$sessions_matched" -gt 0 ]; then status="ok"; confidence="high"
        else status="absent"; confidence="none"; fi
      else
        if [ "$sessions_matched" -gt 0 ]; then status="ambiguous_join"; confidence="low"
        else status="absent"; confidence="none"; fi
      fi
    fi
  fi
  total_tok=$((in_tok + out_tok + cr_tok + cw_tok))
  emit_token_record "$ctask" "$cmodel" "$join_method" "$status" "$confidence" \
    "$in_tok" "$out_tok" "$cr_tok" "$cw_tok" "$total_tok" "$sessions_matched"
done < "$CLAUDE_TASKS_FILE"

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

# shellcheck disable=SC2016 # jq variables are expanded by jq, not the shell.
run_or_die "failed to build machine report with jq" "" -- "$JQ_BIN" -n \
  --slurpfile recs "$REC_FILE" \
  --slurpfile tokrecs "$TOKENS_FILE" \
  --arg generated_at "$NOW_ISO" \
  --arg since "$SINCE_ISO" \
  --arg until "$UNTIL_ISO" \
  --arg home "$TARGET" \
  --arg claude_projects "$CLAUDE_PROJECTS" \
  --argjson grace_hours "$CLAUDE_GRACE_HOURS" '
  ($recs) as $t | ($tokrecs) as $tok |
  {
    schema: "fm-usage-report/1",
    slice: "M2",
    generated_at: $generated_at,
    window: { since: $since, until: $until },
    home: $home,
    sources: ["state/*.meta", "state/task-runs.jsonl", "claude_projects/**/*.jsonl (claude tasks only)"],
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
        status: "partial",
        note: "Claude token join implemented (slice M2, join_method=claude_project_dir, grace=\($grace_hours)h). Codex/Grok/Gemini token joins land in later slices (M3+); those tasks report tokens_status=\"unsupported\".",
        claude: {
          source_dir: $claude_projects,
          tasks_total: ($tok | length),
          tasks_joined: ([ $tok[] | select(.tokens_status == "ok" or .tokens_status == "ambiguous_join") ] | length),
          by_task: ( $tok | sort_by(.task) ),
          by_model: (
            $tok | group_by(.model)
            | map({
                model: .[0].model,
                tasks: length,
                tasks_joined: ([ .[] | select(.tokens_status == "ok" or .tokens_status == "ambiguous_join") ] | length),
                input_tokens: ([ .[].input_tokens ] | add // 0),
                output_tokens: ([ .[].output_tokens ] | add // 0),
                cache_read_tokens: ([ .[].cache_read_tokens ] | add // 0),
                cache_write_tokens: ([ .[].cache_write_tokens ] | add // 0),
                total_tokens: ([ .[].total_tokens ] | add // 0)
              })
            | sort_by([ (-.tasks), .model ])
          )
        },
        unsupported: {
          tasks_total: ([ $t[] | select(.harness != "claude") ] | length),
          by_harness: (
            [ $t[] | select(.harness != "claude") ]
            | group_by(.harness)
            | map({ harness: .[0].harness, count: length })
            | sort_by([ (-.count), .harness ])
          )
        }
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
  }'
cat "$RUN_OUT" > "$TMP_JSON" || { echo "fm-usage-report: failed to write machine report temp" >&2; exit 2; }

# --- render human report into the run-private temp ---------------------------
run_or_die "failed to render human report with jq" "" -- "$JQ_BIN" -r '
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
  "## Panel B - Tokens (\(.panels.tokens.status))",
  "",
  .panels.tokens.note,
  "",
  "### Claude (join_method: claude_project_dir)",
  "",
  "Joined \(.panels.tokens.claude.tasks_joined)/\(.panels.tokens.claude.tasks_total) claude tasks.",
  "",
  ( if (.panels.tokens.claude.by_task | length) > 0
    then ( "| task | model | status | confidence | input | output | cache_read | cache_write | total |",
           "| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: |",
           (.panels.tokens.claude.by_task[]
             | "| \(.task) | \(.model) | \(.tokens_status) | \(.confidence) | \(.input_tokens) | \(.output_tokens) | \(.cache_read_tokens) | \(.cache_write_tokens) | \(.total_tokens) |"),
           "" )
    else empty end ),
  ( if (.panels.tokens.claude.by_model | length) > 0
    then ( "#### By model",
           "",
           "| model | tasks | joined | input | output | cache_read | cache_write | total |",
           "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
           (.panels.tokens.claude.by_model[]
             | "| \(.model) | \(.tasks) | \(.tasks_joined) | \(.input_tokens) | \(.output_tokens) | \(.cache_read_tokens) | \(.cache_write_tokens) | \(.total_tokens) |"),
           "" )
    else empty end ),
  "### Not yet joinable",
  "",
  "\(.panels.tokens.unsupported.tasks_total) tasks on other harnesses are not token-joined in this slice.",
  "",
  ( if (.panels.tokens.unsupported.by_harness | length) > 0
    then ( "| tasks | harness |",
           "| ---: | --- |",
           (.panels.tokens.unsupported.by_harness[] | "| \(.count) | \(.harness) |"),
           "" )
    else empty end ),
  "## Panel C - Estimated spend (\(.panels.spend.status), confidence: \(.panels.spend.confidence))",
  "",
  .panels.spend.note,
  "",
  "## Panel D - Counterfactual savings (\(.panels.counterfactual.status), confidence: \(.panels.counterfactual.confidence))",
  "",
  .panels.counterfactual.note
' "$TMP_JSON"
cat "$RUN_OUT" > "$TMP_MD" || { echo "fm-usage-report: failed to write human report temp" >&2; exit 2; }

# --- fingerprint this run's own private JSON ---------------------------------
# Computed from THIS run's finalized content (which is byte-identical to what
# gets renamed into the archive), so the fingerprint always matches its archive.
# Canonicalize in a checked step first, so a jq failure is reported on its own.
# The canonical form is bounded (mix only).
run_or_die "failed to canonicalize report for fingerprint with jq" "" \
  -- "$JQ_BIN" -S '{window, totals, model_mix: .panels.model_mix}' "$TMP_JSON"
CANON="$(cat "$RUN_OUT")"
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
run_or_die "failed to compute archive timestamp with date" "" -- "$DATE_BIN" -u -d "$NOW_ISO" +%Y%m%dT%H%M%SZ
STAMP="$(cat "$RUN_OUT")"
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
# shellcheck disable=SC2016 # jq variables are expanded by jq, not the shell.
run_or_die "failed to build index line with jq" "" -- "$JQ_BIN" -cn \
  --arg ts "$NOW_ISO" --arg since "$SINCE_ISO" --arg until "$UNTIL_ISO" \
  --arg path "history/$BASE.json" --arg fingerprint "$FINGERPRINT" \
  '{ts: $ts, since: $since, until: $until, path: $path, fingerprint: $fingerprint}'
INDEX_LINE="$(cat "$RUN_OUT")"
printf '%s\n' "$INDEX_LINE" >> "$OUT/index.jsonl" || { echo "fm-usage-report: failed to append index line to $OUT/index.jsonl" >&2; exit 2; }

# --- caller-facing summary (from THIS run's archive, not the shared latest) ---
ARCHIVE_JSON="$OUT/history/$BASE.json"
if [ "$EMIT_JSON" -eq 1 ]; then
  cat "$ARCHIVE_JSON"
else
  run_or_die "failed to read total from archive with jq" "" -- "$JQ_BIN" -r '.totals.tasks' "$ARCHIVE_JSON"
  total="$(cat "$RUN_OUT")"
  run_or_die "failed to read model mix from archive with jq" "" -- "$JQ_BIN" -r \
    '.panels.model_mix.by_harness_model_effort
    | map("\(.harness)/\(.model)/\(.effort)=\(.count)") | join(" ")' "$ARCHIVE_JSON"
  mix="$(cat "$RUN_OUT")"
  printf 'usage report: %s tasks in window %s..%s\n' "$total" "$SINCE_ISO" "$UNTIL_ISO"
  [ -n "$mix" ] && printf 'mix: %s\n' "$mix"
  printf 'report: %s\n' "$OUT/history/$BASE.md"
fi

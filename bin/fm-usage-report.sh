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
#                            "type":"assistant" and a SCHEMA-VALID "message.usage"
#                            object contribute (report's Aggregation rule: "Sum
#                            every assistant message.usage"); schema-valid also
#                            requires a non-empty STRING timestamp on every such
#                            event. SEPARATELY, every one of those timestamps
#                            (not just a session-wide min/max sample) is
#                            batch-validated for actual GNU-date parseability in
#                            one `date -f -` call per session: a usage-bearing
#                            event this cannot place in time is exactly as
#                            untrustworthy as one whose token counts are
#                            unreadable, whether it is missing, non-string, or
#                            lexically buried between OTHER valid timestamps
#                            (QA rounds 2 and 3: a naive extrema-only check let
#                            a hidden bad timestamp evade validation entirely).
#                            A session's own time range for window-matching is
#                            derived SOLELY from its (validated) assistant-event
#                            timestamps, never from unrelated envelope events,
#                            and is included only when that range overlaps the
#                            task's [spawned_at, window_end + grace] interval
#                            (report 3.4). window_end is ended_at for a closed
#                            task (task-runs.jsonl), "now" for a still-live
#                            task, and falls back to spawned_at when no better
#                            bound exists. A task with no parseable spawned_at
#                            cannot be time-filtered at all: every top-level
#                            session under its worktree dir is a candidate
#                            instead, and the result is labeled
#                            tokens_status=ambiguous_join (report 3.4, 3.5). A
#                            session claimed by MORE THAN ONE task (a reused
#                            worktree with overlapping windows) is excluded
#                            from every claiming task's sum rather than being
#                            double-counted or arbitrarily assigned; every
#                            affected task is also ambiguous_join. A malformed/
#                            schema-invalid/unparseable-timestamp/concurrently-
#                            mutated session file is data tolerance, like a
#                            malformed task-runs.jsonl row, but - unlike a
#                            merely out-of-window sibling - it downgrades its
#                            whole task to tokens_status=partial (a floor,
#                            never a false ok/high); a session file that cannot
#                            be READ at all (permissions, I/O) is an
#                            operational failure and aborts the run via
#                            run_or_die/run_or_die_to_file. See the "Claude
#                            token join (slice M2 round 4, class-level)"
#                            section below for the full per-finding rationale
#                            (data/qa-m2-q34/report.md,
#                            data/qa-m2r2-q43/report.md,
#                            data/qa-m2r3-q47/report.md).
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
# DETERMINISM: given fixed inputs and an explicit window, the mix tables, the
# Claude token join, and the fingerprint are all deterministic (the fingerprint
# deliberately excludes the wall clock, but DOES cover the tokens panel - see
# "fingerprint this run's own private JSON" below; QA round 1 found the
# original mix-only canonical form let two archives with different Claude
# usage share one fingerprint). The concurrency-critical publish/lock mechanism
# itself is unchanged from the M1 QA rounds; only the data folded into the
# fingerprint widened. Claude token sums are deterministic for fixed session
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
fm-usage-report.sh - model-economy usage report (slice M2: model mix + Claude tokens)

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

# must_read_run_out <diagnostic>: prints the CURRENT $RUN_OUT content
# (trailing newline stripped, same as any $(...) capture) for the caller to
# assign via $(...). Reads via bash's own "$(< file)" redirection builtin, not
# an external process, so this is deliberately NOT a run_or_die candidate -
# there is nothing external to route through it. It exists because run_or_die
# itself cannot be reused for this: run_or_die unconditionally resets $RUN_OUT
# to empty as its own first step, so a run_or_die call can never read $RUN_OUT
# as an input - only ever produce a fresh one. A read failure (RUN_OUT
# vanished, permissions) still aborts loud with a named diagnostic; bash's own
# raw "No such file" message for this construct bypasses normal fd redirection
# (verified empirically), so it is suppressed in favor of this one.
#
# CALLING CONTRACT (load-bearing - do not violate it): this function's
# failure path is an `exit 2` INSIDE its own subshell, because it always runs
# as $(must_read_run_out ...). A command substitution's `exit` only
# terminates THAT subshell, never the parent script. Empirically verified:
# the exit status DOES propagate correctly when the substitution is the
# entire right-hand side of a bare assignment - `var=$(must_read_run_out
# ...)` - but is SILENTLY DISCARDED when embedded inside another command's
# arguments, e.g. `printf '%s\n' "$(must_read_run_out ...)"`, because
# printf's OWN exit status is then what `$?`/`||` observes, and printf
# happily succeeds on whatever partial/empty string the aborted substitution
# produced. QA round 3 (data/qa-m2r3-q47/report.md finding 3) caught exactly
# this: four call sites embedded the substitution and could publish a report
# with a silently missing Claude token row. EVERY call to this function MUST
# therefore be a bare assignment on its own line -
# `content="$(must_read_run_out "...")"` - with any use of $content on a
# SEPARATE, later statement. The static assertion in
# tests/fm-usage-report.test.sh enforces this shape for every call site in
# the join stage.
must_read_run_out() {
  local diagnostic="$1" content
  if ! content="$(< "$RUN_OUT")" 2>/dev/null; then
    printf 'fm-usage-report: %s\n' "$diagnostic" >&2
    exit 2
  fi
  printf '%s' "$content"
}

# run_or_die_to_file <diagnostic> <allowed-regex> <dest> -- <command> [args...]
# Same checked/named-diagnostic/real-status contract as run_or_die, but
# writes the command's stdout DIRECTLY to <dest> instead of the shared
# $RUN_OUT. This is the checked owner for find's NUL-delimited -print0
# output: shell file redirection is always byte-for-byte (unlike a bash
# variable, which cannot hold an embedded NUL byte), so writing straight to
# <dest> is NUL-safe with no intermediate copy step at all - there is no
# separate "preserve $RUN_OUT before the next call resets it" step to get
# wrong, and so no separate cp call to guard. Mirrors run_or_die's own
# structure exactly, INCLUDING capturing the real exit status in an explicit
# `else` branch. That else is load-bearing, not stylistic: `status=$?` placed
# AFTER an `if cmd; then ...; fi` with NO else is a real bug, not a style
# nit - POSIX defines a condition-only-false if-statement's own exit status
# as 0 regardless of the condition's real status (empirically verified), so
# `$?` immediately after such a block is always 0, never the failed
# command's actual code. The removed save_run_out_to had exactly this bug
# (QA round 3 finding 2): it bypassed run_or_die AND silently misreported a
# real cp failure as "(exit 0)".
run_or_die_to_file() {
  local diagnostic=$1 allowed=${2:-} dest=$3 status
  shift 3
  [ "${1:-}" = "--" ] && shift
  if ! : > "$RUN_ERR"; then
    printf 'fm-usage-report: failed to reset command diagnostic capture %s\n' "$RUN_ERR" >&2
    exit 2
  fi
  if "$@" > "$dest" 2> "$RUN_ERR"; then
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

# --- Claude token join (slice M2 round 4, class-level) ------------------------
# Redesigned a third time after independent QA (data/qa-m2r3-q47/report.md)
# found the round-3 point patches did not close their finding classes:
#
#   F1 (class-level): round 3 validated that every assistant event's
#      timestamp is a non-empty STRING, then computed the session's
#      [min,max] window from ALL events (assistant and non-assistant) and
#      epoch-converted only those two extrema. An assistant event with a
#      LEXICALLY INTERIOR but semantically unparseable timestamp (e.g.
#      "12:30:99") never became an extremum when real envelope events
#      bracketed it, so it was never epoch-converted and never invalidated -
#      the exact QA reproduction. The class-level fix: stop deriving the
#      window from ALL events, and stop checking only two extrema. The
#      session's window is now derived SOLELY from assistant-event
#      timestamps (the only ones that can ever contribute tokens), and EVERY
#      one of them is individually epoch-validated via one batched
#      `date -u -f -` call per session (feeding the whole timestamp list at
#      once, not one process per timestamp) - any single unparseable
#      timestamp fails the whole batch, and the session is invalid. There is
#      now exactly one timestamp gate for the whole join, and it validates
#      every timestamp that matters, not two samples of many.
#   F2 (class-level): round 3 introduced save_run_out_to, a cp call OUTSIDE
#      run_or_die with a real bug (see run_or_die_to_file's own comment for
#      why `status=$?` after an if-with-no-else is 0, not the real code) -
#      so it neither routed through the frozen owner NOR reported the truth
#      when it failed. The class-level fix removes the need for a copy step
#      at all: find's NUL-delimited output now goes straight from `find` to
#      its destination FILE via run_or_die_to_file - shell file redirection
#      is always byte-for-byte, so there is nothing left to copy, and
#      nothing left to get wrong. run_or_die_to_file mirrors run_or_die's own
#      proven-correct structure (explicit else branch) exactly.
#   F3 (class-level): round 3's "write $RUN_OUT to a file" sites all wrote
#      `printf '%s\n' "$(must_read_run_out ...)" > dest || { ...; exit 2; }`.
#      must_read_run_out's own `exit 2` on failure only terminates the
#      $(...) SUBSHELL it runs in; when that call is embedded inside
#      printf's arguments, printf still runs (on whatever partial/empty text
#      the aborted subshell produced), printf still succeeds, and the `||`
#      guard never fires - four sites could each publish a report with a
#      silently missing Claude token row. Verified empirically: the failure
#      DOES propagate under `set -e` when the substitution is instead the
#      ENTIRE right-hand side of a bare assignment on its own line. The
#      class-level fix separates every one of the four sites into a bare
#      assignment followed by a separate use, and must_read_run_out's own
#      comment now states this as a load-bearing calling contract. The
#      static assertion below greps for ANY remaining embedded
#      $(must_read_run_out ...) call, not just the four QA found, so a
#      future regression at a new call site is caught the same way.
#
# Architecture is otherwise unchanged: bash gathers structured facts (date
# parsing, guarded external calls, now via run_or_die/run_or_die_to_file
# exclusively - must_read_run_out is a bash builtin, not an external call,
# so it is deliberately not itself a run_or_die candidate); one jq pass at
# the end does every comparison, validation, and arithmetic sum.

CLAUDE_TOKEN_MAX_FIELD=1000000000

run_or_die "cannot create a claude-tokens temp file" "" -- mktemp "${TMPDIR:-/tmp}/fm-usage-tokens.XXXXXX"
TOKENS_FILE="$(must_read_run_out "cannot read the claude-tokens temp file path")"
CLEANUP_FILES+=("$TOKENS_FILE")

run_or_die "cannot create a claude task-records temp file" "" -- mktemp "${TMPDIR:-/tmp}/fm-usage-claude-task-records.XXXXXX"
CLAUDE_TASK_RECORDS_FILE="$(must_read_run_out "cannot read the claude task-records temp file path")"
CLEANUP_FILES+=("$CLAUDE_TASK_RECORDS_FILE")

run_or_die "cannot create a claude-sessions temp file" "" -- mktemp "${TMPDIR:-/tmp}/fm-usage-claude-sessions.XXXXXX"
CLAUDE_SESSIONS_FILE="$(must_read_run_out "cannot read the claude-sessions temp file path")"
CLEANUP_FILES+=("$CLAUDE_SESSIONS_FILE")

run_or_die "cannot create a claude session-list temp file" "" -- mktemp "${TMPDIR:-/tmp}/fm-usage-sessionlist.XXXXXX"
SESSION_LIST_FILE="$(must_read_run_out "cannot read the claude session-list temp file path")"
CLEANUP_FILES+=("$SESSION_LIST_FILE")

run_or_die "cannot create a claude task extraction temp file" "" -- mktemp "${TMPDIR:-/tmp}/fm-usage-claude-tasks-raw.XXXXXX"
CLAUDE_TASKS_RAW_FILE="$(must_read_run_out "cannot read the claude task extraction temp file path")"
CLEANUP_FILES+=("$CLAUDE_TASKS_RAW_FILE")

# Claude task rows to join, extracted from the already-deduplicated REC_FILE.
# CLAUDE_TASKS_RAW_FILE is created ABOVE, before this call: must_read_run_out
# must run immediately after the ONE run_or_die call whose output it reads,
# with no other run_or_die (such as a mktemp) interposed - any run_or_die call
# resets $RUN_OUT as its own first step, so an interposed call would clobber
# this extraction's output before it is ever read.
run_or_die "failed to extract claude task rows with jq" "" -- "$JQ_BIN" -r '
  select(.harness == "claude") |
  [ .task, (.worktree // ""), (.model // ""), (.spawned_at // ""), (.window_end // "") ]
  | join("\u001f")
' "$REC_FILE"
CLAUDE_TASKS_RAW_CONTENT="$(must_read_run_out "failed to read claude task extraction output")"
printf '%s\n' "$CLAUDE_TASKS_RAW_CONTENT" > "$CLAUDE_TASKS_RAW_FILE" \
  || { echo "fm-usage-report: failed to write claude task extraction temp" >&2; exit 2; }

# emit_claude_task_record <task> <model> <dir> <has_worktree true|false> <dir_found true|false> <sp_epoch-or-empty> <task_hi_epoch-or-empty>
emit_claude_task_record() {
  # shellcheck disable=SC2016 # jq variables are expanded by jq, not the shell.
  run_or_die "failed to build claude task record with jq" "" -- "$JQ_BIN" -n \
    --arg task "$1" --arg model "$2" --arg dir "$3" \
    --argjson has_worktree "$4" --argjson dir_found "$5" \
    --arg sp "${6:-}" --arg hi "${7:-}" '
    def numOrNull(x): if x == "" then null else (x|tonumber) end;
    { task:$task, model:$model, dir:(if $dir=="" then null else $dir end),
      has_worktree:$has_worktree, dir_found:$dir_found,
      sp_epoch: numOrNull($sp), task_hi_epoch: numOrNull($hi) }'
  CLAUDE_TASK_RECORD_CONTENT="$(must_read_run_out "failed to read claude task record output")"
  printf '%s\n' "$CLAUDE_TASK_RECORD_CONTENT" >> "$CLAUDE_TASK_RECORDS_FILE" \
    || { echo "fm-usage-report: failed to append claude task record" >&2; exit 2; }
}

# emit_claude_session_record <dir> <valid true|false> <ts_min_epoch-or-empty> <ts_max_epoch-or-empty> <input> <output> <cache_read> <cache_write> <models-json-array>
CLAUDE_SESSION_ID=0
emit_claude_session_record() {
  CLAUDE_SESSION_ID=$((CLAUDE_SESSION_ID + 1))
  # shellcheck disable=SC2016 # jq variables are expanded by jq, not the shell.
  run_or_die "failed to build claude session record with jq" "" -- "$JQ_BIN" -n \
    --argjson id "$CLAUDE_SESSION_ID" --arg dir "$1" --argjson valid "$2" \
    --arg tsmin "${3:-}" --arg tsmax "${4:-}" \
    --argjson input "$5" --argjson output "$6" --argjson cr "$7" --argjson cw "$8" \
    --argjson models "$9" '
    def numOrNull(x): if x == "" then null else (x|tonumber) end;
    { id:$id, dir:$dir, valid:$valid,
      ts_min_epoch: numOrNull($tsmin), ts_max_epoch: numOrNull($tsmax),
      input_tokens:$input, output_tokens:$output,
      cache_read_tokens:$cr, cache_write_tokens:$cw, models:$models }'
  CLAUDE_SESSION_RECORD_CONTENT="$(must_read_run_out "failed to read claude session record output")"
  printf '%s\n' "$CLAUDE_SESSION_RECORD_CONTENT" >> "$CLAUDE_SESSIONS_FILE" \
    || { echo "fm-usage-report: failed to append claude session record" >&2; exit 2; }
}

# A directory is scanned at most once even when several tasks share a worktree
# (F2's reuse hazard is exactly this sharing); CLAUDE_DIR_FOUND records find's
# outcome (F5) so every task referencing that directory reuses it.
declare -A CLAUDE_DIR_SEEN=()
declare -A CLAUDE_DIR_FOUND=()

while IFS=$'\x1f' read -r ctask cworktree cmodel cspawned cwindow_end; do
  [ -n "$ctask" ] || continue
  has_worktree="false"; cdirkey=""
  if [ -n "$cworktree" ]; then
    has_worktree="true"
    cdirkey="$(encode_claude_dir "$cworktree")"
    if [ -z "${CLAUDE_DIR_SEEN[$cdirkey]:-}" ]; then
      CLAUDE_DIR_SEEN["$cdirkey"]=1
      cdir="$CLAUDE_PROJECTS/$cdirkey"
      # F5: only a genuinely-missing directory is tolerated as absent; any
      # other find failure (permission denied, I/O) aborts the run loudly.
      # F2 (round 4): find writes straight to SESSION_LIST_FILE via
      # run_or_die_to_file - NUL-delimited -print0 output surviving a plain
      # file redirect intact, no separate copy step to guard.
      if run_or_die_to_file "failed to list claude session files in $cdir with find" 'No such file or directory' "$SESSION_LIST_FILE" \
          -- find "$cdir" -maxdepth 1 -type f -name '*.jsonl' -print0; then
        CLAUDE_DIR_FOUND["$cdirkey"]="true"
        while IFS= read -r -d '' sfile; do
          # F1: bracket the read with a stat before and after. A file that
          # vanishes before we can even stat it, or whose size/mtime changes
          # across the read, was being written concurrently - the read cannot
          # be trusted, so the whole file is invalid regardless of what jq saw.
          if ! run_or_die "failed to stat claude session file: $sfile" 'No such file or directory' \
              -- stat -c '%s %Y' "$sfile"; then
            emit_claude_session_record "$cdirkey" false "" "" 0 0 0 0 '[]'
            continue
          fi
          stat_before="$(must_read_run_out "failed to read claude session pre-read stat output")"

          # F1 (round 4, class-level): schema-validate every assistant usage
          # field AND require a non-empty string timestamp on every such
          # event (same as round 3), but this program now ALSO emits every
          # one of those timestamps as its own output line - not just the
          # two session-wide extrema - so the batched date validation below
          # sees and checks every one of them, not a sample that a lexically
          # interior bad timestamp could hide behind. Any parse error
          # (truncated/malformed JSON, e.g. a concurrent writer's torn tail)
          # is tolerated as data, not an operational failure, but marks this
          # session invalid rather than silently skipping it.
          # shellcheck disable=SC2016 # jq variables are expanded by jq, not the shell.
          if ! run_or_die "failed to parse claude session file with jq: $sfile" '^jq: parse error:' \
              -- "$JQ_BIN" -rs --argjson maxv "$CLAUDE_TOKEN_MAX_FIELD" '
            def MAXV: $maxv;
            def numOK(x): (x != null) and (x|type=="number") and ((x|floor)==x) and (x>=0) and (x<=MAXV);
            def evOK(e): (e.message.usage? != null) and
              numOK(e.message.usage.input_tokens) and
              numOK(e.message.usage.output_tokens) and
              ((e.message.usage.cache_read_input_tokens==null) or numOK(e.message.usage.cache_read_input_tokens)) and
              ((e.message.usage.cache_creation_input_tokens==null) or numOK(e.message.usage.cache_creation_input_tokens)) and
              (e.timestamp != null) and (e.timestamp|type=="string") and (e.timestamp != "");
            ( [ .[] | select(type=="object" and .type=="assistant") ] ) as $asst |
            ( $asst | all(evOK(.)) ) as $schemaOk |
            [ ($schemaOk|tostring), (($asst|length)>0|tostring),
              ((if $schemaOk then ([ $asst[] | (.message.usage.input_tokens? // 0) ] | add // 0) else 0 end)|tostring),
              ((if $schemaOk then ([ $asst[] | (.message.usage.output_tokens? // 0) ] | add // 0) else 0 end)|tostring),
              ((if $schemaOk then ([ $asst[] | (.message.usage.cache_read_input_tokens? // 0) ] | add // 0) else 0 end)|tostring),
              ((if $schemaOk then ([ $asst[] | (.message.usage.cache_creation_input_tokens? // 0) ] | add // 0) else 0 end)|tostring),
              ((if $schemaOk then ([ $asst[] | .message.model? // empty ] | map(select(type=="string")) | unique) else [] end)|tojson)
            ] | join("\u001f"),
            ( if $schemaOk and ($asst|length)>0 then $asst[].timestamp else empty end )' \
              "$sfile"; then
            emit_claude_session_record "$cdirkey" false "" "" 0 0 0 0 '[]'
            continue
          fi
          sess_content="$(must_read_run_out "failed to read claude session parse output")"

          if ! run_or_die "failed to stat claude session file: $sfile" 'No such file or directory' \
              -- stat -c '%s %Y' "$sfile"; then
            stat_after=""
          else
            stat_after="$(must_read_run_out "failed to read claude session post-read stat output")"
          fi

          if [ "$stat_before" != "$stat_after" ]; then
            emit_claude_session_record "$cdirkey" false "" "" 0 0 0 0 '[]'
            continue
          fi

          readarray -t sess_lines <<< "$sess_content"
          IFS=$'\x1f' read -r v_valid v_has_events v_in v_out v_cr v_cw v_models <<< "${sess_lines[0]}"
          v_tsmin_epoch=""
          v_tsmax_epoch=""
          if [ "$v_valid" = "true" ] && [ "$v_has_events" = "true" ] && [ "${#sess_lines[@]}" -gt 1 ]; then
            # F1 (round 4): validate EVERY assistant timestamp in ONE batched
            # `date -f -` call (not one process per timestamp, not just the
            # extrema). Any single unparseable line fails the whole batch
            # (GNU date continues past bad lines but exits nonzero and names
            # each one on stderr, matching the same '^date: invalid date '
            # text to_epoch already tolerates elsewhere in this script), so
            # the session is marked invalid rather than silently keeping
            # whichever lines happened to parse.
            ts_list="$(printf '%s\n' "${sess_lines[@]:1}")"
            if run_or_die "failed to validate assistant timestamps in claude session file: $sfile" '^date: invalid date ' \
                -- "$DATE_BIN" -u -f - +%s <<< "$ts_list"; then
              epochs_content="$(must_read_run_out "failed to read validated assistant timestamp epochs")"
              readarray -t epoch_lines <<< "$epochs_content"
              v_tsmin_epoch="${epoch_lines[0]}"; v_tsmax_epoch="${epoch_lines[0]}"
              for e in "${epoch_lines[@]}"; do
                [ "$e" -lt "$v_tsmin_epoch" ] && v_tsmin_epoch="$e"
                [ "$e" -gt "$v_tsmax_epoch" ] && v_tsmax_epoch="$e"
              done
            else
              v_valid="false"
            fi
          fi
          emit_claude_session_record "$cdirkey" "$v_valid" "$v_tsmin_epoch" "$v_tsmax_epoch" \
            "$v_in" "$v_out" "$v_cr" "$v_cw" "$v_models"
        done < "$SESSION_LIST_FILE"
      else
        CLAUDE_DIR_FOUND["$cdirkey"]="false"
      fi
    fi
  fi
  sp_epoch=""; [ -n "$cspawned" ] && sp_epoch="$(to_epoch "$cspawned")"
  we_epoch=""; [ -n "$cwindow_end" ] && we_epoch="$(to_epoch "$cwindow_end")"
  task_hi_epoch=""; [ -n "$we_epoch" ] && task_hi_epoch=$((we_epoch + CLAUDE_GRACE_SECONDS))
  dir_found="false"; [ -n "$cdirkey" ] && dir_found="${CLAUDE_DIR_FOUND[$cdirkey]:-false}"
  emit_claude_task_record "$ctask" "$cmodel" "$cdirkey" "$has_worktree" "$dir_found" "$sp_epoch" "$task_hi_epoch"
done < "$CLAUDE_TASKS_RAW_FILE"

# F2/F3/F4: one jq pass resolves global session-claim uniqueness (never split
# or double-count a shared session), sums validated fields in jq (never signed
# Bash arithmetic), and resolves the reported model/confidence/provenance.
# shellcheck disable=SC2016 # jq variables are expanded by jq, not the shell.
run_or_die "failed to aggregate claude token joins with jq" "" -- "$JQ_BIN" -nc \
  --slurpfile tasks "$CLAUDE_TASK_RECORDS_FILE" \
  --slurpfile sessions "$CLAUDE_SESSIONS_FILE" '
  ($tasks) as $T | ($sessions) as $S |
  ($T | map(
    . as $t |
    ($S | map(select(.dir == $t.dir))) as $dirSessions |
    ($dirSessions | map(select(.valid))) as $validSessions |
    ($dirSessions | map(select(.valid|not)) | length) as $problemCount |
    (if $t.sp_epoch == null then
       ($validSessions | map(.id))
     else
       ($validSessions | map(select(
          (.ts_min_epoch != null) and (.ts_max_epoch != null) and
          (([.ts_min_epoch, .ts_max_epoch] | min) <= $t.task_hi_epoch) and
          (([.ts_min_epoch, .ts_max_epoch] | max) >= $t.sp_epoch)
        )) | map(.id))
     end) as $claimIds |
    { task: $t.task, model_meta: $t.model, has_worktree: $t.has_worktree, dir_found: $t.dir_found,
      undated: ($t.sp_epoch == null), problem_count: $problemCount, claim_ids: $claimIds }
  )) as $claims |
  ($claims | map(.claim_ids[]) | group_by(.) | map({key: (.[0]|tostring), value: length}) | from_entries) as $claimCounts |
  ($S | map({(.id|tostring): .}) | add // {}) as $sessById |
  ($claims | map(
    . as $c |
    ($c.claim_ids | map(select(($claimCounts[(.|tostring)] // 0) == 1))) as $uniqueIds |
    ($c.claim_ids | map(select(($claimCounts[(.|tostring)] // 0) > 1)) | length) as $ambiguousCount |
    ($uniqueIds | map($sessById[(.|tostring)])) as $uniqueSessions |
    {
      task: $c.task, model_meta: $c.model_meta, has_worktree: $c.has_worktree, dir_found: $c.dir_found,
      undated: $c.undated, problem_count: $c.problem_count, ambiguous_excluded: $ambiguousCount,
      sessions_matched: ($uniqueSessions | length),
      input_tokens: ([$uniqueSessions[].input_tokens] | add // 0),
      output_tokens: ([$uniqueSessions[].output_tokens] | add // 0),
      cache_read_tokens: ([$uniqueSessions[].cache_read_tokens] | add // 0),
      cache_write_tokens: ([$uniqueSessions[].cache_write_tokens] | add // 0),
      transcript_models: ([$uniqueSessions[].models[]] | unique)
    }
  ))
  | map(
    . as $r |
    (if $r.problem_count > 0 then "partial"
     elif $r.ambiguous_excluded > 0 then "ambiguous_join"
     elif $r.undated and $r.sessions_matched > 0 then "ambiguous_join"
     elif $r.sessions_matched > 0 then "ok"
     else "absent"
     end) as $status |
    (if ($r.has_worktree | not) then "none" else "claude_project_dir" end) as $join_method |
    ($r.transcript_models) as $tm |
    (if ($tm | length) == 1 then $tm[0] else null end) as $single |
    (if $r.model_meta == "default" then
       (if $single != null then $single else "default" end)
     elif ($single != null and $single != $r.model_meta) then $single
     else $r.model_meta end) as $resolved_model |
    ( ($r.model_meta == "default") or (($tm|length) > 1) or ($single != null and $single != $r.model_meta) ) as $model_uncertain |
    (if $status == "ok" then (if $model_uncertain then "low" else "high" end)
     elif $status == "ambiguous_join" then "low"
     elif $status == "partial" then "low"
     else "none" end) as $confidence |
    (if $r.model_meta == "default" then
       (if $single != null then "transcript" else "unknown" end)
     elif ($single != null and $single != $r.model_meta) then "transcript"
     else "routing" end) as $model_source |
    {
      task: $r.task, harness: "claude", model: $resolved_model, join_method: $join_method,
      tokens_status: $status, confidence: $confidence,
      input_tokens: $r.input_tokens, output_tokens: $r.output_tokens,
      cache_read_tokens: $r.cache_read_tokens, cache_write_tokens: $r.cache_write_tokens,
      reasoning_tokens: null,
      total_tokens: ($r.input_tokens + $r.output_tokens + $r.cache_read_tokens + $r.cache_write_tokens),
      sessions_matched: $r.sessions_matched,
      sessions_problem: $r.problem_count,
      ambiguous_sessions_excluded: $r.ambiguous_excluded,
      model_source: $model_source
    }
  )[]'
CLAUDE_TOKEN_JOIN_CONTENT="$(must_read_run_out "failed to read claude token join output")"
printf '%s\n' "$CLAUDE_TOKEN_JOIN_CONTENT" > "$TOKENS_FILE" \
  || { echo "fm-usage-report: failed to write claude token join output" >&2; exit 2; }

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
      tokens: (
        # F6: one normalized row per task, EVERY harness - claude rows already
        # fully resolved (status/confidence/model/uniqueness) by the join
        # stage above; every other harness gets an explicit unsupported
        # placeholder row here rather than being reduced to an aggregate-only
        # count. by_task is therefore a complete, captain-checkable ledger.
        ( $tok + ( [ $t[] | select(.harness != "claude") ] | map({
            task: .task, harness: .harness, model: .model, join_method: "none",
            tokens_status: "unsupported", confidence: "none",
            input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0,
            reasoning_tokens: null, total_tokens: 0, sessions_matched: 0,
            sessions_problem: 0, ambiguous_sessions_excluded: 0, model_source: "n/a"
          }) )
        | sort_by(.task) ) as $byTask |
        {
          status: "partial",
          note: "Claude token join implemented (slice M2, join_method=claude_project_dir, grace=\($grace_hours)h, source_dir=\($claude_projects)). Codex/Grok/Gemini token joins land in later slices (M3+); those tasks report tokens_status=\"unsupported\".",
          by_task: $byTask,
          by_harness_model: (
            $byTask | group_by([.harness, .model])
            | map({
                harness: .[0].harness, model: .[0].model,
                tasks: length,
                tasks_with_data: ([ .[] | select(.tokens_status == "ok" or .tokens_status == "ambiguous_join" or .tokens_status == "partial") ] | length),
                input_tokens: ([ .[].input_tokens ] | add // 0),
                output_tokens: ([ .[].output_tokens ] | add // 0),
                cache_read_tokens: ([ .[].cache_read_tokens ] | add // 0),
                cache_write_tokens: ([ .[].cache_write_tokens ] | add // 0),
                total_tokens: ([ .[].total_tokens ] | add // 0)
              })
            | sort_by([ (-.tasks), .harness, .model ])
          ),
          totals: {
            tasks_total: ($byTask | length),
            ok: ([ $byTask[] | select(.tokens_status == "ok") ] | length),
            ambiguous_join: ([ $byTask[] | select(.tokens_status == "ambiguous_join") ] | length),
            partial: ([ $byTask[] | select(.tokens_status == "partial") ] | length),
            absent: ([ $byTask[] | select(.tokens_status == "absent") ] | length),
            unsupported: ([ $byTask[] | select(.tokens_status == "unsupported") ] | length),
            ambiguous_sessions_excluded: ([ $byTask[].ambiguous_sessions_excluded ] | add // 0)
          }
        }
      ),
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
  "Totals: \(.panels.tokens.totals.ok) ok, \(.panels.tokens.totals.ambiguous_join) ambiguous_join, \(.panels.tokens.totals.partial) partial, \(.panels.tokens.totals.absent) absent, \(.panels.tokens.totals.unsupported) unsupported (of \(.panels.tokens.totals.tasks_total) tasks; \(.panels.tokens.totals.ambiguous_sessions_excluded) session(s) excluded fleet-wide for reused-worktree ambiguity).",
  "",
  "### By task",
  "",
  ( if (.panels.tokens.by_task | length) > 0
    then ( "| task | harness | model | join_method | status | confidence | input | output | cache_read | cache_write | total | sessions | problems | excluded |",
           "| --- | --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
           (.panels.tokens.by_task[]
             | "| \(.task) | \(.harness) | \(.model) | \(.join_method) | \(.tokens_status) | \(.confidence) | \(.input_tokens) | \(.output_tokens) | \(.cache_read_tokens) | \(.cache_write_tokens) | \(.total_tokens) | \(.sessions_matched) | \(.sessions_problem) | \(.ambiguous_sessions_excluded) |"),
           "" )
    else empty end ),
  ( if (.panels.tokens.by_harness_model | length) > 0
    then ( "### By harness / model",
           "",
           "| harness | model | tasks | with data | input | output | cache_read | cache_write | total |",
           "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
           (.panels.tokens.by_harness_model[]
             | "| \(.harness) | \(.model) | \(.tasks) | \(.tasks_with_data) | \(.input_tokens) | \(.output_tokens) | \(.cache_read_tokens) | \(.cache_write_tokens) | \(.total_tokens) |"),
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
# The canonical form is bounded (mix + tokens, still excluding the not-yet-
# implemented spend/counterfactual scaffolding, which never varies at this
# slice). QA round 1 (data/qa-m2-q34/report.md finding 6) found that omitting
# panels.tokens let two archives with different Claude usage share one
# fingerprint; tokens is deterministic for fixed inputs and a fixed
# FM_USAGE_NOW exactly like model_mix, so it belongs in the canonical form too.
run_or_die "failed to canonicalize report for fingerprint with jq" "" \
  -- "$JQ_BIN" -S '{window, totals, model_mix: .panels.model_mix, tokens: .panels.tokens}' "$TMP_JSON"
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

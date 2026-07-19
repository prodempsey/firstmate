#!/usr/bin/env bash
# Behavior tests for bin/fm-usage-report.sh (Slice M1: model-mix reporting;
# Slice M2: Claude token joiner).
#
# Everything runs in mktemp sandboxes seeded with fixture metas, a fixture
# task-runs.jsonl, and (for M2) fixture Claude session JSONL trees under
# FM_CLAUDE_PROJECTS_OVERRIDE; no test ever reads a live runtime home or a live
# ~/.claude/projects. Coverage:
#   - deterministic model-mix tables (harness/model/effort, kind, repo splits)
#   - live-meta / task-runs dedup (a still-live task counted once, meta wins)
#   - window filtering, including inclusive date-only bounds
#   - undated tasks (no timestamp) always included and counted
#   - routing-profile coverage (live meta only)
#   - confidence-label scaffolding for the not-yet-built spend/cf panels, and
#     the M2 tokens panel's partial status with a unified by_task ledger
#   - fingerprint determinism across a wall-clock change
#   - empty inputs still produce a valid report
#   - FM_STATE_OVERRIDE input scoping
#   - the accumulator survives a fleet larger than the argv limit
#   - interval overlap: a task spanning the whole window is kept (QA finding 1)
#   - index.jsonl is physical JSON Lines, one object per line (QA finding 2)
#   - same-second archive runs do not overwrite each other (QA finding 3)
#   - CONCURRENT same-second runs each yield one correct immutable snapshot,
#     with agreeing json/md pairs and fingerprints that recompute (QA r2 f1)
#   - forced publication interleaving keeps the latest pair coherent (QA r3 f1)
#   - publication failures (lock open, first rename) fail loud and nonzero,
#     never a masked success with a half-published pair (QA r4 f1)
#   - a sha256sum failure in the fingerprint pipeline fails loud and nonzero
#     instead of publishing with an empty fingerprint (QA r5 f1)
#   - ledger jq failures and timestamp converter failures fail loud and nonzero
#     instead of publishing a silently reduced or mis-windowed report (QA r6 f1/f2)
#   - default-window date failures fail loud even if the failed date process
#     emitted plausible output (QA r7 f1)
#   - helper capture-reset failures fail loud, and helper diagnostics preserve
#     the failed tool's actual exit status (QA r8 f1/f2)
#
# Slice M2 (Claude token joiner) coverage. The joiner has been reworked twice
# after independent QA found it could publish confidently-wrong numbers
# (data/qa-m2-q34/report.md, then data/qa-m2r2-q43/report.md); every fixed
# finding below is annotated with its QA round and finding number, and NONE of
# them tolerate a reduced-but-unlabeled subtotal - a session this joiner
# cannot fully trust never contributes to an ok/high row.
#   - happy path: encode(worktree) join, sum of a matched session's assistant
#     usage, tokens_status=ok, confidence=high, join_method=claude_project_dir
#   - session-file-level time filtering: an unrelated session outside the join
#     window is excluded wholesale even though the directory holds other,
#     in-window sessions (the worktree-pool-reuse hazard from report 4.3/6.3)
#   - inclusive lower/upper join-window boundaries (spawned_at and
#     ended_at+grace), and exclusion one second outside each
#   - grace-hours configurability via FM_USAGE_CLAUDE_GRACE_HOURS, and
#     FM_USAGE_CLAUDE_GRACE_HOURS rejects a non-numeric value
#   - undated tasks (no spawned_at) fall back to summing every top-level
#     session unfiltered, labeled tokens_status=ambiguous_join, confidence=low
#   - absent cases: no worktree recorded, worktree recorded but no matching
#     directory, and a directory with zero top-level session files
#   - subagents/ subdirectories are excluded from the sum by design
#   - missing usage subfields (no cache_read/cache_creation keys) default to 0
#     - this is legitimate (no cache activity that turn), not a schema problem
#   - QA r1 F1 / r2 continued: an assistant event with no usage object, an
#     invalid/negative/overflowing/fractional/string numeric field, a
#     malformed (truncated) session file, and a session whose stat changes
#     across the guarded read (a concurrent writer) ALL make their task
#     tokens_status=partial/confidence=low - a floor, NEVER a
#     silently-reduced ok/high. A malformed sibling never hides a valid
#     session's tokens; it just downgrades the whole task's status.
#   - QA r1 F1 / r2 / r3 / r4 (class-level): a usage-bearing assistant event's
#     timestamp is validated as a whole class, not sampled. Missing,
#     non-string (numeric/null), and unparseable timestamps are all caught -
#     including one that is LEXICALLY INTERIOR to valid non-assistant
#     envelope timestamps, which round 3's extrema-only check missed (round 3
#     QA's exact reproduction). Every assistant timestamp in a session is
#     batch-validated in one `date -f -` call; any single failure invalidates
#     the whole session. An assistant-free session is never penalized (it has
#     no timestamp to lose). round 4 QA then found the batch's newline-joined
#     record framing itself was ambiguous: a JSON timestamp value containing
#     an embedded CR/LF is indistinguishable from two separate records once
#     joined, so a crafted composite value could split into two individually-
#     valid dates and evade validation entirely. Fixed by rejecting an
#     embedded CR/LF at the schema gate, before any batching - a real
#     ISO-8601 timestamp can never legitimately contain one.
#   - QA r1 F2: a session claimed by more than one task sharing a reused
#     worktree with overlapping windows is excluded from ALL of their sums
#     (never split, never double counted); a session claimed by only one of
#     several tasks sharing a worktree is unaffected for the others
#   - QA r1 F3 / r2 F3: routing model=default resolves to a single consistent
#     transcript model with confidence capped to low; a concrete routing model
#     that disagrees with a single transcript model also resolves to the
#     transcript (ground truth) with confidence capped to low AND
#     model_source correctly reported as "transcript" (not "routing") in
#     both cases; heterogeneous transcript models across sessions cap
#     confidence without discarding the tokens
#   - QA r1 F5: an unsearchable (not missing) Claude root - e.g. a mode-000
#     parent - is an operational failure (loud, nonzero, no publish), never
#     silent absence
#   - QA r1 F6: every task (every harness) gets one normalized by_task row;
#     non-claude tasks are explicit tokens_status=unsupported rows, not an
#     aggregate-only tally; the report fingerprint changes when only Claude
#     token totals change, not just when model_mix changes
#   - QA r1 F7 / r2 / r3 (class-level): every external call in the join
#     stage - mktemp, find, jq, stat, and `date -f -` - is routed through
#     run_or_die or run_or_die_to_file (find's NUL-delimited output now
#     writes straight to its destination file, so there is no separate copy
#     step, and no cp to guard at all). must_read_run_out (a bash builtin
#     read, not itself an external call) is used ONLY as a bare assignment on
#     its own line - the one shape whose failure actually propagates under
#     set -e, per round 3's swallowed-substitution finding. A static
#     assertion greps the join stage for every QA-identified anti-pattern
#     (bare cat/cp $RUN_OUT, any embedded/non-bare must_read_run_out call,
#     an unrouted mktemp or find) and asserts zero matches, plus
#     operational-failure regressions preserving the REAL exit status for
#     the mktemp and find call classes.
#   - by_harness_model token rollup across multiple claude tasks sharing a
#     model, including non-claude rows correctly showing zero tokens
#   - Markdown Panel B renders the unified by_task table, the by_harness_model
#     rollup, and the totals line
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

USAGE="$ROOT/bin/fm-usage-report.sh"
TMP_ROOT=$(fm_test_tmproot fm-usage)

# make_home <name>: a bare sandbox home with a state/ dir; echoes its path.
make_home() {
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# append_run <ledger> <task> <kind> <project> <harness> <model> <effort> <ended_at>
# Appends one task_run/1 row (provider null, mirroring the real ledger).
append_run() {
  jq -nc \
    --arg task "$2" --arg kind "$3" --arg project "$4" \
    --arg harness "$5" --arg model "$6" --arg effort "$7" --arg ended "$8" \
    '{schema:"task_run/1", task:$task, kind:$kind, project:$project,
      harness:$harness, model:$model, effort:$effort, provider:null,
      branch:("fm/"+$task), worktree:("/wt/"+$task),
      spawned_at:$ended, ended_at:$ended, outcome:"landed"}' >> "$1"
}

# encode_worktree <absolute-path>: independently mirrors encode_claude_dir()'s
# encoding rule (every '/' and '.' becomes '-') so fixtures can place session
# files exactly where the script will look for them, and so the test spells
# out the same rule as the production code instead of hard-coding one example.
encode_worktree() {
  local p="$1"
  printf '%s' "${p//[\/.]/-}"
}

# claude_event <ts> [input] [output] [cache_read] [cache_creation]: one
# top-level type=assistant NDJSON line with a message.usage block. Token args
# default to 0 so a boundary-timing fixture can omit them.
claude_event() {
  jq -nc \
    --arg ts "$1" --argjson in "${2:-0}" --argjson out "${3:-0}" \
    --argjson cr "${4:-0}" --argjson cc "${5:-0}" \
    '{type:"assistant", timestamp:$ts, cwd:"/irrelevant", sessionId:"s",
      message:{model:"claude-opus-4-8", usage:{
        input_tokens:$in, output_tokens:$out,
        cache_read_input_tokens:$cr, cache_creation_input_tokens:$cc}}}'
}

# non_assistant_event <ts>: a non-assistant line (e.g. type=user), proving the
# joiner ignores everything except type=assistant events with a usage block.
non_assistant_event() {
  jq -nc --arg ts "$1" '{type:"user", timestamp:$ts, message:{content:"hi"}}'
}

OUT_SUB="data/model-economy/usage"

# --- 1. deterministic mix tables + dedup + window ---------------------------
H=$(make_home mix)
S=$H/state
fm_write_meta "$S/t1.meta" \
  project=/home/prode/fleet/firstmate harness=claude kind=ship \
  model=claude-opus-4-8 effort=high spawned_at=2026-07-15T10:00:00Z \
  class=normal_code_change profile=implementer_balanced provider=anthropic
fm_write_meta "$S/t2.meta" \
  project=/home/prode/fleet/krakenloop harness=codex kind=scout \
  model=gpt-5.5 effort=high spawned_at=2026-07-16T10:00:00Z
fm_write_meta "$S/t3.meta" \
  project=/home/prode/fleet/firstmate harness=claude kind=ship \
  model=claude-opus-4-8 effort=high spawned_at=2026-07-17T10:00:00Z
L=$S/task-runs.jsonl
append_run "$L" t1 ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T09:30:00Z
append_run "$L" r1 ship /home/prode/fleet/fleet-bridge codex gpt-5.6-sol high 2026-07-14T09:00:00Z
append_run "$L" wayold scout /home/prode/fleet/fleet-bridge grok grok-4.5 high 2026-06-01T10:00:00Z

FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
  --target "$H" --since 2026-07-10 --until 2026-07-18 >/dev/null \
  || fail "mix run exited non-zero"

J=$H/$OUT_SUB/latest.json
assert_present "$J" "latest.json written"
assert_present "$H/$OUT_SUB/latest.md" "latest.md written"

[ "$(jq -r '.schema' "$J")" = "fm-usage-report/1" ] || fail "schema field"
[ "$(jq -r '.slice' "$J")" = "M2" ] || fail "slice field"

# Dedup + window: t1 (live) counted once, wayold excluded -> 4 tasks total.
[ "$(jq -r '.totals.tasks' "$J")" = 4 ] || fail "totals.tasks (dedup/window): $(jq -c .totals "$J")"
[ "$(jq -r '.totals.live' "$J")" = 3 ] || fail "totals.live"
[ "$(jq -r '.totals.closed' "$J")" = 1 ] || fail "totals.closed"
[ "$(jq -r '.totals.undated' "$J")" = 0 ] || fail "totals.undated"

# grok/wayold must be entirely absent from the mix.
assert_no_grep grok "$J" "out-of-window grok task must not appear"

# Exact by-harness/model/effort table, in the script's sort order.
EXPECT_HME='[["claude","claude-opus-4-8","high",2],["codex","gpt-5.5","high",1],["codex","gpt-5.6-sol","high",1]]'
GOT_HME=$(jq -c '[.panels.model_mix.by_harness_model_effort[]|[.harness,.model,.effort,.count]]' "$J")
[ "$GOT_HME" = "$EXPECT_HME" ] || fail "by_harness_model_effort: got $GOT_HME"

# kind split.
[ "$(jq -c '[.panels.model_mix.by_kind[]|[.kind,.count]]' "$J")" = '[["ship",3],["scout",1]]' ] \
  || fail "by_kind split"

# repo split (basename of project).
EXPECT_REPO='[["firstmate",2],["fleet-bridge",1],["krakenloop",1]]'
[ "$(jq -c '[.panels.model_mix.by_repo[]|[.repo,.count]]' "$J")" = "$EXPECT_REPO" ] \
  || fail "by_repo split"

# Profile coverage: only the one live meta carried a profile.
[ "$(jq -r '.panels.model_mix.profile_coverage.with_profile' "$J")" = 1 ] || fail "profile with_profile"
[ "$(jq -r '.panels.model_mix.profile_coverage.total' "$J")" = 4 ] || fail "profile total"
[ "$(jq -c '[.panels.model_mix.by_profile[]|[.profile,.class,.count]]' "$J")" \
  = '[["implementer_balanced","normal_code_change",1]]' ] || fail "by_profile row"
pass "mix tables, dedup, and window are deterministic"

# --- 2. markdown is captain-readable ----------------------------------------
MD=$H/$OUT_SUB/latest.md
assert_grep "Panel A - Model mix (confidence: high)" "$MD" "md Panel A header"
assert_grep "| 2 | claude | claude-opus-4-8 | high |" "$MD" "md mix row"
assert_grep "Profile recorded on 1/4 tasks" "$MD" "md profile coverage"
pass "markdown report is captain-readable"

# --- 3. confidence scaffolding for future slices (spend/counterfactual) -----
[ "$(jq -r '.panels.model_mix.confidence' "$J")" = high ] || fail "model_mix confidence"
for panel in spend counterfactual; do
  [ "$(jq -r ".panels.$panel.status" "$J")" = not_implemented ] || fail "$panel status"
  [ "$(jq -r ".panels.$panel.confidence" "$J")" = none ] || fail "$panel confidence"
done
[ "$(jq -r '.panels.tokens.status' "$J")" = partial ] || fail "tokens status"
pass "spend/counterfactual panels are labeled scaffolding; tokens is partial (M2)"

# --- 3b. tokens panel: fixture 1's two claude metas carry no worktree=, so
# both are legitimately absent (no join possible); the two codex tasks (t2,
# r1) land in by_task as explicit unsupported rows (M2 does not join codex).
# QA round-1 finding 6a: by_task is UNIFIED across every harness, not a
# claude-only list plus an aggregate-only unsupported tally.
EXPECT_BYTASK='[["t1","claude","claude-opus-4-8","none","absent"],["t2","codex","gpt-5.5","none","unsupported"],["t3","claude","claude-opus-4-8","none","absent"],["r1","codex","gpt-5.6-sol","none","unsupported"]]'
GOT_BYTASK=$(jq -c '[.panels.tokens.by_task[]|[.task,.harness,.model,.join_method,.tokens_status]] | sort' "$J")
EXPECT_SORTED=$(jq -c 'sort' <<< "$EXPECT_BYTASK")
[ "$GOT_BYTASK" = "$EXPECT_SORTED" ] || fail "unified by_task: got $GOT_BYTASK want $EXPECT_SORTED"
[ "$(jq -r '.panels.tokens.totals.absent' "$J")" = 2 ] || fail "totals.absent"
[ "$(jq -r '.panels.tokens.totals.unsupported' "$J")" = 2 ] || fail "totals.unsupported"
[ "$(jq -r '.panels.tokens.totals.tasks_total' "$J")" = 4 ] || fail "tokens totals.tasks_total"
pass "tokens panel by_task is unified: claude tasks without a worktree are absent, codex is unsupported"

# --- 4. dated archive + index -----------------------------------------------
HIST=$H/$OUT_SUB/history
[ "$(find "$HIST" -name 'usage-*.json' | wc -l)" -ge 1 ] || fail "history json archive"
[ "$(find "$HIST" -name 'usage-*.md' | wc -l)" -ge 1 ] || fail "history md archive"
[ "$(jq -r '.fingerprint' "$H/$OUT_SUB/index.jsonl" | head -1 | wc -c)" -gt 1 ] || fail "index fingerprint"
pass "dated archive copy and run index are written"

# --- 5. fingerprint determinism across a clock change -----------------------
DH=$(make_home determinism)
fm_write_meta "$DH/state/d1.meta" \
  project=/home/prode/fleet/firstmate harness=claude kind=ship \
  model=claude-opus-4-8 effort=high spawned_at=2026-07-15T10:00:00Z
FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" --target "$DH" --since 2026-07-01 --until 2026-07-18 >/dev/null
FM_USAGE_NOW=2026-07-18T23:59:59Z "$USAGE" --target "$DH" --since 2026-07-01 --until 2026-07-18 >/dev/null
FPS=$(jq -r '.fingerprint' "$DH/$OUT_SUB/index.jsonl")
[ "$(printf '%s\n' "$FPS" | wc -l)" = 2 ] || fail "index should have two run lines"
[ "$(printf '%s\n' "$FPS" | sort -u | wc -l)" = 1 ] || fail "fingerprint must be clock-independent"
pass "fingerprint is deterministic across a wall-clock change"

# --- 6. undated tasks are always included and counted -----------------------
UH=$(make_home undated)
# Meta with no spawned_at cannot be windowed.
fm_write_meta "$UH/state/u1.meta" \
  project=/home/prode/fleet/firstmate harness=grok kind=ship model=grok-4.5 effort=high
FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" --target "$UH" --since 2026-07-17 --until 2026-07-18 >/dev/null
UJ=$UH/$OUT_SUB/latest.json
[ "$(jq -r '.totals.tasks' "$UJ")" = 1 ] || fail "undated task must be included"
[ "$(jq -r '.totals.undated' "$UJ")" = 1 ] || fail "undated task must be counted as undated"
pass "undated tasks are always included and counted"

# --- 7. empty inputs still produce a valid report ---------------------------
EH=$(make_home empty)
FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" --target "$EH" --since 2026-07-01 --until 2026-07-18 >/dev/null \
  || fail "empty run exited non-zero"
EJ=$EH/$OUT_SUB/latest.json
[ "$(jq -r '.totals.tasks' "$EJ")" = 0 ] || fail "empty totals.tasks"
[ "$(jq -c '.panels.model_mix.by_harness_model_effort' "$EJ")" = '[]' ] || fail "empty mix array"
pass "empty inputs still produce a valid report"

# --- 8. FM_STATE_OVERRIDE scopes the input ----------------------------------
OH=$(make_home stateoverride)
mkdir -p "$OH/altstate" "$OH/out"
fm_write_meta "$OH/altstate/o1.meta" \
  project=/home/prode/fleet/krakenloop harness=codex kind=ship \
  model=gpt-5.5 effort=high spawned_at=2026-07-15T10:00:00Z
FM_USAGE_NOW=2026-07-18T00:00:00Z FM_STATE_OVERRIDE="$OH/altstate" \
  "$USAGE" --out "$OH/out" --since 2026-07-01 --until 2026-07-18 >/dev/null \
  || fail "FM_STATE_OVERRIDE run exited non-zero"
OJ=$OH/out/latest.json
[ "$(jq -r '.totals.tasks' "$OJ")" = 1 ] || fail "FM_STATE_OVERRIDE input not read"
[ "$(jq -r '.panels.model_mix.by_harness_model_effort[0].model' "$OJ")" = gpt-5.5 ] \
  || fail "FM_STATE_OVERRIDE model mix"
pass "FM_STATE_OVERRIDE scopes the input state dir"

# --- 9. accumulator survives a fleet past the argv limit --------------------
# The per-task accumulator streams through a temp file read by jq --slurpfile,
# never through argv. A pre-argv-limit fixture proves it: ~1500 rows at well over
# 128 bytes each is far past the ~128KB single-argument ceiling that sank earlier
# firstmate readers that folded their input into `jq --argjson`.
BH=$(make_home bigfleet)
BL=$BH/state/task-runs.jsonl
n=0
while [ "$n" -lt 1500 ]; do
  append_run "$BL" "big-$n" ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T10:00:00Z
  n=$((n + 1))
done
[ "$(wc -c < "$BL")" -gt 200000 ] || fail "big fixture must exceed the argv limit to be a real regression"
FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" --target "$BH" --since 2026-07-01 --until 2026-07-18 >/dev/null \
  || fail "big-fleet run exited non-zero (argv limit?)"
[ "$(jq -r '.totals.tasks' "$BH/$OUT_SUB/latest.json")" = 1500 ] || fail "big-fleet task count"
pass "accumulator handles a fleet larger than the argv limit"

# --- 10. bad arguments fail cleanly -----------------------------------------
"$USAGE" --nonsense >/dev/null 2>&1 && fail "unknown arg should exit non-zero"
"$USAGE" --target >/dev/null 2>&1 && fail "flag missing value should exit non-zero"
pass "argument errors exit non-zero"

# --- 11. interval overlap keeps window-spanning tasks (QA finding 1) --------
# Window 2026-07-10..2026-07-11 (date-only: 00:00:00Z .. 23:59:59Z), now well
# after. A task is in the report when its [spawned,ended] interval OVERLAPS the
# window, not when a single collapsed timestamp lands inside it.
present() { jq -e --arg m "$2" 'any(.panels.model_mix.by_harness_model_effort[]; .model==$m)' "$1" >/dev/null 2>&1; }
IH=$(make_home overlap)
IS=$IH/state
# live meta spawned BEFORE the window, still running -> interval [spawn, now]
# overlaps -> kept (the live-meta half of the same interval bug).
fm_write_meta "$IS/live-span.meta" \
  project=/home/prode/fleet/firstmate harness=claude kind=ship \
  model=claude-fable-5 effort=high spawned_at=2026-07-05T00:00:00Z
IL=$IS/task-runs.jsonl
# spanning: spawned before --since, ended after --until -> overlaps whole window.
append_run "$IL" span ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-20T00:00:00Z
# append_run sets spawned_at==ended_at; overwrite span's spawned_at to 07-01.
jq -c 'if .task=="span" then .spawned_at="2026-07-01T00:00:00Z" else . end' "$IL" > "$IL.tmp" && mv "$IL.tmp" "$IL"
# boundary: ended EXACTLY at --since 00:00:00Z -> end>=since is inclusive -> kept.
append_run "$IL" bend scout /home/prode/fleet/krakenloop codex gpt-5.5 high 2026-07-10T00:00:00Z
jq -c 'if .task=="bend" then .spawned_at="2026-07-08T00:00:00Z" else . end' "$IL" > "$IL.tmp" && mv "$IL.tmp" "$IL"
# boundary: spawned EXACTLY at --until 23:59:59Z -> start<=until inclusive -> kept.
append_run "$IL" bstart ship /home/prode/fleet/fleet-bridge grok grok-4.5 high 2026-07-13T00:00:00Z
jq -c 'if .task=="bstart" then .spawned_at="2026-07-11T23:59:59Z" else . end' "$IL" > "$IL.tmp" && mv "$IL.tmp" "$IL"
# entirely before and entirely after -> excluded.
append_run "$IL" before ship /home/prode/fleet/firstmate claude claude-sonnet-5 default 2026-07-06T00:00:00Z
append_run "$IL" after ship /home/prode/fleet/firstmate codex gpt-5.6-sol high 2026-07-16T00:00:00Z

FM_USAGE_NOW=2026-07-25T00:00:00Z "$USAGE" --target "$IH" --since 2026-07-10 --until 2026-07-11 >/dev/null
IJ=$IH/$OUT_SUB/latest.json
[ "$(jq -r '.totals.tasks' "$IJ")" = 4 ] || fail "overlap totals: got $(jq -c .totals "$IJ")"
present "$IJ" claude-opus-4-8 || fail "spanning task must be kept"
present "$IJ" claude-fable-5  || fail "live task spanning into the window must be kept"
present "$IJ" gpt-5.5         || fail "task ending exactly at --since must be kept"
present "$IJ" grok-4.5        || fail "task spawned exactly at --until must be kept"
present "$IJ" claude-sonnet-5 && fail "entirely-before task must be excluded"
present "$IJ" gpt-5.6-sol     && fail "entirely-after task must be excluded"
pass "window overlap keeps spanning and boundary tasks, drops disjoint ones"

# --- 12+13. index is real JSONL and archives never overwrite (findings 2,3) --
# Two runs at the SAME pinned second with DIFFERENT input must each leave a
# distinct immutable archive and a distinct physical JSONL index line.
CH=$(make_home collide)
fm_write_meta "$CH/state/c1.meta" \
  project=/home/prode/fleet/firstmate harness=claude kind=ship \
  model=claude-opus-4-8 effort=high spawned_at=2026-07-15T10:00:00Z
FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" --target "$CH" --since 2026-07-01 --until 2026-07-18 >/dev/null
# Change the input, then run again with the IDENTICAL clock.
fm_write_meta "$CH/state/c2.meta" \
  project=/home/prode/fleet/krakenloop harness=codex kind=scout \
  model=gpt-5.5 effort=high spawned_at=2026-07-16T10:00:00Z
FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" --target "$CH" --since 2026-07-01 --until 2026-07-18 >/dev/null

CIDX=$CH/$OUT_SUB/index.jsonl
# Finding 2: exactly two PHYSICAL lines, each parsing as one object.
[ "$(wc -l < "$CIDX")" = 2 ] || fail "index.jsonl must have exactly 2 physical lines, got $(wc -l < "$CIDX")"
li=0
while IFS= read -r ln; do
  li=$((li + 1))
  printf '%s' "$ln" | jq -e 'type=="object"' >/dev/null 2>&1 || fail "index line $li is not a single JSON object"
done < "$CIDX"
[ "$li" = 2 ] || fail "index.jsonl line count mismatch"
# Finding 3: two distinct, non-overwritten archive snapshots.
CHIST=$CH/$OUT_SUB/history
[ "$(find "$CHIST" -name 'usage-*.json' | wc -l)" = 2 ] || fail "same-second runs must leave 2 archive json files"
[ "$(jq -r '.path' "$CIDX" | sort -u | wc -l)" = 2 ] || fail "index must reference 2 distinct archive paths"
# The two archives preserve the two different reports (1 task, then 2 tasks).
COUNTS=$(find "$CHIST" -name 'usage-*.json' -exec jq -r '.totals.tasks' {} \; | sort | tr '\n' ' ')
[ "$COUNTS" = "1 2 " ] || fail "archives must preserve both distinct reports, got '$COUNTS'"
pass "index.jsonl is real JSONL and same-second archives never overwrite"

# --- 14. concurrent same-second runs stay run-private (QA round 2, finding 1) --
# Four processes with distinct per-run model markers and isolated input homes,
# all writing ONE shared --out at the IDENTICAL pinned second. Each must land its
# own correct immutable snapshot; none may capture another run's content. Asserts
# exactly what the QA report requires: every run appears exactly once, each
# json/md pair agrees, every indexed path exists, and every fingerprint
# recomputes from its referenced archive.
NPROC=4
CSHARED=$TMP_ROOT/cc-shared-out
mkdir -p "$CSHARED"
cpids=()
k=1
while [ "$k" -le "$NPROC" ]; do
  chome=$TMP_ROOT/cc-home-$k
  mkdir -p "$chome/state"
  # A distinct model marker per run, three rows so content is nontrivial.
  t=1
  while [ "$t" -le 3 ]; do
    append_run "$chome/state/task-runs.jsonl" "r$k-t$t" ship \
      /home/prode/fleet/firstmate claude "model-$k" high 2026-07-15T10:00:00Z
    t=$((t + 1))
  done
  FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
    --target "$chome" --out "$CSHARED" --since 2026-07-01 --until 2026-07-18 \
    >/dev/null 2>&1 &
  cpids+=("$!")
  k=$((k + 1))
done
crc=0
for p in "${cpids[@]}"; do wait "$p" || crc=1; done
[ "$crc" = 0 ] || fail "a concurrent run exited non-zero"

# One line and one json/md archive pair per run - nothing lost, nothing merged.
[ "$(wc -l < "$CSHARED/index.jsonl")" = "$NPROC" ] || fail "concurrent: expected $NPROC index lines, got $(wc -l < "$CSHARED/index.jsonl")"
[ "$(find "$CSHARED/history" -name 'usage-*.json' | wc -l)" = "$NPROC" ] || fail "concurrent: expected $NPROC json archives"
[ "$(find "$CSHARED/history" -name 'usage-*.md' | wc -l)" = "$NPROC" ] || fail "concurrent: expected $NPROC md archives"

# Every expected model appears exactly once across the archives (no run's report
# was overwritten by another's shared latest).
CMODELS=$(find "$CSHARED/history" -name 'usage-*.json' -exec jq -r '.panels.model_mix.by_harness_model_effort[].model' {} \; | sort | tr '\n' ' ')
CEXPECT=""
k=1; while [ "$k" -le "$NPROC" ]; do CEXPECT="$CEXPECT model-$k"; k=$((k + 1)); done
CEXPECT="$(printf '%s' "$CEXPECT" | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' ')"
[ "$CMODELS" = "$CEXPECT" ] || fail "concurrent: each model must appear exactly once; got [$CMODELS] want [$CEXPECT]"

# Each indexed run: path exists, json/md pair agrees, fingerprint recomputes.
while IFS= read -r ln; do
  cp_path=$(printf '%s' "$ln" | jq -r '.path')
  cp_fp=$(printf '%s' "$ln" | jq -r '.fingerprint')
  [ -f "$CSHARED/$cp_path" ] || fail "concurrent: indexed archive missing: $cp_path"
  cp_md="${cp_path%.json}.md"
  [ -f "$CSHARED/$cp_md" ] || fail "concurrent: md pair missing for $cp_path"
  cp_tasks=$(jq -r '.totals.tasks' "$CSHARED/$cp_path")
  grep -q "Total tasks: $cp_tasks " "$CSHARED/$cp_md" || fail "concurrent: json/md pair disagree for $cp_path"
  cp_recompute=$(jq -S '{window, totals, model_mix: .panels.model_mix, tokens: .panels.tokens}' "$CSHARED/$cp_path" | sha256sum | cut -d' ' -f1)
  [ "$cp_fp" = "$cp_recompute" ] || fail "concurrent: fingerprint does not recompute for $cp_path ($cp_fp vs $cp_recompute)"
done < "$CSHARED/index.jsonl"
# The published latest pair must itself be a coherent single run: latest.md must
# state the same totals as latest.json and carry every model row it lists.
CL_TASKS=$(jq -r '.totals.tasks' "$CSHARED/latest.json")
grep -q "Total tasks: $CL_TASKS " "$CSHARED/latest.md" || fail "concurrent: latest.json/latest.md disagree on totals"
while IFS= read -r m; do
  grep -q "| $m |" "$CSHARED/latest.md" || fail "concurrent: latest.md missing model row $m from latest.json"
done < <(jq -r '.panels.model_mix.by_harness_model_effort[].model' "$CSHARED/latest.json")
pass "concurrent same-second runs each yield one correct immutable snapshot"

# --- 15. forced publication interleaving keeps the latest pair coherent -------
# Round 3 published latest.json and latest.md in two separate renames, so
# concurrent writers could interleave (A-json, B-json, B-md, A-md) and leave
# latest.json from one run beside latest.md from another. The fix serializes the
# whole pair under one output-scoped lock. This regression forces the exact
# contention: run A is paused by a `mv` shim right AFTER it renames latest.json
# (the gap round 3 published through) while STILL holding the pair lock; run B
# then contends. With the lock, B blocks until A finishes both of its renames,
# so whichever run wins publishes both of ITS files - the pair can never split.
IHOME=$TMP_ROOT/pairlock
mkdir -p "$IHOME"
POUT=$IHOME/out; mkdir -p "$POUT"
REAL_MV="$(command -v mv)"
FB=$(fm_fakebin "$IHOME")
# Shim mv: for the marked slow run only, do the real latest.json rename, signal
# that A has published its json, then block (still inside A's held lock) until
# the test releases it. All other renames pass straight through to the real mv.
cat > "$FB/mv" <<'SH'
#!/usr/bin/env bash
real="${REAL_MV:-/bin/mv}"
if [ "${SLOW_RUN:-0}" = 1 ]; then
  last="${*: -1}"
  case "$last" in
    */latest.json)
      "$real" "$@"
      : > "$A_JSON_DONE"
      tries=0
      while [ ! -e "$A_RELEASE" ] && [ "$tries" -lt 600 ]; do sleep 0.05; tries=$((tries + 1)); done
      exit 0
      ;;
  esac
fi
exec "$real" "$@"
SH
chmod +x "$FB/mv"

hA=$IHOME/home-A; mkdir -p "$hA/state"
hB=$IHOME/home-B; mkdir -p "$hB/state"
# A: one claude/model-A task. B: two codex/model-B tasks (distinct home, model,
# and totals, so any split pair is unambiguous).
append_run "$hA/state/task-runs.jsonl" a1 ship /home/prode/fleet/firstmate claude model-A high 2026-07-15T10:00:00Z
append_run "$hB/state/task-runs.jsonl" b1 ship /home/prode/fleet/krakenloop codex model-B high 2026-07-15T10:00:00Z
append_run "$hB/state/task-runs.jsonl" b2 ship /home/prode/fleet/krakenloop codex model-B high 2026-07-15T10:00:00Z
SIG=$IHOME/a-json-done; REL=$IHOME/a-release

# A runs with the mv shim on PATH and pauses holding the lock after its json rename.
( PATH="$FB:$PATH" SLOW_RUN=1 REAL_MV="$REAL_MV" A_JSON_DONE="$SIG" A_RELEASE="$REL" \
    FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" --target "$hA" --out "$POUT" \
    --since 2026-07-01 --until 2026-07-18 >/dev/null 2>&1 ) &
apid=$!
tries=0; while [ ! -e "$SIG" ] && [ "$tries" -lt 400 ]; do sleep 0.05; tries=$((tries + 1)); done
[ -e "$SIG" ] || { kill "$apid" 2>/dev/null; fail "run A never reached the latest.json publish"; }

# B runs normally (real mv); it writes its archive, then blocks on the pair lock A holds.
( FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" --target "$hB" --out "$POUT" \
    --since 2026-07-01 --until 2026-07-18 >/dev/null 2>&1 ) &
bpid=$!
# Wait until B has written its archive (proof it reached the publish lock and is
# contending), so the interleaving window is genuinely open, THEN release A.
tries=0
while [ "$(find "$POUT/history" -name 'usage-*.json' 2>/dev/null | wc -l)" -lt 2 ] && [ "$tries" -lt 400 ]; do
  sleep 0.05; tries=$((tries + 1))
done
: > "$REL"
wait "$apid" || fail "run A exited non-zero"
wait "$bpid" || fail "run B exited non-zero"

# Whatever won, latest.json and latest.md must be the SAME run: same home, same
# totals, same model rows. A split pair (round 3's bug) fails at least one.
PLJ=$POUT/latest.json; PLM=$POUT/latest.md
pl_home=$(jq -r '.home' "$PLJ")
pl_tasks=$(jq -r '.totals.tasks' "$PLJ")
grep -q "Home: $pl_home" "$PLM" || fail "forced-interleave: latest pair disagree on home (json=$pl_home)"
grep -q "Total tasks: $pl_tasks " "$PLM" || fail "forced-interleave: latest pair disagree on totals (json=$pl_tasks)"
while IFS= read -r m; do
  grep -q "| $m |" "$PLM" || fail "forced-interleave: latest.md missing model row $m present in latest.json"
done < <(jq -r '.panels.model_mix.by_harness_model_effort[].model' "$PLJ")
# And both immutable archives must still be intact and correct.
[ "$(find "$POUT/history" -name 'usage-*.json' | wc -l)" = 2 ] || fail "forced-interleave: expected 2 archives"
pass "forced publication interleaving keeps latest.json/latest.md a coherent pair"

# --- 16. publication failures fail loud and nonzero (QA round 4, finding 1) ---
# The round-4 publish ran the renames inside `if ! ( ... ) 9>lock`, where set -e
# is suppressed and a failed compound-redirect fd-open is skipped, so a lock that
# could not be opened AND a failed first rename both returned exit 0 with a
# success summary and an index entry - a masked half-published pair. These two
# probes force each failure and assert: nonzero exit, a diagnostic on stderr, no
# success summary on stdout, no index line, and no published latest.json.
fail_meta() {  # <home>
  mkdir -p "$1/state"
  fm_write_meta "$1/state/t.meta" \
    project=/home/prode/fleet/firstmate harness=claude kind=ship \
    model=fail-probe effort=high spawned_at=2026-07-15T10:00:00Z
}

# 16a. Lock descriptor cannot be opened (the lock path is a directory).
FLH=$TMP_ROOT/fail-lockopen
fail_meta "$FLH"
FLO=$FLH/out
mkdir -p "$FLO/history"
mkdir -p "$FLO/.latest.lock"   # a directory where the lock file must be opened
FLO_OUT=$FLH/stdout; FLO_ERR=$FLH/stderr
FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" --target "$FLH" --out "$FLO" \
  --since 2026-07-01 --until 2026-07-18 >"$FLO_OUT" 2>"$FLO_ERR"
flo_rc=$?
[ "$flo_rc" -ne 0 ] || fail "lock-open failure must exit nonzero, got $flo_rc"
grep -q "cannot open publication lock" "$FLO_ERR" || fail "lock-open failure must print a diagnostic to stderr"
assert_absent "$FLO/latest.json" "lock-open failure must not publish latest.json"
assert_no_grep "usage report:" "$FLO_OUT" "lock-open failure must not print a success summary"
[ ! -f "$FLO/index.jsonl" ] || [ "$(wc -l < "$FLO/index.jsonl")" = 0 ] || fail "lock-open failure must not append an index line"
pass "unopenable publication lock fails loud and nonzero, no false success"

# 16b. The first final rename (latest.json) fails.
FRH=$TMP_ROOT/fail-rename
fail_meta "$FRH"
FRO=$FRH/out
mkdir -p "$FRO/history"
FRB=$(fm_fakebin "$FRH")
FR_REAL_MV="$(command -v mv)"
# mv shim: fail only the latest.json publish rename; pass everything else through
# (archive renames and the latest.md rename) so the failure is isolated to the
# first of the two final renames.
cat > "$FRB/mv" <<'SH'
#!/usr/bin/env bash
real="${REAL_MV:-/bin/mv}"
case "${*: -1}" in
  */latest.json) echo "injected latest.json rename failure" >&2; exit 74 ;;
esac
exec "$real" "$@"
SH
chmod +x "$FRB/mv"
FRO_OUT=$FRH/stdout; FRO_ERR=$FRH/stderr
PATH="$FRB:$PATH" REAL_MV="$FR_REAL_MV" FM_USAGE_NOW=2026-07-18T00:00:00Z \
  "$USAGE" --target "$FRH" --out "$FRO" --since 2026-07-01 --until 2026-07-18 \
  >"$FRO_OUT" 2>"$FRO_ERR"
fr_rc=$?
[ "$fr_rc" -ne 0 ] || fail "first-rename failure must exit nonzero, got $fr_rc"
grep -q "failed to publish latest.json" "$FRO_ERR" || fail "first-rename failure must print a diagnostic to stderr"
assert_absent "$FRO/latest.json" "first-rename failure must not leave a published latest.json"
assert_absent "$FRO/latest.md" "first-rename failure must not publish latest.md after the json rename failed"
assert_no_grep "usage report:" "$FRO_OUT" "first-rename failure must not print a success summary"
[ ! -f "$FRO/index.jsonl" ] || [ "$(wc -l < "$FRO/index.jsonl")" = 0 ] || fail "first-rename failure must not append an index line"
pass "a failed first rename fails loud and nonzero, no half-published pair"

# --- 17. a failed fingerprint hash fails loud, not empty (QA round 5, f1) -----
# The fingerprint was computed as `printf ... | sha256sum | cut`. Under a bare
# set -eu (no pipefail) a sha256sum failure was masked by cut's success, so the
# assignment took cut's exit 0 and FINGERPRINT became empty; the run then
# published and indexed the report with an empty fingerprint and printed success.
# With pipefail plus the explicit guard, a hash failure must abort before the
# archive rename, the index append, or the success summary.
FHH=$TMP_ROOT/fail-hash
mkdir -p "$FHH/state"
fm_write_meta "$FHH/state/t.meta" \
  project=/home/prode/fleet/firstmate harness=claude kind=ship \
  model=hash-probe effort=high spawned_at=2026-07-15T10:00:00Z
FHO=$FHH/out
mkdir -p "$FHO/history"
FHB=$(fm_fakebin "$FHH")
cat > "$FHB/sha256sum" <<'SH'
#!/usr/bin/env bash
echo "injected sha256sum failure" >&2
exit 76
SH
chmod +x "$FHB/sha256sum"
FHO_OUT=$FHH/stdout; FHO_ERR=$FHH/stderr
PATH="$FHB:$PATH" FM_USAGE_NOW=2026-07-18T00:00:00Z \
  "$USAGE" --target "$FHH" --out "$FHO" --since 2026-07-01 --until 2026-07-18 \
  >"$FHO_OUT" 2>"$FHO_ERR"
fh_rc=$?
[ "$fh_rc" -ne 0 ] || fail "sha256sum failure must exit nonzero, got $fh_rc"
grep -q "failed to compute report fingerprint" "$FHO_ERR" || fail "sha256sum failure must print a diagnostic to stderr"
assert_no_grep "usage report:" "$FHO_OUT" "sha256sum failure must not print a success summary"
assert_absent "$FHO/latest.json" "sha256sum failure must not publish latest.json"
[ ! -f "$FHO/index.jsonl" ] || [ "$(wc -l < "$FHO/index.jsonl")" = 0 ] || fail "sha256sum failure must not append an index line"
# And no index entry may ever carry an empty fingerprint.
if [ -f "$FHO/index.jsonl" ]; then
  ! grep -q '"fingerprint":""' "$FHO/index.jsonl" || fail "an empty fingerprint must never reach the index"
fi
pass "a failed fingerprint hash fails loud and nonzero, never an empty fingerprint"

# --- 18. ledger jq and date failures fail loud, not reduced/undated ----------
# Round 6 found that the two task-runs.jsonl jq extractions used `|| true`
# inside command substitutions, so an operational jq failure became an empty
# task/row and the valid closed-task row was silently dropped. A broken date
# invocation likewise became an empty timestamp, which let an out-of-window
# task enter the report as undated. Each probe below injects one operational
# failure and asserts the run stops before latest/index/success publication.

# 18a. The task-id extraction jq fails.
JTH=$TMP_ROOT/fail-jq-task
mkdir -p "$JTH/state"
append_run "$JTH/state/task-runs.jsonl" jqtask ship /home/prode/fleet/firstmate claude model-jq-task high 2026-07-15T10:00:00Z
JTO=$JTH/out
JTB=$(fm_fakebin "$JTH")
JT_REAL_JQ="$(command -v jq)"
cat > "$JTB/jq" <<'SH'
#!/usr/bin/env bash
real="${REAL_JQ:-/usr/bin/jq}"
for arg in "$@"; do
  case "$arg" in
    *'.task // empty'*) echo "injected task jq failure" >&2; exit 72 ;;
  esac
done
exec "$real" "$@"
SH
chmod +x "$JTB/jq"
JTO_OUT=$JTH/stdout; JTO_ERR=$JTH/stderr
PATH="$JTB:$PATH" REAL_JQ="$JT_REAL_JQ" FM_USAGE_NOW=2026-07-18T00:00:00Z \
  "$USAGE" --target "$JTH" --out "$JTO" --since 2026-07-01 --until 2026-07-18 \
  >"$JTO_OUT" 2>"$JTO_ERR"
jt_rc=$?
[ "$jt_rc" -ne 0 ] || fail "ledger task jq failure must exit nonzero, got $jt_rc"
grep -q "failed to parse task-runs.jsonl task field with jq" "$JTO_ERR" || fail "ledger task jq failure must print a diagnostic to stderr"
grep -q "injected task jq failure" "$JTO_ERR" || fail "ledger task jq failure must preserve jq stderr"
assert_no_grep "usage report:" "$JTO_OUT" "ledger task jq failure must not print a success summary"
assert_absent "$JTO/latest.json" "ledger task jq failure must not publish latest.json"
[ ! -f "$JTO/index.jsonl" ] || [ "$(wc -l < "$JTO/index.jsonl")" = 0 ] || fail "ledger task jq failure must not append an index line"
pass "a failed ledger task jq extraction fails loud and nonzero"

# 18b. The full-row extraction jq fails after task-id extraction succeeded.
JRH=$TMP_ROOT/fail-jq-row
mkdir -p "$JRH/state"
append_run "$JRH/state/task-runs.jsonl" jqrow ship /home/prode/fleet/firstmate claude model-jq-row high 2026-07-15T10:00:00Z
JRO=$JRH/out
JRB=$(fm_fakebin "$JRH")
JR_REAL_JQ="$(command -v jq)"
cat > "$JRB/jq" <<'SH'
#!/usr/bin/env bash
real="${REAL_JQ:-/usr/bin/jq}"
for arg in "$@"; do
  case "$arg" in
    *'(.harness // "")'*) echo "injected row jq failure" >&2; exit 71 ;;
  esac
done
exec "$real" "$@"
SH
chmod +x "$JRB/jq"
JRO_OUT=$JRH/stdout; JRO_ERR=$JRH/stderr
PATH="$JRB:$PATH" REAL_JQ="$JR_REAL_JQ" FM_USAGE_NOW=2026-07-18T00:00:00Z \
  "$USAGE" --target "$JRH" --out "$JRO" --since 2026-07-01 --until 2026-07-18 \
  >"$JRO_OUT" 2>"$JRO_ERR"
jr_rc=$?
[ "$jr_rc" -ne 0 ] || fail "ledger row jq failure must exit nonzero, got $jr_rc"
grep -q "failed to parse task-runs.jsonl row fields with jq" "$JRO_ERR" || fail "ledger row jq failure must print a diagnostic to stderr"
grep -q "injected row jq failure" "$JRO_ERR" || fail "ledger row jq failure must preserve jq stderr"
assert_no_grep "usage report:" "$JRO_OUT" "ledger row jq failure must not print a success summary"
assert_absent "$JRO/latest.json" "ledger row jq failure must not publish latest.json"
[ ! -f "$JRO/index.jsonl" ] || [ "$(wc -l < "$JRO/index.jsonl")" = 0 ] || fail "ledger row jq failure must not append an index line"
pass "a failed ledger row jq extraction fails loud and nonzero"

# A malformed ledger row is data tolerance, not an operational jq failure.
MLH=$TMP_ROOT/malformed-ledger
mkdir -p "$MLH/state"
append_run "$MLH/state/task-runs.jsonl" goodrow ship /home/prode/fleet/firstmate claude model-good high 2026-07-15T10:00:00Z
printf '{bad json\n' >> "$MLH/state/task-runs.jsonl"
FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" --target "$MLH" --since 2026-07-01 --until 2026-07-18 >/dev/null \
  || fail "malformed ledger row should be skipped, not fatal"
[ "$(jq -r '.totals.tasks' "$MLH/$OUT_SUB/latest.json")" = 1 ] || fail "malformed ledger row must not drop the valid row"
pass "malformed ledger rows remain tolerated"

# 18c. A valid out-of-window timestamp hits an operational date failure.
DFH=$TMP_ROOT/fail-date
mkdir -p "$DFH/state"
fm_write_meta "$DFH/state/dateprobe.meta" \
  project=/home/prode/fleet/firstmate harness=claude kind=ship \
  model=date-probe effort=high spawned_at=2026-06-01T10:00:00Z
DFO=$DFH/out
DFB=$(fm_fakebin "$DFH")
DF_REAL_DATE="$(command -v date)"
cat > "$DFB/date" <<'SH'
#!/usr/bin/env bash
real="${REAL_DATE:-/bin/date}"
for arg in "$@"; do
  case "$arg" in
    2026-06-01T10:00:00Z) echo "injected date failure" >&2; exit 73 ;;
  esac
done
exec "$real" "$@"
SH
chmod +x "$DFB/date"
DFO_OUT=$DFH/stdout; DFO_ERR=$DFH/stderr
PATH="$DFB:$PATH" REAL_DATE="$DF_REAL_DATE" FM_USAGE_NOW=2026-07-18T00:00:00Z \
  "$USAGE" --target "$DFH" --out "$DFO" --since 2026-07-01 --until 2026-07-18 \
  >"$DFO_OUT" 2>"$DFO_ERR"
df_rc=$?
[ "$df_rc" -ne 0 ] || fail "date failure must exit nonzero, got $df_rc"
grep -q "failed to convert timestamp with date" "$DFO_ERR" || fail "date failure must print a diagnostic to stderr"
grep -q "injected date failure" "$DFO_ERR" || fail "date failure must preserve date stderr"
assert_no_grep "usage report:" "$DFO_OUT" "date failure must not print a success summary"
assert_absent "$DFO/latest.json" "date failure must not publish latest.json"
[ ! -f "$DFO/index.jsonl" ] || [ "$(wc -l < "$DFO/index.jsonl")" = 0 ] || fail "date failure must not append an index line"
pass "a failed timestamp conversion fails loud and nonzero"

# 18d. A helper capture reset failure must be fatal even inside a tolerant
# ledger parse. The old helper relied on errexit while being called in an `if`
# condition, so a stale allowed parse diagnostic could be reused.
CRH=$TMP_ROOT/fail-capture-reset
mkdir -p "$CRH/state" "$CRH/tmp"
printf '{bad json\n' > "$CRH/state/task-runs.jsonl"
cr_i=0
while [ "$cr_i" -lt 20 ]; do
  append_run "$CRH/state/task-runs.jsonl" "capture-$cr_i" ship /home/prode/fleet/firstmate claude model-capture high 2026-07-15T10:00:00Z
  cr_i=$((cr_i + 1))
done
CRO=$CRH/out
CRB=$(fm_fakebin "$CRH")
CR_REAL_JQ="$(command -v jq)"
CR_REAL_GREP="$(command -v grep)"
cat > "$CRB/jq" <<'SH'
#!/usr/bin/env bash
real="${REAL_JQ:-/usr/bin/jq}"
input="$(cat)"
printf '%s\n' "$input" | "$real" "$@"
SH
cat > "$CRB/grep" <<'SH'
#!/usr/bin/env bash
real="${REAL_GREP:-/bin/grep}"
"$real" "$@"
rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$CAPTURE_RESET_DONE" ]; then
  last=
  for arg in "$@"; do
    last=$arg
  done
  case "$last" in
    */fm-usage-run-err.*)
      : > "$CAPTURE_RESET_DONE"
      chmod 400 "$last" 2>/dev/null || true
      ( sleep 0.2; chmod 600 "$last" 2>/dev/null || true ) >/dev/null 2>&1 &
      ;;
  esac
fi
exit "$rc"
SH
chmod +x "$CRB/jq" "$CRB/grep"
CRO_OUT=$CRH/stdout; CRO_ERR=$CRH/stderr
PATH="$CRB:$PATH" REAL_JQ="$CR_REAL_JQ" REAL_GREP="$CR_REAL_GREP" TMPDIR="$CRH/tmp" \
  CAPTURE_RESET_DONE="$CRH/reset-done" FM_USAGE_NOW=2026-07-18T00:00:00Z \
  "$USAGE" --target "$CRH" --out "$CRO" --since 2026-07-01 --until 2026-07-18 \
  >"$CRO_OUT" 2>"$CRO_ERR"
cr_rc=$?
[ "$cr_rc" -ne 0 ] || fail "capture reset failure must exit nonzero, got $cr_rc"
grep -q "failed to reset command diagnostic capture" "$CRO_ERR" || fail "capture reset failure must print a helper diagnostic"
assert_no_grep "usage report:" "$CRO_OUT" "capture reset failure must not print a success summary"
assert_absent "$CRO/latest.json" "capture reset failure must not publish latest.json"
[ ! -f "$CRO/index.jsonl" ] || [ "$(wc -l < "$CRO/index.jsonl")" = 0 ] || fail "capture reset failure must not append an index line"
pass "a failed helper capture reset fails loud and nonzero"

# 18e. The omitted --since default date computation fails after writing plausible
# output. The old nested substitution let norm_since hide that nonzero status and
# publish a report under the wrong window.
DSH=$TMP_ROOT/fail-default-since
mkdir -p "$DSH/state"
fm_write_meta "$DSH/state/defaultsince.meta" \
  project=/home/prode/fleet/firstmate harness=claude kind=ship \
  model=default-since-probe effort=high spawned_at=2026-07-15T10:00:00Z
DSO=$DSH/out
DSB=$(fm_fakebin "$DSH")
DS_REAL_DATE="$(command -v date)"
cat > "$DSB/date" <<'SH'
#!/usr/bin/env bash
real="${REAL_DATE:-/bin/date}"
for arg in "$@"; do
  case "$arg" in
    "2026-07-18T00:00:00Z - 7 days")
      printf '%s\n' "2020-01-01T00:00:00Z"
      echo "injected default-since date failure" >&2
      exit 77
      ;;
  esac
done
exec "$real" "$@"
SH
chmod +x "$DSB/date"
DSO_OUT=$DSH/stdout; DSO_ERR=$DSH/stderr
PATH="$DSB:$PATH" REAL_DATE="$DS_REAL_DATE" FM_USAGE_NOW=2026-07-18T00:00:00Z \
  "$USAGE" --target "$DSH" --out "$DSO" --until 2026-07-18 \
  >"$DSO_OUT" 2>"$DSO_ERR"
ds_rc=$?
[ "$ds_rc" -ne 0 ] || fail "default-since date failure must exit nonzero, got $ds_rc"
grep -q "failed to compute default --since with date" "$DSO_ERR" || fail "default-since date failure must print a diagnostic to stderr"
grep -q "(exit 77)" "$DSO_ERR" || fail "default-since date failure must report the real tool exit code"
grep -q "injected default-since date failure" "$DSO_ERR" || fail "default-since date failure must preserve date stderr"
assert_no_grep "usage report:" "$DSO_OUT" "default-since date failure must not print a success summary"
assert_absent "$DSO/latest.json" "default-since date failure must not publish latest.json"
[ ! -f "$DSO/index.jsonl" ] || [ "$(wc -l < "$DSO/index.jsonl")" = 0 ] || fail "default-since date failure must not append an index line"
pass "a failed default-since date computation fails loud and nonzero"


# ============================================================================
# Slice M2 - Claude token joiner (round 2, redesigned after independent QA
# data/qa-m2-q34/report.md found round 1 could publish confidently-wrong
# numbers). Every block below is keyed to the QA finding it regresses.
# ============================================================================

# --- 19. happy path: single uniquely-claimed session, correct sums, high ----
HP=$(make_home claude-happy)
CP19="$HP/claude-projects"
append_run "$HP/state/task-runs.jsonl" happy1 ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
ENC19=$(encode_worktree /wt/happy1)
mkdir -p "$CP19/$ENC19"
{
  claude_event 2026-07-15T12:15:00Z 100 50 10 5
  claude_event 2026-07-15T13:45:00Z 200 80 20 8
} > "$CP19/$ENC19/sessA.jsonl"
FM_CLAUDE_PROJECTS_OVERRIDE="$CP19" FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
  --target "$HP" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "happy-path run exited non-zero"
HPJ=$HP/$OUT_SUB/latest.json
row_of() { jq -r --arg t "$2" --arg f "$3" '.panels.tokens.by_task[] | select(.task==$t) | .[$f]' "$1"; }
[ "$(row_of "$HPJ" happy1 tokens_status)" = ok ] || fail "happy-path status"
[ "$(row_of "$HPJ" happy1 confidence)" = high ] || fail "happy-path confidence"
EXPECT_HP='{"task":"happy1","harness":"claude","model":"claude-opus-4-8","join_method":"claude_project_dir","tokens_status":"ok","confidence":"high","input_tokens":300,"output_tokens":130,"cache_read_tokens":30,"cache_write_tokens":13,"reasoning_tokens":null,"total_tokens":473,"sessions_matched":1,"sessions_problem":0,"ambiguous_sessions_excluded":0,"model_source":"routing"}'
GOT_HP=$(jq -cS '.panels.tokens.by_task[] | select(.task=="happy1")' "$HPJ")
[ "$GOT_HP" = "$(jq -cS . <<< "$EXPECT_HP")" ] || fail "happy-path row: got $GOT_HP want $EXPECT_HP"
pass "claude happy path: unique claim yields tokens_status=ok, confidence=high"

# --- 20. session-file-level exclusion (worktree pool-reuse hazard, single task)
RH=$(make_home claude-reuse)
CP20="$RH/claude-projects"
append_run "$RH/state/task-runs.jsonl" reuse1 ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
ENC20=$(encode_worktree /wt/reuse1)
mkdir -p "$CP20/$ENC20"
claude_event 2026-07-15T12:30:00Z 10 10 0 0 > "$CP20/$ENC20/sessIn.jsonl"
claude_event 2026-07-20T00:00:00Z 999 999 999 999 > "$CP20/$ENC20/sessOut.jsonl"
FM_CLAUDE_PROJECTS_OVERRIDE="$CP20" FM_USAGE_NOW=2026-07-25T00:00:00Z "$USAGE" \
  --target "$RH" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "reuse-hazard run exited non-zero"
RJ=$RH/$OUT_SUB/latest.json
[ "$(row_of "$RJ" reuse1 sessions_matched)" = 1 ] || fail "reuse: only one session should match"
[ "$(row_of "$RJ" reuse1 total_tokens)" = 20 ] || fail "reuse: unrelated out-of-window session must not be summed"
pass "an unrelated out-of-window session in the same directory is excluded wholesale"

# --- 21. inclusive lower/upper join-window boundaries (default grace=2h) ---
BH=$(make_home claude-bounds)
CP21="$BH/claude-projects"
append_run "$BH/state/task-runs.jsonl" bound1 ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
ENC21=$(encode_worktree /wt/bound1)
mkdir -p "$CP21/$ENC21"
claude_event 2026-07-15T12:00:00Z 1 0 0 0 > "$CP21/$ENC21/lo_in.jsonl"
claude_event 2026-07-15T11:59:59Z 1000 0 0 0 > "$CP21/$ENC21/lo_out.jsonl"
claude_event 2026-07-15T14:00:00Z 0 1 0 0 > "$CP21/$ENC21/hi_in.jsonl"
claude_event 2026-07-15T14:00:01Z 0 1000 0 0 > "$CP21/$ENC21/hi_out.jsonl"
FM_CLAUDE_PROJECTS_OVERRIDE="$CP21" FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
  --target "$BH" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "boundary run exited non-zero"
BJ=$BH/$OUT_SUB/latest.json
[ "$(row_of "$BJ" bound1 sessions_matched)" = 2 ] || fail "boundary: expected exactly the two inclusive-boundary sessions"
[ "$(row_of "$BJ" bound1 input_tokens)" = 1 ] || fail "boundary: input tokens (lo_in only)"
[ "$(row_of "$BJ" bound1 output_tokens)" = 1 ] || fail "boundary: output tokens (hi_in only)"
pass "join window is inclusive on both ends, one second outside excludes"

# --- 22. grace-hours configurability -----------------------------------------
GH=$(make_home claude-grace)
CP22="$GH/claude-projects"
append_run "$GH/state/task-runs.jsonl" grace1 ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
ENC22=$(encode_worktree /wt/grace1)
mkdir -p "$CP22/$ENC22"
claude_event 2026-07-15T12:00:00Z 5 0 0 0 > "$CP22/$ENC22/atstart.jsonl"
claude_event 2026-07-15T13:00:00Z 500 0 0 0 > "$CP22/$ENC22/plus1h.jsonl"
FM_CLAUDE_PROJECTS_OVERRIDE="$CP22" FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
  --target "$GH" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "default-grace run exited non-zero"
GJ=$GH/$OUT_SUB/latest.json
[ "$(row_of "$GJ" grace1 sessions_matched)" = 2 ] || fail "default grace (2h) should include the +1h session"
[ "$(row_of "$GJ" grace1 input_tokens)" = 505 ] || fail "default grace (2h) token sum"
GH0=$(make_home claude-grace0)
CP220="$GH0/claude-projects"
append_run "$GH0/state/task-runs.jsonl" grace1 ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
mkdir -p "$CP220/$ENC22"
claude_event 2026-07-15T12:00:00Z 5 0 0 0 > "$CP220/$ENC22/atstart.jsonl"
claude_event 2026-07-15T13:00:00Z 500 0 0 0 > "$CP220/$ENC22/plus1h.jsonl"
FM_CLAUDE_PROJECTS_OVERRIDE="$CP220" FM_USAGE_CLAUDE_GRACE_HOURS=0 FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
  --target "$GH0" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "zero-grace run exited non-zero"
GJ0=$GH0/$OUT_SUB/latest.json
[ "$(row_of "$GJ0" grace1 sessions_matched)" = 1 ] || fail "zero grace should exclude the +1h session"
[ "$(row_of "$GJ0" grace1 input_tokens)" = 5 ] || fail "zero grace token sum"
pass "FM_USAGE_CLAUDE_GRACE_HOURS changes which sessions are within the join window"

# --- 23. invalid FM_USAGE_CLAUDE_GRACE_HOURS exits nonzero -------------------
IGH=$(make_home claude-badgrace)
IGO=$IGH/out; IGO_ERR=$IGH/stderr
FM_USAGE_CLAUDE_GRACE_HOURS=notanumber FM_USAGE_NOW=2026-07-18T00:00:00Z \
  "$USAGE" --target "$IGH" --out "$IGO" --since 2026-07-01 --until 2026-07-18 \
  >/dev/null 2>"$IGO_ERR"
igh_rc=$?
[ "$igh_rc" -eq 2 ] || fail "invalid grace hours must exit 2, got $igh_rc"
grep -q "FM_USAGE_CLAUDE_GRACE_HOURS must be a non-negative integer" "$IGO_ERR" \
  || fail "invalid grace hours must print a diagnostic"
assert_absent "$IGO/latest.json" "invalid grace hours must not publish a report"
pass "a non-numeric FM_USAGE_CLAUDE_GRACE_HOURS is a usage error"

# --- 24. undated claude task: ambiguous_join sums every session unfiltered --
UDH=$(make_home claude-undated)
CP24="$UDH/claude-projects"
fm_write_meta "$UDH/state/undated1.meta" \
  project=/home/prode/fleet/firstmate harness=claude kind=ship \
  model=claude-opus-4-8 effort=high worktree=/wt/undated1
ENC24=$(encode_worktree /wt/undated1)
mkdir -p "$CP24/$ENC24"
claude_event 2020-01-01T00:00:00Z 10 0 0 0 > "$CP24/$ENC24/old.jsonl"
claude_event 2030-01-01T00:00:00Z 20 0 0 0 > "$CP24/$ENC24/future.jsonl"
FM_CLAUDE_PROJECTS_OVERRIDE="$CP24" FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
  --target "$UDH" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "undated claude run exited non-zero"
UDJ=$UDH/$OUT_SUB/latest.json
[ "$(row_of "$UDJ" undated1 tokens_status)" = ambiguous_join ] || fail "undated claude task must be ambiguous_join"
[ "$(row_of "$UDJ" undated1 confidence)" = low ] || fail "ambiguous_join confidence must be low"
[ "$(row_of "$UDJ" undated1 sessions_matched)" = 2 ] || fail "undated claude task must sum every session unfiltered"
[ "$(row_of "$UDJ" undated1 input_tokens)" = 30 ] || fail "undated claude token sum"
[ "$(row_of "$UDJ" undated1 ambiguous_sessions_excluded)" = 0 ] || fail "undated task alone shares nothing, no exclusion expected"
pass "an undated claude task falls back to ambiguous_join over every top-level session"

# --- 25/26/27. absent cases: no worktree, missing dir, empty dir -----------
AH=$(make_home claude-absent)
CP25="$AH/claude-projects"
fm_write_meta "$AH/state/noworktree.meta" \
  project=/home/prode/fleet/firstmate harness=claude kind=ship \
  model=claude-opus-4-8 effort=high spawned_at=2026-07-15T10:00:00Z
fm_write_meta "$AH/state/nodir.meta" \
  project=/home/prode/fleet/firstmate harness=claude kind=ship \
  model=claude-opus-4-8 effort=high spawned_at=2026-07-15T10:00:00Z worktree=/wt/nodir1
fm_write_meta "$AH/state/emptydir.meta" \
  project=/home/prode/fleet/firstmate harness=claude kind=ship \
  model=claude-opus-4-8 effort=high spawned_at=2026-07-15T10:00:00Z worktree=/wt/emptydir1
mkdir -p "$CP25/$(encode_worktree /wt/emptydir1)"
FM_CLAUDE_PROJECTS_OVERRIDE="$CP25" FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
  --target "$AH" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "absent-cases run exited non-zero"
AJ=$AH/$OUT_SUB/latest.json
[ "$(row_of "$AJ" noworktree tokens_status)" = absent ] || fail "no-worktree claude task must be absent"
[ "$(row_of "$AJ" noworktree join_method)" = none ] || fail "no-worktree join_method must be none"
[ "$(row_of "$AJ" nodir tokens_status)" = absent ] || fail "missing-directory claude task must be absent"
[ "$(row_of "$AJ" nodir join_method)" = claude_project_dir ] || fail "missing-directory join_method is still claude_project_dir (attempted)"
[ "$(row_of "$AJ" emptydir tokens_status)" = absent ] || fail "empty-directory claude task must be absent"
[ "$(row_of "$AJ" noworktree sessions_matched)" = 0 ] || fail "no-worktree sessions_matched must be 0"
[ "$(row_of "$AJ" nodir sessions_matched)" = 0 ] || fail "missing-directory sessions_matched must be 0"
[ "$(row_of "$AJ" emptydir sessions_matched)" = 0 ] || fail "empty-directory sessions_matched must be 0"
[ "$(row_of "$AJ" noworktree sessions_problem)" = 0 ] || fail "no-worktree sessions_problem must be 0 (absent is not the same as a data problem)"
[ "$(jq -rc '[.panels.tokens.by_task[] | select(.task=="noworktree" or .task=="nodir" or .task=="emptydir") | .confidence] | unique' "$AJ")" = '["none"]' ] \
  || fail "all three absent rows must carry confidence=none"
pass "no worktree, a missing session directory, and an empty session directory are all absent, not errors"

# --- 28. subagents/ subdirectory is excluded from the sum -------------------
SAH=$(make_home claude-subagents)
CP28="$SAH/claude-projects"
append_run "$SAH/state/task-runs.jsonl" subtask1 ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
ENC28=$(encode_worktree /wt/subtask1)
mkdir -p "$CP28/$ENC28/sess-uuid-1/subagents"
claude_event 2026-07-15T12:30:00Z 7 0 0 0 > "$CP28/$ENC28/sessM.jsonl"
claude_event 2026-07-15T12:30:00Z 9999 0 0 0 > "$CP28/$ENC28/sess-uuid-1/subagents/agent-x.jsonl"
FM_CLAUDE_PROJECTS_OVERRIDE="$CP28" FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
  --target "$SAH" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "subagents run exited non-zero"
SAJ=$SAH/$OUT_SUB/latest.json
[ "$(row_of "$SAJ" subtask1 input_tokens)" = 7 ] || fail "subagents/ transcript must not be summed into the parent task"
[ "$(row_of "$SAJ" subtask1 sessions_matched)" = 1 ] || fail "only the top-level session file should be counted"
pass "a session's own subagents/ subtree is excluded from the sum"

# --- 29. missing usage subfields default to 0 (legitimate: no cache activity)
MFH=$(make_home claude-missingfields)
CP29="$MFH/claude-projects"
append_run "$MFH/state/task-runs.jsonl" missing1 ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
ENC29=$(encode_worktree /wt/missing1)
mkdir -p "$CP29/$ENC29"
jq -nc --arg ts 2026-07-15T12:30:00Z \
  '{type:"assistant", timestamp:$ts, message:{model:"claude-opus-4-8", usage:{input_tokens:3, output_tokens:4}}}' \
  > "$CP29/$ENC29/sparse.jsonl"
FM_CLAUDE_PROJECTS_OVERRIDE="$CP29" FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
  --target "$MFH" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "missing-fields run exited non-zero"
MFJ=$MFH/$OUT_SUB/latest.json
[ "$(row_of "$MFJ" missing1 tokens_status)" = ok ] || fail "a legitimately cache-less event must still join as ok"
[ "$(jq -c '.panels.tokens.by_task[] | select(.task=="missing1") | [.input_tokens,.output_tokens,.cache_read_tokens,.cache_write_tokens,.total_tokens]' "$MFJ")" = '[3,4,0,0,7]' ] \
  || fail "missing cache fields must default to 0, not error"
pass "a usage block missing ONLY cache fields defaults them to 0 and still joins ok (not a schema problem)"

# --- 30 (QA F1). a session with NO usage object at all is a SCHEMA problem: the
# task must be downgraded to partial, never silently ok/high on a reduced sum.
NUH=$(make_home claude-nousage)
CPNU="$NUH/claude-projects"
append_run "$NUH/state/task-runs.jsonl" nousage1 ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
ENCNU=$(encode_worktree /wt/nousage1)
mkdir -p "$CPNU/$ENCNU"
jq -nc --arg ts 2026-07-15T12:30:00Z '{type:"assistant", timestamp:$ts, message:{model:"claude-opus-4-8"}}' \
  > "$CPNU/$ENCNU/nousage.jsonl"
FM_CLAUDE_PROJECTS_OVERRIDE="$CPNU" FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
  --target "$NUH" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "no-usage-object run exited non-zero"
NUJ=$NUH/$OUT_SUB/latest.json
[ "$(row_of "$NUJ" nousage1 tokens_status)" = partial ] || fail "QA F1: an assistant event with no usage object must never be reported ok"
[ "$(row_of "$NUJ" nousage1 confidence)" = low ] || fail "QA F1: partial status must carry confidence=low, never high"
[ "$(row_of "$NUJ" nousage1 sessions_problem)" = 1 ] || fail "QA F1: the schema-invalid session must be counted as a problem"
[ "$(row_of "$NUJ" nousage1 total_tokens)" = 0 ] || fail "QA F1: an all-invalid session yields a zero floor, not a fabricated total"
pass "QA F1: an assistant event missing its usage object makes the task partial/low, never ok/high"

# --- 31 (QA F1/F4). numeric field validation: negative, huge (overflow),
# fractional, and string values are all schema-invalid, and their WHOLE
# session downgrades the task to partial - never a garbage or negative total.
NVH=$(make_home claude-numvalid)
CPNV="$NVH/claude-projects"
append_run "$NVH/state/task-runs.jsonl" negtask ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
append_run "$NVH/state/task-runs.jsonl" hugetask ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
append_run "$NVH/state/task-runs.jsonl" fractask ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
append_run "$NVH/state/task-runs.jsonl" strtask ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
mkdir -p "$CPNV/$(encode_worktree /wt/negtask)" "$CPNV/$(encode_worktree /wt/hugetask)" \
  "$CPNV/$(encode_worktree /wt/fractask)" "$CPNV/$(encode_worktree /wt/strtask)"
jq -nc --arg ts 2026-07-15T12:30:00Z '{type:"assistant", timestamp:$ts, message:{model:"claude-opus-4-8", usage:{input_tokens:-5, output_tokens:10}}}' \
  > "$CPNV/$(encode_worktree /wt/negtask)/s.jsonl"
jq -nc --arg ts 2026-07-15T12:30:00Z '{type:"assistant", timestamp:$ts, message:{model:"claude-opus-4-8", usage:{input_tokens:10000000000000000000, output_tokens:10}}}' \
  > "$CPNV/$(encode_worktree /wt/hugetask)/s.jsonl"
jq -nc --arg ts 2026-07-15T12:30:00Z '{type:"assistant", timestamp:$ts, message:{model:"claude-opus-4-8", usage:{input_tokens:3.5, output_tokens:10}}}' \
  > "$CPNV/$(encode_worktree /wt/fractask)/s.jsonl"
jq -nc --arg ts 2026-07-15T12:30:00Z '{type:"assistant", timestamp:$ts, message:{model:"claude-opus-4-8", usage:{input_tokens:"5", output_tokens:10}}}' \
  > "$CPNV/$(encode_worktree /wt/strtask)/s.jsonl"
FM_CLAUDE_PROJECTS_OVERRIDE="$CPNV" FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
  --target "$NVH" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "numeric-validation run exited non-zero"
NVJ=$NVH/$OUT_SUB/latest.json
for t in negtask hugetask fractask strtask; do
  [ "$(row_of "$NVJ" "$t" tokens_status)" = partial ] || fail "QA F4: $t with an invalid numeric field must be partial, got $(row_of "$NVJ" "$t" tokens_status)"
  tt=$(row_of "$NVJ" "$t" total_tokens)
  [ "$tt" = 0 ] || fail "QA F4: $t must never publish a fabricated/negative total, got $tt"
  case "$tt" in -*) fail "QA F4: $t total_tokens must never be negative (bash arithmetic overflow), got $tt" ;; esac
done
pass "QA F4: negative, overflowing, fractional, and string numeric fields are rejected, never summed"

# --- 32 (QA F1). a malformed (truncated) session file is data tolerance, but
# now correctly downgrades the task to partial - the valid sibling's tokens
# are still shown as an honest floor, not silently promoted to ok/high.
MDH=$(make_home claude-malformed)
CP30="$MDH/claude-projects"
append_run "$MDH/state/task-runs.jsonl" malf1 ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
ENC30=$(encode_worktree /wt/malf1)
mkdir -p "$CP30/$ENC30"
claude_event 2026-07-15T12:30:00Z 5 5 0 0 > "$CP30/$ENC30/good.jsonl"
printf '{not valid json\n' > "$CP30/$ENC30/bad.jsonl"
FM_CLAUDE_PROJECTS_OVERRIDE="$CP30" FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
  --target "$MDH" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "malformed-session run must still exit zero (tolerated data issue)"
MDJ=$MDH/$OUT_SUB/latest.json
[ "$(row_of "$MDJ" malf1 tokens_status)" = partial ] || fail "QA F1: a malformed sibling must downgrade the task to partial, not leave it ok"
[ "$(row_of "$MDJ" malf1 confidence)" = low ] || fail "QA F1: partial confidence must be low"
[ "$(row_of "$MDJ" malf1 sessions_matched)" = 1 ] || fail "the valid sibling must still be counted toward the floor"
[ "$(row_of "$MDJ" malf1 sessions_problem)" = 1 ] || fail "the malformed file must be counted as a problem"
[ "$(row_of "$MDJ" malf1 input_tokens)" = 5 ] || fail "the valid sibling's tokens are still an honest floor"
pass "QA F1: a malformed session file downgrades the task to partial; the valid sibling is still an honest floor, not a false ok"

# --- 33 (QA F1). a concurrently-mutated session file (size/mtime changes
# between the before and after stat) is treated as unreadable, not trusted.
CTH=$(make_home claude-concurrent)
CTP="$CTH/claude-projects"
append_run "$CTH/state/task-runs.jsonl" conctask ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
ENCCT=$(encode_worktree /wt/conctask)
mkdir -p "$CTP/$ENCCT"
claude_event 2026-07-15T12:30:00Z 5 5 0 0 > "$CTP/$ENCCT/mutating.jsonl"
CTB=$(fm_fakebin "$CTH")
CT_REAL_STAT="$(command -v stat)"
# Shim stat: the SECOND call for this file reports a different size than the
# first, simulating a writer appending mid-read.
cat > "$CTB/stat" <<'SH'
#!/usr/bin/env bash
real="${REAL_STAT:-/usr/bin/stat}"
last="${*: -1}"
case "$last" in
  */mutating.jsonl)
    if [ ! -e "${MUTATE_MARK:?}" ]; then
      : > "$MUTATE_MARK"
      exec "$real" "$@"
    else
      echo "999999 9999999999"
    fi
    ;;
  *) exec "$real" "$@" ;;
esac
SH
chmod +x "$CTB/stat"
PATH="$CTB:$PATH" REAL_STAT="$CT_REAL_STAT" MUTATE_MARK="$CTH/mutate-seen" \
  FM_CLAUDE_PROJECTS_OVERRIDE="$CTP" FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
  --target "$CTH" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "concurrent-mutation run must still exit zero (tolerated data issue)"
CTJ=$CTH/$OUT_SUB/latest.json
[ "$(row_of "$CTJ" conctask tokens_status)" = partial ] || fail "QA F1: a file whose stat changed mid-read must not be trusted"
[ "$(row_of "$CTJ" conctask sessions_matched)" = 0 ] || fail "QA F1: the mutated file must not contribute to the sum"
[ "$(row_of "$CTJ" conctask sessions_problem)" = 1 ] || fail "QA F1: the mutated file must be counted as a problem"
pass "QA F1: a session file whose size/mtime changes across the read is treated as unstable, not trusted"

# --- 34 (QA F2). ONE session shared by two tasks with overlapping windows on
# the SAME reused worktree must never be double-counted; both affected tasks
# are downgraded to ambiguous_join/low and the session is excluded from both.
DUP=$(make_home claude-duplicate)
CPDUP="$DUP/claude-projects"
L=$DUP/state/task-runs.jsonl
append_run "$L" task-a ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
jq -c 'if .task=="task-a" then .worktree="/wt/shared" | .spawned_at="2026-07-15T10:00:00Z" | .ended_at="2026-07-15T12:00:00Z" else . end' "$L" > "$L.tmp" && mv "$L.tmp" "$L"
append_run "$L" task-b ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T13:00:00Z
jq -c 'if .task=="task-b" then .worktree="/wt/shared" | .spawned_at="2026-07-15T11:00:00Z" | .ended_at="2026-07-15T13:00:00Z" else . end' "$L" > "$L.tmp" && mv "$L.tmp" "$L"
ENCDUP=$(encode_worktree /wt/shared)
mkdir -p "$CPDUP/$ENCDUP"
# One session at 11:30, inside BOTH tasks' windows (a-window 10:00-14:00 with
# grace, b-window 11:00-15:00 with grace) - genuinely ambiguous.
claude_event 2026-07-15T11:30:00Z 10 0 0 0 > "$CPDUP/$ENCDUP/shared.jsonl"
FM_CLAUDE_PROJECTS_OVERRIDE="$CPDUP" FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
  --target "$DUP" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "duplicate-claim run exited non-zero"
DUPJ=$DUP/$OUT_SUB/latest.json
for t in task-a task-b; do
  [ "$(row_of "$DUPJ" "$t" tokens_status)" = ambiguous_join ] || fail "QA F2: $t sharing an ambiguous session must be ambiguous_join, got $(row_of "$DUPJ" "$t" tokens_status)"
  [ "$(row_of "$DUPJ" "$t" confidence)" = low ] || fail "QA F2: $t confidence must be low"
  [ "$(row_of "$DUPJ" "$t" total_tokens)" = 0 ] || fail "QA F2: $t must not receive any of the ambiguous session's tokens"
  [ "$(row_of "$DUPJ" "$t" ambiguous_sessions_excluded)" = 1 ] || fail "QA F2: $t must record the excluded ambiguous session"
done
SUMTOK=$(jq '[.panels.tokens.by_task[] | select(.task=="task-a" or .task=="task-b") | .total_tokens] | add' "$DUPJ")
[ "$SUMTOK" = 0 ] || fail "QA F2: the fleet-wide sum across both tasks must be 0, not 10+10=20 (double count), got $SUMTOK"
pass "QA F2: a session claimed by two reused-worktree tasks is excluded from both, never double counted"

# --- 35 (QA F2). the SAME scenario but with a session uniquely inside only
# task-a's window: task-a must join normally (ok/high); task-b (which never
# claims it) is unaffected.
UNQ=$(make_home claude-unique-share)
CPUNQ="$UNQ/claude-projects"
LU=$UNQ/state/task-runs.jsonl
append_run "$LU" uniq-a ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
jq -c 'if .task=="uniq-a" then .worktree="/wt/uniqshared" | .spawned_at="2026-07-15T09:00:00Z" | .ended_at="2026-07-15T09:30:00Z" else . end' "$LU" > "$LU.tmp" && mv "$LU.tmp" "$LU"
append_run "$LU" uniq-b ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-16T12:00:00Z
jq -c 'if .task=="uniq-b" then .worktree="/wt/uniqshared" | .spawned_at="2026-07-16T09:00:00Z" | .ended_at="2026-07-16T09:30:00Z" else . end' "$LU" > "$LU.tmp" && mv "$LU.tmp" "$LU"
ENCUNQ=$(encode_worktree /wt/uniqshared)
mkdir -p "$CPUNQ/$ENCUNQ"
claude_event 2026-07-15T09:15:00Z 42 0 0 0 > "$CPUNQ/$ENCUNQ/only-a.jsonl"
FM_CLAUDE_PROJECTS_OVERRIDE="$CPUNQ" FM_USAGE_NOW=2026-07-20T00:00:00Z "$USAGE" \
  --target "$UNQ" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "unique-share run exited non-zero"
UNQJ=$UNQ/$OUT_SUB/latest.json
[ "$(row_of "$UNQJ" uniq-a tokens_status)" = ok ] || fail "a session inside only one task's window must still join ok for that task"
[ "$(row_of "$UNQJ" uniq-a input_tokens)" = 42 ] || fail "uniquely-claimed session tokens"
[ "$(row_of "$UNQJ" uniq-b tokens_status)" = absent ] || fail "a task sharing a worktree but not claiming the session must be unaffected (absent)"
pass "worktree reuse alone does not force ambiguity - only a session genuinely claimed by more than one task does"

# --- 36 (QA F3). meta model=default resolves to the transcript's single
# observed model, and confidence is capped to low even though the join
# itself is otherwise clean (single uniquely-claimed session).
DMH=$(make_home claude-defaultmodel)
CPDM="$DMH/claude-projects"
fm_write_meta "$DMH/state/defaulttask.meta" \
  project=/home/prode/fleet/firstmate harness=claude kind=ship \
  model=default effort=high spawned_at=2026-07-15T10:00:00Z worktree=/wt/defaulttask
ENCDM=$(encode_worktree /wt/defaulttask)
mkdir -p "$CPDM/$ENCDM"
claude_event 2026-07-15T10:15:00Z 5 0 0 0 > "$CPDM/$ENCDM/s.jsonl"
FM_CLAUDE_PROJECTS_OVERRIDE="$CPDM" FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
  --target "$DMH" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "default-model run exited non-zero"
DMJ=$DMH/$OUT_SUB/latest.json
[ "$(row_of "$DMJ" defaulttask model)" = claude-opus-4-8 ] || fail "QA F3: model=default must resolve to the transcript's observed model"
[ "$(row_of "$DMJ" defaulttask tokens_status)" = ok ] || fail "QA F3: the token count itself is still trustworthy"
[ "$(row_of "$DMJ" defaulttask confidence)" = low ] || fail "QA F3: confidence must be capped to low when the routing model was default"
[ "$(row_of "$DMJ" defaulttask model_source)" = transcript ] || fail "QA F3: model_source must say the model came from the transcript"
pass "QA F3: model=default resolves to the transcript's real model and caps confidence to low"

# --- 37 (QA F3). routing declared a concrete model that DISAGREES with the
# transcript's single observed model - confidence still capped to low.
MMH=$(make_home claude-modelmismatch)
CPMM="$MMH/claude-projects"
append_run "$MMH/state/task-runs.jsonl" mismatch1 ship /home/prode/fleet/firstmate claude claude-sonnet-5 high 2026-07-15T12:00:00Z
ENCMM=$(encode_worktree /wt/mismatch1)
mkdir -p "$CPMM/$ENCMM"
claude_event 2026-07-15T12:15:00Z 8 0 0 0 > "$CPMM/$ENCMM/s.jsonl"
FM_CLAUDE_PROJECTS_OVERRIDE="$CPMM" FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
  --target "$MMH" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "model-mismatch run exited non-zero"
MMJ=$MMH/$OUT_SUB/latest.json
[ "$(row_of "$MMJ" mismatch1 model)" = claude-opus-4-8 ] || fail "QA F3: the transcript's ground truth model should be reported over a disagreeing routing label"
[ "$(row_of "$MMJ" mismatch1 confidence)" = low ] || fail "QA F3: a routing/transcript model mismatch must cap confidence to low"
[ "$(row_of "$MMJ" mismatch1 model_source)" = transcript ] || fail "QA r2 F3: model_source must say transcript when a routing mismatch was overridden, not routing"
pass "QA F3: a routing/transcript model mismatch resolves to the transcript, caps confidence to low, and reports model_source=transcript"

# --- 38 (QA F3). multiple DISTINCT transcript models observed across the
# uniquely-claimed sessions of one task - heterogeneous, confidence capped.
HMH=$(make_home claude-heteromodel)
CPHM="$HMH/claude-projects"
append_run "$HMH/state/task-runs.jsonl" hetero1 ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
ENCHM=$(encode_worktree /wt/hetero1)
mkdir -p "$CPHM/$ENCHM"
jq -nc --arg ts 2026-07-15T12:15:00Z '{type:"assistant", timestamp:$ts, message:{model:"claude-opus-4-8", usage:{input_tokens:5, output_tokens:0}}}' > "$CPHM/$ENCHM/s1.jsonl"
jq -nc --arg ts 2026-07-15T12:30:00Z '{type:"assistant", timestamp:$ts, message:{model:"claude-fable-5", usage:{input_tokens:5, output_tokens:0}}}' > "$CPHM/$ENCHM/s2.jsonl"
FM_CLAUDE_PROJECTS_OVERRIDE="$CPHM" FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
  --target "$HMH" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "heterogeneous-model run exited non-zero"
HMJ=$HMH/$OUT_SUB/latest.json
[ "$(row_of "$HMJ" hetero1 tokens_status)" = ok ] || fail "QA F3: heterogeneous models is a confidence concern, not a data problem"
[ "$(row_of "$HMJ" hetero1 confidence)" = low ] || fail "QA F3: two distinct transcript models must cap confidence to low"
[ "$(row_of "$HMJ" hetero1 total_tokens)" = 10 ] || fail "QA F3: the token sum itself is still summed normally"
pass "QA F3: disagreeing transcript models across sessions cap confidence to low without discarding the tokens"

# --- 39 (QA F5). an unsearchable Claude root (mode 000 parent, not ENOENT) is
# an OPERATIONAL failure - loud, nonzero, no publication - never absent/none.
UPH=$(make_home claude-unsearchable)
CPUP="$UPH/claude-projects"
append_run "$UPH/state/task-runs.jsonl" blockedtask ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
ENCUP=$(encode_worktree /wt/blockedtask)
mkdir -p "$CPUP/blocked-parent/$ENCUP"
claude_event 2026-07-15T12:15:00Z 10 0 0 0 > "$CPUP/blocked-parent/$ENCUP/s.jsonl"
# Point CLAUDE_PROJECTS at the now-inaccessible parent so encode_claude_dir's
# target directory lives underneath a mode-000 ancestor (EACCES, not ENOENT).
chmod 000 "$CPUP/blocked-parent"
UPO=$UPH/out; UPO_OUT=$UPH/stdout; UPO_ERR=$UPH/stderr
FM_CLAUDE_PROJECTS_OVERRIDE="$CPUP/blocked-parent" FM_USAGE_NOW=2026-07-18T00:00:00Z \
  "$USAGE" --target "$UPH" --out "$UPO" --since 2026-07-01 --until 2026-07-31 \
  >"$UPO_OUT" 2>"$UPO_ERR"
up_rc=$?
chmod 755 "$CPUP/blocked-parent"
[ "$up_rc" -ne 0 ] || fail "QA F5: an unsearchable claude root must exit nonzero, got $up_rc"
grep -q "failed to list claude session files" "$UPO_ERR" || fail "QA F5: an unsearchable claude root must print the named diagnostic"
assert_no_grep "usage report:" "$UPO_OUT" "QA F5: an unsearchable claude root must not print a success summary"
assert_absent "$UPO/latest.json" "QA F5: an unsearchable claude root must not publish a report"
pass "QA F5: an unsearchable (not missing) Claude root is an operational failure, never silent absence"

# --- 40 (QA F6). fingerprint changes when ONLY Claude token data changes,
# with model_mix (totals/window) held byte-identical.
FPH=$(make_home claude-fingerprint)
CPFP="$FPH/claude-projects"
append_run "$FPH/state/task-runs.jsonl" fptask ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
ENCFP=$(encode_worktree /wt/fptask)
mkdir -p "$CPFP/$ENCFP"
claude_event 2026-07-15T12:15:00Z 5 0 0 0 > "$CPFP/$ENCFP/s.jsonl"
FM_CLAUDE_PROJECTS_OVERRIDE="$CPFP" FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
  --target "$FPH" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "fingerprint-baseline run exited non-zero"
FP1=$(jq -r '.fingerprint' "$FPH/$OUT_SUB/index.jsonl" | tail -1)
# Same task-runs.jsonl, same window, same model mix - but MORE tokens in the
# claude session (a second event). The fingerprint must differ.
claude_event 2026-07-15T12:20:00Z 500 0 0 0 >> "$CPFP/$ENCFP/s.jsonl"
FM_CLAUDE_PROJECTS_OVERRIDE="$CPFP" FM_USAGE_NOW=2026-07-18T00:00:01Z "$USAGE" \
  --target "$FPH" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "fingerprint-changed run exited non-zero"
FP2=$(jq -r '.fingerprint' "$FPH/$OUT_SUB/index.jsonl" | tail -1)
[ "$FP1" != "$FP2" ] || fail "QA F6: the fingerprint must change when only Claude token totals change (got identical $FP1)"
pass "QA F6: the report fingerprint covers the tokens panel, not just model_mix"

# --- 41 (QA F7). a checked cat-append failure on a new M2 temp file fails
# loud and nonzero, exactly like the M1 publish-path checks it mirrors.
CAH=$(make_home claude-catfail)
append_run "$CAH/state/task-runs.jsonl" catfailtask ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
CAB=$(fm_fakebin "$CAH")
CA_REAL_MKTEMP="$(command -v mktemp)"
# Shim mktemp: for the claude-task-records temp specifically, create it via
# the real tool then immediately strip write permission, forcing the FIRST
# emit_claude_task_record append to fail.
cat > "$CAB/mktemp" <<'SH'
#!/usr/bin/env bash
real="${REAL_MKTEMP:-/usr/bin/mktemp}"
out="$("$real" "$@")"
rc=$?
case "$out" in
  */fm-usage-claude-task-records.*) chmod 400 "$out" ;;
esac
printf '%s\n' "$out"
exit "$rc"
SH
chmod +x "$CAB/mktemp"
CAO=$CAH/out; CAO_OUT=$CAH/stdout; CAO_ERR=$CAH/stderr
PATH="$CAB:$PATH" REAL_MKTEMP="$CA_REAL_MKTEMP" FM_USAGE_NOW=2026-07-18T00:00:00Z \
  "$USAGE" --target "$CAH" --out "$CAO" --since 2026-07-01 --until 2026-07-31 \
  >"$CAO_OUT" 2>"$CAO_ERR"
ca_rc=$?
[ "$ca_rc" -ne 0 ] || fail "QA F7: an unwritable claude task-records temp must exit nonzero, got $ca_rc"
grep -q "failed to append claude task record" "$CAO_ERR" || fail "QA F7: must print the named append diagnostic"
assert_no_grep "usage report:" "$CAO_OUT" "QA F7: must not print a success summary"
assert_absent "$CAO/latest.json" "QA F7: must not publish a report"
pass "QA F7: a checked cat-append failure on a new M2 temp file fails loud and nonzero"

# --- 42. an OPERATIONAL jq failure on a session file aborts loud (mutation-
# sensitive counterpart to test 32/33: this must NOT be silently tolerated
# the way a parse error or a stat mutation is).
OJH=$(make_home claude-jqfail)
CP31="$OJH/claude-projects"
append_run "$OJH/state/task-runs.jsonl" jqfail1 ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
ENC31=$(encode_worktree /wt/jqfail1)
mkdir -p "$CP31/$ENC31"
claude_event 2026-07-15T12:30:00Z 5 5 0 0 > "$CP31/$ENC31/trigger.jsonl"
OJB=$(fm_fakebin "$OJH")
OJ_REAL_JQ="$(command -v jq)"
cat > "$OJB/jq" <<'SH'
#!/usr/bin/env bash
real="${REAL_JQ:-/usr/bin/jq}"
for arg in "$@"; do
  case "$arg" in
    *'evOK'*) echo "injected operational jq failure" >&2; exit 66 ;;
  esac
done
exec "$real" "$@"
SH
chmod +x "$OJB/jq"
OJO=$OJH/out; OJO_OUT=$OJH/stdout; OJO_ERR=$OJH/stderr
PATH="$OJB:$PATH" REAL_JQ="$OJ_REAL_JQ" FM_CLAUDE_PROJECTS_OVERRIDE="$CP31" \
  FM_USAGE_NOW=2026-07-18T00:00:00Z \
  "$USAGE" --target "$OJH" --out "$OJO" --since 2026-07-01 --until 2026-07-31 \
  >"$OJO_OUT" 2>"$OJO_ERR"
oj_rc=$?
[ "$oj_rc" -ne 0 ] || fail "operational session-file jq failure must exit nonzero, got $oj_rc"
grep -q "failed to parse claude session file with jq" "$OJO_ERR" || fail "operational session jq failure must print the named diagnostic"
grep -q "injected operational jq failure" "$OJO_ERR" || fail "operational session jq failure must preserve the tool's own stderr"
assert_no_grep "usage report:" "$OJO_OUT" "operational session jq failure must not print a success summary"
assert_absent "$OJO/latest.json" "operational session jq failure must not publish a report"
[ ! -f "$OJO/index.jsonl" ] || [ "$(wc -l < "$OJO/index.jsonl")" = 0 ] || fail "operational session jq failure must not append an index line"
pass "an operational (non-parse-error) jq failure on a session file fails loud, unlike a malformed file"

# --- 43. an operational `find` failure (ENOENT-unrelated) listing a claude
# session directory aborts loud -------------------------------------------
FFH=$(make_home claude-findfail)
CP32="$FFH/claude-projects"
append_run "$FFH/state/task-runs.jsonl" findfail1 ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
ENC32=$(encode_worktree /wt/findfail1)
mkdir -p "$CP32/$ENC32"
FFB=$(fm_fakebin "$FFH")
cat > "$FFB/find" <<'SH'
#!/usr/bin/env bash
echo "injected find failure" >&2
exit 65
SH
chmod +x "$FFB/find"
FFO=$FFH/out; FFO_OUT=$FFH/stdout; FFO_ERR=$FFH/stderr
PATH="$FFB:$PATH" FM_CLAUDE_PROJECTS_OVERRIDE="$CP32" FM_USAGE_NOW=2026-07-18T00:00:00Z \
  "$USAGE" --target "$FFH" --out "$FFO" --since 2026-07-01 --until 2026-07-31 \
  >"$FFO_OUT" 2>"$FFO_ERR"
ff_rc=$?
[ "$ff_rc" -ne 0 ] || fail "operational find failure must exit nonzero, got $ff_rc"
grep -q "failed to list claude session files" "$FFO_ERR" || fail "operational find failure must print the named diagnostic"
grep -q "injected find failure" "$FFO_ERR" || fail "operational find failure must preserve the tool's own stderr"
assert_no_grep "usage report:" "$FFO_OUT" "operational find failure must not print a success summary"
assert_absent "$FFO/latest.json" "operational find failure must not publish a report"
pass "an operational find failure listing a claude session directory fails loud"

# --- 44. non-claude harnesses are unified into by_task as unsupported, never
# attempted --------------------------------------------------------------
NCH=$(make_home claude-nonclaude)
fm_write_meta "$NCH/state/g1.meta" \
  project=/home/prode/fleet/firstmate harness=grok kind=ship \
  model=grok-4.5 effort=high spawned_at=2026-07-15T10:00:00Z worktree=/wt/g1
fm_write_meta "$NCH/state/g2.meta" \
  project=/home/prode/fleet/firstmate harness=gemini kind=ship \
  model=gemini-3.5-flash effort=high spawned_at=2026-07-15T10:00:00Z worktree=/wt/g2
FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
  --target "$NCH" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "non-claude run exited non-zero"
NCJ=$NCH/$OUT_SUB/latest.json
EXPECT_NC='[["g1","grok","unsupported"],["g2","gemini","unsupported"]]'
GOT_NC=$(jq -c '[.panels.tokens.by_task[]|[.task,.harness,.tokens_status]] | sort' "$NCJ")
[ "$GOT_NC" = "$(jq -c 'sort' <<< "$EXPECT_NC")" ] || fail "unsupported by_task: got $GOT_NC want $EXPECT_NC"
[ "$(jq -r '.panels.tokens.totals.unsupported' "$NCJ")" = 2 ] || fail "totals.unsupported"
pass "grok/gemini tasks land in by_task as unsupported, no join attempted (M3+ scope)"

# --- 45. by_harness_model rollup across multiple claude tasks sharing a model
BMH=$(make_home claude-bymodel)
CPBM="$BMH/claude-projects"
append_run "$BMH/state/task-runs.jsonl" bm1 ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
append_run "$BMH/state/task-runs.jsonl" bm2 ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
ENCBM1=$(encode_worktree /wt/bm1)
ENCBM2=$(encode_worktree /wt/bm2)
mkdir -p "$CPBM/$ENCBM1" "$CPBM/$ENCBM2"
claude_event 2026-07-15T12:15:00Z 10 20 0 0 > "$CPBM/$ENCBM1/sess.jsonl"
claude_event 2026-07-15T12:15:00Z 30 40 0 0 > "$CPBM/$ENCBM2/sess.jsonl"
FM_CLAUDE_PROJECTS_OVERRIDE="$CPBM" FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
  --target "$BMH" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "by_harness_model run exited non-zero"
BMJ=$BMH/$OUT_SUB/latest.json
[ "$(jq -r '.panels.tokens.by_harness_model | length' "$BMJ")" = 1 ] || fail "by_harness_model must roll both tasks into one row"
GOT_BM=$(jq -c '.panels.tokens.by_harness_model[0] | [.harness,.model,.tasks,.tasks_with_data,.input_tokens,.output_tokens,.total_tokens]' "$BMJ")
[ "$GOT_BM" = '["claude","claude-opus-4-8",2,2,40,60,100]' ] || fail "by_harness_model rollup: got $GOT_BM"
pass "by_harness_model rolls up token sums across multiple claude tasks sharing a model"

# --- 46. Markdown Panel B renders the unified by_task table, by_harness_model
# rollup, and the totals line -----------------------------------------------
MDOWN=$HP/$OUT_SUB/latest.md
assert_grep "## Panel B - Tokens (partial)" "$MDOWN" "md Panel B header"
assert_grep "### By task" "$MDOWN" "md by-task header"
assert_grep "| happy1 | claude | claude-opus-4-8 | claude_project_dir | ok | high | 300 | 130 | 30 | 13 | 473 | 1 | 0 | 0 |" "$MDOWN" "md claude per-task row"
assert_grep "### By harness / model" "$MDOWN" "md by-harness-model header"
assert_grep "| claude | claude-opus-4-8 | 1 | 1 | 300 | 130 | 30 | 13 | 473 |" "$MDOWN" "md by-harness-model row"
assert_grep "1 ok, 0 ambiguous_join, 0 partial, 0 absent, 0 unsupported" "$MDOWN" "md totals line"
pass "Markdown Panel B renders the unified by_task table, by_harness_model rollup, and totals"


# ============================================================================
# Slice M2 round 3 (data/qa-m2r2-q43/report.md): missing/invalid session
# timestamps and the full run_or_die invocation-class invariant.
# ============================================================================

# --- 47 (QA r2 F1, critical). QA's exact reproduction: a usage-bearing
# session with NO timestamp beside a small valid sibling must NOT silently
# drop the untimed session's tokens and report the survivor as ok/high.
NTH=$(make_home claude-notimestamp)
CPNT="$NTH/claude-projects"
append_run "$NTH/state/task-runs.jsonl" tstask ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
ENCNT=$(encode_worktree /wt/tstask)
mkdir -p "$CPNT/$ENCNT"
claude_event 2026-07-15T12:15:00Z 5 0 0 0 > "$CPNT/$ENCNT/small.jsonl"
jq -nc '{type:"assistant", message:{model:"claude-opus-4-8", usage:{input_tokens:100, output_tokens:0}}}' \
  > "$CPNT/$ENCNT/notime.jsonl"
FM_CLAUDE_PROJECTS_OVERRIDE="$CPNT" FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
  --target "$NTH" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "missing-timestamp run exited non-zero"
NTJ=$NTH/$OUT_SUB/latest.json
[ "$(row_of "$NTJ" tstask tokens_status)" = partial ] || fail "QA r2 F1: a usage-bearing session with no timestamp must make the task partial, got $(row_of "$NTJ" tstask tokens_status)"
[ "$(row_of "$NTJ" tstask confidence)" = low ] || fail "QA r2 F1: partial confidence must be low, never high"
[ "$(row_of "$NTJ" tstask sessions_problem)" = 1 ] || fail "QA r2 F1: the untimed session must count as a problem"
[ "$(row_of "$NTJ" tstask total_tokens)" = 5 ] || fail "QA r2 F1: total must be the valid sibling's honest floor (5), never silently reported as complete"
pass "QA r2 F1: a usage-bearing session missing its timestamp downgrades the task to partial, never a silent ok/high"

# --- 48 (QA r2 F1). The same missing-timestamp session ALONE (no sibling)
# must be partial/low with a zero floor, not absent/none.
NTAH=$(make_home claude-notimestamp-alone)
CPNTA="$NTAH/claude-projects"
append_run "$NTAH/state/task-runs.jsonl" alonetask ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
ENCNTA=$(encode_worktree /wt/alonetask)
mkdir -p "$CPNTA/$ENCNTA"
jq -nc '{type:"assistant", message:{model:"claude-opus-4-8", usage:{input_tokens:100, output_tokens:0}}}' \
  > "$CPNTA/$ENCNTA/notime.jsonl"
FM_CLAUDE_PROJECTS_OVERRIDE="$CPNTA" FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
  --target "$NTAH" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "missing-timestamp-alone run exited non-zero"
NTAJ=$NTAH/$OUT_SUB/latest.json
[ "$(row_of "$NTAJ" alonetask tokens_status)" = partial ] || fail "QA r2 F1: an untimed session alone must be partial, not absent (got $(row_of "$NTAJ" alonetask tokens_status))"
[ "$(row_of "$NTAJ" alonetask sessions_problem)" = 1 ] || fail "QA r2 F1: the untimed session must be an explicit problem, not silently absent"
pass "QA r2 F1: a lone usage-bearing session with no timestamp is partial/problem, not absent"

# --- 49 (QA r2 F1). A non-string timestamp (a JSON number, or explicit null)
# on a usage-bearing event is exactly as invalid as a missing one.
NSH=$(make_home claude-nonstring-timestamp)
CPNS="$NSH/claude-projects"
append_run "$NSH/state/task-runs.jsonl" numts ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
append_run "$NSH/state/task-runs.jsonl" nullts ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
mkdir -p "$CPNS/$(encode_worktree /wt/numts)" "$CPNS/$(encode_worktree /wt/nullts)"
jq -nc '{type:"assistant", timestamp:1784117700, message:{model:"claude-opus-4-8", usage:{input_tokens:5, output_tokens:0}}}' \
  > "$CPNS/$(encode_worktree /wt/numts)/s.jsonl"
jq -nc '{type:"assistant", timestamp:null, message:{model:"claude-opus-4-8", usage:{input_tokens:5, output_tokens:0}}}' \
  > "$CPNS/$(encode_worktree /wt/nullts)/s.jsonl"
FM_CLAUDE_PROJECTS_OVERRIDE="$CPNS" FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
  --target "$NSH" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "non-string-timestamp run exited non-zero"
NSJ=$NSH/$OUT_SUB/latest.json
for t in numts nullts; do
  [ "$(row_of "$NSJ" "$t" tokens_status)" = partial ] || fail "QA r2 F1: $t (non-string timestamp) must be partial, got $(row_of "$NSJ" "$t" tokens_status)"
  [ "$(row_of "$NSJ" "$t" total_tokens)" = 0 ] || fail "QA r2 F1: $t must not publish a fabricated total"
done
pass "QA r2 F1: a numeric or null timestamp on a usage-bearing event is invalid, same as a missing one"

# --- 50 (QA r2 F1). A syntactically-fine but semantically unparseable
# timestamp string (passes jq's non-empty-string check, GNU date rejects it)
# is the residual gap a schema check alone cannot catch - closed via the
# post-epoch-conversion re-check.
UPTH=$(make_home claude-unparseable-timestamp)
CPUPT="$UPTH/claude-projects"
append_run "$UPTH/state/task-runs.jsonl" badts ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
ENCUPT=$(encode_worktree /wt/badts)
mkdir -p "$CPUPT/$ENCUPT"
jq -nc '{type:"assistant", timestamp:"not-a-real-timestamp", message:{model:"claude-opus-4-8", usage:{input_tokens:50, output_tokens:0}}}' \
  > "$CPUPT/$ENCUPT/s.jsonl"
FM_CLAUDE_PROJECTS_OVERRIDE="$CPUPT" FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
  --target "$UPTH" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "unparseable-timestamp run exited non-zero"
UPTJ=$UPTH/$OUT_SUB/latest.json
[ "$(row_of "$UPTJ" badts tokens_status)" = partial ] || fail "QA r2 F1: an unparseable timestamp string must be partial, got $(row_of "$UPTJ" badts tokens_status)"
[ "$(row_of "$UPTJ" badts sessions_problem)" = 1 ] || fail "QA r2 F1: an unparseable timestamp must count as a problem"
[ "$(row_of "$UPTJ" badts total_tokens)" = 0 ] || fail "QA r2 F1: an unparseable-timestamp session must never contribute a fabricated total"
pass "QA r2 F1: a syntactically-valid but GNU-date-unparseable timestamp is caught after epoch conversion, not just at the schema layer"

# --- 51. An assistant-FREE session (no assistant events at all) legitimately
# has no timestamp to lose and must NOT be penalized - proves the timestamp
# rule is scoped to usage-bearing events, not every file.
NAEH=$(make_home claude-no-assistant-events)
CPNAE="$NAEH/claude-projects"
append_run "$NAEH/state/task-runs.jsonl" noassist ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
ENCNAE=$(encode_worktree /wt/noassist)
mkdir -p "$CPNAE/$ENCNAE"
non_assistant_event 2026-07-15T12:15:00Z > "$CPNAE/$ENCNAE/useronly.jsonl"
claude_event 2026-07-15T12:20:00Z 7 0 0 0 > "$CPNAE/$ENCNAE/real.jsonl"
FM_CLAUDE_PROJECTS_OVERRIDE="$CPNAE" FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
  --target "$NAEH" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "no-assistant-events run exited non-zero"
NAEJ=$NAEH/$OUT_SUB/latest.json
[ "$(row_of "$NAEJ" noassist tokens_status)" = ok ] || fail "an assistant-free sibling must not penalize an otherwise-clean task, got $(row_of "$NAEJ" noassist tokens_status)"
[ "$(row_of "$NAEJ" noassist sessions_problem)" = 0 ] || fail "an assistant-free session (nothing usage-bearing to time-place) must not count as a problem"
[ "$(row_of "$NAEJ" noassist input_tokens)" = 7 ] || fail "the real session's tokens must still be counted"
pass "a session with no assistant events at all is not penalized for lacking a timestamp"

# ============================================================================
# Slice M2 round 4, class-level (data/qa-m2r3-q47/report.md): every timestamp
# gate, not just the two round-3 covered; every external call routed through
# run_or_die/run_or_die_to_file with zero swallowed-substitution sites.
# ============================================================================

# --- 52 (QA r3 F1, critical, exact reproduction). An unparseable assistant
# timestamp that is LEXICALLY INTERIOR to valid non-assistant envelope
# timestamps must not evade validation just because it never becomes the
# session's min/max extremum.
IIH=$(make_home claude-interior-invalid-ts)
CPII="$IIH/claude-projects"
append_run "$IIH/state/task-runs.jsonl" interior ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
ENCII=$(encode_worktree /wt/interior)
mkdir -p "$CPII/$ENCII"
{
  non_assistant_event 2026-07-15T12:10:00Z
  jq -nc --arg ts "2026-07-15T12:30:99Z" '{type:"assistant", timestamp:$ts, message:{model:"claude-opus-4-8", usage:{input_tokens:100, output_tokens:0}}}'
  non_assistant_event 2026-07-15T12:50:00Z
} > "$CPII/$ENCII/interior.jsonl"
FM_CLAUDE_PROJECTS_OVERRIDE="$CPII" FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
  --target "$IIH" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "interior-invalid-timestamp run exited non-zero"
IIJ=$IIH/$OUT_SUB/latest.json
[ "$(row_of "$IIJ" interior tokens_status)" = partial ] || fail "QA r3 F1: an assistant event with an unparseable timestamp bracketed by valid envelope timestamps must be partial, got $(row_of "$IIJ" interior tokens_status)"
[ "$(row_of "$IIJ" interior confidence)" = low ] || fail "QA r3 F1: must never be high when a timestamp cannot be placed in time"
[ "$(row_of "$IIJ" interior sessions_problem)" = 1 ] || fail "QA r3 F1: the session must be counted as a problem"
[ "$(row_of "$IIJ" interior total_tokens)" = 0 ] || fail "QA r3 F1: the 100 tokens must never be confidently attributed via an unrelated envelope event's timestamp"
pass "QA r3 F1: an interior invalid assistant timestamp (hidden between valid envelope timestamps) is caught, never confidently attributed"

# --- 53 (QA r3 F1). Multiple assistant events, one interior timestamp
# unparseable: the WHOLE session is invalid, not just the bad event silently
# dropped from an otherwise-summed total.
MIH=$(make_home claude-multi-interior)
CPMI="$MIH/claude-projects"
append_run "$MIH/state/task-runs.jsonl" multii ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
ENCMI=$(encode_worktree /wt/multii)
mkdir -p "$CPMI/$ENCMI"
{
  claude_event 2026-07-15T12:05:00Z 10 0 0 0
  jq -nc --arg ts "2026-07-15T12:15:99Z" '{type:"assistant", timestamp:$ts, message:{model:"claude-opus-4-8", usage:{input_tokens:20, output_tokens:0}}}'
  claude_event 2026-07-15T12:55:00Z 30 0 0 0
} > "$CPMI/$ENCMI/multi.jsonl"
FM_CLAUDE_PROJECTS_OVERRIDE="$CPMI" FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
  --target "$MIH" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "multi-event interior-invalid run exited non-zero"
MIJ=$MIH/$OUT_SUB/latest.json
[ "$(row_of "$MIJ" multii tokens_status)" = partial ] || fail "QA r3 F1: one bad interior assistant timestamp among several valid ones must still invalidate the whole session"
[ "$(row_of "$MIJ" multii total_tokens)" = 0 ] || fail "QA r3 F1: must not silently sum only the 10+30 from the valid events, dropping the bad one unlabeled"
pass "QA r3 F1: one unparseable assistant timestamp among several valid ones invalidates the whole session, not just itself"

# --- 53b (QA r4 F1, critical, exact reproduction). Record-framing defect: the
# batch validator joins assistant timestamps with newlines before feeding GNU
# `date -f -`. A single JSON timestamp value containing an EMBEDDED newline
# (a JSON string may legally contain "\n" - jq -r materializes it as a real
# newline byte) is therefore split into two separate `date -f` input records.
# If both halves happen to be individually valid dates, the whole batch
# reports success and the ORIGINAL invalid/composite timestamp is never
# rejected - QA round 4's exact reproduction. The fix rejects any embedded
# CR/LF as part of schema validation itself (a real ISO-8601 timestamp can
# never legitimately contain one), so this session never even reaches the
# date -f - batch call.
NLH=$(make_home claude-newline-timestamp)
CPNL="$NLH/claude-projects"
append_run "$NLH/state/task-runs.jsonl" newlinets ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
ENCNL=$(encode_worktree /wt/newlinets)
mkdir -p "$CPNL/$ENCNL"
jq -nc --arg ts "$(printf '2026-07-15T12:30:00Z\n2026-07-15T12:31:00Z')" \
  '{type:"assistant", timestamp:$ts, message:{model:"claude-opus-4-8", usage:{input_tokens:100, output_tokens:0}}}' \
  > "$CPNL/$ENCNL/s.jsonl"
FM_CLAUDE_PROJECTS_OVERRIDE="$CPNL" FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
  --target "$NLH" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "embedded-newline-timestamp run exited non-zero"
NLJ=$NLH/$OUT_SUB/latest.json
[ "$(row_of "$NLJ" newlinets tokens_status)" = partial ] || fail "QA r4 F1: a timestamp containing an embedded newline (two individually-valid dates once split) must be partial, got $(row_of "$NLJ" newlinets tokens_status)"
[ "$(row_of "$NLJ" newlinets confidence)" = low ] || fail "QA r4 F1: must never be high - the composite value was never a single valid timestamp"
[ "$(row_of "$NLJ" newlinets sessions_problem)" = 1 ] || fail "QA r4 F1: the session must be counted as a problem"
[ "$(row_of "$NLJ" newlinets total_tokens)" = 0 ] || fail "QA r4 F1: the 100 tokens must never be confidently attributed via a record-framing artifact"
pass "QA r4 F1: an assistant timestamp with an embedded newline (record-framing ambiguity) is rejected at the schema gate, never ok/high"

# --- 53c (QA r4 F1). An embedded carriage return alone (no LF) is rejected
# the same way - the fix covers CR/LF as a class, not just \n.
CRH=$(make_home claude-cr-timestamp)
CPCR="$CRH/claude-projects"
append_run "$CRH/state/task-runs.jsonl" crts ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
ENCCR=$(encode_worktree /wt/crts)
mkdir -p "$CPCR/$ENCCR"
jq -nc --arg ts "$(printf '2026-07-15T12:30:00Z\r2026-07-15T12:31:00Z')" \
  '{type:"assistant", timestamp:$ts, message:{model:"claude-opus-4-8", usage:{input_tokens:50, output_tokens:0}}}' \
  > "$CPCR/$ENCCR/s.jsonl"
FM_CLAUDE_PROJECTS_OVERRIDE="$CPCR" FM_USAGE_NOW=2026-07-18T00:00:00Z "$USAGE" \
  --target "$CRH" --since 2026-07-01 --until 2026-07-31 >/dev/null \
  || fail "embedded-CR-timestamp run exited non-zero"
CRJ=$CRH/$OUT_SUB/latest.json
[ "$(row_of "$CRJ" crts tokens_status)" = partial ] || fail "QA r4 F1: an embedded carriage return must also be rejected, got $(row_of "$CRJ" crts tokens_status)"
[ "$(row_of "$CRJ" crts sessions_problem)" = 1 ] || fail "QA r4 F1: the CR-containing session must be counted as a problem"
pass "QA r4 F1: an embedded carriage return in a timestamp is rejected the same way as an embedded newline"

# --- 54 (QA r3 F2). run_or_die_to_file preserves the REAL exit status of a
# failed find, not a fixed/fake code - the exact bug save_run_out_to had
# (an if-with-no-else zeroed status=$? to 0 regardless of the real failure).
RSH=$(make_home claude-realstatus)
CPRS="$RSH/claude-projects"
append_run "$RSH/state/task-runs.jsonl" realstatustask ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
ENCRS=$(encode_worktree /wt/realstatustask)
mkdir -p "$CPRS/$ENCRS"
RSB=$(fm_fakebin "$RSH")
cat > "$RSB/find" <<'SH'
#!/usr/bin/env bash
echo "injected find failure with a distinctive code" >&2
exit 93
SH
chmod +x "$RSB/find"
RSO=$RSH/out; RSO_OUT=$RSH/stdout; RSO_ERR=$RSH/stderr
PATH="$RSB:$PATH" FM_CLAUDE_PROJECTS_OVERRIDE="$CPRS" FM_USAGE_NOW=2026-07-18T00:00:00Z \
  "$USAGE" --target "$RSH" --out "$RSO" --since 2026-07-01 --until 2026-07-31 \
  >"$RSO_OUT" 2>"$RSO_ERR"
rs_rc=$?
[ "$rs_rc" -ne 0 ] || fail "QA r3 F2: a failed find must exit nonzero, got $rs_rc"
grep -q "failed to list claude session files" "$RSO_ERR" || fail "QA r3 F2: must print the named find diagnostic"
grep -q "(exit 93)" "$RSO_ERR" || fail "QA r3 F2: the diagnostic must report the REAL exit status (93), not a fixed/lost one - the exact save_run_out_to bug"
grep -q "injected find failure with a distinctive code" "$RSO_ERR" || fail "QA r3 F2: must preserve find's own stderr"
assert_no_grep "usage report:" "$RSO_OUT" "QA r3 F2: must not print a success summary"
assert_absent "$RSO/latest.json" "QA r3 F2: must not publish a report"
pass "QA r3 F2: run_or_die_to_file preserves find's real exit status (not zeroed by an if-with-no-else)"

# --- 55 (QA r3 F2 class check). Isolated proof of the exact bug class: an
# if-condition that fails with NO else branch resolves the if-STATEMENT's own
# exit status to 0 per POSIX, not the condition's real status - this is why
# save_run_out_to silently reported "(exit 0)" for a real cp failure, and
# exactly why run_or_die_to_file captures status in an explicit else.
if bash -c '
  set -eu
  f() { if false; then :; fi; return $?; }
  f
' >/dev/null 2>&1; then
  : # expected: the if-with-no-else zeroing makes f() return 0, not false's 1
else
  fail "QA r3 F2 class check: this bash version does not exhibit the if-with-no-else zeroing bug as expected - re-verify the exploit premise"
fi
pass "QA r3 F2: verified the if-with-no-else exit-status-zeroing bug class this round's fix specifically avoids"

# --- 56 (QA r3 F3, critical class check). The exact swallowed-substitution
# mechanism: a subshell's `exit` inside $(...) is silently discarded when
# embedded in another command's arguments, but DOES propagate under set -e
# when it is the entire right-hand side of a bare assignment. This is the
# load-bearing invariant must_read_run_out's calling contract depends on;
# reproduced here directly (not via the production script) so a change to
# bash's own semantics, or a misunderstanding of them, is caught immediately.
bash -c '
  set -euo pipefail
  myfn() { echo "before exit"; exit 2; }
  printf "%s\n" "$(myfn)" > /dev/null
  echo "SWALLOWED"
' >/tmp/swallow_repro.out 2>&1
swallow_rc=$?
grep -q "SWALLOWED" /tmp/swallow_repro.out && [ "$swallow_rc" -eq 0 ] \
  || fail "QA r3 F3 class check: expected the embedded-substitution form to swallow the failure (rc=0, SWALLOWED printed) as the known bash behavior this round's fix works around"
rm -f /tmp/swallow_repro.out
bash -c '
  set -euo pipefail
  myfn() { echo "before exit"; exit 2; }
  x="$(myfn)"
  echo "REACHED: $x"
' >/tmp/bare_repro.out 2>&1
bare_rc=$?
[ "$bare_rc" -eq 2 ] || fail "QA r3 F3 class check: a bare assignment must propagate the subshell's real exit status (2), got $bare_rc"
assert_no_grep "REACHED" /tmp/bare_repro.out "QA r3 F3 class check: a bare assignment must abort before the following statement runs"
rm -f /tmp/bare_repro.out
pass "QA r3 F3: verified the exact swallowed-vs-propagated substitution mechanism must_read_run_out's calling contract relies on"

# --- 57 (QA r3 F3). Static assertion: every call to must_read_run_out in the
# join stage is a bare assignment on its own line (the ONLY shape that
# propagates its failure); zero embedded/nested occurrences remain, closing
# all four QA-cited sites AND any other site the same way. Also: zero
# remaining cat/cp $RUN_OUT patterns (save_run_out_to and its cp are gone
# entirely - find now writes straight to its destination via
# run_or_die_to_file, so there is nothing left to copy).
JOIN_SECTION_FILE=$(mktemp "$TMP_ROOT/join-section.XXXXXX")
awk '/^# --- Claude token join \(slice M2 round 5, record-framing fix\)/,/^# --- build machine report/' "$USAGE" > "$JOIN_SECTION_FILE"
[ -s "$JOIN_SECTION_FILE" ] || fail "QA r3 static assertion: the join-stage section marker was not found (anchor text drifted?)"
# shellcheck disable=SC2016
assert_no_grep 'cat "$RUN_OUT"' "$JOIN_SECTION_FILE" "QA r2/r3 F7: no direct 'cat \"\$RUN_OUT\"' in the join stage"
# shellcheck disable=SC2016
assert_no_grep '$(cat "$RUN_OUT")' "$JOIN_SECTION_FILE" "QA r2/r3 F7: no direct '\$(cat \"\$RUN_OUT\")' in the join stage"
# shellcheck disable=SC2016
assert_no_grep 'cp "$RUN_OUT"' "$JOIN_SECTION_FILE" "QA r3 F2: no direct 'cp \"\$RUN_OUT\"' anywhere in the join stage - find now writes straight to its destination"
# save_run_out_to may still be named in a comment explaining why round 4
# removed it (documentation, not usage); only an actual CALL - a non-comment
# line naming it - would mean it survived.
JOIN_SECTION_NOCOMMENTS=$(mktemp "$TMP_ROOT/join-section-nocomments.XXXXXX")
grep -v '^[[:space:]]*#' "$JOIN_SECTION_FILE" > "$JOIN_SECTION_NOCOMMENTS"
assert_no_grep 'save_run_out_to' "$JOIN_SECTION_NOCOMMENTS" \
  "QA r3 F2: save_run_out_to must be fully removed as a callable, not merely unused"
# Every mktemp INVOCATION (not a comment merely mentioning the word) must be
# routed through run_or_die.
MKTEMP_LINES=$(grep -v '^[[:space:]]*#' "$JOIN_SECTION_FILE" | grep -c 'mktemp')
MKTEMP_ROUTED=$(grep -v '^[[:space:]]*#' "$JOIN_SECTION_FILE" | grep -c -- '-- mktemp')
[ "$MKTEMP_LINES" -ge 5 ] || fail "QA r2 F7: expected at least 5 mktemp temp files in the join stage, found $MKTEMP_LINES"
[ "$MKTEMP_LINES" = "$MKTEMP_ROUTED" ] || fail "QA r2 F7: every mktemp line must be routed through run_or_die (-- mktemp); $MKTEMP_LINES total vs $MKTEMP_ROUTED routed"
# find must be routed through run_or_die_to_file, never called bare: exactly
# one "-- find" invocation marker (proving it is an argument to a checked
# owner, not a standalone command), and at least one non-comment call to
# run_or_die_to_file itself (proving the owner is actually used, not just
# defined).
FIND_LINES=$(grep -v '^[[:space:]]*#' "$JOIN_SECTION_FILE" | grep -c -- '-- find ')
FIND_ROUTED=$(grep -v '^[[:space:]]*#' "$JOIN_SECTION_FILE" | grep -c 'run_or_die_to_file')
[ "$FIND_LINES" -ge 1 ] || fail "QA r3 F2: expected at least 1 find invocation in the join stage, found $FIND_LINES"
[ "$FIND_ROUTED" -ge 1 ] || fail "QA r3 F2: expected at least 1 call to run_or_die_to_file, found $FIND_ROUTED"
# Every occurrence of "$(must_read_run_out" must be the ENTIRE right-hand
# side of a bare "VAR=" assignment on its own line - the only shape whose
# failure propagates under set -e (test 56 proves the mechanism). A line
# where anything precedes "VAR=" (e.g. it is itself an argument to another
# command such as printf) is exactly QA round 3 finding 3's bug class.
EMBEDDED_MUST_READ=0
while IFS= read -r ln; do
  trimmed="${ln#"${ln%%[![:space:]]*}"}"
  case "$trimmed" in
    '#'*) continue ;;  # comment line (e.g. documenting the historical bug) - not code
  esac
  # shellcheck disable=SC2016 # these are literal case-pattern text, not shell expansions
  case "$ln" in
    *'$(must_read_run_out'*)
      # shellcheck disable=SC2016
      case "$trimmed" in
        [A-Za-z_]*'="$(must_read_run_out'*'")"')
          : # bare assignment - safe shape
          ;;
        *)
          EMBEDDED_MUST_READ=$((EMBEDDED_MUST_READ + 1))
          echo "  embedded must_read_run_out: $ln" >&2
          ;;
      esac
      ;;
  esac
done < "$JOIN_SECTION_FILE"
[ "$EMBEDDED_MUST_READ" -eq 0 ] || fail "QA r3 F3: found $EMBEDDED_MUST_READ must_read_run_out call(s) NOT in bare-assignment form (the exact swallowed-substitution bug class)"
pass "QA r2/r3 F2/F3/F7: the join stage has zero cat/cp \$RUN_OUT reads, zero embedded must_read_run_out calls, find routes through run_or_die_to_file, and every mktemp routes through run_or_die"

# --- 58 (QA r2 F7). Operational mutation: a run_or_die-routed mktemp failure
# for a new M2 temp file fails loud, nonzero, before any publication.
MTH=$(make_home claude-mktempfail)
append_run "$MTH/state/task-runs.jsonl" mtfailtask ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
MTB=$(fm_fakebin "$MTH")
MT_REAL_MKTEMP="$(command -v mktemp)"
cat > "$MTB/mktemp" <<'SH'
#!/usr/bin/env bash
real="${REAL_MKTEMP:-/usr/bin/mktemp}"
for arg in "$@"; do
  case "$arg" in
    *fm-usage-tokens.*) echo "injected mktemp failure" >&2; exit 71 ;;
  esac
done
exec "$real" "$@"
SH
chmod +x "$MTB/mktemp"
MTO=$MTH/out; MTO_OUT=$MTH/stdout; MTO_ERR=$MTH/stderr
PATH="$MTB:$PATH" REAL_MKTEMP="$MT_REAL_MKTEMP" FM_USAGE_NOW=2026-07-18T00:00:00Z \
  "$USAGE" --target "$MTH" --out "$MTO" --since 2026-07-01 --until 2026-07-31 \
  >"$MTO_OUT" 2>"$MTO_ERR"
mt_rc=$?
[ "$mt_rc" -ne 0 ] || fail "QA r2 F7: a failed claude-tokens mktemp must exit nonzero, got $mt_rc"
grep -q "cannot create a claude-tokens temp file" "$MTO_ERR" || fail "QA r2 F7: must print the named mktemp diagnostic"
grep -q "injected mktemp failure" "$MTO_ERR" || fail "QA r2 F7: must preserve mktemp's own stderr"
assert_no_grep "usage report:" "$MTO_OUT" "QA r2 F7: must not print a success summary"
assert_absent "$MTO/latest.json" "QA r2 F7: must not publish a report"
pass "QA r2 F7: a run_or_die-routed mktemp failure for a new M2 temp file fails loud and nonzero"

# --- 59 (QA r3 F3). Operational mutation: a jq failure feeding one of the
# now-bare-assignment must_read_run_out reads still aborts loud (proves the
# fix did not accidentally weaken the existing operational-failure guarantee
# while restructuring these call sites).
JFH=$(make_home claude-jqrecordfail)
append_run "$JFH/state/task-runs.jsonl" jqrecordtask ship /home/prode/fleet/firstmate claude claude-opus-4-8 high 2026-07-15T12:00:00Z
JFB=$(fm_fakebin "$JFH")
JF_REAL_JQ="$(command -v jq)"
cat > "$JFB/jq" <<'SH'
#!/usr/bin/env bash
real="${REAL_JQ:-/usr/bin/jq}"
for arg in "$@"; do
  case "$arg" in
    *'has_worktree:$has_worktree'*) echo "injected task-record jq failure" >&2; exit 74 ;;
  esac
done
exec "$real" "$@"
SH
chmod +x "$JFB/jq"
JFO=$JFH/out; JFO_OUT=$JFH/stdout; JFO_ERR=$JFH/stderr
PATH="$JFB:$PATH" REAL_JQ="$JF_REAL_JQ" FM_USAGE_NOW=2026-07-18T00:00:00Z \
  "$USAGE" --target "$JFH" --out "$JFO" --since 2026-07-01 --until 2026-07-31 \
  >"$JFO_OUT" 2>"$JFO_ERR"
jf_rc=$?
[ "$jf_rc" -ne 0 ] || fail "QA r3 F3: a failed claude-task-record jq must exit nonzero, got $jf_rc"
grep -q "failed to build claude task record with jq" "$JFO_ERR" || fail "QA r3 F3: must print the named diagnostic"
grep -q "injected task-record jq failure" "$JFO_ERR" || fail "QA r3 F3: must preserve jq's own stderr"
assert_no_grep "usage report:" "$JFO_OUT" "QA r3 F3: must not print a success summary"
assert_absent "$JFO/latest.json" "QA r3 F3: must not publish a report with a silently missing claude token row"
pass "QA r3 F3: a jq failure feeding a bare-assignment must_read_run_out call still aborts loud, no silently missing row"

echo "ok - fm-usage-report.test.sh"

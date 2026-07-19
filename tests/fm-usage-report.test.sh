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
#     the M2 tokens panel's partial (claude-only) shape
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
# Slice M2 (Claude token joiner) coverage:
#   - happy path: encode(worktree) join, sum of a matched session's assistant
#     usage, tokens_status=ok, confidence=high, join_method=claude_project_dir
#   - session-file-level time filtering: an unrelated session outside the join
#     window is excluded wholesale even though the directory holds other,
#     in-window sessions (the worktree-pool-reuse hazard from report 4.3/6.3)
#   - inclusive lower/upper join-window boundaries (spawned_at and
#     ended_at+grace), and exclusion one second outside each
#   - grace-hours configurability via FM_USAGE_CLAUDE_GRACE_HOURS
#   - undated tasks (no spawned_at) fall back to summing every top-level
#     session unfiltered, labeled tokens_status=ambiguous_join, confidence=low
#   - absent cases: no worktree recorded, worktree recorded but no matching
#     directory, and a directory with zero top-level session files
#   - subagents/ subdirectories are excluded from the sum by design
#   - missing usage subfields (no cache_read/cache_creation keys) default to 0
#   - a malformed session file is skipped (data tolerance), a valid sibling
#     file in the same directory still contributes
#   - an OPERATIONAL jq failure on a session file (not a parse error) aborts
#     the run loudly instead of being silently tolerated (the mutation-
#     sensitive counterpart to the malformed-file-is-tolerated case above)
#   - an operational `find` failure listing a claude session directory aborts
#     the run loudly
#   - non-claude tasks are tallied under panels.tokens.unsupported, never
#     attempted as a join (M3+ scope)
#   - by_model token rollup across multiple claude tasks sharing a model
#   - Markdown Panel B renders the claude per-task table, by-model rollup, and
#     the not-yet-joinable harness tally
#   - FM_USAGE_CLAUDE_GRACE_HOURS rejects a non-numeric value
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
# r1) land in the unsupported tally (M2 does not join codex).
[ "$(jq -r '.panels.tokens.claude.tasks_total' "$J")" = 2 ] || fail "claude tasks_total"
[ "$(jq -r '.panels.tokens.claude.tasks_joined' "$J")" = 0 ] || fail "claude tasks_joined (no worktree in fixture)"
EXPECT_CBYTASK='[["t1","claude-opus-4-8","none","absent"],["t3","claude-opus-4-8","none","absent"]]'
GOT_CBYTASK=$(jq -c '[.panels.tokens.claude.by_task[]|[.task,.model,.join_method,.tokens_status]]' "$J")
[ "$GOT_CBYTASK" = "$EXPECT_CBYTASK" ] || fail "claude by_task: got $GOT_CBYTASK want $EXPECT_CBYTASK"
[ "$(jq -r '.panels.tokens.unsupported.tasks_total' "$J")" = 2 ] || fail "unsupported tasks_total"
EXPECT_UNSUP='[["codex",2]]'
GOT_UNSUP=$(jq -c '[.panels.tokens.unsupported.by_harness[]|[.harness,.count]]' "$J")
[ "$GOT_UNSUP" = "$EXPECT_UNSUP" ] || fail "unsupported by_harness: got $GOT_UNSUP want $EXPECT_UNSUP"
pass "tokens panel tallies claude tasks without a worktree as absent, codex as unsupported"

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
  cp_recompute=$(jq -S '{window, totals, model_mix: .panels.model_mix}' "$CSHARED/$cp_path" | sha256sum | cut -d' ' -f1)
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
# Slice M2 - Claude token joiner
# ============================================================================

# --- 19. happy path: single matched session, correct sums, high confidence --
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
[ "$(jq -r '.panels.tokens.claude.tasks_total' "$HPJ")" = 1 ] || fail "happy-path claude tasks_total"
[ "$(jq -r '.panels.tokens.claude.tasks_joined' "$HPJ")" = 1 ] || fail "happy-path claude tasks_joined"
EXPECT_HP='{"task":"happy1","model":"claude-opus-4-8","join_method":"claude_project_dir","tokens_status":"ok","confidence":"high","input_tokens":300,"output_tokens":130,"cache_read_tokens":30,"cache_write_tokens":13,"reasoning_tokens":null,"total_tokens":473,"sessions_matched":1}'
GOT_HP=$(jq -cS '.panels.tokens.claude.by_task[0]' "$HPJ")
[ "$GOT_HP" = "$(jq -cS . <<< "$EXPECT_HP")" ] || fail "happy-path by_task row: got $GOT_HP want $EXPECT_HP"
pass "claude happy path: encode+sum+time-filter yields tokens_status=ok, confidence=high"

# --- 20. session-file-level exclusion (worktree pool-reuse hazard) ----------
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
[ "$(jq -r '.panels.tokens.claude.by_task[0].sessions_matched' "$RJ")" = 1 ] || fail "reuse: only one session should match"
[ "$(jq -r '.panels.tokens.claude.by_task[0].total_tokens' "$RJ")" = 20 ] || fail "reuse: unrelated out-of-window session must not be summed"
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
[ "$(jq -r '.panels.tokens.claude.by_task[0].sessions_matched' "$BJ")" = 2 ] || fail "boundary: expected exactly the two inclusive-boundary sessions"
[ "$(jq -r '.panels.tokens.claude.by_task[0].input_tokens' "$BJ")" = 1 ] || fail "boundary: input tokens (lo_in only)"
[ "$(jq -r '.panels.tokens.claude.by_task[0].output_tokens' "$BJ")" = 1 ] || fail "boundary: output tokens (hi_in only)"
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
[ "$(jq -r '.panels.tokens.claude.by_task[0].sessions_matched' "$GJ")" = 2 ] || fail "default grace (2h) should include the +1h session"
[ "$(jq -r '.panels.tokens.claude.by_task[0].input_tokens' "$GJ")" = 505 ] || fail "default grace (2h) token sum"
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
[ "$(jq -r '.panels.tokens.claude.by_task[0].sessions_matched' "$GJ0")" = 1 ] || fail "zero grace should exclude the +1h session"
[ "$(jq -r '.panels.tokens.claude.by_task[0].input_tokens' "$GJ0")" = 5 ] || fail "zero grace token sum"
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
[ "$(jq -r '.panels.tokens.claude.by_task[0].tokens_status' "$UDJ")" = ambiguous_join ] || fail "undated claude task must be ambiguous_join"
[ "$(jq -r '.panels.tokens.claude.by_task[0].confidence' "$UDJ")" = low ] || fail "ambiguous_join confidence must be low"
[ "$(jq -r '.panels.tokens.claude.by_task[0].sessions_matched' "$UDJ")" = 2 ] || fail "undated claude task must sum every session unfiltered"
[ "$(jq -r '.panels.tokens.claude.by_task[0].input_tokens' "$UDJ")" = 30 ] || fail "undated claude token sum"
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
row_of() { jq -r --arg t "$1" --arg f "$2" '.panels.tokens.claude.by_task[] | select(.task==$t) | .[$f]' "$AJ"; }
[ "$(row_of noworktree tokens_status)" = absent ] || fail "no-worktree claude task must be absent"
[ "$(row_of noworktree join_method)" = none ] || fail "no-worktree join_method must be none"
[ "$(row_of nodir tokens_status)" = absent ] || fail "missing-directory claude task must be absent"
[ "$(row_of nodir join_method)" = claude_project_dir ] || fail "missing-directory join_method is still claude_project_dir (attempted)"
[ "$(row_of emptydir tokens_status)" = absent ] || fail "empty-directory claude task must be absent"
[ "$(row_of noworktree sessions_matched)" = 0 ] || fail "no-worktree sessions_matched must be 0"
[ "$(row_of nodir sessions_matched)" = 0 ] || fail "missing-directory sessions_matched must be 0"
[ "$(row_of emptydir sessions_matched)" = 0 ] || fail "empty-directory sessions_matched must be 0"
[ "$(jq -rc '[.panels.tokens.claude.by_task[]|.confidence]|unique' "$AJ")" = '["none"]' ] || fail "all three absent rows must carry confidence=none"
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
[ "$(jq -r '.panels.tokens.claude.by_task[0].input_tokens' "$SAJ")" = 7 ] || fail "subagents/ transcript must not be summed into the parent task"
[ "$(jq -r '.panels.tokens.claude.by_task[0].sessions_matched' "$SAJ")" = 1 ] || fail "only the top-level session file should be counted"
pass "a session's own subagents/ subtree is excluded from the sum"

# --- 29. missing usage subfields default to 0 --------------------------------
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
[ "$(jq -c '.panels.tokens.claude.by_task[0] | [.input_tokens,.output_tokens,.cache_read_tokens,.cache_write_tokens,.total_tokens]' "$MFJ")" = '[3,4,0,0,7]' ] \
  || fail "missing cache fields must default to 0, not error"
pass "a usage block missing cache fields defaults them to 0"

# --- 30. a malformed session file is tolerated; a valid sibling still counts
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
[ "$(jq -r '.panels.tokens.claude.by_task[0].tokens_status' "$MDJ")" = ok ] || fail "valid sibling session must still be joined"
[ "$(jq -r '.panels.tokens.claude.by_task[0].sessions_matched' "$MDJ")" = 1 ] || fail "malformed session must be skipped, not counted"
[ "$(jq -r '.panels.tokens.claude.by_task[0].input_tokens' "$MDJ")" = 5 ] || fail "malformed session must not corrupt the sum"
pass "a malformed session file is skipped; a valid sibling in the same directory still contributes"

# --- 31. an OPERATIONAL jq failure on a session file aborts loud (QA-style
# mutation-sensitive counterpart to test 30: this must NOT be silently
# tolerated the way a parse error is).
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
    *'ts_min'*) echo "injected operational jq failure" >&2; exit 66 ;;
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

# --- 32. an operational `find` failure listing a claude session directory
# aborts loud -------------------------------------------------------------
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

# --- 33. non-claude harnesses are tallied as unsupported, never attempted --
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
[ "$(jq -r '.panels.tokens.claude.tasks_total' "$NCJ")" = 0 ] || fail "no claude tasks in this fixture"
EXPECT_NC='[["gemini",1],["grok",1]]'
GOT_NC=$(jq -c '[.panels.tokens.unsupported.by_harness[]|[.harness,.count]]' "$NCJ")
[ "$GOT_NC" = "$EXPECT_NC" ] || fail "unsupported by_harness: got $GOT_NC want $EXPECT_NC"
pass "grok/gemini tasks are tallied as unsupported, no join attempted (M3+ scope)"

# --- 34. by_model rollup across multiple claude tasks sharing a model ------
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
  || fail "by_model run exited non-zero"
BMJ=$BMH/$OUT_SUB/latest.json
[ "$(jq -r '.panels.tokens.claude.by_model | length' "$BMJ")" = 1 ] || fail "by_model must roll both tasks into one model row"
GOT_BM=$(jq -c '.panels.tokens.claude.by_model[0] | [.model,.tasks,.tasks_joined,.input_tokens,.output_tokens,.total_tokens]' "$BMJ")
[ "$GOT_BM" = '["claude-opus-4-8",2,2,40,60,100]' ] || fail "by_model rollup: got $GOT_BM"
pass "by_model rolls up token sums across multiple claude tasks sharing a model"

# --- 35. Markdown Panel B renders the claude table, by-model rollup, and the
# not-yet-joinable harness tally --------------------------------------------
MDOWN=$HP/$OUT_SUB/latest.md
assert_grep "## Panel B - Tokens (partial)" "$MDOWN" "md Panel B header"
assert_grep "### Claude (join_method: claude_project_dir)" "$MDOWN" "md claude section header"
assert_grep "Joined 1/1 claude tasks." "$MDOWN" "md claude coverage line"
assert_grep "| happy1 | claude-opus-4-8 | ok | high | 300 | 130 | 30 | 13 | 473 |" "$MDOWN" "md claude per-task row"
assert_grep "#### By model" "$MDOWN" "md by-model header"
assert_grep "| claude-opus-4-8 | 1 | 1 | 300 | 130 | 30 | 13 | 473 |" "$MDOWN" "md by-model row"
assert_grep "### Not yet joinable" "$MDOWN" "md not-yet-joinable header"
pass "Markdown Panel B renders the claude per-task table, by-model rollup, and the unsupported tally"

echo "ok - fm-usage-report.test.sh"

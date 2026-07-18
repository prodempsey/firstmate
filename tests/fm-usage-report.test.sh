#!/usr/bin/env bash
# Behavior tests for bin/fm-usage-report.sh (Slice M1: model-mix reporting).
#
# Everything runs in mktemp sandboxes seeded with fixture metas and a fixture
# task-runs.jsonl; no test ever reads a live runtime home. Coverage:
#   - deterministic model-mix tables (harness/model/effort, kind, repo splits)
#   - live-meta / task-runs dedup (a still-live task counted once, meta wins)
#   - window filtering, including inclusive date-only bounds
#   - undated tasks (no timestamp) always included and counted
#   - routing-profile coverage (live meta only)
#   - confidence-label scaffolding for the not-yet-built token/spend/cf panels
#   - fingerprint determinism across a wall-clock change
#   - empty inputs still produce a valid report
#   - FM_STATE_OVERRIDE input scoping
#   - the accumulator survives a fleet larger than the argv limit
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
[ "$(jq -r '.slice' "$J")" = "M1" ] || fail "slice field"

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

# --- 3. confidence scaffolding for future slices ----------------------------
[ "$(jq -r '.panels.model_mix.confidence' "$J")" = high ] || fail "model_mix confidence"
for panel in tokens spend counterfactual; do
  [ "$(jq -r ".panels.$panel.status" "$J")" = not_implemented ] || fail "$panel status"
  [ "$(jq -r ".panels.$panel.confidence" "$J")" = none ] || fail "$panel confidence"
done
pass "token/spend/counterfactual panels are labeled scaffolding"

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

echo "ok - fm-usage-report.test.sh"

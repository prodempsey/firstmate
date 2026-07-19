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
#   - interval overlap: a task spanning the whole window is kept (QA finding 1)
#   - index.jsonl is physical JSON Lines, one object per line (QA finding 2)
#   - same-second archive runs do not overwrite each other (QA finding 3)
#   - CONCURRENT same-second runs each yield one correct immutable snapshot,
#     with agreeing json/md pairs and fingerprints that recompute (QA r2 f1)
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

echo "ok - fm-usage-report.test.sh"

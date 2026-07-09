#!/usr/bin/env bash
# Behavior tests for bin/fm-needs-firstmate-reconcile.sh - the read-only
# Needs FirstMate inbox enumerator.
#
# Coverage:
#   - empty home prints NEEDS_FIRSTMATE: none and exits 0
#   - done scout classifies as scout_report
#   - local-only ship "ready in branch" classifies as ready_to_land_local
#   - serving worktree reclassifies ready land as ready_to_land_serving
#   - pr checks-green classifies as pr_ready with captain_gate when yolo=off
#   - working: non-terminal status is excluded
#   - kind=secondmate is excluded
#   - --id filters to one task
#   - --json schema keys and counts
#   - SUPERSEDED backlog note reclassifies
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECONCILE="$ROOT/bin/fm-needs-firstmate-reconcile.sh"
TMP_ROOT=$(fm_test_tmproot fm-nf-reconcile)
fm_git_identity fmtest fmtest@example.invalid

new_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

run_nf() {
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$RECONCILE" "$@"
}

# --- tests ------------------------------------------------------------------

test_empty_home() {
  local home out status
  home=$(new_home empty)
  out=$(run_nf "$home" --digest)
  status=$?
  expect_code 0 "$status" "empty home should exit 0"
  assert_contains "$out" "NEEDS_FIRSTMATE: none" "empty home should print clear empty success"
  [ "$out" = "NEEDS_FIRSTMATE: none" ] || fail "empty digest should be exact one line, got: $out"
  pass "empty fleet prints NEEDS_FIRSTMATE: none"
}

test_done_scout() {
  local home out status
  home=$(new_home scout)
  mkdir -p "$home/data/scout-done-a1"
  printf '# findings\n' > "$home/data/scout-done-a1/report.md"
  fm_write_meta "$home/state/scout-done-a1.meta" \
    "window=firstmate:fm-scout-done-a1" \
    "worktree=$home/wt" \
    "project=demo" \
    "harness=claude" \
    "kind=scout" \
    "mode=no-mistakes" \
    "yolo=off"
  printf 'working: investigating\n' > "$home/state/scout-done-a1.status"
  printf 'done: report at data/scout-done-a1/report.md\n' >> "$home/state/scout-done-a1.status"

  out=$(run_nf "$home" --digest)
  status=$?
  expect_code 0 "$status" "done scout should exit 0"
  assert_contains "$out" "NEEDS_FIRSTMATE: 1 open" "done scout should be one open NF item"
  assert_contains "$out" "[scout_report" "done scout should classify as scout_report"
  assert_contains "$out" "scout-done-a1" "done scout id should appear"
  assert_contains "$out" "GATE: relay" "scout should suggest relay gate"

  out=$(run_nf "$home" --json)
  assert_contains "$out" '"schema": "fm-needs-firstmate-reconcile/v1"' "json schema marker"
  assert_contains "$out" '"class": "scout_report"' "json class scout_report"
  assert_contains "$out" '"captain_gate": false' "scout relay is not captain-gated for land"
  pass "done scout classifies as scout_report"
}

test_ready_local_only_ship() {
  local home out
  home=$(new_home local-ship)
  fm_write_meta "$home/state/land-me-b2.meta" \
    "window=firstmate:fm-land-me-b2" \
    "worktree=$home/wt-land" \
    "project=demo" \
    "harness=claude" \
    "kind=ship" \
    "mode=local-only" \
    "yolo=off"
  printf 'done: ready in branch fm/land-me-b2 @ abcdef1 (restart: no)\n' \
    > "$home/state/land-me-b2.status"

  out=$(run_nf "$home" --digest)
  assert_contains "$out" "NEEDS_FIRSTMATE: 1 open" "local-only ready should open NF"
  assert_contains "$out" "[ready_to_land_local" "should classify ready_to_land_local without serving"
  assert_contains "$out" "tip=abcdef1" "should extract tip from status"
  assert_contains "$out" "GATE: land" "should gate on land"
  assert_contains "$out" "yolo=off" "should show yolo=off"
  assert_contains "$out" "BATCH local-land:" "should batch local land items"

  out=$(run_nf "$home" --json)
  assert_contains "$out" '"class": "ready_to_land_local"' "json class"
  assert_contains "$out" '"captain_gate": true' "yolo=off land is captain-gated"
  assert_contains "$out" '"tip": "abcdef1"' "json tip"
  pass "ready local-only ship classifies as ready_to_land_local"
}

test_ready_with_serving() {
  local home serving out tip
  home=$(new_home serving-ship)
  serving="$TMP_ROOT/serving-repo"
  fm_git_init_commit "$serving"
  tip=$(git -C "$serving" rev-parse --short HEAD)

  fm_write_meta "$home/state/serve-land-c3.meta" \
    "window=firstmate:fm-serve-land-c3" \
    "worktree=$home/wt" \
    "project=fleet-bridge" \
    "harness=claude" \
    "kind=ship" \
    "mode=local-only" \
    "yolo=off"
  # Tip not in serving (made-up sha) so not already_live.
  printf 'done: ready in branch fm/serve-land-c3 @ deadbeef\n' \
    > "$home/state/serve-land-c3.status"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SERVING_WORKTREE="$serving" "$RECONCILE" --digest)
  assert_contains "$out" "[ready_to_land_serving" "with serving path should use serving class"
  assert_contains "$out" "BATCH serving-land:" "should batch under serving-land"

  # Tip that is the serving HEAD -> already_live
  printf 'done: ready in branch fm/already @ %s\n' "$tip" > "$home/state/serve-land-c3.status"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SERVING_WORKTREE="$serving" "$RECONCILE" --digest)
  assert_contains "$out" "[already_live" "tip ancestor of serving should be already_live"
  pass "serving path selects ready_to_land_serving and already_live"
}

test_pr_ready_yolo_off() {
  local home out
  home=$(new_home pr-ready)
  fm_write_meta "$home/state/pr-green-d4.meta" \
    "window=firstmate:fm-pr-green-d4" \
    "worktree=$home/wt" \
    "project=demo" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "pr=https://github.com/example/demo/pull/9"
  printf 'done: PR https://github.com/example/demo/pull/9 checks green\n' \
    > "$home/state/pr-green-d4.status"

  out=$(run_nf "$home" --digest)
  assert_contains "$out" "[pr_ready" "checks green should be pr_ready"
  assert_contains "$out" "GATE: merge" "pr_ready gates on merge"

  out=$(run_nf "$home" --json)
  assert_contains "$out" '"class": "pr_ready"' "json pr_ready"
  assert_contains "$out" '"captain_gate": true' "yolo=off PR merge gated"
  pass "pr checks green classifies as pr_ready captain-gated"
}

test_excludes_working_and_secondmate() {
  local home out
  home=$(new_home exclude)
  fm_write_meta "$home/state/still-work-e5.meta" \
    "window=firstmate:fm-still-work-e5" \
    "worktree=$home/wt1" \
    "project=demo" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  printf 'working: still implementing\n' > "$home/state/still-work-e5.status"

  fm_write_secondmate_meta "$home/state/domain-sm.meta" "$home/sm-home" "firstmate:fm-domain-sm" alpha
  printf 'done: idle\n' > "$home/state/domain-sm.status"

  out=$(run_nf "$home" --digest)
  assert_contains "$out" "NEEDS_FIRSTMATE: none" "working + secondmate should not open NF"
  pass "working and secondmate are excluded from NF"
}

test_id_filter() {
  local home out
  home=$(new_home id-filter)
  fm_write_meta "$home/state/one-f6.meta" \
    "window=firstmate:fm-one-f6" "project=demo" "harness=claude" \
    "kind=ship" "mode=local-only" "yolo=off"
  printf 'done: ready in branch fm/one-f6 @ 1111111\n' > "$home/state/one-f6.status"
  fm_write_meta "$home/state/two-f7.meta" \
    "window=firstmate:fm-two-f7" "project=demo" "harness=claude" \
    "kind=ship" "mode=local-only" "yolo=off"
  printf 'done: ready in branch fm/two-f7 @ 2222222\n' > "$home/state/two-f7.status"

  out=$(run_nf "$home" --id one-f6 --digest)
  assert_contains "$out" "one-f6" "filter should include one-f6"
  assert_not_contains "$out" "two-f7" "filter should exclude two-f7"
  assert_contains "$out" "NEEDS_FIRSTMATE: 1 open" "filter should report one"

  out=$(run_nf "$home" --id missing-xx --digest)
  assert_contains "$out" "NEEDS_FIRSTMATE: none" "missing id is empty success"
  pass "--id filters to a single task"
}

test_superseded_from_backlog() {
  local home out
  home=$(new_home supersede)
  fm_write_meta "$home/state/old-way-g8.meta" \
    "window=firstmate:fm-old-way-g8" "project=demo" "harness=claude" \
    "kind=ship" "mode=local-only" "yolo=off"
  printf 'done: ready in branch fm/old-way-g8 @ 3333333\n' > "$home/state/old-way-g8.status"
  cat > "$home/data/backlog.md" <<'MD'
## Done
- [x] old-way-g8 - earlier approach SUPERSEDED by new-way-h9
MD

  out=$(run_nf "$home" --digest)
  assert_contains "$out" "[superseded" "backlog SUPERSEDED should reclassify"
  assert_contains "$out" "GATE: clear" "superseded gates on clear"
  pass "SUPERSEDED backlog note reclassifies ready land"
}

test_json_counts() {
  local home out
  home=$(new_home counts)
  fm_write_meta "$home/state/a.meta" \
    "window=firstmate:fm-a" "project=demo" "harness=claude" \
    "kind=ship" "mode=local-only" "yolo=off"
  printf 'done: ready in branch fm/a @ aaaaaaa\n' > "$home/state/a.status"
  mkdir -p "$home/data/b"
  printf 'report\n' > "$home/data/b/report.md"
  fm_write_meta "$home/state/b.meta" \
    "window=firstmate:fm-b" "project=demo" "harness=claude" \
    "kind=scout" "mode=no-mistakes" "yolo=off"
  printf 'done: report ready\n' > "$home/state/b.status"

  out=$(run_nf "$home" --json)
  assert_contains "$out" '"total": 2' "two open items"
  assert_contains "$out" '"captain_gated": 1' "local land gated"
  assert_contains "$out" '"actionable_now": 1' "scout self-act"
  pass "json counts captain_gated vs actionable_now"
}

test_usage_error() {
  local status
  status=0
  "$RECONCILE" --not-a-flag >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "unknown flag should exit 2"
  pass "usage error exits 2"
}

test_empty_home
test_done_scout
test_ready_local_only_ship
test_ready_with_serving
test_pr_ready_yolo_off
test_excludes_working_and_secondmate
test_id_filter
test_superseded_from_backlog
test_json_counts
test_usage_error

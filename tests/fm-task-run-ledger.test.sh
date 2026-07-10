#!/usr/bin/env bash
# Behavior tests for the durable task-run ledger written by fm-teardown.sh.
# Every case runs against a scratch FM_HOME and uses isolated git repositories.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-run-ledger)
HOME_ROOT="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$HOME_ROOT/state" "$HOME_ROOT/data" "$HOME_ROOT/config" "$HOME_ROOT/projects" "$FAKEBIN"
printf '%s\n' manual > "$HOME_ROOT/config/backlog-backend"
fm_fake_exit0 "$FAKEBIN" tmux treehouse gh-axi gh

make_task() {
  local id=$1 include_spawned_at=${2:-yes} complete_meta=${3:-yes}
  local project="$HOME_ROOT/projects/$id" worktree="$TMP_ROOT/$id-wt"
  mkdir -p "$project"
  git -C "$project" init -q -b main
  printf '%s\n' "$id" > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git -C "$project" worktree add -q -b "fm/$id" "$worktree" main

  fm_write_meta "$HOME_ROOT/state/$id.meta" \
    "window=fakeses:fm-$id" \
    "worktree=$worktree" \
    "project=$project" \
    "kind=ship" \
    "mode=local-only"
  if [ "$complete_meta" = yes ]; then
    printf '%s\n' \
      'harness=claude' \
      'model=claude-sonnet-5' \
      'effort=high' \
      'provider=anthropic' >> "$HOME_ROOT/state/$id.meta"
  fi
  if [ "$include_spawned_at" = yes ]; then
    printf '%s\n' 'spawned_at=2026-07-10T12:00:00Z' >> "$HOME_ROOT/state/$id.meta"
  fi
}

run_teardown() {
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$HOME_ROOT" \
  PATH="$FAKEBIN:$PATH" \
    "$TEARDOWN" "$@"
}

assert_valid_ledger() {
  local ledger="$HOME_ROOT/state/task-runs.jsonl"
  jq -e . "$ledger" >/dev/null || fail "ledger contains malformed JSON"
  [ "$(tail -c 1 "$ledger" | od -An -t u1 | tr -d ' ')" = 10 ] \
    || fail "ledger is not newline-terminated"
}

reset_ledger() {
  rm -f "$HOME_ROOT/state/task-runs.jsonl" "$HOME_ROOT/state/task-runs.lock"
}

test_spawn_records_explicit_utc_start() {
  # shellcheck disable=SC2016  # This is a literal source line, not an expansion.
  grep -F 'echo "spawned_at=$(date -u '\''+%Y-%m-%dT%H:%M:%SZ'\'')"' "$SPAWN" >/dev/null \
    || fail "fm-spawn.sh does not record an explicit UTC spawned_at value in meta"
  pass "spawn records spawned_at as ISO-8601 UTC in task meta"
}

test_normal_teardown_appends_one_complete_record() {
  local id=ledger-normal-a1 ledger="$HOME_ROOT/state/task-runs.jsonl"
  reset_ledger
  make_task "$id"
  run_teardown "$id" >/dev/null 2> "$TMP_ROOT/$id.stderr" \
    || fail "normal teardown failed"

  [ "$(wc -l < "$ledger")" -eq 1 ] || fail "normal teardown did not append exactly one line"
  assert_valid_ledger
  jq -e --arg id "$id" \
    '.schema == "task_run/1" and .task == $id and .kind == "ship" and
     .project != null and .harness == "claude" and .model == "claude-sonnet-5" and
     .effort == "high" and .provider == "anthropic" and .branch == ("fm/" + $id) and
     .worktree != null and .spawned_at == "2026-07-10T12:00:00Z" and
     (.ended_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
     .outcome == "landed" and (has("spawned_at_estimated") | not)' "$ledger" >/dev/null \
    || fail "normal teardown record does not match task_run/1"
  assert_absent "$HOME_ROOT/state/$id.meta" "normal teardown left task meta behind"
  pass "normal teardown appends one complete, valid task_run/1 line"
}

test_force_records_forced_outcome() {
  local id=ledger-force-b2 ledger="$HOME_ROOT/state/task-runs.jsonl"
  reset_ledger
  make_task "$id"
  run_teardown "$id" --force >/dev/null 2> "$TMP_ROOT/$id.stderr" \
    || fail "forced teardown failed"

  assert_valid_ledger
  jq -e --arg id "$id" '.task == $id and .outcome == "forced"' "$ledger" >/dev/null \
    || fail "--force teardown did not record outcome=forced"
  pass "--force teardown records outcome=forced"
}

test_legacy_meta_uses_marked_ctime_estimate_and_nulls() {
  local id=ledger-legacy-c3 ledger="$HOME_ROOT/state/task-runs.jsonl"
  reset_ledger
  make_task "$id" no no
  run_teardown "$id" >/dev/null 2> "$TMP_ROOT/$id.stderr" \
    || fail "legacy-meta teardown failed"

  assert_valid_ledger
  jq -e --arg id "$id" \
    '.task == $id and .spawned_at_estimated == true and
     (.spawned_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
     .harness == null and .model == null and .effort == null and .provider == null' \
    "$ledger" >/dev/null \
    || fail "legacy meta did not record a marked ctime estimate and null absent fields"
  pass "legacy meta records a marked ctime estimate and null absent fields"
}

test_concurrent_teardowns_append_two_intact_lines() {
  local first=ledger-race-d4 second=ledger-race-e5 ledger="$HOME_ROOT/state/task-runs.jsonl"
  local first_pid second_pid first_rc second_rc
  reset_ledger
  make_task "$first"
  make_task "$second"

  run_teardown "$first" > "$TMP_ROOT/$first.stdout" 2> "$TMP_ROOT/$first.stderr" &
  first_pid=$!
  run_teardown "$second" > "$TMP_ROOT/$second.stdout" 2> "$TMP_ROOT/$second.stderr" &
  second_pid=$!
  wait "$first_pid"; first_rc=$?
  wait "$second_pid"; second_rc=$?
  expect_code 0 "$first_rc" "first concurrent teardown"
  expect_code 0 "$second_rc" "second concurrent teardown"

  [ "$(wc -l < "$ledger")" -eq 2 ] || fail "concurrent teardowns did not append exactly two lines"
  assert_valid_ledger
  jq -s -e --arg first "$first" --arg second "$second" \
    'length == 2 and ([.[].task] | sort) == ([$first, $second] | sort)' "$ledger" >/dev/null \
    || fail "concurrent teardown ledger records are missing or interleaved"
  pass "concurrent teardowns append two intact JSON lines under flock"
}

test_ledger_write_failure_warns_and_teardown_continues() {
  local id=ledger-failure-f6 ledger="$HOME_ROOT/state/task-runs.jsonl" rc
  reset_ledger
  mkdir "$ledger"
  make_task "$id"

  set +e
  run_teardown "$id" > "$TMP_ROOT/$id.stdout" 2> "$TMP_ROOT/$id.stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "ledger append failure must not fail teardown"
  assert_grep "warning: could not append task-run ledger record" "$TMP_ROOT/$id.stderr" \
    "ledger append failure did not warn"
  assert_absent "$HOME_ROOT/state/$id.meta" "ledger append failure prevented meta cleanup"
  rmdir "$ledger"
  pass "ledger write failure warns and does not fail teardown"
}

test_unlanded_and_dirty_work_still_refuse_without_logging() {
  local unlanded=ledger-refuse-g7 dirty=ledger-refuse-h8 rc
  reset_ledger
  make_task "$unlanded"
  git -C "$TMP_ROOT/$unlanded-wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m unlanded

  set +e
  run_teardown "$unlanded" > "$TMP_ROOT/$unlanded.stdout" 2> "$TMP_ROOT/$unlanded.stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "unlanded work refusal"
  assert_grep "REFUSED:" "$TMP_ROOT/$unlanded.stderr" "unlanded work did not refuse"
  assert_present "$HOME_ROOT/state/$unlanded.meta" "unlanded refusal removed task meta"
  assert_absent "$HOME_ROOT/state/task-runs.jsonl" "unlanded refusal wrote a ledger record"

  make_task "$dirty"
  printf '%s\n' dirty >> "$TMP_ROOT/$dirty-wt/README.md"
  set +e
  run_teardown "$dirty" > "$TMP_ROOT/$dirty.stdout" 2> "$TMP_ROOT/$dirty.stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "dirty work refusal"
  assert_grep "REFUSED:" "$TMP_ROOT/$dirty.stderr" "dirty work did not refuse"
  assert_present "$HOME_ROOT/state/$dirty.meta" "dirty refusal removed task meta"
  assert_absent "$HOME_ROOT/state/task-runs.jsonl" "dirty refusal wrote a ledger record"
  pass "unlanded and uncommitted work still refuse before ledger append"
}

test_spawn_records_explicit_utc_start
test_normal_teardown_appends_one_complete_record
test_force_records_forced_outcome
test_legacy_meta_uses_marked_ctime_estimate_and_nulls
test_concurrent_teardowns_append_two_intact_lines
test_ledger_write_failure_warns_and_teardown_continues
test_unlanded_and_dirty_work_still_refuse_without_logging

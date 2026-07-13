#!/usr/bin/env bash
# Tests for bin/fm-task-events.sh, the durable closeout writer teardown gates on.
#
# The close step must be self-healing without weakening the gate:
#   (a) no TaskRecord at all (tasks predating the visibility CLI) -> record, then close
#   (b) an already-terminal record WITH valid closure evidence    -> success; the durable
#                                                                    trail already exists
#   (c) no record and no obtainable evidence                      -> still fails closed
# The (b) success is gated on `visibility audit`: a terminal record whose closure evidence
# is missing or invalid, or an audit that cannot be read, must still fail closed.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-task-events)

# Build a sandbox for one case: a firstmate home with state/, plus a stateful fake
# visibility CLI that logs every invocation's argv (one call per line-group in $LOG).
# The fake's behavior is driven by env the test sets:
#   FM_FAKE_HAS_RECORD  - file whose existence means "the TaskRecord exists"
#   FM_FAKE_TERMINAL    - non-empty means the record is already terminal
#   FM_FAKE_AUDIT       - what `audit --json` prints (empty = print nothing)
# Echoes the case dir.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state"
  cat > "$case_dir/visibility.mjs" <<'JS'
#!/usr/bin/env node
import { appendFileSync, existsSync, writeFileSync } from 'node:fs';
const argv = process.argv.slice(2);
appendFileSync(process.env.FM_TEST_EVENT_LOG, `CALL ${argv.join(' ')}\n`);
const [command, id] = argv;
const home = argv.includes('--home') ? argv[argv.indexOf('--home') + 1] : 'default-home';
if (command === 'audit') {
  if (process.env.FM_FAKE_AUDIT) console.log(process.env.FM_FAKE_AUDIT);
  process.exit(0);
}
if (command === 'record') {
  writeFileSync(process.env.FM_FAKE_HAS_RECORD, 'recorded');
  console.log('{"id":"' + id + '"}');
  process.exit(0);
}
if (command === 'close') {
  if (!existsSync(process.env.FM_FAKE_HAS_RECORD)) {
    console.error(`✗ unknown task: ${home}/${id}`);
    process.exit(1);
  }
  if (process.env.FM_FAKE_TERMINAL) {
    console.error(`✗ terminal task cannot accept closure_evidence: ${home}/${id}`);
    process.exit(1);
  }
  console.log('{"status":"terminal"}');
  process.exit(0);
}
console.error(`✗ unknown command: ${command}`);
process.exit(1);
JS
  printf '%s\n' "$case_dir"
}

# Run the writer inside a case sandbox. Args: case_dir [writer args...]
run_events() {
  local case_dir=$1; shift
  FM_HOME="$case_dir" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_VISIBILITY_CLI="$case_dir/visibility.mjs" \
  FM_TEST_EVENT_LOG="$case_dir/args" \
  FM_FAKE_HAS_RECORD="$case_dir/recorded" \
  FM_FAKE_TERMINAL="${FM_FAKE_TERMINAL:-}" \
  FM_FAKE_AUDIT="${FM_FAKE_AUDIT:-}" \
    "$ROOT/bin/fm-task-events.sh" "$@"
}

test_close_delegates_to_visibility_cli() {
  local case_dir
  case_dir=$(make_case delegates)
  : > "$case_dir/recorded"
  fm_write_meta "$case_dir/state/task-a1.meta" "kind=ship" "mode=local-only"

  run_events "$case_dir" task-a1 landed outcome fm/task-a1 local-only deadbeef \
    || fail "delegates: writer should close a recorded task"
  assert_grep 'CALL close task-a1' "$case_dir/args" "writer should invoke close"
  assert_grep '--sha deadbeef' "$case_dir/args" "code closeout should include SHA evidence"
  assert_no_grep 'CALL record' "$case_dir/args" "an existing record must not be re-recorded"
  pass "task event writer delegates closure to visibility CLI"
}

test_unknown_task_is_recorded_then_closed() {
  local case_dir
  case_dir=$(make_case unknown-task)
  fm_write_meta "$case_dir/state/task-a1.meta" "kind=ship" "mode=local-only"

  run_events "$case_dir" task-a1 landed outcome fm/task-a1 local-only deadbeef \
    || fail "unknown-task: writer should backfill the missing record and close"
  assert_grep 'CALL record task-a1 task-a1' "$case_dir/args" "missing record should be backfilled"
  assert_grep '--status in_progress' "$case_dir/args" "backfill must use a valid non-terminal status"
  assert_grep "--kind ship" "$case_dir/args" "backfill should carry the task's real kind"
  assert_grep "--home unknown-task" "$case_dir/args" "record and close must agree on an explicit home"
  # The close must be retried AFTER the record, or the durable trail never lands.
  if [ "$(grep -c 'CALL close' "$case_dir/args")" -ne 2 ]; then
    fail "unknown-task: close should be retried once the record exists"
  fi
  pass "unknown task is recorded from its meta, then closed"
}

test_unknown_scout_task_is_recorded_with_its_kind() {
  local case_dir
  case_dir=$(make_case unknown-scout)
  fm_write_meta "$case_dir/state/task-a1.meta" "kind=scout" "mode=local-only"

  run_events "$case_dir" task-a1 reported outcome fm/task-a1 scout-report data/task-a1/report.md \
    || fail "unknown-scout: writer should backfill and close a scout task"
  assert_grep '--kind scout' "$case_dir/args" "backfill should carry kind=scout from meta"
  assert_grep '--report data/task-a1/report.md' "$case_dir/args" "scout closeout should carry report evidence"
  pass "unknown scout task is recorded with its own kind and report evidence"
}

test_terminal_record_with_valid_evidence_succeeds() {
  local case_dir
  case_dir=$(make_case terminal-valid)
  : > "$case_dir/recorded"
  fm_write_meta "$case_dir/state/task-a1.meta" "kind=ship" "mode=local-only"

  FM_FAKE_TERMINAL=1 FM_FAKE_AUDIT='{"ok":true,"diagnostics":[]}' \
    run_events "$case_dir" task-a1 landed outcome fm/task-a1 local-only deadbeef \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "terminal-valid: an already-closed record with valid evidence must succeed"
  assert_grep 'already closed' "$case_dir/stderr" "success should say the durable trail already exists"
  assert_grep 'CALL audit --json' "$case_dir/args" "the audit is what proves the evidence is valid"
  pass "already-terminal record with valid closure evidence closes out as success"
}

test_terminal_record_without_valid_evidence_fails_closed() {
  local case_dir rc=0
  case_dir=$(make_case terminal-invalid)
  : > "$case_dir/recorded"
  fm_write_meta "$case_dir/state/task-a1.meta" "kind=ship" "mode=local-only"

  FM_FAKE_TERMINAL=1 \
  FM_FAKE_AUDIT='{"ok":false,"diagnostics":[{"type":"invalid_closeout","recordId":"ship:task-a1","reason":"terminal record lacks closure evidence"}]}' \
    run_events "$case_dir" task-a1 landed outcome fm/task-a1 local-only deadbeef \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "a terminal record without valid evidence must not be waved through"
  assert_grep 'lacks valid closure evidence' "$case_dir/stderr" "refusal should name the missing evidence"
  pass "already-terminal record without valid closure evidence still fails closed"
}

test_unreadable_audit_fails_closed() {
  local case_dir rc=0
  case_dir=$(make_case audit-unreadable)
  : > "$case_dir/recorded"
  fm_write_meta "$case_dir/state/task-a1.meta" "kind=ship" "mode=local-only"

  # Audit prints nothing usable: the evidence is unverified, so teardown must not proceed.
  FM_FAKE_TERMINAL=1 FM_FAKE_AUDIT='not json' \
    run_events "$case_dir" task-a1 landed outcome fm/task-a1 local-only deadbeef \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "an unverifiable audit must fail closed"
  pass "unreadable audit leaves the closeout gate closed"
}

test_close_failure_still_fails_closed() {
  local case_dir rc=0
  case_dir=$(make_case close-failure)
  fm_write_meta "$case_dir/state/task-a1.meta" "kind=ship" "mode=local-only"
  printf '%s\n' '#!/usr/bin/env node' 'console.error("✗ boom"); process.exit(1);' > "$case_dir/visibility.mjs"

  run_events "$case_dir" task-a1 landed outcome fm/task-a1 local-only deadbeef \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "an unrecoverable close failure must still fail"
  assert_grep 'boom' "$case_dir/stderr" "the CLI's own error should reach the caller"
  pass "an unrecoverable closeout failure still fails closed"
}

test_close_delegates_to_visibility_cli
test_unknown_task_is_recorded_then_closed
test_unknown_scout_task_is_recorded_with_its_kind
test_terminal_record_with_valid_evidence_succeeds
test_terminal_record_without_valid_evidence_fails_closed
test_unreadable_audit_fails_closed
test_close_failure_still_fails_closed

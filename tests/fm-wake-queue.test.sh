#!/usr/bin/env bash
# tests/fm-wake-queue.test.sh - wake-queue losslessness (the queue safety matrix):
# concurrent append/drain, signal catch-up while no watcher runs, stale/check
# enqueue-before-suppressor ordering, atomic double-drain, duplicate collapse,
# and the drain-time watcher-liveness assertion.
# Nothing is lost and nothing is double-consumed. General watcher/lock liveness
# lives in fm-watcher-lock.test.sh; daemon classification/injection in
# fm-daemon.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-tests)


test_concurrent_append_and_drain() {
  local dir state out1 out2 all pids i pid count unique malformed
  dir=$(make_case concurrent)
  state="$dir/state"
  out1="$dir/drain-one.out"
  out2="$dir/drain-two.out"
  all="$dir/all.out"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    append_wake "$state" signal "status-$i" "signal: $state/status-$i.status" &
    pids="$pids $!"
    i=$((i + 1))
  done
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out1" &
  pids="$pids $!"
  for pid in $pids; do
    wait "$pid" || fail "concurrent append/drain subprocess failed"
  done
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out2" || fail "final drain failed"
  cat "$out1" "$out2" > "$all"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$all")
  [ "$count" -eq 40 ] || fail "expected 40 drained records, got $count"
  malformed=$(awk -F '\t' 'NF != 5 { bad++ } END { print bad + 0 }' "$all")
  [ "$malformed" -eq 0 ] || fail "drained records had malformed fields"
  unique=$(awk -F '\t' '{ keys[$4] = 1 } END { for (k in keys) count++; print count + 0 }' "$all")
  [ "$unique" -eq 40 ] || fail "expected 40 unique keys, got $unique"
  pass "concurrent append plus drain preserves queue records"
}

test_signal_catchup_without_running_watcher() {
  local dir state fakebin out drain_out status_file
  dir=$(make_case signal)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  status_file="$state/task.status"
  # The durable-queue catch-up contract applies to ACTIONABLE wakes (the always-on
  # watcher can absorb no-verb working: notes when the crew is provably working).
  # Use a captain-relevant verb so the wake is surfaced and the catch-up path is
  # tested.
  printf 'blocked: first\n' > "$status_file"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for first signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print first signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after first signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "first signal was not queued"

  printf 'done: second\n' >> "$status_file"
  : > "$out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for second signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "signal written with no watcher was not caught"
  pass "signal written while no watcher runs is caught on next run"
}

test_stale_enqueue_before_suppressor() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig
  dir=$(make_case stale)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  capture_file="$dir/pane.txt"
  window="test:fm-stale"
  printf 'idle prompt' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/stale.meta"
  # A stale pane sitting on a captain-relevant status is actionable when the crew
  # is not provably working, so give the window one and prime the .seen-* marker
  # to its current signature so the per-poll signal scan does not pre-empt the
  # stale wake with a signal wake.
  printf 'done: ready in branch fm/stale\n' > "$state/stale.status"
  if [ "$(uname)" = Darwin ]; then sig=$(stat -f '%z:%Fm' "$state/stale.status"); else sig=$(stat -c '%s:%Y' "$state/stale.status"); fi
  printf '%s' "$sig" > "$state/.seen-stale_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for stale pane"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print stale wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after stale wake failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "stale wake was not queued"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not written"
  pass "stale wake is queued before suppressor state is advanced"
}

# Absorb-only-when-provably-working adds a new actionable wake: a non-terminal stale
# whose crew is NOT provably working is surfaced immediately. That new path must keep
# the queue-safety invariant - enqueue the stale wake BEFORE advancing the .stale-*
# suppressor - so a watcher killed between the two never swallows the surfaced finish.
test_not_working_stale_enqueue_before_suppressor() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig
  dir=$(make_case stale-stopped)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  capture_file="$dir/pane.txt"
  window="test:fm-stopped"
  printf 'idle prompt, finished' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/stopped.meta"
  # Non-terminal status (no captain-relevant verb); prime .seen-* so the per-poll
  # signal scan does not pre-empt the stale path.
  printf 'working: implementing\n' > "$state/stopped.status"
  if [ "$(uname)" = Darwin ]; then sig=$(stat -f '%z:%Fm' "$state/stopped.status"); else sig=$(stat -c '%s:%Y' "$state/stopped.status"); fi
  printf '%s' "$sig" > "$state/.seen-stopped_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt, finished")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # NOT provably working: no running pipeline, idle pane. (make_case installed the
  # fake fm-crew-state.sh the watcher reads via FM_CREW_STATE_BIN.)
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not surface a not-provably-working stale"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print the immediate stale wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after the immediate stale wake failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "immediate stale wake was not queued"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not advanced after the enqueue"
  unset FM_FAKE_CREW_STATE
  pass "a not-provably-working stale wake is queued before its suppressor is advanced"
}

# A check that FAILS must not look like a check that wants to wake firstmate.
#
# It did: run_check threw the exit status away, so a broken check that printed its own
# error printed it on every sweep, woke the watcher every sweep, and the watcher exits
# on a wake - releasing state/.watch.lock each time. A single broken poll script took
# supervision down completely, every cycle, and the turn-end guard's entirely correct
# "no live watcher" block looked like a false alarm. These pin the failing check onto a
# distinct, rate-limited path so it can never do that again.

write_broken_check() {
  local check_file=$1 rc=$2 line=$3
  cat > "$check_file" <<SH
#!/usr/bin/env bash
# Prints a diagnostic, exactly as a broken check shim does, and fails.
printf '%s\n' '$line'
exit $rc
SH
  chmod +x "$check_file"
}

test_broken_check_is_reported_once_then_stops_waking() {
  local dir state fakebin out drain_out check_file marker i watcher_pid
  dir=$(make_case broken-check)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  check_file="$state/fleet-triage.check.sh"
  # Its stdout even LOOKS like a legitimate wake line - the only thing separating a
  # broken check from a real signal is the exit status, which is why it must be read.
  write_broken_check "$check_file" 126 'merged: https://example.test/pr/9'

  # First sweep: reported, once, and unmistakably as a failure rather than a signal.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 60 || fail "watcher did not surface the first failure of a broken check"
  grep -F 'BROKEN - exited 126' "$out" >/dev/null || fail "broken check was not reported as broken: $(cat "$out")"
  grep -F 'not a wake signal' "$out" >/dev/null || fail "the report did not say the output is not a wake signal: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after the broken-check report failed"
  grep -F 'BROKEN - exited 126' "$drain_out" >/dev/null || fail "the broken-check report was not queued durably"
  marker="$state/.check-error-fleet-triage_check_sh"
  [ -e "$marker" ] || fail "no loud-once marker was recorded for the broken check"

  # Every sweep after that: absorbed. The watcher must SURVIVE the broken check now -
  # this is the regression. Before the fix it died within one poll, over and over.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>/dev/null &
  watcher_pid=$!
  i=0
  while [ "$i" -lt 40 ]; do
    is_live_non_zombie "$watcher_pid" || break
    sleep 0.1
    i=$((i + 1))
  done
  if ! is_live_non_zombie "$watcher_pid"; then
    fail "the watcher exited again on an already-reported broken check (supervision collapse): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "an already-reported broken check woke firstmate again: $(cat "$out")"
  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true
  pass "a broken check is reported once and then absorbed - it can never wake the watcher every cycle"
}

test_silent_nonzero_check_is_not_treated_as_broken() {
  local dir state fakebin out check_file marker watcher_pid i
  dir=$(make_case silent-nonzero-check)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  check_file="$state/task.check.sh"
  marker="$state/.check-error-task_check_sh"
  # The shape bin/fm-pr-check.sh generates: `[ "$state" = MERGED ] && echo merged`
  # exits 1 exactly when the PR is NOT merged, i.e. on its normal silent path. A
  # working check must never be condemned as broken for that - and it cannot wake
  # anyone anyway, because the wake is carried by the output, and there is none.
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
state=not-merged
[ "$state" = "MERGED" ] && echo "merged"
SH
  chmod +x "$check_file"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>/dev/null &
  watcher_pid=$!
  i=0
  while [ "$i" -lt 30 ]; do
    is_live_non_zombie "$watcher_pid" || break
    sleep 0.1
    i=$((i + 1))
  done
  if ! is_live_non_zombie "$watcher_pid"; then
    fail "the watcher woke on a silent non-zero check that had nothing to report: $(cat "$out")"
  fi
  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true
  [ ! -s "$out" ] || fail "a silent non-zero check produced a wake: $(cat "$out")"
  [ ! -e "$marker" ] || fail "a working check on its silent path was recorded as broken"
  pass "a check that exits non-zero with nothing to say is silent, not broken"
}

test_broken_check_resurfaces_when_the_failure_changes() {
  local dir state fakebin out check_file
  dir=$(make_case broken-check-changed)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  check_file="$state/task.check.sh"
  write_broken_check "$check_file" 1 'boom'
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 60 || fail "watcher did not surface the first failure"
  grep -F 'BROKEN - exited 1' "$out" >/dev/null || fail "first failure was not reported"

  # Silencing is per failure, not per check: a check that starts failing a NEW way is
  # news again, well inside the cooldown.
  write_broken_check "$check_file" 127 'command not found'
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 60 || fail "watcher did not surface a CHANGED failure within the cooldown"
  grep -F 'BROKEN - exited 127' "$out" >/dev/null || fail "the changed failure was not reported: $(cat "$out")"
  pass "a broken check that starts failing differently is reported again, not silenced"
}

test_recovered_check_wakes_normally_again() {
  local dir state fakebin out check_file marker
  dir=$(make_case recovered-check)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  check_file="$state/task.check.sh"
  marker="$state/.check-error-task_check_sh"
  write_broken_check "$check_file" 1 'boom'
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 60 || fail "watcher did not surface the failure"
  [ -e "$marker" ] || fail "no loud-once marker was recorded"

  # Fixed: it exits 0 and prints a real signal, which must wake firstmate exactly as
  # before - suppression applies to the FAILURE, never to a working check's signal.
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'merged: https://example.test/pr/3\n'
SH
  chmod +x "$check_file"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 60 || fail "watcher did not wake for a recovered check's real signal"
  grep -F "check: $check_file: merged: https://example.test/pr/3" "$out" >/dev/null || fail "recovered check's signal was not surfaced as a normal wake: $(cat "$out")"
  ! grep -qF 'BROKEN' "$out" || fail "a working check was still reported as broken"
  [ ! -e "$marker" ] || fail "the loud-once marker was not cleared when the check recovered"
  pass "a check that recovers wakes normally again and its failure marker is cleared"
}

test_check_output_is_queued() {
  local dir state fakebin out drain_out check_file
  dir=$(make_case check)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  check_file="$state/task.check.sh"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'merged: https://example.test/pr/1\n'
SH
  chmod +x "$check_file"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for check output"
  grep -F "check: $check_file: merged: https://example.test/pr/1" "$out" >/dev/null || fail "watcher did not print check wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after check wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "$check_file" | grep -F 'merged: https://example.test/pr/1' >/dev/null || fail "check wake was not queued"
  [ -e "$state/.last-check" ] || fail "check cadence marker was not written after queue append"
  pass "check output is queued before cadence suppression"
}

test_atomic_double_drain() {
  local dir state out1 out2 all count leftover
  dir=$(make_case double-drain)
  state="$dir/state"
  out1="$dir/drain-one.out"
  out2="$dir/drain-two.out"
  all="$dir/all.out"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "heartbeat append failed"
  append_wake "$state" signal task "signal: $state/task.status" || fail "signal append failed"
  append_wake "$state" stale 's:fm-task' 'stale: s:fm-task' || fail "stale append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out1" &
  pid1=$!
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out2" &
  pid2=$!
  wait "$pid1" || fail "first drain failed"
  wait "$pid2" || fail "second drain failed"
  cat "$out1" "$out2" > "$all"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$all")
  [ "$count" -eq 3 ] || fail "two drains consumed records more than once or lost records; got $count"
  leftover=$(FM_STATE_OVERRIDE="$state" "$DRAIN" | awk 'NF { count++ } END { print count + 0 }')
  [ "$leftover" -eq 0 ] || fail "queue was not empty after double drain"
  pass "two atomic drains cannot consume the same records twice"
}

test_drain_dedupes_obvious_duplicates() {
  local dir state out count
  dir=$(make_case dedupe)
  state="$dir/state"
  out="$dir/drain.out"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "first heartbeat append failed"
  append_wake "$state" signal task.status "signal: $state/task.status" || fail "first signal append failed"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "second heartbeat append failed"
  append_wake "$state" signal task.status "signal: $state/task.status $state/task.turn-ended" || fail "second signal append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "dedupe drain failed"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$out")
  [ "$count" -eq 2 ] || fail "expected 2 deduped records, got $count"
  grep "$(printf '\theartbeat\theartbeat\theartbeat')" "$out" >/dev/null || fail "heartbeat was not preserved"
  grep "$(printf '\tsignal\ttask.status\t')" "$out" | grep -F "$state/task.turn-ended" >/dev/null || fail "latest signal payload was not preserved"
  pass "drain collapses obvious duplicate heartbeat and signal records"
}

# The drain runs at the top of every wake-handling turn, so it also asserts
# watcher liveness via fm-guard.sh: a lapsed re-arm chain then surfaces even on a
# plain drain-and-handle turn that runs no other supervision script. It must warn
# when work is in flight with no live watcher, and stay silent right after a
# normal fire (a fresh beacon within grace), so it never false-alarms every wake.
test_drain_asserts_watcher_liveness() {
  local dir state err
  dir=$(make_case drain-liveness)
  state="$dir/state"
  err="$dir/drain.err"
  printf 'window=test:fm-x\nkind=ship\n' > "$state/x.meta"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || fail "drain failed while asserting liveness"
  grep -F 'WATCHER DOWN' "$err" >/dev/null || fail "drain did not surface the watcher-down banner with work in flight and no live watcher"
  : > "$err"
  touch "$state/.last-watcher-beat"
  FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 "$DRAIN" >/dev/null 2> "$err" || fail "drain failed with a fresh beacon"
  if grep -F 'WATCHER DOWN' "$err" >/dev/null; then
    fail "drain false-alarmed right after a normal fire (fresh beacon within grace)"
  fi
  pass "drain asserts watcher liveness: warns on a lapse, stays silent right after a fire"
}

test_concurrent_append_and_drain
test_signal_catchup_without_running_watcher
test_stale_enqueue_before_suppressor
test_not_working_stale_enqueue_before_suppressor
test_check_output_is_queued
test_broken_check_is_reported_once_then_stops_waking
test_silent_nonzero_check_is_not_treated_as_broken
test_broken_check_resurfaces_when_the_failure_changes
test_recovered_check_wakes_normally_again
test_atomic_double_drain
test_drain_dedupes_obvious_duplicates
test_drain_asserts_watcher_liveness

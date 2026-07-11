#!/usr/bin/env bash
# tests/fm-triage-duty.test.sh - the fleet-triage duty banner and its call sites.
#
# The duty banner is the Phase-2 wiring that makes the triage ledger consulted at
# every fleet-state change instead of only at session start. What has to hold:
# it fires for the locked primary at each trigger, it stays silent for everyone
# who does not owe the duty (no lock, away mode, kill switch), it never touches a
# caller's stdout or exit status, and it never enumerates or writes anything.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DUTY="$ROOT/bin/fm-triage-duty.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-triage-duty)

# A home whose session lock this test process owns: fm_triage_owns_lock walks the
# caller's process ancestry looking for the lock's PID, and the script under test
# is our child, so writing our own PID makes this the locked primary. Each case gets
# its own home - make_home runs in a command substitution, so a shared counter would
# increment in the subshell and hand every case the same directory.
make_home() {
  local dir
  mkdir -p "$TMP_ROOT"
  dir=$(mktemp -d "$TMP_ROOT/case.XXXXXX")
  mkdir -p "$dir/state" "$dir/data"
  printf '%s\n' "$$" > "$dir/state/.lock"
  printf '%s\n' "$dir"
}

run_duty() {  # <home> <args...>
  local home=$1
  shift
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" "$DUTY" "$@" 2>&1
}

test_banner_fires_for_each_trigger() {
  local home out trigger
  home=$(make_home)
  for trigger in wake-drain heartbeat ship-complete scout-complete teardown; do
    out=$(run_duty "$home" "$trigger") || fail "duty exited non-zero for trigger $trigger"
    assert_contains "$out" 'FLEET TRIAGE DUTY' "no banner for trigger $trigger"
    assert_contains "$out" 'bin/fm-fleet-triage.sh --digest' "trigger $trigger did not name the enumerator"
    assert_contains "$out" 'bin/fm-fleet-triage-record.sh' "trigger $trigger did not name the ledger writer"
  done
  pass "duty banner fires for every script-emitted trigger"
}

test_scope_differs_between_targeted_and_full_triggers() {
  local home wake heart
  home=$(make_home)
  wake=$(run_duty "$home" wake-drain)
  heart=$(run_duty "$home" heartbeat)
  assert_contains "$wake" 'targeted' "an ordinary drained wake did not ask for a targeted pass"
  assert_not_contains "$wake" 'full (every lane)' "an ordinary drained wake demanded a full pass"
  assert_contains "$heart" 'full (every lane)' "a heartbeat did not ask for a full pass"
  pass "pass scope tracks the trigger"
}

test_detail_is_surfaced() {
  local home out
  home=$(make_home)
  out=$(run_duty "$home" teardown --detail 'fix-login-k3 torn down.')
  assert_contains "$out" 'fix-login-k3 torn down.' "duty banner dropped its --detail line"
  pass "duty banner surfaces the caller's detail"
}

test_silent_without_the_session_lock() {
  local home out rc
  home=$(make_home)
  rm -f "$home/state/.lock"
  out=$(run_duty "$home" teardown)
  rc=$?
  expect_code 0 "$rc" "duty without a lock"
  [ -z "$out" ] || fail "duty printed a banner for a session that does not own the lock: $out"

  # A live lock held by someone else (PID 1 is alive and is never our ancestor)
  # is the read-only-session case: still silent, because triage belongs to the
  # session holding the fleet lock.
  printf '1\n' > "$home/state/.lock"
  out=$(run_duty "$home" teardown)
  [ -z "$out" ] || fail "duty printed a banner for a read-only session: $out"
  pass "duty is silent for a session that does not own the fleet lock"
}

test_silent_while_away() {
  local home out
  home=$(make_home)
  : > "$home/state/.afk"
  out=$(run_duty "$home" teardown)
  [ -z "$out" ] || fail "duty printed a banner while the away daemon owns supervision: $out"
  pass "duty is silent while state/.afk exists"
}

test_kill_switch_silences_the_banner() {
  local home out
  home=$(make_home)
  out=$(FM_TRIAGE_DUTY=off FM_STATE_OVERRIDE="$home/state" "$DUTY" teardown 2>&1)
  [ -z "$out" ] || fail "FM_TRIAGE_DUTY=off did not silence the banner: $out"
  pass "FM_TRIAGE_DUTY=off silences the banner"
}

test_enumerate_only_mode_is_declared() {
  local home out
  home=$(make_home)
  out=$(FLEET_TRIAGE_MODE=enumerate_only FM_STATE_OVERRIDE="$home/state" "$DUTY" teardown 2>&1)
  assert_contains "$out" 'FLEET TRIAGE DUTY' "enumerate_only suppressed the banner; it should still enumerate and report"
  assert_contains "$out" 'enumerate_only' "banner did not declare the kill switch under enumerate_only"
  pass "enumerate_only still prompts the pass but declares that writes are refused"
}

test_unknown_trigger_fails_loudly() {
  local home out rc
  home=$(make_home)
  out=$(run_duty "$home" not-a-trigger)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unknown trigger exited 0; a caller typo must not pass silently"
  assert_contains "$out" 'unknown trigger' "unknown trigger did not say so"
  assert_not_contains "$out" 'FLEET TRIAGE DUTY' "unknown trigger printed a banner anyway"

  out=$(run_duty "$home")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a missing trigger exited 0"
  pass "an unknown or missing trigger fails loudly instead of printing an unactionable banner"
}

test_banner_never_pollutes_stdout() {
  local home stdout
  home=$(make_home)
  stdout=$(FM_STATE_OVERRIDE="$home/state" "$DUTY" teardown 2>/dev/null)
  [ -z "$stdout" ] || fail "duty wrote to stdout; a caller's parseable output must stay byte-identical: $stdout"
  pass "the banner goes to stderr only"
}

test_duty_writes_no_ledger() {
  local home
  home=$(make_home)
  run_duty "$home" teardown >/dev/null
  assert_absent "$home/data/fleet-triage.jsonl" "the duty banner wrote to the triage ledger; it must only prompt, never record"
  pass "the duty banner records nothing"
}

# --- call sites -------------------------------------------------------------

test_wake_drain_prompts_the_duty_and_keeps_records_clean() {
  local home stdout stderr
  home=$(make_home)
  printf '%s\t%s\t%s\t%s\t%s\n' 100 1 signal task-a 'signal: task-a blocked' > "$home/state/.wake-queue"
  stdout="$home/drain.out"
  stderr="$home/drain.err"
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" "$DRAIN" > "$stdout" 2> "$stderr" \
    || fail "drain failed"

  assert_grep 'FLEET TRIAGE DUTY' "$stderr" "wake drain did not prompt the triage duty for a drained wake"
  assert_grep 'targeted' "$stderr" "an ordinary drained wake did not ask for a targeted pass"
  # The record lines are parsed as 5 tab-separated fields; a banner on stdout would
  # corrupt every consumer of the drain.
  awk -F '\t' 'NF != 5 { bad = 1 } END { exit bad + 0 }' "$stdout" \
    || fail "drain stdout carried non-record lines; the banner must go to stderr"
  pass "wake drain prompts the duty on stderr without touching its record output"
}

test_drained_heartbeat_asks_for_a_full_pass() {
  local home stderr
  home=$(make_home)
  {
    printf '%s\t%s\t%s\t%s\t%s\n' 100 1 signal task-a 'signal: task-a done'
    printf '%s\t%s\t%s\t%s\t%s\n' 101 2 heartbeat fleet 'heartbeat: review the fleet'
  } > "$home/state/.wake-queue"
  stderr="$home/drain.err"
  FM_STATE_OVERRIDE="$home/state" "$DRAIN" >/dev/null 2> "$stderr" || fail "drain failed"
  assert_grep 'HEARTBEAT WAKE REACHED THE AGENT' "$stderr" "a drained heartbeat did not escalate to the heartbeat trigger"
  assert_grep 'full (every lane)' "$stderr" "a drained heartbeat did not ask for a full pass"
  pass "a drained heartbeat escalates the duty to a full pass"
}

test_empty_drain_is_silent() {
  local home stderr
  home=$(make_home)
  : > "$home/state/.wake-queue"
  stderr="$home/drain.err"
  FM_STATE_OVERRIDE="$home/state" "$DRAIN" >/dev/null 2> "$stderr" || fail "empty drain failed"
  assert_no_grep 'FLEET TRIAGE DUTY' "$stderr" "an empty drain prompted the duty; nothing changed, so nothing is owed"
  pass "an empty drain prompts no duty"
}

test_local_only_merge_prompts_the_duty() {
  # A local-only merge is a ship completion with no PR and no CI, so it is the only
  # moment that work lands. fm-pr-merge's own suite covers the PR path; this covers
  # the path that has no other suite.
  local home stderr
  home=$(make_home)
  fm_git_worktree "$home/project" "$home/wt" fm/task-x1
  git -C "$home/project" branch -M main 2>/dev/null || true
  printf 'work\n' > "$home/wt/f.txt"
  git -C "$home/wt" add f.txt
  git -C "$home/wt" -c user.email=t@t -c user.name=t commit -qm work
  fm_write_meta "$home/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$home/wt" "project=$home/project" "kind=ship" "mode=local-only"

  stderr="$home/merge.err"
  FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-merge-local.sh" task-x1 > "$home/merge.out" 2> "$stderr" \
    || fail "local-only merge failed"
  assert_grep 'FLEET TRIAGE DUTY - SHIP WORK LANDED' "$stderr" \
    "a local-only merge did not prompt the fleet-triage duty"
  assert_no_grep 'FLEET TRIAGE DUTY' "$home/merge.out" \
    "the duty banner reached fm-merge-local's stdout; it must stay on stderr"
  pass "a local-only merge prompts the fleet-triage duty"
}

test_banner_fires_at_every_wired_call_site() {
  # Guards the wiring itself: the four scripts that change fleet state must all
  # reach fm-triage-duty.sh. A call site deleted in a refactor is exactly the
  # regression this phase exists to prevent, and it is invisible in their own
  # behavior tests.
  local script
  for script in fm-wake-drain.sh fm-teardown.sh fm-pr-merge.sh fm-merge-local.sh; do
    grep -F 'fm-triage-duty.sh' "$ROOT/bin/$script" >/dev/null \
      || fail "$script no longer prompts the fleet-triage duty"
  done
  pass "every wired call site still prompts the fleet-triage duty"
}

test_banner_fires_for_each_trigger
test_scope_differs_between_targeted_and_full_triggers
test_detail_is_surfaced
test_silent_without_the_session_lock
test_silent_while_away
test_kill_switch_silences_the_banner
test_enumerate_only_mode_is_declared
test_unknown_trigger_fails_loudly
test_banner_never_pollutes_stdout
test_duty_writes_no_ledger
test_wake_drain_prompts_the_duty_and_keeps_records_clean
test_drained_heartbeat_asks_for_a_full_pass
test_empty_drain_is_silent
test_local_only_merge_prompts_the_duty
test_banner_fires_at_every_wired_call_site

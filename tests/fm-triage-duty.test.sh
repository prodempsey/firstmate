#!/usr/bin/env bash
# tests/fm-triage-duty.test.sh - the fleet-triage duty pass and its call sites.
#
# Phase 2B load-bearing property: the duty is PROVEN, not just prompted. It runs the
# real read-only enumerator for the trigger's scope and prints a banner ONLY when that
# pass actually finds actionable state - a clear fleet stays exactly as silent as any
# other healthy diagnostic in this codebase. What has to hold: it fires for the locked
# primary at each of the eleven named triggers when (and only when) something is
# actionable, it stays silent for everyone who does not owe the duty (no lock, away
# mode, kill switch) regardless of what is actionable, it never touches a caller's
# stdout or exit status, it never writes the outcome ledger, it surfaces its own
# machine-readable pass result (trigger, scope, actionable, ownerless, unhealthy,
# captain_gated, fingerprint) in both the banner and a volatile state cache, and an
# enumerator crash is a visible FAILED finding rather than indistinguishable silence.
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
# increment in the subshell and hand every case the same directory. mkdir -p on
# TMP_ROOT itself guards against fm_test_tmproot's own EXIT trap firing at the end of
# ITS OWN command-substitution subshell and removing the directory before this
# function's nested mktemp gets to use it as a parent.
make_home() {
  local dir
  mkdir -p "$TMP_ROOT"
  dir=$(mktemp -d "$TMP_ROOT/case.XXXXXX")
  mkdir -p "$dir/state" "$dir/data"
  printf '%s\n' "$$" > "$dir/state/.lock"
  printf '%s\n' "$dir"
}

# One ready, unblocked queued backlog row - the cheapest fixture that lands in the
# backlog_hygiene lane as `actionable`, `ownerless` (nothing has claimed it), and
# FIRSTMATE_JUDGMENT-class (never captain-gated) real enumerator output.
seed_actionable() {  # <home>
  cat > "$1/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] ready-q1 - Ready queued work (repo: demo)

## Done
EOF
}

run_duty() {  # <home> <args...>
  local home=$1
  shift
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_FLEET_TRIAGE_BUG_CLI=off "$DUTY" "$@" 2>&1
}

cache_of() {  # <home>
  printf '%s/state/.triage-duty-last.json\n' "$1"
}

test_silent_when_nothing_actionable() {
  local home out rc
  home=$(make_home)
  out=$(run_duty "$home" teardown)
  rc=$?
  expect_code 0 "$rc" "duty on a clear fleet"
  [ -z "$out" ] || fail "duty printed a banner with nothing actionable: $out"
  [ "$(jq -r '.ok' "$(cache_of "$home")")" = true ] \
    || fail "a clear pass should still cache ok:true"
  [ "$(jq -r '.actionable' "$(cache_of "$home")")" -eq 0 ] \
    || fail "a clear pass should cache actionable:0"
  pass "a clear fleet stays silent, proven by an ok:true/actionable:0 cache, not just assumed"
}

test_banner_fires_for_each_trigger_only_when_actionable() {
  local home out trigger
  for trigger in wake-drain heartbeat ship-complete scout-complete teardown \
    session-start recovery backlog-mutation bug-mutation blocker-freed afk-exit; do
    home=$(make_home)
    seed_actionable "$home"
    out=$(run_duty "$home" "$trigger") || fail "duty exited non-zero for trigger $trigger"
    assert_contains "$out" 'FLEET TRIAGE DUTY' "no banner for trigger $trigger with actionable state present"
    assert_contains "$out" 'TRIAGE_DUTY_RESULT:' "trigger $trigger did not expose the machine-readable pass result"
    assert_contains "$out" "\"trigger\":\"$trigger\"" "trigger $trigger's result did not name itself"
    assert_contains "$out" 'bin/fm-fleet-triage-record.sh' "trigger $trigger did not name the ledger writer"
    assert_contains "$out" 'ready-q1' "trigger $trigger's banner did not surface the actionable item"
  done
  pass "duty banner fires for every named trigger, but only because actionable state was present"
}

test_scope_differs_between_targeted_and_full_triggers() {
  local home wake heart
  home=$(make_home)
  seed_actionable "$home"
  wake=$(run_duty "$home" wake-drain)
  heart=$(run_duty "$home" heartbeat)
  assert_contains "$wake" 'targeted' "an ordinary drained wake did not ask for a targeted pass"
  assert_not_contains "$wake" 'full (every lane)' "an ordinary drained wake demanded a full pass"
  assert_contains "$wake" '"scope":"targeted"' "wake-drain's machine-readable result did not record scope=targeted"
  assert_contains "$heart" 'full (every lane)' "a heartbeat did not ask for a full pass"
  assert_contains "$heart" '"scope":"full"' "heartbeat's machine-readable result did not record scope=full"
  pass "pass scope tracks the trigger, in both the prose and the machine-readable result"
}

test_detail_is_surfaced() {
  local home out
  home=$(make_home)
  seed_actionable "$home"
  out=$(run_duty "$home" teardown --detail 'fix-login-k3 torn down.')
  assert_contains "$out" 'fix-login-k3 torn down.' "duty banner dropped its --detail line"
  pass "duty banner surfaces the caller's detail when it fires"
}

test_silent_without_the_session_lock() {
  local home out rc
  home=$(make_home)
  seed_actionable "$home"
  rm -f "$home/state/.lock"
  out=$(run_duty "$home" teardown)
  rc=$?
  expect_code 0 "$rc" "duty without a lock"
  [ -z "$out" ] || fail "duty printed a banner for a session that does not own the lock: $out"
  assert_absent "$(cache_of "$home")" "a lockless session must not write the result cache either"

  # A live lock held by someone else (PID 1 is alive and is never our ancestor)
  # is the read-only-session case: still silent, because triage belongs to the
  # session holding the fleet lock. Silence here holds regardless of actionable
  # content, which is exactly what proves this is a lock check, not a "nothing to
  # report" coincidence.
  printf '1\n' > "$home/state/.lock"
  out=$(run_duty "$home" teardown)
  [ -z "$out" ] || fail "duty printed a banner for a read-only session: $out"
  pass "duty is silent for a session that does not own the fleet lock, even with actionable state present"
}

test_silent_while_away() {
  local home out
  home=$(make_home)
  seed_actionable "$home"
  : > "$home/state/.afk"
  out=$(run_duty "$home" teardown)
  [ -z "$out" ] || fail "duty printed a banner while the away daemon owns supervision: $out"
  assert_absent "$(cache_of "$home")" "away mode must not write the result cache either"
  pass "duty is silent while state/.afk exists, even with actionable state present"
}

test_kill_switch_silences_everything() {
  local home out
  home=$(make_home)
  seed_actionable "$home"
  out=$(FM_TRIAGE_DUTY=off FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" "$DUTY" teardown 2>&1)
  [ -z "$out" ] || fail "FM_TRIAGE_DUTY=off did not silence the banner: $out"
  assert_absent "$(cache_of "$home")" "FM_TRIAGE_DUTY=off must run NOTHING, including the result cache write"
  pass "FM_TRIAGE_DUTY=off silences the banner and skips enumeration entirely"
}

# Point 7 fix: the two switches must be tested in isolation from each other. The old
# version of this case ran enumerate_only against an EMPTY fleet, so "no banner"
# proved nothing about the mode - an empty fleet stays silent regardless of mode. That
# conflated "enumerate_only suppressed the banner" with "nothing was actionable",
# which is exactly the contradictory description point 7 asked to correct. This
# version isolates the variable: seeded actionable state under enumerate_only must
# still produce a banner (mode never suppresses reporting), and a companion clear-fleet
# case under the SAME mode must stay silent (silence there is about content, not mode).
test_enumerate_only_reports_but_refuses_writes_clear_fleet_stays_silent_regardless() {
  local home out
  home=$(make_home)
  seed_actionable "$home"
  out=$(FLEET_TRIAGE_MODE=enumerate_only run_duty "$home" teardown)
  assert_contains "$out" 'FLEET TRIAGE DUTY' \
    "enumerate_only must not suppress a banner that actionable state would otherwise produce"
  assert_contains "$out" 'enumerate_only' "banner did not declare the report-only mode"
  assert_contains "$out" 'every ledger' "banner did not explain that ledger writes and domain actions are refused"

  home=$(make_home)
  out=$(FLEET_TRIAGE_MODE=enumerate_only run_duty "$home" teardown)
  [ -z "$out" ] || fail "a clear fleet under enumerate_only printed a banner anyway: $out"
  pass "enumerate_only reports normally (banner fires when actionable) and never explains an unrelated silent, clear fleet"
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
  pass "an unknown or missing trigger fails loudly instead of running an unactionable pass"
}

# The captain-order digest line and the duty banner were built on separate branches
# against separate renderings of the same enumeration, so the one thing that can silently
# regress here is the captain-order line surviving in only ONE of them. It lives in
# fm_triage_render_digest (fm-fleet-triage-lib.sh), which both callers share, so both must
# lead with it while the fleet ALSO has ordinary actionable work of its own: an unanswered
# captain request outranks that housekeeping, and neither presentation may drop it.
test_captain_orders_lead_the_shared_digest_alongside_other_actionable_items() {
  local home inbox banner digest
  home=$(make_home)
  seed_actionable "$home"          # ownerless backlog_hygiene item
  inbox="$home/captain-orders.jsonl"
  FM_ORDERS_PATH="$inbox" "$ROOT/bin/fm-order.sh" add "Fix the bug history mismatch." >/dev/null \
    || fail "could not record the captain order fixture"

  banner=$(FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_FLEET_TRIAGE_BUG_CLI=off FM_ORDERS_PATH="$inbox" "$DUTY" heartbeat 2>&1)
  assert_contains "$banner" 'captain orders: 1 needing action' \
    "the duty banner dropped the captain-order line the digest is supposed to lead with"
  assert_contains "$banner" 'untriaged: 1' "the duty banner lost the untriaged captain-order count"
  assert_contains "$banner" '[captain orders] ORD-001' \
    "the duty banner did not list the captain order as an actionable item"
  assert_contains "$banner" 'ready-q1' \
    "the captain-order line displaced the fleet's other actionable work instead of leading it"

  digest=$(FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_FLEET_TRIAGE_BUG_CLI=off FM_ORDERS_PATH="$inbox" "$ROOT/bin/fm-fleet-triage.sh" --digest 2>/dev/null)
  assert_contains "$digest" 'captain orders: 1 needing action' \
    "fm-fleet-triage.sh --digest dropped the captain-order line the duty banner still prints"
  [ "$(printf '%s\n' "$digest" | grep -n 'captain orders: 1 needing action' | cut -d: -f1)" -lt \
    "$(printf '%s\n' "$digest" | grep -n 'backlog hygiene:' | cut -d: -f1)" ] \
    || fail "captain orders no longer lead the digest"
  pass "captain orders lead both renderings of one enumeration, next to the fleet's other actionable work"
}

test_banner_never_pollutes_stdout() {
  local home stdout
  home=$(make_home)
  seed_actionable "$home"
  stdout=$(FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_FLEET_TRIAGE_BUG_CLI=off "$DUTY" teardown 2>/dev/null)
  [ -z "$stdout" ] || fail "duty wrote to stdout; a caller's parseable output must stay byte-identical: $stdout"
  pass "the banner goes to stderr only"
}

test_duty_writes_no_ledger_but_caches_its_own_result() {
  local home
  home=$(make_home)
  seed_actionable "$home"
  run_duty "$home" teardown >/dev/null
  assert_absent "$home/data/fleet-triage.jsonl" "the duty pass wrote to the triage OUTCOME ledger; it must only read and cache its own result"
  assert_present "$(cache_of "$home")" "the duty pass did not cache its own result for bin/fm-guard.sh's preflight to read"
  pass "the duty pass never writes the outcome ledger, but does cache its own pass result"
}

test_enumeration_failure_is_a_visible_finding_not_swallowed_silence() {
  local root home out rc
  home=$(make_home)
  root="$TMP_ROOT/fail-root-$$"
  mkdir -p "$root/bin"
  cp "$ROOT/bin/fm-fleet-triage-lib.sh" "$ROOT/bin/fm-fleet-triage-record.sh" "$ROOT/bin/fm-triage-duty.sh" "$root/bin/"
  chmod +x "$root/bin/fm-triage-duty.sh"
  cat > "$root/bin/fm-fleet-triage.sh" <<'SH'
#!/usr/bin/env bash
echo "fm-fleet-triage: jq not found" >&2
exit 1
SH
  chmod +x "$root/bin/fm-fleet-triage.sh"

  out=$(FM_ROOT_OVERRIDE="$root" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$root/bin/fm-triage-duty.sh" heartbeat 2>&1)
  rc=$?
  expect_code 0 "$rc" "an enumerator crash must still leave the caller non-breaking (exit 0)"
  assert_contains "$out" 'FLEET TRIAGE DUTY - ENUMERATION FAILED' "an enumerator crash produced no visible finding at all"
  assert_contains "$out" 'jq not found' "the failure banner did not surface the enumerator's own error"
  assert_contains "$out" 'runtime/triage-health finding' "the failure banner did not name itself as a stable finding, not silence"
  [ "$(jq -r '.ok' "$(cache_of "$home")")" = false ] \
    || fail "an enumerator crash must cache ok:false so bin/fm-guard.sh keeps surfacing it later"
  pass "an enumerator crash is a visible, cached FAILED finding - never indistinguishable from a clear fleet"
}

# --- call sites -------------------------------------------------------------

test_wake_drain_prompts_the_duty_and_keeps_records_clean() {
  local home stdout stderr
  home=$(make_home)
  seed_actionable "$home"
  printf '%s\t%s\t%s\t%s\t%s\n' 100 1 signal task-a 'signal: task-a blocked' > "$home/state/.wake-queue"
  stdout="$home/drain.out"
  stderr="$home/drain.err"
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_FLEET_TRIAGE_BUG_CLI=off \
    "$DRAIN" > "$stdout" 2> "$stderr" || fail "drain failed"

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
  seed_actionable "$home"
  {
    printf '%s\t%s\t%s\t%s\t%s\n' 100 1 signal task-a 'signal: task-a done'
    printf '%s\t%s\t%s\t%s\t%s\n' 101 2 heartbeat fleet 'heartbeat: review the fleet'
  } > "$home/state/.wake-queue"
  stderr="$home/drain.err"
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_FLEET_TRIAGE_BUG_CLI=off \
    "$DRAIN" >/dev/null 2> "$stderr" || fail "drain failed"
  assert_grep 'HEARTBEAT WAKE REACHED THE AGENT' "$stderr" "a drained heartbeat did not escalate to the heartbeat trigger"
  assert_grep 'full (every lane)' "$stderr" "a drained heartbeat did not ask for a full pass"
  pass "a drained heartbeat escalates the duty to a full pass"
}

test_empty_drain_is_silent() {
  local home stderr
  home=$(make_home)
  seed_actionable "$home"
  : > "$home/state/.wake-queue"
  stderr="$home/drain.err"
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_FLEET_TRIAGE_BUG_CLI=off \
    "$DRAIN" >/dev/null 2> "$stderr" || fail "empty drain failed"
  assert_no_grep 'FLEET TRIAGE DUTY' "$stderr" "an empty drain prompted the duty; nothing changed, so nothing is owed"
  pass "an empty drain prompts no duty, even with actionable state sitting in the fleet"
}

test_local_only_merge_prompts_the_duty() {
  # A local-only merge is a ship completion with no PR and no CI, so it is the only
  # moment that work lands. fm-pr-merge's own suite covers the PR path; this covers
  # the path that has no other suite.
  local home stderr
  home=$(make_home)
  seed_actionable "$home"
  fm_git_worktree "$home/project" "$home/wt" fm/task-x1
  git -C "$home/project" branch -M main 2>/dev/null || true
  printf 'work\n' > "$home/wt/f.txt"
  git -C "$home/wt" add f.txt
  git -C "$home/wt" -c user.email=t@t -c user.name=t commit -qm work
  fm_write_meta "$home/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$home/wt" "project=$home/project" "kind=ship" "mode=local-only"

  stderr="$home/merge.err"
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_FLEET_TRIAGE_BUG_CLI=off \
    "$ROOT/bin/fm-merge-local.sh" task-x1 > "$home/merge.out" 2> "$stderr" \
    || fail "local-only merge failed"
  assert_grep 'FLEET TRIAGE DUTY - SHIP WORK LANDED' "$stderr" \
    "a local-only merge did not prompt the fleet-triage duty"
  assert_no_grep 'FLEET TRIAGE DUTY' "$home/merge.out" \
    "the duty banner reached fm-merge-local's stdout; it must stay on stderr"
  pass "a local-only merge prompts the fleet-triage duty"
}

test_banner_fires_at_every_wired_call_site() {
  # Guards the wiring itself: every script that changes fleet state must reach
  # fm-triage-duty.sh. A call site deleted in a refactor is exactly the regression
  # this phase exists to prevent, and it is invisible in their own behavior tests.
  local script
  for script in fm-wake-drain.sh fm-teardown.sh fm-pr-merge.sh fm-merge-local.sh \
    fm-session-start.sh fm-backlog-handoff.sh; do
    grep -F 'fm-triage-duty.sh' "$ROOT/bin/$script" >/dev/null \
      || fail "$script no longer prompts the fleet-triage duty"
  done
  pass "every wired call site still prompts the fleet-triage duty"
}

test_silent_when_nothing_actionable
test_captain_orders_lead_the_shared_digest_alongside_other_actionable_items
test_banner_fires_for_each_trigger_only_when_actionable
test_scope_differs_between_targeted_and_full_triggers
test_detail_is_surfaced
test_silent_without_the_session_lock
test_silent_while_away
test_kill_switch_silences_everything
test_enumerate_only_reports_but_refuses_writes_clear_fleet_stays_silent_regardless
test_unknown_trigger_fails_loudly
test_banner_never_pollutes_stdout
test_duty_writes_no_ledger_but_caches_its_own_result
test_enumeration_failure_is_a_visible_finding_not_swallowed_silence
test_wake_drain_prompts_the_duty_and_keeps_records_clean
test_drained_heartbeat_asks_for_a_full_pass
test_empty_drain_is_silent
test_local_only_merge_prompts_the_duty
test_banner_fires_at_every_wired_call_site

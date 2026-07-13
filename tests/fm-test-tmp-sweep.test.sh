#!/usr/bin/env bash
# tests/fm-test-tmp-sweep.test.sh - temp-root lifecycle: the test harness must not
# be able to exhaust /tmp.
#
# Covers the three ways a temp root dies (clean exit, catchable signal, SIGKILL),
# the sweep that is the only recovery from the third, and the invariant that
# matters most: a root belonging to a LIVE test is never reclaimed. Regression
# cover for the 2026-07-13 outage, where leaked secondmate-suite roots exhausted
# /tmp's inodes and every write on the box - including the captain order inbox
# write - began failing with ENOSPC.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SWEEP="$ROOT/bin/fm-test-tmp-sweep.sh"
TMP_ROOT=$(fm_test_tmproot fm-tmp-sweep)

# A minimal suite that makes a temp root through the real tests/lib.sh, reports
# it, then idles until killed. $1 is the sandbox TMPDIR.
write_victim_suite() {
  cat > "$TMP_ROOT/victim.sh" <<EOF
#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib.sh"
victim=\$(fm_test_tmproot fm-victim)
mkdir -p "\$victim/home/data"
printf '%s\n' "\$victim" > "$TMP_ROOT/victim.path"
sleep 120
EOF
  chmod +x "$TMP_ROOT/victim.sh"
}

# Start the victim under its own TMPDIR sandbox and publish VICTIM_PID/VICTIM_ROOT.
#
# Assignment-style on purpose: a victim launched inside a command substitution is
# a child of that subshell and is HUP'd the moment the substitution ends, which
# would kill it before the test could kill it deliberately. It must be a child of
# the test process itself.
VICTIM_PID=
VICTIM_ROOT=
start_victim() {
  local sandbox=$1
  rm -f "$TMP_ROOT/victim.path"
  TMPDIR="$sandbox" "$TMP_ROOT/victim.sh" &
  VICTIM_PID=$!
  for _ in $(seq 1 100); do
    [ -s "$TMP_ROOT/victim.path" ] && break
    sleep 0.1
  done
  VICTIM_ROOT=$(cat "$TMP_ROOT/victim.path" 2>/dev/null || true)
  [ -n "$VICTIM_ROOT" ] || fail "victim suite never reported its temp root"
}

test_clean_exit_leaves_no_root() {
  # The original bug: fm_test_tmproot registered cleanup inside a command
  # substitution (a subshell), so the parent shell had no trap and no registry,
  # and EVERY run - not just a killed one - leaked its whole root.
  local sandbox out
  sandbox="$TMP_ROOT/clean"
  mkdir -p "$sandbox"
  cat > "$TMP_ROOT/clean.sh" <<EOF
#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib.sh"
r=\$(fm_test_tmproot fm-clean)
mkdir -p "\$r/deep/nested"
EOF
  TMPDIR="$sandbox" bash "$TMP_ROOT/clean.sh" || fail "clean victim suite failed"
  out=$(find "$sandbox" -mindepth 1 -maxdepth 1)
  [ -z "$out" ] || fail "clean exit leaked a temp root: $out"
  pass "a suite that exits cleanly leaves no temp root behind"
}

test_sigterm_and_sigint_clean_up_via_trap() {
  local sig sandbox pid root
  for sig in TERM INT; do
    sandbox="$TMP_ROOT/sig-$sig"
    mkdir -p "$sandbox"
    write_victim_suite
    start_victim "$sandbox"
    pid=$VICTIM_PID
    root=$VICTIM_ROOT
    assert_present "$root" "victim root was not created before the $sig"

    kill -"$sig" "$pid" 2>/dev/null || fail "could not send $sig to the victim"
    wait "$pid" 2>/dev/null || true
    # The trap runs during shutdown; give it a moment to finish the rm -rf.
    for _ in $(seq 1 50); do
      [ -e "$root" ] || break
      sleep 0.1
    done
    assert_absent "$root" "SIG$sig did not clean up the temp root via the trap"
  done
  pass "a suite killed with SIGTERM or SIGINT cleans up immediately via its trap"
}

test_sigkill_leaks_and_the_sweep_reclaims_it() {
  # SIGKILL cannot be trapped by any process, so the root necessarily survives
  # the kill. The sweep is the only thing that can reclaim it - end to end.
  local sandbox pid root out
  sandbox="$TMP_ROOT/kill"
  mkdir -p "$sandbox"
  write_victim_suite
  start_victim "$sandbox"
  pid=$VICTIM_PID
  root=$VICTIM_ROOT

  kill -9 "$pid" 2>/dev/null || fail "could not SIGKILL the victim"
  wait "$pid" 2>/dev/null || true
  assert_present "$root" "SIGKILL somehow cleaned up - the premise of this test is wrong"
  assert_present "$root/.fm-test-owner" "orphaned root carries no ownership marker"

  out=$("$SWEEP" --tmpdir "$sandbox" --min-age-seconds 0)
  assert_contains "$out" "reclaimed $root" "sweep did not reclaim the SIGKILL-orphaned root"
  assert_contains "$out" "fm-victim" "sweep did not name the suite that orphaned the root"
  assert_absent "$root" "sweep reported a reclaim but the root is still on disk"
  pass "a SIGKILLed suite's orphaned root is reclaimed by the sweep"
}

test_sweep_never_touches_a_live_roots() {
  # The invariant that protects a running test: one of the 8 leaked roots on
  # 2026-07-13 WAS live and had to be left alone. Age is not proof of staleness -
  # a slow suite can outlive any threshold - so a live owner always wins.
  local sandbox pid root out
  sandbox="$TMP_ROOT/live"
  mkdir -p "$sandbox"
  write_victim_suite
  start_victim "$sandbox"
  pid=$VICTIM_PID
  root=$VICTIM_ROOT

  # Backdate the root far past every threshold: only liveness may save it now.
  touch -d '1970-01-02' "$root" 2>/dev/null || touch -t 197001020000 "$root"

  out=$("$SWEEP" --tmpdir "$sandbox" --min-age-seconds 0)
  assert_present "$root" "sweep deleted a temp root while its owning test was still running"
  assert_contains "$out" "kept $root" "sweep did not report keeping the live root"
  assert_contains "$out" "still alive" "sweep did not explain why the live root was kept"
  assert_not_contains "$out" "reclaimed $root" "sweep claimed to reclaim a live root"

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "the sweep never removes a temp root belonging to a live test"
}

test_sweep_respects_min_age_and_dry_run() {
  local sandbox pid root out
  sandbox="$TMP_ROOT/age"
  mkdir -p "$sandbox"
  write_victim_suite
  start_victim "$sandbox"
  pid=$VICTIM_PID
  root=$VICTIM_ROOT
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  # Freshly orphaned: too young to be provably stale, so it is left alone.
  out=$("$SWEEP" --tmpdir "$sandbox" --min-age-seconds 600)
  assert_not_contains "$out" "reclaimed" "sweep reclaimed a root younger than the age threshold"
  assert_present "$root" "sweep deleted a root younger than the age threshold"

  out=$("$SWEEP" --tmpdir "$sandbox" --min-age-seconds 0 --dry-run)
  assert_contains "$out" "would-reclaim $root" "dry run did not report the reclaim it would do"
  assert_present "$root" "dry run deleted the root"

  out=$("$SWEEP" --tmpdir "$sandbox" --min-age-seconds 0)
  assert_contains "$out" "reclaimed $root" "sweep did not reclaim the stale root"
  assert_absent "$root" "stale root survived the sweep"
  pass "the sweep honors the staleness threshold and --dry-run"
}

test_sweep_reports_the_reclaimed_footprint() {
  local sandbox pid root out
  sandbox="$TMP_ROOT/report"
  mkdir -p "$sandbox"
  write_victim_suite
  start_victim "$sandbox"
  pid=$VICTIM_PID
  root=$VICTIM_ROOT
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  out=$("$SWEEP" --tmpdir "$sandbox" --min-age-seconds 0)
  assert_contains "$out" "MB, " "sweep did not report the reclaimed footprint"
  assert_contains "$out" " files)" "sweep did not report the reclaimed file count"
  pass "the sweep reports what it reclaimed, never sweeping silently"
}

test_sweep_ignores_dirs_that_are_not_test_roots() {
  # TMPDIR is shared with the runtime. Anything without a marker is not ours,
  # and only the two unambiguous legacy suite prefixes are recognized by name.
  local sandbox out
  sandbox="$TMP_ROOT/foreign"
  mkdir -p "$sandbox/fm-task-scratch" "$sandbox/some-runtime-dir"
  touch -d '1970-01-02' "$sandbox/fm-task-scratch" "$sandbox/some-runtime-dir" 2>/dev/null \
    || touch -t 197001020000 "$sandbox/fm-task-scratch" "$sandbox/some-runtime-dir"

  out=$("$SWEEP" --tmpdir "$sandbox" --min-age-seconds 0)
  assert_not_contains "$out" "reclaimed" "sweep reclaimed a dir that is not a test root"
  assert_present "$sandbox/fm-task-scratch" "sweep deleted an unowned runtime temp dir"
  assert_present "$sandbox/some-runtime-dir" "sweep deleted an unrelated temp dir"
  pass "the sweep leaves temp dirs that are not test roots alone"
}

test_sweep_reclaims_legacy_unowned_secondmate_roots() {
  # The roots that took the box down predate the ownership marker. They are
  # recognized by their unmistakable suite prefix, and only once truly ancient.
  local sandbox legacy fresh out
  sandbox="$TMP_ROOT/legacy"
  legacy="$sandbox/fm-secondmate-safety.aBcDeF"
  fresh="$sandbox/fm-secondmate-safety.zZzZzZ"
  mkdir -p "$legacy/home" "$fresh/home"
  touch -d '1970-01-02' "$legacy" 2>/dev/null || touch -t 197001020000 "$legacy"

  out=$("$SWEEP" --tmpdir "$sandbox" --min-age-seconds 0)
  assert_contains "$out" "reclaimed $legacy" "sweep did not reclaim the ancient legacy root"
  assert_absent "$legacy" "ancient legacy root survived the sweep"
  assert_present "$fresh" "sweep reclaimed a recent unowned root that may still be in use"
  pass "the sweep reclaims ancient legacy roots but spares recent ones"
}

test_bootstrap_reports_what_the_sweep_reclaimed() {
  local sandbox pid root out
  sandbox="$TMP_ROOT/bootstrap"
  mkdir -p "$sandbox"
  write_victim_suite
  start_victim "$sandbox"
  pid=$VICTIM_PID
  root=$VICTIM_ROOT
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  out=$(TMPDIR="$sandbox" FM_TEST_SWEEP_MIN_AGE=0 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null || true)
  assert_contains "$out" "TEST_TMP_SWEEP: reclaimed 1 orphaned test temp root(s)" \
    "bootstrap did not report the reclaimed root"
  assert_absent "$root" "bootstrap sweep did not actually reclaim the orphaned root"

  # A clean sweep must stay silent: silence in bootstrap means all good.
  out=$(TMPDIR="$sandbox" FM_TEST_SWEEP_MIN_AGE=0 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null || true)
  assert_not_contains "$out" "TEST_TMP_SWEEP" "bootstrap reported a sweep with nothing to reclaim"
  pass "session start reports reclaimed roots and stays silent when there is nothing to reclaim"
}

test_headroom_guard_refuses_to_run_on_an_exhausted_tmpdir() {
  # The pre-flight check that turns a fleet-wide ENOSPC outage into one legible
  # test failure. Thresholds are absurdly high here to force the refusal.
  local sandbox out rc
  sandbox="$TMP_ROOT/headroom"
  mkdir -p "$sandbox"
  cat > "$TMP_ROOT/greedy.sh" <<EOF
#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib.sh"
fm_test_require_tmp_headroom 999999999 999999999
printf 'suite ran anyway\n'
EOF
  set +e
  out=$(TMPDIR="$sandbox" bash "$TMP_ROOT/greedy.sh" 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "headroom guard did not fail the suite on an exhausted TMPDIR"
  assert_contains "$out" "near exhaustion" "headroom guard did not explain the refusal"
  assert_not_contains "$out" "suite ran anyway" "headroom guard let the heavy suite run"

  # And it must NOT fire on a healthy TMPDIR.
  cat > "$TMP_ROOT/modest.sh" <<EOF
#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib.sh"
fm_test_require_tmp_headroom 1 1
printf 'suite ran\n'
EOF
  out=$(TMPDIR="$sandbox" bash "$TMP_ROOT/modest.sh" 2>&1) || fail "headroom guard blocked a healthy TMPDIR"
  assert_contains "$out" "suite ran" "healthy TMPDIR did not run the suite"
  pass "the headroom guard refuses an exhausted TMPDIR and passes a healthy one"
}

test_heavy_suites_declare_the_headroom_guard() {
  # The guard only protects the fleet if the suites that seed firstmate homes
  # actually call it.
  local suite
  for suite in fm-secondmate-safety fm-secondmate-lifecycle-e2e; do
    assert_grep 'fm_test_require_tmp_headroom' "$ROOT/tests/$suite.test.sh" \
      "$suite does not pre-flight its TMPDIR headroom"
  done
  pass "the home-seeding suites pre-flight TMPDIR headroom before running"
}

test_clean_exit_leaves_no_root
test_sigterm_and_sigint_clean_up_via_trap
test_sigkill_leaks_and_the_sweep_reclaims_it
test_sweep_never_touches_a_live_roots
test_sweep_respects_min_age_and_dry_run
test_sweep_reports_the_reclaimed_footprint
test_sweep_ignores_dirs_that_are_not_test_roots
test_sweep_reclaims_legacy_unowned_secondmate_roots
test_bootstrap_reports_what_the_sweep_reclaimed
test_headroom_guard_refuses_to_run_on_an_exhausted_tmpdir
test_heavy_suites_declare_the_headroom_guard

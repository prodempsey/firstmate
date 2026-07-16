#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_SUPERVISION_TEST_MODE=1 FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  [ -f "$home/state/.codex-watch-checkpoint.next.json" ] || fail "quiet checkpoint did not leave a durable next-checkpoint schedule"
  [ "$(jq -r '.previous_result' "$home/state/.codex-watch-checkpoint.next.json")" = quiet ] \
    || fail "quiet checkpoint schedule did not record the quiet result"
  jq -e '.integrity | startswith("sha256:")' "$home/state/.codex-watch-checkpoint.next.json" >/dev/null \
    || fail "quiet checkpoint schedule did not carry integrity"
  [ "$(jq -r '.scheduler.adapter' "$home/state/.codex-watch-checkpoint.next.json")" = systemd-user-timer ] \
    || fail "quiet checkpoint schedule did not carry managed scheduler metadata"
  [ "$(stat -c '%a' "$home/state/.codex-watch-checkpoint.next.json" 2>/dev/null || stat -f '%Lp' "$home/state/.codex-watch-checkpoint.next.json")" = 600 ] \
    || fail "quiet checkpoint schedule was not written with restrictive 0600 mode"
  [ "$(stat -c '%a' "$home/state/.primary-harness.json" 2>/dev/null || stat -f '%Lp' "$home/state/.primary-harness.json")" = 600 ] \
    || fail "primary harness record was not written with restrictive 0600 mode"
  [ -n "$(find "$home/fake-systemd/timers" -name '*.json' -print -quit 2>/dev/null)" ] \
    || fail "quiet checkpoint did not register the managed fake timer"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_SUPERVISION_TEST_MODE=1 FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  [ "$(jq -r '.previous_result' "$home/state/.codex-watch-checkpoint.next.json")" = wake ] \
    || fail "signal checkpoint schedule did not record the wake result"
  drained=$(cat "$home/state/.wake-queue" 2>/dev/null || true)
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod +x "$home/state/env-check.check.sh"
  status=0
  FM_SUPERVISION_TEST_MODE=1 FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for the foreground fm-watch.sh"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_SUPERVISION_TEST_MODE=1 FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  assert_absent "$home/state/.codex-watch-checkpoint.next.json" "failed checkpoint left a healthy schedule"
  [ "$(jq -r '.previous_result' "$home/state/.codex-watch-checkpoint.last.json")" = failed ] \
    || fail "failed checkpoint did not record a failed last-checkpoint result"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

test_duplicate_running_checkpoint_is_refused() {
  local home out err status pid identity
  home=$(make_home duplicate-running)
  out="$home/out.txt"
  err="$home/err.txt"
  sleep 60 >/dev/null 2>&1 &
  pid=$!
  identity=$(FM_SUPERVISION_TEST_MODE=1 FM_HOME="$home" bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_codex_primary_identity "$2/state" "$2"' _ "$ROOT" "$home")
  jq -cnS --arg owner "codex:$identity" --arg primary_identity "$identity" --arg home "$home" \
    --arg state "$home/state" --argjson pid "$pid" \
    '{version:1,harness:"codex",owner:$owner,primary_identity:$primary_identity,
      fm_home:$home,state_dir:$state,runner_pid:$pid,checkpoint_start:1,
      cadence_seconds:1,mechanism:"codex-bounded-checkpoint"}' \
    > "$home/state/.codex-watch-checkpoint.running.json"
  status=0
  FM_SUPERVISION_TEST_MODE=1 FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" FM_HOME="$home" "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 1 "$status" "duplicate running checkpoint exit"
  assert_contains "$(cat "$err")" "duplicate-running-checkpoint" "duplicate running checkpoint was not named"
  assert_absent "$home/state/.codex-watch-checkpoint.next.json" "duplicate running refusal wrote a healthy schedule"
  pass "checkpoint refuses a duplicate live running checkpoint lease"
}

test_checkpoint_advances_generation_from_existing_schedule() {
  local home out err status gen1 gen2
  home=$(make_home generation)
  out="$home/out.txt"
  err="$home/err.txt"
  FM_SUPERVISION_TEST_MODE=1 FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || true
  gen1=$(jq -r '.generation' "$home/state/.codex-watch-checkpoint.next.json")
  FM_SUPERVISION_TEST_MODE=1 FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  status=${status:-124}
  expect_code 124 "$status" "second quiet checkpoint exit"
  gen2=$(jq -r '.generation' "$home/state/.codex-watch-checkpoint.next.json")
  [ "$gen2" -gt "$gen1" ] || fail "checkpoint did not advance the durable schedule generation: $gen1 -> $gen2"
  pass "checkpoint consumes and advances an existing durable next-checkpoint schedule"
}

# arm_valid_schedule <home>: run one quiet checkpoint so the home holds a valid
# durable schedule plus a live fake scheduler registration.
arm_valid_schedule() {
  local home=$1
  FM_SUPERVISION_TEST_MODE=1 FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >/dev/null 2>&1 || true
  [ -f "$home/state/.codex-watch-checkpoint.next.json" ] || fail "could not arm a valid schedule for $home"
  [ -n "$(find "$home/fake-systemd/timers" -name '*.json' -print -quit 2>/dev/null)" ] \
    || fail "could not arm a fake scheduler registration for $home"
}

# Review finding F-6: a prepare that fails (here: no live identity, production
# mode) must fail BEFORE consuming the armed timer and durable schedule, leaving
# the prior-valid supervision fully intact.
test_prepare_failure_preserves_prior_supervision() {
  local home out
  home=$(make_home preserve-prior)
  arm_valid_schedule "$home"
  # shellcheck disable=SC2016  # $1/$2 expand in the inner bash -c process, not here.
  out=$(env -u FM_SUPERVISION_TEST_MODE -u FM_CODEX_PRIMARY_IDENTITY -u FM_CODEX_SYSTEMD_FAKE_DIR \
    bash -c '. "$1/bin/fm-supervision-lib.sh"
      fm_codex_checkpoint_prepare "$2/state" "$2" "$(date +%s)" 60
      printf "prepare_rc=%s reason=%s\n" "$?" "$FM_CODEX_CHECKPOINT_PREPARE_REASON"' _ "$ROOT" "$home")
  assert_contains "$out" "prepare_rc=1" "prepare without a live verified primary must fail"
  assert_contains "$out" "reason=identity-unresolvable" "prepare must name the identity failure"
  [ -f "$home/state/.codex-watch-checkpoint.next.json" ] \
    || fail "failed prepare consumed the durable schedule"
  [ -n "$(find "$home/fake-systemd/timers" -name '*.json' -print -quit 2>/dev/null)" ] \
    || fail "failed prepare destroyed the armed scheduler registration"
  assert_absent "$home/state/.codex-watch-checkpoint.running.json" "failed prepare left a running-checkpoint lease behind"
  pass "checkpoint prepare failure preserves the prior schedule and armed timer"
}

# Review finding F-6: ownership acquisition is atomic. Two prepares released
# against one barrier admit exactly one winner; the loser touches nothing.
test_concurrent_prepare_admits_exactly_one_winner() {
  local home barrier i ok_count fail_count winner_result loser_result deadline
  home=$(make_home concurrent-prepare)
  arm_valid_schedule "$home"
  barrier="$home/barrier"
  for i in 1 2; do
    FM_SUPERVISION_TEST_MODE=1 FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" \
      bash -c '. "$1/bin/fm-supervision-lib.sh"
        until [ -f "$2" ]; do sleep 0.02; done
        if fm_codex_checkpoint_prepare "$3/state" "$3" "$(date +%s)" 60; then
          printf "ok gen=%s\n" "$FM_CODEX_CHECKPOINT_GENERATION" > "$4"
        else
          printf "fail %s\n" "$FM_CODEX_CHECKPOINT_PREPARE_REASON" > "$4"
        fi
        until [ -f "$5" ]; do sleep 0.05; done' \
      _ "$ROOT" "$barrier" "$home" "$home/result-$i" "$home/release" >/dev/null 2>&1 &
  done
  : > "$barrier"
  deadline=$((SECONDS + 20))
  while [ ! -s "$home/result-1" ] || [ ! -s "$home/result-2" ]; do
    [ "$SECONDS" -lt "$deadline" ] || { : > "$home/release"; fail "concurrent prepares did not both report" ; }
    sleep 0.05
  done
  ok_count=$(cat "$home/result-1" "$home/result-2" | grep -c '^ok' || true)
  fail_count=$(cat "$home/result-1" "$home/result-2" | grep -c '^fail duplicate-running-checkpoint' || true)
  winner_result=$(cat "$home/result-1" "$home/result-2" | grep '^ok' || true)
  loser_result=$(cat "$home/result-1" "$home/result-2" | grep '^fail' || true)
  [ "$ok_count" = 1 ] || { : > "$home/release"; fail "expected exactly one prepare winner, got $ok_count ($winner_result / $loser_result)"; }
  [ "$fail_count" = 1 ] || { : > "$home/release"; fail "loser did not fail as duplicate-running-checkpoint: $loser_result"; }
  assert_contains "$winner_result" "gen=1" "winner did not consume the armed schedule generation"
  assert_absent "$home/state/.codex-watch-checkpoint.next.json" "the schedule was not consumed exactly once"
  [ -f "$home/state/.codex-watch-checkpoint.running.json" ] \
    || { : > "$home/release"; fail "the winner's running-checkpoint lease is missing"; }
  : > "$home/release"
  wait
  pass "checkpoint prepare admits exactly one concurrent owner and the loser preserves state"
}

test_stale_running_record_is_reclaimed() {
  local home out err status dead
  home=$(make_home stale-running)
  out="$home/out.txt"
  err="$home/err.txt"
  dead=999999
  while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
  jq -cnS --argjson pid "$dead" '{version:1,harness:"codex",runner_pid:$pid,lease_id:"stale",generation:0}' \
    > "$home/state/.codex-watch-checkpoint.running.json"
  status=0
  FM_SUPERVISION_TEST_MODE=1 FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "checkpoint exit with a stale running record present"
  [ -f "$home/state/.codex-watch-checkpoint.next.json" ] \
    || fail "checkpoint did not recover from a dead runner's stale running record"
  pass "checkpoint reclaims a dead runner's stale running-checkpoint record"
}

# --- review-r5 F-1: the managed service's actual process environment ----------
# A systemd user service inherits the user manager's environment underneath the
# validated unit Environment= lines, so the checkpoint itself must establish a
# deterministic clean environment when started as the managed service
# (FM_CODEX_SYSTEMD_SERVICE=1). These cases run the service entry exactly as
# the unit would, with hostile inherited manager variables layered on top.

# run_service_checkpoint <home> [hostile NAME=VALUE assignments...] <cmd...>
# Runs the checkpoint the way the generated unit does - the seven unit-declared
# variables - with any hostile inherited manager variables layered on top by
# the caller as extra env assignments before the command.
run_service_checkpoint() {
  local home=$1
  shift
  env \
    FM_CODEX_SYSTEMD_SERVICE=1 \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_SUPERVISION_HARNESS=codex \
    FM_CODEX_SYSTEMD_LEASE=unit-lease \
    FM_CODEX_SYSTEMD_GENERATION=1 \
    FM_CODEX_WATCH_CHECKPOINT=1 \
    "$@"
}

test_service_mode_scrubs_inherited_manager_environment() {
  local home decoy out err status schedule owner canon_home
  home=$(make_home service-scrub)
  decoy="$TMP_ROOT/service-scrub-decoy"
  mkdir -p "$decoy/state"
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  run_service_checkpoint "$home" \
    FM_SUPERVISION_TEST_MODE=1 \
    FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" \
    FM_ROOT_OVERRIDE="$decoy" \
    FM_CODEX_WATCH_CHECKPOINT_MAX_LATENESS=999999 \
    FM_CODEX_PRIMARY_IDENTITY=forged-manager-identity \
    FM_GUARD_GRACE=1 \
    "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "service-mode quiet checkpoint exit under hostile inherited environment"
  schedule="$home/state/.codex-watch-checkpoint.next.json"
  [ -f "$schedule" ] || fail "service-mode checkpoint did not leave a durable schedule: $(cat "$err")"
  [ "$(jq -r '.max_lateness_seconds' "$schedule")" = 60 ] \
    || fail "inherited FM_CODEX_WATCH_CHECKPOINT_MAX_LATENESS altered the recorded lateness bound"
  canon_home=$(cd "$home" && pwd -P)
  owner=$(jq -r '.owner' "$schedule")
  [ "$owner" = "codex:test:codex:$canon_home" ] \
    || fail "inherited FM_CODEX_PRIMARY_IDENTITY reached service identity resolution: $owner"
  [ -z "$(find "$decoy/state" -mindepth 1 -print -quit 2>/dev/null)" ] \
    || fail "inherited FM_ROOT_OVERRIDE redirected service state writes into the decoy root"
  pass "service mode scrubs inherited manager FM_* variables before reading any configuration"
}

test_service_mode_rejects_inherited_test_mode_outside_test_owned_home() {
  local home out err status
  home=$(mktemp -d) || fail "mktemp failed"
  FM_TEST_CLEANUP_DIRS+=("$home")
  mkdir -p "$home/state"
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  run_service_checkpoint "$home" \
    FM_SUPERVISION_TEST_MODE=1 \
    FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" \
    "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "service-mode checkpoint with inherited test mode and no live primary must fail"
  assert_contains "$(cat "$err")" "failed to persist Codex primary harness identity" \
    "the failure must be the identity resolution, not a later stage"
  assert_absent "$home/state/.codex-watch-checkpoint.next.json" \
    "inherited test mode minted a healthy schedule with no live primary"
  assert_absent "$home/fake-systemd" \
    "inherited fake-scheduler seam was honored outside a test-owned home"
  rm -rf "$home"
  pass "service mode rejects inherited FM_SUPERVISION_TEST_MODE outside a test-owned home (no synthetic identity)"
}

test_service_mode_requires_codex_harness_binding() {
  local home out err status
  home=$(make_home service-binding)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  env FM_CODEX_SYSTEMD_SERVICE=1 FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 2 "$status" "service mode without the codex harness binding must fail closed"
  assert_contains "$(cat "$err")" "without FM_SUPERVISION_HARNESS=codex" "the missing harness binding must be named"
  pass "service mode requires the unit-declared codex harness binding"
}

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_duplicate_running_checkpoint_is_refused
test_checkpoint_advances_generation_from_existing_schedule
test_prepare_failure_preserves_prior_supervision
test_concurrent_prepare_admits_exactly_one_winner
test_stale_running_record_is_reclaimed
test_service_mode_scrubs_inherited_manager_environment
test_service_mode_rejects_inherited_test_mode_outside_test_owned_home
test_service_mode_requires_codex_harness_binding

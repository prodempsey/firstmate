#!/usr/bin/env bash
# Tests for the Codex systemd user scheduler adapter: the fail-closed test-seam
# gate, fake-mode lifecycle, and the shipping real-mode branch driven through a
# stub systemctl with a scratch unit directory (never the real user manager).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCHED="$ROOT/bin/fm-codex-systemd-scheduler.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-systemd-scheduler)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config" "$home/data"
  printf '%s\n' "$home"
}

# fake_env <home> <cmd...>: run under the gated fake-mode test seam.
fake_env() {
  local home=$1
  shift
  FM_SUPERVISION_TEST_MODE=1 FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" "$@"
}

# write_stub_systemctl <home>: install a deterministic systemctl stub that
# serves unit state from <home>/units and marker files from <home>/stub-state.
# Property overrides for attack cases live at stub-state/override-<unit>-<prop>.
write_stub_systemctl() {
  local home=$1 stub="$1/systemctl-stub"
  mkdir -p "$home/units" "$home/stub-state"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
set -u
UNITS=${STUB_UNITS:?}
MARKS=${STUB_MARKS:?}
[ "${1:-}" = --user ] && shift
cmd=${1:-}
shift || true
unit_file() { printf '%s/%s' "$UNITS" "$1"; }
prop_value() {
  local unit=$1 prop=$2 f override
  override="$MARKS/override-$unit-$prop"
  if [ -f "$override" ]; then cat "$override"; return 0; fi
  f=$(unit_file "$unit")
  case "$prop" in
    LoadState) if [ -f "$f" ]; then printf 'loaded'; else printf 'not-found'; fi ;;
    ActiveState) if [ -f "$MARKS/active-$unit" ]; then printf 'active'; else printf 'inactive'; fi ;;
    UnitFileState) if [ -f "$MARKS/enabled-$unit" ]; then printf 'enabled'; else printf 'disabled'; fi ;;
    FragmentPath) printf '%s' "$f" ;;
    Triggers) sed -n 's/^Unit=//p' "$f" 2>/dev/null | head -n 1 | tr -d '\n' ;;
    NextElapseUSecRealtime) sed -n 's/^OnCalendar=//p' "$f" 2>/dev/null | head -n 1 | tr -d '\n' ;;
    *) : ;;
  esac
}
case "$cmd" in
  show)
    unit=${1:-}
    shift || true
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -p)
          printf '%s=%s\n' "$2" "$(prop_value "$unit" "$2")"
          shift 2
          ;;
        *) shift ;;
      esac
    done
    ;;
  cat)
    unit=${1:-}
    f=$(unit_file "$unit")
    [ -f "$f" ] || exit 1
    printf '# %s\n' "$f"
    cat "$f"
    ;;
  enable)
    for a in "$@"; do
      case "$a" in
        --*) ;;
        *) : > "$MARKS/enabled-$a"; : > "$MARKS/active-$a" ;;
      esac
    done
    ;;
  disable)
    for a in "$@"; do
      case "$a" in
        --*) ;;
        *) rm -f "$MARKS/enabled-$a" "$MARKS/active-$a" ;;
      esac
    done
    ;;
  daemon-reload|stop|reset-failed) ;;
  is-system-running) printf 'running\n' ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$stub"
}

# real_env <home> <cmd...>: run the SHIPPING real-mode branch against the stub
# systemctl and the scratch unit dir, still inside the test-seam gate.
real_env() {
  local home=$1
  shift
  FM_SUPERVISION_TEST_MODE=1 \
    FM_CODEX_SYSTEMD_SYSTEMCTL="$home/systemctl-stub" \
    FM_CODEX_SYSTEMD_UNIT_DIR="$home/units" \
    STUB_UNITS="$home/units" STUB_MARKS="$home/stub-state" \
    "$@"
}

# build_record <home> <metadata-json> <generation> <lease> [due-offset] [cadence]
# Writes a schedule record consistent with the given adapter metadata.
build_record() {
  local home=$1 meta=$2 generation=$3 lease=$4 due_offset=${5:-60} cadence=${6:-60}
  local now payload hash canon_home canon_state
  now=$(date +%s)
  canon_home=$(printf '%s' "$meta" | jq -r '.fm_home')
  canon_state=$(printf '%s' "$meta" | jq -r '.state_dir')
  payload=$(jq -cnS \
    --argjson scheduler "$meta" \
    --arg lease "$lease" \
    --arg home "$canon_home" \
    --arg state "$canon_state" \
    --argjson now "$now" \
    --argjson due_offset "$due_offset" \
    --argjson cadence "$cadence" \
    --argjson generation "$generation" \
    '{version:1,harness:"codex",owner:"codex:test:codex",primary_identity:"test:codex",
      fm_home:$home,state_dir:$state,previous_checkpoint_start:($now - 2),
      previous_checkpoint_end:($now - 1),previous_result:"quiet",
      next_checkpoint_due:($now + $due_offset),cadence_seconds:$cadence,max_lateness_seconds:60,
      generation:$generation,lease_id:$lease,mechanism:"codex-bounded-checkpoint",
      scheduling_mechanism:"systemd-user-timer",scheduler:$scheduler}') || fail "payload build failed"
  hash=$(printf '%s\n' "$payload" | sha256sum | awk '{print $1}')
  printf '%s\n' "$payload" | jq -cS --arg integrity "sha256:$hash" '. + {integrity:$integrity}' \
    > "$home/record.json" || fail "record write failed"
  printf '%s\n' "$home/record.json"
}

fake_record() {  # <home> <generation> <lease>
  local home=$1 meta
  meta=$(fake_env "$home" "$SCHED" unit-metadata --home "$home" --state "$home/state") \
    || fail "fake unit metadata failed"
  build_record "$home" "$meta" "$2" "$3"
}

real_record() {  # <home> <generation> <lease> [due-offset] [cadence]
  local home=$1 meta
  meta=$(real_env "$home" "$SCHED" unit-metadata --home "$home" --state "$home/state") \
    || fail "real unit metadata failed"
  build_record "$home" "$meta" "$2" "$3" "${4:-60}" "${5:-60}"
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# --- the fail-closed test-seam gate (review finding F-1) ---------------------

test_fake_dir_without_test_mode_fails_closed() {
  local home status out
  home=$(make_home gate-no-test-mode)
  for verb in unit-metadata status validate schedule; do
    status=0
    out=$(FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" "$SCHED" "$verb" --home "$home" --state "$home/state" --record "$home/record.json" --json 2>&1) || status=$?
    expect_code 2 "$status" "ambient FM_CODEX_SYSTEMD_FAKE_DIR without test mode must fail closed for $verb"
    assert_contains "$out" "test-override-without-test-mode" "gate refusal must name the ungated override for $verb"
  done
  out=$(FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" "$SCHED" validate --home "$home" --state "$home/state" --record "$home/record.json" --json 2>/dev/null || true)
  [ "$(printf '%s' "$out" | jq -r '.ok' 2>/dev/null)" = false ] \
    || fail "gated validate --json did not report ok:false: $out"
  pass "fm-codex-systemd-scheduler: fake mode without FM_SUPERVISION_TEST_MODE=1 fails closed, never green"
}

test_stub_systemctl_without_test_unit_dir_fails_closed() {
  local home status out
  home=$(make_home gate-stub-no-unit-dir)
  write_stub_systemctl "$home"
  status=0
  out=$(FM_SUPERVISION_TEST_MODE=1 FM_CODEX_SYSTEMD_SYSTEMCTL="$home/systemctl-stub" \
    "$SCHED" status --home "$home" --state "$home/state" --json 2>&1) || status=$?
  expect_code 2 "$status" "stub systemctl without a test-owned unit dir must fail closed"
  assert_contains "$out" "stub-systemctl-without-test-unit-dir" "gate refusal must name the missing unit dir"
  pass "fm-codex-systemd-scheduler: a stubbed systemctl never writes into the real unit directory"
}

test_test_overrides_require_test_owned_home() {
  local home status out
  home=$(mktemp -d) || fail "mktemp failed"
  mkdir -p "$home/state"
  status=0
  out=$(FM_SUPERVISION_TEST_MODE=1 FM_CODEX_SYSTEMD_FAKE_DIR="$TMP_ROOT/stray-fake" \
    "$SCHED" status --home "$home" --state "$home/state" --json 2>&1) || status=$?
  rm -rf "$home"
  expect_code 2 "$status" "test overrides against a non-test-owned home must fail closed"
  assert_contains "$out" "test-override-home-not-test-owned" "gate refusal must name the non-test-owned home"
  pass "fm-codex-systemd-scheduler: test seams require a provably test-owned home"
}

# --- fake-mode lifecycle ------------------------------------------------------

test_metadata_is_deterministic_and_home_scoped() {
  local home other a b c
  home=$(make_home metadata-a)
  other=$(make_home metadata-b)
  a=$(fake_env "$home" "$SCHED" unit-metadata --home "$home" --state "$home/state")
  b=$(fake_env "$home" "$SCHED" unit-metadata --home "$home" --state "$home/state")
  c=$(fake_env "$other" "$SCHED" unit-metadata --home "$other" --state "$other/state")
  [ "$(printf '%s' "$a" | jq -r '.timer_name')" = "$(printf '%s' "$b" | jq -r '.timer_name')" ] \
    || fail "unit metadata is not deterministic for the same home"
  [ "$(printf '%s' "$a" | jq -r '.timer_name')" != "$(printf '%s' "$c" | jq -r '.timer_name')" ] \
    || fail "unit metadata did not vary by canonical home"
  pass "fm-codex-systemd-scheduler: metadata is deterministic and scoped by home"
}

test_schedule_query_validate_disable_remove() {
  local home record status validation
  home=$(make_home lifecycle)
  record=$(fake_record "$home" 1 lease-one)
  fake_env "$home" "$SCHED" schedule --home "$home" --state "$home/state" --record "$record" \
    || fail "schedule command failed"
  status=$(fake_env "$home" "$SCHED" query --home "$home" --state "$home/state" --json) \
    || fail "query command failed"
  [ "$(printf '%s' "$status" | jq -r '.registered')" = true ] || fail "query did not report registered timer: $status"
  validation=$(fake_env "$home" "$SCHED" validate --home "$home" --state "$home/state" --record "$record" --json) \
    || fail "validate command failed"
  [ "$(printf '%s' "$validation" | jq -r '.ok')" = true ] || fail "validate did not report ok: $validation"
  fake_env "$home" "$SCHED" disable --home "$home" --state "$home/state" \
    || fail "disable command failed"
  if fake_env "$home" "$SCHED" validate --home "$home" --state "$home/state" --record "$record" --json >/dev/null 2>&1; then
    fail "disabled scheduler still validated healthy"
  fi
  fake_env "$home" "$SCHED" remove --home "$home" --state "$home/state" \
    || fail "remove command failed"
  status=$(fake_env "$home" "$SCHED" status --home "$home" --state "$home/state" --json) \
    || fail "status command failed after remove"
  [ "$(printf '%s' "$status" | jq -r '.registered')" = false ] || fail "remove left scheduler registered: $status"
  pass "fm-codex-systemd-scheduler: schedule/query/validate/disable/remove lifecycle works in fake mode"
}

test_alias_verbs_replace_generation() {
  local home record status
  home=$(make_home aliases)
  record=$(fake_record "$home" 1 lease-one)
  fake_env "$home" "$SCHED" install --home "$home" --state "$home/state" --record "$record" \
    || fail "install alias failed"
  record=$(fake_record "$home" 2 lease-two)
  fake_env "$home" "$SCHED" controlled-replacement --home "$home" --state "$home/state" --record "$record" \
    || fail "controlled-replacement alias failed"
  status=$(fake_env "$home" "$SCHED" status --home "$home" --state "$home/state" --json)
  [ "$(printf '%s' "$status" | jq -r '.generation')" = 2 ] || fail "replacement did not publish generation 2: $status"
  [ "$(printf '%s' "$status" | jq -r '.lease_id')" = lease-two ] || fail "replacement did not publish lease-two: $status"
  pass "fm-codex-systemd-scheduler: install and controlled-replacement aliases publish one active generation"
}

# --- the shipping real-mode branch, driven through the stub (F-3/F-5) ---------

real_home_with_schedule() {  # <name> -> prints "<home>"; record at $home/record.json
  local name=$1 home record
  home=$(make_home "$name")
  write_stub_systemctl "$home"
  record=$(real_record "$home" 1 lease-one)
  real_env "$home" "$SCHED" schedule --home "$home" --state "$home/state" --record "$record" \
    || fail "real-mode schedule failed for $name"
  printf '%s\n' "$home"
}

real_meta() {  # <home>
  real_env "$1" "$SCHED" unit-metadata --home "$1" --state "$1/state"
}

real_validate_reason() {  # <home> - prints the (possibly empty) failure reason
  local home=$1 out
  out=$(real_env "$home" "$SCHED" validate --home "$home" --state "$home/state" --record "$home/record.json" --json 2>/dev/null || true)
  printf '%s' "$out" | jq -r '.reason // empty' 2>/dev/null
}

test_real_mode_schedule_generates_exact_unit_contract() {
  local home meta service_path timer_path exec_path due calendar validation
  home=$(real_home_with_schedule real-lifecycle)
  meta=$(real_meta "$home")
  service_path=$(printf '%s' "$meta" | jq -r '.service_path')
  timer_path=$(printf '%s' "$meta" | jq -r '.timer_path')
  exec_path=$(printf '%s' "$meta" | jq -r '.exec_path')
  assert_present "$service_path" "real-mode schedule did not write the service unit"
  assert_present "$timer_path" "real-mode schedule did not write the timer unit"
  [ "$(file_mode "$service_path")" = 600 ] || fail "service unit was not written with restrictive 0600 mode"
  [ "$(file_mode "$timer_path")" = 600 ] || fail "timer unit was not written with restrictive 0600 mode"
  assert_grep "ExecStart=$exec_path --seconds 60" "$service_path" "service ExecStart is not the adapter-constructed command"
  [ "$(grep -c '^ExecStart=' "$service_path")" = 1 ] || fail "service unit carries more than one ExecStart"
  assert_grep 'Environment="FM_CODEX_SYSTEMD_LEASE=lease-one"' "$service_path" "service unit lost the lease environment line"
  assert_grep 'Environment="FM_CODEX_SYSTEMD_GENERATION=1"' "$service_path" "service unit lost the generation environment line"
  assert_grep 'Environment="FM_CODEX_WATCH_CHECKPOINT=60"' "$service_path" "service unit lost the cadence environment line"
  due=$(jq -r '.next_checkpoint_due' "$home/record.json")
  calendar=$(date -u -d "@$due" '+%Y-%m-%d %H:%M:%S UTC')
  assert_grep "OnCalendar=$calendar" "$timer_path" "timer OnCalendar does not match the record due time"
  [ -f "$home/stub-state/enabled-$(printf '%s' "$meta" | jq -r '.timer_name')" ] \
    || fail "real-mode schedule did not enable the timer"
  validation=$(real_env "$home" "$SCHED" validate --home "$home" --state "$home/state" --record "$home/record.json" --json) \
    || fail "real-mode validate failed on a freshly armed contract"
  [ "$(printf '%s' "$validation" | jq -r '.ok')" = true ] || fail "real-mode validate did not report ok: $validation"
  real_env "$home" "$SCHED" remove --home "$home" --state "$home/state" || fail "real-mode remove failed"
  assert_absent "$service_path" "remove left the service unit behind"
  assert_absent "$timer_path" "remove left the timer unit behind"
  if real_env "$home" "$SCHED" validate --home "$home" --state "$home/state" --record "$home/record.json" --json >/dev/null 2>&1; then
    fail "removed scheduler still validated healthy"
  fi
  pass "fm-codex-systemd-scheduler: real mode writes, arms, validates, and removes the exact unit contract"
}

test_real_mode_rejects_altered_exec_start() {
  local home meta service_path reason
  home=$(real_home_with_schedule real-exec-tamper)
  meta=$(real_meta "$home")
  service_path=$(printf '%s' "$meta" | jq -r '.service_path')
  sed -i 's|^ExecStart=.*|ExecStart=/bin/true|' "$service_path"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "exec-start-mismatch" "altered ExecStart must fail validation"
  pass "fm-codex-systemd-scheduler: real mode reads back and rejects an altered service command"
}

test_real_mode_rejects_disabled_timer() {
  local home meta timer reason
  home=$(real_home_with_schedule real-disabled)
  meta=$(real_meta "$home")
  timer=$(printf '%s' "$meta" | jq -r '.timer_name')
  rm -f "$home/stub-state/enabled-$timer"
  printf 'active' > "$home/stub-state/override-$timer-ActiveState"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "timer-not-enabled" "a disabled-but-active timer must fail validation"
  pass "fm-codex-systemd-scheduler: real mode rejects a timer that would not survive re-login"
}

test_real_mode_rejects_missing_timer() {
  local home meta timer_path reason
  home=$(real_home_with_schedule real-missing-timer)
  meta=$(real_meta "$home")
  timer_path=$(printf '%s' "$meta" | jq -r '.timer_path')
  rm -f "$timer_path"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "timer-not-registered" "a missing timer must fail validation"
  pass "fm-codex-systemd-scheduler: real mode rejects a missing timer"
}

test_real_mode_rejects_next_elapse_disagreement() {
  local home meta timer_path reason
  home=$(real_home_with_schedule real-next-elapse)
  meta=$(real_meta "$home")
  timer_path=$(printf '%s' "$meta" | jq -r '.timer_path')
  sed -i 's|^OnCalendar=.*|OnCalendar=2036-01-01 00:00:00 UTC|' "$timer_path"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "calendar-mismatch" "a decade-off timer trigger must fail validation"
  assert_contains "$reason" "next-elapse-mismatch" "the timer real next-elapse must be compared to the record due time"
  pass "fm-codex-systemd-scheduler: real mode compares the timer's real next trigger to the record due time"
}

test_real_mode_rejects_trigger_mismatch() {
  local home meta timer reason
  home=$(real_home_with_schedule real-trigger)
  meta=$(real_meta "$home")
  timer=$(printf '%s' "$meta" | jq -r '.timer_name')
  printf 'someone-elses.service' > "$home/stub-state/override-$timer-Triggers"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "trigger-mismatch" "a timer triggering another service must fail validation"
  pass "fm-codex-systemd-scheduler: real mode requires the timer to trigger the expected service"
}

test_real_mode_rejects_duplicate_unit_for_home() {
  local home meta service_path reason
  home=$(real_home_with_schedule real-duplicate-unit)
  meta=$(real_meta "$home")
  service_path=$(printf '%s' "$meta" | jq -r '.service_path')
  cp "$service_path" "$home/units/fm-codex-checkpoint-feedbeefdeadbeef.service"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "duplicate-unit" "a second unit claiming this home must fail validation"
  pass "fm-codex-systemd-scheduler: real mode refuses duplicate unit ownership of one home"
}

# --- unit-file injection (review finding F-4) ----------------------------------

test_real_mode_rejects_directive_injection_in_lease() {
  local home record status out
  home=$(make_home real-inject-lease)
  write_stub_systemctl "$home"
  record=$(real_record "$home" 1 safe-lease)
  jq -c --arg lease $'ok\nExecStart=/bin/sh -c "id > /tmp/fm-INJECTED-PROOF.txt"' \
    '.lease_id = $lease' "$record" > "$record.tmp" && mv "$record.tmp" "$record"
  status=0
  out=$(real_env "$home" "$SCHED" schedule --home "$home" --state "$home/state" --record "$record" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "schedule accepted a lease with an embedded unit directive"
  assert_contains "$out" "bad-lease" "injection refusal must name the invalid lease"
  if grep -r "INJECTED" "$home/units" >/dev/null 2>&1; then
    fail "an injected directive reached a generated unit file"
  fi
  status=0
  real_env "$home" "$SCHED" validate --home "$home" --state "$home/state" --record "$record" --json >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "validate accepted a lease with an embedded unit directive"
  pass "fm-codex-systemd-scheduler: record fields with embedded directives never reach a unit file"
}

test_real_mode_rejects_non_numeric_cadence() {
  local home record status out
  home=$(make_home real-inject-cadence)
  write_stub_systemctl "$home"
  record=$(real_record "$home" 1 lease-one)
  jq -c '.cadence_seconds = "60 --seconds 1"' "$record" > "$record.tmp" && mv "$record.tmp" "$record"
  status=0
  out=$(real_env "$home" "$SCHED" schedule --home "$home" --state "$home/state" --record "$record" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "schedule accepted a non-numeric cadence"
  assert_contains "$out" "bad-cadence" "cadence refusal must name the invalid field"
  pass "fm-codex-systemd-scheduler: only validated numeric cadence reaches the service command"
}

test_fake_mode_rejects_invalid_record_fields() {
  local home record status
  home=$(make_home fake-bad-fields)
  record=$(fake_record "$home" 1 lease-one)
  jq -c '.lease_id = "bad lease with spaces"' "$record" > "$record.tmp" && mv "$record.tmp" "$record"
  status=0
  fake_env "$home" "$SCHED" schedule --home "$home" --state "$home/state" --record "$record" 2>/dev/null || status=$?
  [ "$status" -ne 0 ] || fail "fake schedule accepted an invalid lease"
  pass "fm-codex-systemd-scheduler: fake mode applies the same record-field validation"
}

test_fake_dir_without_test_mode_fails_closed
test_stub_systemctl_without_test_unit_dir_fails_closed
test_test_overrides_require_test_owned_home
test_metadata_is_deterministic_and_home_scoped
test_schedule_query_validate_disable_remove
test_alias_verbs_replace_generation
test_real_mode_schedule_generates_exact_unit_contract
test_real_mode_rejects_altered_exec_start
test_real_mode_rejects_disabled_timer
test_real_mode_rejects_missing_timer
test_real_mode_rejects_next_elapse_disagreement
test_real_mode_rejects_trigger_mismatch
test_real_mode_rejects_duplicate_unit_for_home
test_real_mode_rejects_directive_injection_in_lease
test_real_mode_rejects_non_numeric_cadence
test_fake_mode_rejects_invalid_record_fields

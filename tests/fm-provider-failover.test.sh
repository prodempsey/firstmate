#!/usr/bin/env bash
# Behavior tests for the provider/harness circuit-breaker helper and CLI.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-provider-failover.sh"
TMP_ROOT=$(fm_test_tmproot fm-provider-failover)

test_missing_state_is_enabled() {
  local home fakebin out rc
  home="$TMP_ROOT/missing"; mkdir -p "$home/state"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" codex

  set +e
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$PATH" bash -c \
    '. "$1"; fm_failover_candidate_reason codex openai' _ "$HELPER" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "missing failover state should leave a candidate enabled"
  [ -z "$out" ] || fail "enabled candidate unexpectedly printed a reason: $out"
  pass "provider failover helper treats missing state as fully enabled"
}

test_cli_disable_and_enable_provider() {
  local home state out rc
  home="$TMP_ROOT/cli"; mkdir -p "$home/state"
  state="$home/state/provider-failover.json"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$HELPER" disable provider openai --reason "usage limit" --until "2099-01-01T00:00:00Z" >/dev/null
  assert_grep '"disabled": true' "$state" "disable did not write an open provider circuit"
  assert_grep '"reason": "usage limit"' "$state" "disable did not persist its reason"

  set +e
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash -c \
    '. "$1"; fm_failover_disabled provider openai' _ "$HELPER" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "new provider circuit should be disabled"
  assert_contains "$out" "usage limit" "disabled provider reason was not returned"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$HELPER" enable provider openai >/dev/null
  set +e
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash -c \
    '. "$1"; fm_failover_disabled provider openai' _ "$HELPER" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "enable should close the provider circuit"
  pass "provider failover CLI disables and enables providers atomically"
}

test_harness_disable_reason_precedes_provider() {
  local home fakebin out rc
  home="$TMP_ROOT/harness"; mkdir -p "$home/state"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" codex
  printf '%s\n' '{"version":1,"providers":{"openai":{"disabled":true,"reason":"provider reason"}},"harnesses":{"codex":{"disabled":true,"reason":"harness reason"}}}' \
    > "$home/state/provider-failover.json"

  set +e
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$PATH" bash -c \
    '. "$1"; fm_failover_candidate_reason codex openai' _ "$HELPER" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "disabled harness should make the candidate unavailable"
  assert_contains "$out" "harness 'codex' disabled: harness reason" "harness circuit reason was not preferred"
  pass "harness circuit is checked before its provider circuit"
}

test_missing_state_is_enabled
test_cli_disable_and_enable_provider
test_harness_disable_reason_precedes_provider

echo "# all fm-provider-failover tests passed"

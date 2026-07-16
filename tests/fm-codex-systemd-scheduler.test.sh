#!/usr/bin/env bash
# Tests for the Codex systemd user scheduler adapter.
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

schedule_record() {  # <home> <generation> <lease>
  local home=$1 generation=$2 lease=$3 now payload hash meta
  now=$(date +%s)
  meta=$(FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" "$SCHED" unit-metadata --home "$home" --state "$home/state") \
    || fail "unit metadata failed"
  payload=$(jq -cnS \
    --argjson scheduler "$meta" \
    --arg lease "$lease" \
    --arg home "$home" \
    --arg state "$home/state" \
    --argjson now "$now" \
    --argjson generation "$generation" \
    '{version:1,harness:"codex",owner:"codex:test:codex",primary_identity:"test:codex",
      fm_home:$home,state_dir:$state,previous_checkpoint_start:($now - 2),
      previous_checkpoint_end:($now - 1),previous_result:"quiet",
      next_checkpoint_due:($now + 60),cadence_seconds:60,max_lateness_seconds:60,
      generation:$generation,lease_id:$lease,mechanism:"codex-bounded-checkpoint",
      scheduling_mechanism:"systemd-user-timer",scheduler:$scheduler}') || fail "payload build failed"
  hash=$(printf '%s\n' "$payload" | sha256sum | awk '{print $1}')
  printf '%s\n' "$payload" | jq -cS --arg integrity "sha256:$hash" '. + {integrity:$integrity}' \
    > "$home/record.json" || fail "record write failed"
  printf '%s\n' "$home/record.json"
}

test_metadata_is_deterministic_and_home_scoped() {
  local home other a b c
  home=$(make_home metadata-a)
  other=$(make_home metadata-b)
  a=$(FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" "$SCHED" unit-metadata --home "$home" --state "$home/state")
  b=$(FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" "$SCHED" unit-metadata --home "$home" --state "$home/state")
  c=$(FM_CODEX_SYSTEMD_FAKE_DIR="$other/fake-systemd" "$SCHED" unit-metadata --home "$other" --state "$other/state")
  [ "$(printf '%s' "$a" | jq -r '.timer_name')" = "$(printf '%s' "$b" | jq -r '.timer_name')" ] \
    || fail "unit metadata is not deterministic for the same home"
  [ "$(printf '%s' "$a" | jq -r '.timer_name')" != "$(printf '%s' "$c" | jq -r '.timer_name')" ] \
    || fail "unit metadata did not vary by canonical home"
  pass "fm-codex-systemd-scheduler: metadata is deterministic and scoped by home"
}

test_schedule_query_validate_disable_remove() {
  local home record status validation
  home=$(make_home lifecycle)
  record=$(schedule_record "$home" 1 lease-one)
  FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" "$SCHED" schedule --home "$home" --state "$home/state" --record "$record" \
    || fail "schedule command failed"
  status=$(FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" "$SCHED" query --home "$home" --state "$home/state" --json) \
    || fail "query command failed"
  [ "$(printf '%s' "$status" | jq -r '.registered')" = true ] || fail "query did not report registered timer: $status"
  validation=$(FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" "$SCHED" validate --home "$home" --state "$home/state" --record "$record" --json) \
    || fail "validate command failed"
  [ "$(printf '%s' "$validation" | jq -r '.ok')" = true ] || fail "validate did not report ok: $validation"
  FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" "$SCHED" disable --home "$home" --state "$home/state" \
    || fail "disable command failed"
  if FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" "$SCHED" validate --home "$home" --state "$home/state" --record "$record" --json >/dev/null 2>&1; then
    fail "disabled scheduler still validated healthy"
  fi
  FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" "$SCHED" remove --home "$home" --state "$home/state" \
    || fail "remove command failed"
  status=$(FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" "$SCHED" status --home "$home" --state "$home/state" --json) \
    || fail "status command failed after remove"
  [ "$(printf '%s' "$status" | jq -r '.registered')" = false ] || fail "remove left scheduler registered: $status"
  pass "fm-codex-systemd-scheduler: schedule/query/validate/disable/remove lifecycle works in fake mode"
}

test_alias_verbs_replace_generation() {
  local home record status
  home=$(make_home aliases)
  record=$(schedule_record "$home" 1 lease-one)
  FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" "$SCHED" install --home "$home" --state "$home/state" --record "$record" \
    || fail "install alias failed"
  record=$(schedule_record "$home" 2 lease-two)
  FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" "$SCHED" controlled-replacement --home "$home" --state "$home/state" --record "$record" \
    || fail "controlled-replacement alias failed"
  status=$(FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" "$SCHED" status --home "$home" --state "$home/state" --json)
  [ "$(printf '%s' "$status" | jq -r '.generation')" = 2 ] || fail "replacement did not publish generation 2: $status"
  [ "$(printf '%s' "$status" | jq -r '.lease_id')" = lease-two ] || fail "replacement did not publish lease-two: $status"
  pass "fm-codex-systemd-scheduler: install and controlled-replacement aliases publish one active generation"
}

test_metadata_is_deterministic_and_home_scoped
test_schedule_query_validate_disable_remove
test_alias_verbs_replace_generation

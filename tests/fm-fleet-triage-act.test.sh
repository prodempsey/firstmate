#!/usr/bin/env bash
# Behavior tests for the one mechanical fleet-triage auto-action.
#
# The load-bearing property under test is that fm-fleet-triage-act.sh decides nothing:
# it acts only on candidates the enumerator already proved (backlog_hygiene items with a
# done blocker), it defaults to a dry run that changes nothing, and an --apply performs
# the sanctioned domain action FIRST and records the disposition with lineage SECOND -
# never overriding a disposition firstmate already made.
set -u

# shellcheck disable=SC1091 # Dynamic test-library path is resolved from BASH_SOURCE.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck disable=SC2153 # ROOT is provided by tests/lib.sh.
ACT="$ROOT/bin/fm-fleet-triage-act.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-triage-act)

new_world() {
  local name=$1 world root home fakebin
  world="$TMP_ROOT/$name"
  root="$world/root"
  home="$world/home"
  mkdir -p "$root/bin" "$home/state" "$home/data"
  cp "$ACT" "$ROOT/bin/fm-fleet-triage.sh" "$ROOT/bin/fm-fleet-triage-lib.sh" \
    "$ROOT/bin/fm-supervision-lib.sh" \
    "$ROOT/bin/fm-fleet-triage-record.sh" "$ROOT/bin/fm-tasks-axi-lib.sh" "$root/bin/"
  chmod +x "$root/bin/fm-fleet-triage-act.sh" "$root/bin/fm-fleet-triage.sh" \
    "$root/bin/fm-fleet-triage-record.sh"
  cat > "$root/bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$FM_TEST_SNAPSHOT"
SH
  chmod +x "$root/bin/fm-fleet-snapshot.sh"
  # A compatible fake tasks-axi: answers the shared compatibility probe and logs every
  # unblock invocation verbatim, so a test can assert exactly what was (not) executed.
  fakebin=$(fm_fakebin "$world")
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf 'tasks-axi 0.2.2\n' ;;
  update) printf 'usage: tasks-axi update <id> --body-file <path> --archive-body\n' ;;
  mv) printf 'usage: tasks-axi mv [<id>...]\n' ;;
  unblock) printf '%s\n' "$*" >> "$FM_TEST_AXI_LOG"; exit "${FM_TEST_AXI_RC:-0}" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/tasks-axi"
  printf '%s|%s|%s\n' "$root" "$home" "$fakebin"
}

own_lock() {  # <home>
  printf '%s\n' "$$" > "$1/state/.lock"
}

# Two provably-unblockable rows, one merely ready row, and one row whose blocker is NOT
# done. Only the first two are blocker_done candidates; touching either of the others
# would be the auto-action inventing a decision.
act_snapshot() {
  cat <<'EOF'
{"backlog":{"records":[
  {"order":1,"state":"queued","structured":true,"id":"ready-q1","title":"Ready queued work","blocked_by":null},
  {"order":2,"state":"done","structured":true,"id":"blocker-d1","title":"Completed blocker","blocked_by":null},
  {"order":3,"state":"queued","structured":true,"id":"unblocked-q2","title":"Now unblocked","blocked_by":"blocker-d1"},
  {"order":4,"state":"done","structured":true,"id":"blocker-d2","title":"Second completed blocker","blocked_by":null},
  {"order":5,"state":"queued","structured":true,"id":"unblocked-q3","title":"Also unblocked","blocked_by":"blocker-d2"},
  {"order":6,"state":"queued","structured":true,"id":"still-blocked-q4","title":"Still blocked","blocked_by":"ready-q1"}
]},"scout_reports":[],"tasks":[]}
EOF
}

# The same fleet after unblocked-q2's row actually lost its blocked-by marker.
unblocked_snapshot() {
  cat <<'EOF'
{"backlog":{"records":[
  {"order":1,"state":"done","structured":true,"id":"blocker-d1","title":"Completed blocker","blocked_by":null},
  {"order":2,"state":"queued","structured":true,"id":"unblocked-q2","title":"Now unblocked","blocked_by":null}
]},"scout_reports":[],"tasks":[]}
EOF
}

run_act() {  # <root> <home> <fakebin> [args...]
  local root=$1 home=$2 fakebin=$3
  shift 3
  FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_FLEET_TRIAGE_BUG_CLI=off \
    FM_TEST_AXI_LOG="$home/axi.log" \
    PATH="$fakebin:$PATH" \
    "$root/bin/fm-fleet-triage-act.sh" "$@"
}

run_triage() {  # <root> <home> [args...]
  local root=$1 home=$2
  shift 2
  FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_FLEET_TRIAGE_BUG_CLI=off \
    "$root/bin/fm-fleet-triage.sh" "$@"
}

run_record() {  # <root> <home> [args...]
  local root=$1 home=$2
  shift 2
  FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_FLEET_TRIAGE_BUG_CLI=off \
    "$root/bin/fm-fleet-triage-record.sh" "$@"
}

ledger_of() {  # <home>
  printf '%s/data/fleet-triage.jsonl' "$1"
}

split3() {  # <pair> -> sets ROOT_W HOME_W FAKEBIN_W
  ROOT_W=${1%%|*}
  HOME_W=${1#*|}
  FAKEBIN_W=${HOME_W#*|}
  HOME_W=${HOME_W%%|*}
}

test_dry_run_is_default_and_changes_nothing() {
  local pair out
  pair=$(new_world dryrun)
  split3 "$pair"

  # Deliberately no lock: the dry run is read-only and must not require one.
  out=$(FM_TEST_SNAPSHOT="$(act_snapshot)" run_act "$ROOT_W" "$HOME_W" "$FAKEBIN_W" unblock) \
    || fail "the default dry run should succeed"
  assert_contains "$out" 'would unblock: unblocked-q2 --by blocker-d1' \
    "the dry run should name the first provable unblock"
  assert_contains "$out" 'would unblock: unblocked-q3 --by blocker-d2' \
    "the dry run should name the second provable unblock"
  assert_contains "$out" 'dry run: 2 item(s) would be unblocked' \
    "the dry run should summarize and point at --apply"
  assert_not_contains "$out" 'would unblock: ready-q1' \
    "a merely-ready row must never be an unblock candidate"
  assert_not_contains "$out" 'would unblock: still-blocked-q4' \
    "a row whose blocker is not done must never be an unblock candidate"
  assert_absent "$HOME_W/axi.log" "the dry run must not invoke tasks-axi"
  assert_absent "$(ledger_of "$HOME_W")" "the dry run must not write the triage ledger"
  pass "the default dry run reports the provable set and changes nothing"
}

test_apply_unblocks_and_records_lineage() {
  local pair out ev row
  pair=$(new_world apply)
  split3 "$pair"
  own_lock "$HOME_W"

  ev=$(FM_TEST_SNAPSHOT="$(act_snapshot)" run_triage "$ROOT_W" "$HOME_W" --json \
    | jq -r '.items[] | select(.item_id == "backlog_hygiene:unblocked-q2") | .evidence_version')
  [ -n "$ev" ] || fail "fixture should enumerate unblocked-q2 as blocker_done"

  out=$(FM_TEST_SNAPSHOT="$(act_snapshot)" run_act "$ROOT_W" "$HOME_W" "$FAKEBIN_W" unblock --apply) \
    || fail "apply should succeed when every unblock and record lands"
  assert_contains "$out" 'unblocked: unblocked-q2 --by blocker-d1' \
    "apply should report each executed unblock"
  assert_grep 'unblock unblocked-q2 --by blocker-d1' "$HOME_W/axi.log" \
    "apply should run the sanctioned tasks-axi unblock verb"
  assert_grep 'unblock unblocked-q3 --by blocker-d2' "$HOME_W/axi.log" \
    "apply should unblock every provable candidate"
  [ "$(wc -l < "$HOME_W/axi.log" | tr -d ' ')" -eq 2 ] \
    || fail "apply must invoke tasks-axi exactly once per candidate and never for other rows"

  row=$(jq -c 'select(.item_id == "backlog_hygiene:unblocked-q2")' "$(ledger_of "$HOME_W")")
  [ "$(printf '%s' "$row" | jq -r '.event')" = resolve ] \
    || fail "each unblock should record a resolve event"
  [ "$(printf '%s' "$row" | jq -r '.outcome_type')" = resolved ] \
    || fail "the recorded disposition should be a terminal resolved outcome"
  [ "$(printf '%s' "$row" | jq -r '.outcome_link')" = blocker-d1 ] \
    || fail "the disposition must carry its lineage: the completed blocker"
  [ "$(printf '%s' "$row" | jq -r '.evidence_version')" = "$ev" ] \
    || fail "the disposition must bind to the evidence the candidate was enumerated with"
  pass "apply runs the sanctioned unblock and records the disposition with lineage"
}

test_unblocked_item_resurfaces_as_ready_for_dispatch_judgment() {
  local pair out
  pair=$(new_world resurface)
  split3 "$pair"
  own_lock "$HOME_W"

  FM_TEST_SNAPSHOT="$(act_snapshot)" run_act "$ROOT_W" "$HOME_W" "$FAKEBIN_W" unblock --apply >/dev/null \
    || fail "apply should succeed"

  # While the evidence still reads blocker_done, the recorded disposition retires it.
  out=$(FM_TEST_SNAPSHOT="$(act_snapshot)" run_triage "$ROOT_W" "$HOME_W" --json)
  [ "$(printf '%s' "$out" | jq -r '.items[] | select(.item_id == "backlog_hygiene:unblocked-q2") | .actionable')" = false ] \
    || fail "a recorded unblock disposition should retire the blocker_done item"

  # Once the row actually loses its blocked-by marker, the SAME logical item comes back
  # as ready with moved evidence: dispatching it is firstmate's judgment, so the
  # auto-action must leave that decision open rather than pre-handling the ready item.
  out=$(FM_TEST_SNAPSHOT="$(unblocked_snapshot)" run_triage "$ROOT_W" "$HOME_W" --json)
  [ "$(printf '%s' "$out" | jq -r '.items[] | select(.item_id == "backlog_hygiene:unblocked-q2") | .status')" = ready ] \
    || fail "the unblocked row should re-enumerate as ready"
  [ "$(printf '%s' "$out" | jq -r '.items[] | select(.item_id == "backlog_hygiene:unblocked-q2") | .health')" = evidence_changed ] \
    || fail "the moved evidence should invalidate the mechanical disposition"
  [ "$(printf '%s' "$out" | jq -r '.items[] | select(.item_id == "backlog_hygiene:unblocked-q2") | .actionable')" = true ] \
    || fail "the ready item must return to firstmate for the dispatch judgment"
  pass "the auto-action leaves the dispatch judgment open by re-surfacing the ready item"
}

test_apply_does_not_override_a_recorded_disposition() {
  local pair out
  pair=$(new_world dispositioned)
  split3 "$pair"
  own_lock "$HOME_W"

  # firstmate already decided this one stays blocked-looking (a hold, a rejection): the
  # mechanical action must treat that decision as final, not as an unblock candidate.
  FM_TEST_SNAPSHOT="$(act_snapshot)" run_record "$ROOT_W" "$HOME_W" \
    reject backlog_hygiene:unblocked-q2 --reason 'deliberately staying sequenced' >/dev/null \
    || fail "fixture rejection should record"

  out=$(FM_TEST_SNAPSHOT="$(act_snapshot)" run_act "$ROOT_W" "$HOME_W" "$FAKEBIN_W" unblock --apply) \
    || fail "apply should still succeed for the remaining candidate"
  assert_not_contains "$out" 'unblocked-q2' \
    "a dispositioned item must not be re-acted on"
  assert_grep 'unblock unblocked-q3 --by blocker-d2' "$HOME_W/axi.log" \
    "the still-actionable candidate should still be unblocked"
  [ "$(wc -l < "$HOME_W/axi.log" | tr -d ' ')" -eq 1 ] \
    || fail "only the actionable candidate may be unblocked"
  pass "apply never overrides a disposition firstmate already recorded"
}

test_apply_requires_the_lock() {
  local pair out
  pair=$(new_world lock)
  split3 "$pair"

  out=$(FM_TEST_SNAPSHOT="$(act_snapshot)" run_act "$ROOT_W" "$HOME_W" "$FAKEBIN_W" unblock --apply 2>&1) \
    && fail "apply without the session lock must be refused"
  assert_contains "$out" 'does not own the fleet session lock' \
    "the refusal should name the lock"
  assert_absent "$HOME_W/axi.log" "a refused apply must not invoke tasks-axi"
  assert_absent "$(ledger_of "$HOME_W")" "a refused apply must not write the ledger"
  pass "apply is refused without the per-home session lock"
}

test_enumerate_only_blocks_apply_but_not_the_dry_run() {
  local pair out
  pair=$(new_world killswitch)
  split3 "$pair"
  own_lock "$HOME_W"

  out=$(FM_TEST_SNAPSHOT="$(act_snapshot)" FLEET_TRIAGE_MODE=enumerate_only \
    run_act "$ROOT_W" "$HOME_W" "$FAKEBIN_W" unblock --apply 2>&1) \
    && fail "enumerate_only must refuse apply even for the lock owner"
  assert_contains "$out" 'enumerate_only' "the refusal should name the kill switch"
  assert_absent "$HOME_W/axi.log" "enumerate_only must not invoke tasks-axi"

  out=$(FM_TEST_SNAPSHOT="$(act_snapshot)" FLEET_TRIAGE_MODE=enumerate_only \
    run_act "$ROOT_W" "$HOME_W" "$FAKEBIN_W" unblock) \
    || fail "enumerate_only still inspects and reports"
  assert_contains "$out" 'would unblock: unblocked-q2' \
    "the dry run is report-only and stays available under enumerate_only"
  pass "enumerate-only mode blocks the domain action but keeps the report"
}

test_manual_backlog_backend_refuses_apply() {
  local pair out
  pair=$(new_world manual)
  split3 "$pair"
  own_lock "$HOME_W"
  mkdir -p "$HOME_W/config"
  printf 'manual\n' > "$HOME_W/config/backlog-backend"

  out=$(FM_TEST_SNAPSHOT="$(act_snapshot)" run_act "$ROOT_W" "$HOME_W" "$FAKEBIN_W" unblock --apply 2>&1) \
    && fail "apply must be refused when the backlog backend is manual"
  assert_contains "$out" 'tasks-axi backlog backend is unavailable' \
    "the refusal should name the unavailable backend"
  assert_absent "$HOME_W/axi.log" "a refused apply must not invoke tasks-axi"
  pass "a manual backlog backend refuses the auto-action instead of hand-editing"
}

test_failed_unblock_is_reported_and_not_recorded() {
  local pair out
  pair=$(new_world axifail)
  split3 "$pair"
  own_lock "$HOME_W"

  out=$(FM_TEST_SNAPSHOT="$(act_snapshot)" FM_TEST_AXI_RC=1 \
    run_act "$ROOT_W" "$HOME_W" "$FAKEBIN_W" unblock --apply 2>&1) \
    && fail "apply must exit non-zero when an unblock fails"
  assert_contains "$out" 'failed' "a failed unblock should be reported"
  assert_absent "$(ledger_of "$HOME_W")" \
    "a disposition must never be recorded for a domain action that did not happen"
  pass "a failed unblock is reported, exits non-zero, and records nothing"
}

test_nothing_to_unblock_reports_cleanly() {
  local pair out snap
  pair=$(new_world quiet)
  split3 "$pair"
  own_lock "$HOME_W"
  snap='{"backlog":{"records":[{"order":1,"state":"queued","structured":true,"id":"ready-q1","title":"Ready","blocked_by":null}]},"scout_reports":[],"tasks":[]}'

  out=$(FM_TEST_SNAPSHOT="$snap" run_act "$ROOT_W" "$HOME_W" "$FAKEBIN_W" unblock --apply) \
    || fail "an empty candidate set is a healthy state, not a failure"
  assert_contains "$out" 'nothing to unblock' "the empty case should say so"
  assert_absent "$HOME_W/axi.log" "an empty candidate set must not invoke tasks-axi"
  pass "an empty candidate set exits cleanly without acting"
}

test_unknown_arguments_are_refused() {
  local pair rc
  pair=$(new_world args)
  split3 "$pair"

  FM_TEST_SNAPSHOT="$(act_snapshot)" run_act "$ROOT_W" "$HOME_W" "$FAKEBIN_W" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "a missing action"
  FM_TEST_SNAPSHOT="$(act_snapshot)" run_act "$ROOT_W" "$HOME_W" "$FAKEBIN_W" frobnicate >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "an unknown action"
  FM_TEST_SNAPSHOT="$(act_snapshot)" run_act "$ROOT_W" "$HOME_W" "$FAKEBIN_W" unblock --frob >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "an unknown option"
  FM_TEST_SNAPSHOT="$(act_snapshot)" run_act "$ROOT_W" "$HOME_W" "$FAKEBIN_W" --help >/dev/null 2>&1 \
    || fail "--help should print usage and exit zero"
  pass "unknown actions and options are refused with usage"
}

test_dry_run_is_default_and_changes_nothing
test_apply_unblocks_and_records_lineage
test_unblocked_item_resurfaces_as_ready_for_dispatch_judgment
test_apply_does_not_override_a_recorded_disposition
test_apply_requires_the_lock
test_enumerate_only_blocks_apply_but_not_the_dry_run
test_manual_backlog_backend_refuses_apply
test_failed_unblock_is_reported_and_not_recorded
test_nothing_to_unblock_reports_cleanly
test_unknown_arguments_are_refused

printf 'fm-fleet-triage-act tests passed\n'

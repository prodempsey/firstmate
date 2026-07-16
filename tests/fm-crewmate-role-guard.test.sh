#!/usr/bin/env bash
# crew-role-guard-r2 - operation-level role enforcement. Proves the canonical
# role-context resolver classifies primary/crewmate/unknown from DURABLE evidence
# (not FM_CREWMATE alone) and FAILS CLOSED, and that the permission matrix guards
# mutating primary-only subcommands while leaving read-only inspection open to
# crewmates. Isolated fixtures + fake task/worktree metadata; never the live fleet.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity

ROLE_LIB="$ROOT/bin/fm-role-context-lib.sh"
GOVERN="$ROOT/bin/fm-govern.sh"
HOLD="$ROOT/bin/fm-hold.sh"
FREEZE="$ROOT/bin/fm-freeze-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-crewmate-role-guard)
export FM_GOV_NOW=2026-07-16T00:00:00Z

# Fixture: a primary home + a registered crew worktree with a durable marker.
HOME_DIR="$TMP_ROOT/home"; mkdir -p "$HOME_DIR/state/holds"
PRIMARY_DIR="$HOME_DIR/work"; mkdir -p "$PRIMARY_DIR"   # a primary-side dir UNDER the home
NEUTRAL_DIR="$TMP_ROOT/neutral"; mkdir -p "$NEUTRAL_DIR" # not under home, not a worktree
CREW_WT="$TMP_ROOT/crew-wt"; fm_git_init_commit "$CREW_WT"
printf 'task_id=demo-task\nprimary_home=%s\nkind=ship\n' "$HOME_DIR" > "$CREW_WT/.fm-crew-role"
fm_write_meta "$HOME_DIR/state/demo-task.meta" "window=x" "worktree=$CREW_WT" "kind=ship"

# role_context at a given cwd with given extra env; prints the verdict.
role_at() {  # <cwd> [KEY=VAL ...]
  local cwd=$1; shift
  ( cd "$cwd" && env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$@" \
      bash -c '. "'"$ROLE_LIB"'"; fm_role_context' )
}

# 1 + 18: a primary (under its home, no crew evidence) resolves primary and may mutate.
test_primary_under_home_allowed() {
  local role
  role=$(role_at "$PRIMARY_DIR")
  [ "$role" = primary ] || fail "a primary-home dir must resolve primary, got '$role'"
  ( cd "$PRIMARY_DIR" && FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$HOLD" add --kind milestone --value m-ok --reason x >/dev/null 2>&1 ) \
    || fail "a primary must be able to add a hold"
  pass "a primary (under its home) resolves primary and may run primary-only mutations"
}

# BLOCKER-1 regression: a crew that cd's OUT to a neutral dir AND clears its env has no
# positive primary evidence -> unknown -> fail closed (must NOT become primary).
test_cd_out_neutral_fails_closed() {
  local role out status
  role=$( cd "$NEUTRAL_DIR" && env -u FM_CREWMATE -u FM_TASK_ID FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" bash -c '. "'"$ROLE_LIB"'"; fm_role_context' )
  [ "$role" = unknown ] || fail "cd-out neutral dir with cleared env must be unknown (fail closed), got '$role'"
  out=$( cd "$NEUTRAL_DIR" && env -u FM_CREWMATE -u FM_TASK_ID FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$HOLD" add --kind milestone --value esc --reason r 2>&1 ); status=$?
  expect_code 2 "$status" "a mutation from a neutral dir with no primary evidence must fail closed"
  pass "a crew that cd's out and clears its env fails closed (BLOCKER-1 fixed)"
}

# 2 + 9: a crewmate (durable marker) is refused from a primary-only mutation.
test_crewmate_refused_hold_add() {
  local out status
  out=$( cd "$CREW_WT" && FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CREWMATE=1 "$HOLD" add --kind milestone --value m-x --reason y 2>&1 ); status=$?
  expect_code 2 "$status" "crewmate must be refused from hold add"
  assert_contains "$out" "crewmate" "refusal must name the crewmate role"
  assert_contains "$out" ".fm-crew-role marker" "refusal must name the deciding evidence (diagnostic propagates)"
  pass "a crewmate is refused from a primary-only mutation, with the deciding evidence named"
}

# 3: a crewmate that UNSETS FM_CREWMATE is still refused via the durable marker.
test_crewmate_unset_env_still_refused() {
  local role status
  role=$( cd "$CREW_WT" && env -u FM_CREWMATE FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" bash -c '. "'"$ROLE_LIB"'"; fm_role_context' )
  [ "$role" = crewmate ] || fail "durable marker must classify crewmate with FM_CREWMATE unset, got '$role'"
  ( cd "$CREW_WT" && env -u FM_CREWMATE FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$HOLD" release --kind milestone --value m --authorization z >/dev/null 2>&1 ); status=$?
  expect_code 2 "$status" "crewmate with unset FM_CREWMATE must still be refused"
  pass "a crewmate that unsets FM_CREWMATE remains refused (durable marker wins)"
}

# MAJOR-2 regression: membership does not collapse to FM_HOME. A crew in a registered
# worktree (no marker) that repoints FM_HOME/FM_PRIMARY_HOME to an empty home is STILL a
# crewmate because membership is resolved from FM_STATE_OVERRIDE (the install-root state
# in the real fleet), not the attacker's FM_HOME.
test_membership_survives_home_repoint() {
  local wt role empty
  wt="$TMP_ROOT/member-wt"; fm_git_init_commit "$wt"   # no marker file
  fm_write_meta "$HOME_DIR/state/member-task.meta" "window=x" "worktree=$wt" "kind=ship"
  empty="$TMP_ROOT/empty-home"; mkdir -p "$empty/state"
  role=$( cd "$wt" && env -u FM_CREWMATE -u FM_TASK_ID FM_HOME="$empty" FM_PRIMARY_HOME="$empty" FM_STATE_OVERRIDE="$HOME_DIR/state" bash -c '. "'"$ROLE_LIB"'"; fm_role_context' )
  [ "$role" = crewmate ] || fail "membership must survive an FM_HOME repoint, got '$role'"
  pass "task-worktree membership survives an FM_HOME/FM_PRIMARY_HOME repoint (MAJOR-2 fixed)"
}

# 4: conflicting signals (env=crewmate but cwd=primary home) fail closed.
test_conflicting_signals_fail_closed() {
  local role status
  role=$( cd "$PRIMARY_DIR" && env FM_CREWMATE=1 FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" bash -c '. "'"$ROLE_LIB"'"; fm_role_context' )
  [ "$role" = unknown ] || fail "conflicting env/cwd must be unknown, got '$role'"
  ( cd "$PRIMARY_DIR" && env FM_CREWMATE=1 FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$HOLD" add --kind milestone --value c --reason r >/dev/null 2>&1 ); status=$?
  expect_code 2 "$status" "conflicting signals must fail closed on a mutation"
  pass "conflicting role signals resolve unknown and fail closed for mutations"
}

# 7: primary inspecting a crew worktree - reads OK, mutation refused-with-reason,
#    explicit audited override allowed + recorded.
test_primary_inspecting_crew_worktree() {
  ( cd "$CREW_WT" && FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$HOLD" check --milestone none >/dev/null 2>&1 ); local rc=$?
  [ "$rc" -ne 2 ] || fail "read-only hold check must not be role-refused"
  local out status
  out=$( cd "$CREW_WT" && FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$HOLD" add --kind milestone --value p --reason r 2>&1 ); status=$?
  expect_code 2 "$status" "a mutation from a crew worktree must be refused"
  assert_contains "$out" "role evidence" "the refusal must explain the deciding evidence"
  out=$( cd "$CREW_WT" && FM_ROLE_OVERRIDE=primary FM_ROLE_OVERRIDE_REASON="captain-authorized recovery" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$HOLD" add --kind milestone --value ovr --reason r 2>&1 ); status=$?
  expect_code 0 "$status" "an explicit audited override must let a primary proceed"
  assert_grep "override=primary" "$HOME_DIR/state/role-override-audit.log" "the override must append an audit record"
  pass "primary inspecting a crew worktree: reads OK, mutation refused-with-reason, override explicit+audited"
}

# 8 + 13: a crewmate CAN run approved read-only govern/hold/freeze inspection.
test_crewmate_readonly_allowed() {
  local rc
  ( cd "$CREW_WT" && FM_CREWMATE=1 FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$GOVERN" classify "docs" docs/x.md >/dev/null 2>&1 ); rc=$?; [ "$rc" -ne 2 ] || fail "crewmate classify must be allowed"
  ( cd "$CREW_WT" && FM_CREWMATE=1 FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$HOLD" check --milestone none >/dev/null 2>&1 ); rc=$?; [ "$rc" -ne 2 ] || fail "crewmate hold check must be allowed"
  ( cd "$CREW_WT" && FM_CREWMATE=1 FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$GOVERN" delivery-check --mode local-only >/dev/null 2>&1 ); rc=$?; [ "$rc" -ne 2 ] || fail "crewmate delivery-check must be allowed"
  fm_write_meta "$HOME_DIR/state/fz.meta" "window=x" "worktree=$CREW_WT" "kind=ship"
  printf '1\t1\t%s\tbash\n' "$CREW_WT" > "$TMP_ROOT/procs.tsv"
  ( cd "$CREW_WT" && FM_CREWMATE=1 FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_FREEZE_PROC_SOURCE="$TMP_ROOT/procs.tsv" "$FREEZE" fz >/dev/null 2>&1 ); rc=$?; [ "$rc" -ne 2 ] || fail "crewmate freeze inspection must be allowed"
  pass "a crewmate may run approved read-only classify/delivery-check, hold check, and freeze inspection"
}

# 10: a crewmate cannot record review/QA/Captain attestation.
test_crewmate_cannot_attest() {
  ( cd "$PRIMARY_DIR" && FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$GOVERN" record init att local-only /r id fm/att b h scope 1 >/dev/null 2>&1 )
  local status
  ( cd "$CREW_WT" && FM_CREWMATE=1 FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$GOVERN" record attest att qa h pass >/dev/null 2>&1 ); status=$?
  expect_code 2 "$status" "crewmate must not record an attestation"
  pass "a crewmate cannot record review/QA/Captain attestation"
}

# 13b: fm-freeze-check --stop (mutating) is refused for a crewmate.
test_crewmate_freeze_stop_refused() {
  local status
  ( cd "$CREW_WT" && FM_CREWMATE=1 FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_FREEZE_PROC_SOURCE="$TMP_ROOT/procs.tsv" "$FREEZE" fz --stop >/dev/null 2>&1 ); status=$?
  expect_code 2 "$status" "crewmate must be refused from freeze --stop"
  pass "fm-freeze-check --stop (mutating) is refused for a crewmate; inspection stays available"
}

# 11 + 12: every guarded mutating command refuses a crewmate (the guard fires before the
# command's own arg handling, so minimal args suffice).
test_all_guarded_mutations_refuse_crewmate() {
  local script args status out
  for spec in \
      "fm-spawn.sh:x projects/none" \
      "fm-teardown.sh:x" \
      "fm-pr-merge.sh:x https://github.com/o/r/pull/1" \
      "fm-merge-local.sh:x" \
      "fm-order.sh:add hello" \
      "fm-config-push.sh:" \
      "fm-home-seed.sh:x" \
      "fm-fleet-triage-record.sh:reject x --reason y" \
      "fm-wake-drain.sh:" \
      "fm-triage-duty.sh:session-start"; do
    script=${spec%%:*}; args=${spec#*:}
    # shellcheck disable=SC2086
    out=$( cd "$CREW_WT" && FM_CREWMATE=1 FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/$script" $args 2>&1 ); status=$?
    expect_code 2 "$status" "crewmate must be refused from $script (got exit $status)"
    assert_contains "$out" "refused" "$script refusal must say refused"
  done
  pass "every guarded mutation (spawn/teardown/merge/pr-merge/order-write/config-push/home-seed/triage-record/wake-drain/triage-duty) refuses a crewmate"
}

# 17: a secondmate (a primary in its OWN home, no crew marker) resolves primary and is
# not a crewmate. Modeled as a home-rooted dir with no crew evidence.
test_secondmate_resolves_primary() {
  local sm role
  sm="$TMP_ROOT/secondmate-home"; mkdir -p "$sm/state/holds"
  role=$( cd "$sm" && env FM_HOME="$sm" FM_STATE_OVERRIDE="$sm/state" bash -c '. "'"$ROLE_LIB"'"; fm_role_context' )
  [ "$role" = primary ] || fail "a secondmate in its own home must resolve primary, got '$role'"
  ( cd "$sm" && FM_HOME="$sm" FM_STATE_OVERRIDE="$sm/state" "$HOLD" add --kind milestone --value sm --reason r >/dev/null 2>&1 ) \
    || fail "a secondmate must be able to run primary-only ops in its own home"
  pass "a secondmate resolves primary in its own home and may run primary-only ops"
}

# 14: this change deletes nothing from the governance package or memory/.
test_governance_controls_preserved() {
  for f in bin/fm-governance-lib.sh bin/fm-govern.sh bin/fm-hold.sh bin/fm-freeze-check.sh; do
    assert_present "$ROOT/$f" "$f must still exist"
  done
  assert_grep "fm_gov_delivery_validate" "$ROOT/bin/fm-governance-lib.sh" "governance rules must be intact"
  pass "the incident-prevention governance controls are preserved (nothing removed)"
}

# 6: an inert shell is not classed as an active mutating agent (freeze classifier).
test_inert_shell_not_active_agent() {
  fm_write_meta "$HOME_DIR/state/inert.meta" "window=x" "worktree=$CREW_WT" "kind=ship"
  printf '5\t1\t%s\tbash\n' "$CREW_WT" > "$TMP_ROOT/inert.tsv"
  ( cd "$PRIMARY_DIR" && FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_FREEZE_PROC_SOURCE="$TMP_ROOT/inert.tsv" "$FREEZE" inert >/dev/null 2>&1 ); local rc=$?
  [ "$rc" -eq 0 ] || fail "an inert shell must not block freeze (not an active crewmate agent)"
  pass "an inert shell is not classed as an active crewmate agent"
}

test_primary_under_home_allowed
test_cd_out_neutral_fails_closed
test_crewmate_refused_hold_add
test_crewmate_unset_env_still_refused
test_membership_survives_home_repoint
test_conflicting_signals_fail_closed
test_primary_inspecting_crew_worktree
test_crewmate_readonly_allowed
test_crewmate_cannot_attest
test_crewmate_freeze_stop_refused
test_all_guarded_mutations_refuse_crewmate
test_secondmate_resolves_primary
test_governance_controls_preserved
test_inert_shell_not_active_agent

pass "fm-crewmate-role-guard: all role-context and permission-matrix cases passed"

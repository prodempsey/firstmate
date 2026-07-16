#!/usr/bin/env bash
# crew-role-guard-r2 - operation-level role enforcement. Proves the canonical
# role-context resolver classifies primary/crewmate/unknown from durable evidence
# (not FM_CREWMATE alone), and that the permission matrix guards mutating
# primary-only subcommands while leaving read-only inspection available to crewmates.
# Isolated fixtures + fake task/worktree metadata; never the live fleet.
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

# --- fixture: a primary home + a registered crew worktree with a durable marker ------
HOME_DIR="$TMP_ROOT/home"; mkdir -p "$HOME_DIR/state/holds"
CREW_WT="$TMP_ROOT/crew-wt"; fm_git_init_commit "$CREW_WT"
printf 'task_id=demo-task\nprimary_home=%s\nkind=ship\n' "$HOME_DIR" > "$CREW_WT/.fm-crew-role"
# register the crew worktree in the primary's state so membership is detectable
fm_write_meta "$HOME_DIR/state/demo-task.meta" "window=x" "worktree=$CREW_WT" "kind=ship"
# a NON-crew dir (a plain primary-side dir, no marker, not a registered worktree)
PRIMARY_DIR="$TMP_ROOT/primary-cwd"; mkdir -p "$PRIMARY_DIR"

# role_context helper: run in a subshell with a given cwd + env, print the verdict.
role_at() {  # <cwd> [env assignments...]
  local cwd=$1; shift
  ( cd "$cwd" && env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$@" \
      bash -c '. "'"$ROLE_LIB"'"; fm_role_context' )
}

# 1 + 18: a primary (clean env) may run authorized primary operations.
test_primary_clean_env_allowed() {
  local role
  role=$(role_at "$PRIMARY_DIR")
  [ "$role" = primary ] || fail "clean env must resolve primary, got '$role'"
  # and a primary-only mutation succeeds
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$HOLD" add --kind milestone --value m-ok --reason x >/dev/null 2>&1 \
    || fail "primary must be able to add a hold"
  pass "a primary (clean env) resolves primary and may run primary-only mutations"
}

# 2 + 9: a crewmate (durable marker) is refused from a primary-only mutation (hold add).
test_crewmate_refused_hold_add() {
  local out status
  out=$( cd "$CREW_WT" && FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CREWMATE=1 "$HOLD" add --kind milestone --value m-x --reason y 2>&1 ); status=$?
  expect_code 2 "$status" "crewmate must be refused from hold add"
  assert_contains "$out" "crewmate" "refusal must name the crewmate role"
  pass "a crewmate is refused from a primary-only mutation (hold add)"
}

# 3: a crewmate that UNSETS FM_CREWMATE is still refused via durable worktree/task evidence.
test_crewmate_unset_env_still_refused() {
  local role out status
  role=$( cd "$CREW_WT" && env -u FM_CREWMATE FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" bash -c '. "'"$ROLE_LIB"'"; fm_role_context' )
  [ "$role" = crewmate ] || fail "durable marker must classify crewmate even with FM_CREWMATE unset, got '$role'"
  out=$( cd "$CREW_WT" && env -u FM_CREWMATE FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$HOLD" release --kind milestone --value m --authorization z 2>&1 ); status=$?
  expect_code 2 "$status" "crewmate with unset FM_CREWMATE must still be refused"
  pass "a crewmate that unsets FM_CREWMATE remains refused (durable marker/membership wins)"
}

# 3b: durable TASK-WORKTREE MEMBERSHIP (no marker file) also classifies crewmate.
test_membership_without_marker_is_crewmate() {
  local wt role
  wt="$TMP_ROOT/member-wt"; fm_git_init_commit "$wt"   # no .fm-crew-role marker
  fm_write_meta "$HOME_DIR/state/member-task.meta" "window=x" "worktree=$wt" "kind=ship"
  role=$( cd "$wt" && env -u FM_CREWMATE FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" bash -c '. "'"$ROLE_LIB"'"; fm_role_context' )
  [ "$role" = crewmate ] || fail "task-worktree membership must classify crewmate, got '$role'"
  pass "task-worktree membership classifies crewmate even without the marker file"
}

# 4: conflicting signals (env=crewmate but cwd=primary home, no durable evidence) fail closed.
test_conflicting_signals_fail_closed() {
  local role out status
  role=$( cd "$HOME_DIR" && env FM_CREWMATE=1 FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" bash -c '. "'"$ROLE_LIB"'"; fm_role_context' )
  [ "$role" = unknown ] || fail "conflicting env/cwd must be unknown, got '$role'"
  out=$( cd "$HOME_DIR" && env FM_CREWMATE=1 FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$HOLD" add --kind milestone --value c --reason r 2>&1 ); status=$?
  expect_code 2 "$status" "conflicting signals must fail closed on a mutation"
  pass "conflicting role signals resolve unknown and fail closed for mutations"
}

# 5: a high-risk mutation with a crew env signal and no primary proof fails closed.
test_high_risk_env_crew_fails_closed() {
  local out status
  # FM_TASK_ID set, cwd a plain dir (not a worktree, no marker) -> crewmate (env) -> refuse.
  out=$( cd "$TMP_ROOT" && env FM_TASK_ID=some-task FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$HOLD" release --kind milestone --value h --authorization a 2>&1 ); status=$?
  expect_code 2 "$status" "a high-risk mutation under a crew env signal must fail closed"
  pass "a high-risk mutation with a crew signal and no primary proof fails closed"
}

# 7: a primary inspecting a crewmate worktree gets no false positive on READ-ONLY ops;
#    a mutation there is refused-but-explained; an explicit audited override is allowed.
test_primary_inspecting_crew_worktree() {
  # read-only from inside the crew worktree is allowed for anyone
  ( cd "$CREW_WT" && FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$HOLD" check --milestone none >/dev/null 2>&1 ); rc=$?
  [ "$rc" -ne 2 ] || fail "read-only hold check must not be role-refused"
  # a mutation from inside the crew worktree is refused, WITH an explanation
  local out status
  out=$( cd "$CREW_WT" && FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$HOLD" add --kind milestone --value p --reason r 2>&1 ); status=$?
  expect_code 2 "$status" "a mutation from a crew worktree must be refused"
  assert_contains "$out" "role evidence" "the refusal must explain the deciding evidence (no unexplained false positive)"
  # explicit, narrow, audited override lets a genuine primary proceed and records an audit line
  out=$( cd "$CREW_WT" && FM_ROLE_OVERRIDE=primary FM_ROLE_OVERRIDE_REASON="captain-authorized recovery" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$HOLD" add --kind milestone --value ovr --reason r 2>&1 ); status=$?
  expect_code 0 "$status" "an explicit audited override must let a primary proceed"
  assert_grep "override=primary" "$HOME_DIR/state/role-override-audit.log" "the override must append an audit record"
  pass "primary inspecting a crew worktree: reads OK, mutation refused-with-reason, override explicit+audited"
}

# 8 + 13: a crewmate CAN run approved read-only governance status/check commands.
test_crewmate_readonly_allowed() {
  local status
  ( cd "$CREW_WT" && FM_CREWMATE=1 FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$GOVERN" classify "docs" docs/x.md >/dev/null 2>&1 ); rc=$?; [ "$rc" -ne 2 ] || fail "crewmate classify must be allowed"
  ( cd "$CREW_WT" && FM_CREWMATE=1 FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$HOLD" check --milestone none >/dev/null 2>&1 ); rc=$?; [ "$rc" -ne 2 ] || fail "crewmate hold check must be allowed"
  ( cd "$CREW_WT" && FM_CREWMATE=1 FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$GOVERN" delivery-check --mode local-only >/dev/null 2>&1 ); rc=$?; [ "$rc" -ne 2 ] || fail "crewmate delivery-check must be allowed"
  # fm-freeze-check read-only inspection available to a crewmate
  fm_write_meta "$HOME_DIR/state/fz.meta" "window=x" "worktree=$CREW_WT" "kind=ship"
  printf '1\t1\t%s\tbash\n' "$CREW_WT" > "$TMP_ROOT/procs.tsv"
  ( cd "$CREW_WT" && FM_CREWMATE=1 FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_FREEZE_PROC_SOURCE="$TMP_ROOT/procs.tsv" "$FREEZE" fz >/dev/null 2>&1 ); rc=$?; [ "$rc" -ne 2 ] || fail "crewmate freeze inspection must be allowed"
  pass "a crewmate may run approved read-only govern classify/delivery-check, hold check, and freeze inspection"
}

# 10: a crewmate cannot record review/QA/Captain authorization.
test_crewmate_cannot_attest() {
  # seed a record as primary first
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$GOVERN" record init att local-only /r id fm/att b h scope 1 >/dev/null 2>&1
  local status
  ( cd "$CREW_WT" && FM_CREWMATE=1 FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$GOVERN" record attest att qa h pass >/dev/null 2>&1 ); status=$?
  expect_code 2 "$status" "crewmate must not record an attestation"
  pass "a crewmate cannot record review/QA/Captain attestation"
}

# 13b: fm-freeze-check --stop (mutating) is refused for a crewmate.
test_crewmate_freeze_stop_refused() {
  local status
  ( cd "$CREW_WT" && FM_CREWMATE=1 FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_FREEZE_PROC_SOURCE="$TMP_ROOT/procs.tsv" "$FREEZE" fz --stop >/dev/null 2>&1 ); status=$?
  expect_code 2 "$status" "crewmate must be refused from freeze --stop (mutating)"
  pass "fm-freeze-check --stop (mutating) is refused for a crewmate; inspection stays available"
}

# 14: the historical stale branch cannot overwrite current governance controls -
#     this change deletes nothing from the governance package or memory/.
test_governance_controls_preserved() {
  for f in bin/fm-governance-lib.sh bin/fm-govern.sh bin/fm-hold.sh bin/fm-freeze-check.sh; do
    assert_present "$ROOT/$f" "$f must still exist (controls not removed)"
  done
  # the governance library itself is untouched by this branch
  assert_grep "fm_gov_delivery_validate" "$ROOT/bin/fm-governance-lib.sh" "governance rules must be intact"
  pass "the incident-prevention governance controls are preserved (nothing removed)"
}

# 15 (smoke): the governance CLIs still function in primary mode after guarding.
test_governance_cli_still_functions() {
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$GOVERN" classify "one" memory/lib/registry.mjs | grep -q 'governed=1' || fail "classify broken"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$HOLD" list >/dev/null 2>&1 || fail "hold list broken"
  pass "the governance CLIs still function in primary mode after role guarding"
}

# 6: an inert shell is not classed as an active mutating agent (freeze-check classifier).
test_inert_shell_not_active_agent() {
  fm_write_meta "$HOME_DIR/state/inert.meta" "window=x" "worktree=$CREW_WT" "kind=ship"
  printf '5\t1\t%s\tbash\n' "$CREW_WT" > "$TMP_ROOT/inert.tsv"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_FREEZE_PROC_SOURCE="$TMP_ROOT/inert.tsv" "$FREEZE" inert >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] || fail "an inert shell must not block freeze (not an active crewmate agent)"
  pass "an inert shell is not classed as an active crewmate agent"
}

test_primary_clean_env_allowed
test_crewmate_refused_hold_add
test_crewmate_unset_env_still_refused
test_membership_without_marker_is_crewmate
test_conflicting_signals_fail_closed
test_high_risk_env_crew_fails_closed
test_primary_inspecting_crew_worktree
test_crewmate_readonly_allowed
test_crewmate_cannot_attest
test_crewmate_freeze_stop_refused
test_governance_controls_preserved
test_governance_cli_still_functions
test_inert_shell_not_active_agent

pass "fm-crewmate-role-guard: all role-context and permission-matrix cases passed"

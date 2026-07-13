#!/usr/bin/env bash
# Behavior tests for the local-only merge gate (bin/fm-merge-local.sh).
#
# The gate is the one place detection is not enough. Startup and audit surfaces
# only REPORT trunk drift; a warning here is exactly what firstmate blew past when
# it landed the next branch into the serving worktree out of habit and pushed
# trunk a commit behind - twice. So these cases pin refusal, not warning:
#   * a landing aimed at anything but the declared canonical trunk is REFUSED
#     (the literal recurrence: the task's project path is the serving worktree);
#   * a landing while trunk is already behind the serving lineage is REFUSED;
#   * a landing that would leave trunk behind serving is REFUSED;
#   * a missing or malformed declaration REFUSES the merge (absence is never a pass);
#   * a legitimate fast-forward onto the DECLARED trunk still lands - the old gate
#     guessed `main` from origin/HEAD and refused a legitimate landing during the
#     convergence, so the target now comes from the declaration;
#   * every refusal names the exact fix and moves no ref.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "ok - fm-merge-local: skipped (no jq)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-merge-local)
fm_git_identity fmtest fmtest@example.invalid

MERGE="$ROOT/bin/fm-merge-local.sh"

# make_fleet <name> [task-id]: a home with state/, a governed project on `main`, a
# separate SERVING worktree, and a finished crew branch fm/<task-id> cut from trunk.
# Sets FLEET_HOME/FLEET_PROJ/FLEET_SERVING/FLEET_ID.
make_fleet() {
  local name=$1
  local id=${2:-task-a1}
  local dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/home/data"
  git init -q -b main "$dir/proj"
  git -C "$dir/proj" commit -q --allow-empty -m X
  git -C "$dir/proj" worktree add -q -b serving "$dir/serving" main
  git -C "$dir/proj" branch "fm/$id" main
  git -C "$dir/proj" worktree add -q "$dir/crew" "fm/$id"
  git -C "$dir/crew" commit -q --allow-empty -m 'the finished work'
  printf -- '- proj [local-only] - governed test project (added 2026-07-13)\n' > "$dir/home/data/projects.md"
  # Stub the Fleet Bridge visibility CLI: a landing writes durable closure
  # evidence through bin/fm-task-events.sh, and a test landing must never reach
  # the live store (same pattern as tests/fm-pr-merge.test.sh).
  printf '%s\n' '#!/usr/bin/env node' 'process.exit(0);' > "$dir/home/visibility.mjs"
  FLEET_HOME="$dir/home"
  FLEET_PROJ="$dir/proj"
  FLEET_SERVING="$dir/serving"
  FLEET_ID=$id
  printf '%s\n' "$dir"
}

# declare_trunk <home> <trunk-checkout> <serving-json>
declare_trunk() {
  cat > "$1/config/canonical-trunk.json" <<EOF
{"schema":"firstmate/canonical-trunk/1","projects":{"proj":{"trunk_branch":"main","trunk_checkout":"$2","provisioning_base":"main","serving":$3}}}
EOF
}

# write_task_meta <home> <id> <project-path>
write_task_meta() {
  fm_write_meta "$1/state/$2.meta" \
    "window=firstmate:fm-$2" \
    "worktree=$TMP_ROOT/crew" \
    "project=$3" \
    "harness=echo" \
    "kind=ship" \
    "mode=local-only" \
    "yolo=off"
}

run_merge() {
  local home=$1 id=$2
  set +e
  OUT=$(FM_HOME="$home" FM_ROOT_OVERRIDE='' FM_VISIBILITY_CLI="$home/visibility.mjs" "$MERGE" "$id" 2>&1)
  CODE=$?
  set -e
}

trunk_sha() { git -C "$1" rev-parse main; }

# --- the recurrence, refused at the gate ------------------------------------

# The literal habit that caused the drift: the landing is aimed at the SERVING
# worktree instead of canonical trunk. Detection after the fact is not enough -
# the gate must refuse.
test_refuses_landing_into_the_serving_worktree() {
  make_fleet serving-target >/dev/null
  declare_trunk "$FLEET_HOME" "$FLEET_PROJ" "{\"source\": \"worktree\", \"worktree\": \"$FLEET_SERVING\"}"
  # The task's project path IS the serving worktree - out of habit.
  write_task_meta "$FLEET_HOME" "$FLEET_ID" "$FLEET_SERVING"

  local before_trunk before_serving
  before_trunk=$(trunk_sha "$FLEET_PROJ")
  before_serving=$(git -C "$FLEET_SERVING" rev-parse HEAD)

  run_merge "$FLEET_HOME" "$FLEET_ID"
  expect_code 1 "$CODE" "a landing aimed at the serving worktree is refused"
  assert_contains "$OUT" 'REFUSED' 'the gate refuses, it does not warn'
  assert_contains "$OUT" 'NOT the canonical trunk checkout' 'the wrong target is named'
  assert_contains "$OUT" 'another checkout of the same repo' 'the same-repo case is diagnosed'
  assert_contains "$OUT" "$FLEET_PROJ" 'the right target is named'
  [ "$(trunk_sha "$FLEET_PROJ")" = "$before_trunk" ] || fail "a refused merge moved trunk"
  [ "$(git -C "$FLEET_SERVING" rev-parse HEAD)" = "$before_serving" ] || fail "a refused merge moved the serving checkout"
  pass "fm-merge-local: REFUSES a landing aimed at the serving worktree (the recurrence)"
}

# Trunk is already behind serving (the drift is live). Landing more work on top
# compounds it, so the gate refuses until the two lineages are converged.
test_refuses_while_trunk_is_already_drifted() {
  make_fleet already-drifted >/dev/null
  declare_trunk "$FLEET_HOME" "$FLEET_PROJ" "{\"source\": \"worktree\", \"worktree\": \"$FLEET_SERVING\"}"
  write_task_meta "$FLEET_HOME" "$FLEET_ID" "$FLEET_PROJ"
  git -C "$FLEET_SERVING" commit -q --allow-empty -m 'landed into serving earlier'

  local before
  before=$(trunk_sha "$FLEET_PROJ")
  run_merge "$FLEET_HOME" "$FLEET_ID"
  expect_code 1 "$CODE" "landing onto an already-drifted trunk is refused"
  assert_contains "$OUT" 'ALREADY violated' 'the live drift is named'
  assert_contains "$OUT" 'AHEAD of canonical trunk' 'the verifier findings are surfaced'
  [ "$(trunk_sha "$FLEET_PROJ")" = "$before" ] || fail "a refused merge moved trunk"
  pass "fm-merge-local: REFUSES to land while trunk is already behind the serving lineage"
}

# The invariant projected onto the landing: even with the drift cleared from the
# gate's point of view, a branch that does not contain the serving commit would
# leave trunk behind what is actually running.
test_refuses_landing_that_would_leave_trunk_behind_serving() {
  local dir
  dir=$(make_fleet projected)
  # A serving lineage in a SEPARATE clone (so the pre-check sees a commit the trunk
  # repo does not have): the landing must still not leave trunk behind it.
  git clone -q "$FLEET_PROJ" "$dir/deployed"
  git -C "$dir/deployed" commit -q --allow-empty -m 'served, never landed'
  declare_trunk "$FLEET_HOME" "$FLEET_PROJ" "{\"source\": \"worktree\", \"worktree\": \"$dir/deployed\"}"
  write_task_meta "$FLEET_HOME" "$FLEET_ID" "$FLEET_PROJ"

  local before
  before=$(trunk_sha "$FLEET_PROJ")
  run_merge "$FLEET_HOME" "$FLEET_ID"
  expect_code 1 "$CODE" "a landing that leaves trunk behind serving is refused"
  assert_contains "$OUT" 'REFUSED' 'the gate refuses'
  [ "$(trunk_sha "$FLEET_PROJ")" = "$before" ] || fail "a refused merge moved trunk"
  pass "fm-merge-local: REFUSES a landing that would leave trunk behind the serving lineage"
}

# --- declaration errors refuse the merge ------------------------------------

test_missing_declaration_refuses() {
  make_fleet no-decl >/dev/null
  write_task_meta "$FLEET_HOME" "$FLEET_ID" "$FLEET_PROJ"

  local before
  before=$(trunk_sha "$FLEET_PROJ")
  run_merge "$FLEET_HOME" "$FLEET_ID"
  expect_code 2 "$CODE" "a missing declaration is a verification error"
  assert_contains "$OUT" 'not verifiable' 'the gate says why it cannot proceed'
  assert_contains "$OUT" 'canonical-trunk' 'the declaration is named'
  [ "$(trunk_sha "$FLEET_PROJ")" = "$before" ] || fail "a refused merge moved trunk"
  pass "fm-merge-local: a missing declaration REFUSES the merge, never passes it"
}

test_malformed_declaration_refuses() {
  make_fleet bad-decl >/dev/null
  printf 'not json {\n' > "$FLEET_HOME/config/canonical-trunk.json"
  write_task_meta "$FLEET_HOME" "$FLEET_ID" "$FLEET_PROJ"

  run_merge "$FLEET_HOME" "$FLEET_ID"
  expect_code 2 "$CODE" "a malformed declaration is a verification error"
  assert_contains "$OUT" 'REFUSED' 'the gate refuses'
  pass "fm-merge-local: a malformed declaration REFUSES the merge"
}

# --- legitimate landings still land -----------------------------------------

# The old gate guessed the target (origin/HEAD, else main) and refused a
# legitimate landing during the convergence. The target now comes from the
# declaration, so a trunk that is not named `main`, in a checkout that is not the
# task's own clone path spelling, still lands.
test_lands_onto_declared_trunk_not_named_main() {
  local dir
  dir=$(make_fleet named-trunk)
  git -C "$FLEET_PROJ" branch -m main release
  git -C "$FLEET_PROJ" worktree remove --force "$dir/crew" 2>/dev/null || true
  cat > "$FLEET_HOME/config/canonical-trunk.json" <<EOF
{"projects":{"proj":{"trunk_branch":"release","trunk_checkout":"$FLEET_PROJ","provisioning_base":"release","serving":{"source":"worktree","worktree":"$FLEET_SERVING"}}}}
EOF
  write_task_meta "$FLEET_HOME" "$FLEET_ID" "$FLEET_PROJ"

  local want
  want=$(git -C "$FLEET_PROJ" rev-parse "fm/$FLEET_ID")
  run_merge "$FLEET_HOME" "$FLEET_ID"
  expect_code 0 "$CODE" "a legitimate fast-forward onto declared trunk lands"
  assert_contains "$OUT" 'merged fm/' 'the merge is reported'
  assert_contains "$OUT" 'canonical trunk release' 'the declared trunk is the target, not a guessed main'
  [ "$(git -C "$FLEET_PROJ" rev-parse release)" = "$want" ] || fail "trunk did not fast-forward to the branch tip"
  pass "fm-merge-local: lands onto the DECLARED trunk even when it is not named main"
}

# Serving behind trunk is a deploy lag, the tolerable direction: the landing
# proceeds, and the lag is reported rather than repaired.
test_lands_with_deploy_lag_and_reports_it() {
  make_fleet lag >/dev/null
  declare_trunk "$FLEET_HOME" "$FLEET_PROJ" "{\"source\": \"worktree\", \"worktree\": \"$FLEET_SERVING\"}"
  write_task_meta "$FLEET_HOME" "$FLEET_ID" "$FLEET_PROJ"

  local serving_before
  serving_before=$(git -C "$FLEET_SERVING" rev-parse HEAD)
  run_merge "$FLEET_HOME" "$FLEET_ID"
  expect_code 0 "$CODE" "landing ahead of the deployed commit is allowed"
  assert_contains "$OUT" 'deploy lag' 'the resulting lag is reported'
  [ "$(git -C "$FLEET_SERVING" rev-parse HEAD)" = "$serving_before" ] || fail "the gate moved the serving checkout - it must never auto-repair"
  pass "fm-merge-local: lands, then REPORTS the deploy lag without touching the serving checkout"
}

# Re-running the gate after a merge is a no-op success, not a confusing refusal.
test_already_landed_is_a_no_op() {
  make_fleet idempotent >/dev/null
  declare_trunk "$FLEET_HOME" "$FLEET_PROJ" '{"source": "none"}'
  write_task_meta "$FLEET_HOME" "$FLEET_ID" "$FLEET_PROJ"

  run_merge "$FLEET_HOME" "$FLEET_ID"
  expect_code 0 "$CODE" "the first landing succeeds"
  local landed
  landed=$(trunk_sha "$FLEET_PROJ")
  run_merge "$FLEET_HOME" "$FLEET_ID"
  expect_code 0 "$CODE" "a repeat landing is a no-op success"
  assert_contains "$OUT" 'already landed' 'the no-op is named'
  [ "$(trunk_sha "$FLEET_PROJ")" = "$landed" ] || fail "the repeat landing moved trunk"
  pass "fm-merge-local: an already-landed branch is a no-op success, not a refusal"
}

# A diverged branch still gets the rebase instruction, now naming the declared trunk.
test_diverged_branch_is_refused_with_the_rebase_fix() {
  make_fleet diverged >/dev/null
  declare_trunk "$FLEET_HOME" "$FLEET_PROJ" '{"source": "none"}'
  write_task_meta "$FLEET_HOME" "$FLEET_ID" "$FLEET_PROJ"
  git -C "$FLEET_PROJ" commit -q --allow-empty -m 'trunk moved on independently'

  run_merge "$FLEET_HOME" "$FLEET_ID"
  expect_code 1 "$CODE" "a diverged branch is refused"
  assert_contains "$OUT" 'not a fast-forward' 'the divergence is named'
  assert_contains "$OUT" 'rebase' 'the exact fix is named'
  pass "fm-merge-local: a diverged branch is refused with the rebase fix"
}

test_refuses_landing_into_the_serving_worktree
test_refuses_while_trunk_is_already_drifted
test_refuses_landing_that_would_leave_trunk_behind_serving
test_missing_declaration_refuses
test_malformed_declaration_refuses
test_lands_onto_declared_trunk_not_named_main
test_lands_with_deploy_lag_and_reports_it
test_already_landed_is_a_no_op
test_diverged_branch_is_refused_with_the_rebase_fix

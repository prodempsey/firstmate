#!/usr/bin/env bash
# Behavior tests for the canonical trunk invariant verifier (bin/fm-trunk-check.sh).
#
# The failure it exists to catch, replayed literally in test_the_recurrence:
# trunk at commit X; a branch lands into the SERVING worktree; serving moves to Y
# while trunk stays at X. That drift went unnoticed for sixteen days, was
# converged, and recurred within hours. These cases pin what makes that
# impossible to sustain silently:
#   * the recurrence is caught (serving ahead of trunk -> drift, exit 1);
#   * a missing or malformed declaration is a LOUD ERROR, never a pass (exit 2);
#   * a project governed by the registry but absent from the declaration errors;
#   * healthy is SILENT (exit 0, no output);
#   * deploy lag (serving behind trunk) is reported but tolerated (exit 0);
#   * the verifier NEVER mutates a ref, branch, or HEAD in any repo it reads;
#   * the serving lineage is read from the project's own machine-readable identity
#     command (the serving-root contract), not re-derived here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "ok - fm-trunk-check: skipped (no jq)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-trunk-check)
fm_git_identity fmtest fmtest@example.invalid

CHECK="$ROOT/bin/fm-trunk-check.sh"

# --- fixtures ---------------------------------------------------------------
#
# A governed project shaped like the real one: a trunk checkout on `main`, plus a
# separate SERVING worktree of the same repo on its own branch. That second
# checkout is where the drift came from, so every fixture has one.

# make_fleet <name>: build home + project + serving worktree under $TMP_ROOT/<name>.
# Echoes the fleet dir. Sets FLEET_HOME/FLEET_PROJ/FLEET_SERVING.
make_fleet() {
  local name=$1
  local dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/config" "$dir/home/data"
  git init -q -b main "$dir/proj"
  git -C "$dir/proj" commit -q --allow-empty -m X
  git -C "$dir/proj" worktree add -q -b serving "$dir/serving" main
  printf -- '- proj [local-only] - governed test project (added 2026-07-13)\n' > "$dir/home/data/projects.md"
  FLEET_HOME="$dir/home"
  FLEET_PROJ="$dir/proj"
  FLEET_SERVING="$dir/serving"
  printf '%s\n' "$dir"
}

# declare_trunk <home> <proj> <serving-json>: write the canonical-trunk declaration.
declare_trunk() {
  local home=$1 proj=$2 serving=$3
  cat > "$home/config/canonical-trunk.json" <<EOF
{
  "schema": "firstmate/canonical-trunk/1",
  "projects": {
    "proj": {
      "trunk_branch": "main",
      "trunk_checkout": "$proj",
      "provisioning_base": "main",
      "serving": $serving
    }
  }
}
EOF
}

# run_check <home> [args...]: run the verifier against a fixture home, capturing
# stdout+stderr in OUT and the exit code in CODE.
run_check() {
  local home=$1
  shift
  set +e
  OUT=$(FM_HOME="$home" FM_ROOT_OVERRIDE='' "$CHECK" "$@" 2>&1)
  CODE=$?
  set -e
}

# ref_snapshot <repo>: every ref and HEAD, so a test can prove nothing moved.
ref_snapshot() {
  git -C "$1" for-each-ref --format='%(refname) %(objectname)'
  git -C "$1" rev-parse HEAD
  git -C "$1" symbolic-ref --quiet HEAD || true
}

# --- the recurrence ---------------------------------------------------------

# THE case from the captain's order: a branch lands into the serving worktree,
# serving moves ahead, trunk stays put. If this does not fail, nothing else here
# matters.
test_the_recurrence() {
  make_fleet recurrence >/dev/null
  declare_trunk "$FLEET_HOME" "$FLEET_PROJ" "{\"source\": \"worktree\", \"worktree\": \"$FLEET_SERVING\"}"

  run_check "$FLEET_HOME"
  expect_code 0 "$CODE" "converged fleet is healthy"
  [ -z "$OUT" ] || fail "healthy fleet must be silent, got: $OUT"

  # A branch lands into the SERVING worktree - the habit that caused the drift.
  git -C "$FLEET_SERVING" commit -q --allow-empty -m 'landed into the serving worktree'

  run_check "$FLEET_HOME"
  expect_code 1 "$CODE" "serving ahead of trunk is drift"
  assert_contains "$OUT" 'TRUNK DRIFT' 'the recurrence is named as drift'
  assert_contains "$OUT" 'AHEAD of canonical trunk' 'the direction of the drift is named'
  assert_contains "$OUT" 'merge --ff-only' 'the exact fix is named'
  pass "fm-trunk-check: catches the exact recurrence (branch landed into the serving worktree)"
}

# The tolerable direction: serving behind trunk is a deploy lag, reported, exit 0.
test_deploy_lag_is_tolerated() {
  make_fleet lag >/dev/null
  declare_trunk "$FLEET_HOME" "$FLEET_PROJ" "{\"source\": \"worktree\", \"worktree\": \"$FLEET_SERVING\"}"
  git -C "$FLEET_PROJ" commit -q --allow-empty -m 'trunk moves ahead of the deployed commit'

  run_check "$FLEET_HOME"
  expect_code 0 "$CODE" "deploy lag is tolerable"
  assert_contains "$OUT" 'deploy lag' 'lag is reported, not silent'
  assert_not_contains "$OUT" 'DRIFT' 'lag is not drift'
  pass "fm-trunk-check: serving behind trunk is a reported deploy lag, not a failure"
}

# A serving lineage that shares no history with trunk is drift, and the verifier
# must not crash on a commit its trunk repo has never heard of.
test_divergent_serving() {
  local dir
  dir=$(make_fleet diverged)
  git init -q -b main "$dir/elsewhere"
  git -C "$dir/elsewhere" commit -q --allow-empty -m 'unrelated lineage'
  declare_trunk "$FLEET_HOME" "$FLEET_PROJ" "{\"source\": \"worktree\", \"worktree\": \"$dir/elsewhere\"}"

  run_check "$FLEET_HOME"
  expect_code 1 "$CODE" "a serving commit outside the governed repo is drift"
  assert_contains "$OUT" 'not present in the trunk repository' 'the unknown commit is named'
  pass "fm-trunk-check: a serving commit absent from the trunk repo is drift, not a crash"
}

# --- declaration errors: absence is never a pass ----------------------------

test_missing_declaration_is_an_error() {
  make_fleet nodecl >/dev/null

  run_check "$FLEET_HOME"
  expect_code 2 "$CODE" "a missing declaration is an error"
  assert_contains "$OUT" 'no canonical-trunk declaration' 'the absence is named'
  assert_contains "$OUT" 'NOT being verified' 'it says verification is not happening'
  assert_contains "$OUT" 'firstmate/canonical-trunk/1' 'the schema template is printed'
  pass "fm-trunk-check: a missing declaration is a loud error, never a silent pass"
}

test_malformed_declaration_is_an_error() {
  make_fleet malformed >/dev/null
  printf 'this is not json {\n' > "$FLEET_HOME/config/canonical-trunk.json"

  run_check "$FLEET_HOME"
  expect_code 2 "$CODE" "a malformed declaration is an error"
  assert_contains "$OUT" 'malformed' 'the malformed file is named'
  pass "fm-trunk-check: a malformed declaration is a loud error"
}

# Every field that could be silently omitted must be required, or the omission
# becomes the new silent skip.
test_incomplete_declaration_is_an_error() {
  local dir case_json n=0
  dir=$(make_fleet incomplete)
  for case_json in \
    '{"projects":{"proj":{"trunk_checkout":"PROJ","serving":{"source":"none"}}}}' \
    '{"projects":{"proj":{"trunk_branch":"main","serving":{"source":"none"}}}}' \
    '{"projects":{"proj":{"trunk_branch":"main","trunk_checkout":"PROJ"}}}' \
    '{"projects":{"proj":{"trunk_branch":"main","trunk_checkout":"PROJ","serving":{"source":"guess"}}}}' \
    '{"projects":{"proj":{"trunk_branch":"main","trunk_checkout":"PROJ","serving":{"source":"command"}}}}'
  do
    n=$((n + 1))
    printf '%s\n' "${case_json//PROJ/$FLEET_PROJ}" > "$FLEET_HOME/config/canonical-trunk.json"
    run_check "$FLEET_HOME"
    expect_code 2 "$CODE" "incomplete declaration case $n is an error"
    assert_contains "$OUT" 'missing or malformed' "incomplete declaration case $n is named"
  done
  [ "$n" = 5 ] || fail "expected 5 incomplete-declaration cases, ran $n"
  pass "fm-trunk-check: every required declaration field is enforced ($n cases)"
}

# The delete-the-declaration hole: a project registered in data/projects.md but
# absent from the declaration is still governed, and still errors. The registry is
# the independent list that makes an omission impossible to hide.
test_registered_but_undeclared_is_an_error() {
  make_fleet undeclared >/dev/null
  declare_trunk "$FLEET_HOME" "$FLEET_PROJ" '{"source": "none"}'
  printf -- '- other [local-only] - a second governed project (added 2026-07-13)\n' >> "$FLEET_HOME/data/projects.md"

  run_check "$FLEET_HOME"
  expect_code 2 "$CODE" "a registered but undeclared project is an error"
  assert_contains "$OUT" 'other' 'the undeclared project is named'
  pass "fm-trunk-check: a registered project missing from the declaration errors"
}

# A declared serving source that cannot be read is an observation error, not a
# pass: a verifier that cannot see the running process must say so.
test_unreadable_serving_is_an_error() {
  make_fleet unreadable >/dev/null
  declare_trunk "$FLEET_HOME" "$FLEET_PROJ" '{"source": "command", "command": "exit 7"}'

  run_check "$FLEET_HOME"
  expect_code 2 "$CODE" "an unreadable serving lineage is an error"
  assert_contains "$OUT" 'cannot read the serving lineage' 'the unreadable serving source is named'
  pass "fm-trunk-check: an unreadable serving lineage is an error, never health"
}

# --- the serving-root boundary ----------------------------------------------
#
# The running process's branch/SHA come from the project's OWN machine-readable
# identity (fleet-bridge's bin/serving-root.sh identity), which firstmate consumes
# and never re-derives. This pins that contract at the boundary.
test_serving_identity_command() {
  make_fleet identity >/dev/null
  local sha
  git -C "$FLEET_SERVING" commit -q --allow-empty -m 'serving moved ahead'
  sha=$(git -C "$FLEET_SERVING" rev-parse HEAD)
  local id_script="$TMP_ROOT/identity/serving-root.sh"
  cat > "$id_script" <<EOF
#!/usr/bin/env bash
printf '{"schema":"fleet-bridge/serving-root/1","canonicalRoot":"$FLEET_SERVING","branch":"serving","sha":"$sha","dirty":false,"launcherIsCanonical":true}\n'
EOF
  chmod +x "$id_script"
  declare_trunk "$FLEET_HOME" "$FLEET_PROJ" "{\"source\": \"command\", \"command\": \"$id_script\"}"

  run_check "$FLEET_HOME"
  expect_code 1 "$CODE" "drift read through the identity command is still drift"
  assert_contains "$OUT" 'AHEAD of canonical trunk' 'the identity command feeds the same rule'
  assert_contains "$OUT" 'serving' 'the branch from the identity JSON is reported'
  pass "fm-trunk-check: consumes the serving-root identity JSON at the boundary"
}

# --- the other three comparisons --------------------------------------------

test_primary_checkout_off_trunk() {
  make_fleet primary >/dev/null
  declare_trunk "$FLEET_HOME" "$FLEET_PROJ" '{"source": "none"}'
  git -C "$FLEET_PROJ" checkout -q -b feature

  run_check "$FLEET_HOME"
  expect_code 1 "$CODE" "a trunk checkout parked off trunk is drift"
  assert_contains "$OUT" "is on 'feature'" 'the wrong branch is named'
  pass "fm-trunk-check: the trunk checkout sitting off canonical trunk is drift"
}

test_provisioning_base_off_trunk() {
  make_fleet provisioning >/dev/null
  git -C "$FLEET_PROJ" branch crew-base main
  git -C "$FLEET_PROJ" commit -q --allow-empty -m 'trunk advances past the crew base'
  cat > "$FLEET_HOME/config/canonical-trunk.json" <<EOF
{"projects":{"proj":{"trunk_branch":"main","trunk_checkout":"$FLEET_PROJ","provisioning_base":"crew-base","serving":{"source":"none"}}}}
EOF

  run_check "$FLEET_HOME"
  expect_code 1 "$CODE" "a stale crew provisioning base is drift"
  assert_contains "$OUT" 'provisioning base' 'the stale base is named'
  pass "fm-trunk-check: a crewmate provisioning base off trunk is drift"
}

test_github_default_disagrees() {
  make_fleet ghdefault >/dev/null
  declare_trunk "$FLEET_HOME" "$FLEET_PROJ" '{"source": "none"}'
  # Simulate a clone whose GitHub default branch is not the declared trunk.
  git -C "$FLEET_PROJ" branch trunk-elsewhere main
  git -C "$FLEET_PROJ" remote add origin "file://$FLEET_PROJ"
  git -C "$FLEET_PROJ" update-ref refs/remotes/origin/trunk-elsewhere "$(git -C "$FLEET_PROJ" rev-parse main)"
  git -C "$FLEET_PROJ" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk-elsewhere

  run_check "$FLEET_HOME"
  expect_code 1 "$CODE" "a GitHub default that is not canonical trunk is drift"
  assert_contains "$OUT" 'GitHub default branch' 'the disagreement is named'
  pass "fm-trunk-check: GitHub default branch disagreeing with canonical trunk is drift"
}

# --- the verifier never mutates ---------------------------------------------
#
# "A verifier that silently moves refs is a new way to lose work." Prove it: run
# every mode over a drifted fleet and assert every ref, HEAD, and index in both
# checkouts is byte-identical afterwards.
test_never_mutates() {
  make_fleet readonly >/dev/null
  declare_trunk "$FLEET_HOME" "$FLEET_PROJ" "{\"source\": \"worktree\", \"worktree\": \"$FLEET_SERVING\"}"
  git -C "$FLEET_SERVING" commit -q --allow-empty -m 'drifted'

  local before_proj before_serving after_proj after_serving
  before_proj=$(ref_snapshot "$FLEET_PROJ")
  before_serving=$(ref_snapshot "$FLEET_SERVING")

  run_check "$FLEET_HOME"
  run_check "$FLEET_HOME" --json
  run_check "$FLEET_HOME" --lines
  run_check "$FLEET_HOME" -q
  run_check "$FLEET_HOME" proj

  after_proj=$(ref_snapshot "$FLEET_PROJ")
  after_serving=$(ref_snapshot "$FLEET_SERVING")
  [ "$before_proj" = "$after_proj" ] || fail "the verifier moved a ref in the trunk checkout"
  [ "$before_serving" = "$after_serving" ] || fail "the verifier moved a ref in the serving checkout"
  pass "fm-trunk-check: never mutates a ref, branch, or HEAD in any repo it reads"
}

# --- output contracts -------------------------------------------------------

test_json_and_lines_contracts() {
  make_fleet formats >/dev/null
  declare_trunk "$FLEET_HOME" "$FLEET_PROJ" "{\"source\": \"worktree\", \"worktree\": \"$FLEET_SERVING\"}"
  git -C "$FLEET_SERVING" commit -q --allow-empty -m 'drifted'

  run_check "$FLEET_HOME" --json
  expect_code 1 "$CODE" "--json keeps the status exit code"
  printf '%s' "$OUT" | jq -e '.schema == "firstmate/canonical-trunk-check/1"' >/dev/null \
    || fail "--json must emit the stable schema: $OUT"
  printf '%s' "$OUT" | jq -e '.status == "drift"' >/dev/null || fail "--json must report status=drift"
  printf '%s' "$OUT" | jq -e '.projects[0].serving.relation == "ahead"' >/dev/null \
    || fail "--json must report the serving relation consumed by the merge gate"
  printf '%s' "$OUT" | jq -e '.findings[0].fix != ""' >/dev/null || fail "--json findings must carry the fix"

  run_check "$FLEET_HOME" --lines
  expect_code 1 "$CODE" "--lines keeps the status exit code"
  assert_contains "$OUT" 'TRUNK: proj: drift:' 'the bootstrap line format is stable'
  pass "fm-trunk-check: --json and --lines emit their stable contracts"
}

# Cheap enough for startup and every merge: the whole check is a handful of git
# plumbing reads, so a converged fleet must verify well inside a second.
test_is_cheap() {
  make_fleet cheap >/dev/null
  declare_trunk "$FLEET_HOME" "$FLEET_PROJ" "{\"source\": \"worktree\", \"worktree\": \"$FLEET_SERVING\"}"
  local start end elapsed
  start=$(date +%s%N)
  run_check "$FLEET_HOME"
  end=$(date +%s%N)
  expect_code 0 "$CODE" "the cheap-run fixture is healthy"
  elapsed=$(( (end - start) / 1000000 ))
  [ "$elapsed" -lt 1000 ] || fail "verification took ${elapsed}ms; too slow to run at startup and every merge"
  pass "fm-trunk-check: verifies a project in ${elapsed}ms (budget 1000ms)"
}

test_the_recurrence
test_deploy_lag_is_tolerated
test_divergent_serving
test_missing_declaration_is_an_error
test_malformed_declaration_is_an_error
test_incomplete_declaration_is_an_error
test_registered_but_undeclared_is_an_error
test_unreadable_serving_is_an_error
test_serving_identity_command
test_primary_checkout_off_trunk
test_provisioning_base_off_trunk
test_github_default_disagrees
test_never_mutates
test_json_and_lines_contracts
test_is_cheap

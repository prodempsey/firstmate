#!/usr/bin/env bash
# tests/fm-qa-dispatch.test.sh - behavior tests for bin/fm-qa-dispatch.sh, the
# QA-dispatch chokepoint (Gauntlet slice 2). The wrapper refuses to spawn a QA
# scout unless a FRESH, PASSING verify bundle exists for the EXACT candidate SHA,
# scaffolds the QA brief so it auto-references that bundle, and offers an explicit,
# logged --no-gauntlet escape hatch for non-code scouts.
#
# The real fm-spawn is never invoked: FM_QA_SPAWN points the final launch at a
# recorder stub, so a refusal test never reaches a terminal backend and a pass
# test asserts on the exact spawn command the wrapper would run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

DISPATCH="$ROOT/bin/fm-qa-dispatch.sh"
TMP=$(fm_test_tmproot fm-qa-dispatch)
fm_git_identity

# new_home: a fresh isolated firstmate home with a recorder spawn stub wired via
# FM_QA_SPAWN. Echoes the home path; the recorder writes its args to <home>/spawn.args.
new_home() {
  local h="$TMP/$1"
  mkdir -p "$h/state" "$h/data" "$h/projects/foo"
  cat > "$h/fake-spawn.sh" <<SH
#!/usr/bin/env bash
printf '%s' "\$*" > "$h/spawn.args"
SH
  chmod +x "$h/fake-spawn.sh"
  printf '%s\n' "$h"
}

# write_bundle <home> <task> <verdict> <head_sha>: drop a verify bundle with the
# real slice-1 schema and field layout.
write_bundle() {
  local h=$1 task=$2 verdict=$3 sha=$4
  mkdir -p "$h/data/$task"
  printf '%s\n' "{\"schema\":\"firstmate/verify-bundle/1\",\"verdict\":\"$verdict\",\"task\":\"$task\",\"candidate\":{\"head_sha\":\"$sha\"}}" \
    > "$h/data/$task/verify-bundle.json"
}

run_dispatch() {
  local h=$1; shift
  FM_HOME="$h" FM_QA_SPAWN="$h/fake-spawn.sh" "$DISPATCH" "$@"
}

# --- the script must always parse -------------------------------------------
test_script_parses() {
  bash -n "$DISPATCH" 2>&1 || fail "bin/fm-qa-dispatch.sh fails bash -n"
  pass "fm-qa-dispatch.sh: bash -n succeeds"
}

test_help_renders() {
  local out
  out=$("$DISPATCH" --help)
  assert_contains "$out" "QA scout's own task id" "help omitted its usage block"
  assert_contains "$out" "--no-gauntlet" "help omitted the escape hatch"
  pass "fm-qa-dispatch.sh: --help renders"
}

# --- gate refusal cases (exit 3, remedy always names fm-verify) --------------
test_refuse_missing_bundle() {
  local h; h=$(new_home missing)
  local out rc
  out=$(run_dispatch "$h" qa-a projects/foo --sha abc123 --no-spawn 2>&1); rc=$?
  expect_code 3 "$rc" "missing bundle must refuse"
  assert_contains "$out" "no verify bundle" "refusal must say the bundle is missing"
  assert_contains "$out" "fm-verify.sh" "refusal must name the fm-verify remedy"
  pass "refuse: missing bundle -> exit 3 with remedy"
}

test_refuse_failing_verdict() {
  local h; h=$(new_home failing)
  write_bundle "$h" qa-b fail abc123
  local out rc
  out=$(run_dispatch "$h" qa-b projects/foo --sha abc123 --no-spawn 2>&1); rc=$?
  expect_code 3 "$rc" "failing bundle must refuse"
  assert_contains "$out" "verdict is 'fail'" "refusal must report the failing verdict"
  assert_contains "$out" "fm-verify.sh" "refusal must name the fm-verify remedy"
  pass "refuse: failing verdict -> exit 3"
}

test_refuse_stale_sha() {
  local h; h=$(new_home stale)
  write_bundle "$h" qa-c pass OLDSHA
  local out rc
  out=$(run_dispatch "$h" qa-c projects/foo --sha NEWSHA --no-spawn 2>&1); rc=$?
  expect_code 3 "$rc" "stale (SHA mismatch) must refuse even when verdict is pass"
  assert_contains "$out" "stale" "refusal must say the bundle is stale"
  assert_contains "$out" "NEWSHA" "refusal must name the candidate SHA under review"
  pass "refuse: stale SHA -> exit 3 (freshness bound to exact SHA)"
}

test_refuse_invalidated() {
  local h; h=$(new_home invalid)
  write_bundle "$h" qa-d invalidated ""
  local out rc
  out=$(run_dispatch "$h" qa-d projects/foo --sha whatever --no-spawn 2>&1); rc=$?
  expect_code 3 "$rc" "invalidated bundle must refuse"
  assert_contains "$out" "invalidated" "refusal must report the invalidated bundle"
  pass "refuse: invalidated bundle -> exit 3"
}

test_refuse_wrong_schema() {
  local h; h=$(new_home schema)
  mkdir -p "$h/data/qa-e"
  printf '%s\n' '{"schema":"something/else","verdict":"pass"}' > "$h/data/qa-e/verify-bundle.json"
  local out rc
  out=$(run_dispatch "$h" qa-e projects/foo --sha abc123 --no-spawn 2>&1); rc=$?
  expect_code 3 "$rc" "wrong-schema bundle must refuse"
  assert_contains "$out" "not a readable Gauntlet bundle" "refusal must reject the wrong schema"
  pass "refuse: wrong schema -> exit 3"
}

test_no_refusal_spawns() {
  # A refusal must occur BEFORE any spawn: the recorder must stay empty.
  local h; h=$(new_home norefspawn)
  local rc
  run_dispatch "$h" qa-f projects/foo --sha abc123 >/dev/null 2>&1; rc=$?
  expect_code 3 "$rc" "missing bundle must refuse"
  assert_absent "$h/spawn.args" "a refused dispatch must never reach fm-spawn"
  pass "refuse: fail-closed before spawn"
}

# --- pass case: gate clears, brief references the bundle, then spawns ---------
test_pass_scaffolds_referencing_brief() {
  local h; h=$(new_home pass1)
  write_bundle "$h" qa-g pass deadbeef1234
  local out rc
  out=$(run_dispatch "$h" qa-g projects/foo --sha deadbeef1234 2>&1); rc=$?
  expect_code 0 "$rc" "passing bundle must clear the gate"
  assert_contains "$out" "gate PASSED" "a cleared gate must announce itself"
  assert_present "$h/data/qa-g/brief.md" "the QA brief must be scaffolded"
  assert_grep "$h/data/qa-g/verify-bundle.json" "$h/data/qa-g/brief.md" \
    "the scaffolded brief must auto-reference the evidence bundle path"
  assert_grep "Gauntlet evidence" "$h/data/qa-g/brief.md" "the brief must carry the Gauntlet evidence section"
  # {TASK} is unfilled, so the wrapper stops short of spawning.
  assert_absent "$h/spawn.args" "wrapper must not spawn a brief that still carries {TASK}"
  pass "pass: gate clears, brief auto-references the bundle, holds at {TASK}"
}

test_pass_spawns_after_task_authored() {
  local h; h=$(new_home pass2)
  write_bundle "$h" qa-h pass cafef00d
  run_dispatch "$h" qa-h projects/foo --sha cafef00d --no-spawn >/dev/null 2>&1
  # Author the QA charge, then re-run: now it spawns with forwarded flags.
  sed -i 's/{TASK}/Review the change./' "$h/data/qa-h/brief.md"
  local rc
  run_dispatch "$h" qa-h projects/foo --sha cafef00d --harness codex --effort high >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "authored brief must spawn"
  assert_present "$h/spawn.args" "the wrapper must reach fm-spawn once {TASK} is filled"
  local args; args=$(cat "$h/spawn.args")
  assert_contains "$args" "qa-h projects/foo --scout" "spawn must be a scout for the QA task"
  assert_contains "$args" "--harness codex" "spawn must forward --harness"
  assert_contains "$args" "--effort high" "spawn must forward --effort"
  pass "pass: spawns as a scout with forwarded flags after {TASK} authored"
}

test_pass_logs_dispatch() {
  local h; h=$(new_home passlog)
  write_bundle "$h" qa-i pass 0badc0de
  run_dispatch "$h" qa-i projects/foo --sha 0badc0de --no-spawn >/dev/null 2>&1
  assert_grep "PASS" "$h/state/gauntlet-dispatch.log" "a cleared gate must be logged"
  assert_grep "qa-i" "$h/state/gauntlet-dispatch.log" "the log line must name the task"
  pass "pass: dispatch decision is logged"
}

# --- escape hatch: --no-gauntlet, logged, never silent -----------------------
test_escape_hatch_bypasses_and_logs() {
  local h; h=$(new_home escape)
  # No bundle exists at all - the gate would refuse, but the waiver bypasses it.
  local out rc
  out=$(run_dispatch "$h" qa-j projects/foo --no-gauntlet "docs-only audit, no code" --no-spawn 2>&1); rc=$?
  expect_code 0 "$rc" "an explicit waiver must clear dispatch"
  assert_contains "$out" "WAIVED" "the waiver must be announced"
  assert_grep "WAIVED" "$h/state/gauntlet-dispatch.log" "the waiver must be logged (never silent)"
  assert_grep "docs-only audit, no code" "$h/state/gauntlet-dispatch.log" "the log must record the waiver reason"
  assert_grep "WAIVED" "$h/data/qa-j/brief.md" "the brief must record that the Gauntlet was waived"
  assert_grep "docs-only audit, no code" "$h/data/qa-j/brief.md" "the brief must carry the waiver reason"
  pass "escape hatch: --no-gauntlet bypasses the gate and logs the waiver"
}

test_escape_hatch_requires_reason() {
  local h; h=$(new_home escapenoreason)
  local rc
  run_dispatch "$h" qa-k projects/foo --no-gauntlet --no-spawn >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "--no-gauntlet without a reason is a usage error"
  # A bare --no-gauntlet followed by another flag must not silently swallow the flag as a reason.
  run_dispatch "$h" qa-k projects/foo --no-gauntlet --harness codex --no-spawn >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "--no-gauntlet must not consume the next flag as its reason"
  pass "escape hatch: reason is mandatory"
}

# --- usage errors ------------------------------------------------------------
test_missing_sha_without_waiver() {
  local h; h=$(new_home nosha)
  write_bundle "$h" qa-l pass abc123
  local rc
  run_dispatch "$h" qa-l projects/foo --no-spawn >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "--sha is required for a gated dispatch"
  pass "usage: --sha required unless --no-gauntlet"
}

test_missing_positionals() {
  local h; h=$(new_home nopos)
  local rc
  run_dispatch "$h" --sha abc123 >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "a bare --sha with no task id/repo is a usage error"
  run_dispatch "$h" qa-m --sha abc123 >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "a task id with no repo is a usage error"
  pass "usage: task id and repo are required"
}

test_unknown_option() {
  local h; h=$(new_home unknown)
  local rc
  run_dispatch "$h" qa-n projects/foo --sha abc123 --bogus >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "an unknown option is a usage error"
  pass "usage: unknown option rejected"
}

# --- custom --bundle path ----------------------------------------------------
test_custom_bundle_path() {
  local h; h=$(new_home custombundle)
  mkdir -p "$h/data/candidate-task"
  printf '%s\n' '{"schema":"firstmate/verify-bundle/1","verdict":"pass","candidate":{"head_sha":"feedface"}}' \
    > "$h/data/candidate-task/verify-bundle.json"
  local rc
  run_dispatch "$h" qa-o projects/foo --sha feedface --bundle "$h/data/candidate-task/verify-bundle.json" --no-spawn >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "an explicit --bundle path must be honored"
  pass "gate: honors an explicit --bundle path (bundle need not live in the QA task dir)"
}

# --- integration with the REAL slice-1 verifier ------------------------------
# Proves the wrapper consumes an actual fm-verify.sh bundle (schema/field names).
test_real_verify_bundle_integration() {
  local h; h=$(new_home realverify)
  local R="$h/cand"
  git init -q "$R"; git -C "$R" checkout -q -b main
  mkdir -p "$R/tests"
  printf '#!/usr/bin/env bash\necho "ok - a"\n' > "$R/tests/a.test.sh"; chmod +x "$R/tests/a.test.sh"
  echo base > "$R/f"; git -C "$R" add -A; git -C "$R" commit -qm base
  git -C "$R" checkout -q -b fm/qa-p; echo change >> "$R/f"; git -C "$R" add -A; git -C "$R" commit -qm work
  local sha; sha=$(git -C "$R" rev-parse HEAD)
  mkdir -p "$h/data/qa-p"
  cat > "$h/data/qa-p/brief.md" <<'EOF'
# Setup
1. First action: create your branch: git checkout -b fm/qa-p
# Rules
1. Never push.
# Definition of done
done: ready in branch fm/qa-p
EOF
  FM_HOME="$h" "$ROOT/bin/fm-verify.sh" --worktree "$R" --sha "$sha" --branch fm/qa-p --task qa-p --base main >/dev/null 2>&1
  [ "$(jq -r .verdict "$h/data/qa-p/verify-bundle.json")" = pass ] \
    || fail "the real verifier should produce a passing bundle"
  # Exact SHA clears; wrong SHA is stale.
  local rc
  run_dispatch "$h" qa-p projects/foo --sha "$sha" --branch fm/qa-p >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "the real passing bundle must clear the gate at its exact SHA"
  assert_present "$h/spawn.args" "an authored, gated QA scout must spawn"
  run_dispatch "$h" qa-p projects/foo --sha 0000000000000000 --branch fm/qa-p --no-spawn >/dev/null 2>&1; rc=$?
  expect_code 3 "$rc" "the real bundle must be stale against a different SHA"
  pass "integration: consumes a real fm-verify.sh bundle (fresh clears, wrong SHA is stale)"
}

test_script_parses
test_help_renders
test_refuse_missing_bundle
test_refuse_failing_verdict
test_refuse_stale_sha
test_refuse_invalidated
test_refuse_wrong_schema
test_no_refusal_spawns
test_pass_scaffolds_referencing_brief
test_pass_spawns_after_task_authored
test_pass_logs_dispatch
test_escape_hatch_bypasses_and_logs
test_escape_hatch_requires_reason
test_missing_sha_without_waiver
test_missing_positionals
test_unknown_option
test_custom_bundle_path
test_real_verify_bundle_integration

echo "all fm-qa-dispatch tests passed"

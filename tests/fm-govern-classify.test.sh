#!/usr/bin/env bash
# Scope B - deterministic governed-task classifier. Proves ordinary work stays
# ordinary, protected paths and governed intent enter governed mode, a real diff
# escalates an initially-ordinary task, and a governed task is never auto-downgraded.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GOVERN="$ROOT/bin/fm-govern.sh"
TMP_ROOT=$(fm_test_tmproot fm-govern-classify)
export FM_HOME="$TMP_ROOT/home" FM_STATE_OVERRIDE="$TMP_ROOT/home/state" FM_CONFIG_OVERRIDE="$TMP_ROOT/home/config"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE"
export FM_GOV_NOW=2026-07-15T00:00:00Z

classify() { "$GOVERN" classify "$@" 2>&1; }

# Regression 2: a simple documentation/UI text task stays ordinary.
test_simple_doc_task_ordinary() {
  local out
  out=$(classify "fix a typo and reword the button label in the docs" docs/guide.md src/ui/button-label.txt)
  assert_contains "$out" "governed=0" "a plain docs/UI task must not be governed"
  pass "a simple documentation/UI text task remains ordinary"
}

# Regression 3: a one-line change to a protected path enters governed mode.
test_protected_path_governed() {
  local out
  out=$(classify "one-line fix" memory/lib/registry.mjs)
  assert_contains "$out" "governed=1" "a change to memory/ must be governed"
  assert_contains "$out" "protected-path:memory/lib/registry.mjs" "must name the matched protected path"
  pass "a one-line change to a protected memory path enters governed mode"
}

test_protected_auth_path_governed() {
  local out
  out=$(classify "tweak spawn" bin/fm-spawn.sh)
  assert_contains "$out" "governed=1" "a change to bin/fm-spawn.sh must be governed"
  pass "a change to a protected fleet-lifecycle path enters governed mode"
}

test_intent_keyword_governed_without_paths() {
  local out
  out=$(classify "update the memory registry activation and supersession policy")
  assert_contains "$out" "governed=1" "governed intent must classify even with no concrete path yet"
  assert_contains "$out" "intent-keyword" "must record the intent-keyword rule"
  pass "governed intent (no path known yet) enters governed mode at intake"
}

# Regression 4: an actual diff touching a protected path escalates an initially
# ordinary task. The intake classification (scope text only, no path) is ordinary;
# re-running with the diff's paths escalates to governed.
test_diff_escalates_ordinary_to_governed() {
  local intake diffpass
  intake=$(classify "refactor a helper for clarity")
  assert_contains "$intake" "governed=0" "intake with an innocuous scope must be ordinary"
  diffpass=$(classify "refactor a helper for clarity" lib/helper.js memory/lib/schema.mjs)
  assert_contains "$diffpass" "governed=1" "a diff touching memory/ must escalate to governed"
  pass "a real diff touching a protected path escalates an initially ordinary task"
}

# Regression 5: a governed task is never automatically downgraded. Once a record is
# governed, re-classifying its scope as ordinary does NOT flip the record's governed
# flag - there is no automatic-downgrade path.
test_governed_never_auto_downgraded() {
  local sha=1111111111111111111111111111111111111111
  "$GOVERN" record init dg-1 local-only /repo ident fm/dg-1 base "$sha" "memory/" 1 >/dev/null
  # A later, narrower classification says ordinary...
  local reclass
  reclass=$(classify "just a docs tweak now" docs/x.md)
  assert_contains "$reclass" "governed=0" "the re-classification itself may read ordinary"
  # ...but the durable record stays governed; nothing downgraded it.
  local governed
  governed=$("$GOVERN" record get dg-1 governed)
  [ "$governed" = "true" ] || fail "governed record must not be auto-downgraded (got '$governed')"
  # And there is no downgrade verb to do it silently.
  ! "$GOVERN" record downgrade dg-1 2>/dev/null || fail "no automatic downgrade command may exist"
  pass "a governed task is never automatically downgraded"
}

test_home_override_extends_protected_paths() {
  printf '# extra protected paths\n^deploy/runtime-fold\n' > "$FM_CONFIG_OVERRIDE/governed-paths.txt"
  local out
  out=$(classify "touch the fold surface" deploy/runtime-fold/apply.sh)
  assert_contains "$out" "governed=1" "a home override path must be honored"
  rm -f "$FM_CONFIG_OVERRIDE/governed-paths.txt"
  pass "config/governed-paths.txt extends the protected-path list"
}

test_simple_doc_task_ordinary
test_protected_path_governed
test_protected_auth_path_governed
test_intent_keyword_governed_without_paths
test_diff_escalates_ordinary_to_governed
test_governed_never_auto_downgraded
test_home_override_extends_protected_paths

pass "fm-govern-classify: all classifier cases passed"

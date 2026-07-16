#!/usr/bin/env bash
# Scope G - local-only governance gate. Proves the local-only landing gate requires
# every exact-SHA field, never touches a remote or PR, and that public PR-mode work
# still routes to the no-mistakes/PR path rather than the local-only adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GOVERN="$ROOT/bin/fm-govern.sh"
MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-local-gate)
export FM_HOME="$TMP_ROOT/home" FM_STATE_OVERRIDE="$TMP_ROOT/home/state"
mkdir -p "$FM_STATE_OVERRIDE"
export FM_GOV_NOW=2026-07-15T00:00:00Z

SHA=abcabcabcabcabcabcabcabcabcabcabcabcabca

local_gate() { "$GOVERN" local-gate "$@" 2>&1; }

ready_args() {
  printf '%s' "--task lg-1 --repo /repo --base base000 --candidate $SHA --tree-clean 1 --tests-pass 1 --review-pass 1 --unresolved 0 --qa-pass 1 --captain-sha $SHA --merge-method ff-only"
}

test_local_gate_ready_when_complete() {
  local out status
  # shellcheck disable=SC2046
  out=$(local_gate $(ready_args)); status=$?
  expect_code 0 "$status" "a complete local-only gate must be READY"
  assert_contains "$out" "READY" "must report READY"
  pass "the local-only gate passes when every exact-SHA field is recorded"
}

test_local_gate_blocks_each_missing_field() {
  local out
  out=$(local_gate --task lg-2 --repo /repo --base base --candidate "$SHA" --tree-clean 0 --tests-pass 1 --review-pass 1 --unresolved 0 --qa-pass 1 --captain-sha "$SHA" --merge-method ff-only)
  assert_contains "$out" "working tree not clean" "dirty tree must block"
  out=$(local_gate --task lg-2 --repo /repo --base base --candidate "$SHA" --tree-clean 1 --tests-pass 1 --review-pass 1 --unresolved 0 --qa-pass 0 --captain-sha "$SHA" --merge-method ff-only)
  assert_contains "$out" "exact-SHA QA not passing" "missing QA must block"
  out=$(local_gate --task lg-2 --repo /repo --base base --candidate "$SHA" --tree-clean 1 --tests-pass 1 --review-pass 1 --unresolved 0 --qa-pass 1 --captain-sha "" --merge-method ff-only)
  assert_contains "$out" "Captain authorization not recorded" "missing captain auth must block"
  out=$(local_gate --task lg-2 --repo /repo --base base --candidate "$SHA" --tree-clean 1 --tests-pass 1 --review-pass 1 --unresolved 2 --qa-pass 1 --captain-sha "$SHA" --merge-method ff-only)
  assert_contains "$out" "unresolved actionable finding" "unresolved findings must block"
  pass "the local-only gate blocks on each missing/failed field"
}

test_local_gate_captain_sha_must_equal_candidate() {
  local out status
  out=$(local_gate --task lg-3 --repo /repo --base base --candidate "$SHA" --tree-clean 1 --tests-pass 1 --review-pass 1 --unresolved 0 --qa-pass 1 --captain-sha deadbeefdeadbeefdeadbeefdeadbeefdeadbeef --merge-method ff-only); status=$?
  expect_code 1 "$status" "a captain SHA that differs from the candidate must block"
  assert_contains "$out" "does not equal candidate" "must explain the exact-SHA mismatch"
  pass "the local-only gate requires the Captain-authorized SHA to equal the candidate"
}

# Regression 16: local-only governance does not create or mutate a GitHub PR.
test_local_gate_never_touches_a_pr() {
  local fakebin marker out status brief
  fakebin=$(fm_fakebin "$TMP_ROOT/fake16")
  marker="$TMP_ROOT/gh-was-called"
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
echo called >> "$marker"
exit 0
SH
  chmod +x "$fakebin/gh"
  cp "$fakebin/gh" "$fakebin/gh-axi"
  # A brief that mentions a PR must be REFUSED by the local-only gate.
  brief="$TMP_ROOT/remote-brief.txt"
  printf 'update PR #592 after landing\n' > "$brief"
  # shellcheck disable=SC2046
  out=$(PATH="$fakebin:$PATH" local_gate $(ready_args) --text-file "$brief"); status=$?
  expect_code 1 "$status" "a local-only gate carrying PR/push text must be refused"
  assert_contains "$out" "never touches a remote or PR" "must refuse the remote instruction"
  # And a passing gate never invokes gh/gh-axi at all.
  # shellcheck disable=SC2046
  PATH="$fakebin:$PATH" local_gate $(ready_args) >/dev/null 2>&1
  assert_absent "$marker" "the local-only gate must never invoke gh/gh-axi"
  pass "local-only governance neither invokes gh nor accepts PR/push instructions"
}

# Regression 17: public PR-mode work still routes to no-mistakes/PR, not local-only.
# fm-merge-local (the local-only landing adapter) refuses a non-local-only task and
# directs it to the PR merge path.
test_pr_mode_routes_to_no_mistakes_not_local() {
  local id=lg-17 out status
  fm_write_meta "$FM_STATE_OVERRIDE/$id.meta" "project=$TMP_ROOT/repo" "mode=direct-PR" "kind=ship"
  out=$("$MERGE_LOCAL" "$id" 2>&1); status=$?
  expect_code 1 "$status" "a PR-mode task must be refused by the local-only adapter"
  assert_contains "$out" "not local-only" "must explain the PR-mode task is not local-only"
  assert_contains "$out" "fm-pr-merge.sh" "must route PR-mode work to the no-mistakes/PR merge path"
  pass "public PR-mode work still routes to no-mistakes/PR, not the local-only adapter"
}

test_local_gate_ready_when_complete
test_local_gate_blocks_each_missing_field
test_local_gate_captain_sha_must_equal_candidate
test_local_gate_never_touches_a_pr
test_pr_mode_routes_to_no_mistakes_not_local

pass "fm-local-gate: all local-only gate cases passed"

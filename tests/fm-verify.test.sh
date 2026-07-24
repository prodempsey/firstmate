#!/usr/bin/env bash
# tests/fm-verify.test.sh - behavior tests for bin/fm-verify.sh, the Gauntlet
# pre-QA verifier. Every fixture is a deliberately-shaped candidate repo; the
# verifier is LLM-free and execution-backed, so the tests assert on the machine
# bundle it produces and on its exit code.
#
# Coverage:
#   identity       clean pass; SHA mismatch; branch mismatch; dirty tree;
#                  detached HEAD each fail the gate
#   base_currency  --base current => pass; --base stale => fail; fm-trunk-check
#                  integration (--project) current => pass, missing declaration
#                  => fail closed
#   tests          suites ACTUALLY executed: a passing suite passes; a failing
#                  suite, a SKIP (never a pass), and no-tests each fail
#   cue_lint       FC-004/FC-006/FC-007 detection cues hit the diff at the right
#                  file:line; a clean diff produces no hits; unlinted classes are
#                  reported advisory-only, not silently clean
#   brief_contract contract echoed from the brief; no-commits and a wrong branch
#                  name each fail
#   refuse         missing worktree, unknown option, and a missing test runner
#                  all exit 2 (fail closed, FC-004) and leave no partial bundle
#   bundle         a completed run leaves a valid-JSON bundle + summary sibling
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

VERIFY="$ROOT/bin/fm-verify.sh"
fm_git_identity
TMP=$(fm_test_tmproot fm-verify)

BRIEF="$TMP/brief.md"
cat > "$BRIEF" <<'EOF'
# Setup
1. First action: create your branch: git checkout -b fm/g1
# Rules
1. Never push to any remote and never open a PR.
# Definition of done
When implemented and committed, append done: ready in branch fm/g1
EOF

# build_repo <name>: a repo at $TMP/<name>/r with a passing test suite, a base
# commit on main, and a fresh fm/g1 branch checked out. Echoes the repo path.
build_repo() {
  local name=$1
  local d="$TMP/$name"
  mkdir -p "$d"
  git -C "$d" init -q r
  git -C "$d/r" checkout -q -b main
  mkdir -p "$d/r/tests"
  printf '#!/usr/bin/env bash\necho "ok - a"\n' > "$d/r/tests/t.test.sh"
  chmod +x "$d/r/tests/t.test.sh"
  echo base > "$d/r/f.txt"
  git -C "$d/r" add -A
  git -C "$d/r" commit -qm base
  git -C "$d/r" checkout -q -b fm/g1
  printf '%s\n' "$d/r"
}

# run_verify <out> <args...>: run the verifier, echo exit code to stdout.
run_verify() {
  local out=$1; shift
  FM_HOME="$TMP/nohome" "$VERIFY" --out "$out" --brief "$BRIEF" "$@" >/dev/null 2>&1
  printf '%s\n' "$?"
}

bget() { jq -r "$2" "$1"; }

# --- identity: clean candidate passes end to end -----------------------------
R=$(build_repo clean)
echo feat >> "$R/f.txt"; git -C "$R" commit -qam feature
SHA=$(git -C "$R" rev-parse HEAD)
OUT="$TMP/clean.json"
rc=$(run_verify "$OUT" --worktree "$R" --base main --sha "$SHA" --branch fm/g1 --task g1)
expect_code 0 "$rc" "clean candidate exits 0"
[ "$(bget "$OUT" .verdict)" = pass ] || fail "clean candidate verdict should be pass"
[ "$(bget "$OUT" '.gates[]|select(.gate=="identity")|.status')" = pass ] || fail "identity gate should pass on clean candidate"
[ "$(bget "$OUT" .finding_count)" = 0 ] || fail "clean candidate should have zero findings"
pass "clean candidate: verdict pass, exit 0, no findings"

# --- identity: SHA mismatch fails --------------------------------------------
rc=$(run_verify "$TMP/mm.json" --worktree "$R" --base main --sha deadbeefdeadbeef --branch fm/g1)
expect_code 1 "$rc" "SHA mismatch exits 1"
[ "$(bget "$TMP/mm.json" '.gates[]|select(.gate=="identity")|.status')" = fail ] || fail "SHA mismatch should fail identity"
[ "$(bget "$TMP/mm.json" '.findings[]|select(.code=="sha-mismatch")|.code')" = sha-mismatch ] || fail "expected sha-mismatch finding"
pass "SHA mismatch: identity fail, exit 1"

# --- identity: branch mismatch fails -----------------------------------------
rc=$(run_verify "$TMP/bm.json" --worktree "$R" --base main --branch fm/other)
expect_code 1 "$rc" "branch mismatch exits 1"
[ "$(bget "$TMP/bm.json" '.findings[]|select(.code=="branch-mismatch")|.code')" = branch-mismatch ] || fail "expected branch-mismatch finding"
pass "branch mismatch: identity fail"

# --- identity: dirty tree fails ----------------------------------------------
RD=$(build_repo dirty)
echo feat >> "$RD/f.txt"; git -C "$RD" commit -qam feature
echo uncommitted >> "$RD/f.txt"
rc=$(run_verify "$TMP/dirty.json" --worktree "$RD" --base main)
expect_code 1 "$rc" "dirty tree exits 1"
[ "$(bget "$TMP/dirty.json" '.findings[]|select(.code=="tree-dirty")|.code')" = tree-dirty ] || fail "expected tree-dirty finding"
pass "dirty tree: identity fail"

# --- identity: detached HEAD fails -------------------------------------------
RH=$(build_repo detached)
echo feat >> "$RH/f.txt"; git -C "$RH" commit -qam feature
git -C "$RH" checkout -q --detach HEAD
rc=$(run_verify "$TMP/det.json" --worktree "$RH" --base main)
expect_code 1 "$rc" "detached HEAD exits 1"
[ "$(bget "$TMP/det.json" '.findings[]|select(.code=="detached-head")|.code')" = detached-head ] || fail "expected detached-head finding"
pass "detached HEAD: identity fail"

# --- base_currency: stale base fails -----------------------------------------
RS=$(build_repo stale)
git -C "$RS" checkout -q main                    # free fm/g1 for a worktree
git -C "$RS" worktree add -q "$TMP/stale/cand" fm/g1
# advance main after the branch point; the candidate never picks it up
echo trunkmove >> "$RS/f.txt"; git -C "$RS" commit -qam advance
( cd "$TMP/stale/cand" && echo feat >> f.txt && git commit -qam feature )
rc=$(run_verify "$TMP/stale.json" --worktree "$TMP/stale/cand" --base main)
expect_code 1 "$rc" "stale base exits 1"
[ "$(bget "$TMP/stale.json" '.gates[]|select(.gate=="base_currency")|.status')" = fail ] || fail "stale base should fail base_currency"
[ "$(bget "$TMP/stale.json" '.gates[]|select(.gate=="base_currency")|.details.relation')" = behind ] || fail "stale base relation should be behind"
[ "$(bget "$TMP/stale.json" '.findings[]|select(.code=="base-stale")|.code')" = base-stale ] || fail "expected base-stale finding"
pass "stale base: base_currency fail, relation behind"

# --- base_currency: fm-trunk-check integration (current => pass) -------------
RT=$(build_repo trunk)
git -C "$RT" checkout -q main                     # free fm/g1 for a worktree
git -C "$RT" worktree add -q "$TMP/trunk/cand" fm/g1
( cd "$TMP/trunk/cand" && echo feat >> f.txt && git commit -qam feature )
HOME_OK="$TMP/home-ok"; mkdir -p "$HOME_OK/config" "$HOME_OK/data"
cat > "$HOME_OK/config/canonical-trunk.json" <<EOF
{ "schema":"firstmate/canonical-trunk/1",
  "projects": { "alpha": {
    "trunk_branch":"main", "trunk_checkout":"$RT", "provisioning_base":"main",
    "serving": { "source":"none", "why":"test" } } } }
EOF
printf -- '- alpha [local-only] - test (added 2026-07-24)\n' > "$HOME_OK/data/projects.md"
FM_HOME="$HOME_OK" "$VERIFY" --worktree "$TMP/trunk/cand" --project alpha \
  --brief "$BRIEF" --out "$TMP/trunkok.json" >/dev/null 2>&1
trc=$?
expect_code 0 "$trc" "trunk-check current candidate exits 0"
[ "$(bget "$TMP/trunkok.json" '.gates[]|select(.gate=="base_currency")|.details.source')" = trunk-check ] || fail "base source should be trunk-check"
[ "$(bget "$TMP/trunkok.json" '.gates[]|select(.gate=="base_currency")|.details.base_branch')" = main ] || fail "trunk base_branch should be main"
[ "$(bget "$TMP/trunkok.json" '.gates[]|select(.gate=="base_currency")|.status')" = pass ] || fail "trunk-check current should pass base_currency"
pass "fm-trunk-check integration: current candidate passes via trunk-check"

# --- base_currency: missing declaration => fail closed -----------------------
HOME_NO="$TMP/home-nodecl"; mkdir -p "$HOME_NO/config" "$HOME_NO/data"
printf -- '- alpha [local-only] - test (added 2026-07-24)\n' > "$HOME_NO/data/projects.md"
FM_HOME="$HOME_NO" "$VERIFY" --worktree "$TMP/trunk/cand" --project alpha \
  --brief "$BRIEF" --out "$TMP/trunkno.json" >/dev/null 2>&1
trc=$?
expect_code 1 "$trc" "missing declaration exits 1"
[ "$(bget "$TMP/trunkno.json" '.gates[]|select(.gate=="base_currency")|.status')" = fail ] || fail "missing declaration should fail base_currency (fail closed)"
[ "$(bget "$TMP/trunkno.json" '.findings[]|select(.code=="trunk-declaration-error")|.code')" = trunk-declaration-error ] || fail "expected trunk-declaration-error finding"
pass "fm-trunk-check integration: missing declaration fails closed"

# --- tests: a failing suite fails --------------------------------------------
RF=$(build_repo failt)
printf 'echo "not ok - broken"\nexit 1\n' >> "$RF/tests/t.test.sh"
git -C "$RF" commit -qam breaktest
rc=$(run_verify "$TMP/failt.json" --worktree "$RF" --base main)
expect_code 1 "$rc" "failing test exits 1"
[ "$(bget "$TMP/failt.json" '.gates[]|select(.gate=="tests")|.status')" = fail ] || fail "failing suite should fail tests gate"
[ "$(bget "$TMP/failt.json" '.gates[]|select(.gate=="tests")|.details.executed')" = true ] || fail "tests must record executed=true"
pass "tests: failing suite fails, executed=true"

# --- tests: a SKIP is a finding, never a pass --------------------------------
RSK=$(build_repo skipt)
printf 'echo "skip: CHROME_BIN not set"\n' >> "$RSK/tests/t.test.sh"
git -C "$RSK" commit -qam skiptest
rc=$(run_verify "$TMP/skipt.json" --worktree "$RSK" --base main)
expect_code 1 "$rc" "skipped test exits 1"
[ "$(bget "$TMP/skipt.json" '.gates[]|select(.gate=="tests")|.status')" = fail ] || fail "a SKIP must fail the tests gate"
[ "$(bget "$TMP/skipt.json" '.findings[]|select(.code=="skipped")|.code')" = skipped ] || fail "expected skipped finding"
[ "$(bget "$TMP/skipt.json" '.gates[]|select(.gate=="tests")|.details.totals.skip')" = 1 ] || fail "skip total should be 1"
pass "tests: SKIP counted as a finding, never a pass"

# --- tests: no test suite => fail --------------------------------------------
RN=$(build_repo notests)
git -C "$RN" rm -q -r tests
echo feat >> "$RN/f.txt"; git -C "$RN" commit -qam droptests
rc=$(run_verify "$TMP/notests.json" --worktree "$RN" --base main)
expect_code 1 "$rc" "no tests exits 1"
[ "$(bget "$TMP/notests.json" '.findings[]|select(.code=="no-tests")|.code')" = no-tests ] || fail "expected no-tests finding"
pass "tests: no discovered suite fails (never a silent pass)"

# --- cue_lint: FC-004/FC-006/FC-007 hits at the right file:line --------------
RC=$(build_repo cues)
cat > "$RC/script.sh" <<'EOF'
command -v gtimeout || true
curl https://example.com/data || true
rm -f /tmp/attest 2>/dev/null || true
EOF
git -C "$RC" add -A; git -C "$RC" commit -qam cues
rc=$(run_verify "$TMP/cues.json" --worktree "$RC" --base main)
expect_code 1 "$rc" "cue hits exit 1"
[ "$(bget "$TMP/cues.json" '.gates[]|select(.gate=="cue_lint")|.status')" = fail ] || fail "cue hits should fail cue_lint"
[ "$(bget "$TMP/cues.json" '[.findings[]|select(.gate=="cue_lint")|.code]|sort|join(",")')" = "FC-004,FC-006,FC-007" ] || fail "expected FC-004/006/007 cue findings"
[ "$(bget "$TMP/cues.json" '.findings[]|select(.code=="FC-004")|.file')" = script.sh ] || fail "FC-004 finding should name script.sh"
[ "$(bget "$TMP/cues.json" '.findings[]|select(.code=="FC-004")|.line')" = 1 ] || fail "FC-004 should be at line 1"
[ "$(bget "$TMP/cues.json" '.findings[]|select(.code=="FC-007")|.line')" = 3 ] || fail "FC-007 should be at line 3"
pass "cue_lint: FC-004/006/007 detected at correct file:line"

# --- cue_lint: a clean diff hits nothing but still reports which classes ran --
[ "$(bget "$TMP/clean.json" '.gates[]|select(.gate=="cue_lint")|.details.advisory_only|index("FC-001")|type')" = number ] || fail "FC-001 (no mechanical cue) should be listed advisory-only"
[ "$(bget "$TMP/clean.json" '.gates[]|select(.gate=="cue_lint")|.details.mechanically_linted|length')" = 3 ] || fail "the 3 mechanically-linted classes should be reported as run"
[ "$(bget "$TMP/clean.json" '.gates[]|select(.gate=="cue_lint")|.details.hits')" = 0 ] || fail "a clean diff should have zero cue hits"
[ "$(bget "$TMP/clean.json" '.gates[]|select(.gate=="cue_lint")|.status')" = pass ] || fail "clean diff cue_lint should pass"
pass "cue_lint: clean diff hits nothing; run/advisory classes both reported"

# --- brief_contract: contract echoed + no-commits fails ----------------------
[ -n "$(bget "$TMP/clean.json" '.gates[]|select(.gate=="brief_contract")|.details.contract_echo')" ] || fail "brief contract should be echoed"
[ "$(bget "$TMP/clean.json" '.gates[]|select(.gate=="brief_contract")|.details.commits_on_branch')" = 1 ] || fail "clean candidate has 1 commit over base"
RB=$(build_repo nocommits)   # branch sits at base: no commits over it
rc=$(run_verify "$TMP/nocommits.json" --worktree "$RB" --base main --task g1)
expect_code 1 "$rc" "no-commits exits 1"
[ "$(bget "$TMP/nocommits.json" '.findings[]|select(.code=="no-commits")|.code')" = no-commits ] || fail "expected no-commits finding"
pass "brief_contract: contract echoed; no-commits fails"

# --- brief_contract: wrong branch name for the task fails --------------------
RW=$(build_repo wrongbranch)
git -C "$RW" checkout -q -b fm/wrong
echo feat >> "$RW/f.txt"; git -C "$RW" commit -qam feature
rc=$(run_verify "$TMP/wrongbranch.json" --worktree "$RW" --base main --task g1)
expect_code 1 "$rc" "wrong branch exits 1"
[ "$(bget "$TMP/wrongbranch.json" '.findings[]|select(.code=="branch-name")|.code')" = branch-name ] || fail "expected branch-name finding"
pass "brief_contract: branch not matching fm/<task> fails"

# --- refuse: exit 2 and no partial bundle ------------------------------------
FM_HOME="$TMP/nohome" "$VERIFY" --worktree "$TMP/does-not-exist" --out "$TMP/refuse1.json" >/dev/null 2>&1
expect_code 2 "$?" "missing worktree refuses (exit 2)"
assert_absent "$TMP/refuse1.json" "a refused run must leave no bundle"

FM_HOME="$TMP/nohome" "$VERIFY" --totally-unknown-flag >/dev/null 2>&1
expect_code 2 "$?" "unknown option refuses (exit 2)"

FM_HOME="$TMP/nohome" "$VERIFY" --worktree "$R" --base main \
  --tests-cmd "definitely-not-a-real-binary-xyz run" --out "$TMP/refuse2.json" >/dev/null 2>&1
expect_code 2 "$?" "missing test runner refuses (exit 2, FC-004)"
assert_absent "$TMP/refuse2.json" "a refused runner run must leave no bundle"
pass "refuse: missing worktree/unknown option/missing runner all exit 2, no partial bundle"

# --- bundle: a completed run leaves a valid bundle + summary -----------------
assert_present "$OUT" "completed run writes the bundle"
jq -e '.schema=="firstmate/verify-bundle/1"' "$OUT" >/dev/null || fail "bundle carries the schema id"
assert_present "$(dirname "$OUT")/verify-summary.md" "completed run writes the summary sibling"
pass "bundle: valid JSON bundle + summary sibling written"

echo "# all fm-verify tests passed"

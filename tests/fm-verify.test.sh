#!/usr/bin/env bash
# tests/fm-verify.test.sh - behavior tests for bin/fm-verify.sh, the Gauntlet
# pre-QA verifier. Every fixture is a deliberately-shaped candidate repo; the
# verifier is LLM-free and execution-backed, so the tests assert on the machine
# bundle it produces and on its exit code.
#
# The adversarial fixtures deliberately exercise the failure classes the verifier
# must itself obey (see the qa-gauntlet-g1-q145 fix round):
#   FC-004  mandatory bindings + a missing runner refuse (never a skipped check)
#   FC-005  a passing suite that dirties the tree or moves HEAD fails revalidation
#           (the proof is atomic with the attestation)
#   FC-006  a hung suite is killed by the hard deadline (timeout(1) path AND the
#           forced PID-watchdog fallback) and recorded as a finding, never a hang
#   FC-002  a mixed shell+make suite set runs EVERY member; a failing member fails
#           the gate (no first-match omission)
#   FC-007  any refusal leaves the output path carrying a non-authoritative marker,
#           never a stale passing bundle
#   F5      detection cues are sourced from the ledger's machine-readable
#           `detection` field; changing the ledger changes what is linted
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

bget() { jq -r "$2" "$1"; }

# verify <out> <args...>: run with the mandatory --brief injected; echo exit code.
verify() {
  local out=$1; shift
  FM_HOME="$TMP/nohome" "$VERIFY" --out "$out" --brief "$BRIEF" "$@" >/dev/null 2>&1
  printf '%s\n' "$?"
}

# --- clean candidate passes end to end (all mandatory bindings supplied) ------
R=$(build_repo clean)
echo feat >> "$R/f.txt"; git -C "$R" commit -qam feature
SHA=$(git -C "$R" rev-parse HEAD)
OUT="$TMP/clean.json"
rc=$(verify "$OUT" --worktree "$R" --base main --sha "$SHA" --branch fm/g1 --task g1)
expect_code 0 "$rc" "clean candidate exits 0"
[ "$(bget "$OUT" .verdict)" = pass ] || fail "clean candidate verdict should be pass"
[ "$(bget "$OUT" '.gates[]|select(.gate=="identity")|.status')" = pass ] || fail "identity gate should pass"
[ "$(bget "$OUT" '.gates[]|select(.gate=="revalidation")|.status')" = pass ] || fail "revalidation gate should pass on a well-behaved suite"
[ "$(bget "$OUT" .finding_count)" = 0 ] || fail "clean candidate should have zero findings"
pass "clean candidate: verdict pass, exit 0, revalidation clean"

# --- F1/FC-004: mandatory bindings are required; absence refuses (exit 2) ------
rc=$(verify "$TMP/no-sha.json" --worktree "$R" --base main --branch fm/g1 --task g1)
expect_code 2 "$rc" "missing --sha refuses"
rc=$(verify "$TMP/no-branch.json" --worktree "$R" --base main --sha "$SHA" --task g1)
expect_code 2 "$rc" "missing --branch refuses"
FM_HOME="$TMP/nohome" "$VERIFY" --out "$TMP/no-task.json" --brief "$BRIEF" \
  --worktree "$R" --base main --sha "$SHA" --branch fm/g1 >/dev/null 2>&1
expect_code 2 "$?" "missing --task refuses"
FM_HOME="$TMP/nohome" "$VERIFY" --out "$TMP/no-brief.json" --brief "$TMP/does-not-exist.md" \
  --worktree "$R" --base main --sha "$SHA" --branch fm/g1 --task g1 >/dev/null 2>&1
expect_code 2 "$?" "unreadable brief refuses"
pass "mandatory bindings: missing sha/branch/task/brief each refuse (F1)"

# --- identity: SHA mismatch, branch mismatch, dirty tree, detached HEAD --------
rc=$(verify "$TMP/mm.json" --worktree "$R" --base main --sha deadbeefdeadbeef --branch fm/g1 --task g1)
expect_code 1 "$rc" "SHA mismatch exits 1"
[ "$(bget "$TMP/mm.json" '.findings[]|select(.code=="sha-mismatch")|.code')" = sha-mismatch ] || fail "expected sha-mismatch finding"
rc=$(verify "$TMP/bm.json" --worktree "$R" --base main --sha "$SHA" --branch fm/other --task g1)
expect_code 1 "$rc" "branch mismatch exits 1"
[ "$(bget "$TMP/bm.json" '.findings[]|select(.code=="branch-mismatch")|.code')" = branch-mismatch ] || fail "expected branch-mismatch finding"
RH=$(build_repo detached); echo feat >> "$RH/f.txt"; git -C "$RH" commit -qam feature
DSHA=$(git -C "$RH" rev-parse HEAD); git -C "$RH" checkout -q --detach HEAD
rc=$(verify "$TMP/det.json" --worktree "$RH" --base main --sha "$DSHA" --branch fm/g1 --task g1)
expect_code 1 "$rc" "detached HEAD exits 1"
[ "$(bget "$TMP/det.json" '.findings[]|select(.code=="detached-head")|.code')" = detached-head ] || fail "expected detached-head finding"
pass "identity: sha/branch mismatch and detached HEAD each fail"

# --- F2/FC-005: a passing suite that DIRTIES the tree fails revalidation -------
RM=$(build_repo mutate-dirty)
printf 'echo "ok - one"\necho "mutation" >> f.txt\necho "ok - two"\n' >> "$RM/tests/t.test.sh"
git -C "$RM" commit -qam "suite dirties tree"
MSHA=$(git -C "$RM" rev-parse HEAD)
rc=$(verify "$TMP/mutdirty.json" --worktree "$RM" --base main --sha "$MSHA" --branch fm/g1 --task g1)
expect_code 1 "$rc" "tree-dirtying suite exits 1"
[ "$(bget "$TMP/mutdirty.json" '.gates[]|select(.gate=="revalidation")|.status')" = fail ] || fail "a suite that dirties the tree must fail revalidation (FC-005)"
[ "$(bget "$TMP/mutdirty.json" '.findings[]|select(.code=="identity-drift")|.code')" = identity-drift ] || fail "expected identity-drift finding"
[ "$(bget "$TMP/mutdirty.json" '.gates[]|select(.gate=="identity")|.details.tree_dirty')" = true ] || fail "published tree_dirty must be true at publish time (no stale clean claim)"
pass "revalidation: a passing suite that dirties the tree fails (FC-005)"

# --- F2/FC-005: a suite that COMMITS (moves HEAD) fails revalidation -----------
RC2=$(build_repo mutate-head)
cat >> "$RC2/tests/t.test.sh" <<'EOF'
echo "ok - one"
echo drift >> f.txt
git -c user.name=x -c user.email=x@e.invalid commit -qam "suite moved HEAD"
EOF
git -C "$RC2" commit -qam "suite commits"
CSHA=$(git -C "$RC2" rev-parse HEAD)
rc=$(verify "$TMP/muthead.json" --worktree "$RC2" --base main --sha "$CSHA" --branch fm/g1 --task g1)
expect_code 1 "$rc" "HEAD-moving suite exits 1"
[ "$(bget "$TMP/muthead.json" '.gates[]|select(.gate=="revalidation")|.status')" = fail ] || fail "a suite that moves HEAD must fail revalidation (FC-005)"
[ "$(bget "$TMP/muthead.json" '.gates[]|select(.gate=="revalidation")|.details.before.head_sha')" != "$(bget "$TMP/muthead.json" '.gates[]|select(.gate=="revalidation")|.details.after.head_sha')" ] || fail "revalidation must record the HEAD move"
pass "revalidation: a suite that moves HEAD fails (FC-005)"

# --- FC-006: a hung suite is killed by the hard deadline (timeout(1) path) -----
RT6=$(build_repo hang)
printf 'echo "ok - one"\nsleep 30\n' >> "$RT6/tests/t.test.sh"
git -C "$RT6" commit -qam "hanging suite"
HSHA=$(git -C "$RT6" rev-parse HEAD)
start=$SECONDS
FM_HOME="$TMP/nohome" FM_VERIFY_TEST_TIMEOUT=2 "$VERIFY" --out "$TMP/hang.json" --brief "$BRIEF" \
  --worktree "$RT6" --base main --sha "$HSHA" --branch fm/g1 --task g1 >/dev/null 2>&1
rc=$?; elapsed=$((SECONDS - start))
expect_code 1 "$rc" "hung suite exits 1"
[ "$elapsed" -lt 25 ] || fail "the deadline did not bound execution (took ${elapsed}s)"
[ "$(bget "$TMP/hang.json" '.findings[]|select(.code=="suite-timeout")|.code')" = suite-timeout ] || fail "expected suite-timeout finding"
[ "$(bget "$TMP/hang.json" '.gates[]|select(.gate=="tests")|.details.suites[0].timed_out')" = true ] || fail "suite record must mark timed_out=true"
pass "FC-006: hung suite killed by the deadline (timeout path), recorded as a finding"

# --- FC-006: the deadline holds via the PID-watchdog fallback (no timeout(1)) --
start=$SECONDS
FM_HOME="$TMP/nohome" FM_VERIFY_TEST_TIMEOUT=2 FM_VERIFY_FORCE_PID_WATCHDOG=1 "$VERIFY" \
  --out "$TMP/hang2.json" --brief "$BRIEF" \
  --worktree "$RT6" --base main --sha "$HSHA" --branch fm/g1 --task g1 >/dev/null 2>&1
rc=$?; elapsed=$((SECONDS - start))
expect_code 1 "$rc" "hung suite (watchdog) exits 1"
[ "$elapsed" -lt 25 ] || fail "the PID-watchdog deadline did not bound execution (took ${elapsed}s)"
[ "$(bget "$TMP/hang2.json" '.findings[]|select(.code=="suite-timeout")|.code')" = suite-timeout ] || fail "watchdog path must still record suite-timeout"
pass "FC-006: PID-watchdog fallback bounds a hung suite when timeout(1) is forced off"

# --- FC-002: every discovered suite runs; a mixed set omits nothing -----------
if command -v make >/dev/null 2>&1; then
  RMX=$(build_repo mixed)
  printf 'test:\n\t@echo "not ok - make suite ran and failed"; exit 1\n' > "$RMX/Makefile"
  git -C "$RMX" add -A; echo feat >> "$RMX/f.txt"; git -C "$RMX" commit -qam "add failing make suite"
  XSHA=$(git -C "$RMX" rev-parse HEAD)
  rc=$(verify "$TMP/mixed.json" --worktree "$RMX" --base main --sha "$XSHA" --branch fm/g1 --task g1)
  expect_code 1 "$rc" "mixed suite with a failing member exits 1"
  [ "$(bget "$TMP/mixed.json" '.gates[]|select(.gate=="tests")|.details.suites_detected')" = 2 ] || fail "both shell and make suites must be detected"
  [ "$(bget "$TMP/mixed.json" '.gates[]|select(.gate=="tests")|.details.suites_executed')" = 2 ] || fail "both suites must be executed (no first-match omission)"
  [ "$(bget "$TMP/mixed.json" '[.gates[]|select(.gate=="tests")|.details.suites[]|select(.suite=="make test")]|length')" = 1 ] || fail "the make suite must have an execution record"
  [ "$(bget "$TMP/mixed.json" '.gates[]|select(.gate=="tests")|.status')" = fail ] || fail "the failing make suite must fail the gate"
  pass "FC-002: mixed shell+make suite set runs every member; a failing member fails"
else
  echo "skip: make not found (FC-002 mixed-suite fixture)"
fi

# --- tests: failing suite, SKIP, and no-tests each fail -----------------------
RF=$(build_repo failt)
printf 'echo "not ok - broken"\nexit 1\n' >> "$RF/tests/t.test.sh"
git -C "$RF" commit -qam breaktest
FSHA=$(git -C "$RF" rev-parse HEAD)
rc=$(verify "$TMP/failt.json" --worktree "$RF" --base main --sha "$FSHA" --branch fm/g1 --task g1)
expect_code 1 "$rc" "failing test exits 1"
[ "$(bget "$TMP/failt.json" '.gates[]|select(.gate=="tests")|.status')" = fail ] || fail "failing suite should fail tests gate"

RSK=$(build_repo skipt)
printf 'echo "skip: CHROME_BIN not set"\n' >> "$RSK/tests/t.test.sh"
git -C "$RSK" commit -qam skiptest
KSHA=$(git -C "$RSK" rev-parse HEAD)
rc=$(verify "$TMP/skipt.json" --worktree "$RSK" --base main --sha "$KSHA" --branch fm/g1 --task g1)
expect_code 1 "$rc" "skipped test exits 1"
[ "$(bget "$TMP/skipt.json" '.findings[]|select(.code=="skipped")|.code')" = skipped ] || fail "a SKIP must be a finding"

RN=$(build_repo notests)
git -C "$RN" rm -q -r tests
echo feat >> "$RN/f.txt"; git -C "$RN" commit -qam droptests
NSHA=$(git -C "$RN" rev-parse HEAD)
rc=$(verify "$TMP/notests.json" --worktree "$RN" --base main --sha "$NSHA" --branch fm/g1 --task g1)
expect_code 1 "$rc" "no tests exits 1"
[ "$(bget "$TMP/notests.json" '.findings[]|select(.code=="no-tests")|.code')" = no-tests ] || fail "expected no-tests finding"
pass "tests: failing suite, SKIP, and no-tests each fail"

# --- base_currency: stale base fails; trunk-check current passes, missing fails -
RS=$(build_repo stale)
git -C "$RS" checkout -q main
git -C "$RS" worktree add -q "$TMP/stale/cand" fm/g1
echo trunkmove >> "$RS/f.txt"; git -C "$RS" commit -qam advance
( cd "$TMP/stale/cand" && echo feat >> f.txt && git commit -qam feature )
STSHA=$(git -C "$TMP/stale/cand" rev-parse HEAD)
rc=$(verify "$TMP/stale.json" --worktree "$TMP/stale/cand" --base main --sha "$STSHA" --branch fm/g1 --task g1)
expect_code 1 "$rc" "stale base exits 1"
[ "$(bget "$TMP/stale.json" '.gates[]|select(.gate=="base_currency")|.details.relation')" = behind ] || fail "stale base relation should be behind"

RTk=$(build_repo trunk)
git -C "$RTk" checkout -q main
git -C "$RTk" worktree add -q "$TMP/trunk/cand" fm/g1
( cd "$TMP/trunk/cand" && echo feat >> f.txt && git commit -qam feature )
TKSHA=$(git -C "$TMP/trunk/cand" rev-parse HEAD)
HOME_OK="$TMP/home-ok"; mkdir -p "$HOME_OK/config" "$HOME_OK/data"
cat > "$HOME_OK/config/canonical-trunk.json" <<EOF
{ "schema":"firstmate/canonical-trunk/1",
  "projects": { "alpha": {
    "trunk_branch":"main", "trunk_checkout":"$RTk", "provisioning_base":"main",
    "serving": { "source":"none", "why":"test" } } } }
EOF
printf -- '- alpha [local-only] - test (added 2026-07-24)\n' > "$HOME_OK/data/projects.md"
FM_HOME="$HOME_OK" "$VERIFY" --worktree "$TMP/trunk/cand" --project alpha \
  --sha "$TKSHA" --branch fm/g1 --task g1 --brief "$BRIEF" --out "$TMP/trunkok.json" >/dev/null 2>&1
expect_code 0 "$?" "trunk-check current candidate exits 0"
[ "$(bget "$TMP/trunkok.json" '.gates[]|select(.gate=="base_currency")|.details.source')" = trunk-check ] || fail "base source should be trunk-check"

HOME_NO="$TMP/home-nodecl"; mkdir -p "$HOME_NO/config" "$HOME_NO/data"
printf -- '- alpha [local-only] - test (added 2026-07-24)\n' > "$HOME_NO/data/projects.md"
FM_HOME="$HOME_NO" "$VERIFY" --worktree "$TMP/trunk/cand" --project alpha \
  --sha "$TKSHA" --branch fm/g1 --task g1 --brief "$BRIEF" --out "$TMP/trunkno.json" >/dev/null 2>&1
expect_code 1 "$?" "missing declaration exits 1"
[ "$(bget "$TMP/trunkno.json" '.findings[]|select(.code=="trunk-declaration-error")|.code')" = trunk-declaration-error ] || fail "expected trunk-declaration-error finding (fail closed)"
pass "base_currency: stale base fails; trunk-check current passes, missing declaration fails closed"

# --- cue_lint: built-in FC-004/006/007 fire; advisory classes reported --------
RCu=$(build_repo cues)
cat > "$RCu/script.sh" <<'EOF'
command -v gtimeout || true
curl https://example.com/data || true
rm -f /tmp/attest 2>/dev/null || true
EOF
git -C "$RCu" add -A; git -C "$RCu" commit -qam cues
USHA=$(git -C "$RCu" rev-parse HEAD)
rc=$(verify "$TMP/cues.json" --worktree "$RCu" --base main --sha "$USHA" --branch fm/g1 --task g1)
expect_code 1 "$rc" "cue hits exit 1"
[ "$(bget "$TMP/cues.json" '[.findings[]|select(.gate=="cue_lint")|.code]|sort|unique|join(",")')" = "FC-004,FC-006,FC-007" ] || fail "expected FC-004/006/007 cue findings"
[ "$(bget "$TMP/cues.json" '.findings[]|select(.code=="FC-007")|.line')" = 3 ] || fail "FC-007 should be at line 3"
[ "$(bget "$TMP/cues.json" '.gates[]|select(.gate=="cue_lint")|.details.detections[]|select(.fc=="FC-004")|.source')" = builtin ] || fail "FC-004 detection source should be builtin when the ledger has no detection field"
[ "$(bget "$TMP/clean.json" '.gates[]|select(.gate=="cue_lint")|.details.advisory_only|index("FC-001")|type')" = number ] || fail "FC-001 should be advisory-only"
pass "cue_lint: built-in FC-004/006/007 fire; advisory classes reported"

# --- F5: detection cues are sourced from the ledger; changing it changes lint --
LEDGER_FIX="$TMP/ledger-fixture.jsonl"
cat > "$LEDGER_FIX" <<'EOF'
{"schema":"kraken-failure-class/ledger-event/v1","event":"class-defined","id":"FC-901","name":"Fixture ledger-sourced cue","invariant":"test","cues":["natural language"],"detection":[{"engine":"awk-ere","pattern":"LEDGER_SOURCED_TOKEN","cue_ref":"a token only the ledger knows about"}],"fix":"x","provenance":[],"registry":{}}
EOF
RL=$(build_repo ledger)
printf 'x LEDGER_SOURCED_TOKEN y\n' > "$RL/thing.sh"
git -C "$RL" add -A; git -C "$RL" commit -qam token
LSHA=$(git -C "$RL" rev-parse HEAD)
FM_HOME="$TMP/nohome" FM_FAILURE_LEDGER="$LEDGER_FIX" "$VERIFY" --out "$TMP/ledger.json" --brief "$BRIEF" \
  --worktree "$RL" --base main --sha "$LSHA" --branch fm/g1 --task g1 >/dev/null 2>&1
expect_code 1 "$?" "ledger-sourced cue hit exits 1"
[ "$(bget "$TMP/ledger.json" '.findings[]|select(.code=="FC-901")|.code')" = FC-901 ] || fail "the ledger-defined detection must drive the lint"
[ "$(bget "$TMP/ledger.json" '.gates[]|select(.gate=="cue_lint")|.details.detections[]|select(.fc=="FC-901")|.source')" = ledger ] || fail "FC-901 detection source should be ledger"
pass "F5: detection cues sourced from the ledger; ledger data drives what is linted"

# --- F4/FC-007: any refusal leaves a non-authoritative marker, not a stale pass -
STALE_OUT="$TMP/stale-out.json"
cp "$OUT" "$STALE_OUT"                          # a genuine prior PASS bundle
[ "$(bget "$STALE_OUT" .verdict)" = pass ] || fail "precondition: stale-out starts as a pass"
FM_HOME="$TMP/nohome" "$VERIFY" --out "$STALE_OUT" --brief "$BRIEF" \
  --worktree "$R" --base main --sha "$SHA" --branch fm/g1 --task g1 \
  --tests-cmd "definitely-not-a-real-binary-xyz run" >/dev/null 2>&1
expect_code 2 "$?" "missing runner refuses (exit 2, FC-004)"
[ "$(bget "$STALE_OUT" .verdict)" = invalidated ] || fail "a refused run must overwrite the stale pass with an invalidation marker (FC-007)"

STALE_OUT2="$TMP/stale-out2.json"
cp "$OUT" "$STALE_OUT2"
FM_HOME="$TMP/nohome" "$VERIFY" --out "$STALE_OUT2" --brief "$BRIEF" \
  --worktree "$R" --base main --branch fm/g1 --task g1 >/dev/null 2>&1   # missing --sha
expect_code 2 "$?" "missing binding refuses"
[ "$(bget "$STALE_OUT2" .verdict)" = invalidated ] || fail "a binding-refusal must also invalidate the stale pass (FC-007)"
pass "FC-007: every refusal path leaves an invalidation marker, never a readable stale pass"

# --- refuse: missing worktree and unknown option still exit 2 -----------------
FM_HOME="$TMP/nohome" "$VERIFY" --out "$TMP/rf.json" --brief "$BRIEF" \
  --worktree "$TMP/does-not-exist" --sha x --branch fm/g1 --task g1 >/dev/null 2>&1
expect_code 2 "$?" "missing worktree refuses"
FM_HOME="$TMP/nohome" "$VERIFY" --totally-unknown-flag >/dev/null 2>&1
expect_code 2 "$?" "unknown option refuses"
pass "refuse: missing worktree and unknown option exit 2"

# --- bundle: a completed run writes a valid bundle + summary sibling -----------
assert_present "$OUT" "completed run writes the bundle"
jq -e '.schema=="firstmate/verify-bundle/1"' "$OUT" >/dev/null || fail "bundle carries the schema id"
assert_present "$(dirname "$OUT")/verify-summary.md" "completed run writes the summary sibling"
pass "bundle: valid JSON bundle + summary sibling written"

echo "# all fm-verify tests passed"

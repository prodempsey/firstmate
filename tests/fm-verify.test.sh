#!/usr/bin/env bash
# tests/fm-verify.test.sh - behavior tests for bin/fm-verify.sh, the Shakedown
# pre-QA verifier. Every fixture is a deliberately-shaped candidate repo; the
# verifier is LLM-free and execution-backed, so the tests assert on the machine
# bundle it produces and on its exit code.
#
# The adversarial fixtures exercise the failure classes the verifier must itself
# obey, including the round-2 (qa-gauntlet-g1r2-q148) escapes:
#   FC-005  tests run in a DISPOSABLE isolated checkout, so neither a synchronous
#           nor a delayed BACKGROUND mutation can dirty the authority-bearing
#           worktree the bundle attests.
#   FC-002  discovery is independent of execution and queries Make's own parsed
#           target database, so `test :` (whitespace before the colon) is found
#           and its failing suite is executed, not silently omitted.
#   FC-007  EVERY refusal - unknown option, invalid format, missing tool/binding -
#           invalidates BOTH the JSON bundle and the summary sibling first, so no
#           stale pass survives in either artifact.
#   F5      executable cues are read LIVE from the production ledger's `detection`
#           field with no hardcoded fallback; editing the ledger changes the lint.
#   FC-006  a wedged suite is killed by a portable hard deadline (timeout AND the
#           forced PID-watchdog path).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

VERIFY="$ROOT/bin/fm-verify.sh"
LEDGER="$ROOT/docs/failure-classes/ledger.jsonl"
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

verify() {
  local out=$1; shift
  FM_HOME="$TMP/nohome" "$VERIFY" --out "$out" --brief "$BRIEF" "$@" >/dev/null 2>&1
  printf '%s\n' "$?"
}

# --- clean candidate passes end to end ----------------------------------------
R=$(build_repo clean)
echo feat >> "$R/f.txt"; git -C "$R" commit -qam feature
SHA=$(git -C "$R" rev-parse HEAD)
OUT="$TMP/clean.json"
rc=$(verify "$OUT" --worktree "$R" --base main --sha "$SHA" --branch fm/g1 --task g1)
expect_code 0 "$rc" "clean candidate exits 0"
[ "$(bget "$OUT" .verdict)" = pass ] || fail "clean candidate verdict should be pass"
[ "$(bget "$OUT" '.gates[]|select(.gate=="tests")|.details.isolated_checkout')" = true ] || fail "tests must run in an isolated checkout"
[ "$(bget "$OUT" '.gates[]|select(.gate=="revalidation")|.status')" = pass ] || fail "revalidation should pass on a clean run"
[ "$(bget "$OUT" .finding_count)" = 0 ] || fail "clean candidate should have zero findings"
pass "clean candidate: verdict pass, isolated checkout, revalidation clean"

# --- FC-005: a delayed BACKGROUND mutation cannot dirty the authoritative tree -
# (the exact round-2 escape: the suite launches a child that writes AFTER return)
RBG=$(build_repo bg-mutate)
cat >> "$RBG/tests/t.test.sh" <<'EOF'
echo "ok - one"
nohup sh -c 'sleep 0.4; echo late-mutation >> f.txt' >/dev/null 2>&1 &
echo "ok - two"
EOF
git -C "$RBG" commit -qam "delayed background mutation"
BSHA=$(git -C "$RBG" rev-parse HEAD)
rc=$(verify "$TMP/bg.json" --worktree "$RBG" --base main --sha "$BSHA" --branch fm/g1 --task g1)
expect_code 0 "$rc" "isolated background mutation still exits 0"
[ "$(bget "$TMP/bg.json" '.gates[]|select(.gate=="identity")|.details.tree_dirty')" = false ] || fail "the authoritative tree must be attested clean; the mutation is isolated"
sleep 1   # let the delayed child finish; it wrote into the disposable checkout
[ -z "$(git -C "$RBG" status --porcelain)" ] || fail "FC-005: the authority-bearing worktree was dirtied by an executed suite"
pass "FC-005: a delayed background mutation runs in isolation; the authoritative tree stays clean"

# --- FC-005: a synchronous tree-dirtying suite is also contained --------------
RS5=$(build_repo sync-mutate)
printf 'echo "ok - one"\necho mutation >> f.txt\necho "ok - two"\n' >> "$RS5/tests/t.test.sh"
git -C "$RS5" commit -qam "suite dirties its checkout"
S5=$(git -C "$RS5" rev-parse HEAD)
rc=$(verify "$TMP/sync.json" --worktree "$RS5" --base main --sha "$S5" --branch fm/g1 --task g1)
expect_code 0 "$rc" "isolated synchronous mutation still exits 0"
[ -z "$(git -C "$RS5" status --porcelain)" ] || fail "FC-005: the authoritative worktree was dirtied by a synchronous suite"
pass "FC-005: a synchronous tree-dirtying suite is contained in the isolated checkout"

# --- FC-004/005: memory dependencies are provisioned before suite execution ---
build_memory_repo() {
  local name=$1
  local repo
  repo=$(build_repo "$name")
  mkdir -p "$repo/memory/bin"
  cat > "$repo/memory/package.json" <<'EOF'
{"name":"memory-fixture","private":true,"type":"module","dependencies":{"fixture-dep":"1.0.0"}}
EOF
  cat > "$repo/memory/package-lock.json" <<'EOF'
{"name":"memory-fixture","lockfileVersion":3,"requires":true,"packages":{"":{"dependencies":{"fixture-dep":"1.0.0"}},"node_modules/fixture-dep":{"version":"1.0.0"}}}
EOF
  cat > "$repo/memory/bin/mem.mjs" <<'EOF'
import value from "fixture-dep";
if (value !== "ready") process.exit(1);
EOF
  printf 'memory/node_modules/\n' > "$repo/.gitignore"
  cat >> "$repo/tests/t.test.sh" <<'EOF'
[ -z "${FM_ROOT_OVERRIDE+x}" ] || { echo "not ok - FM_ROOT_OVERRIDE leaked into sandbox"; exit 1; }
[ -z "${FM_HOME+x}" ] || { echo "not ok - FM_HOME leaked into sandbox"; exit 1; }
[ -z "${FM_STATE_OVERRIDE+x}" ] || { echo "not ok - FM_STATE_OVERRIDE leaked into sandbox"; exit 1; }
node memory/bin/mem.mjs
echo "ok - memory CLI dependency loaded"
EOF
  git -C "$repo" add -A
  git -C "$repo" commit -qm "memory fixture"
  printf '%s\n' "$repo"
}

FAKEBIN="$TMP/fake-npm"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/npm" <<'EOF'
#!/usr/bin/env bash
exit 91
EOF
chmod +x "$FAKEBIN/npm"

RMD=$(build_memory_repo memory-deps-copy)
mkdir -p "$RMD/memory/node_modules/fixture-dep"
cat > "$RMD/memory/node_modules/fixture-dep/package.json" <<'EOF'
{"name":"fixture-dep","version":"1.0.0","type":"module","exports":"./index.mjs"}
EOF
printf 'export default "ready";\n' > "$RMD/memory/node_modules/fixture-dep/index.mjs"
MDSHA=$(git -C "$RMD" rev-parse HEAD)
PATH="$FAKEBIN:$PATH" FM_HOME="$TMP/nohome" "$VERIFY" \
  --out "$TMP/memdeps-copy.json" --brief "$BRIEF" \
  --worktree "$RMD" --base main --sha "$MDSHA" --branch fm/g1 --task g1 >/dev/null 2>&1
expect_code 0 "$?" "source memory dependencies make the isolated fixture pass"
[ "$(bget "$TMP/memdeps-copy.json" '.gates[]|select(.gate=="tests")|.details.dependency_provisioner')" = source-copy ] \
  || fail "byte-identical memory lockfiles must prefer source node_modules"
pass "FC-005: provisioned memory dependencies make a mem-dependent sandbox fixture pass"

mkdir -p "$TMP/poison-root" "$TMP/poison-home" "$TMP/poison-state"
FM_ROOT_OVERRIDE="$TMP/poison-root" FM_HOME="$TMP/poison-home" \
  FM_STATE_OVERRIDE="$TMP/poison-state" FM_FAILURE_LEDGER="$LEDGER" \
  PATH="$FAKEBIN:$PATH" "$VERIFY" \
  --out "$TMP/memdeps-env.json" --brief "$BRIEF" \
  --worktree "$RMD" --base main --sha "$MDSHA" --branch fm/g1 --task g1 >/dev/null 2>&1
expect_code 0 "$?" "poisoned ambient home overrides are scrubbed from sandbox suites"
[ "$(bget "$TMP/memdeps-env.json" '.gates[]|select(.gate=="tests")|.status')" = pass ] \
  || fail "poisoned ambient home overrides must not reach the mem-dependent fixture"
pass "FC-004: poisoned ambient home overrides are scrubbed from sandbox suite execution"

RMF=$(build_memory_repo memory-deps-fail)
MFSHA=$(git -C "$RMF" rev-parse HEAD)
PATH="$FAKEBIN:$PATH" FM_HOME="$TMP/nohome" "$VERIFY" \
  --out "$TMP/memdeps-fail.json" --brief "$BRIEF" \
  --worktree "$RMF" --base main --sha "$MFSHA" --branch fm/g1 --task g1 >/dev/null 2>&1
expect_code 1 "$?" "memory dependency provisioning failure exits 1"
[ "$(bget "$TMP/memdeps-fail.json" .finding_count)" = 1 ] \
  || fail "dependency provisioning failure must yield exactly one finding"
[ "$(bget "$TMP/memdeps-fail.json" '.findings[0]|(.gate + "/" + .code)')" = tests/deps-unprovisioned ] \
  || fail "dependency provisioning failure must yield tests/deps-unprovisioned"
[ "$(bget "$TMP/memdeps-fail.json" '.gates[]|select(.gate=="tests")|.details.suites_executed')" = 0 ] \
  || fail "dependency provisioning failure must stop suite fan-out"
pass "FC-004: dependency provisioning failure yields one fail-closed finding"

# --- mandatory bindings are required; absence refuses (exit 2) ----------------
rc=$(verify "$TMP/no-sha.json" --worktree "$R" --base main --branch fm/g1 --task g1)
expect_code 2 "$rc" "missing --sha refuses"
FM_HOME="$TMP/nohome" "$VERIFY" --out "$TMP/no-task.json" --brief "$BRIEF" \
  --worktree "$R" --base main --sha "$SHA" --branch fm/g1 >/dev/null 2>&1
expect_code 2 "$?" "missing --task refuses"
FM_HOME="$TMP/nohome" "$VERIFY" --out "$TMP/no-brief.json" --brief "$TMP/does-not-exist.md" \
  --worktree "$R" --base main --sha "$SHA" --branch fm/g1 --task g1 >/dev/null 2>&1
expect_code 2 "$?" "unreadable brief refuses"
pass "mandatory bindings: missing sha/task/brief each refuse"

# --- identity: SHA mismatch, branch mismatch, detached HEAD -------------------
rc=$(verify "$TMP/mm.json" --worktree "$R" --base main --sha deadbeefdeadbeef --branch fm/g1 --task g1)
expect_code 1 "$rc" "SHA mismatch exits 1"
[ "$(bget "$TMP/mm.json" '.findings[]|select(.code=="sha-mismatch")|.code')" = sha-mismatch ] || fail "expected sha-mismatch finding"
RHd=$(build_repo detached); echo feat >> "$RHd/f.txt"; git -C "$RHd" commit -qam feature
DSHA=$(git -C "$RHd" rev-parse HEAD); git -C "$RHd" checkout -q --detach HEAD
rc=$(verify "$TMP/det.json" --worktree "$RHd" --base main --sha "$DSHA" --branch fm/g1 --task g1)
expect_code 1 "$rc" "detached HEAD exits 1"
[ "$(bget "$TMP/det.json" '.findings[]|select(.code=="detached-head")|.code')" = detached-head ] || fail "expected detached-head finding"
pass "identity: sha mismatch and detached HEAD each fail"

# --- FC-006: a hung suite is killed by the hard deadline (timeout + watchdog) --
RT6=$(build_repo hang)
printf 'echo "ok - one"\nsleep 30\n' >> "$RT6/tests/t.test.sh"
git -C "$RT6" commit -qam "hanging suite"
HSHA=$(git -C "$RT6" rev-parse HEAD)
for mode in timeout watchdog; do
  force=0; [ "$mode" = watchdog ] && force=1
  start=$SECONDS
  FM_HOME="$TMP/nohome" FM_VERIFY_TEST_TIMEOUT=2 FM_VERIFY_FORCE_PID_WATCHDOG=$force "$VERIFY" \
    --out "$TMP/hang-$mode.json" --brief "$BRIEF" \
    --worktree "$RT6" --base main --sha "$HSHA" --branch fm/g1 --task g1 >/dev/null 2>&1
  rc=$?; elapsed=$((SECONDS - start))
  expect_code 1 "$rc" "hung suite ($mode) exits 1"
  [ "$elapsed" -lt 25 ] || fail "the $mode deadline did not bound execution (${elapsed}s)"
  [ "$(bget "$TMP/hang-$mode.json" '.findings[]|select(.code=="suite-timeout")|.code')" = suite-timeout ] || fail "$mode path must record suite-timeout"
done
pass "FC-006: a hung suite is bounded by the deadline (timeout and forced-watchdog paths)"

# --- FC-002: Make's parsed DB finds `test :` (space before colon) -------------
if command -v make >/dev/null 2>&1; then
  RMk=$(build_repo make-space)
  printf 'test :\n\t@echo "not ok - make suite ran"; exit 1\n' > "$RMk/Makefile"
  git -C "$RMk" add -A; echo feat >> "$RMk/f.txt"; git -C "$RMk" commit -qam "test with space before colon"
  XSHA=$(git -C "$RMk" rev-parse HEAD)
  rc=$(verify "$TMP/makespace.json" --worktree "$RMk" --base main --sha "$XSHA" --branch fm/g1 --task g1)
  expect_code 1 "$rc" "make 'test :' suite exits 1"
  [ "$(bget "$TMP/makespace.json" '.gates[]|select(.gate=="tests")|.details.declared_suites|index("make test")|type')" = number ] || fail "make 'test :' target must be discovered via Make's parsed DB"
  [ "$(bget "$TMP/makespace.json" '.gates[]|select(.gate=="tests")|.details.suites_executed')" = 2 ] || fail "both shell and make suites must execute (no omission)"
  [ "$(bget "$TMP/makespace.json" '.gates[]|select(.gate=="tests")|.status')" = fail ] || fail "the failing make suite must fail the gate"
  pass "FC-002: 'test :' is discovered via Make's parsed target DB and executed"
else
  echo "skip: make not found (FC-002 Make-DB fixture)"
fi

# --- tests: failing suite, SKIP, no-tests each fail; declared==executed --------
RF=$(build_repo failt)
printf 'echo "not ok - broken"\nexit 1\n' >> "$RF/tests/t.test.sh"
git -C "$RF" commit -qam breaktest; FSHA=$(git -C "$RF" rev-parse HEAD)
rc=$(verify "$TMP/failt.json" --worktree "$RF" --base main --sha "$FSHA" --branch fm/g1 --task g1)
expect_code 1 "$rc" "failing test exits 1"
RSK=$(build_repo skipt)
printf 'echo "skip: CHROME_BIN not set"\n' >> "$RSK/tests/t.test.sh"
git -C "$RSK" commit -qam skiptest; KSHA=$(git -C "$RSK" rev-parse HEAD)
rc=$(verify "$TMP/skipt.json" --worktree "$RSK" --base main --sha "$KSHA" --branch fm/g1 --task g1)
expect_code 1 "$rc" "skipped test exits 1"
[ "$(bget "$TMP/skipt.json" '.findings[]|select(.code=="skipped")|.code')" = skipped ] || fail "a SKIP must be a finding"
RN=$(build_repo notests)
git -C "$RN" rm -q -r tests; echo feat >> "$RN/f.txt"; git -C "$RN" commit -qam droptests
NSHA=$(git -C "$RN" rev-parse HEAD)
rc=$(verify "$TMP/notests.json" --worktree "$RN" --base main --sha "$NSHA" --branch fm/g1 --task g1)
expect_code 1 "$rc" "no tests exits 1"
[ "$(bget "$TMP/notests.json" '.findings[]|select(.code=="no-tests")|.code')" = no-tests ] || fail "expected no-tests finding"
pass "tests: failing suite, SKIP, and no-tests each fail"

# --- base_currency: stale base fails; trunk-check current/missing -------------
RSt=$(build_repo stale)
git -C "$RSt" checkout -q main
git -C "$RSt" worktree add -q "$TMP/stale/cand" fm/g1
echo trunkmove >> "$RSt/f.txt"; git -C "$RSt" commit -qam advance
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
  "projects": { "alpha": { "trunk_branch":"main", "trunk_checkout":"$RTk", "provisioning_base":"main",
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
[ "$(bget "$TMP/trunkno.json" '.findings[]|select(.code=="trunk-declaration-error")|.code')" = trunk-declaration-error ] || fail "expected trunk-declaration-error (fail closed)"
pass "base_currency: stale base fails; trunk-check current passes, missing declaration fails closed"

# --- F5: cues are read LIVE from the production ledger (no hardcoded fallback) --
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
[ "$(bget "$TMP/cues.json" '[.findings[]|select(.gate=="cue_lint")|.code]|sort|unique|join(",")')" = "FC-004,FC-006,FC-007" ] || fail "the production ledger must drive FC-004/006/007"
[ "$(bget "$TMP/cues.json" '[.gates[]|select(.gate=="cue_lint")|.details.detections[].source]|unique|join(",")')" = ledger ] || fail "every detection source must be the live ledger (no builtin)"
[ "$(bget "$TMP/cues.json" '.gates[]|select(.gate=="cue_lint")|.details.ledger')" = "$LEDGER" ] || fail "cue_lint must record the live ledger path it read"
pass "F5: FC-004/006/007 detections are read live from the production ledger"

# --- F5: editing the ledger authority alone changes the lint ------------------
STRIPPED="$TMP/ledger-no-fc007.jsonl"
jq -c 'if .id=="FC-007" then del(.detection) else . end' "$LEDGER" > "$STRIPPED"
FM_HOME="$TMP/nohome" FM_FAILURE_LEDGER="$STRIPPED" "$VERIFY" --out "$TMP/cues2.json" --brief "$BRIEF" \
  --worktree "$RCu" --base main --sha "$USHA" --branch fm/g1 --task g1 >/dev/null 2>&1
[ "$(bget "$TMP/cues2.json" '[.findings[]|select(.gate=="cue_lint")|.code]|sort|unique|join(",")')" = "FC-004,FC-006" ] || fail "removing FC-007's detection from the ledger must stop FC-007 linting"
[ "$(bget "$TMP/cues2.json" '.gates[]|select(.gate=="cue_lint")|.details.advisory_only|index("FC-007")|type')" = number ] || fail "FC-007 must fall to advisory-only when the ledger drops its detection"
pass "F5: lint behavior changes from the ledger authority alone (strip FC-007 detection => not linted)"

# --- FC-007: EVERY refusal invalidates the prior pass in BOTH artifacts --------
seed_pass() { # <out>  - seed an authoritative pass bundle + pass summary
  jq -n '{schema:"firstmate/verify-bundle/1",verdict:"pass"}' > "$1"
  printf '# Shakedown verify - pass\n' > "$(dirname "$1")/verify-summary.md"
}
for refusal in unknown-option bad-format missing-runner missing-binding; do
  SO="$TMP/refuse-$refusal/verify-bundle.json"; mkdir -p "$(dirname "$SO")"
  seed_pass "$SO"
  case "$refusal" in
    unknown-option)  FM_HOME="$TMP/nohome" "$VERIFY" --out "$SO" --brief "$BRIEF" --totally-unknown-flag >/dev/null 2>&1 ;;
    bad-format)      FM_HOME="$TMP/nohome" "$VERIFY" --out "$SO" --brief "$BRIEF" --format bogus >/dev/null 2>&1 ;;
    missing-runner)  FM_HOME="$TMP/nohome" "$VERIFY" --out "$SO" --brief "$BRIEF" --worktree "$R" --base main --sha "$SHA" --branch fm/g1 --task g1 --tests-cmd "definitely-not-a-real-binary-xyz run" >/dev/null 2>&1 ;;
    missing-binding) FM_HOME="$TMP/nohome" "$VERIFY" --out "$SO" --brief "$BRIEF" --worktree "$R" --base main --branch fm/g1 --task g1 >/dev/null 2>&1 ;;
  esac
  rc=$?
  expect_code 2 "$rc" "$refusal refuses (exit 2)"
  [ "$(bget "$SO" .verdict)" = invalidated ] || fail "FC-007: $refusal left a readable stale PASS bundle"
  assert_no_grep "pass" "$(dirname "$SO")/verify-summary.md" "FC-007: $refusal left a stale PASS summary sibling"
done
pass "FC-007: unknown-option, bad-format, missing-runner, missing-binding each invalidate BOTH artifacts"

# --- refuse: missing worktree and unknown option exit 2 -----------------------
FM_HOME="$TMP/nohome" "$VERIFY" --out "$TMP/rf.json" --brief "$BRIEF" \
  --worktree "$TMP/does-not-exist" --sha x --branch fm/g1 --task g1 >/dev/null 2>&1
expect_code 2 "$?" "missing worktree refuses"
pass "refuse: missing worktree exits 2"

# --- bundle: a completed run writes a valid bundle + summary sibling -----------
assert_present "$OUT" "completed run writes the bundle"
jq -e '.schema=="firstmate/verify-bundle/1"' "$OUT" >/dev/null || fail "bundle carries the schema id"
assert_present "$(dirname "$OUT")/verify-summary.md" "completed run writes the summary sibling"
pass "bundle: valid JSON bundle + summary sibling written"

echo "# all fm-verify tests passed"

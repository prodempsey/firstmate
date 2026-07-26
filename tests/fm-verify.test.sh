#!/usr/bin/env bash
# tests/fm-verify.test.sh - behavior tests for bin/fm-verify.sh, the Shakedown
# pre-QA verifier. Every fixture is a deliberately-shaped candidate repo; the
# verifier uses bounded fake adjudication and execution-backed gates, so the
# tests assert on the machine bundle it produces and on its exit code.
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
#           field - both the inline class-defined detection and later class-amended
#           detection, folded at read - with no hardcoded fallback; a class the ledger
#           gives no detection stays advisory; editing the ledger changes the lint.
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
FM_SCANNER_DIR="$TMP/scanners"
export FM_SCANNER_DIR
mkdir -p "$FM_SCANNER_DIR/bin"
cat > "$FM_SCANNER_DIR/bin/gitleaks" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then printf 'gitleaks version 8.30.1\n'; exit 0; fi
if [ -n "${FM_TEST_ADVANCE_BASE_REPO:-}" ] &&
  [ -n "${FM_TEST_ADVANCE_BASE_SHA:-}" ] &&
  [ -n "${FM_TEST_ADVANCE_BASE_MARKER:-}" ] &&
  [ ! -e "$FM_TEST_ADVANCE_BASE_MARKER" ]; then
  git -C "$FM_TEST_ADVANCE_BASE_REPO" update-ref refs/heads/main "$FM_TEST_ADVANCE_BASE_SHA"
  : > "$FM_TEST_ADVANCE_BASE_MARKER"
fi
report=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --report-path) report=${2:-}; shift ;;
    --report-path=*) report=${1#*=} ;;
  esac
  shift
done
[ -n "$report" ] || exit 2
if grep -Rqs 'FM_TEST_NEW_SECRET' . --exclude-dir=.git; then
  printf '[{"RuleID":"generic-api-key","File":"secret.txt","StartLine":1,"Description":"potential secret","Line":"FM_TEST_NEW_SECRET"}]\n' > "$report"
  exit 1
else
  printf '[]\n' > "$report"
fi
exit 0
SH
chmod +x "$FM_SCANNER_DIR/bin/gitleaks"
cat > "$FM_SCANNER_DIR/bin/oxlint" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then printf 'oxlint 1.75.0\n'; exit 0; fi
printf '{"runs":[]}\n'
SH
chmod +x "$FM_SCANNER_DIR/bin/oxlint"
cat > "$FM_SCANNER_DIR/bin/eslint-scanner" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then printf '9.39.5\n'; exit 0; fi
printf '['
comma=""
for file in "$@"; do
  [ -f "$file" ] && grep -q FM_TEST_SECURITY_NOISE "$file" || continue
  printf '%s' "$comma"
  jq -nc --arg path "$PWD/$file" '{
    filePath:$path,
    messages:[{
      ruleId:"security/detect-object-injection",severity:2,line:1,
      message:"high-noise security heuristic"
    }]
  }'
  comma=","
done
printf ']\n'
SH
chmod +x "$FM_SCANNER_DIR/bin/eslint-scanner"
cat > "$FM_SCANNER_DIR/bin/claude" <<'SH'
#!/usr/bin/env bash
set -u
prompt=$(mktemp)
sed -n '2,$p' | sed '$d' > "$prompt"
jq '{
  structured_output:{
    results:[
      .untrusted_clusters[].findings[] |
      if .scanner=="osv-scanner" then
        {
          fingerprint,verdict:"demote-to-report",reason_code:"dev-only-package",
          reason:"The candidate lockfile independently proves this package is dev-only.",
          evidence:{source:"hunk",quote:"\"dev\":true"}
        }
      else
        {fingerprint,verdict:"confirm",reason_code:null,reason:null,evidence:null}
      end
    ]
  }
}' "$prompt"
rm -f "$prompt"
SH
chmod +x "$FM_SCANNER_DIR/bin/claude"
FM_SCANNER_ADJUDICATOR_CLI="$FM_SCANNER_DIR/bin/claude"
FM_SCANNER_ADJUDICATOR_AUDIT_SEED=verify-fixture
export FM_SCANNER_ADJUDICATOR_CLI FM_SCANNER_ADJUDICATOR_AUDIT_SEED
cat > "$FM_SCANNER_DIR/bin/osv-scanner" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then printf 'osv-scanner version: 2.4.0\n'; exit 0; fi
if [ -f package-lock.json ] && grep -q FM_TEST_DEV_OSV package-lock.json; then
  jq -nc '{
    results:[{
      source:{path:"package-lock.json",type:"lockfile"},
      packages:[{
        package:{name:"dev-vuln",version:"1.0.0",ecosystem:"npm"},
        vulnerabilities:[{id:"GHSA-DEV-TEST"}]
      }]
    }]
  }'
else
  printf '{"results":[]}\n'
fi
SH
chmod +x "$FM_SCANNER_DIR/bin/osv-scanner"
cat > "$FM_SCANNER_DIR/bin/actionlint" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then printf '1.7.12\n'; exit 0; fi
printf '[]\n'
SH
chmod +x "$FM_SCANNER_DIR/bin/actionlint"
cat > "$FM_SCANNER_DIR/bin/ast-grep" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then printf 'ast-grep 0.45.0\n'; exit 0; fi
printf '[]\n'
SH
chmod +x "$FM_SCANNER_DIR/bin/ast-grep"
ln -s "$(command -v jq)" "$FM_SCANNER_DIR/bin/jq"
cat > "$FM_SCANNER_DIR/bin/json-schema-scanner" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then printf 'ajv 8.17.1\n'; exit 0; fi
printf '[]\n'
SH
chmod +x "$FM_SCANNER_DIR/bin/json-schema-scanner"
cat > "$FM_SCANNER_DIR/bin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
printf '[]\n'
SH
chmod +x "$FM_SCANNER_DIR/bin/shellcheck"
cat > "$FM_SCANNER_DIR/bin/ruff" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then printf 'ruff 0.16.0\n'; exit 0; fi
printf '{"runs":[]}\n'
SH
chmod +x "$FM_SCANNER_DIR/bin/ruff"
mkdir -p "$FM_SCANNER_DIR/osv-db/osv-scanner"
printf '%s\n' \
  '{"schema":"firstmate/scanner-tools-ready/1","status":"ready","versions":{"actionlint":"1.7.12","ajv":"8.17.1","ast-grep":"0.45.0","eslint":"9.39.5","eslint-plugin-n":"18.2.2","eslint-plugin-security":"4.0.1","eslint-plugin-sonarjs":"4.2.0","gitleaks":"8.30.1","jq":"1.7.1","osv-scanner":"2.4.0","oxlint":"1.75.0","ruff":"0.16.0","shellcheck":"0.11.0"}}' \
  > "$FM_SCANNER_DIR/tools-ready.json"
printf '%s\n' '{"schema":"firstmate/scanner-provisioned/1","status":"ready"}' \
  > "$FM_SCANNER_DIR/provisioned.json"

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

# --- scanner adoption: visible note before provisioning, no silent skip -------
RUNADOPTED=$(build_repo scanner-not-adopted)
echo feat >> "$RUNADOPTED/f.txt"; git -C "$RUNADOPTED" commit -qam feature
UNADOPTED_SHA=$(git -C "$RUNADOPTED" rev-parse HEAD)
rc=$(FM_SCANNER_DIR="$TMP/not-provisioned" verify "$TMP/scanner-not-adopted.json" \
  --worktree "$RUNADOPTED" --base main --sha "$UNADOPTED_SHA" --branch fm/g1 --task g1)
expect_code 0 "$rc" "scanner gate is non-blocking before explicit adoption"
[ "$(bget "$TMP/scanner-not-adopted.json" '.gates[]|select(.gate=="scanner")|.details.adopted')" = false ] ||
  fail "unprovisioned scanner gate must record adopted=false"
[ "$(bget "$TMP/scanner-not-adopted.json" '[.findings[]|select(.gate=="scanner" and .code=="gate-not-adopted" and .severity=="note")]|length')" = 1 ] ||
  fail "unprovisioned scanner gate must emit exactly one visible gate-not-adopted note"
pass "scanner adoption: an unprovisioned environment passes with one visible note"

# Explicit adoption retains fail-closed behavior for a missing pinned scanner.
mkdir -p "$TMP/adopted-config"
printf 'enabled\n' > "$TMP/adopted-config/scanner-gate"
mkdir -p "$TMP/ambient-bin"
cat > "$TMP/ambient-bin/gitleaks" <<'SH'
#!/usr/bin/env bash
printf 'ambient gitleaks must not run\n' >> "$AMBIENT_GITLEAKS_MARKER"
if [ "${1:-}" = "--version" ]; then printf 'gitleaks version 8.30.1\n'; exit 0; fi
exit 0
SH
chmod +x "$TMP/ambient-bin/gitleaks"
AMBIENT_GITLEAKS_MARKER="$TMP/ambient-gitleaks-ran"
export AMBIENT_GITLEAKS_MARKER
mv "$FM_SCANNER_DIR/bin/gitleaks" "$FM_SCANNER_DIR/bin/gitleaks.missing"
rc=$(PATH="$TMP/ambient-bin:$PATH" FM_CONFIG_OVERRIDE="$TMP/adopted-config" \
  verify "$TMP/scanner-adopted-missing.json" \
  --worktree "$RUNADOPTED" --base main --sha "$UNADOPTED_SHA" --branch fm/g1 --task g1)
mv "$FM_SCANNER_DIR/bin/gitleaks.missing" "$FM_SCANNER_DIR/bin/gitleaks"
expect_code 1 "$rc" "explicitly adopted scanner gate fails closed on a missing scanner"
[ "$(bget "$TMP/scanner-adopted-missing.json" '.gates[]|select(.gate=="scanner")|.details.adopted')" = true ] ||
  fail "explicit scanner config must record adopted=true"
[ "$(bget "$TMP/scanner-adopted-missing.json" '[.findings[]|select(.gate=="scanner" and .code=="gitleaks/scanner-unavailable")]|length')" = 1 ] ||
  fail "an adopted missing scanner must produce one loud scanner-unavailable finding"
[ ! -e "$AMBIENT_GITLEAKS_MARKER" ] ||
  fail "an ambient matching-version gitleaks replaced the missing pinned executable"
pass "scanner adoption: a missing pin fails closed and never falls back to ambient PATH"

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

# --- scanner integration: synthetic diff finding reaches the verifier gate ----
RSCAN=$(build_repo scanner-integration)
printf 'FM_TEST_NEW_SECRET\n' > "$RSCAN/secret.txt"
git -C "$RSCAN" add secret.txt
git -C "$RSCAN" commit -qm "add synthetic secret"
SCANSHA=$(git -C "$RSCAN" rev-parse HEAD)
rc=$(verify "$TMP/scanner-integration.json" --worktree "$RSCAN" --base main \
  --sha "$SCANSHA" --branch fm/g1 --task g1)
expect_code 1 "$rc" "scanner finding fails integrated verifier"
[ "$(bget "$TMP/scanner-integration.json" '.gates[]|select(.gate=="scanner")|.status')" = fail ] ||
  fail "scanner gate did not fail on the synthetic candidate finding"
[ "$(bget "$TMP/scanner-integration.json" '.findings[]|select(.gate=="scanner" and .code=="gitleaks/generic-api-key")|.code')" = gitleaks/generic-api-key ] ||
  fail "normalized scanner finding did not reach the top-level verifier findings"
pass "scanner gate integration: a synthetic candidate diff blocks fm-verify"

# --- adjudication integration: independently proven noise is demoted ----------
RADJ=$(build_repo adjudication-integration)
printf '{"marker":"FM_TEST_DEV_OSV","packages":{"node_modules/dev-vuln":{"dev":true}}}\n' > "$RADJ/package-lock.json"
git -C "$RADJ" add package-lock.json
git -C "$RADJ" commit -qm "add synthetic dev advisory"
ADJSHA=$(git -C "$RADJ" rev-parse HEAD)
rc=$(verify "$TMP/adjudication-integration.json" --worktree "$RADJ" --base main \
  --sha "$ADJSHA" --branch fm/g1 --task g1)
expect_code 0 "$rc" "independently proven noisy finding is demoted without hiding its bundle record"
jq -e '
  .gates[]|select(.gate=="scanner")|.details
  | .adjudication.schema=="firstmate/scanner-adjudication/2"
  and .adjudication.submitted_count==1
  and .adjudication.adjudicated_count==1
  and .adjudication.demoted_count==1
  and (.adjudication.model_prompt_fingerprint|test("^[0-9a-f]{64}$"))
  and .adjudication.cost_estimate_usd>0
  and (.adjudication.demotions[0].reason_code=="dev-only-package")
  and (.adjudication.demotions[0].corroboration.kind=="candidate-package-lock-dev-scope")
  and (.adjudication.demotions[0].corroboration.proof_id|test("^[0-9a-f]{64}$"))
  and (.adjudication.demotions[0].corroboration.subject.name=="dev-vuln")
  and (.adjudication.demotions[0].corroboration.subject.advisory_id=="GHSA-DEV-TEST")
  and (.adjudication.demotions[0].audit_sampled)
  and ([.findings[]|select(
    .rule_id=="dev-dependency/GHSA-DEV-TEST"
    and .policy_decision=="report-only"
    and (.blocking|not)
  )]|length)==1
' "$TMP/adjudication-integration.json" >/dev/null ||
  fail "verifier bundle omitted adjudication counts, reasons, fingerprint, cost, or audit marker"
pass "scanner adjudication bundle records independent proofs, reasons, fingerprint, cost, and audit sample"

# --- baseline freshness: scanner stays pinned and final publication rechecks ---
RBASE=$(build_repo base-advances-during-scan)
echo feat >> "$RBASE/f.txt"; git -C "$RBASE" commit -qam feature
BASE_CANDIDATE_SHA=$(git -C "$RBASE" rev-parse HEAD)
ORIGINAL_BASE_SHA=$(git -C "$RBASE" rev-parse main)
ORIGINAL_BASE_TREE=$(git -C "$RBASE" rev-parse 'main^{tree}')
ADVANCED_BASE_SHA=$(printf 'advance base during scanner\n' |
  git -C "$RBASE" commit-tree "$ORIGINAL_BASE_TREE" -p "$ORIGINAL_BASE_SHA")
FM_TEST_ADVANCE_BASE_REPO="$RBASE"
FM_TEST_ADVANCE_BASE_SHA="$ADVANCED_BASE_SHA"
FM_TEST_ADVANCE_BASE_MARKER="$TMP/base-advanced"
export FM_TEST_ADVANCE_BASE_REPO FM_TEST_ADVANCE_BASE_SHA FM_TEST_ADVANCE_BASE_MARKER
rc=$(verify "$TMP/base-advances.json" --worktree "$RBASE" --base main \
  --sha "$BASE_CANDIDATE_SHA" --branch fm/g1 --task g1)
unset FM_TEST_ADVANCE_BASE_REPO FM_TEST_ADVANCE_BASE_SHA FM_TEST_ADVANCE_BASE_MARKER
expect_code 1 "$rc" "a base advance during scanning invalidates the verifier pass"
[ "$(bget "$TMP/base-advances.json" '.gates[]|select(.gate=="revalidation")|.status')" = fail ] ||
  fail "final revalidation did not fail after the authoritative base advanced"
[ "$(bget "$TMP/base-advances.json" '.gates[]|select(.gate=="scanner")|.details.baseline_matches_base_currency')" = true ] ||
  fail "scanner baseline was not bound to the exact base_currency SHA"
[ "$(bget "$TMP/base-advances.json" '.gates[]|select(.gate=="scanner")|.details.baseline_sha')" = "$ORIGINAL_BASE_SHA" ] ||
  fail "scanner report did not retain the exact pre-advance base SHA"
pass "baseline freshness: scanner/base_currency SHAs match and a later base advance blocks publication"

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
[ -z "${FM_TEST_NPM_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_TEST_NPM_LOG"
if [ "${1:-}" = config ] && [ "${2:-}" = get ] && [ "${3:-}" = cache ]; then
  [ "${FM_TEST_NPM_CONFIG_MODE:-}" != hang ] || { sleep 30; exit 91; }
  [ -n "${FM_TEST_NPM_CACHE:-}" ] || exit 91
  printf '%s\n' "$FM_TEST_NPM_CACHE"
  exit 0
fi
if [ "${1:-}" = ci ] && [ "${FM_TEST_NPM_MODE:-fail}" = success ]; then
  mkdir -p memory/node_modules/fixture-dep
  cat > memory/node_modules/fixture-dep/package.json <<'JSON'
{"name":"fixture-dep","version":"1.0.0","type":"module","exports":"./index.mjs"}
JSON
  printf 'export default "ready";\n' > memory/node_modules/fixture-dep/index.mjs
  exit 0
fi
exit 91
EOF
chmod +x "$FAKEBIN/npm"

NPM_CACHE="$TMP/npm-cache"
mkdir -p "$NPM_CACHE"

RMD=$(build_memory_repo memory-deps-green)
MDSHA=$(git -C "$RMD" rev-parse HEAD)
GREEN_NPM_LOG="$TMP/memdeps-green-npm.log"
FM_TEST_NPM_MODE=success FM_TEST_NPM_CACHE="$NPM_CACHE" FM_TEST_NPM_LOG="$GREEN_NPM_LOG" \
  PATH="$FAKEBIN:$PATH" FM_HOME="$TMP/nohome" "$VERIFY" \
  --out "$TMP/memdeps-copy.json" --brief "$BRIEF" \
  --worktree "$RMD" --base main --sha "$MDSHA" --branch fm/g1 --task g1 >/dev/null 2>&1
expect_code 0 "$?" "npm ci provisions the isolated memory fixture"
[ "$(bget "$TMP/memdeps-copy.json" '.gates[]|select(.gate=="tests")|.details.dependency_provisioner')" = npm-ci ] \
  || fail "npm ci must be the only memory dependency provisioner"
[ "$(sed -n '1p' "$GREEN_NPM_LOG")" = "config get cache" ] \
  || fail "provisioning must resolve the invoking npm cache"
[ "$(sed -n '2p' "$GREEN_NPM_LOG")" = "ci --prefix memory --silent --prefer-offline --cache $NPM_CACHE" ] \
  || fail "provisioning must run npm ci with the invoking cache and --prefer-offline"
pass "FC-001: bounded npm ci positively provisions a mem-dependent sandbox fixture"

RHC=$(build_memory_repo memory-deps-cache-hang)
HCSHA=$(git -C "$RHC" rev-parse HEAD)
HANG_CACHE_LOG="$TMP/memdeps-cache-hang-npm.log"
start=$SECONDS
FM_VERIFY_TEST_TIMEOUT=1 FM_TEST_NPM_CONFIG_MODE=hang FM_TEST_NPM_LOG="$HANG_CACHE_LOG" \
  PATH="$FAKEBIN:$PATH" FM_HOME="$TMP/nohome" "$VERIFY" \
  --out "$TMP/memdeps-cache-hang.json" --brief "$BRIEF" \
  --worktree "$RHC" --base main --sha "$HCSHA" --branch fm/g1 --task g1 >/dev/null 2>&1
rc=$?
elapsed=$((SECONDS - start))
expect_code 1 "$rc" "hung npm cache lookup falls back to bounded npm ci failure"
[ "$elapsed" -lt 10 ] || fail "npm cache lookup escaped its short deadline (${elapsed}s)"
[ "$(bget "$TMP/memdeps-cache-hang.json" .finding_count)" = 1 ] \
  || fail "hung npm cache lookup plus failed npm ci must yield exactly one finding"
[ "$(bget "$TMP/memdeps-cache-hang.json" '.findings[0]|(.gate + "/" + .code)')" = tests/deps-unprovisioned ] \
  || fail "hung npm cache lookup plus failed npm ci must yield tests/deps-unprovisioned"
[ "$(sed -n '2p' "$HANG_CACHE_LOG")" = "ci --prefix memory --silent --prefer-offline" ] \
  || fail "failed cache lookup must fall back to npm ci without a --cache argument"
pass "FC-006: npm cache lookup is bounded and failure falls back without a cache argument"

mkdir -p "$TMP/poison-root" "$TMP/poison-home" "$TMP/poison-state"
FM_ROOT_OVERRIDE="$TMP/poison-root" FM_HOME="$TMP/poison-home" \
  FM_STATE_OVERRIDE="$TMP/poison-state" FM_FAILURE_LEDGER="$LEDGER" \
  FM_TEST_NPM_MODE=success FM_TEST_NPM_CACHE="$NPM_CACHE" PATH="$FAKEBIN:$PATH" "$VERIFY" \
  --out "$TMP/memdeps-env.json" --brief "$BRIEF" \
  --worktree "$RMD" --base main --sha "$MDSHA" --branch fm/g1 --task g1 >/dev/null 2>&1
expect_code 0 "$?" "poisoned ambient home overrides are scrubbed from sandbox suites"
[ "$(bget "$TMP/memdeps-env.json" '.gates[]|select(.gate=="tests")|.status')" = pass ] \
  || fail "poisoned ambient home overrides must not reach the mem-dependent fixture"
pass "FC-004: poisoned ambient home overrides are scrubbed from sandbox suite execution"

RME=$(build_memory_repo memory-deps-empty)
mkdir -p "$RME/memory/node_modules"
MESHA=$(git -C "$RME" rev-parse HEAD)
EMPTY_NPM_LOG="$TMP/memdeps-empty-npm.log"
FM_TEST_NPM_LOG="$EMPTY_NPM_LOG" FM_TEST_NPM_CACHE="$NPM_CACHE" \
  PATH="$FAKEBIN:$PATH" FM_HOME="$TMP/nohome" "$VERIFY" \
  --out "$TMP/memdeps-empty.json" --brief "$BRIEF" \
  --worktree "$RME" --base main --sha "$MESHA" --branch fm/g1 --task g1 >/dev/null 2>&1
expect_code 1 "$?" "empty source node_modules fails closed when npm ci also fails"
[ "$(bget "$TMP/memdeps-empty.json" .finding_count)" = 1 ] \
  || fail "empty source node_modules must yield exactly one finding"
[ "$(bget "$TMP/memdeps-empty.json" '.findings[0]|(.gate + "/" + .code)')" = tests/deps-unprovisioned ] \
  || fail "empty source node_modules must yield tests/deps-unprovisioned"
[ "$(bget "$TMP/memdeps-empty.json" '.gates[]|select(.gate=="tests")|.details.suites_executed')" = 0 ] \
  || fail "empty source node_modules must stop suite fan-out"
[ "$(sed -n '2p' "$EMPTY_NPM_LOG")" = "ci --prefix memory --silent --prefer-offline --cache $NPM_CACHE" ] \
  || fail "empty source node_modules must be ignored in favor of npm ci"
pass "FC-001: empty source dependencies are ignored and failed npm ci stays fail closed"

RML=$(build_memory_repo memory-deps-lock-divergent)
mkdir -p "$RML/memory/node_modules/fixture-dep"
cat > "$RML/memory/node_modules/fixture-dep/package.json" <<'EOF'
{"name":"fixture-dep","version":"1.1.0","type":"module","exports":"./index.mjs"}
EOF
printf 'export default "wrong-source-version";\n' > "$RML/memory/node_modules/fixture-dep/index.mjs"
MLSHA=$(git -C "$RML" rev-parse HEAD)
LOCK_NPM_LOG="$TMP/memdeps-lock-npm.log"
FM_TEST_NPM_MODE=success FM_TEST_NPM_CACHE="$NPM_CACHE" FM_TEST_NPM_LOG="$LOCK_NPM_LOG" \
  PATH="$FAKEBIN:$PATH" FM_HOME="$TMP/nohome" "$VERIFY" \
  --out "$TMP/memdeps-lock.json" --brief "$BRIEF" \
  --worktree "$RML" --base main --sha "$MLSHA" --branch fm/g1 --task g1 >/dev/null 2>&1
expect_code 0 "$?" "lock-divergent source node_modules is ignored and npm ci provisions green"
[ "$(bget "$TMP/memdeps-lock.json" '.gates[]|select(.gate=="tests")|.details.dependency_provisioner')" = npm-ci ] \
  || fail "lock-divergent source dependencies must not create another provisioner"
[ "$(sed -n '2p' "$LOCK_NPM_LOG")" = "ci --prefix memory --silent --prefer-offline --cache $NPM_CACHE" ] \
  || fail "lock-divergent source dependencies must be ignored in favor of npm ci"
pass "FC-001: lock-divergent source dependencies cannot bypass npm ci"

RMF=$(build_memory_repo memory-deps-fail)
MFSHA=$(git -C "$RMF" rev-parse HEAD)
FM_TEST_NPM_CACHE="$NPM_CACHE" PATH="$FAKEBIN:$PATH" FM_HOME="$TMP/nohome" "$VERIFY" \
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

# --- adjudicator timeout: committed default, strict operator override ----------
jq -e '
  .limits.timeout_s
  | type == "number" and . >= 1 and . == floor
' "$ROOT/docs/scanner/adjudicator-policy.json" >/dev/null ||
  fail "committed adjudicator timeout default must be a positive integer"
env -u FM_SCANNER_ADJUDICATOR_TIMEOUT \
  FM_HOME="$TMP/nohome" FM_SCANNER_DIR="$TMP/not-provisioned" "$VERIFY" \
  --out "$TMP/adjudicator-timeout-default.json" --brief "$BRIEF" \
  --worktree "$R" --base main --sha "$SHA" --branch fm/g1 --task g1 >/dev/null 2>&1
expect_code 0 "$?" "unset adjudicator timeout reaches and passes the verifier gates"
[ "$(bget "$TMP/adjudicator-timeout-default.json" .verdict)" = pass ] ||
  fail "unset adjudicator timeout did not reach an authoritative verifier verdict"
FM_SCANNER_ADJUDICATOR_TIMEOUT=invalid \
  FM_HOME="$TMP/nohome" FM_SCANNER_DIR="$TMP/not-provisioned" "$VERIFY" \
  --out "$TMP/adjudicator-timeout-invalid.json" --brief "$BRIEF" \
  --worktree "$R" --base main --sha "$SHA" --branch fm/g1 --task g1 >/dev/null 2>&1
expect_code 2 "$?" "invalid adjudicator timeout override refuses"
pass "adjudicator timeout: unset uses a positive committed default; invalid override refuses"

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

# --- F8: fleet-bridge suite summaries are a closed assertion grammar ---------
RFS=$(build_repo fleet-suite-summary)
echo feat >> "$RFS/f.txt"
git -C "$RFS" commit -qam "fleet suite summary fixture"
FSSHA=$(git -C "$RFS" rev-parse HEAD)
rc=$(verify "$TMP/fleet-suite-pass.json" \
  --worktree "$RFS" --base main --sha "$FSSHA" --branch fm/g1 --task g1 \
  --tests-cmd "printf '%s\\n' 'SUITE PASS — 114 passed, 0 skipped, 0 failed'")
expect_code 0 "$rc" "fleet-bridge SUITE PASS exits 0"
[ "$(bget "$TMP/fleet-suite-pass.json" '.gates[]|select(.gate=="tests")|.details.totals.ok')" = 114 ] ||
  fail "fleet-bridge SUITE PASS count was not parsed as passing assertions"
[ "$(bget "$TMP/fleet-suite-pass.json" '[.findings[]|select(.code=="no-assertions")]|length')" = 0 ] ||
  fail "recognized fleet-bridge SUITE PASS retained the false no-assertions finding"

rc=$(verify "$TMP/fleet-suite-fail.json" \
  --worktree "$RFS" --base main --sha "$FSSHA" --branch fm/g1 --task g1 \
  --tests-cmd "printf '%s\\n' 'SUITE FAIL - 113 passed, 0 skipped, 1 failed'")
expect_code 1 "$rc" "fleet-bridge SUITE FAIL exits 1 even when the command exits 0"
[ "$(bget "$TMP/fleet-suite-fail.json" '.gates[]|select(.gate=="tests")|.details.totals.not_ok')" = 1 ] ||
  fail "fleet-bridge SUITE FAIL count was not parsed as a failing assertion"
[ "$(bget "$TMP/fleet-suite-fail.json" '[.findings[]|select(.code=="assertions-failed")]|length')" = 1 ] ||
  fail "fleet-bridge SUITE FAIL did not produce the assertions-failed finding"

rc=$(verify "$TMP/fleet-suite-unknown.json" \
  --worktree "$RFS" --base main --sha "$FSSHA" --branch fm/g1 --task g1 \
  --tests-cmd "printf '%s\\n' 'PASS some-file.mjs' 'SUITE PASS — many passed, 0 skipped, 0 failed'")
expect_code 1 "$rc" "unknown suite-summary format remains unproved"
[ "$(bget "$TMP/fleet-suite-unknown.json" '[.findings[]|select(.code=="no-assertions")]|length')" = 1 ] ||
  fail "unknown suite-summary format bypassed the no-assertions finding"
pass "F8: fleet-bridge SUITE PASS/FAIL counts are closed-recognized and unknown formats fail closed"

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
# One added line per class the production ledger gives a detection tripwire for:
# FC-004/006/007 carry their detection inline on the class-defined event; FC-001/002/005
# carry theirs on an appended `class-amended` event, so this fixture also proves the
# verifier folds class-amended detection at read. FC-003 has no ledger detection and
# must therefore stay advisory-only, not linted, no matter what the diff contains.
RCu=$(build_repo cues)
cat > "$RCu/script.sh" <<'EOF'
command -v gtimeout || true
curl https://example.com/data || true
rm -f /tmp/attest 2>/dev/null || true
  "additionalProperties": true,
  if (count == items.length) { accounted = 1; }
  mv "$tmp1" "$dst1" && mv "$tmp2" "$dst2"
EOF
git -C "$RCu" add -A; git -C "$RCu" commit -qam cues
USHA=$(git -C "$RCu" rev-parse HEAD)
rc=$(verify "$TMP/cues.json" --worktree "$RCu" --base main --sha "$USHA" --branch fm/g1 --task g1)
expect_code 1 "$rc" "cue hits exit 1"
[ "$(bget "$TMP/cues.json" '[.findings[]|select(.gate=="cue_lint")|.code]|sort|unique|join(",")')" = "FC-001,FC-002,FC-004,FC-005,FC-006,FC-007" ] || fail "the production ledger must drive every class it gives a detection - inline (FC-004/006/007) AND class-amended (FC-001/002/005)"
[ "$(bget "$TMP/cues.json" '[.gates[]|select(.gate=="cue_lint")|.details.detections[].source]|unique|join(",")')" = ledger ] || fail "every detection source must be the live ledger (no builtin)"
[ "$(bget "$TMP/cues.json" '.gates[]|select(.gate=="cue_lint")|.details.ledger')" = "$LEDGER" ] || fail "cue_lint must record the live ledger path it read"
# FC-003 carries no ledger detection, so it must be reported advisory-only and NEVER linted,
# even though the diff above contains per-field-equality conditionals it could over-match.
[ "$(bget "$TMP/cues.json" '.gates[]|select(.gate=="cue_lint")|.details.advisory_only|index("FC-003")|type')" = number ] || fail "FC-003 (no ledger detection) must be advisory-only, not mechanically linted"
[ "$(bget "$TMP/cues.json" '[.findings[]|select(.gate=="cue_lint")|.code]|index("FC-003")|type')" = null ] || fail "FC-003 must never produce a mechanical cue finding while the ledger gives it no detection"
pass "F5: inline AND class-amended detections are read live from the production ledger; a detection-less class stays advisory"

# --- F5: editing the ledger authority alone changes the lint ------------------
STRIPPED="$TMP/ledger-no-fc007.jsonl"
jq -c 'if .id=="FC-007" then del(.detection) else . end' "$LEDGER" > "$STRIPPED"
FM_HOME="$TMP/nohome" FM_FAILURE_LEDGER="$STRIPPED" "$VERIFY" --out "$TMP/cues2.json" --brief "$BRIEF" \
  --worktree "$RCu" --base main --sha "$USHA" --branch fm/g1 --task g1 >/dev/null 2>&1
[ "$(bget "$TMP/cues2.json" '[.findings[]|select(.gate=="cue_lint")|.code]|sort|unique|join(",")')" = "FC-001,FC-002,FC-004,FC-005,FC-006" ] || fail "removing FC-007's detection from the ledger must stop FC-007 linting while the other classes keep theirs"
[ "$(bget "$TMP/cues2.json" '.gates[]|select(.gate=="cue_lint")|.details.advisory_only|index("FC-007")|type')" = number ] || fail "FC-007 must fall to advisory-only when the ledger drops its detection"
pass "F5: lint behavior changes from the ledger authority alone (strip FC-007 detection => not linted)"

# --- FC-004: a MALFORMED ledger fails the cue lint CLOSED, never a silent pass ----
# The ledger is the cue-lint authority (qa-scg1-q168 F1). Before this, "readable" was a file
# check plus a substring grep, and error-suppressed jq streams meant invalid JSON before a
# valid class row silently emptied the lint while the gate stayed pass. The whole ledger is
# now folded once up front and must fail closed. Malformed JSON both BEFORE and AFTER a valid
# class row must still produce one loud finding, not a silent all-clear.
CORRUPT="$TMP/ledger-corrupt.jsonl"
{ printf '{broken-json\n'; grep '"event":"class-defined"' "$LEDGER" | head -1; printf '}also-broken\n'; } > "$CORRUPT"
FM_HOME="$TMP/nohome" FM_FAILURE_LEDGER="$CORRUPT" "$VERIFY" --out "$TMP/cues3.json" --brief "$BRIEF" \
  --worktree "$RCu" --base main --sha "$USHA" --branch fm/g1 --task g1 >/dev/null 2>&1
expect_code 1 "$?" "a malformed ledger fails the verifier closed (never exit 0)"
[ "$(bget "$TMP/cues3.json" '.gates[]|select(.gate=="cue_lint")|.status')" = fail ] || fail "cue_lint must fail closed on an unparseable ledger, never report pass"
[ "$(bget "$TMP/cues3.json" '[.findings[]|select(.gate=="cue_lint" and .code=="ledger-unreadable")]|length')" -ge 1 ] || fail "a malformed ledger must emit one loud ledger-unreadable finding"
[ "$(bget "$TMP/cues3.json" '[.findings[]|select(.gate=="cue_lint" and .severity=="finding")]|length')" = 0 ] || fail "a malformed ledger must not silently emit mechanical cue findings off a half-parsed authority"
pass "F5/FC-004: a malformed ledger fails the cue lint closed with a loud finding, never a silent pass"

# --- FC-001/FC-004: the live reader proves the SAME closed cue-row schema the writer does ----
# (qa-scg1r2-q173) A parse-VALID ledger can still carry a detection row that is invalid on the
# read path: an unsupported engine (silently skipped -> advisory -> pass, F2) or a syntactically
# invalid ERE (crashes awk in an unchecked process substitution -> empty hit stream -> pass, F1).
# Both are hand-injected class-amended rows the sanctioned writer would now refuse, exercising
# corruption on the live read side. Each must fail the cue lint CLOSED with one loud finding.
# F1 - an invalid awk-ere pattern must not become a silent empty-hit pass:
BADERE="$TMP/ledger-bad-ere.jsonl"; cp "$LEDGER" "$BADERE"
printf '{"schema":"kraken-failure-class/ledger-event/v1","event":"class-amended","id":"FC-001","detection":[{"engine":"awk-ere","pattern":"[","cue_ref":"invalid ERE"}]}\n' >> "$BADERE"
FM_HOME="$TMP/nohome" FM_FAILURE_LEDGER="$BADERE" "$VERIFY" --out "$TMP/badere.json" --brief "$BRIEF" \
  --worktree "$RCu" --base main --sha "$USHA" --branch fm/g1 --task g1 >/dev/null 2>&1
expect_code 1 "$?" "an invalid ERE in the ledger fails the verifier closed"
[ "$(bget "$TMP/badere.json" '.gates[]|select(.gate=="cue_lint")|.status')" = fail ] || fail "an invalid ERE must fail the cue_lint gate closed, never a silent empty-hit pass"
[ "$(bget "$TMP/badere.json" '[.findings[]|select(.gate=="cue_lint" and .severity=="fail")]|length')" -ge 1 ] || fail "an invalid ERE must emit a loud fail-closed cue-lint finding"
pass "F1: an invalid awk-ere pattern fails the cue lint closed, never a silent empty-hit pass"
# F2 - an unsupported engine on the LIVE read path must fail closed, not downgrade to advisory:
BADENG="$TMP/ledger-bad-engine.jsonl"; cp "$LEDGER" "$BADENG"
printf '{"schema":"kraken-failure-class/ledger-event/v1","event":"class-amended","id":"FC-001","detection":[{"engine":"regex-pcre","pattern":"feature","cue_ref":"unsupported"}]}\n' >> "$BADENG"
FM_HOME="$TMP/nohome" FM_FAILURE_LEDGER="$BADENG" "$VERIFY" --out "$TMP/badeng.json" --brief "$BRIEF" \
  --worktree "$RCu" --base main --sha "$USHA" --branch fm/g1 --task g1 >/dev/null 2>&1
expect_code 1 "$?" "an unsupported engine on the read path fails the verifier closed"
[ "$(bget "$TMP/badeng.json" '.gates[]|select(.gate=="cue_lint")|.status')" = fail ] || fail "the live reader must fail closed on an unsupported engine, not downgrade the class to advisory and pass"
[ "$(bget "$TMP/badeng.json" '[.findings[]|select(.gate=="cue_lint" and .severity=="fail")]|length')" -ge 1 ] || fail "an unsupported engine must emit a loud fail-closed finding on the read path"
pass "F2: the live cue lint enforces the closed engine set on its read path (fail closed, one finding)"
# F3 (qa-scg1r3-q180) - an undeclared detection property (additionalProperties:false) must fail
# the LIVE read path closed, not be admitted and executed. A hand-injected class-amended row with
# a valid engine/pattern/cue_ref plus one unknown key exercises read-side corruption.
BADKEY="$TMP/ledger-bad-key.jsonl"; cp "$LEDGER" "$BADKEY"
printf '{"schema":"kraken-failure-class/ledger-event/v1","event":"class-amended","id":"FC-001","detection":[{"engine":"awk-ere","pattern":"feature","cue_ref":"extra","unexpected":true}]}\n' >> "$BADKEY"
FM_HOME="$TMP/nohome" FM_FAILURE_LEDGER="$BADKEY" "$VERIFY" --out "$TMP/badkey.json" --brief "$BRIEF" \
  --worktree "$RCu" --base main --sha "$USHA" --branch fm/g1 --task g1 >/dev/null 2>&1
expect_code 1 "$?" "an undeclared detection property fails the verifier closed"
[ "$(bget "$TMP/badkey.json" '.gates[]|select(.gate=="cue_lint")|.status')" = fail ] || fail "the live reader must fail closed on an undeclared detection property, not execute the row"
[ "$(bget "$TMP/badkey.json" '[.findings[]|select(.gate=="cue_lint" and .severity=="fail")]|length')" -ge 1 ] || fail "an undeclared detection property must emit a loud fail-closed finding on the read path"
pass "F3: the live cue lint enforces additionalProperties:false on its read path (fail closed, one finding)"

# --- R5: the binding ruling's READ-path matrix (data/seasoning-cues-g1/design-ruling.md sec 4) ----
# Every corruption class - proven by the single authority over RAW bytes before any fold - fails the
# cue lint CLOSED with a ledger-unreadable fail finding and NO hit. Duplicate members (jq cannot see
# them) are the kill shot; the engine is a hard prerequisite. Each fixture hand-injects exactly one
# mutation onto the committed ledger and asserts (verify rc=1, cue_lint fail, a fail finding, no hit).
if command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' 2>/dev/null; then
  read_fail_closed() { # <ledger-file> <label> [extra-env]
    local led=$1 label=$2 env=${3:-} rc
    # shellcheck disable=SC2086
    env $env FM_HOME="$TMP/nohome$RANDOM" FM_FAILURE_LEDGER="$led" "$VERIFY" --out "$TMP/rf.json" --brief "$BRIEF" \
      --worktree "$RCu" --base main --sha "$USHA" --branch fm/g1 --task g1 >/dev/null 2>&1
    rc=$?
    [ "$rc" = 1 ] || fail "$label: verify must exit 1 (got $rc)"
    [ "$(bget "$TMP/rf.json" '.gates[]|select(.gate=="cue_lint")|.status')" = fail ] || fail "$label: cue_lint must fail closed"
    [ "$(bget "$TMP/rf.json" '[.findings[]|select(.gate=="cue_lint" and .severity=="fail")]|length')" -ge 1 ] || fail "$label: must emit a fail-closed finding"
    [ "$(bget "$TMP/rf.json" '[.findings[]|select(.gate=="cue_lint" and .severity=="finding")]|length')" = 0 ] || fail "$label: must produce no hit off a refused authority"
    pass "$label"
  }
  inject() { cp "$LEDGER" "$1"; printf '%s\n' "$2" >> "$1"; }   # <dest> <extra-line>
  amline() { printf '{"schema":"kraken-failure-class/ledger-event/v1","event":"class-amended","id":"FC-001","detection":[%s]}' "$1"; }
  occ() { printf '{"schema":"kraken-failure-class/ledger-event/v1","event":"occurrence","id":"FC-001","provenance":{"type":"q","ref":"r"}}'; }
  # Duplicate detection members, ALL THREE members in BOTH orderings, on the live read path.
  L="$TMP/rd-dupe1.jsonl"; inject "$L" "$(amline '{"engine":"awk-ere","engine":"regex-pcre","pattern":"x","cue_ref":"c"}')"; read_fail_closed "$L" "R5 read: DUP engine (first-valid/last-invalid)"
  L="$TMP/rd-dupe2.jsonl"; inject "$L" "$(amline '{"engine":"regex-pcre","engine":"awk-ere","pattern":"x","cue_ref":"c"}')"; read_fail_closed "$L" "R5 read: DUP engine (first-invalid/last-valid)"
  L="$TMP/rd-dupp1.jsonl"; inject "$L" "$(amline '{"engine":"awk-ere","pattern":"feature","pattern":"[","cue_ref":"c"}')"; read_fail_closed "$L" "R5 read: DUP pattern (first-valid/last-invalid)"
  L="$TMP/rd-dupp2.jsonl"; inject "$L" "$(amline '{"engine":"awk-ere","pattern":"[","pattern":"feature","cue_ref":"c"}')"; read_fail_closed "$L" "R5 read: DUP pattern (first-invalid/last-valid)"
  L="$TMP/rd-dupc1.jsonl"; inject "$L" "$(amline '{"engine":"awk-ere","pattern":"a","cue_ref":"ok","cue_ref":""}')"; read_fail_closed "$L" "R5 read: DUP cue_ref (first-valid/last-invalid)"
  L="$TMP/rd-dupc2.jsonl"; inject "$L" "$(amline '{"engine":"awk-ere","pattern":"a","cue_ref":"","cue_ref":"ok"}')"; read_fail_closed "$L" "R5 read: DUP cue_ref (first-invalid/last-valid)"
  L="$TMP/rd-envdup.jsonl"; inject "$L" '{"schema":"kraken-failure-class/ledger-event/v1","event":"occurrence","id":"FC-001","id":"FC-002","provenance":{"type":"q","ref":"r"}}'; read_fail_closed "$L" "R5 read: DUP member on the ledger envelope"
  L="$TMP/rd-nestdup.jsonl"; inject "$L" '{"schema":"kraken-failure-class/ledger-event/v1","event":"occurrence","id":"FC-001","provenance":{"type":"q","ref":"r","ref":"r2"}}'; read_fail_closed "$L" "R5 read: DUP member nested in a value object"
  L="$TMP/rd-dupid.jsonl"; cp "$LEDGER" "$L"; grep '"event":"class-defined".*"id":"FC-001"' "$LEDGER" | head -1 >> "$L"; read_fail_closed "$L" "R5 read: duplicate class id"
  # Undeclared property nested in a value object (a new class-defined whose registry carries a rogue key).
  L="$TMP/rd-nestundecl.jsonl"; inject "$L" '{"schema":"kraken-failure-class/ledger-event/v1","event":"class-defined","id":"FC-099","name":"n","invariant":"i","cues":["c"],"fix":"f","provenance":[{"type":"qa","ref":"r"}],"registry":{"memory_type":"procedural","scope":"fleet","confidence":"guarded","keywords":["k"],"rogue":1}}'; read_fail_closed "$L" "R5 read: undeclared property nested in a value object"
  # Lexical / encoding fixtures.
  L="$TMP/rd-bom.jsonl"; printf '\xef\xbb\xbf' > "$L"; cat "$LEDGER" >> "$L"; read_fail_closed "$L" "R5 read: leading UTF-8 BOM"
  L="$TMP/rd-bomline.jsonl"; cp "$LEDGER" "$L"; printf '\xef\xbb\xbf%s\n' "$(occ)" >> "$L"; read_fail_closed "$L" "R5 read: BOM on a non-initial line"
  L="$TMP/rd-ctl.jsonl"; cp "$LEDGER" "$L"; printf '%s\x07\n' "$(occ)" >> "$L"; read_fail_closed "$L" "R5 read: control byte in a line"
  L="$TMP/rd-nul.jsonl"; cp "$LEDGER" "$L"; printf '%s\x00\n' "$(occ)" >> "$L"; read_fail_closed "$L" "R5 read: NUL byte in a line"
  L="$TMP/rd-trail.jsonl"; cp "$LEDGER" "$L"; printf '%s garbage\n' "$(occ)" >> "$L"; read_fail_closed "$L" "R5 read: trailing garbage after a valid object"
  L="$TMP/rd-emptyline.jsonl"; cp "$LEDGER" "$L"; printf '\n%s\n' "$(occ)" >> "$L"; read_fail_closed "$L" "R5 read: an empty line"
  L="$TMP/rd-wsline.jsonl"; cp "$LEDGER" "$L"; printf '   \n%s\n' "$(occ)" >> "$L"; read_fail_closed "$L" "R5 read: a whitespace-only line"
  L="$TMP/rd-malafter.jsonl"; cp "$LEDGER" "$L"; printf '{broken-json\n' >> "$L"; read_fail_closed "$L" "R5 read: malformed JSON AFTER a valid line (isolated)"
  read_fail_closed "$TMP/rd-missing-does-not-exist.jsonl" "R5 read: a MISSING ledger fails closed (distinct from empty)"
  # Both engines' GENUINE absence fails the read path closed - no injection hook. python3 absence runs
  # the verifier under a constrained PATH; jsonschema absence under a python that cannot import it.
  RNOPY=$(fm_test_path_without_python3 "$TMP/r-nopy")
  read_fail_closed "$LEDGER" "R5 read: python3 genuinely absent (constrained PATH) fails closed" "PATH=$RNOPY"
  RNOJS=$(fm_test_pythonpath_no_jsonschema "$TMP/r-nojs")
  read_fail_closed "$LEDGER" "R5 read: jsonschema genuinely unimportable fails closed" "PYTHONPATH=$RNOJS"
  # REGRESSION (qa-scg1r5-q185 F1): ambient FM_CUE_VALIDATOR / FM_CUE_SCHEMAS_DIR cannot substitute the
  # authority on the read path - a malformed ledger must STILL fail the cue lint closed.
  L="$TMP/rd-override.jsonl"; printf '{broken-json\n' > "$L"
  read_fail_closed "$L" "R5 read: ambient FM_CUE_VALIDATOR override cannot authorize a malformed ledger (F1)" "FM_CUE_VALIDATOR=true FM_CUE_SCHEMAS_DIR=/tmp"
  # An EMPTY-but-present ledger is valid-empty on the read path: no cues to lint, gate passes, no hit.
  EMPTYL="$TMP/rd-empty.jsonl"; : > "$EMPTYL"
  FM_HOME="$TMP/nohomeE" FM_FAILURE_LEDGER="$EMPTYL" "$VERIFY" --out "$TMP/rfe.json" --brief "$BRIEF" \
    --worktree "$RCu" --base main --sha "$USHA" --branch fm/g1 --task g1 >/dev/null 2>&1
  if [ "$(bget "$TMP/rfe.json" '.gates[]|select(.gate=="cue_lint")|.status')" = pass ]; then
    pass "R5 read: an empty-but-present ledger is valid-empty (cue_lint passes, no hit)"
  else
    fail "an empty-but-present ledger must be valid-empty on the read path"
  fi
else
  echo "SKIP fm-verify: python3+jsonschema absent - read-path matrix not exercised" >&2
fi

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

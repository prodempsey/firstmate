#!/usr/bin/env bash
# Memory PR-4 spawn-time injection + Compounding Fleet stage B dispatch recall.
# Three layers:
#   * the fm-memory-inject.sh wrapper contract (default ON, config/env disable,
#     fail-open, a portable spawn-safe deadline, real injection against a fixture),
#   * the fm-spawn.sh integration (recall runs on every ship/scout dispatch, injects
#     when the registry has relevant memory, stays inert when it does not, and NEVER
#     fails a spawn), reusing the govern-gate fakebin pattern, and
#   * the failure-class recall wiring: a dispatch whose brief text matches a failure
#     class's detection cues yields a bounded pack containing that class, cited.
# Every registry used here is an isolated fixture; the production registry is never
# read or written (MEM_REGISTRY_DIR is always pinned to a temp dir). tests/lib.sh
# pins FM_MEMORY_INJECT=0 suite-wide, so this suite must explicitly opt in: it either
# UNSETS it (env -u) to exercise the intrinsic default-on, or forces it on/off.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INJECT="$ROOT/bin/fm-memory-inject.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
MEMBIN="$ROOT/memory/bin/mem.mjs"
FAILCLASS="$ROOT/bin/fm-failure-class.sh"
TMP_ROOT=$(fm_test_tmproot fm-memory-inject)

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP fm-memory-inject: node not available" >&2
  exit 0
fi

# Seed an isolated fixture registry with active memories and a built FTS index,
# via the package's own test helper (distinct proposer/activator, fixtures only).
seed_registry() {  # <registry-dir>
  local reg=$1
  mkdir -p "$reg"
  node --input-type=module -e '
    import { seedActive } from "'"$ROOT"'/memory/test/helpers.mjs";
    import { buildRetrievalIndex } from "'"$ROOT"'/memory/lib/retrieval-index.mjs";
    const dir = process.argv[1];
    await seedActive(dir, [
      { id: "MEM-0001", summary: "stale watcher leaves idle done crew waiting", keywords: ["watcher","stale"], memoryType: "procedural", scope: "fleet", projects: ["*"], taskKinds: ["*"] },
      { id: "MEM-0002", summary: "worktree project mismatch on primary checkout", keywords: ["worktree","isolation"], memoryType: "factual", scope: "project", projects: ["firstmate"], taskKinds: ["ship"] }
    ]);
    await buildRetrievalIndex(dir);
  ' "$reg"
}

# Seed a fixture registry with real failure classes from the committed ledger,
# through the sanctioned register flow (mem propose | mem activate). This is the
# actual dispatch-recall corpus, not a synthetic stand-in.
seed_failure_classes() {  # <registry-dir> <FC-id>...
  local reg=$1; shift
  mkdir -p "$reg"
  local -a ids=()
  local fc; for fc in "$@"; do ids+=(--id "$fc"); done
  MEM_REGISTRY_DIR="$reg" "$FAILCLASS" register "${ids[@]}" --live --gate "test:cf-recall-b1" >/dev/null
}

FINAL_BRIEF=$'# Task\nFix the stale watcher and the worktree isolation problem.\n\n# Setup\ndetails\n'

# A brief whose # Task text matches failure class FC-004's detection cues (a
# validation check that fails open to success when a prerequisite tool is missing).
FC_BRIEF=$'# Task\nThe profile validator skips its duplicate-key check when python3 is missing, so a missing prerequisite tool makes it warn and fall open to success instead of refusing.\n\n# Setup\ndetails\n'

# --- wrapper: enablement gate -----------------------------------------------
test_wrapper_default_on_injects() {
  local d="$TMP_ROOT/def"; mkdir -p "$d/config"
  local brief="$d/brief.md"; printf '%s' "$FINAL_BRIEF" > "$brief"
  local reg="$d/registry"; seed_registry "$reg"
  local out status
  out=$(env -u FM_MEMORY_INJECT FM_HOME="$d" MEM_REGISTRY_DIR="$reg" "$INJECT" --task t1 --brief "$brief" --project firstmate --kind ship); status=$?
  expect_code 0 "$status" "wrapper must exit 0 on default-on injection"
  assert_grep '## Fleet memory' "$brief" "recall runs by DEFAULT (no env, no config): the pointer block must be injected"
  assert_grep 'MEM-0001' "$brief" "an active memory pointer must appear"
  assert_grep 'mem show MEM-0001' "$brief" "pointer must carry the show command (pointer-only)"
  assert_present "$d/memory-proof.json" "a spawn-time proof must be written"
  pass "wrapper injects by default: recall at every dispatch"
}

test_wrapper_config_disable_off() {
  local d="$TMP_ROOT/cd"; mkdir -p "$d/config"
  printf 'off\n' > "$d/config/memory-inject.enabled"   # the only way to opt a home out
  local brief="$d/brief.md"; printf '%s' "$FINAL_BRIEF" > "$brief"
  local reg="$d/registry"; seed_registry "$reg"
  local before; before=$(cat "$brief")
  env -u FM_MEMORY_INJECT FM_HOME="$d" MEM_REGISTRY_DIR="$reg" "$INJECT" --task t1 --brief "$brief" --project firstmate --kind ship >/dev/null
  [ "$(cat "$brief")" = "$before" ] || fail "a config disable token must force injection off"
  assert_absent "$d/memory-proof.json" "no proof is written when disabled by config"
  pass "config/memory-inject.enabled disable token forces injection off"
}

test_wrapper_env_disable_wins() {
  local d="$TMP_ROOT/ed"; mkdir -p "$d/config"
  printf 'on\n' > "$d/config/memory-inject.enabled"   # config says on...
  local brief="$d/brief.md"; printf '%s' "$FINAL_BRIEF" > "$brief"
  local reg="$d/registry"; seed_registry "$reg"
  local before; before=$(cat "$brief")
  FM_MEMORY_INJECT=0 FM_HOME="$d" MEM_REGISTRY_DIR="$reg" "$INJECT" --task t1 --brief "$brief" --project firstmate --kind ship >/dev/null
  [ "$(cat "$brief")" = "$before" ] || fail "FM_MEMORY_INJECT=0 must override an enabling config file"
  pass "explicit FM_MEMORY_INJECT=0 overrides an enabling config file"
}

test_wrapper_env_enable_injects() {
  local d="$TMP_ROOT/ee"; mkdir -p "$d/config"
  local brief="$d/brief.md"; printf '%s' "$FINAL_BRIEF" > "$brief"
  local reg="$d/registry"; seed_registry "$reg"
  local out status
  out=$(FM_MEMORY_INJECT=1 FM_HOME="$d" MEM_REGISTRY_DIR="$reg" "$INJECT" --task t1 --brief "$brief" --project firstmate --kind ship); status=$?
  expect_code 0 "$status" "wrapper must exit 0 on successful injection"
  assert_grep '## Fleet memory' "$brief" "the pointer block must be injected when enabled"
  assert_grep 'MEM-0001' "$brief" "an active memory pointer must appear"
  assert_present "$d/memory-proof.json" "a spawn-time proof must be written"
  assert_grep '"injected": true' "$d/memory-proof.json" "the proof must record a real injection"
  # After-the-fact verification passes on the injected artifact.
  MEM_REGISTRY_DIR="$reg" node "$MEMBIN" verify-brief --brief "$brief" >/dev/null 2>&1 || fail "verify-brief must pass on the injected brief"
  pass "explicit FM_MEMORY_INJECT=1 injects a pointer block + proof that verifies"
}

# --- wrapper: fail-open (inert when registry empty/unavailable) --------------
test_wrapper_failopen_absent_registry() {
  local d="$TMP_ROOT/fo"; mkdir -p "$d/config"
  local brief="$d/brief.md"; printf '%s' "$FINAL_BRIEF" > "$brief"
  local before; before=$(cat "$brief")
  local status
  env -u FM_MEMORY_INJECT FM_HOME="$d" MEM_REGISTRY_DIR="$d/nope" "$INJECT" --task t1 --brief "$brief" --project firstmate --kind ship >/dev/null; status=$?
  expect_code 0 "$status" "wrapper must never fail even with an absent registry"
  [ "$(cat "$brief")" = "$before" ] || fail "brief must be unchanged when the registry is unavailable (fail-open to no-injection)"
  pass "default-on + an unavailable registry fails open: exit 0, brief unchanged"
}

test_wrapper_no_cli_noop() {
  local d="$TMP_ROOT/nocli"; mkdir -p "$d/config"
  local brief="$d/brief.md"; printf '%s' "$FINAL_BRIEF" > "$brief"
  local before; before=$(cat "$brief")
  local status
  # MEM_CLI points at a non-existent command -> the wrapper's run is non-fatal.
  env -u FM_MEMORY_INJECT MEM_CLI="$d/no-such-mem-binary" FM_HOME="$d" "$INJECT" --task t1 --brief "$brief" --project firstmate --kind ship >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "wrapper must exit 0 even when the CLI cannot run"
  [ "$(cat "$brief")" = "$before" ] || fail "brief must be unchanged when the CLI cannot run"
  pass "a broken/missing memory CLI is a silent no-op (fail-open)"
}

# --- wrapper: portable spawn-safe deadline (FC-006) --------------------------
test_wrapper_deadline_failopen() {
  local d="$TMP_ROOT/deadline"; mkdir -p "$d/config"
  local brief="$d/brief.md"; printf '%s' "$FINAL_BRIEF" > "$brief"
  local before; before=$(cat "$brief")
  # A CLI that would hang far past the deadline; the wrapper must kill it and
  # fail open to no-injection without blocking the (simulated) spawn.
  local slow="$d/slow-mem"
  printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$slow"; chmod +x "$slow"
  local start status
  start=$SECONDS
  env -u FM_MEMORY_INJECT FM_MEMORY_INJECT_TIMEOUT=1 MEM_CLI="$slow" FM_HOME="$d" \
    "$INJECT" --task t1 --brief "$brief" --project firstmate --kind ship >/dev/null 2>&1; status=$?
  local elapsed=$((SECONDS - start))
  expect_code 0 "$status" "the deadline path must still exit 0 (never fail the spawn)"
  [ "$elapsed" -lt 8 ] || fail "the deadline must bound the call (elapsed ${elapsed}s should be well under the 30s child)"
  [ "$(cat "$brief")" = "$before" ] || fail "brief must be unchanged when the recall call is killed by the deadline"
  pass "a hung memory CLI is bounded by the portable deadline: fail-open, brief unchanged, spawn never blocked"
}

# --- fm-spawn integration (fakebin) -----------------------------------------
make_fakebin() {  # <dir> -> echoes fakebin path
  local fakebin; fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|select-window|set-option|rename-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do [ "$prev" = "-l" ] && printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"; prev=$a; done
    fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ]; then printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0; fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# build_home <name> <id> <brief-content> -> echoes home|proj|wt|fakebin|launchlog|reg|id
# (the registry is created but NOT seeded; each caller seeds it as it needs).
build_home() {
  local name=$1 id=$2 brief=$3 dir home proj wt fakebin launchlog reg
  dir="$TMP_ROOT/$name"; home="$dir/home"; proj="$dir/project"; wt="$dir/.treehouse/1/wt"
  launchlog="$dir/launch.log"; reg="$dir/registry"
  fakebin=$(make_fakebin "$dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  printf '%s' "$brief" > "$home/data/$id/brief.md"
  printf '%s|%s|%s|%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$reg" "$id"
}

run_spawn() {  # <home> <proj> <wt> <fakebin> <launchlog> <id> [env KEY=VAL ...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 launchlog=$5 id=$6; shift 6
  : > "$launchlog"
  # env -u FM_MEMORY_INJECT drops tests/lib.sh's suite-wide OFF pin so the spawn
  # exercises the INTRINSIC default (recall on); a caller can still re-add
  # FM_MEMORY_INJECT=1 via "$@" for the explicit-enable cases.
  # FM_ROLE_OVERRIDE=primary: this suite targets injection, not the dispatch role
  # guard (that is fm-govern-spawn-gate's job), so it forces the primary role via the
  # documented audited override. That keeps the test runnable both as the primary and
  # from inside a crew worktree (e.g. a crewmate verifying its own change).
  env -u FM_MEMORY_INJECT FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_ROLE_OVERRIDE=primary FM_ROLE_OVERRIDE_REASON=fm-memory-inject-test \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" \
    TMUX="fake,1,0" FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$@" "$SPAWN" "$id" "$proj" 2>&1
}

test_spawn_injects_by_default() {
  local rec home proj wt fakebin launchlog reg id out status
  rec=$(build_home spawn-default ship-default-1 "$FINAL_BRIEF")
  IFS='|' read -r home proj wt fakebin launchlog reg id <<EOF
$rec
EOF
  seed_registry "$reg"
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id" MEM_REGISTRY_DIR="$reg"); status=$?
  expect_code 0 "$status" "a normal ship spawn must succeed"
  assert_contains "$out" "spawned $id" "spawn must report success"
  assert_grep '## Fleet memory' "$home/data/$id/brief.md" "recall runs on every dispatch: the brief must carry the injected pointer block"
  assert_grep 'MEM-0001' "$home/data/$id/brief.md" "the injected pointer must reference the active memory"
  assert_present "$home/data/$id/memory-proof.json" "a spawn-time proof must be written"
  # The launch command reads the brief at runtime (`cat <brief>`), so the crew sees
  # the injected block; assert the launch references that exact brief path.
  assert_grep "$home/data/$id/brief.md" "$launchlog" "the launch command must read the injected brief"
  pass "fm-spawn: injection wires into every dispatch's brief by default, spawn still succeeds"
}

test_spawn_inert_when_registry_absent() {
  local rec home proj wt fakebin launchlog reg id out status before
  rec=$(build_home spawn-inert ship-inert-1 "$FINAL_BRIEF")
  IFS='|' read -r home proj wt fakebin launchlog reg id <<EOF
$rec
EOF
  before=$(cat "$home/data/$id/brief.md")
  # Default-on, but the registry is absent: recall fails open -> no injection, and
  # the spawn still succeeds. This is the contract's "inert when registry unavailable".
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id" MEM_REGISTRY_DIR="$home/absent"); status=$?
  expect_code 0 "$status" "a spawn against an unavailable registry must succeed"
  assert_contains "$out" "spawned $id" "spawn must report success"
  [ "$(cat "$home/data/$id/brief.md")" = "$before" ] || fail "brief must be unchanged when the registry is unavailable"
  assert_not_contains "$(cat "$home/data/$id/brief.md")" "## Fleet memory" "no memory block when the registry is unavailable"
  pass "fm-spawn: default-on is inert when the registry is empty/unavailable (fail-open, no injection)"
}

test_spawn_failopen_does_not_break_spawn() {
  local rec home proj wt fakebin launchlog reg id out status
  rec=$(build_home spawn-failopen ship-failopen-1 "$FINAL_BRIEF")
  IFS='|' read -r home proj wt fakebin launchlog reg id <<EOF
$rec
EOF
  # Explicitly enabled, pointed at an absent registry: recall fails -> no injection,
  # but the spawn must still succeed (fail-open, never fail-wrong, never break dispatch).
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id" MEM_REGISTRY_DIR="$home/absent" FM_MEMORY_INJECT=1); status=$?
  expect_code 0 "$status" "a recall failure must not break the spawn"
  assert_contains "$out" "spawned $id" "spawn must succeed despite recall failure"
  assert_not_contains "$(cat "$home/data/$id/brief.md")" "## Fleet memory" "no memory block on recall failure"
  pass "fm-spawn: a recall failure fails open (no injection) without breaking dispatch"
}

# --- dispatch recall of a failure class (Compounding Fleet stage B) ----------
test_spawn_failure_class_recall() {
  local rec home proj wt fakebin launchlog reg id out status
  rec=$(build_home spawn-fc ship-fc-1 "$FC_BRIEF")
  IFS='|' read -r home proj wt fakebin launchlog reg id <<EOF
$rec
EOF
  # The real dispatch-recall corpus: failure classes registered from the committed
  # ledger. FC-004 is "fail-open on a missing prerequisite tool"; FC-006 is a
  # distinct class seeded alongside it to show the RIGHT class surfaces.
  seed_failure_classes "$reg" FC-004 FC-006
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id" MEM_REGISTRY_DIR="$reg"); status=$?
  expect_code 0 "$status" "a failure-class-matching ship spawn must succeed"
  assert_contains "$out" "spawned $id" "spawn must report success"
  assert_grep '## Fleet memory' "$home/data/$id/brief.md" "the brief must carry the injected recall pack"
  assert_grep 'FC-004' "$home/data/$id/brief.md" "the pack must contain the failure class whose detection cues the brief matches"
  assert_grep 'mem show MEM-' "$home/data/$id/brief.md" "the pack must cite the memory id (pointer-only)"
  assert_present "$home/data/$id/memory-proof.json" "a spawn-time proof must be written"
  assert_grep '"injected": true' "$home/data/$id/memory-proof.json" "the proof must record what was injected"
  pass "fm-spawn: a brief matching a failure class's cues yields a pack containing that class, cited, with proof"
}

test_wrapper_default_on_injects
test_wrapper_config_disable_off
test_wrapper_env_disable_wins
test_wrapper_env_enable_injects
test_wrapper_failopen_absent_registry
test_wrapper_no_cli_noop
test_wrapper_deadline_failopen
test_spawn_injects_by_default
test_spawn_inert_when_registry_absent
test_spawn_failopen_does_not_break_spawn
test_spawn_failure_class_recall

pass "fm-memory-inject: all wrapper + fm-spawn integration + failure-class recall cases passed"

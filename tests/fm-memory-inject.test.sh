#!/usr/bin/env bash
# Memory PR-4 spawn-time injection. Two layers:
#   * the fm-memory-inject.sh wrapper contract (opt-in gate, fail-open, real
#     injection against a fixture registry), and
#   * the fm-spawn.sh integration (injection is inert by default, injects when
#     enabled, and NEVER fails a spawn), reusing the govern-gate fakebin pattern.
# Every registry used here is an isolated fixture; the production registry is never
# read or written (MEM_REGISTRY_DIR is always pinned to a temp dir).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INJECT="$ROOT/bin/fm-memory-inject.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
MEMBIN="$ROOT/memory/bin/mem.mjs"
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

FINAL_BRIEF=$'# Task\nFix the stale watcher and the worktree isolation problem.\n\n# Setup\ndetails\n'

# --- wrapper: opt-in gate ---------------------------------------------------
test_wrapper_disabled_by_default() {
  local d="$TMP_ROOT/wd"; mkdir -p "$d/config"
  local brief="$d/brief.md"; printf '%s' "$FINAL_BRIEF" > "$brief"
  local reg="$d/registry"; seed_registry "$reg"
  local before; before=$(cat "$brief")
  local out status
  out=$(FM_HOME="$d" MEM_REGISTRY_DIR="$reg" "$INJECT" --task t1 --brief "$brief" --project firstmate --kind ship); status=$?
  expect_code 0 "$status" "wrapper must exit 0 when disabled"
  [ "$(cat "$brief")" = "$before" ] || fail "brief must be unchanged when injection is disabled by default"
  assert_absent "$d/memory-proof.json" "no proof is written when disabled"
  pass "wrapper is inert (no injection, no proof) by default"
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

# --- wrapper: enabled real injection ----------------------------------------
test_wrapper_env_enable_injects() {
  local d="$TMP_ROOT/ee"; mkdir -p "$d/config"
  local brief="$d/brief.md"; printf '%s' "$FINAL_BRIEF" > "$brief"
  local reg="$d/registry"; seed_registry "$reg"
  local out status
  out=$(FM_MEMORY_INJECT=1 FM_HOME="$d" MEM_REGISTRY_DIR="$reg" "$INJECT" --task t1 --brief "$brief" --project firstmate --kind ship); status=$?
  expect_code 0 "$status" "wrapper must exit 0 on successful injection"
  assert_grep '## Fleet memory' "$brief" "the pointer block must be injected when enabled"
  assert_grep 'MEM-0001' "$brief" "an active memory pointer must appear"
  assert_grep 'mem show MEM-0001' "$brief" "pointer must carry the show command (pointer-only)"
  assert_present "$d/memory-proof.json" "a spawn-time proof must be written"
  assert_grep '"injected": true' "$d/memory-proof.json" "the proof must record a real injection"
  # After-the-fact verification passes on the injected artifact.
  MEM_REGISTRY_DIR="$reg" node "$MEMBIN" verify-brief --brief "$brief" >/dev/null 2>&1 || fail "verify-brief must pass on the injected brief"
  pass "FM_MEMORY_INJECT=1 injects a pointer block + proof that verifies"
}

test_wrapper_config_enable_injects() {
  local d="$TMP_ROOT/ce"; mkdir -p "$d/config"
  printf 'true\n' > "$d/config/memory-inject.enabled"
  local brief="$d/brief.md"; printf '%s' "$FINAL_BRIEF" > "$brief"
  local reg="$d/registry"; seed_registry "$reg"
  FM_HOME="$d" MEM_REGISTRY_DIR="$reg" "$INJECT" --task t1 --brief "$brief" --project firstmate --kind ship >/dev/null
  assert_grep '## Fleet memory' "$brief" "config-enabled injection must inject"
  pass "config/memory-inject.enabled turns injection on"
}

# --- wrapper: fail-open -------------------------------------------------------
test_wrapper_failopen_absent_registry() {
  local d="$TMP_ROOT/fo"; mkdir -p "$d/config"
  local brief="$d/brief.md"; printf '%s' "$FINAL_BRIEF" > "$brief"
  local before; before=$(cat "$brief")
  local status
  FM_MEMORY_INJECT=1 FM_HOME="$d" MEM_REGISTRY_DIR="$d/nope" "$INJECT" --task t1 --brief "$brief" --project firstmate --kind ship >/dev/null; status=$?
  expect_code 0 "$status" "wrapper must never fail even with an absent registry"
  [ "$(cat "$brief")" = "$before" ] || fail "brief must be unchanged on recall failure (fail-open to no-injection)"
  pass "an absent registry fails open: exit 0, brief unchanged"
}

test_wrapper_no_cli_noop() {
  local d="$TMP_ROOT/nocli"; mkdir -p "$d/config"
  local brief="$d/brief.md"; printf '%s' "$FINAL_BRIEF" > "$brief"
  local before; before=$(cat "$brief")
  local status
  # MEM_CLI points at a non-existent command -> the wrapper's run is non-fatal.
  FM_MEMORY_INJECT=1 MEM_CLI="$d/no-such-mem-binary" FM_HOME="$d" "$INJECT" --task t1 --brief "$brief" --project firstmate --kind ship >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "wrapper must exit 0 even when the CLI cannot run"
  [ "$(cat "$brief")" = "$before" ] || fail "brief must be unchanged when the CLI cannot run"
  pass "a broken/missing memory CLI is a silent no-op (fail-open)"
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

spawn_case() {  # <name> <id> ; echoes home|proj|wt|fakebin|launchlog|reg|id
  local name=$1 id=$2 dir home proj wt fakebin launchlog reg
  dir="$TMP_ROOT/$name"; home="$dir/home"; proj="$dir/project"; wt="$dir/.treehouse/1/wt"
  launchlog="$dir/launch.log"; reg="$dir/registry"
  fakebin=$(make_fakebin "$dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  seed_registry "$reg"
  printf '%s' "$FINAL_BRIEF" > "$home/data/$id/brief.md"
  printf '%s|%s|%s|%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$reg" "$id"
}

run_spawn() {  # <home> <proj> <wt> <fakebin> <launchlog> <id> [env KEY=VAL ...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 launchlog=$5 id=$6; shift 6
  : > "$launchlog"
  # FM_ROLE_OVERRIDE=primary: this suite targets injection, not the dispatch role
  # guard (that is fm-govern-spawn-gate's job), so it forces the primary role via the
  # documented audited override. That keeps the test runnable both as the primary and
  # from inside a crew worktree (e.g. a crewmate verifying its own change).
  env FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_ROLE_OVERRIDE=primary FM_ROLE_OVERRIDE_REASON=fm-memory-inject-test \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" \
    TMUX="fake,1,0" FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$@" "$SPAWN" "$id" "$proj" 2>&1
}

test_spawn_inert_by_default() {
  local rec home proj wt fakebin launchlog reg id out status before
  rec=$(spawn_case spawn-default ship-default-1)
  IFS='|' read -r home proj wt fakebin launchlog reg id <<EOF
$rec
EOF
  before=$(cat "$home/data/$id/brief.md")
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id" MEM_REGISTRY_DIR="$reg"); status=$?
  expect_code 0 "$status" "a normal ship spawn must succeed"
  assert_contains "$out" "spawned $id" "spawn must report success"
  [ "$(cat "$home/data/$id/brief.md")" = "$before" ] || fail "brief must be unchanged: injection is opt-in and OFF by default"
  assert_absent "$home/data/$id/memory-proof.json" "no proof sidecar when injection is disabled by default"
  pass "fm-spawn: memory injection is inert by default (brief byte-identical)"
}

test_spawn_injects_when_enabled() {
  local rec home proj wt fakebin launchlog reg id out status
  rec=$(spawn_case spawn-enabled ship-enabled-1)
  IFS='|' read -r home proj wt fakebin launchlog reg id <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id" MEM_REGISTRY_DIR="$reg" FM_MEMORY_INJECT=1); status=$?
  expect_code 0 "$status" "an enabled-injection ship spawn must still succeed"
  assert_contains "$out" "spawned $id" "spawn must report success even with injection on"
  assert_grep '## Fleet memory' "$home/data/$id/brief.md" "the brief must carry the injected pointer block"
  assert_grep 'MEM-0001' "$home/data/$id/brief.md" "the injected pointer must reference the active memory"
  assert_present "$home/data/$id/memory-proof.json" "a spawn-time proof must be written"
  # The launch command reads the brief at runtime (`cat <brief>`), so the crew sees
  # the injected block; assert the launch references that exact brief path.
  assert_grep "$home/data/$id/brief.md" "$launchlog" "the launch command must read the injected brief"
  pass "fm-spawn: injection wires into the launched brief when enabled, spawn still succeeds"
}

test_spawn_failopen_does_not_break_spawn() {
  local rec home proj wt fakebin launchlog reg id out status
  rec=$(spawn_case spawn-failopen ship-failopen-1)
  IFS='|' read -r home proj wt fakebin launchlog reg id <<EOF
$rec
EOF
  # Enabled, but point at an absent registry: recall fails -> no injection, but the
  # spawn must still succeed (fail-open, never fail-wrong, never break dispatch).
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id" MEM_REGISTRY_DIR="$home/absent" FM_MEMORY_INJECT=1); status=$?
  expect_code 0 "$status" "a recall failure must not break the spawn"
  assert_contains "$out" "spawned $id" "spawn must succeed despite recall failure"
  assert_not_contains "$(cat "$home/data/$id/brief.md")" "## Fleet memory" "no memory block on recall failure"
  pass "fm-spawn: a recall failure fails open (no injection) without breaking dispatch"
}

test_wrapper_disabled_by_default
test_wrapper_env_disable_wins
test_wrapper_env_enable_injects
test_wrapper_config_enable_injects
test_wrapper_failopen_absent_registry
test_wrapper_no_cli_noop
test_spawn_inert_by_default
test_spawn_injects_when_enabled
test_spawn_failopen_does_not_break_spawn

pass "fm-memory-inject: all wrapper + fm-spawn integration cases passed"

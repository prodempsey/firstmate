#!/usr/bin/env bash
# Integration test for the postmortem-capture chokepoint WIRING in bin/fm-teardown.sh (ORD-274
# Compounding Fleet stage A). Drives the REAL bin/fm-teardown.sh end-to-end against a scratch
# project/worktree/store and asserts the closeout distills a structured postmortem CANDIDATE into
# a FIXTURE registry - proving the hook is actually wired at the universal closeout, not merely
# unit-tested in isolation. Two standing contracts are pinned at the real call site:
#   * gate on  -> a candidate for the torn-down task lands in the fixture registry;
#   * gate off  -> no candidate is written;
# and in BOTH cases the real teardown succeeds (exit 0) - the postmortem hook can never block or
# fail a closeout. FIXTURE REGISTRY ONLY: MEM_REGISTRY_DIR points at a per-case temp dir, so the
# canonical registry is never touched.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-postmortem-wiring)

wait_for_candidate() { # <registry-dir> <task>
  local reg=$1 task=$2 f="$1/memory-registry.jsonl" _
  for _ in $(seq 1 40); do
    if [ -f "$f" ] && grep -Fq "\"$task\"" "$f" 2>/dev/null; then return 0; fi
    command sleep 0.3 2>/dev/null || true
  done
  return 1
}

# A real ship task teardown case: a project clone whose fm/<id> branch is LANDED (pushed to a
# remote, which teardown's safety check accepts), the fakebins teardown shells out to, a
# visibility stub, a meta, and a data/<id>/report.md for the postmortem to distill.
make_teardown_case() { # <name> <task> -> echoes "<case_dir>"
  local name=$1 task=$2 cd fakebin
  cd="$TMP_ROOT/$name"
  fakebin="$cd/fakebin"
  mkdir -p "$cd/state" "$cd/data/$task" "$fakebin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/treehouse"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/tmux"
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
  "pr view") exit 1 ;;
esac
exit 0
SH
  cp "$fakebin/gh-axi" "$fakebin/gh"
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh"
  printf '#!/usr/bin/env node\nprocess.exit(0);\n' > "$cd/visibility.mjs"
  {
    printf '# %s postmortem source\n\n' "$task"
    printf '## What worked\nlanded as a clean fast-forward.\n\n'
    printf '## Sharp edges\nthe pooled clone lagged origin; compared against the authoritative base.\n'
  } > "$cd/data/$task/report.md"
  git init -q --bare "$cd/origin.git"
  git -C "$cd/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$cd/origin.git" "$cd/_seed" 2>/dev/null
  git -C "$cd/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$cd/_seed" push -q origin main
  rm -rf "$cd/_seed"
  git clone -q "$cd/origin.git" "$cd/project"
  git -C "$cd/project" remote set-head origin main 2>/dev/null || true
  git -C "$cd/project" worktree add -q -b "fm/$task" "$cd/wt" main
  git -C "$cd/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "wt work"
  git -C "$cd/wt" push -q origin "fm/$task"
  git -C "$cd/project" fetch -q origin
  touch "$cd/state/.last-watcher-beat"
  fm_write_meta "$cd/state/$task.meta" \
    "window=fm-$task" "worktree=$cd/wt" "project=$cd/project" "kind=ship" "mode=local-only"
  printf '%s' "$cd"
}

# Run the real teardown. FM_ROLE_OVERRIDE=primary is the sanctioned audited override for a primary
# acting inside a crew worktree (this suite runs from a crew worktree during firstmate's own gate).
# The extra env after the fixed prefix is the postmortem gate/registry for the case.
run_teardown() { # <case_dir> <task> <extra env>...
  local cd=$1 task=$2; shift 2
  PATH="$cd/fakebin:$PATH" \
  FM_ROLE_OVERRIDE=primary FM_ROLE_OVERRIDE_REASON="fm-postmortem-wiring integration test drives a real primary teardown" \
  FM_HOME="$cd" FM_STATE_OVERRIDE="$cd/state" FM_VISIBILITY_CLI="$cd/visibility.mjs" \
  env "$@" "$ROOT/bin/fm-teardown.sh" "$task" >/dev/null 2>&1
  return $?
}

# --- gate on: the real closeout lands a postmortem candidate -----------------------
test_teardown_captures_postmortem() {
  local cd reg rc regfile
  cd=$(make_teardown_case captured task-x1)
  reg="$cd/reg"
  run_teardown "$cd" task-x1 FM_POSTMORTEM_STOW=1 MEM_REGISTRY_DIR="$reg"
  rc=$?
  expect_code 0 "$rc" "the real teardown must succeed (exit 0) with postmortem capture enabled"
  wait_for_candidate "$reg" task-x1 \
    || fail "a REAL ship teardown with the gate on must land a postmortem candidate for the task"
  regfile="$reg/memory-registry.jsonl"
  assert_grep '"event":"proposed"' "$regfile" "the captured postmortem must be a candidate (proposed)"
  assert_grep '"type":"source-type","ref":"task-postmortem"' "$regfile" "the captured record must carry source_type=task-postmortem"
  assert_grep '"type":"task","ref":"task-x1"' "$regfile" "the captured record must carry task provenance"
  assert_grep 'landed as a clean fast-forward' "$regfile" "the report content must be distilled into the record"
  pass "real fm-teardown closeout (gate on) -> structured postmortem candidate lands in fixture registry"
}

# --- gate off: closeout writes nothing, still succeeds -----------------------------
test_teardown_inert_when_gate_off() {
  local cd reg rc
  cd=$(make_teardown_case inert task-y2)
  reg="$cd/reg"
  # FM_POSTMORTEM_STOW unset entirely; MEM_REGISTRY_DIR still isolated so an accidental write would
  # be caught here rather than in the canonical registry.
  run_teardown "$cd" task-y2 MEM_REGISTRY_DIR="$reg"
  rc=$?
  expect_code 0 "$rc" "the real teardown must succeed (exit 0) with postmortem capture disabled"
  command sleep 1 2>/dev/null || true
  [ ! -f "$reg/memory-registry.jsonl" ] || fail "with the gate off a real teardown must write no postmortem"
  pass "real fm-teardown closeout (gate off) -> inert, teardown still succeeds"
}

test_teardown_captures_postmortem
test_teardown_inert_when_gate_off

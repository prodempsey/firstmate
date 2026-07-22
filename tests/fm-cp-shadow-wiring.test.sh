#!/usr/bin/env bash
# Actual-shell integration tests for the CW2 shadow-run chokepoint wiring (ORD-256, QA
# qa-cw2r2-q88). These drive the REAL template lifecycle scripts against a REAL control-plane
# store and assert the intended WRITER ACTION lands - not merely an annotation. The focus is
# the terminal chokepoints QA found unwired:
#   * fm-task-events.sh `failed`  disposition -> drives failRun (task failed, `failed` event);
#   * fm-task-events.sh `landed`  disposition -> drives completeRun (`completed` event);
#   * fm-task-events.sh `reported` (scout)    -> a generic status annotation, no terminal verb;
#   * fm-teardown.sh archive call (ship)      -> drives archiveTask (`archived` event).
# Plus the standing contracts at these real call sites: gated by CP_SHADOW=1, fired only on a
# successful/committed closeout, and never blocking or failing the legacy operation.
#
# The shadow hook backgrounds a detached node process, so every assertion POLLS the store
# with a bounded wait rather than reading it once.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-cp-shadow-wiring)
CP="$ROOT/control-plane/bin/cp.mjs"
HELPER="$TMP_ROOT/cphelper.mjs"

assert_eq() { # <expected> <actual> <msg>
  [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"
}

# A single node helper the shell drives: build a task state, or query the store. Uses dynamic
# import() so the control-plane lib dir is resolved from CP_LIB at runtime.
cat > "$HELPER" <<'JS'
const lib = process.env.CP_LIB;
const { PgliteLocalStore } = await import(lib + '/pglite-local-store.mjs');
const { createTask, beginRun } = await import(lib + '/domain-store.mjs');
const { completeRun } = await import(lib + '/domain-store-s2.mjs');
const { recordSpawn, commitRunning, cleanupIntent, cleanupFinish } = await import(lib + '/domain-store-s3.mjs');
const { claimConsumer, claimDelivery, markApplied, ack } = await import(lib + '/domain-store-s4.mjs');
const { readOnlyQuery } = await import(lib + '/cw1-readonly.mjs');

const ID = { endpointId: '@0', paneId: '%0', bootId: 'b', paneLeaderPid: 1, paneStartTicks: 1, agentPid: 2, agentStartTicks: 2, agentExe: '/n', agentArgvHash: 'h', agentPpid: 1, agentPty: 'pts/0', worktree: '/wt', harness: 'claude' };
const captureOk = () => ({ ok: true, identity: { ...ID } });
const probeMatch = () => ({ matches: true, failingClause: null, anomalyClass: null });
const dd = process.env.DD;
const [cmd, task, arg] = process.argv.slice(2);
const s = PgliteLocalStore.create({ dataDir: dd });
try {
  if (cmd === 'spawning') {
    const c = await createTask(s, { taskId: task, kind: 'ship', title: 'x', origin: 'internal', internalReason: 'r', commandId: `c:${task}` });
    await beginRun(s, { taskId: task, expectedRevision: c.revision, commandId: `b:${task}` });
  } else if (cmd === 'running') {
    const c = await createTask(s, { taskId: task, kind: 'ship', title: 'x', origin: 'internal', internalReason: 'r', commandId: `c:${task}` });
    const beg = await beginRun(s, { taskId: task, expectedRevision: c.revision, commandId: `b:${task}` });
    const rs = await recordSpawn(s, { taskId: task, generation: 1, expectedRevision: beg.revision, launchMarker: beg.launch_marker, endpoint: ID.endpointId, pane: ID.paneId, regFile: '/reg', commandId: `rs:${task}` }, { captureIdentity: captureOk });
    await commitRunning(s, { taskId: task, generation: 1, expectedRevision: rs.revision, commandId: `cr:${task}` }, { probeIdentity: probeMatch });
  } else if (cmd === 'archivable') {
    const c = await createTask(s, { taskId: task, kind: 'ship', title: 'x', origin: 'internal', internalReason: 'r', commandId: `c:${task}` });
    const beg = await beginRun(s, { taskId: task, expectedRevision: c.revision, commandId: `b:${task}` });
    const rs = await recordSpawn(s, { taskId: task, generation: 1, expectedRevision: beg.revision, launchMarker: beg.launch_marker, endpoint: ID.endpointId, pane: ID.paneId, regFile: '/reg', commandId: `rs:${task}` }, { captureIdentity: captureOk });
    const cr = await commitRunning(s, { taskId: task, generation: 1, expectedRevision: rs.revision, commandId: `cr:${task}` }, { probeIdentity: probeMatch });
    const done = await completeRun(s, { taskId: task, generation: 1, expectedRevision: cr.revision, outcome: 'success', producer: 'crewmate', seq: 1, evidence: {}, commandId: `dn:${task}` });
    const term = (await readOnlyQuery(s, "SELECT outbox_id, event_id FROM outbox WHERE task_id=$1 AND event_type IN ('completed','failed')", [task]))[0];
    const intent = await cleanupIntent(s, { taskId: task, generation: 1, expectedRevision: done.revision, commandId: `ci:${task}` });
    await cleanupFinish(s, { taskId: task, generation: 1, expectedRevision: intent.revision, effectResult: { killed: true, confirmed_absent: true }, commandId: `cf:${task}` });
    const lease = await claimConsumer(s, { bootId: 'b', pid: 9, commandId: `cc:${task}` });
    await claimDelivery(s, { outboxId: Number(term.outbox_id), ownerToken: lease.owner_token, ownerEpoch: lease.owner_epoch, sinkKind: 'disposition', commandId: `cd:${task}` });
    await markApplied(s, { eventId: term.event_id, ownerToken: lease.owner_token, ownerEpoch: lease.owner_epoch, sinkResult: { ok: true, event_id: term.event_id }, commandId: `ma:${task}` });
    await ack(s, { outboxId: Number(term.outbox_id), ownerToken: lease.owner_token, ownerEpoch: lease.owner_epoch, commandId: `ak:${task}` });
  } else if (cmd === 'event-count') {
    const r = await readOnlyQuery(s, 'SELECT count(*)::int n FROM task_events WHERE task_id=$1 AND event_type=$2', [task, arg]);
    process.stdout.write(String(r[0].n));
  } else if (cmd === 'task-status') {
    const r = await readOnlyQuery(s, 'SELECT status FROM tasks WHERE task_id=$1', [task]);
    process.stdout.write(r.length ? r[0].status : 'ABSENT');
  } else if (cmd === 'annotation-count') {
    const present = (await readOnlyQuery(s, "SELECT 1 FROM information_schema.tables WHERE table_name='shadow_annotations'")).length > 0;
    if (!present) { process.stdout.write('0'); }
    else { const r = await readOnlyQuery(s, 'SELECT count(*)::int n FROM shadow_annotations WHERE task_id=$1 AND action=$2', [task, arg]); process.stdout.write(String(r[0].n)); }
  }
} finally { await s.close(); }
JS

helper() { DD="$1" CP_LIB="$ROOT/control-plane/lib" node "$HELPER" "${@:2}"; }

# Poll a helper count query until it reaches $target (bounded ~15s), tolerating the detached
# background mirror.
poll_until() { # $1=DD $2=target $3.. = helper args
  local dd=$1 target=$2; shift 2
  local n
  for _ in $(seq 1 30); do
    n=$(helper "$dd" "$@" 2>/dev/null || echo 0)
    [ "$n" = "$target" ] && return 0
    command sleep 0.5 2>/dev/null || true
  done
  return 1
}

# Build a case: a fresh cp store + a firstmate home with a visibility stub that succeeds.
make_case() { # $1=name  -> echoes "<dd>|<home>"
  local name=$1 dir dd home
  dir="$TMP_ROOT/$name"
  dd="$dir/store/pgdata"
  home="$dir/home"
  mkdir -p "$home/state"
  node "$CP" init --data-dir "$dd" >/dev/null 2>&1
  cat > "$home/vis.mjs" <<'JS'
const a = process.argv.slice(2);
if (a[0] === 'close') { console.log('{"status":"terminal"}'); process.exit(0); }
process.exit(0);
JS
  printf '%s|%s' "$dd" "$home"
}

run_task_events() { # $1=dd $2=home  then fm-task-events args
  local dd=$1 home=$2; shift 2
  CP_SHADOW=1 CP_SHADOW_DATA_DIR="$dd" \
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_VISIBILITY_CLI="$home/vis.mjs" \
    "$ROOT/bin/fm-task-events.sh" "$@" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------------

test_failed_disposition_drives_failRun() {
  local dd home c
  c=$(make_case failed); dd=${c%%|*}; home=${c##*|}
  helper "$dd" spawning fail-1
  printf 'kind=ship\nmode=local-only\n' > "$home/state/fail-1.meta"
  run_task_events "$dd" "$home" fail-1 failed "worker failed" fm/fail-1 no-mistakes deadbeef
  poll_until "$dd" 1 event-count fail-1 failed || fail "failed disposition should drive a failed event"
  assert_eq failed "$(helper "$dd" task-status fail-1)" "the task must be FAILED, not left spawning"
  assert_eq 0 "$(helper "$dd" annotation-count fail-1 status:failed)" "a real failRun, NOT a status:failed annotation"
  pass "fm-task-events failed -> failRun (verb, not annotation)"
}

test_landed_disposition_drives_completeRun() {
  local dd home c
  c=$(make_case landed); dd=${c%%|*}; home=${c##*|}
  helper "$dd" running done-1
  printf 'kind=ship\nmode=local-only\n' > "$home/state/done-1.meta"
  run_task_events "$dd" "$home" done-1 landed "merged" fm/done-1 PR deadbeef
  poll_until "$dd" 1 event-count done-1 completed || fail "landed disposition should drive a completed event"
  assert_eq completed "$(helper "$dd" task-status done-1)" "the task must be COMPLETED"
  pass "fm-task-events landed -> completeRun (verb, not annotation)"
}

test_reported_scout_disposition_is_a_status_annotation() {
  local dd home c
  c=$(make_case reported); dd=${c%%|*}; home=${c##*|}
  helper "$dd" spawning scout-1
  printf 'kind=scout\nmode=local-only\n' > "$home/state/scout-1.meta"
  run_task_events "$dd" "$home" scout-1 reported "found it" fm/scout-1 scout-report data/scout-1/report.md
  poll_until "$dd" 1 annotation-count scout-1 status:reported || fail "a scout report closeout should record a status:reported annotation"
  assert_eq 0 "$(helper "$dd" event-count scout-1 failed)" "a scout report must not drive a terminal verb"
  assert_eq 0 "$(helper "$dd" event-count scout-1 completed)" "a scout report must not drive a terminal verb"
  pass "fm-task-events reported (scout) -> status annotation, no terminal verb"
}

# A REAL fm-teardown ship closeout from an ordinary running generation must reach `archived`.
# This runs the actual bin/fm-teardown.sh end-to-end (scratch project/worktree/store), the
# exact path QA's earlier direct-hook test bypassed and could not catch.
make_teardown_case() { # $1=name  -> echoes "<case_dir>|<dd>"
  local name=$1 cd fakebin dd
  cd="$TMP_ROOT/.treehouse/$name"
  fakebin="$cd/fakebin"
  mkdir -p "$cd/state" "$fakebin"
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
  # git project with a worktree whose task branch is LANDED (reachable from a remote).
  git init -q --bare "$cd/origin.git"
  git -C "$cd/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$cd/origin.git" "$cd/_seed" 2>/dev/null
  git -C "$cd/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$cd/_seed" push -q origin main
  rm -rf "$cd/_seed"
  git clone -q "$cd/origin.git" "$cd/project"
  git -C "$cd/project" remote set-head origin main 2>/dev/null || true
  git -C "$cd/project" worktree add -q -b fm/task-x1 "$cd/wt" main
  git -C "$cd/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "wt work"
  git -C "$cd/wt" push -q origin fm/task-x1
  git -C "$cd/project" fetch -q origin
  touch "$cd/state/.last-watcher-beat"
  fm_write_meta "$cd/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$cd/wt" "project=$cd/project" "kind=ship" "mode=local-only"
  # A cp store whose task-x1 has an ordinary running generation.
  dd="$cd/store/pgdata"
  node "$CP" init --data-dir "$dd" >/dev/null 2>&1
  helper "$dd" running task-x1
  printf '%s|%s' "$cd" "$dd"
}

run_teardown() { # $1=case_dir $2=dd  then fm-teardown args
  local cd=$1 dd=$2; shift 2
  # FM_ROLE_OVERRIDE=primary is the sanctioned audited override for a primary acting inside a
  # crew worktree: this suite runs from a crew worktree whose durable role marker would
  # otherwise make fm-teardown (a primary-only mutation) refuse. It does not affect the shadow
  # behaviour under test; in a primary CI checkout the override is a harmless confirmation.
  PATH="$cd/fakebin:$PATH" CP_SHADOW=1 CP_SHADOW_DATA_DIR="$dd" \
  FM_ROLE_OVERRIDE=primary FM_ROLE_OVERRIDE_REASON="fm-cp-shadow-wiring integration test drives a real primary teardown" \
  FM_HOME="$cd" FM_STATE_OVERRIDE="$cd/state" FM_VISIBILITY_CLI="$cd/visibility.mjs" \
    "$ROOT/bin/fm-teardown.sh" "$@" >/dev/null 2>&1 || true
}

test_real_ship_teardown_reaches_archived() {
  local c cd dd
  c=$(make_teardown_case tdreal); cd=${c%%|*}; dd=${c##*|}
  # Sanity: before teardown the shadow task is a normal running generation.
  assert_eq running "$(helper "$dd" task-status task-x1)" "precondition: the shadow task is running"
  run_teardown "$cd" "$dd" task-x1
  poll_until "$dd" 1 event-count task-x1 archived \
    || fail "a REAL ship teardown from a running generation must drive the shadow task to archived"
  assert_eq archived "$(helper "$dd" task-status task-x1)" "the shadow task must be ARCHIVED after a real fm-teardown"
  assert_eq 1 "$(helper "$dd" event-count task-x1 completed)" "exactly one completed event"
  assert_eq 1 "$(helper "$dd" event-count task-x1 cleaned)" "exactly one cleaned event"
  assert_eq 1 "$(helper "$dd" event-count task-x1 archived)" "exactly one archived event"
  pass "real fm-teardown ship closeout -> finalize -> archived"
}

test_finalize_is_idempotent() {
  # A second finalize (as a retried teardown would) replays: task stays archived, no dup events.
  local dd c
  c=$(make_case fin); dd=${c%%|*}
  helper "$dd" running fin-1
  CP_SHADOW=1 CP_SHADOW_DATA_DIR="$dd" "$ROOT/bin/fm-cp-shadow.sh" finalize --task fin-1 || fail "hook must not fail"
  poll_until "$dd" 1 event-count fin-1 archived || fail "first finalize should archive"
  CP_SHADOW=1 CP_SHADOW_DATA_DIR="$dd" "$ROOT/bin/fm-cp-shadow.sh" finalize --task fin-1 || fail "hook must not fail on replay"
  command sleep 1 2>/dev/null || true
  assert_eq archived "$(helper "$dd" task-status fin-1)" "still archived after a second finalize"
  assert_eq 1 "$(helper "$dd" event-count fin-1 archived)" "no duplicate archived event on replay"
  pass "finalize is idempotent (retried teardown replays)"
}

test_gate_off_touches_no_store() {
  local dd home c
  c=$(make_case gateoff); dd=${c%%|*}; home=${c##*|}
  helper "$dd" spawning off-1
  printf 'kind=ship\nmode=local-only\n' > "$home/state/off-1.meta"
  # CP_SHADOW unset: fm-task-events runs, but the hook is a no-op.
  CP_SHADOW='' CP_SHADOW_DATA_DIR="$dd" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_VISIBILITY_CLI="$home/vis.mjs" \
    "$ROOT/bin/fm-task-events.sh" off-1 failed "x" fm/off-1 no-mistakes deadbeef >/dev/null 2>&1 || true
  command sleep 1 2>/dev/null || true
  assert_eq spawning "$(helper "$dd" task-status off-1)" "with CP_SHADOW unset the store is untouched (task stays spawning)"
  pass "CP_SHADOW unset -> zero shadow-store effect"
}

test_never_blocks_on_broken_store() {
  # A configured-but-nonexistent store with CP_SHADOW=1: the legacy op still returns and the
  # missing store is never created.
  local home missing rc
  home="$TMP_ROOT/broken/home"; missing="$TMP_ROOT/broken/nope/pgdata"
  mkdir -p "$home/state"
  cat > "$home/vis.mjs" <<'JS'
const a = process.argv.slice(2); if (a[0]==='close'){console.log('{}');process.exit(0)} process.exit(0);
JS
  printf 'kind=ship\nmode=local-only\n' > "$home/state/brk-1.meta"
  CP_SHADOW=1 CP_SHADOW_DATA_DIR="$missing" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_VISIBILITY_CLI="$home/vis.mjs" \
    "$ROOT/bin/fm-task-events.sh" brk-1 failed "x" fm/brk-1 no-mistakes deadbeef >/dev/null 2>&1
  rc=$?
  command sleep 1 2>/dev/null || true
  assert_eq 0 "$rc" "the legacy closeout succeeds regardless of the shadow store"
  assert_absent "$missing" "a broken shadow-store path is never created"
  pass "broken shadow store never blocks or creates a split-brain store"
}

test_failed_disposition_drives_failRun
test_landed_disposition_drives_completeRun
test_reported_scout_disposition_is_a_status_annotation
test_real_ship_teardown_reaches_archived
test_finalize_is_idempotent
test_gate_off_touches_no_store
test_never_blocks_on_broken_store

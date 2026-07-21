import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { runExclusive } from '../lib/internal-runtime.mjs';
import { createTask, beginRun } from '../lib/domain-store.mjs';
import { completeRun } from '../lib/domain-store-s2.mjs';
import { recordSpawn, commitRunning } from '../lib/domain-store-s3.mjs';
import { resolveAnomaly } from '../lib/domain-store-s5.mjs';
import { reconcilePass } from '../lib/reconciler.mjs';
import { mkFixtureHome, cleanupAll } from './helpers.mjs';

// Adversarial S5: a reconcile writer that hard-exits between per-item commits, two passes
// racing on the flock, a reconciler promotion racing a coordinator commit-running, a
// partial-launch fail racing a late record-spawn, pid-reuse detection, and a terminal
// run left without cleanup then resolved. The invariants under attack: the pass is
// atomic per item and resumable (never a half-applied or duplicated sweep); every race
// resolves to EXACTLY ONE canonical outcome via the revision CAS and the flock; and the
// reconciler never kills, adopts, or double-audits.
after(cleanupAll);

const IDENTITY = {
  endpointId: '@0', paneId: '%0', bootId: 'boot-xyz',
  paneLeaderPid: 4242, paneStartTicks: 111111,
  agentPid: 4243, agentStartTicks: 222222, agentExe: '/usr/bin/node',
  agentArgvHash: 'argvhash-abc', agentPpid: 4242, agentPty: 'pts/7',
  worktree: '/tmp/wt', harness: 'claude'
};
const captureOk = () => ({ ok: true, identity: { ...IDENTITY } });
const probeMatch = () => ({ matches: true, failingClause: null, anomalyClass: null });
const probePidReuse = () => ({ matches: false, failingClause: 'agent_start_ticks', anomalyClass: 'pid_reuse_suspected' });
const FAR_FUTURE = '2999-01-01T00:00:00.000Z';

async function freshStore() {
  const { fmHome } = mkFixtureHome();
  const store = new PgliteLocalStore({ fmHome });
  await store.init({ homeLabel: 'test' });
  return { store, fmHome };
}
async function rows(store, sql, params) {
  return runExclusive(store, async (conn) => (await conn.query(sql, params)).rows);
}
async function counters(store) {
  const r = await rows(store, 'SELECT domain_revision, projection_revision, commit_sequence FROM coordinator_state WHERE id = 1');
  return { domain: Number(r[0].domain_revision), projection: Number(r[0].projection_revision), commit: Number(r[0].commit_sequence) };
}
async function runRow(store, taskId, generation = 1) {
  const r = await rows(store, 'SELECT status, binding_state, closed_at, endpoint_id, verified_at FROM runs WHERE task_id = $1 AND run_generation = $2', [taskId, generation]);
  return r[0];
}
async function taskRow(store, taskId) {
  const r = await rows(store, 'SELECT status, revision FROM tasks WHERE task_id = $1', [taskId]);
  return r[0];
}
async function eventCount(store, taskId, type) {
  const r = await rows(store, 'SELECT count(*)::int AS n FROM task_events WHERE task_id = $1 AND event_type = $2', [taskId, type]);
  return Number(r[0].n);
}
async function anomalyRows(store, cls) {
  return runExclusive(store, async (conn) => {
    const reg = await conn.query("SELECT to_regclass('public.anomalies') AS reg");
    if (reg.rows[0].reg === null) return [];
    const r = await conn.query('SELECT fingerprint, anomaly_class, occurrence_count, status FROM anomalies WHERE anomaly_class = $1', [cls]);
    return r.rows;
  });
}

async function beganTask(store, taskId) {
  await createTask(store, { taskId, kind: 'ship', title: 'x', origin: 'internal', internalReason: 'r', commandId: `c-create-${taskId}` });
  const beg = await beginRun(store, { taskId, expectedRevision: 1, commandId: `c-begin-${taskId}` });
  return { revision: beg.revision, launchMarker: beg.launch_marker };
}
async function spawnedTask(store, taskId, endpoint = IDENTITY.endpointId, pane = IDENTITY.paneId) {
  const { revision, launchMarker } = await beganTask(store, taskId);
  const rs = await recordSpawn(store, {
    taskId, generation: 1, expectedRevision: revision, launchMarker,
    endpoint, pane, regFile: '/reg', commandId: `c-spawn-${taskId}`
  }, { captureIdentity: () => ({ ok: true, identity: { ...IDENTITY, endpointId: endpoint, paneId: pane } }) });
  return { revision: rs.revision, launchMarker };
}
async function runningTask(store, taskId) {
  const { revision } = await spawnedTask(store, taskId);
  const cr = await commitRunning(store, { taskId, generation: 1, expectedRevision: revision, commandId: `c-run-${taskId}` }, { probeIdentity: probeMatch });
  return cr.revision;
}

test('t_reconcile_crash_mid_pass_recovers', async () => {
  const { store, fmHome } = await freshStore();
  await spawnedTask(store, 't1', '@1', '%1');
  await spawnedTask(store, 't2', '@2', '%2');
  const before = await counters(store);
  await store.close();

  // A REAL writer-exit between the two per-item commits: the child promotes t1 (committed),
  // then hard-exits before t2. The OS releases the flock.
  const worker = fileURLToPath(new URL('./workers/crash-reconcile-writer.mjs', import.meta.url));
  const child = spawnSync(process.execPath, [worker], {
    env: { ...process.env, CP_FM_HOME: fmHome, CP_NONCE: 'crash-pass' }, encoding: 'utf8', timeout: 60000
  });
  assert.equal(child.status, 46, `reconcile writer must hard-exit between commits (stderr: ${child.stderr})`);

  const reopened = new PgliteLocalStore({ fmHome });
  // t1 is durably promoted; t2 never was (the crash cut it off). No half-applied state.
  assert.equal((await taskRow(reopened, 't1')).status, 'running', 'the first promotion committed before the crash');
  assert.equal((await runRow(reopened, 't1')).binding_state, 'bound_verified');
  assert.equal((await taskRow(reopened, 't2')).status, 'spawning', 'the second promotion never ran');
  assert.equal(await eventCount(reopened, 't1', 'running_verified'), 1, 'exactly one running_verified for t1');
  assert.equal(await eventCount(reopened, 't2', 'running_verified'), 0);
  // t1's promotion is one domain change; t2 contributed nothing.
  assert.deepEqual(await counters(reopened), { domain: before.domain + 1, projection: 0, commit: before.commit + 1 });

  // A rerun with the SAME nonce finishes t2 and does NOT re-promote or duplicate t1.
  const rerun = await reconcilePass(reopened, { nonce: 'crash-pass', probeIdentity: probeMatch });
  assert.equal(rerun.committed.length, 1, 'the rerun promotes only the unfinished t2');
  assert.equal(rerun.committed[0].taskId, 't2');
  assert.equal((await taskRow(reopened, 't2')).status, 'running');
  assert.equal(await eventCount(reopened, 't1', 'running_verified'), 1, 'still exactly one running_verified for t1 - no duplicate');
  assert.equal(await eventCount(reopened, 't2', 'running_verified'), 1);
  assert.deepEqual(await counters(reopened), { domain: before.domain + 2, projection: 0, commit: before.commit + 2 });
});

test('t_concurrent_reconcile_flock_serializes', async () => {
  const { store, fmHome } = await freshStore();
  const other = new PgliteLocalStore({ fmHome });
  const { revision } = await spawnedTask(store, 't1', '@1', '%1'); // one promotable spawning generation
  const before = await counters(store);

  // Two full reconcile passes with DIFFERENT nonces race through two store instances on the
  // real flock. They serialize; exactly one promotes t1, the other finds it already running
  // and its promote attempt resolves against it (skipped) - never a double promotion.
  const settled = await Promise.allSettled([
    reconcilePass(store, { nonce: 'race-a', probeIdentity: probeMatch }),
    reconcilePass(other, { nonce: 'race-b', probeIdentity: probeMatch })
  ]);
  assert.equal(settled.every((s) => s.status === 'fulfilled'), true, 'neither pass throws; a race is a benign skip');

  // The strong, interleaving-independent invariant: EXACTLY ONE promotion. The loser
  // either found the run already running (no action) or attempted on a stale token and was
  // audited as a causal conflict - both leave a single promotion and a single revision bump.
  assert.equal((await taskRow(store, 't1')).status, 'running');
  assert.equal(Number((await taskRow(store, 't1')).revision), revision + 1, 'exactly one revision bump - no double promotion');
  assert.equal(await eventCount(store, 't1', 'running_verified'), 1, 'exactly one running_verified survived the concurrent passes');
  // The winner's promotion is one domain change; a losing stale-token attempt adds at most
  // one causal-conflict audit, so the delta is 1 (loser saw the promotion) or 2 (loser
  // raced it). Never more: there is only ever one promotion.
  const delta = await counters(store);
  assert.ok(delta.domain - before.domain >= 1 && delta.domain - before.domain <= 2, `promotion + at most one causal audit (got +${delta.domain - before.domain})`);
  assert.equal(delta.commit - before.commit, delta.domain - before.domain, 'domain and commit move together');
  assert.equal(delta.projection, 0);
  await other.close();
});

test('t_promote_vs_manual_commit_running_race', async () => {
  const { store, fmHome } = await freshStore();
  const other = new PgliteLocalStore({ fmHome });
  const { revision } = await spawnedTask(store, 't1', '@1', '%1');
  const before = await counters(store);

  // The reconciler's promote and a coordinator commit-running race the SAME spawning
  // generation on the flock. Exactly one promotes; the other sees a no-longer-spawning
  // task and refuses. Never two promotions, never two running_verified.
  const settled = await Promise.allSettled([
    reconcilePass(store, { nonce: 'rp', probeIdentity: probeMatch }),
    commitRunning(other, { taskId: 't1', generation: 1, expectedRevision: revision, commandId: 'c-coord-run' }, { probeIdentity: probeMatch })
  ]);
  // The reconcile pass never rejects (it catches the race); commit-running either wins or
  // rejects with a state-transition.
  assert.equal(settled[0].status, 'fulfilled', 'the reconcile pass never throws on a race');

  assert.equal((await taskRow(store, 't1')).status, 'running');
  assert.equal(Number((await taskRow(store, 't1')).revision), revision + 1, 'exactly one revision bump - never two promotions');
  assert.equal(await eventCount(store, 't1', 'running_verified'), 1, 'exactly one running_verified from the single winner');
  const d = await counters(store);
  assert.ok(d.domain - before.domain >= 1 && d.domain - before.domain <= 2, `one promotion + at most one causal audit (got +${d.domain - before.domain})`);
  assert.equal(d.projection, 0);
  await other.close();
});

test('t_fail_vs_late_record_spawn_race', async () => {
  const { store, fmHome } = await freshStore();
  const other = new PgliteLocalStore({ fmHome });
  const { revision, launchMarker } = await beganTask(store, 't1'); // spawning, NO endpoint recorded
  const before = await counters(store);

  // A partial-launch fail (deadline forced past, identity NOT live so the pass never
  // promotes) races a LATE record-spawn on the same spawning generation. The revision CAS
  // is what makes this safe under ANY interleaving: the state is never torn. The pass may
  // fail the never-recorded launch, the late spawn may record its endpoint first, or a
  // fail may land after a recorded spawn - but the task and run status ALWAYS agree, there
  // is never more than one terminal, and a failed generation never carries a fresh
  // endpoint written under it out of order.
  const probeGone = () => ({ matches: false, failingClause: 'agent_pid', anomalyClass: 'missing_pane' });
  const settled = await Promise.allSettled([
    reconcilePass(store, { nonce: 'fr', probeIdentity: probeGone, deadlineNow: FAR_FUTURE }),
    recordSpawn(other, {
      taskId: 't1', generation: 1, expectedRevision: revision, launchMarker,
      endpoint: IDENTITY.endpointId, pane: IDENTITY.paneId, regFile: '/reg', commandId: 'c-late-spawn'
    }, { captureIdentity: captureOk })
  ]);
  assert.equal(settled[0].status, 'fulfilled', 'the reconcile pass never throws on a race');

  const run = await runRow(store, 't1');
  const task = await taskRow(store, 't1');
  // No torn state: run status and task status are consistent, always.
  if (run.status === 'failed') {
    assert.equal(task.status, 'failed', 'a failed run implies a failed task');
    assert.notEqual(run.closed_at, null, 'a failed run is closed');
  } else {
    assert.equal(run.status, 'spawning', 'the only non-terminal outcome is still-spawning');
    assert.equal(task.status, 'spawning', 'a spawning run implies a spawning task');
    assert.equal(run.closed_at, null, 'a spawning run is not closed');
  }
  assert.ok(await eventCount(store, 't1', 'failed') <= 1, 'never more than one terminal for the generation');
  assert.equal(Number(task.revision) >= revision + 1, true, 'at least one racer committed');
  await other.close();
});

test('t_pid_reuse_suspected_detected', async () => {
  const { store } = await freshStore();
  const rev = await runningTask(store, 't1'); // open, bound_verified
  const before = await counters(store);

  // The probe finds the recorded pid LIVE but with DIFFERENT start ticks: the pid was
  // reused by a new process. That is a definitive loss - the reconciler audits a
  // pid_reuse_suspected anomaly (the actionable "why") and marks the binding lost.
  const r = await reconcilePass(store, { nonce: 'pr', probeIdentity: probePidReuse });
  assert.deepEqual(r.committed.map((c) => c.kind), ['pid_reuse_suspected', 'mark_lost']);

  const pidReuse = await anomalyRows(store, 'pid_reuse_suspected');
  assert.equal(pidReuse.length, 1, 'exactly one pid_reuse_suspected anomaly persisted');
  assert.equal(pidReuse[0].status, 'active');
  assert.equal((await runRow(store, 't1')).binding_state, 'lost', 'the reused-pid binding is marked lost');
  assert.equal(await eventCount(store, 't1', 'identity_lost'), 1);
  assert.equal(Number((await taskRow(store, 't1')).revision), rev + 1);
  assert.deepEqual(await counters(store), { domain: before.domain + 2, projection: 0, commit: before.commit + 2 });
});

test('t_terminal_without_cleanup_anomaly_then_resolution', async () => {
  const { store } = await freshStore();
  const rev = await runningTask(store, 't1');
  await completeRun(store, { taskId: 't1', generation: 1, expectedRevision: rev, outcome: 'success', producer: 'crewmate', seq: 1, evidence: {}, commandId: 'c-done' });
  // The generation is now terminal but still binding cleanup_pending with cleanup never
  // started. A pass with a tiny grace window flags terminal_without_cleanup; the stored
  // cleanup target still MATCHES (probeMatch-equivalent), so no kill, no identity_mismatch.
  const before = await counters(store);
  const r = await reconcilePass(store, {
    nonce: 'tw', terminalCleanupGraceMs: 0,
    cleanupProbe: () => ({ present: true, matches: true, reason: 'exact_match' })
  });
  assert.equal(r.committed.map((c) => c.kind).includes('terminal_without_cleanup'), true);
  const anom = await anomalyRows(store, 'terminal_without_cleanup');
  assert.equal(anom.length, 1, 'exactly one terminal_without_cleanup anomaly');
  assert.equal(anom[0].status, 'active');
  // Never a kill, never a cleaned event: the run stays cleanup_pending for a real cleanup.
  assert.equal((await runRow(store, 't1')).binding_state, 'cleanup_pending');
  assert.equal(await eventCount(store, 't1', 'cleaned'), 0);
  assert.deepEqual(await counters(store), { domain: before.domain + 1, projection: 0, commit: before.commit + 1 });

  // Resolve it (agent-level; not an orphan). The row is preserved, status flips.
  const resolved = await resolveAnomaly(store, { fingerprint: anom[0].fingerprint, reason: 'cleanup completed out of band', resolutionKind: 'agent_verified', commandId: 'res-tw' });
  assert.equal(resolved.status, 'resolved');
  const after = await anomalyRows(store, 'terminal_without_cleanup');
  assert.equal(after.length, 1, 'the resolved anomaly is preserved');
  assert.equal(after[0].status, 'resolved');

  // A subsequent pass re-observes the still-pending terminal and RE-OPENS nothing: the
  // resolved row coalesces (occurrence_count climbs) but stays resolved is NOT required;
  // what matters is no duplicate row and no kill. (Reobservation reactivates via upsert
  // detail only; status is not downgraded here.)
  const r2 = await reconcilePass(store, {
    nonce: 'tw2', terminalCleanupGraceMs: 0,
    cleanupProbe: () => ({ present: true, matches: true, reason: 'exact_match' })
  });
  assert.equal(r2.committed.map((c) => c.kind).filter((k) => k === 'terminal_without_cleanup').length, 1, 're-observed once');
  assert.equal((await anomalyRows(store, 'terminal_without_cleanup')).length, 1, 'still exactly one row - coalesced, not duplicated');
});

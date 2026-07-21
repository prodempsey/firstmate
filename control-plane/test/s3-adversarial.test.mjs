import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { runExclusive } from '../lib/internal-runtime.mjs';
import { createTask, beginRun } from '../lib/domain-store.mjs';
import { completeRun } from '../lib/domain-store-s2.mjs';
import { CausalOrderingError, StateTransitionError } from '../lib/errors-s1.mjs';
import { IdentityMismatchError } from '../lib/errors-s3.mjs';
import {
  recordSpawn, commitRunning, verifyRunning, cleanupIntent, cleanupFinish, recordCleanupMismatch
} from '../lib/domain-store-s3.mjs';
import { mkFixtureHome, cleanupAll } from './helpers.mjs';

// Adversarial S3: what happens when a spawn/cleanup writer crashes mid-bundle, when two
// record-spawns race, when a generation is committed from the wrong state, and - the
// point of the whole slice - when the endpoint has DIED by the time commit-running runs.
// The invariant under attack is the anti-ghost guarantee: promotion to running is gated
// on a LIVE identity match at commit time, and each lifecycle write is one atomic commit.
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
const probeDead = (clause = 'agent_pid', anomalyClass = 'missing_pane') =>
  () => ({ matches: false, failingClause: clause, anomalyClass });

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
  const r = await rows(
    store, 'SELECT domain_revision, projection_revision, commit_sequence FROM coordinator_state WHERE id = 1'
  );
  return { domain: Number(r[0].domain_revision), projection: Number(r[0].projection_revision), commit: Number(r[0].commit_sequence) };
}

async function runRow(store, taskId, generation = 1) {
  const r = await rows(
    store,
    `SELECT status, binding_state, cleanup_state, closed_at, endpoint_id, verified_at, cleanup_finished_at
       FROM runs WHERE task_id = $1 AND run_generation = $2`,
    [taskId, generation]
  );
  return r[0];
}

async function taskRow(store, taskId) {
  const r = await rows(store, 'SELECT status, revision FROM tasks WHERE task_id = $1', [taskId]);
  return r[0];
}

async function eventCount(store, taskId, type) {
  const r = await rows(
    store, 'SELECT count(*)::int AS n FROM task_events WHERE task_id = $1 AND event_type = $2', [taskId, type]
  );
  return Number(r[0].n);
}

async function anomalies(store, cls) {
  return rows(
    store,
    'SELECT anomaly_class, task_id, run_generation, occurrence_count, status FROM anomalies WHERE anomaly_class = $1',
    [cls]
  );
}

// ---- lifecycle builders ----

async function beganTask(store, taskId = 't1') {
  await createTask(store, {
    taskId, kind: 'ship', title: 'x', origin: 'internal', internalReason: 'r', commandId: `c-create-${taskId}`
  });
  const beg = await beginRun(store, { taskId, expectedRevision: 1, commandId: `c-begin-${taskId}` });
  return { revision: beg.revision, launchMarker: beg.launch_marker };
}

async function spawnedTask(store, taskId = 't1') {
  const { revision, launchMarker } = await beganTask(store, taskId);
  const rs = await recordSpawn(store, {
    taskId, generation: 1, expectedRevision: revision, launchMarker,
    endpoint: IDENTITY.endpointId, pane: IDENTITY.paneId, regFile: '/reg', commandId: `c-spawn-${taskId}`
  }, { captureIdentity: captureOk });
  return rs.revision;
}

async function runningTask(store, taskId = 't1') {
  const rev = await spawnedTask(store, taskId);
  const cr = await commitRunning(store, { taskId, generation: 1, expectedRevision: rev, commandId: `c-run-${taskId}` }, { probeIdentity: probeMatch });
  return cr.revision;
}

async function cleanupPendingTask(store, taskId = 't1') {
  const rev = await runningTask(store, taskId);
  const done = await completeRun(store, {
    taskId, generation: 1, expectedRevision: rev, outcome: 'success', producer: 'crewmate', seq: 1, evidence: {}, commandId: `c-done-${taskId}`
  });
  return done.revision;
}

test('t_endpoint_death_detected_at_commit_running_not_ghost', async () => {
  const { store } = await freshStore();
  const rev = await spawnedTask(store, 't1'); // endpoint recorded, run spawning
  const before = await counters(store);

  // THE anti-ghost gate: the endpoint died between record-spawn and commit-running.
  // commit-running must REFUSE to promote and leave the run exactly as spawning.
  await assert.rejects(
    () => commitRunning(store, { taskId: 't1', generation: 1, expectedRevision: rev, commandId: 'c-run-dead' }, { probeIdentity: probeDead('agent_pid', 'missing_pane') }),
    (e) => e instanceof IdentityMismatchError
      && e.code === 'identity_mismatch'
      && e.detail.failing_clause === 'agent_pid',
    'a dead endpoint at commit time is an identity mismatch, never a promotion'
  );

  // Nothing was promoted: the run is STILL spawning, the binding is STILL spawning, and
  // there is no running_verified event. A dead crew can never surface as a live card.
  const run = await runRow(store, 't1');
  assert.equal(run.status, 'spawning', 'the run stayed spawning - no ghost open run');
  assert.equal(run.binding_state, 'spawning', 'the binding was not advanced to bound_verified');
  assert.equal(run.verified_at, null);
  const task = await taskRow(store, 't1');
  assert.equal(task.status, 'spawning', 'the task stayed spawning');
  assert.equal(Number(task.revision), rev, 'the task revision did NOT advance (the audit does not bump task revision)');
  assert.equal(await eventCount(store, 't1', 'running_verified'), 0, 'no running_verified event was written');

  // The rejection IS audited: mutation rolled back, one anomaly persisted, domain+commit
  // each advance by exactly one.
  assert.deepEqual(
    await counters(store),
    { domain: before.domain + 1, projection: 0, commit: before.commit + 1 },
    'the identity conflict audit is one domain change; projection stays 0'
  );
  const anom = await anomalies(store, 'missing_pane');
  assert.equal(anom.length, 1, 'exactly one missing_pane anomaly persisted');
  assert.equal(anom[0].task_id, 't1');
  assert.equal(Number(anom[0].run_generation), 1);

  // verify-running agrees: not running_verified.
  const vr = await verifyRunning(store, { taskId: 't1', generation: 1 }, { probeIdentity: probeDead('agent_pid') });
  assert.equal(vr.running_verified, false);

  // The gate is REAL, not a permanent block: once the identity is live again (same
  // stored revision, a fresh command-id), commit-running promotes normally.
  const ok = await commitRunning(store, { taskId: 't1', generation: 1, expectedRevision: rev, commandId: 'c-run-live' }, { probeIdentity: probeMatch });
  assert.equal(ok.status, 'running');
  assert.equal(ok.revision, rev + 1);
  assert.equal((await runRow(store, 't1')).binding_state, 'bound_verified');
});

test('t_crash_between_record_spawn_and_commit_running', async () => {
  const { store, fmHome } = await freshStore();
  const rev = await spawnedTask(store, 't1'); // endpoint recorded, run spawning
  const before = await counters(store);
  await store.close();

  // A REAL writer-exit: a child hard-exits mid commit-running transaction (after the
  // promotion writes, before COMMIT). The OS releases the flock; on reopen PGlite crash
  // recovery must show the run STILL spawning - never a half-promoted ghost.
  const worker = fileURLToPath(new URL('./workers/crash-spawn-writer.mjs', import.meta.url));
  const child = spawnSync(process.execPath, [worker], {
    env: { ...process.env, CP_FM_HOME: fmHome, CP_TASK_ID: 't1', CP_GENERATION: '1', CP_EXPECTED_REVISION: String(rev), CP_COMMAND_ID: 'c-run-child' },
    encoding: 'utf8', timeout: 60000
  });
  assert.equal(child.status, 43, `commit-running writer must hard-exit mid-transaction (stderr: ${child.stderr})`);

  const reopened = new PgliteLocalStore({ fmHome });
  const run = await runRow(reopened, 't1');
  assert.equal(run.status, 'spawning', 'the exited writer left the run spawning - no ghost open run');
  assert.equal(run.binding_state, 'spawning');
  assert.equal(run.verified_at, null);
  assert.equal(await eventCount(reopened, 't1', 'running_verified'), 0, 'no running_verified event survived the crash');
  assert.deepEqual(await counters(reopened), before, 'counters unchanged across the writer exit');
  const ghost = await rows(reopened, "SELECT count(*)::int AS n FROM command_results WHERE command_id = 'c-run-child'");
  assert.equal(Number(ghost[0].n), 0, 'no command_results ghost from the exited writer');

  // The sequence recovers: a retry with a live probe promotes to running exactly once.
  const ok = await commitRunning(reopened, { taskId: 't1', generation: 1, expectedRevision: rev, commandId: 'c-run-retry' }, { probeIdentity: probeMatch });
  assert.equal(ok.status, 'running');
  assert.equal(ok.revision, rev + 1);
  assert.deepEqual(await counters(reopened), { domain: before.domain + 1, projection: 0, commit: before.commit + 1 });
});

test('t_commit_running_on_non_spawning_conflicts', async () => {
  const { store } = await freshStore();
  const rev = await runningTask(store, 't1'); // already running
  const before = await counters(store);

  // commit-running requires a spawning task. A task that is already running cannot be
  // committed again, even with a current revision and a fresh command-id.
  await assert.rejects(
    () => commitRunning(store, { taskId: 't1', generation: 1, expectedRevision: rev, commandId: 'c-run-again' }, { probeIdentity: probeMatch }),
    (e) => e.code === 'state_transition' && /requires a spawning task/.test(e.message),
    'commit-running on an already-running task is refused'
  );
  assert.equal((await taskRow(store, 't1')).status, 'running');
  assert.equal(Number((await taskRow(store, 't1')).revision), rev, 'the refusal did not advance the revision');

  // And a terminal generation is equally uncommittable.
  const done = await completeRun(store, {
    taskId: 't1', generation: 1, expectedRevision: rev, outcome: 'success', producer: 'crewmate', seq: 1, evidence: {}, commandId: 'c-done'
  });
  await assert.rejects(
    () => commitRunning(store, { taskId: 't1', generation: 1, expectedRevision: done.revision, commandId: 'c-run-terminal' }, { probeIdentity: probeMatch }),
    (e) => e.code === 'state_transition',
    'commit-running on a terminal generation is refused'
  );

  // Neither refusal is an audited conflict: nothing persisted beyond the legitimate
  // complete between them.
  assert.deepEqual(
    await counters(store),
    { domain: before.domain + 1, projection: 0, commit: before.commit + 1 },
    'only the legitimate complete moved counters; the two refusals wrote nothing'
  );
});

test('t_concurrent_record_spawn_serializes', async () => {
  const { store, fmHome } = await freshStore();
  const other = new PgliteLocalStore({ fmHome });
  const { revision, launchMarker } = await beganTask(store, 't1');

  // Two record-spawn commands race on the same began generation with the same causal
  // token, through two independent store instances contending on the real flock.
  const args = (commandId) => ({
    taskId: 't1', generation: 1, expectedRevision: revision, launchMarker,
    endpoint: IDENTITY.endpointId, pane: IDENTITY.paneId, regFile: '/reg', commandId
  });
  const settled = await Promise.allSettled([
    recordSpawn(store, args('c-a'), { captureIdentity: captureOk }),
    recordSpawn(other, args('c-b'), { captureIdentity: captureOk })
  ]);
  const fulfilled = settled.filter((s) => s.status === 'fulfilled');
  const rejected = settled.filter((s) => s.status === 'rejected');
  assert.equal(fulfilled.length, 1, 'exactly one record-spawn wins');
  assert.equal(rejected.length, 1, 'exactly one record-spawn loses');
  // The loser acted on a revision the winner already advanced: a causal conflict.
  assert.ok(rejected[0].reason instanceof CausalOrderingError, `the loser is a causal conflict (got ${rejected[0].reason})`);

  // The winner recorded the endpoint and emitted exactly one spawned event; the task
  // advanced by exactly one revision; the loser's conflict is audited once.
  const run = await runRow(store, 't1');
  assert.equal(run.endpoint_id, IDENTITY.endpointId);
  assert.equal(await eventCount(store, 't1', 'spawned'), 1, 'exactly one spawned event survived the race');
  assert.equal(Number((await taskRow(store, 't1')).revision), revision + 1, 'the task advanced by exactly one revision');
  const anom = await anomalies(store, 'causal_ordering_violation');
  assert.equal(anom.length, 1, 'the losing command left exactly one causal anomaly');
  await other.close();
});

test('t_cleanup_saga_atomic', async () => {
  const { store } = await freshStore();
  const rev = await cleanupPendingTask(store, 't1'); // binding cleanup_pending
  const before = await counters(store);

  // cleanup-intent is atomic under an in-process crash cut: a fault after the domain
  // bundle rolls the WHOLE bundle back - no intent, no cleanup_started, no counter move.
  await assert.rejects(
    () => cleanupIntent(store, { taskId: 't1', generation: 1, expectedRevision: rev, commandId: 'c-intent-crash' }, { fault: () => { throw new Error('crash after cleanup-intent bundle'); } }),
    /crash after cleanup-intent bundle/
  );
  let run = await runRow(store, 't1');
  assert.equal(run.cleanup_state, 'not_started', 'the crashed cleanup-intent left cleanup_state untouched');
  assert.equal(run.binding_state, 'cleanup_pending');
  assert.equal(await eventCount(store, 't1', 'cleanup_started'), 0);
  assert.deepEqual(await counters(store), before, 'the crashed cleanup-intent moved no counter');

  // A clean cleanup-intent then commits, and cleanup-finish is equally atomic under a cut.
  const intent = await cleanupIntent(store, { taskId: 't1', generation: 1, expectedRevision: rev, commandId: 'c-intent' });
  const afterIntent = await counters(store);
  await assert.rejects(
    () => cleanupFinish(store, { taskId: 't1', generation: 1, expectedRevision: intent.revision, effectResult: { confirmed_absent: true }, commandId: 'c-finish-crash' }, { fault: () => { throw new Error('crash after cleanup-finish bundle'); } }),
    /crash after cleanup-finish bundle/
  );
  run = await runRow(store, 't1');
  assert.equal(run.cleanup_state, 'intent_committed', 'the crashed cleanup-finish left cleanup_state at intent_committed');
  assert.equal(run.binding_state, 'cleanup_pending', 'the binding was not closed by the crashed finish');
  assert.equal(await eventCount(store, 't1', 'cleaned'), 0);
  assert.deepEqual(await counters(store), afterIntent, 'the crashed cleanup-finish moved no counter');

  // The clean retry commits the finish exactly once.
  const done = await cleanupFinish(store, { taskId: 't1', generation: 1, expectedRevision: intent.revision, effectResult: { confirmed_absent: true }, commandId: 'c-finish' });
  assert.equal(done.binding_state, 'closed');
  assert.equal((await runRow(store, 't1')).cleanup_state, 'cleaned');
  assert.deepEqual(await counters(store), { domain: afterIntent.domain + 1, projection: 0, commit: afterIntent.commit + 1 });
});

test('t_cleanup_crash_cuts_recover', async () => {
  const { store, fmHome } = await freshStore();
  const rev = await cleanupPendingTask(store, 't1');
  const intent = await cleanupIntent(store, { taskId: 't1', generation: 1, expectedRevision: rev, commandId: 'c-intent' });
  const before = await counters(store);
  await store.close();

  // A REAL writer-exit mid cleanup-finish (after the domain writes, before COMMIT). On
  // reopen the cleanup must still read intent_committed - the saga's crash-cut recovery.
  const worker = fileURLToPath(new URL('./workers/crash-cleanup-writer.mjs', import.meta.url));
  const child = spawnSync(process.execPath, [worker], {
    env: { ...process.env, CP_FM_HOME: fmHome, CP_TASK_ID: 't1', CP_GENERATION: '1', CP_EXPECTED_REVISION: String(intent.revision), CP_COMMAND_ID: 'c-finish-child' },
    encoding: 'utf8', timeout: 60000
  });
  assert.equal(child.status, 47, `cleanup-finish writer must hard-exit mid-transaction (stderr: ${child.stderr})`);

  const reopened = new PgliteLocalStore({ fmHome });
  let run = await runRow(reopened, 't1');
  assert.equal(run.cleanup_state, 'intent_committed', 'the exited writer left cleanup_state at intent_committed');
  assert.equal(run.binding_state, 'cleanup_pending', 'the binding was not closed by the crash');
  assert.equal(await eventCount(reopened, 't1', 'cleaned'), 0, 'no cleaned event survived the crash');
  assert.deepEqual(await counters(reopened), before, 'counters unchanged across the writer exit');
  const ghost = await rows(reopened, "SELECT count(*)::int AS n FROM command_results WHERE command_id = 'c-finish-child'");
  assert.equal(Number(ghost[0].n), 0, 'no command_results ghost from the exited writer');

  // Reconciliation reruns cleanup-finish from the committed intent; it commits cleaned.
  const done = await cleanupFinish(reopened, { taskId: 't1', generation: 1, expectedRevision: intent.revision, effectResult: { confirmed_absent: true }, commandId: 'c-finish-retry' });
  assert.equal(done.binding_state, 'closed');
  run = await runRow(reopened, 't1');
  assert.equal(run.cleanup_state, 'cleaned');
  assert.equal(run.binding_state, 'closed');
  assert.deepEqual(await counters(reopened), { domain: before.domain + 1, projection: 0, commit: before.commit + 1 });
});

test('t_cleanup_mismatch_records_anomaly', async () => {
  const { store } = await freshStore();
  const rev = await cleanupPendingTask(store, 't1');
  const intent = await cleanupIntent(store, { taskId: 't1', generation: 1, expectedRevision: rev, commandId: 'c-intent' });
  const before = await counters(store);

  // The adapter's cleanup effect refused to kill a materially mismatched target
  // (killExactPane returns matches:false). Recording the mismatch persists an
  // identity_mismatch anomaly through the audit path so the reconciler (S5) can see it -
  // while performing NO kill and NO domain change beyond the audit.
  const mismatchProbe = () => ({ present: true, matches: false, reason: 'pane_start_mismatch' });
  await assert.rejects(
    () => recordCleanupMismatch(store, { taskId: 't1', generation: 1, expectedRevision: intent.revision, commandId: 'c-mismatch' }, { cleanupProbe: mismatchProbe }),
    (e) => e instanceof IdentityMismatchError && e.detail.reason === 'cleanup_target_mismatch' && e.detail.cleanup_reason === 'pane_start_mismatch',
    'a cleanup target mismatch surfaces as IdentityMismatchError'
  );

  // The anomaly is durably persisted - mutation-sensitive on the row itself.
  const anom = await anomalies(store, 'identity_mismatch');
  assert.equal(anom.length, 1, 'exactly one identity_mismatch anomaly persisted for the cleanup mismatch');
  assert.equal(anom[0].task_id, 't1');
  assert.equal(Number(anom[0].run_generation), 1);
  assert.equal(anom[0].status, 'active');

  // No kill, no cleaned: the run stays intent_committed / cleanup_pending for a real
  // cleanup or the reconciler. The audit advances domain+commit once and never touches
  // task revision or projection_revision.
  const run = await runRow(store, 't1');
  assert.equal(run.cleanup_state, 'intent_committed');
  assert.equal(run.binding_state, 'cleanup_pending');
  assert.equal(await eventCount(store, 't1', 'cleaned'), 0, 'no cleaned event from a mismatch');
  assert.deepEqual(await counters(store), { domain: before.domain + 1, projection: 0, commit: before.commit + 1 });
  assert.equal(Number((await taskRow(store, 't1')).revision), intent.revision, 'the audit did not bump task revision');

  // A target that actually MATCHES records nothing: a caller cannot fabricate an anomaly
  // for a healthy target.
  const before2 = await counters(store);
  await assert.rejects(
    () => recordCleanupMismatch(store, { taskId: 't1', generation: 1, expectedRevision: intent.revision, commandId: 'c-nomatch' }, { cleanupProbe: () => ({ present: true, matches: true, reason: 'exact_match' }) }),
    (e) => e instanceof StateTransitionError && /no identity mismatch to record/.test(e.message),
    'a matching target records no anomaly'
  );
  assert.equal((await anomalies(store, 'identity_mismatch')).length, 1, 'no second anomaly for a matching target');
  assert.deepEqual(await counters(store), before2, 'the no-mismatch refusal wrote nothing');
});

test('t_cleanup_finish_rejects_unconfirmed_effect', async () => {
  const { store } = await freshStore();
  const rev = await cleanupPendingTask(store, 't1');
  const intent = await cleanupIntent(store, { taskId: 't1', generation: 1, expectedRevision: rev, commandId: 'c-intent' });
  const before = await counters(store);

  // An effect that did NOT confirm the endpoint gone must be REFUSED. Turning an
  // unsuccessful cleanup (a failed kill, an identity mismatch, a malformed result) into
  // a canonical `cleaned/closed` would orphan a live endpoint while the DB claims the
  // binding is closed (qa-s3-q58 finding 4).
  const badEffects = [
    { killed: false, confirmed_absent: false, reason: 'identity_mismatch' },
    { killed: true, confirmed_absent: false, reason: 'kill_pane_failed' },
    { confirmed_absent: 'true' }, // wrong type: not the boolean true
    { killed: true }, // absent confirmed_absent
    {},
    null
  ];
  let i = 0;
  for (const bad of badEffects) {
    i += 1;
    await assert.rejects(
      () => cleanupFinish(store, { taskId: 't1', generation: 1, expectedRevision: intent.revision, effectResult: bad, commandId: `c-bad-${i}` }),
      (e) => e instanceof StateTransitionError && /confirmed_absent === true/.test(e.message),
      `cleanup-finish must refuse an unconfirmed effect ${JSON.stringify(bad)}`
    );
  }

  // Every refusal wrote nothing: the run stays intent_committed / cleanup_pending for a
  // real cleanup or the reconciler, with no cleaned event and no counter movement.
  const run = await runRow(store, 't1');
  assert.equal(run.cleanup_state, 'intent_committed');
  assert.equal(run.binding_state, 'cleanup_pending');
  assert.equal(await eventCount(store, 't1', 'cleaned'), 0, 'no cleaned event survived any refusal');
  assert.deepEqual(await counters(store), before, 'the refusals wrote nothing');

  // A confirmed-absent effect then commits normally, proving the guard is a real test of
  // the effect result rather than a blanket block.
  const ok = await cleanupFinish(store, { taskId: 't1', generation: 1, expectedRevision: intent.revision, effectResult: { killed: true, confirmed_absent: true }, commandId: 'c-ok' });
  assert.equal(ok.binding_state, 'closed');
  assert.equal((await runRow(store, 't1')).cleanup_state, 'cleaned');
});

test('t_cleanup_finish_idempotent_on_already_cleaned', async () => {
  const { store } = await freshStore();
  const rev = await cleanupPendingTask(store, 't1');
  const intent = await cleanupIntent(store, { taskId: 't1', generation: 1, expectedRevision: rev, commandId: 'c-intent' });
  const effect = { killed: true, confirmed_absent: true };
  const done = await cleanupFinish(store, { taskId: 't1', generation: 1, expectedRevision: intent.revision, effectResult: effect, commandId: 'c-finish' });
  const afterFirst = await counters(store);

  // Replaying the identical cleanup-finish is an idempotent replay of the stored clean
  // result: no second cleaned event, no counter movement, binding stays closed.
  for (let i = 0; i < 3; i += 1) {
    const replay = await cleanupFinish(store, { taskId: 't1', generation: 1, expectedRevision: intent.revision, effectResult: effect, commandId: 'c-finish' });
    assert.deepEqual(replay, done, 'every replay returns the identical stored clean result');
  }
  assert.equal(await eventCount(store, 't1', 'cleaned'), 1, 'the replays produced no second cleaned event');
  assert.equal((await runRow(store, 't1')).binding_state, 'closed', 'the binding stayed closed');
  assert.deepEqual(await counters(store), afterFirst, 'a replay is not a write and bumps nothing');
});

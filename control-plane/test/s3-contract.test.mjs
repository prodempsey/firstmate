import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { runExclusive } from '../lib/internal-runtime.mjs';
import { runVerb } from '../lib/coordinator.mjs';
import { ValidationError } from '../lib/errors.mjs';
import { StateTransitionError } from '../lib/errors-s1.mjs';
import { createTask, beginRun } from '../lib/domain-store.mjs';
import { completeRun } from '../lib/domain-store-s2.mjs';
import {
  recordSpawn, commitRunning, verifyRunning, cleanupIntent, cleanupFinish
} from '../lib/domain-store-s3.mjs';
import { AUDIT_ONLY_EVENT_TYPES, isDeliverable } from '../lib/delivery-policy.mjs';
import { mkFixtureHome, cleanupAll } from './helpers.mjs';

// S3 owns the spawn/running/cleanup lifecycle verbs (spec-amend-s4 section 12, S3 row).
// No test here uses a table or verb owned by a later slice, projection_revision must
// stay 0 throughout (projections are S6), and every S3 lifecycle event is audit-only:
// the outbox count never moves under any S3 verb.
after(cleanupAll);

// A deterministic identity double standing in for the real /proc + tmux probes. Tests
// inject it so the domain layer's determinism is measured without touching a real host.
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

// Outbox rows for a task, tolerating an outbox table that does not exist yet (before any
// S2 verb has run there is no outbox at all - the strongest form of "nothing delivered").
async function outboxCount(store, taskId) {
  return runExclusive(store, async (conn) => {
    const reg = await conn.query("SELECT to_regclass('public.outbox') AS reg");
    if (reg.rows[0].reg === null) return 0;
    const r = await conn.query('SELECT count(*)::int AS n FROM outbox WHERE task_id = $1', [taskId]);
    return Number(r.rows[0].n);
  });
}

async function eventTypes(store, taskId) {
  const r = await rows(
    store, 'SELECT event_type FROM task_events WHERE task_id = $1 ORDER BY producer_seq, created_at', [taskId]
  );
  return r.map((x) => x.event_type);
}

async function runRow(store, taskId, generation = 1) {
  const r = await rows(
    store,
    `SELECT status, binding_state, cleanup_state, closed_at, endpoint_id, pane_id, pane_leader_pid,
            agent_pid, verified_at, cleanup_started_at, cleanup_finished_at
       FROM runs WHERE task_id = $1 AND run_generation = $2`,
    [taskId, generation]
  );
  return r[0];
}

async function taskRow(store, taskId) {
  const r = await rows(store, 'SELECT status, revision FROM tasks WHERE task_id = $1', [taskId]);
  return r[0];
}

// ---- lifecycle builders (each returns the current task revision) ----

async function beganTask(store, taskId = 't1') {
  await createTask(store, {
    taskId, kind: 'ship', title: 'x', origin: 'internal', internalReason: 'r', commandId: `c-create-${taskId}`
  });
  const beg = await beginRun(store, { taskId, expectedRevision: 1, commandId: `c-begin-${taskId}` });
  return { revision: beg.revision, launchMarker: beg.launch_marker }; // revision 2
}

async function spawnedTask(store, taskId = 't1') {
  const { revision, launchMarker } = await beganTask(store, taskId);
  const rs = await recordSpawn(store, {
    taskId, generation: 1, expectedRevision: revision, launchMarker,
    endpoint: IDENTITY.endpointId, pane: IDENTITY.paneId, regFile: '/reg', commandId: `c-spawn-${taskId}`
  }, { captureIdentity: captureOk });
  return rs.revision; // 3
}

async function runningTask(store, taskId = 't1') {
  const rev = await spawnedTask(store, taskId);
  const cr = await commitRunning(store, {
    taskId, generation: 1, expectedRevision: rev, commandId: `c-run-${taskId}`
  }, { probeIdentity: probeMatch });
  return cr.revision; // 4
}

// running -> completed, leaving the terminal run in binding cleanup_pending (a stored
// endpoint remains for the cleanup saga). The terminal `complete` is S2 (already landed).
async function cleanupPendingTask(store, taskId = 't1') {
  const rev = await runningTask(store, taskId);
  const done = await completeRun(store, {
    taskId, generation: 1, expectedRevision: rev, outcome: 'success', producer: 'crewmate', seq: 1, evidence: {},
    commandId: `c-done-${taskId}`
  });
  return done.revision; // 5
}

test('t_record_spawn_records_endpoint_and_spawned_audit_only', async () => {
  const { store } = await freshStore();
  const { revision, launchMarker } = await beganTask(store, 't1');
  const before = await counters(store);

  const res = await recordSpawn(store, {
    taskId: 't1', generation: 1, expectedRevision: revision, launchMarker,
    endpoint: IDENTITY.endpointId, pane: IDENTITY.paneId, regFile: '/reg', commandId: 'c-spawn'
  }, { captureIdentity: captureOk });

  assert.equal(res.status, 'spawning', 'record-spawn leaves the task spawning');
  assert.equal(res.binding_state, 'spawning', 'binding stays spawning; verification is commit-running (ruling Q4)');
  assert.equal(res.endpoint_id, IDENTITY.endpointId);
  assert.equal(res.revision, revision + 1);

  // The endpoint and /proc identity tuple landed, and the binding did NOT advance.
  const run = await runRow(store, 't1');
  assert.equal(run.status, 'spawning');
  assert.equal(run.binding_state, 'spawning');
  assert.equal(run.endpoint_id, IDENTITY.endpointId);
  assert.equal(run.pane_id, IDENTITY.paneId);
  assert.equal(Number(run.pane_leader_pid), IDENTITY.paneLeaderPid);
  assert.equal(Number(run.agent_pid), IDENTITY.agentPid);
  assert.equal(run.verified_at, null, 'record-spawn does not verify (no verified_at)');

  // The spawned event is durable and AUDIT-ONLY: present in task_events, no outbox row.
  assert.deepEqual(await eventTypes(store, 't1'), ['created', 'spawn_intent', 'spawned']);
  assert.equal(await outboxCount(store, 't1'), 0, 'spawned creates no outbox row');
  assert.equal(isDeliverable('spawned'), false, 'the delivery policy classifies spawned audit-only');

  // Exactly one domain change; projection untouched (S6).
  assert.deepEqual(
    await counters(store),
    { domain: before.domain + 1, projection: 0, commit: before.commit + 1 },
    'record-spawn advances domain+commit by exactly one and never projection_revision'
  );
});

test('t_commit_running_promotes_on_identity_match', async () => {
  const { store } = await freshStore();
  const rev = await spawnedTask(store, 't1'); // revision 3
  const before = await counters(store);

  const res = await commitRunning(store, {
    taskId: 't1', generation: 1, expectedRevision: rev, commandId: 'c-run'
  }, { probeIdentity: probeMatch });

  assert.equal(res.status, 'running');
  assert.equal(res.run_status, 'open');
  assert.equal(res.binding_state, 'bound_verified');
  assert.equal(res.revision, rev + 1);

  const task = await taskRow(store, 't1');
  assert.equal(task.status, 'running');
  assert.equal(Number(task.revision), rev + 1);
  const run = await runRow(store, 't1');
  assert.equal(run.status, 'open');
  assert.equal(run.binding_state, 'bound_verified');
  assert.notEqual(run.verified_at, null, 'commit-running stamps verified_at');

  // running_verified is durable and audit-only.
  assert.deepEqual(await eventTypes(store, 't1'), ['created', 'spawn_intent', 'spawned', 'running_verified']);
  assert.equal(await outboxCount(store, 't1'), 0, 'running_verified creates no outbox row');
  assert.equal(isDeliverable('running_verified'), false);

  assert.deepEqual(
    await counters(store),
    { domain: before.domain + 1, projection: 0, commit: before.commit + 1 },
    'commit-running is exactly one domain change; projection stays 0'
  );
});

test('t_verify_running_reports_predicate_and_failing_clause', async () => {
  const { store } = await freshStore();
  await runningTask(store, 't1'); // fully running
  const beforeVerify = await counters(store);

  // A live match: every clause of the running_verified postcondition holds.
  const ok = await verifyRunning(store, { taskId: 't1', generation: 1 }, { probeIdentity: probeMatch });
  assert.equal(ok.running_verified, true);
  assert.equal(ok.identity_matches, true);
  assert.equal(ok.failing_clause, null);
  assert.equal(ok.task_status, 'running');
  assert.equal(ok.run_status, 'open');
  assert.equal(ok.binding_state, 'bound_verified');

  // A dead endpoint: the predicate fails and names the first failing clause. verify is a
  // read - it never repairs, promotes, or demotes anything.
  const dead = await verifyRunning(store, { taskId: 't1', generation: 1 }, { probeIdentity: probeDead('agent_pid') });
  assert.equal(dead.running_verified, false);
  assert.equal(dead.identity_matches, false);
  assert.equal(dead.failing_clause, 'agent_pid');
  assert.equal(dead.task_status, 'running', 'verify-running did not change task state');

  // verify-running is a locked READ: neither call bumped a counter.
  assert.deepEqual(await counters(store), beforeVerify, 'verify-running is a read: it bumps nothing');

  // A spawning generation (never committed) is not running_verified even under a match.
  await spawnedTask(store, 't2');
  const spawning = await verifyRunning(store, { taskId: 't2', generation: 1 }, { probeIdentity: probeMatch });
  assert.equal(spawning.running_verified, false, 'a spawning generation is not running_verified');
  assert.equal(spawning.task_status, 'spawning');
});

test('t_cleanup_intent_persists_target_and_started', async () => {
  const { store } = await freshStore();
  const rev = await cleanupPendingTask(store, 't1'); // revision 5, binding cleanup_pending
  const before = await counters(store);
  const obBefore = await outboxCount(store, 't1');

  const res = await cleanupIntent(store, {
    taskId: 't1', generation: 1, expectedRevision: rev, commandId: 'c-cleanup-intent'
  });

  assert.equal(res.cleanup_state, 'intent_committed');
  assert.equal(res.binding_state, 'cleanup_pending');
  assert.equal(res.revision, rev + 1);
  // The returned target is the EXACT stored endpoint identity.
  assert.equal(res.target.endpoint_id, IDENTITY.endpointId);
  assert.equal(res.target.pane_id, IDENTITY.paneId);
  assert.equal(Number(res.target.pane_leader_pid), IDENTITY.paneLeaderPid);
  assert.equal(Number(res.target.agent_pid), IDENTITY.agentPid);

  const run = await runRow(store, 't1');
  assert.equal(run.cleanup_state, 'intent_committed');
  assert.equal(run.binding_state, 'cleanup_pending', 'the endpoint is still pending its cleanup effect');
  assert.notEqual(run.cleanup_started_at, null, 'cleanup_started_at is stamped');
  assert.equal(run.cleanup_finished_at, null);

  // cleanup_started is audit-only: it adds no delivery to the existing terminal outbox row.
  assert.equal(await outboxCount(store, 't1'), obBefore, 'cleanup_started creates no outbox row');
  assert.equal(isDeliverable('cleanup_started'), false);
  assert.equal((await eventTypes(store, 't1')).includes('cleanup_started'), true);

  assert.deepEqual(await counters(store), { domain: before.domain + 1, projection: 0, commit: before.commit + 1 });
});

test('t_cleanup_finish_closes_binding_cleaned', async () => {
  const { store } = await freshStore();
  const rev = await cleanupPendingTask(store, 't1');
  const intent = await cleanupIntent(store, { taskId: 't1', generation: 1, expectedRevision: rev, commandId: 'c-intent' });
  const before = await counters(store);
  const obBefore = await outboxCount(store, 't1');

  const effect = { killed: true, confirmed_absent: true };
  const res = await cleanupFinish(store, {
    taskId: 't1', generation: 1, expectedRevision: intent.revision, effectResult: effect, commandId: 'c-finish'
  });

  assert.equal(res.cleanup_state, 'cleaned');
  assert.equal(res.binding_state, 'closed');
  assert.equal(res.revision, intent.revision + 1);

  const run = await runRow(store, 't1');
  assert.equal(run.cleanup_state, 'cleaned');
  assert.equal(run.binding_state, 'closed', 'the binding closes when cleanup finishes');
  assert.notEqual(run.cleanup_finished_at, null, 'cleanup_finished_at is stamped');
  // The run is still the terminal run it was; cleanup does not reopen or move run status.
  assert.equal(run.status, 'completed');
  assert.notEqual(run.closed_at, null);

  // The effect result rides durably in the audit-only cleaned event; no outbox row.
  const ev = await rows(store, "SELECT payload_json FROM task_events WHERE task_id = 't1' AND event_type = 'cleaned'");
  const payload = typeof ev[0].payload_json === 'string' ? JSON.parse(ev[0].payload_json) : ev[0].payload_json;
  assert.deepEqual(payload, { effect_result: effect }, 'the adapter effect result is durable in the cleaned event');
  assert.equal(await outboxCount(store, 't1'), obBefore, 'cleaned creates no outbox row');
  assert.equal(isDeliverable('cleaned'), false);

  assert.deepEqual(await counters(store), { domain: before.domain + 1, projection: 0, commit: before.commit + 1 });
});

test('t_s3_lifecycle_events_are_audit_only', async () => {
  const { store } = await freshStore();
  // Drive the WHOLE lifecycle so the outbox actually exists (the terminal complete
  // creates it) and we can prove not one S3 event ever added a row to it.
  const rev = await cleanupPendingTask(store, 't1');
  const intent = await cleanupIntent(store, { taskId: 't1', generation: 1, expectedRevision: rev, commandId: 'c-intent' });
  await cleanupFinish(store, {
    taskId: 't1', generation: 1, expectedRevision: intent.revision, effectResult: { confirmed_absent: true }, commandId: 'c-finish'
  });

  // All four S3 lifecycle event types are present in the durable log...
  const types = await eventTypes(store, 't1');
  for (const t of ['spawned', 'running_verified', 'cleanup_started', 'cleaned']) {
    assert.equal(types.includes(t), true, `${t} is durable in task_events`);
    assert.equal(AUDIT_ONLY_EVENT_TYPES.has(t), true, `${t} is classified audit-only by the delivery policy`);
    assert.equal(isDeliverable(t), false, `${t} is not deliverable`);
  }

  // ...and NONE of them created an outbox row. The ONLY delivery is the terminal
  // completed event from S2.
  const ob = await rows(store, 'SELECT event_type FROM outbox WHERE task_id = $1', ['t1']);
  assert.deepEqual(ob.map((r) => r.event_type), ['completed'], 'the only delivery is the S2 terminal event; every S3 event is audit-only');
});

test('t_binding_and_cleanup_state_transitions', async () => {
  const { store } = await freshStore();

  const { revision, launchMarker } = await beganTask(store, 't1');
  let run = await runRow(store, 't1');
  assert.equal(run.status, 'spawning');
  assert.equal(run.binding_state, 'spawning');
  assert.equal(run.cleanup_state, 'not_started');
  assert.equal(run.endpoint_id, null, 'no endpoint before record-spawn');

  await recordSpawn(store, {
    taskId: 't1', generation: 1, expectedRevision: revision, launchMarker,
    endpoint: IDENTITY.endpointId, pane: IDENTITY.paneId, regFile: '/reg', commandId: 'c-spawn'
  }, { captureIdentity: captureOk });
  run = await runRow(store, 't1');
  assert.equal(run.status, 'spawning', 'record-spawn does not open the run');
  assert.equal(run.binding_state, 'spawning', 'record-spawn does not verify the binding');
  assert.notEqual(run.endpoint_id, null, 'the endpoint is recorded');

  await commitRunning(store, { taskId: 't1', generation: 1, expectedRevision: revision + 1, commandId: 'c-run' }, { probeIdentity: probeMatch });
  run = await runRow(store, 't1');
  assert.equal(run.status, 'open');
  assert.equal(run.binding_state, 'bound_verified');

  await completeRun(store, {
    taskId: 't1', generation: 1, expectedRevision: revision + 2, outcome: 'success', producer: 'crewmate', seq: 1, evidence: {}, commandId: 'c-done'
  });
  run = await runRow(store, 't1');
  assert.equal(run.status, 'completed');
  assert.notEqual(run.closed_at, null);
  assert.equal(run.binding_state, 'cleanup_pending', 'a terminal run with a stored endpoint is cleanup_pending');
  assert.equal(run.cleanup_state, 'not_started');

  await cleanupIntent(store, { taskId: 't1', generation: 1, expectedRevision: revision + 3, commandId: 'c-intent' });
  run = await runRow(store, 't1');
  assert.equal(run.binding_state, 'cleanup_pending');
  assert.equal(run.cleanup_state, 'intent_committed');

  await cleanupFinish(store, {
    taskId: 't1', generation: 1, expectedRevision: revision + 4, effectResult: { confirmed_absent: true }, commandId: 'c-finish'
  });
  run = await runRow(store, 't1');
  assert.equal(run.binding_state, 'closed', 'cleanup-finish closes the binding');
  assert.equal(run.cleanup_state, 'cleaned');
});

test('t_record_spawn_requires_matching_marker', async () => {
  const { store } = await freshStore();
  const { revision } = await beganTask(store, 't1');
  const before = await counters(store);

  await assert.rejects(
    () => recordSpawn(store, {
      taskId: 't1', generation: 1, expectedRevision: revision, launchMarker: 'not-the-real-marker',
      endpoint: IDENTITY.endpointId, pane: IDENTITY.paneId, regFile: '/reg', commandId: 'c-badmarker'
    }, { captureIdentity: captureOk }),
    (e) => e instanceof StateTransitionError && /launch marker does not match/.test(e.message),
    'a record-spawn whose marker does not match the run is refused'
  );

  // The refusal is a non-audited routing error: nothing persisted at all.
  const run = await runRow(store, 't1');
  assert.equal(run.endpoint_id, null, 'no endpoint was recorded');
  assert.equal((await eventTypes(store, 't1')).includes('spawned'), false, 'no spawned event');
  assert.deepEqual(await counters(store), before, 'the refusal wrote nothing');
  assert.equal(
    (await rows(store, "SELECT count(*)::int AS n FROM command_results WHERE command_id = 'c-badmarker'"))[0].n, 0,
    'no command_results ghost from the refused record-spawn'
  );
});

test('t_no_caller_deliver_switch_s3', async () => {
  const { fmHome } = mkFixtureHome();
  const store = new PgliteLocalStore({ fmHome });
  await store.init({ homeLabel: 'test' });
  await store.close();
  const env = { FM_HOME: fmHome };

  // Every S3 event is audit-only, so no S3 verb may carry a delivery switch. The refusal
  // is loud and fires before any argument-specific validation.
  const verbs = [
    ['record-spawn', ['t1', '--generation', '1']],
    ['commit-running', ['t1', '--generation', '1']],
    ['verify-running', ['t1', '--generation', '1']],
    ['cleanup-intent', ['t1', '--generation', '1']],
    ['cleanup-finish', ['t1', '--generation', '1']]
  ];
  for (const [verb, args] of verbs) {
    for (const switchFlag of ['--deliver', '--no-deliver']) {
      await assert.rejects(
        () => runVerb([verb, ...args, switchFlag, '--command-id', `c-${verb}-${switchFlag}`], { env }),
        (e) => e instanceof ValidationError
          && /has no --deliver\/--no-deliver switch; delivery policy is store-owned/.test(e.message),
        `${verb} must reject ${switchFlag}`
      );
    }
  }
});

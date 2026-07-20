import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { runExclusive } from '../lib/internal-runtime.mjs';
import { runVerb } from '../lib/coordinator.mjs';
import { ValidationError } from '../lib/errors.mjs';
import { IdempotencyConflictError, CausalOrderingError, StateTransitionError } from '../lib/errors-s1.mjs';
import { createTask, beginRun, appendEvent } from '../lib/domain-store.mjs';
import { completeRun, failRun, cancelTask } from '../lib/domain-store-s2.mjs';
import {
  isDeliverable, deliveryPolicyMap, DELIVERABLE_EVENT_TYPES, AUDIT_ONLY_EVENT_TYPES
} from '../lib/delivery-policy.mjs';
import { mkFixtureHome, cleanupAll } from './helpers.mjs';

// S2 owns the outbox, the terminal verbs, and queued cancellation (spec-amend-s4
// section 12, S2 row). No test here uses a table or verb owned by a later slice, and
// projection_revision must stay 0 throughout: projections are S6.
after(cleanupAll);

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
  return {
    domain: Number(r[0].domain_revision),
    projection: Number(r[0].projection_revision),
    commit: Number(r[0].commit_sequence)
  };
}

// Deliveries for a task, tolerating an outbox table that does not exist yet. The S2
// schema is applied lazily inside an S2 mutation, so before any S2 verb has committed
// there is no outbox table at all - which is itself the strongest possible form of
// "nothing was delivered", not a reason to fail the assertion.
async function deliveries(store, taskId) {
  return runExclusive(store, async (conn) => {
    const reg = await conn.query("SELECT to_regclass('public.outbox') AS reg");
    if (reg.rows[0].reg === null) return [];
    const r = await conn.query(
      'SELECT event_type, run_generation, generation_key, task_seq FROM outbox WHERE task_id = $1 ORDER BY outbox_id',
      [taskId]
    );
    return r.rows;
  });
}

// TEST-ONLY FIXTURE standing in for S3's `commit-running`, which is the only thing
// that can legitimately drive a task spawning -> running and is not in this slice.
// Without it no S2 test could exercise `complete` at all, since complete commits only
// from running/waiting_firstmate. It writes through the same in-package seam the
// domain layer uses, mimics exactly what commit-running will do, and DELIBERATELY
// does not touch the coordinator counters, so every counter assertion below measures
// S2's own deltas and nothing else. It is a fixture, not a production path: no
// shipped module exposes it.
async function promoteToRunning(store, taskId, generation, revision, { endpointId = null } = {}) {
  await runExclusive(store, async (conn) => {
    await conn.query(
      `UPDATE runs SET status = 'open', binding_state = 'bound_verified', endpoint_id = $3
         WHERE task_id = $1 AND run_generation = $2`,
      [taskId, generation, endpointId]
    );
    await conn.query(
      "UPDATE tasks SET status = 'running', revision = $2 WHERE task_id = $1",
      [taskId, revision + 1]
    );
  });
  return revision + 1;
}

// A task with one OPEN, running generation 1. Returns the task revision.
async function runningTask(store, taskId = 't1', opts = {}) {
  await createTask(store, {
    taskId, kind: 'ship', title: 'x', origin: 'internal', internalReason: 'r',
    commandId: `c-create-${taskId}`
  });
  await beginRun(store, { taskId, expectedRevision: 1, commandId: `c-begin-${taskId}` });
  return promoteToRunning(store, taskId, 1, 2, opts);
}

async function queuedTask(store, taskId = 't1') {
  await createTask(store, {
    taskId, kind: 'ship', title: 'x', origin: 'internal', internalReason: 'r',
    commandId: `c-create-${taskId}`
  });
  return 1;
}

// Minimal valid required terminal inputs (spec section 6) for tests whose subject is
// something other than the input contract itself; that contract has its own tests
// below.
const COMPLETE_INPUTS = { outcome: 'success', producer: 'crewmate', seq: 1, evidence: {} };

test('t_terminal_run_event_outbox_atomic', async () => {
  const { store } = await freshStore();
  const rev = await runningTask(store, 't1', { endpointId: 'ep-1' });
  const before = await counters(store);

  const res = await completeRun(store, {
    taskId: 't1', generation: 1, expectedRevision: rev, ...COMPLETE_INPUTS, commandId: 'c-complete'
  });
  assert.equal(res.status, 'completed');
  assert.equal(res.revision, rev + 1);

  // All three writes landed, and they landed together.
  const ev = await rows(
    store,
    `SELECT event_id, event_type, outcome, is_terminal, event_scope, run_generation, generation_key, payload_hash
       FROM task_events WHERE task_id = 't1' AND is_terminal`
  );
  assert.equal(ev.length, 1, 'exactly one terminal event for the generation');
  assert.equal(ev[0].event_type, 'completed');
  assert.equal(ev[0].outcome, 'success');
  assert.equal(ev[0].is_terminal, true);
  assert.equal(ev[0].event_scope, 'run');
  assert.equal(Number(ev[0].run_generation), 1);
  assert.equal(Number(ev[0].generation_key), 1);

  const run = await rows(store, "SELECT status, closed_at, binding_state FROM runs WHERE task_id = 't1'");
  assert.equal(run[0].status, 'completed');
  assert.notEqual(run[0].closed_at, null, 'the run is closed');
  assert.equal(run[0].binding_state, 'cleanup_pending', 'a stored endpoint leaves cleanup pending for S3');

  const ob = await rows(
    store,
    `SELECT outbox_id, event_id, task_id, run_generation, generation_key, task_seq, event_type, payload_hash, acked_at
       FROM outbox WHERE task_id = 't1'`
  );
  assert.equal(ob.length, 1, 'exactly one outbox row');
  // The outbox row is an exact COPY of the event's identifying 5-tuple, not an
  // independently-authored record.
  assert.equal(ob[0].event_id, ev[0].event_id);
  assert.equal(ob[0].event_type, ev[0].event_type);
  assert.equal(ob[0].payload_hash, ev[0].payload_hash);
  assert.equal(Number(ob[0].generation_key), Number(ev[0].generation_key));
  assert.equal(Number(ob[0].run_generation), 1);
  assert.equal(Number(ob[0].task_seq), 1, 'first delivery within (task, generation)');
  assert.equal(ob[0].acked_at, null, 'a fresh delivery is unacked');

  const task = await rows(store, "SELECT status, revision FROM tasks WHERE task_id = 't1'");
  assert.equal(task[0].status, 'completed');
  assert.equal(Number(task[0].revision), rev + 1);

  // One command = one domain revision, one commit, no projection movement (S6).
  const after_ = await counters(store);
  assert.deepEqual(
    after_,
    { domain: before.domain + 1, projection: 0, commit: before.commit + 1 },
    'complete advances domain+commit by exactly one and never projection_revision'
  );
});

test('t_outbox_exactly_once_per_terminal_event', async () => {
  const { store } = await freshStore();
  const rev = await runningTask(store, 't1');

  await completeRun(store, {
    taskId: 't1', generation: 1, expectedRevision: rev, ...COMPLETE_INPUTS, commandId: 'c-complete'
  });
  const afterFirst = await counters(store);

  // An identical replay is a replay: the stored result comes back, and it neither
  // writes a second outbox row nor advances any counter.
  const replay = await completeRun(store, {
    taskId: 't1', generation: 1, expectedRevision: rev, ...COMPLETE_INPUTS, commandId: 'c-complete'
  });
  assert.equal(replay.revision, rev + 1, 'the stored result is returned verbatim');

  const ob = await rows(store, "SELECT event_id FROM outbox WHERE task_id = 't1'");
  assert.equal(ob.length, 1, 'the replay produced no second outbox row');
  const ev = await rows(store, "SELECT event_id FROM task_events WHERE task_id = 't1' AND is_terminal");
  assert.equal(ev.length, 1, 'the replay produced no second terminal event');
  assert.deepEqual(await counters(store), afterFirst, 'a replay is not a write and bumps nothing');

  // Exactly-once is enforced at the DDL level too: event_id is UNIQUE in outbox, so
  // a second delivery of one event is impossible even by a direct in-package write.
  await assert.rejects(
    () => runExclusive(store, async (conn) => {
      await conn.query(
        `INSERT INTO outbox (event_id, task_id, run_generation, generation_key, task_seq, event_type, payload_hash, created_at)
           SELECT event_id, task_id, run_generation, generation_key, task_seq + 1, event_type, payload_hash, created_at
             FROM outbox WHERE task_id = 't1'`
      );
    }),
    (e) => /duplicate key value|unique constraint/i.test(e.message),
    'outbox.event_id UNIQUE forbids a second row for the same event'
  );
});

test('t_cancelled_task_scope_delivery', async () => {
  const { store } = await freshStore();
  const rev = await queuedTask(store, 't1');
  const before = await counters(store);

  const res = await cancelTask(store, {
    taskId: 't1', expectedRevision: rev, reason: 'captain withdrew', commandId: 'c-cancel'
  });
  assert.equal(res.status, 'archived');

  // Two task-scope events; only `cancelled` is delivered (delivery policy).
  const ev = await rows(
    store,
    `SELECT event_type, event_scope, run_generation, generation_key, producer_seq
       FROM task_events WHERE task_id = 't1' ORDER BY producer_seq`
  );
  assert.deepEqual(ev.map((r) => r.event_type), ['created', 'cancelled', 'archived']);
  // The coordinator's task-scope producer_seq continues the run_generation = -1
  // high-water rather than restarting, which is what keeps ux_event_producer_seq
  // from colliding (ruling RISK#4).
  assert.deepEqual(ev.map((r) => Number(r.producer_seq)), [1, 2, 3]);
  for (const r of ev) {
    assert.equal(r.event_scope, 'task');
    assert.equal(r.run_generation, null);
    assert.equal(Number(r.generation_key), -1);
  }

  const ob = await rows(
    store,
    'SELECT event_type, run_generation, generation_key, task_seq FROM outbox WHERE task_id = $1', ['t1']
  );
  assert.equal(ob.length, 1, 'exactly one delivery: the cancelled event');
  assert.equal(ob[0].event_type, 'cancelled');
  assert.equal(ob[0].run_generation, null, 'a task-scope delivery carries no run generation');
  assert.equal(Number(ob[0].generation_key), -1, 'task-scope generation_key is -1 (spec R3-1)');
  assert.equal(Number(ob[0].task_seq), 1);

  // `archived` is audit-only: durable in task_events, never delivered.
  const archivedDelivered = await rows(
    store, "SELECT 1 FROM outbox WHERE task_id = 't1' AND event_type = 'archived'"
  );
  assert.equal(archivedDelivered.length, 0, 'archived is audit-only and creates no outbox row');

  const task = await rows(store, "SELECT status, archived_at, revision FROM tasks WHERE task_id = 't1'");
  assert.equal(task[0].status, 'archived');
  assert.notEqual(task[0].archived_at, null, 'archived_at is set');
  assert.equal(Number(task[0].revision), rev + 1);

  // No run was created or closed: cancellation is a task-scope archive path, not a
  // run terminal outcome (spec section 3.1 R2-4).
  const runs = await rows(store, "SELECT 1 FROM runs WHERE task_id = 't1'");
  assert.equal(runs.length, 0, 'cancel never creates or closes a run');

  const after_ = await counters(store);
  assert.deepEqual(
    after_,
    { domain: before.domain + 1, projection: 0, commit: before.commit + 1 },
    'cancel is one domain change even though it writes two events'
  );
});

test('t_delivery_policy_map', async () => {
  // The map must be TOTAL over the event vocabulary the DDL actually permits. Reading
  // the vocabulary from the schema (rather than restating it here) is what makes this
  // fail when a future slice adds an event type without a delivery decision.
  const sqlPath = path.join(
    path.dirname(fileURLToPath(import.meta.url)), '..', 'sql', 'domain-schema-s1.sql'
  );
  const ddl = fs.readFileSync(sqlPath, 'utf8');
  const checkBlock = /event_type\s+TEXT NOT NULL CHECK \(event_type IN \(([\s\S]*?)\)\)/.exec(ddl);
  assert.ok(checkBlock, 'located the event_type CHECK vocabulary in the S1 DDL');
  const ddlTypes = [...checkBlock[1].matchAll(/'([a-z_]+)'/g)].map((m) => m[1]);
  assert.equal(ddlTypes.length, 18, 'the DDL vocabulary is the expected 18 event types');

  const map = deliveryPolicyMap();
  assert.equal(map.size, ddlTypes.length, 'the policy map covers every DDL event type and no extras');
  for (const t of ddlTypes) {
    assert.ok(map.has(t), `event type '${t}' has a delivery decision`);
  }

  // Pin the exact classification. Spec section 6.1 lists these verbatim; a silent
  // move between the two sets is exactly the mutation this test must catch.
  assert.deepEqual(
    [...DELIVERABLE_EVENT_TYPES].sort(),
    ['blocked', 'cancelled', 'completed', 'failed', 'needs_human', 'progress', 'rework', 'unblocked', 'waiting_firstmate'],
    'mandatory-delivery set matches spec section 6.1'
  );
  assert.deepEqual(
    [...AUDIT_ONLY_EVENT_TYPES].sort(),
    ['anomaly', 'archived', 'cleaned', 'cleanup_started', 'created', 'identity_lost', 'running_verified', 'spawn_intent', 'spawned'],
    'audit-only set matches spec section 6.1'
  );
  // The two sets are disjoint: no type may be both.
  for (const t of DELIVERABLE_EVENT_TYPES) {
    assert.ok(!AUDIT_ONLY_EVENT_TYPES.has(t), `'${t}' is classified exactly once`);
  }

  assert.equal(isDeliverable('completed'), true);
  assert.equal(isDeliverable('failed'), true);
  assert.equal(isDeliverable('cancelled'), true);
  assert.equal(isDeliverable('archived'), false);
  assert.equal(isDeliverable('spawn_intent'), false);

  // An unclassified type fails loudly rather than defaulting to no-delivery, so an
  // event FirstMate must see can never be silently dropped.
  assert.throws(
    () => isDeliverable('some_future_event'),
    /delivery policy has no entry/,
    'unknown types are a loud programming error, not a silent audit-only default'
  );
});

test('t_cancel_queued_only', async () => {
  const { store } = await freshStore();

  // A task with a run is past the cancellable window (ruling RISK#4 / spec R3-3):
  // archiving that work is the distinct `archive` verb, which S2 does not own.
  await createTask(store, {
    taskId: 't1', kind: 'ship', title: 'x', origin: 'internal', internalReason: 'r', commandId: 'c-create'
  });
  await beginRun(store, { taskId: 't1', expectedRevision: 1, commandId: 'c-begin' });
  const beforeSpawning = await counters(store);
  await assert.rejects(
    () => cancelTask(store, { taskId: 't1', expectedRevision: 2, reason: 'x', commandId: 'c-cancel-spawning' }),
    (e) => e instanceof StateTransitionError
      && e.code === 'state_transition'
      && /allowed only while a task is still queued/.test(e.message),
    'cancel is refused once a run exists'
  );
  // A state-transition rejection is not an audited conflict: nothing persists at all.
  assert.deepEqual(await counters(store), beforeSpawning, 'the refusal wrote nothing');
  assert.equal(
    (await rows(store, "SELECT 1 FROM task_events WHERE task_id = 't1' AND event_type = 'cancelled'")).length, 0
  );
  assert.deepEqual(await deliveries(store, 't1'), [], 'the refusal delivered nothing');
  assert.equal((await rows(store, "SELECT status FROM tasks WHERE task_id = 't1'"))[0].status, 'spawning');

  // Terminal states are equally uncancellable.
  const rev = await promoteToRunning(store, 't1', 1, 2);
  await completeRun(store, { taskId: 't1', generation: 1, expectedRevision: rev, ...COMPLETE_INPUTS, commandId: 'c-complete' });
  await assert.rejects(
    () => cancelTask(store, { taskId: 't1', expectedRevision: rev + 1, reason: 'x', commandId: 'c-cancel-completed' }),
    (e) => e instanceof StateTransitionError && /allowed only while a task is still queued/.test(e.message),
    'cancel is refused on a completed task'
  );

  // And the queued case still works, proving the guard is a real state test rather
  // than a blanket refusal.
  await createTask(store, {
    taskId: 't2', kind: 'ship', title: 'y', origin: 'internal', internalReason: 'r', commandId: 'c-create-2'
  });
  const ok = await cancelTask(store, { taskId: 't2', expectedRevision: 1, reason: 'x', commandId: 'c-cancel-ok' });
  assert.equal(ok.status, 'archived');
});

test('t_run_terminal_only_through_complete_fail', async () => {
  const { store } = await freshStore();
  const rev = await runningTask(store, 't1');
  const before = await counters(store);

  // Generic append cannot author a terminal event (S1's wrapper guard), so it cannot
  // reach a terminal run status by the back door.
  for (const type of ['completed', 'failed']) {
    await assert.rejects(
      () => appendEvent(store, {
        taskId: 't1', generation: 1, eventType: type, producer: 'crewmate', seq: 10,
        expectedRevision: rev, commandId: `c-append-${type}`
      }),
      (e) => e instanceof StateTransitionError
        && /not appendable through generic 'event'|must use its owning wrapper/.test(e.message),
      `generic append must reject terminal type ${type}`
    );
  }

  // Nothing moved: the run is still open, no terminal event, no delivery.
  const run = await rows(store, "SELECT status, closed_at FROM runs WHERE task_id = 't1'");
  assert.equal(run[0].status, 'open');
  assert.equal(run[0].closed_at, null, 'the rejected appends left the generation open');
  assert.equal((await rows(store, "SELECT 1 FROM task_events WHERE task_id = 't1' AND is_terminal")).length, 0);
  assert.deepEqual(await deliveries(store, 't1'), [], 'the rejected appends delivered nothing');
  assert.deepEqual(await counters(store), before, 'the rejected appends wrote nothing');

  // `cancel` is task-scope and likewise never closes a run.
  await createTask(store, {
    taskId: 't2', kind: 'ship', title: 'y', origin: 'internal', internalReason: 'r', commandId: 'c-create-2'
  });
  await cancelTask(store, { taskId: 't2', expectedRevision: 1, reason: 'x', commandId: 'c-cancel-2' });
  assert.equal((await rows(store, "SELECT 1 FROM runs WHERE task_id = 't2'")).length, 0);

  // The DDL's own invariant: a terminal run status without closed_at is impossible,
  // so no future writer can half-close a generation.
  await assert.rejects(
    () => runExclusive(store, async (conn) => {
      await conn.query("UPDATE runs SET status = 'completed' WHERE task_id = 't1' AND run_generation = 1");
    }),
    /run_closed_iff_terminal/,
    'run_closed_iff_terminal ties terminal status to closed_at'
  );

  // And `complete` DOES close it, proving the guards above are not simply blocking
  // every path.
  const done = await completeRun(store, {
    taskId: 't1', generation: 1, expectedRevision: rev, ...COMPLETE_INPUTS, commandId: 'c-complete'
  });
  assert.equal(done.run_status, 'completed');
  assert.equal((await deliveries(store, 't1')).length, 1, 'complete is the path that does deliver');
});

test('t_no_caller_deliver_switch_terminal', async () => {
  const { store, fmHome } = await freshStore();
  const rev = await runningTask(store, 't1');
  await store.close();
  const env = { FM_HOME: fmHome };

  // Delivery is not caller optional (spec R2-6). Neither forcing nor suppressing it
  // is accepted on any S2 verb, and the refusal is loud rather than a silently
  // ignored flag.
  const cases = [
    ['complete', ['t1', '--generation', '1', '--expected-revision', String(rev)]],
    ['fail', ['t1', '--generation', '1', '--expected-revision', String(rev)]],
    ['cancel', ['t1', '--expected-revision', String(rev)]]
  ];
  for (const [verb, args] of cases) {
    for (const switchFlag of ['--deliver', '--no-deliver']) {
      await assert.rejects(
        () => runVerb([verb, ...args, switchFlag, '--command-id', `c-${verb}-${switchFlag}`], { env }),
        (e) => e instanceof ValidationError
          && /has no --deliver\/--no-deliver switch; delivery policy is store-owned/.test(e.message),
        `${verb} must reject ${switchFlag}`
      );
    }
  }

  // Nothing was delivered or committed by the rejected invocations.
  const reopened = new PgliteLocalStore({ fmHome });
  assert.equal((await rows(reopened, "SELECT 1 FROM task_events WHERE task_id = 't1' AND is_terminal")).length, 0);
  const run = await rows(reopened, "SELECT status FROM runs WHERE task_id = 't1'");
  assert.equal(run[0].status, 'open');
  await reopened.close();
});

// ---- terminal command surface: provenance, evidence, and reason (qa-s2-q54
// finding 2). These run through the PUBLIC runVerb seam - the exact surface the QA
// probes used - so the dispatcher's flag contract and the domain's storage contract
// are pinned together.

const asJson = (v) => (typeof v === 'string' ? JSON.parse(v) : v);

test('t_terminal_inputs_validated_loudly', async () => {
  const { store, fmHome } = await freshStore();
  const rev = await runningTask(store, 't1');
  const before = await counters(store);
  const env = { FM_HOME: fmHome };
  const evidencePath = path.join(fmHome, 'evidence.json');
  fs.writeFileSync(evidencePath, JSON.stringify({ note: 'ok' }));

  const base = ['t1', '--generation', '1', '--expected-revision', String(rev)];
  const good = [
    ...base, '--outcome', 'success', '--producer', 'crewmate', '--seq', '1',
    '--evidence-file', evidencePath
  ];
  const cases = [
    ['no-outcome', [...base, '--producer', 'crewmate', '--seq', '1', '--evidence-file', evidencePath],
      /requires --outcome/],
    ['bad-outcome', [...base, '--outcome', 'failure', '--producer', 'crewmate', '--seq', '1', '--evidence-file', evidencePath],
      /--outcome must be one of success/],
    ['no-producer', [...base, '--outcome', 'success', '--seq', '1', '--evidence-file', evidencePath],
      /requires --producer/],
    ['bad-producer', [...base, '--outcome', 'success', '--producer', 'ghost', '--seq', '1', '--evidence-file', evidencePath],
      /--producer must be one of/],
    ['no-seq', [...base, '--outcome', 'success', '--producer', 'crewmate', '--evidence-file', evidencePath],
      /--seq is required/],
    ['no-evidence', [...base, '--outcome', 'success', '--producer', 'crewmate', '--seq', '1'],
      /requires --evidence-file/],
    ['missing-evidence-file', [...base, '--outcome', 'success', '--producer', 'crewmate', '--seq', '1', '--evidence-file', path.join(fmHome, 'definitely-missing.json')],
      /--evidence-file could not be read/],
    ['generic-payload-file', [...good, '--payload-file', evidencePath],
      /has no --payload-file/]
  ];
  for (const [label, args, pattern] of cases) {
    await assert.rejects(
      () => runVerb(['complete', ...args, '--command-id', `c-${label}`], { env }),
      (e) => e instanceof ValidationError && pattern.test(e.message),
      `complete ${label} must reject loudly`
    );
  }

  await assert.rejects(
    () => runVerb(['fail', ...base, '--producer', 'crewmate', '--seq', '1', '--command-id', 'c-fail-noreason'], { env }),
    (e) => e instanceof ValidationError && /requires --reason/.test(e.message),
    'fail without --reason must reject loudly'
  );
  await assert.rejects(
    () => runVerb(['fail', ...base, '--reason', 'r', '--producer', 'crewmate', '--seq', '1',
      '--artifacts-file', path.join(fmHome, 'no-artifacts.json'), '--command-id', 'c-fail-badart'], { env }),
    (e) => e instanceof ValidationError && /--artifacts-file could not be read/.test(e.message),
    'a supplied-but-missing --artifacts-file must reject loudly, never silently drop'
  );
  await assert.rejects(
    () => runVerb(['cancel', 't1', '--expected-revision', String(rev), '--command-id', 'c-cancel-noreason'], { env }),
    (e) => e instanceof ValidationError && /requires --reason/.test(e.message),
    'cancel without --reason must reject loudly'
  );

  // Every rejection fired before any store mutation: run still open, no terminal
  // event, no delivery, no counter movement, no command_results ghost.
  assert.deepEqual(await counters(store), before, 'the rejected commands wrote nothing');
  const run = await rows(store, "SELECT status, closed_at FROM runs WHERE task_id = 't1'");
  assert.equal(run[0].status, 'open');
  assert.equal(run[0].closed_at, null, 'the generation stayed open through every rejection');
  assert.equal((await rows(store, "SELECT 1 FROM task_events WHERE task_id = 't1' AND is_terminal")).length, 0);
  assert.deepEqual(await deliveries(store, 't1'), [], 'nothing was delivered');
  assert.equal(
    (await rows(
      store,
      "SELECT 1 FROM command_results WHERE command_id NOT IN ('c-create-t1', 'c-begin-t1')"
    )).length, 0,
    'no rejected command was recorded as if it had run'
  );
});

test('t_terminal_provenance_stored_and_checked', async () => {
  const { store, fmHome } = await freshStore();
  const rev = await runningTask(store, 't1');
  const env = { FM_HOME: fmHome };
  const evidencePath = path.join(fmHome, 'evidence.json');
  const evidence = { result: 'green', log: 'all suites passed' };
  fs.writeFileSync(evidencePath, JSON.stringify(evidence));

  // The crewmate has already spoken at seq 7 in this generation.
  await appendEvent(store, {
    taskId: 't1', generation: 1, eventType: 'progress', producer: 'crewmate', seq: 7,
    expectedRevision: rev, commandId: 'c-progress'
  });
  const rev2 = rev + 1;
  const argsFor = (seq, commandId) => [
    'complete', 't1', '--generation', '1', '--expected-revision', String(rev2),
    '--outcome', 'success', '--producer', 'crewmate', '--seq', String(seq),
    '--evidence-file', evidencePath, '--command-id', commandId
  ];

  // A terminal claiming a non-advancing seq is a CHECKED causal conflict against the
  // caller's own high-water, exactly as generic `event` enforces - not accepted
  // decoration (qa-s2-q54 finding 2).
  await assert.rejects(
    () => runVerb(argsFor(7, 'c-stale-seq'), { env }),
    (e) => e instanceof CausalOrderingError && e.detail.reason === 'nonmonotonic_producer_seq',
    'a non-advancing --seq is rejected against the producer high-water'
  );
  const run = await rows(store, "SELECT closed_at FROM runs WHERE task_id = 't1'");
  assert.equal(run[0].closed_at, null, 'the rejected terminal left the generation open');

  const done = await runVerb(argsFor(8, 'c-done'), { env });
  assert.equal(done.result.revision, rev2 + 1);

  // The stored provenance is the CALLER's, verbatim - never rewritten to a
  // coordinator-derived sequence.
  const ev = await rows(
    store,
    `SELECT producer_id, producer_seq, outcome, payload_json
       FROM task_events WHERE task_id = 't1' AND is_terminal`
  );
  assert.equal(ev.length, 1);
  assert.equal(ev[0].producer_id, 'crewmate', 'the terminal event carries the supplied producer');
  assert.equal(Number(ev[0].producer_seq), 8, 'the terminal event carries the supplied seq');
  assert.equal(ev[0].outcome, 'success');
  assert.deepEqual(
    asJson(ev[0].payload_json), { evidence },
    'the evidence file content rides durably in the terminal payload'
  );

  const hw = await rows(
    store,
    `SELECT last_seq FROM producer_highwater
       WHERE task_id = 't1' AND run_generation = 1 AND producer_id = 'crewmate'`
  );
  assert.equal(Number(hw[0].last_seq), 8, "the caller's high-water advanced to the supplied seq");

  // An identical retry is an idempotent replay of the stored result...
  const replay = await runVerb(argsFor(8, 'c-done'), { env });
  assert.deepEqual(replay.result, done.result, 'the identical retry replays the stored result');

  // ...but the same command-id claiming DIFFERENT provenance is a different request:
  // producer/seq are part of the request identity, so it conflicts rather than
  // silently replaying under false provenance.
  await assert.rejects(
    () => runVerb(argsFor(9, 'c-done'), { env }),
    (e) => e instanceof IdempotencyConflictError,
    'changed provenance under a reused command-id is an idempotency conflict'
  );
  assert.equal((await rows(store, "SELECT 1 FROM task_events WHERE task_id = 't1' AND is_terminal")).length, 1);
  assert.equal((await deliveries(store, 't1')).length, 1, 'the conflict enqueued no second delivery');
});

test('t_cancel_and_fail_reason_persisted', async () => {
  const { store, fmHome } = await freshStore();
  const env = { FM_HOME: fmHome };
  await queuedTask(store, 't1');

  const cancelled = await runVerb(
    ['cancel', 't1', '--expected-revision', '1', '--reason', 'captain withdrew the order', '--command-id', 'c-cancel'],
    { env }
  );
  assert.equal(cancelled.result.status, 'archived');
  const ev = await rows(
    store,
    "SELECT payload_json, payload_hash FROM task_events WHERE task_id = 't1' AND event_type = 'cancelled'"
  );
  assert.equal(ev.length, 1);
  assert.deepEqual(
    asJson(ev[0].payload_json), { reason: 'captain withdrew the order' },
    'the required cancel reason IS the cancelled event payload'
  );
  // The delivered copy hashes the same payload, so the consumer-side event carries
  // the reason too.
  const ob = await rows(
    store, "SELECT payload_hash FROM outbox WHERE task_id = 't1' AND event_type = 'cancelled'"
  );
  assert.equal(ob[0].payload_hash, ev[0].payload_hash);

  // fail: the required reason and the optional artifacts are equally durable, under
  // the caller's provenance.
  const rev = await runningTask(store, 't2');
  const artifactsPath = path.join(fmHome, 'artifacts.json');
  fs.writeFileSync(artifactsPath, JSON.stringify({ logs: ['a.log'] }));
  await runVerb(
    ['fail', 't2', '--generation', '1', '--expected-revision', String(rev),
      '--reason', 'suite red', '--producer', 'firstmate', '--seq', '1',
      '--artifacts-file', artifactsPath, '--command-id', 'c-fail'],
    { env }
  );
  const fev = await rows(
    store,
    `SELECT producer_id, producer_seq, outcome, payload_json
       FROM task_events WHERE task_id = 't2' AND is_terminal`
  );
  assert.equal(fev.length, 1);
  assert.equal(fev[0].producer_id, 'firstmate');
  assert.equal(Number(fev[0].producer_seq), 1);
  assert.equal(fev[0].outcome, 'failure');
  assert.deepEqual(
    asJson(fev[0].payload_json), { reason: 'suite red', artifacts: { logs: ['a.log'] } },
    'the fail reason and artifacts ride durably in the failed event payload'
  );
});

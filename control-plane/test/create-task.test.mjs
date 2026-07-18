import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { ValidationError, ConstraintError } from '../lib/errors.mjs';
import { mkFixtureHome, cleanupAll } from './helpers.mjs';

after(cleanupAll);

async function freshStore() {
  const { fmHome } = mkFixtureHome();
  const store = new PgliteLocalStore({ fmHome });
  await store.init();
  return store;
}

test('create-task inserts a queued task and read-back verifies it', async () => {
  const store = await freshStore();
  const created = await store.createTask({
    taskId: 'login-fix',
    kind: 'ship',
    title: 'Fix the login flow',
    repo: 'yourapp',
    origin: 'captain_order',
    orderRef: 'ORD-228'
  });
  assert.equal(created.taskId, 'login-fix');
  assert.equal(created.revision, 1, 'creation increments revision from 0 to 1');

  const head = await store.taskHead('login-fix');
  assert.deepEqual(
    { status: head.status, currentGeneration: head.currentGeneration, revision: head.revision },
    { status: 'queued', currentGeneration: 0, revision: 1 }
  );
  assert.ok(head.domainRevision >= 1, 'domain revision advanced on the create');
});

test('create-task writes a task-scope created event (generation_key -1)', async () => {
  const store = await freshStore();
  await store.createTask({
    taskId: 'evt-task', kind: 'scout', title: 't',
    origin: 'internal', internalReason: 'triage sweep'
  });
  const row = await store.runExclusive(async (conn) => {
    const r = await conn.query(
      "SELECT event_scope, run_generation, generation_key, event_type, is_terminal FROM task_events WHERE task_id='evt-task'"
    );
    return r.rows;
  });
  assert.equal(row.length, 1);
  assert.equal(row[0].event_scope, 'task');
  assert.equal(row[0].run_generation, null);
  assert.equal(Number(row[0].generation_key), -1);
  assert.equal(row[0].event_type, 'created');
  assert.equal(row[0].is_terminal, false);
});

test('internal task with a provenance reason and null order_ref is accepted', async () => {
  const store = await freshStore();
  const r = await store.createTask({
    taskId: 'internal-1', kind: 'secondmate', title: 'triage-mate',
    origin: 'internal', internalReason: 'persistent triage supervisor'
  });
  assert.equal(r.revision, 1);
});

test('origin/order-ref rules are enforced with typed ValidationErrors', async () => {
  const store = await freshStore();
  const base = { kind: 'ship', title: 't' };
  await assert.rejects(
    () => store.createTask({ ...base, taskId: 'a', origin: 'captain_order' }),
    ValidationError, 'captain_order requires order_ref'
  );
  await assert.rejects(
    () => store.createTask({ ...base, taskId: 'b', origin: 'internal' }),
    ValidationError, 'internal requires internal_reason'
  );
  await assert.rejects(
    () => store.createTask({ ...base, taskId: 'c', origin: 'internal', internalReason: 'x', orderRef: 'ORD-1' }),
    ValidationError, 'internal must not carry order_ref'
  );
  await assert.rejects(
    () => store.createTask({ ...base, taskId: 'd', origin: 'captain_order', orderRef: 'ORD-1', internalReason: 'x' }),
    ValidationError, 'captain_order must not carry internal_reason'
  );
  await assert.rejects(
    () => store.createTask({ ...base, taskId: 'e', origin: 'sideways', orderRef: 'ORD-1' }),
    ValidationError, 'invalid origin'
  );
  await assert.rejects(
    () => store.createTask({ taskId: 'f', kind: 'bogus', title: 't', origin: 'internal', internalReason: 'x' }),
    ValidationError, 'invalid kind'
  );
});

test('create-task is idempotent under a repeated command-id', async () => {
  const store = await freshStore();
  const input = {
    taskId: 'idem-1', kind: 'ship', title: 't',
    origin: 'captain_order', orderRef: 'ORD-9', commandId: 'cmd-abc'
  };
  const first = await store.createTask(input);
  const replay = await store.createTask(input);
  assert.equal(replay.replay, true, 'replay flagged');
  assert.equal(replay.taskId, first.taskId);
  assert.equal(replay.revision, first.revision);

  // Only one task and one created event exist.
  const counts = await store.runExclusive(async (conn) => {
    const t = await conn.query("SELECT count(*)::int n FROM tasks WHERE task_id='idem-1'");
    const e = await conn.query("SELECT count(*)::int n FROM task_events WHERE task_id='idem-1'");
    return { tasks: Number(t.rows[0].n), events: Number(e.rows[0].n) };
  });
  assert.deepEqual(counts, { tasks: 1, events: 1 });
});

test('a duplicate task id without a command-id is a ConstraintError', async () => {
  const store = await freshStore();
  const input = { taskId: 'dup-1', kind: 'ship', title: 't', origin: 'captain_order', orderRef: 'ORD-1' };
  await store.createTask(input);
  await assert.rejects(() => store.createTask(input), ConstraintError);
});

test('task-head returns null for an unknown task', async () => {
  const store = await freshStore();
  assert.equal(await store.taskHead('nope'), null);
});

import { test, after, before } from 'node:test';
import assert from 'node:assert/strict';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { mkFixtureHome, cleanupAll } from './helpers.mjs';

after(cleanupAll);

// One initialized fixture with a task + an open run, so run-scope events have a
// valid parent. These tests drive raw inserts through the store's exclusive
// transaction primitive to prove the applied DDL enforces the spec's constraints.
let store;
const NOW = '2026-07-18T00:00:00.000Z';

before(async () => {
  const { fmHome } = mkFixtureHome();
  store = new PgliteLocalStore({ fmHome });
  await store.init();
  await store.createTask({
    taskId: 'task-c',
    kind: 'ship',
    title: 'constraint fixture',
    origin: 'captain_order',
    orderRef: 'ORD-228'
  });
  // Insert an open run (generation 1) as the parent for run-scope events.
  await store.runExclusive(async (conn) => {
    await conn.query(
      `INSERT INTO runs
         (task_id, run_generation, status, backend, bind_nonce, launch_marker,
          launch_dir, registration_path, launch_deadline_at, created_at)
       VALUES ('task-c', 1, 'open', 'tmux', 'nonce', 'marker-1', '/w', '/r', $1, $1)`,
      [NOW]
    );
  });
});

function insertEvent(overrides) {
  const e = {
    event_id: 'e-default',
    task_id: 'task-c',
    event_scope: 'run',
    run_generation: 1,
    producer_id: 'crewmate',
    producer_seq: 1,
    event_type: 'progress',
    generation_key: 1,
    is_terminal: false,
    outcome: null,
    payload_hash: 'h',
    ...overrides
  };
  return store.runExclusive(async (conn) => {
    await conn.query(
      `INSERT INTO task_events
         (event_id, task_id, event_scope, run_generation, producer_id, producer_seq,
          event_type, generation_key, is_terminal, outcome, payload_hash, created_at)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)`,
      [
        e.event_id, e.task_id, e.event_scope, e.run_generation, e.producer_id,
        e.producer_seq, e.event_type, e.generation_key, e.is_terminal, e.outcome,
        e.payload_hash, NOW
      ]
    );
  });
}

test('a well-formed run-scope event inserts', async () => {
  await insertEvent({ event_id: 'e1', producer_seq: 1 });
});

test('duplicate event id is rejected', async () => {
  await assert.rejects(() => insertEvent({ event_id: 'e1', producer_seq: 99 }));
});

test('duplicate (task, generation, producer, seq) is rejected', async () => {
  // Same (task-c, gen 1, crewmate, seq 1) as e1 but a distinct event id.
  await assert.rejects(() => insertEvent({ event_id: 'e-dup-seq', producer_seq: 1 }));
});

test('a second terminal event for the same generation is rejected', async () => {
  await insertEvent({
    event_id: 'e-term-1', producer_seq: 10, event_type: 'completed',
    is_terminal: true, outcome: 'success'
  });
  await assert.rejects(() =>
    insertEvent({
      event_id: 'e-term-2', producer_seq: 11, event_type: 'failed',
      is_terminal: true, outcome: 'failure'
    })
  );
});

test('terminal_derived: is_terminal must match event_type', async () => {
  await assert.rejects(() =>
    insertEvent({ event_id: 'e-bad-term', producer_seq: 20, event_type: 'progress', is_terminal: true })
  );
});

test('outcome_tied: a completed event must carry outcome=success', async () => {
  await assert.rejects(() =>
    insertEvent({
      event_id: 'e-bad-outcome', producer_seq: 21, run_generation: 1, generation_key: 1,
      event_type: 'completed', is_terminal: true, outcome: 'failure'
    })
  );
});

test('scope_gen: a run-scope event requires a run_generation', async () => {
  await assert.rejects(() =>
    insertEvent({ event_id: 'e-bad-scope', producer_seq: 22, event_scope: 'run', run_generation: null })
  );
});

test('origin_link: a captain_order task without order_ref is rejected at the DDL level', async () => {
  await assert.rejects(() =>
    store.runExclusive(async (conn) => {
      await conn.query(
        `INSERT INTO tasks
           (task_id, home_uuid, kind, title, task_origin, status, created_at, updated_at)
         VALUES ('bad-origin', 'h', 'ship', 'x', 'captain_order', 'queued', $1, $1)`,
        [NOW]
      );
    })
  );
});

import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { runExclusive } from '../lib/internal-runtime.mjs';
import { runVerb } from '../lib/coordinator.mjs';
import { ValidationError } from '../lib/errors.mjs';
import { IdempotencyConflictError, StateTransitionError } from '../lib/errors-s1.mjs';
import * as domain from '../lib/domain-store.mjs';
import { createTask, beginRun, appendEvent, launchMarkerFor } from '../lib/domain-store.mjs';
import { mkFixtureHome, cleanupAll } from './helpers.mjs';

// S1 owns the DDL/API negative tests for its tables and API guards (spec-amend-s4
// section 3.2). None of these tests use a table or verb owned by a later slice.
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

// A task with one open generation-1 run. Returns the task revision after begin-run.
async function taskWithOpenRun(store, taskId = 't1') {
  await createTask(store, {
    taskId, kind: 'ship', title: 'x', origin: 'internal', internalReason: 'r', commandId: `c-create-${taskId}`
  });
  await beginRun(store, { taskId, expectedRevision: 1, commandId: `c-begin-${taskId}` });
  return 2; // revision after create(1) -> begin-run(2)
}

test('t_generic_append_rejects_terminal_and_lifecycle', async () => {
  const { store } = await freshStore();
  const rev = await taskWithOpenRun(store);

  const rejectedTypes = [
    'completed', 'failed', // terminal
    'spawn_intent', 'spawned', 'running_verified', 'cleanup_started', 'cleaned', 'archived', 'cancelled', // lifecycle
    'created', 'anomaly', 'identity_lost' // coordinator/reconciler-generated, not caller-appendable
  ];
  for (const type of rejectedTypes) {
    await assert.rejects(
      () => appendEvent(store, {
        taskId: 't1', generation: 1, eventType: type, producer: 'crewmate', seq: 10,
        expectedRevision: rev, commandId: `c-${type}`
      }),
      // Assert the SPECIFIC wrapper guard fired, not merely "some StateTransitionError".
      // Removing the generic terminal/lifecycle guard makes these types fall through to
      // the later status-transition rejection, which carries a different message; pinning
      // the wrapper message keeps this test mutation-sensitive to that guard (QA-s1-q49
      // finding 5.1).
      (e) => e instanceof StateTransitionError
        && e.code === 'state_transition'
        && /not appendable through generic 'event'|must use its owning wrapper/.test(e.message),
      `type ${type} must be rejected by the generic-append wrapper guard`
    );
  }

  // A type that is not even a known event type is a plain validation error.
  await assert.rejects(
    () => appendEvent(store, {
      taskId: 't1', generation: 1, eventType: 'not_a_type', producer: 'crewmate', seq: 10,
      expectedRevision: rev, commandId: 'c-unknown'
    }),
    (e) => e instanceof ValidationError
  );

  // No rejected type was inserted: only the two coordinator-generated events exist,
  // and the task revision never advanced.
  const evs = await rows(store, 'SELECT event_type FROM task_events ORDER BY event_type');
  assert.deepEqual(evs.map((r) => r.event_type).sort(), ['created', 'spawn_intent']);
  const t = await rows(store, 'SELECT revision FROM tasks WHERE task_id = $1', ['t1']);
  assert.equal(Number(t[0].revision), rev, 'no rejected append advanced the revision');
});

test('t_no_caller_deliver_switch', async () => {
  const { store, fmHome } = await freshStore();
  await taskWithOpenRun(store);
  const env = { ...process.env, FM_HOME: fmHome };

  // The generic event verb has no --deliver switch; delivery is store-owned.
  await assert.rejects(
    () => runVerb(
      ['event', 't1', '--generation', '1', '--type', 'progress', '--producer', 'crewmate',
        '--seq', '1', '--expected-revision', '2', '--command-id', 'd1', '--deliver', 'true'],
      { env }
    ),
    (e) => e instanceof ValidationError && /deliver/.test(e.message)
  );
  await assert.rejects(
    () => runVerb(
      ['event', 't1', '--generation', '1', '--type', 'progress', '--producer', 'crewmate',
        '--seq', '1', '--expected-revision', '2', '--command-id', 'd2', '--no-deliver'],
      { env }
    ),
    (e) => e instanceof ValidationError
  );

  // S1 has no delivery surface at all: no outbox table exists.
  const tabs = await rows(store,
    "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'");
  assert.ok(!tabs.map((r) => r.table_name).includes('outbox'), 'S1 must not create an outbox table');
});

test('t_one_open_run', async () => {
  const { store } = await freshStore();
  await taskWithOpenRun(store);

  const open = await rows(store, 'SELECT run_generation FROM runs WHERE task_id = $1 AND closed_at IS NULL', ['t1']);
  assert.equal(open.length, 1, 'exactly one open run after begin-run');

  // A second begin-run from the now-spawning task is rejected, so a second open run
  // is never created through the verb surface.
  await assert.rejects(
    () => beginRun(store, { taskId: 't1', expectedRevision: 2, commandId: 'c-begin-2' }),
    (e) => e instanceof StateTransitionError
  );
  const stillOne = await rows(store, 'SELECT run_generation FROM runs WHERE task_id = $1 AND closed_at IS NULL', ['t1']);
  assert.equal(stillOne.length, 1, 'still exactly one open run');

  // The ux_one_open_run index enforces it at the store level too: a raw second open
  // run insert for the same task fails.
  await assert.rejects(
    () => runExclusive(store, async (conn) => {
      await conn.query(
        `INSERT INTO runs (task_id, run_generation, status, binding_state, backend, bind_nonce,
           launch_marker, launch_dir, registration_path, launch_deadline_at, cleanup_state, created_at)
           VALUES ('t1', 2, 'spawning', 'spawning', 'tmux', 'n2', 'm2', '', 'r2', now(), 'not_started', now())`
      );
    }),
    (e) => e.code === '23505' || /ux_one_open_run/.test(String(e.message))
  );
});

test('t_origin_link_immutable', async () => {
  const { store } = await freshStore();

  // Invalid origin/link combinations are rejected at the store API.
  await assert.rejects(
    () => createTask(store, { taskId: 'bad1', kind: 'ship', title: 't', origin: 'captain_order', commandId: 'x1' }),
    (e) => e instanceof ValidationError, 'captain_order requires order_ref'
  );
  await assert.rejects(
    () => createTask(store, { taskId: 'bad2', kind: 'ship', title: 't', origin: 'internal', orderRef: 'O-1', commandId: 'x2' }),
    (e) => e instanceof ValidationError, 'internal must not set order_ref'
  );
  await assert.rejects(
    () => createTask(store, { taskId: 'bad3', kind: 'ship', title: 't', origin: 'captain_order', orderRef: 'O-1', internalReason: 'r', commandId: 'x3' }),
    (e) => e instanceof ValidationError, 'captain_order must not set internal_reason'
  );

  // A valid captain_order task carries its immutable origin/order_ref.
  await createTask(store, { taskId: 'ok1', kind: 'ship', title: 't', origin: 'captain_order', orderRef: 'ORD-9', commandId: 'x4' });
  const t = await rows(store, 'SELECT task_origin, order_ref FROM tasks WHERE task_id = $1', ['ok1']);
  assert.equal(t[0].task_origin, 'captain_order');
  assert.equal(t[0].order_ref, 'ORD-9');

  // There is no S1 API to mutate origin/order_ref, and re-creating an existing task
  // is rejected rather than overwriting it.
  await assert.rejects(
    () => createTask(store, { taskId: 'ok1', kind: 'ship', title: 't', origin: 'internal', internalReason: 'r', commandId: 'x5' }),
    (e) => e instanceof StateTransitionError
  );

  // Immutability is enforced at the store level, not just the combination shape: a
  // still-VALID rewrite (ORD-1 -> ORD-2) is rejected by the immutability trigger
  // (QA-s1-q49 finding 3). Before this guard the combination CHECK alone let it commit.
  await assert.rejects(
    () => runExclusive(store, async (conn) => {
      await conn.query("UPDATE tasks SET order_ref = 'ORD-2' WHERE task_id = 'ok1'");
    }),
    (e) => e.code === '23514' || /origin_immutable/.test(String(e.message))
  );
  // The stored value is untouched by the rejected rewrite.
  const still = await rows(store, 'SELECT order_ref FROM tasks WHERE task_id = $1', ['ok1']);
  assert.equal(still[0].order_ref, 'ORD-9', 'order_ref unchanged after rejected rewrite');

  // Flipping task_origin (a valid-to-valid change of the origin axis) is likewise rejected.
  await assert.rejects(
    () => runExclusive(store, async (conn) => {
      await conn.query("UPDATE tasks SET task_origin = 'internal', order_ref = NULL, internal_reason = 'r' WHERE task_id = 'ok1'");
    }),
    (e) => e.code === '23514' || /origin_immutable/.test(String(e.message))
  );

  // The origin_link CHECK still backs the shape at the store level: a raw insert with
  // a bad combination, and a raw update that would break the link, are both rejected.
  await assert.rejects(
    () => runExclusive(store, async (conn) => {
      await conn.query(
        `INSERT INTO tasks (task_id, home_uuid, kind, title, task_origin, order_ref, internal_reason,
           status, revision, current_generation, created_at, updated_at)
           VALUES ('raw1','h','ship','t','captain_order', NULL, NULL, 'queued', 1, 0, now(), now())`
      );
    }),
    (e) => e.code === '23514' || /origin_link/.test(String(e.message))
  );
  await assert.rejects(
    () => runExclusive(store, async (conn) => {
      await conn.query("UPDATE tasks SET order_ref = NULL WHERE task_id = 'ok1'");
    }),
    // Either guard may fire first (both are 23514); the point is the rewrite is refused.
    (e) => e.code === '23514' || /origin_immutable|origin_link/.test(String(e.message))
  );
});

test('t_launch_marker_derivation', async () => {
  const { store, fmHome } = await freshStore();
  // Recover the store's home_uuid the same way begin-run does.
  const meta = await new PgliteLocalStore({ fmHome }).schemaMeta();
  const homeUuid = meta.home_uuid;

  await createTask(store, { taskId: 't1', kind: 'ship', title: 'x', origin: 'internal', internalReason: 'r', commandId: 'c1' });
  const begun = await beginRun(store, { taskId: 't1', expectedRevision: 1, commandId: 'c2' });

  // The launch marker is the authoritative sha256(home_uuid || task_id || generation
  // || bind_nonce), not a random id (QA-s1-q49 finding 4).
  const expected = launchMarkerFor(homeUuid, 't1', begun.generation, begun.bind_nonce);
  assert.equal(begun.launch_marker, expected, 'launch_marker is the specified derivation');
  assert.match(begun.launch_marker, /^[0-9a-f]{64}$/, 'launch_marker is a sha256 hex digest');

  // The stored run row carries the same derived marker.
  const run = await rows(store, 'SELECT launch_marker, bind_nonce FROM runs WHERE task_id = $1 AND run_generation = $2', ['t1', 1]);
  assert.equal(run[0].launch_marker, expected);
  assert.equal(launchMarkerFor(homeUuid, 't1', 1, run[0].bind_nonce), run[0].launch_marker);
});

test('t_runs_never_terminal_in_s1', async () => {
  const { store } = await freshStore();
  const rev = await taskWithOpenRun(store);
  await appendEvent(store, { taskId: 't1', generation: 1, eventType: 'progress', producer: 'crewmate', seq: 1, expectedRevision: rev, commandId: 'c-p1' });

  // The run stays non-terminal and open through every S1 operation.
  const r = await rows(store, 'SELECT status, binding_state, closed_at FROM runs WHERE task_id = $1', ['t1']);
  assert.equal(r[0].status, 'spawning');
  assert.equal(r[0].binding_state, 'spawning');
  assert.equal(r[0].closed_at, null);

  // No terminal event exists (ux_terminal_per_gen is empty).
  const term = await rows(store, 'SELECT event_id FROM task_events WHERE is_terminal');
  assert.equal(term.length, 0);

  // S1 exposes no verb that closes a run: complete/fail are S2.
  assert.equal(domain.complete, undefined, 'complete belongs to S2');
  assert.equal(domain.fail, undefined, 'fail belongs to S2');

  // The DDL forbids a terminal status without a closed_at (run_closed_iff_terminal).
  await assert.rejects(
    () => runExclusive(store, async (conn) => {
      await conn.query("UPDATE runs SET status = 'completed' WHERE task_id = 't1' AND run_generation = 1");
    }),
    (e) => e.code === '23514' || /run_closed_iff_terminal/.test(String(e.message))
  );
});

test('t_generation_key_and_scope', async () => {
  const { store } = await freshStore();
  const rev = await taskWithOpenRun(store);
  await appendEvent(store, { taskId: 't1', generation: 1, eventType: 'progress', producer: 'crewmate', seq: 1, expectedRevision: rev, commandId: 'c-p1' });

  const evs = await rows(store,
    'SELECT event_type, event_scope, run_generation, generation_key FROM task_events ORDER BY event_type');
  const byType = Object.fromEntries(evs.map((e) => [e.event_type, e]));

  // Task-scope 'created': run_generation NULL, generation_key -1.
  assert.equal(byType.created.event_scope, 'task');
  assert.equal(byType.created.run_generation, null);
  assert.equal(Number(byType.created.generation_key), -1);

  // Run-scope events: generation_key equals run_generation.
  for (const t of ['spawn_intent', 'progress']) {
    assert.equal(byType[t].event_scope, 'run');
    assert.equal(Number(byType[t].run_generation), 1);
    assert.equal(Number(byType[t].generation_key), 1);
  }

  // scope_gen: a task-scope event may not carry a run_generation.
  await assert.rejects(
    () => runExclusive(store, async (conn) => {
      await conn.query(
        `INSERT INTO task_events (event_id, task_id, event_scope, run_generation, producer_id, producer_seq,
           event_type, generation_key, is_terminal, outcome, payload_hash, created_at)
           VALUES ('raw-a','t1','task', 1, 'coordinator', 99, 'progress', -1, false, NULL, 'h', now())`
      );
    }),
    (e) => e.code === '23514' || /scope_gen/.test(String(e.message))
  );

  // generation_key_matches: a run-scope event's generation_key must equal run_generation.
  await assert.rejects(
    () => runExclusive(store, async (conn) => {
      await conn.query(
        `INSERT INTO task_events (event_id, task_id, event_scope, run_generation, producer_id, producer_seq,
           event_type, generation_key, is_terminal, outcome, payload_hash, created_at)
           VALUES ('raw-b','t1','run', 1, 'coordinator', 98, 'progress', 2, false, NULL, 'h', now())`
      );
    }),
    (e) => e.code === '23514' || /generation_key_matches/.test(String(e.message))
  );
});

test('t_producer_highwater_namespace', async () => {
  const { store } = await freshStore();
  const rev = await taskWithOpenRun(store);
  await appendEvent(store, { taskId: 't1', generation: 1, eventType: 'progress', producer: 'crewmate', seq: 1, expectedRevision: rev, commandId: 'c-p1' });

  const hw = await rows(store,
    'SELECT task_id, run_generation, producer_id, last_seq FROM producer_highwater ORDER BY run_generation, producer_id');
  const key = (r) => `${r.run_generation}/${r.producer_id}=${r.last_seq}`;
  const seen = hw.map(key);

  // The task-scope namespace is run_generation = -1 (mirroring ux_event_producer_seq).
  assert.ok(seen.includes('-1/coordinator=1'), 'task-scope coordinator high-water at run_generation -1');
  // Run-scope namespaces are keyed by the real generation.
  assert.ok(seen.includes('1/coordinator=1'), 'run-scope coordinator high-water at generation 1');
  assert.ok(seen.includes('1/crewmate=1'), 'run-scope crewmate high-water at generation 1');

  // A later crewmate progress with a gap advances the same namespace row (gaps ok).
  await appendEvent(store, { taskId: 't1', generation: 1, eventType: 'progress', producer: 'crewmate', seq: 5, expectedRevision: rev + 1, commandId: 'c-p5' });
  const hw2 = await rows(store,
    "SELECT last_seq FROM producer_highwater WHERE task_id = 't1' AND run_generation = 1 AND producer_id = 'crewmate'");
  assert.equal(hw2.length, 1, 'PK (task_id, run_generation, producer_id) keeps one row');
  assert.equal(Number(hw2[0].last_seq), 5, 'high-water advanced across the gap');
});

test('t_command_id_required_and_idempotent', async () => {
  const { store } = await freshStore();

  // Every mutating command requires --command-id.
  await assert.rejects(
    () => createTask(store, { taskId: 'n1', kind: 'ship', title: 't', origin: 'internal', internalReason: 'r' }),
    (e) => e instanceof ValidationError && /command-id/.test(e.message)
  );
  await createTask(store, { taskId: 'n1', kind: 'ship', title: 't', origin: 'internal', internalReason: 'r', commandId: 'k1' });
  await assert.rejects(
    () => beginRun(store, { taskId: 'n1', expectedRevision: 1 }),
    (e) => e instanceof ValidationError && /command-id/.test(e.message)
  );

  // Same command-id + same request is an idempotent replay: identical result, no
  // second task, no extra commit_sequence.
  const before = (await rows(store, 'SELECT commit_sequence FROM coordinator_state WHERE id = 1'))[0];
  const first = await createTask(store, { taskId: 'n1', kind: 'ship', title: 't', origin: 'internal', internalReason: 'r', commandId: 'k1' });
  const replay = await createTask(store, { taskId: 'n1', kind: 'ship', title: 't', origin: 'internal', internalReason: 'r', commandId: 'k1' });
  assert.deepEqual(replay, first, 'replay returns the identical stored result');
  const after = (await rows(store, 'SELECT commit_sequence FROM coordinator_state WHERE id = 1'))[0];
  assert.equal(Number(after.commit_sequence), Number(before.commit_sequence), 'replay does not bump commit_sequence');
  const count = await rows(store, "SELECT count(*)::int AS n FROM tasks WHERE task_id = 'n1'");
  assert.equal(count[0].n, 1, 'no duplicate task created');

  // A conflict (same command-id, different request) is not a silent replay.
  await assert.rejects(
    () => createTask(store, { taskId: 'n1', kind: 'scout', title: 'different', origin: 'internal', internalReason: 'r', commandId: 'k1' }),
    (e) => e instanceof IdempotencyConflictError
  );
});

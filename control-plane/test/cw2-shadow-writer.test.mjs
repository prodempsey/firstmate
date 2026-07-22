import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { runVerb } from '../lib/coordinator.mjs';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { readOnlyQuery } from '../lib/cw1-readonly.mjs';
import { createShadowWriter } from '../lib/shadow-writer.mjs';
import { loadAnnotations } from '../lib/cw2-annotations.mjs';
import { beginRun } from '../lib/domain-store.mjs';
import { createTask } from '../lib/domain-store.mjs';
import { mkTempDir, cleanupAll } from './helpers.mjs';

// CW2 Part A - the SHADOW WRITER. Proves its three hard contracts:
//  1. never blocks or fails a legacy op (an injected store failure is caught, logged to the
//     divergence file, and returned - never thrown);
//  2. no fabricated runs (mirroring a full lifecycle for a runless task writes zero run and
//     zero task_event rows beyond the create-task `created` event, and the task stays queued);
//  3. idempotent by deterministic command-id (a double-mirror is a replay / a single row).
// Plus the "where applicable" real-verb branch: a run-scoped status transition drives a real
// `event` once a real open run generation exists.
after(cleanupAll);

async function initStore() {
  const dataDir = path.join(mkTempDir('cp-cw2-sw-'), 'pgdata');
  await runVerb(['init', '--data-dir', dataDir], { env: {} });
  return dataDir;
}
async function q(dataDir, sql, params) {
  const store = new PgliteLocalStore({ dataDir });
  try { return await readOnlyQuery(store, sql, params); } finally { await store.close(); }
}
async function present(dataDir, t) {
  const r = await q(dataDir, "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name=$1", [t]);
  return r.length > 0;
}
async function num(dataDir, t) {
  if (!(await present(dataDir, t))) return 0;
  return Number((await q(dataDir, `SELECT count(*)::int n FROM ${t}`))[0].n);
}

// =====================================================================================
// Contract 1: never blocks or fails a legacy op
// =====================================================================================

test('an injected store failure is caught, logged to the divergence file, and NEVER thrown', async () => {
  const dir = mkTempDir('cp-cw2-fail-');
  const divergenceLog = path.join(dir, 'divergence.jsonl');
  // A store factory whose every domain call throws models an unreachable/broken store.
  const brokenStore = new Proxy({ close: async () => {} }, {
    get(target, prop) {
      if (prop === 'close') return target.close;
      throw new Error('injected store failure');
    }
  });
  const writer = createShadowWriter({
    dataDir: path.join(dir, 'pgdata'),
    divergenceLog,
    storeFactory: () => brokenStore,
    now: () => '1970-01-01T00:00:00.000Z'
  });

  // The "legacy op" is represented by this flag: it must be set regardless of the mirror,
  // proving control returned to the caller and the mirror never threw.
  let legacyOpCompleted = false;
  let outcome;
  await assert.doesNotReject(async () => {
    outcome = await writer.taskFiled({ taskId: 'brk-1', kind: 'ship', title: 'x' });
    legacyOpCompleted = true;
  });
  await writer.close();

  assert.equal(legacyOpCompleted, true, 'the legacy op completed unaffected');
  assert.equal(outcome.ok, false);
  assert.equal(outcome.mode, 'error');
  assert.equal(typeof outcome.error, 'string');
  assert.ok(outcome.error.length > 0, 'the store failure was captured, not thrown');

  assert.ok(fs.existsSync(divergenceLog), 'a divergence log entry was written');
  const lines = fs.readFileSync(divergenceLog, 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l));
  assert.equal(lines.length, 1);
  assert.equal(lines[0].kind, 'shadow_write_error');
  assert.equal(lines[0].task_id, 'brk-1');
  assert.equal(lines[0].reason, outcome.error, 'the logged divergence reason IS the caught store error');
});

test('a store that fails to OPEN is also caught, not thrown (storeFactory throws)', async () => {
  const dir = mkTempDir('cp-cw2-openfail-');
  const divergenceLog = path.join(dir, 'divergence.jsonl');
  const writer = createShadowWriter({
    dataDir: path.join(dir, 'pgdata'),
    divergenceLog,
    storeFactory: () => { throw new Error('cannot open store'); },
    now: () => '1970-01-01T00:00:00.000Z'
  });
  const outcome = await writer.dispatched({ taskId: 'open-1' });
  await writer.close();
  assert.equal(outcome.ok, false);
  assert.match(outcome.error, /cannot open store/);
  assert.ok(fs.existsSync(divergenceLog));
});

// =====================================================================================
// Contract 2: no fabricated runs
// =====================================================================================

test('mirroring a full lifecycle for a runless task fabricates NO run and NO extra event', async () => {
  const dataDir = await initStore();
  const writer = createShadowWriter({ dataDir, now: () => '1970-01-01T00:00:00.000Z' });
  const filed = await writer.taskFiled({ taskId: 'life-1', kind: 'ship', title: 'Life 1', repo: 'r' });
  const disp = await writer.dispatched({ taskId: 'life-1', detail: { window: 'fm-life-1' } });
  const blocked = await writer.statusTransition({ taskId: 'life-1', status: 'blocked', detail: 'waiting' });
  const done = await writer.completed({ taskId: 'life-1' });
  const arch = await writer.archived({ taskId: 'life-1' });
  await writer.close();

  assert.equal(filed.mode, 'verb');
  assert.equal(filed.verb, 'create-task');
  // Every run-based action degraded to an annotation (no run exists).
  for (const o of [disp, blocked, done, arch]) assert.equal(o.mode, 'annotation', `${o.action} must annotate`);

  assert.equal(await num(dataDir, 'runs'), 0, 'ZERO run rows - no fabricated runs');
  const events = await q(dataDir, 'SELECT event_type FROM task_events ORDER BY event_id');
  assert.deepEqual(events.map((e) => e.event_type), ['created'], 'only the create-task `created` event exists');
  assert.equal((await q(dataDir, 'SELECT status FROM tasks WHERE task_id=$1', ['life-1']))[0].status, 'queued');

  const anns = await loadAnnotations(new PgliteLocalStore({ dataDir }));
  const actions = anns.filter((a) => a.task_id === 'life-1').map((a) => a.action).sort();
  assert.deepEqual(actions, ['archived', 'dispatched', 'status:blocked', 'completed'].sort());
});

// =====================================================================================
// Contract 3: idempotent by deterministic command-id
// =====================================================================================

test('double-mirror is safe: create-task replays and an annotation is a single row', async () => {
  const dataDir = await initStore();
  const writer = createShadowWriter({ dataDir, now: () => '1970-01-01T00:00:00.000Z' });

  const a1 = await writer.taskFiled({ taskId: 'idem-1', kind: 'ship', title: 'Idem' });
  const a2 = await writer.taskFiled({ taskId: 'idem-1', kind: 'ship', title: 'Idem' });
  assert.equal(a1.ok && a2.ok, true);
  assert.equal(await num(dataDir, 'tasks'), 1, 'one task after double create-task');

  const d1 = await writer.dispatched({ taskId: 'idem-1', detail: { w: 1 } });
  const d2 = await writer.dispatched({ taskId: 'idem-1', detail: { w: 1 } });
  await writer.close();
  assert.equal(d1.annotation_written, 1, 'first dispatch inserts');
  assert.equal(d2.annotation_written, 0, 'second dispatch is a no-op (idempotent)');
  const anns = await loadAnnotations(new PgliteLocalStore({ dataDir }));
  assert.equal(anns.filter((a) => a.task_id === 'idem-1' && a.action === 'dispatched').length, 1, 'one dispatch annotation row');
});

test('an already-existing task (different command-id) does not throw and logs a benign divergence', async () => {
  const dataDir = await initStore();
  // Pre-create the task through the real verb with a DIFFERENT command-id (as the CW1
  // migration would have), then mirror a file for it: the mirror's create-task rejects
  // "task already exists" and that is logged, never thrown.
  const store = new PgliteLocalStore({ dataDir });
  await createTask(store, { taskId: 'pre-1', kind: 'ship', title: 'Pre', origin: 'internal', internalReason: 'seed', commandId: 'seed:pre-1' });
  await store.close();

  const divergenceLog = path.join(mkTempDir('cp-cw2-pre-'), 'div.jsonl');
  const writer = createShadowWriter({ dataDir, divergenceLog, now: () => '1970-01-01T00:00:00.000Z' });
  const outcome = await writer.taskFiled({ taskId: 'pre-1', kind: 'ship', title: 'Pre' });
  await writer.close();
  assert.equal(outcome.ok, false);
  assert.match(outcome.error, /already exists/);
  assert.equal(await num(dataDir, 'tasks'), 1, 'still exactly one task');
});

// =====================================================================================
// "Where applicable" real-verb branch: a status event fires once a real run exists
// =====================================================================================

test('statusTransition drives a real `event` when an open run generation exists', async () => {
  const dataDir = await initStore();
  // Create a task and begin a run through the landed verbs (the shadow writer NEVER does
  // this itself - it only ever acts on a run some real launch path created).
  const store = new PgliteLocalStore({ dataDir });
  const c = await createTask(store, { taskId: 'run-1', kind: 'ship', title: 'Run', origin: 'internal', internalReason: 'seed', commandId: 'seed:create:run-1' });
  await beginRun(store, { taskId: 'run-1', expectedRevision: c.revision, commandId: 'seed:begin:run-1' });
  await store.close();

  const writer = createShadowWriter({ dataDir, now: () => '1970-01-01T00:00:00.000Z' });
  const prog = await writer.statusTransition({ taskId: 'run-1', status: 'progress', detail: { note: 'mirrored progress' } });
  await writer.close();

  assert.equal(prog.mode, 'verb', 'a real open run generation makes this a real event, not an annotation');
  assert.equal(prog.verb, 'event');
  const events = await q(dataDir, "SELECT event_type FROM task_events WHERE task_id=$1 AND event_type='progress'", ['run-1']);
  assert.equal(events.length, 1, 'a real progress event was appended to the open generation');
});

import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { runExclusive } from '../lib/internal-runtime.mjs';
import { IdempotencyConflictError, CausalOrderingError } from '../lib/errors-s1.mjs';
import { createTask, beginRun, appendEvent } from '../lib/domain-store.mjs';
import { mkFixtureHome, cleanupAll } from './helpers.mjs';

// S1 adversarial contract tests. Every assertion is mutation-sensitive: it pins
// exact counts, revisions, error codes, or anomaly fields, so a regression that
// weakens atomicity, idempotency, causal ordering, or the conflict audit fails
// loudly rather than silently.
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
  const r = await rows(store, 'SELECT domain_revision, projection_revision, commit_sequence FROM coordinator_state WHERE id = 1');
  return {
    domain: Number(r[0].domain_revision),
    projection: Number(r[0].projection_revision),
    commit: Number(r[0].commit_sequence)
  };
}

test('t_concurrent_begin_run_serializes', async () => {
  const { store, fmHome } = await freshStore();
  const other = new PgliteLocalStore({ fmHome });
  await createTask(store, { taskId: 't1', kind: 'ship', title: 'x', origin: 'internal', internalReason: 'r', commandId: 'c-create' });

  // Two begin-run commands race on the same task with the same expected revision,
  // through two independent store instances contending on the real flock.
  const settled = await Promise.allSettled([
    beginRun(store, { taskId: 't1', expectedRevision: 1, commandId: 'c-a' }),
    beginRun(other, { taskId: 't1', expectedRevision: 1, commandId: 'c-b' })
  ]);
  const fulfilled = settled.filter((s) => s.status === 'fulfilled');
  const rejected = settled.filter((s) => s.status === 'rejected');
  assert.equal(fulfilled.length, 1, 'exactly one begin-run wins');
  assert.equal(rejected.length, 1, 'exactly one begin-run loses');
  assert.ok(rejected[0].reason instanceof CausalOrderingError, 'the loser is a causal-ordering rejection');

  // The winner produced exactly one open generation; the loser mutated nothing.
  const open = await rows(store, 'SELECT run_generation FROM runs WHERE task_id = $1 AND closed_at IS NULL', ['t1']);
  assert.equal(open.length, 1);
  const t = await rows(store, 'SELECT revision, current_generation FROM tasks WHERE task_id = $1', ['t1']);
  assert.equal(Number(t[0].revision), 2, 'revision advanced by exactly one');
  assert.equal(Number(t[0].current_generation), 1);
  const c = await counters(store);
  assert.deepEqual(c, { domain: 2, projection: 0, commit: 2 }, 'one create + one begin committed; the loser did not');
  const anom = await rows(store, "SELECT count(*)::int AS n FROM anomalies WHERE anomaly_class = 'causal_ordering_violation'");
  assert.equal(anom[0].n, 1, 'the losing command left exactly one causal anomaly');
});

test('t_recovers_when_writer_exits_before_revision_bump', async () => {
  const { store } = await freshStore();
  // A first successful command establishes the domain schema and counters = 1.
  await createTask(store, { taskId: 't1', kind: 'ship', title: 'x', origin: 'internal', internalReason: 'r', commandId: 'c1' });
  const before = await counters(store);
  assert.deepEqual(before, { domain: 1, projection: 0, commit: 1 });

  // A second command crashes AFTER its domain write but BEFORE the counter bump and
  // command_results insert. The whole bundle must roll back atomically.
  await assert.rejects(
    () => createTask(store, {
      taskId: 't2', kind: 'ship', title: 'y', origin: 'internal', internalReason: 'r', commandId: 'c2'
    }, { fault: () => { throw new Error('simulated writer crash before revision bump'); } }),
    /simulated writer crash/
  );

  // Nothing from the crashed command survived: no task, no counter change, no
  // command_results ghost (so a retry is not mistaken for a replay).
  const t2 = await rows(store, "SELECT count(*)::int AS n FROM tasks WHERE task_id = 't2'");
  assert.equal(t2[0].n, 0, 'crashed task row rolled back');
  assert.deepEqual(await counters(store), before, 'counters unchanged by the crashed command');
  const cr = await rows(store, "SELECT count(*)::int AS n FROM command_results WHERE command_id = 'c2'");
  assert.equal(cr[0].n, 0, 'no command_results ghost from the crashed command');

  // A clean retry of the same command now succeeds and advances exactly once.
  const retry = await createTask(store, { taskId: 't2', kind: 'ship', title: 'y', origin: 'internal', internalReason: 'r', commandId: 'c2' });
  assert.equal(retry.revision, 1);
  assert.deepEqual(await counters(store), { domain: 2, projection: 0, commit: 2 });
});

test('t_idempotent_command_replay', async () => {
  const { store } = await freshStore();
  const created = await createTask(store, { taskId: 't1', kind: 'ship', title: 'x', origin: 'internal', internalReason: 'r', commandId: 'c1' });
  assert.deepEqual(await counters(store), { domain: 1, projection: 0, commit: 1 });

  const createdAgain = await createTask(store, { taskId: 't1', kind: 'ship', title: 'x', origin: 'internal', internalReason: 'r', commandId: 'c1' });
  assert.deepEqual(createdAgain, created, 'create replay is identical');
  assert.deepEqual(await counters(store), { domain: 1, projection: 0, commit: 1 }, 'replay bumps no counter');

  const begun = await beginRun(store, { taskId: 't1', expectedRevision: 1, commandId: 'c2' });
  assert.deepEqual(await counters(store), { domain: 2, projection: 0, commit: 2 });
  const begunAgain = await beginRun(store, { taskId: 't1', expectedRevision: 1, commandId: 'c2' });
  assert.deepEqual(begunAgain, begun, 'begin-run replay returns the same generation, nonce, and marker');
  assert.deepEqual(await counters(store), { domain: 2, projection: 0, commit: 2 }, 'begin-run replay bumps no counter');

  const runCount = await rows(store, "SELECT count(*)::int AS n FROM runs WHERE task_id = 't1'");
  assert.equal(runCount[0].n, 1, 'replay created no second run');
});

test('t_conflicting_command_id_audits_and_persists', async () => {
  const { store } = await freshStore();
  await createTask(store, { taskId: 't1', kind: 'ship', title: 'x', origin: 'internal', internalReason: 'r', commandId: 'c1' });
  await beginRun(store, { taskId: 't1', expectedRevision: 1, commandId: 'cX' });
  const afterBegin = await counters(store);

  // Reuse command-id cX with a DIFFERENT request (a different expected revision).
  const conflicting = { taskId: 't1', expectedRevision: 2, commandId: 'cX' };
  await assert.rejects(() => beginRun(store, conflicting), (e) => e instanceof IdempotencyConflictError && e.code === 'idempotency_conflict');

  // The rejected command mutated nothing: still one generation, unchanged revision,
  // no domain-revision bump.
  const t = await rows(store, 'SELECT revision, current_generation FROM tasks WHERE task_id = $1', ['t1']);
  assert.equal(Number(t[0].revision), 2);
  assert.equal(Number(t[0].current_generation), 1);
  const runCount = await rows(store, "SELECT count(*)::int AS n FROM runs WHERE task_id = 't1'");
  assert.equal(runCount[0].n, 1, 'no extra run from the conflicting command');
  assert.equal((await counters(store)).domain, afterBegin.domain, 'conflict did not bump domain_revision');

  // The anomaly is persisted and queryable, keyed by the offending command.
  const anoms = await rows(store,
    "SELECT anomaly_class, status, occurrence_count, terminal_fingerprint, task_id FROM anomalies WHERE anomaly_class = 'idempotency_conflict'");
  assert.equal(anoms.length, 1);
  assert.equal(anoms[0].status, 'active');
  assert.equal(Number(anoms[0].occurrence_count), 1);
  assert.equal(anoms[0].terminal_fingerprint, 'cX');
  assert.equal(anoms[0].task_id, 't1');

  // Reobserving the identical conflict coalesces onto the same row (count++), and
  // never deletes the audit row.
  await assert.rejects(() => beginRun(store, conflicting), (e) => e instanceof IdempotencyConflictError);
  const anoms2 = await rows(store,
    "SELECT occurrence_count FROM anomalies WHERE anomaly_class = 'idempotency_conflict'");
  assert.equal(anoms2.length, 1, 'still exactly one coalesced anomaly row');
  assert.equal(Number(anoms2[0].occurrence_count), 2, 'occurrence_count incremented on reobservation');
});

test('t_event_ordering_under_contention', async () => {
  const { store, fmHome } = await freshStore();
  const other = new PgliteLocalStore({ fmHome });
  await createTask(store, { taskId: 't1', kind: 'ship', title: 'x', origin: 'internal', internalReason: 'r', commandId: 'c1' });
  await beginRun(store, { taskId: 't1', expectedRevision: 1, commandId: 'c2' }); // revision -> 2

  // Sequential monotonic appends thread the revision and the producer sequence.
  await appendEvent(store, { taskId: 't1', generation: 1, eventType: 'progress', producer: 'crewmate', seq: 1, expectedRevision: 2, commandId: 'e1' });
  await appendEvent(store, { taskId: 't1', generation: 1, eventType: 'progress', producer: 'crewmate', seq: 2, expectedRevision: 3, commandId: 'e2' });
  await appendEvent(store, { taskId: 't1', generation: 1, eventType: 'progress', producer: 'crewmate', seq: 3, expectedRevision: 4, commandId: 'e3' });

  const ordered = await rows(store,
    "SELECT producer_seq FROM task_events WHERE task_id = 't1' AND producer_id = 'crewmate' ORDER BY producer_seq");
  assert.deepEqual(ordered.map((r) => Number(r.producer_seq)), [1, 2, 3], 'appends are totally ordered by producer_seq');
  const hw = await rows(store, "SELECT last_seq FROM producer_highwater WHERE task_id = 't1' AND run_generation = 1 AND producer_id = 'crewmate'");
  assert.equal(Number(hw[0].last_seq), 3);

  // A non-monotonic producer sequence (<= high-water) is a causal violation.
  await assert.rejects(
    () => appendEvent(store, { taskId: 't1', generation: 1, eventType: 'progress', producer: 'crewmate', seq: 3, expectedRevision: 5, commandId: 'e-dup' }),
    (e) => e instanceof CausalOrderingError
  );

  // Contention: two workers race the SAME next event. Exactly one commits; the
  // other loses on the revision CAS (a stale causal token). No duplicate row.
  const settled = await Promise.allSettled([
    appendEvent(store, { taskId: 't1', generation: 1, eventType: 'progress', producer: 'crewmate', seq: 4, expectedRevision: 5, commandId: 'e-a' }),
    appendEvent(other, { taskId: 't1', generation: 1, eventType: 'progress', producer: 'crewmate', seq: 4, expectedRevision: 5, commandId: 'e-b' })
  ]);
  assert.equal(settled.filter((s) => s.status === 'fulfilled').length, 1, 'exactly one contended append commits');
  const loser = settled.find((s) => s.status === 'rejected');
  assert.ok(loser.reason instanceof CausalOrderingError, 'the contended loser is a causal rejection');

  const seq4 = await rows(store, "SELECT count(*)::int AS n FROM task_events WHERE task_id = 't1' AND producer_id = 'crewmate' AND producer_seq = 4");
  assert.equal(seq4[0].n, 1, 'no duplicate seq-4 event under contention');
  const hw2 = await rows(store, "SELECT last_seq FROM producer_highwater WHERE task_id = 't1' AND run_generation = 1 AND producer_id = 'crewmate'");
  assert.equal(Number(hw2[0].last_seq), 4, 'high-water reflects exactly one winning append');
});

test('t_stale_revision_rejected', async () => {
  const { store } = await freshStore();
  await createTask(store, { taskId: 't1', kind: 'ship', title: 'x', origin: 'internal', internalReason: 'r', commandId: 'c1' });
  await beginRun(store, { taskId: 't1', expectedRevision: 1, commandId: 'c2' }); // revision -> 2

  // begin-run with a stale expected revision is rejected and audited.
  await assert.rejects(
    () => beginRun(store, { taskId: 't1', expectedRevision: 1, commandId: 'c-stale-begin' }),
    (e) => e instanceof CausalOrderingError && e.code === 'causal_ordering_violation'
  );
  // event with a stale expected revision is rejected and audited.
  await assert.rejects(
    () => appendEvent(store, { taskId: 't1', generation: 1, eventType: 'progress', producer: 'crewmate', seq: 1, expectedRevision: 1, commandId: 'c-stale-event' }),
    (e) => e instanceof CausalOrderingError
  );

  // Neither rejection mutated the task, and both were audited as causal violations.
  const t = await rows(store, 'SELECT revision, current_generation FROM tasks WHERE task_id = $1', ['t1']);
  assert.equal(Number(t[0].revision), 2, 'stale rejections did not advance the revision');
  assert.equal(Number(t[0].current_generation), 1);
  const runCount = await rows(store, "SELECT count(*)::int AS n FROM runs WHERE task_id = 't1'");
  assert.equal(runCount[0].n, 1, 'the stale begin-run created no run');
  const evs = await rows(store, "SELECT count(*)::int AS n FROM task_events WHERE event_type = 'progress'");
  assert.equal(evs[0].n, 0, 'the stale event was not appended');
  const anoms = await rows(store, "SELECT count(*)::int AS n FROM anomalies WHERE anomaly_class = 'causal_ordering_violation' AND detail_json->>'reason' = 'stale_revision'");
  assert.ok(anoms[0].n >= 2, 'both stale rejections recorded a causal anomaly');
});

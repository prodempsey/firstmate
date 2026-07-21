import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { runExclusive } from '../lib/internal-runtime.mjs';
import { runVerb } from '../lib/coordinator.mjs';
import { createTask, beginRun } from '../lib/domain-store.mjs';
import { completeRun } from '../lib/domain-store-s2.mjs';
import {
  claimConsumer, next, claimDelivery, markApplied, ack, readCursor, readReceipt
} from '../lib/domain-store-s4.mjs';
import { FirstMateConsumer } from '../lib/firstmate-consumer.mjs';
import { FileLedgerSink } from '../lib/sinks.mjs';
import { mkFixtureHome, mkTempDir, cleanupAll } from './helpers.mjs';

// Contract S4: the consumer surface as the amended spec pins it (section 8, S4 row).
// The lease is single and self-service; `next` returns exactly the minimum unacked
// outbox row by true MIN(outbox_id) (never cursor+1); claim-delivery/mark-applied/ack
// walk the receipt from claimed to applied to acked; the four mutating verbs bump
// commit_sequence, only ack bumps domain_revision, projection_revision never moves, and
// no consumer verb takes --deliver or --expected-revision.
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
  return { domain: Number(r[0].domain_revision), projection: Number(r[0].projection_revision), commit: Number(r[0].commit_sequence) };
}

// TEST-ONLY stand-in for S3's commit-running (identical to the S2 suites' fixture):
// promotes a begun generation to running through the in-package seam without touching
// the coordinator counters, so a later verb's own delta stays measurable.
async function promoteToRunning(store, taskId, generation, revision) {
  await runExclusive(store, async (conn) => {
    await conn.query("UPDATE runs SET status='open', binding_state='bound_verified' WHERE task_id=$1 AND run_generation=$2", [taskId, generation]);
    await conn.query("UPDATE tasks SET status='running', revision=$2 WHERE task_id=$1", [taskId, revision + 1]);
  });
  return revision + 1;
}

async function runningTask(store, taskId) {
  await createTask(store, { taskId, kind: 'ship', title: 'x', origin: 'internal', internalReason: 'r', commandId: `c-create-${taskId}` });
  await beginRun(store, { taskId, expectedRevision: 1, commandId: `c-begin-${taskId}` });
  return promoteToRunning(store, taskId, 1, 2);
}

// Produce one deliverable (`completed`) outbox row for taskId and return its identity.
async function deliver(store, taskId, rev, commandId = `c-done-${taskId}`) {
  await completeRun(store, { taskId, generation: 1, expectedRevision: rev, outcome: 'success', producer: 'crewmate', seq: 1, evidence: {}, commandId });
  const r = await rows(store, 'SELECT outbox_id, event_id, task_id, event_type FROM outbox WHERE task_id=$1 ORDER BY outbox_id DESC LIMIT 1', [taskId]);
  return { outbox_id: Number(r[0].outbox_id), event_id: r[0].event_id, task_id: r[0].task_id, event_type: r[0].event_type };
}

async function deliverable(store, taskId) {
  const rev = await runningTask(store, taskId);
  return deliver(store, taskId, rev);
}

async function claim(store, opts = {}) {
  return claimConsumer(store, { bootId: opts.bootId ?? 'boot-a', pid: opts.pid ?? 1000, ttlMs: opts.ttlMs, commandId: opts.commandId ?? 'c-claim' }, opts.now === undefined ? {} : { now: opts.now });
}

// Verb-level apply+ack with a direct sink result (no sink adapter under test here).
async function applyAndAck(store, token, row, prefix) {
  await claimDelivery(store, { outboxId: row.outbox_id, ownerToken: token, sinkKind: 'disposition', commandId: `${prefix}-cd` });
  await markApplied(store, { eventId: row.event_id, ownerToken: token, sinkResult: { ok: true, event_id: row.event_id }, commandId: `${prefix}-ma` });
  return ack(store, { outboxId: row.outbox_id, ownerToken: token, commandId: `${prefix}-ak` });
}

async function initHome() {
  const { fmHome } = mkFixtureHome();
  const s = new PgliteLocalStore({ fmHome });
  await s.init({ homeLabel: 'test' });
  await s.close();
  return fmHome;
}

test('t_claim_consumer_grants_and_renews_lease', async () => {
  const { store } = await freshStore();
  const granted = await claim(store, { commandId: 'cc1' });
  assert.equal(granted.granted, true, 'first claim grants');
  assert.equal(granted.renewed, false);
  assert.equal(granted.owner_epoch, 1, 'first epoch is 1');
  assert.ok(typeof granted.owner_token === 'string' && granted.owner_token.length > 0);

  const renewed = await claim(store, { commandId: 'cc2' });
  assert.equal(renewed.renewed, true, 'a same-owner re-claim renews');
  assert.equal(renewed.owner_epoch, 2, 'epoch increments on renew');
  assert.notEqual(renewed.owner_token, granted.owner_token, 'owner_token rotates on renew');

  const lease = await rows(store, 'SELECT owner_token, owner_epoch FROM consumer_leases WHERE consumer_id=$1', ['firstmate']);
  assert.equal(lease.length, 1, 'exactly one lease row for the single consumer');
  assert.equal(lease[0].owner_token, renewed.owner_token);
  assert.equal(Number(lease[0].owner_epoch), 2);
});

test('t_next_returns_minimum_unacked_only', async () => {
  const { store } = await freshStore();
  const d1 = await deliverable(store, 't1'); // outbox_id 1
  const d2 = await deliverable(store, 't2'); // outbox_id 2
  assert.ok(d2.outbox_id > d1.outbox_id);
  const c = await claim(store, { commandId: 'cc' });

  const head = await next(store, { ownerToken: c.owner_token });
  assert.equal(head.row.outbox_id, d1.outbox_id, 'next returns the single minimum unacked row');
  assert.equal(head.row.event_id, d1.event_id);
  // The shape is one row (or null), never a batch.
  assert.ok(!Array.isArray(head.row) && head.row.task_id === 't1');

  await applyAndAck(store, c.owner_token, head.row, 'm1');
  const head2 = await next(store, { ownerToken: c.owner_token });
  assert.equal(head2.row.outbox_id, d2.outbox_id, 'after ack, the next minimum is returned');
});

test('t_next_skips_gapped_outbox_id', async () => {
  const { store } = await freshStore();
  const rev1 = await runningTask(store, 't1');
  const d1 = await deliver(store, 't1', rev1); // outbox_id 1

  // Burn an IDENTITY id: a faulted terminal allocates then rolls back an outbox_id, so
  // the sequence advances but no row commits (ruling RISK#2; IDENTITY is non-transactional).
  const rev2 = await runningTask(store, 't2');
  await assert.rejects(() => completeRun(store, {
    taskId: 't2', generation: 1, expectedRevision: rev2, outcome: 'success', producer: 'crewmate', seq: 1, evidence: {}, commandId: 'c-burn-2'
  }, { fault: () => { throw new Error('burn'); } }), /burn/);
  const d2 = await deliver(store, 't2', rev2, 'c-done-2'); // outbox_id 3 (2 burned)

  const ids = (await rows(store, 'SELECT outbox_id FROM outbox ORDER BY outbox_id')).map((r) => Number(r.outbox_id));
  assert.ok(d2.outbox_id > d1.outbox_id + 1, `expected a burned-id gap, got ${JSON.stringify(ids)}`);
  assert.ok(!ids.includes(d1.outbox_id + 1), 'the burned id is not a committed row');

  const c = await claim(store, { commandId: 'cc' });
  const first = await next(store, { ownerToken: c.owner_token });
  assert.equal(first.row.outbox_id, d1.outbox_id, 'next returns the true MIN, not cursor+1');
  await applyAndAck(store, c.owner_token, first.row, 'g1');
  const second = await next(store, { ownerToken: c.owner_token });
  assert.equal(second.row.outbox_id, d2.outbox_id, 'next skips the burned id and returns the next committed row');
});

test('t_claim_delivery_creates_claimed_receipt_no_effect', async () => {
  const { store } = await freshStore();
  const d = await deliverable(store, 't1');
  const c = await claim(store, { commandId: 'cc' });

  const res = await claimDelivery(store, { outboxId: d.outbox_id, ownerToken: c.owner_token, sinkKind: 'disposition', commandId: 'cd1' });
  assert.equal(res.state, 'claimed');
  assert.equal(res.sink_idempotency_key, d.event_id, 'the sink idempotency key is the event_id');
  assert.equal(res.delivery_attempts, 1, 'claim-delivery records one delivery attempt');

  const receipt = await readReceipt(store, { eventId: d.event_id });
  assert.equal(receipt.state, 'claimed');
  assert.equal(receipt.applied_at, null, 'no applied_at yet');
  assert.equal(receipt.sink_result_hash, null, 'no sink result yet - no external effect has happened');
  const ob = await rows(store, 'SELECT delivered_at, acked_at FROM outbox WHERE outbox_id=$1', [d.outbox_id]);
  assert.equal(ob[0].delivered_at, null, 'claim-delivery does not mark the outbox delivered');
  assert.equal(ob[0].acked_at, null);
});

test('t_mark_applied_transitions_claimed_to_applied', async () => {
  const { store } = await freshStore();
  const d = await deliverable(store, 't1');
  const c = await claim(store, { commandId: 'cc' });
  await claimDelivery(store, { outboxId: d.outbox_id, ownerToken: c.owner_token, sinkKind: 'disposition', commandId: 'cd1' });

  const res = await markApplied(store, { eventId: d.event_id, ownerToken: c.owner_token, sinkResult: { applied: true, event_id: d.event_id }, commandId: 'ma1' });
  assert.equal(res.state, 'applied');
  assert.ok(typeof res.sink_result_hash === 'string' && res.sink_result_hash.length === 64);

  const receipt = await readReceipt(store, { eventId: d.event_id });
  assert.equal(receipt.state, 'applied');
  assert.ok(receipt.applied_at !== null, 'applied_at is stamped');
  assert.ok(receipt.sink_result_hash !== null, 'sink_result_hash is recorded');
  const ob = await rows(store, 'SELECT delivered_at, acked_at FROM outbox WHERE outbox_id=$1', [d.outbox_id]);
  assert.ok(ob[0].delivered_at !== null, 'mark-applied stamps the outbox delivered_at');
  assert.equal(ob[0].acked_at, null, 'but not yet acked');
});

test('t_ack_advances_cursor_and_marks_outbox', async () => {
  const { store } = await freshStore();
  const d = await deliverable(store, 't1');
  const c = await claim(store, { commandId: 'cc' });
  await claimDelivery(store, { outboxId: d.outbox_id, ownerToken: c.owner_token, sinkKind: 'disposition', commandId: 'cd1' });
  await markApplied(store, { eventId: d.event_id, ownerToken: c.owner_token, sinkResult: { ok: true }, commandId: 'ma1' });

  const res = await ack(store, { outboxId: d.outbox_id, ownerToken: c.owner_token, commandId: 'ak1' });
  assert.equal(res.acked, true);
  assert.equal(res.cursor, d.outbox_id);

  const ob = await rows(store, 'SELECT acked_at FROM outbox WHERE outbox_id=$1', [d.outbox_id]);
  assert.ok(ob[0].acked_at !== null, 'the outbox row is acked');
  const cursor = await readCursor(store);
  assert.equal(cursor.last_acked_outbox_id, d.outbox_id, 'the cursor advances to the acked id');
});

test('t_consumer_drains_outbox_in_order', async () => {
  const { store } = await freshStore();
  const d1 = await deliverable(store, 't1');
  const d2 = await deliverable(store, 't2');
  const d3 = await deliverable(store, 't3');
  const ordered = [d1.outbox_id, d2.outbox_id, d3.outbox_id];
  assert.deepEqual(ordered, [...ordered].sort((a, b) => a - b), 'produced in ascending outbox_id order');

  const sinkDir = mkTempDir('cp-s4-sink-');
  const sink = new FileLedgerSink({ dir: sinkDir });
  const consumer = new FirstMateConsumer(store, { bootId: 'boot-a', pid: 1000, sink });
  await consumer.claim();
  const summary = await consumer.drainUntilIdle();

  assert.equal(summary.idle, true, 'the loop drains to an empty outbox');
  assert.deepEqual(summary.handled.map((h) => h.outbox_id), ordered, 'rows drained in ascending outbox_id order');
  const cursor = await readCursor(store);
  assert.equal(cursor.last_acked_outbox_id, d3.outbox_id, 'the cursor ends at the last row');
  const head = await next(store, { ownerToken: consumer.ownerToken });
  assert.equal(head.row, null, 'nothing left unacked');
});

test('t_counter_deltas_per_s4_verb', async () => {
  const { store } = await freshStore();
  const d = await deliverable(store, 't1');
  await claim(store, { commandId: 'cc1' }); // establish lease + schema

  const step = async (label, fn, expCommit, expDomain) => {
    const b = await counters(store);
    await fn();
    const a = await counters(store);
    assert.equal(a.commit - b.commit, expCommit, `${label}: commit_sequence delta`);
    assert.equal(a.domain - b.domain, expDomain, `${label}: domain_revision delta`);
    assert.equal(a.projection, 0, `${label}: projection_revision never moves`);
  };

  // claim-consumer renew -> commit only (rotates the token we then use).
  let token;
  await step('claim-consumer', async () => { token = (await claim(store, { commandId: 'cc2' })).owner_token; }, 1, 0);
  await step('next', async () => { await next(store, { ownerToken: token }); }, 0, 0);
  await step('claim-delivery', async () => { await claimDelivery(store, { outboxId: d.outbox_id, ownerToken: token, sinkKind: 'disposition', commandId: 'cd1' }); }, 1, 0);
  await step('mark-applied', async () => { await markApplied(store, { eventId: d.event_id, ownerToken: token, sinkResult: { ok: true }, commandId: 'ma1' }); }, 1, 0);
  await step('ack', async () => { await ack(store, { outboxId: d.outbox_id, ownerToken: token, commandId: 'ak1' }); }, 1, 1);
});

test('t_no_caller_deliver_switch_s4', async () => {
  const fmHome = await initHome();
  const env = { ...process.env, FM_HOME: fmHome };
  await assert.rejects(
    () => runVerb(['ack', '--consumer', 'firstmate', '--owner-token', 'x', '--outbox-id', '1', '--deliver'], { env }),
    /deliver/,
    'a consumer verb rejects a caller --deliver switch'
  );
  await assert.rejects(
    () => runVerb(['next', '--consumer', 'firstmate', '--owner-token', 'x', '--no-deliver'], { env }),
    /deliver/,
    'and rejects --no-deliver'
  );
});

test('t_no_expected_revision_on_consumer_verbs', async () => {
  const fmHome = await initHome();
  const env = { ...process.env, FM_HOME: fmHome };
  await assert.rejects(
    () => runVerb(['claim-delivery', '--consumer', 'firstmate', '--owner-token', 'x', '--outbox-id', '1', '--sink-kind', 'disposition', '--expected-revision', '5'], { env }),
    /expected-revision/,
    'consumer verbs are not task-causal and reject --expected-revision'
  );
  await assert.rejects(
    () => runVerb(['ack', '--consumer', 'firstmate', '--owner-token', 'x', '--outbox-id', '1', '--expected-revision', '5'], { env }),
    /expected-revision/
  );
});

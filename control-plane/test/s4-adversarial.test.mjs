import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { runExclusive } from '../lib/internal-runtime.mjs';
import { createTask, beginRun } from '../lib/domain-store.mjs';
import { completeRun } from '../lib/domain-store-s2.mjs';
import {
  claimConsumer, next, claimDelivery, markApplied, ack, readReceipt, readCursor
} from '../lib/domain-store-s4.mjs';
import { FirstMateConsumer } from '../lib/firstmate-consumer.mjs';
import { FileLedgerSink, AmbiguousSinkTimeoutError } from '../lib/sinks.mjs';
import { mkFixtureHome, mkTempDir, cleanupAll } from './helpers.mjs';

// Adversarial S4: at-least-once delivery with idempotent-by-event_id apply must survive
// every crash cut between claim, sink effect, mark-applied, and ack; two owners
// contending for the single lease must resolve to exactly one winner with an audited
// conflict; a fenced/stale token must be rejected; the cursor must never regress; a
// duplicate delivery must not duplicate the effect; and a sink that cannot confirm
// idempotency must record an anomaly and STOP rather than lie about apply.
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

async function anomalyCount(store, klass) {
  const r = await rows(store, 'SELECT count(*)::int AS n FROM anomalies WHERE anomaly_class = $1', [klass]);
  return r[0].n;
}

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

async function deliver(store, taskId, rev, commandId = `c-done-${taskId}`) {
  await completeRun(store, { taskId, generation: 1, expectedRevision: rev, outcome: 'success', producer: 'crewmate', seq: 1, evidence: {}, commandId });
  const r = await rows(store, 'SELECT outbox_id, event_id FROM outbox WHERE task_id=$1 ORDER BY outbox_id DESC LIMIT 1', [taskId]);
  return { outbox_id: Number(r[0].outbox_id), event_id: r[0].event_id, task_id: taskId };
}

async function deliverable(store, taskId) {
  const rev = await runningTask(store, taskId);
  return deliver(store, taskId, rev);
}

async function claim(store, opts = {}) {
  return claimConsumer(store, {
    bootId: opts.bootId ?? 'boot-a', pid: opts.pid ?? 1000, ttlMs: opts.ttlMs, commandId: opts.commandId ?? 'c-claim'
  }, opts.now === undefined ? {} : { now: opts.now });
}

async function applyAndAck(store, token, row, prefix) {
  await claimDelivery(store, { outboxId: row.outbox_id, ownerToken: token, sinkKind: 'disposition', commandId: `${prefix}-cd` });
  await markApplied(store, { eventId: row.event_id, ownerToken: token, sinkResult: { ok: true, event_id: row.event_id }, commandId: `${prefix}-ma` });
  return ack(store, { outboxId: row.outbox_id, ownerToken: token, commandId: `${prefix}-ak` });
}

function ledgerCount(dir, sinkKind) {
  const d = path.join(dir, sinkKind);
  if (!fs.existsSync(d)) return 0;
  return fs.readdirSync(d).filter((f) => f.endsWith('.json')).length;
}

const WORKER = fileURLToPath(new URL('./workers/crash-consumer-writer.mjs', import.meta.url));

async function setupForCrash(taskId = 't1') {
  const { store, fmHome } = await freshStore();
  const d = await deliverable(store, taskId);
  const c = await claim(store, { commandId: 'cc' });
  const sinkDir = mkTempDir('cp-s4-sink-');
  await store.close(); // release the flock so the child process can open the store
  return { fmHome, d, token: c.owner_token, sinkDir };
}

function runCrashChild({ fmHome, token, d, sinkDir, cut, prefix = 'x' }) {
  return spawnSync(process.execPath, [WORKER], {
    env: {
      ...process.env, CP_FM_HOME: fmHome, CP_OWNER_TOKEN: token, CP_OUTBOX_ID: String(d.outbox_id),
      CP_EVENT_ID: d.event_id, CP_SINK_KIND: 'disposition', CP_SINK_DIR: sinkDir, CP_CRASH_CUT: cut, CP_CMD_PREFIX: prefix
    },
    encoding: 'utf8', timeout: 60000
  });
}

test('t_crash_after_claim_before_effect', async () => {
  const { fmHome, d, token, sinkDir } = await setupForCrash();
  const child = runCrashChild({ fmHome, token, d, sinkDir, cut: 'after_claim_before_sink' });
  assert.equal(child.status, 51, `worker must hard-exit after claim before effect (stderr: ${child.stderr})`);

  const store = new PgliteLocalStore({ fmHome });
  assert.equal((await readReceipt(store, { eventId: d.event_id })).state, 'claimed', 'the claimed receipt survived');
  assert.equal(ledgerCount(sinkDir, 'disposition'), 0, 'no sink effect happened before the crash');

  const consumer = new FirstMateConsumer(store, { ownerToken: token, sink: new FileLedgerSink({ dir: sinkDir }) });
  const out = await consumer.drainOne();
  assert.equal(out.acked, true);
  assert.equal(ledgerCount(sinkDir, 'disposition'), 1, 'recovery applies the effect exactly once');
  assert.equal((await readCursor(store)).last_acked_outbox_id, d.outbox_id);
  assert.equal((await next(store, { ownerToken: token })).row, null, 'nothing left unacked');
});

test('t_crash_during_effect', async () => {
  const { fmHome, d, token, sinkDir } = await setupForCrash();
  const child = runCrashChild({ fmHome, token, d, sinkDir, cut: 'during_sink' });
  assert.equal(child.status, 54, `worker must hard-exit during the sink effect (stderr: ${child.stderr})`);

  const store = new PgliteLocalStore({ fmHome });
  assert.equal((await readReceipt(store, { eventId: d.event_id })).state, 'claimed');
  assert.equal(ledgerCount(sinkDir, 'disposition'), 0, 'the atomic sink left no committed effect (temp only)');

  const consumer = new FirstMateConsumer(store, { ownerToken: token, sink: new FileLedgerSink({ dir: sinkDir }) });
  await consumer.drainOne();
  assert.equal(ledgerCount(sinkDir, 'disposition'), 1, 'recovery re-drives the sink to exactly one durable effect');
  assert.equal((await readCursor(store)).last_acked_outbox_id, d.outbox_id);
});

test('t_at_least_once_crash_between_apply_and_ack', async () => {
  const { fmHome, d, token, sinkDir } = await setupForCrash();
  const child = runCrashChild({ fmHome, token, d, sinkDir, cut: 'after_sink_before_mark' });
  assert.equal(child.status, 52, `worker must hard-exit after the sink effect before mark (stderr: ${child.stderr})`);

  const store = new PgliteLocalStore({ fmHome });
  assert.equal((await readReceipt(store, { eventId: d.event_id })).state, 'claimed', 'receipt still claimed - apply not yet marked');
  assert.equal(ledgerCount(sinkDir, 'disposition'), 1, 'the sink effect committed once before the crash');

  const consumer = new FirstMateConsumer(store, { ownerToken: token, sink: new FileLedgerSink({ dir: sinkDir }) });
  const out = await consumer.drainOne();
  assert.equal(out.acked, true);
  assert.equal(out.already_applied, true, 'recovery re-drove the sink, which deduped by event_id');
  assert.equal(ledgerCount(sinkDir, 'disposition'), 1, 'still exactly one effect after recovery - at-least-once, applied once');
  assert.equal((await readReceipt(store, { eventId: d.event_id })).state, 'applied');
  assert.equal((await readCursor(store)).last_acked_outbox_id, d.outbox_id);
});

test('t_crash_after_mark_applied_before_ack', async () => {
  const { fmHome, d, token, sinkDir } = await setupForCrash();
  const child = runCrashChild({ fmHome, token, d, sinkDir, cut: 'after_mark_before_ack' });
  assert.equal(child.status, 53, `worker must hard-exit after mark before ack (stderr: ${child.stderr})`);

  const store = new PgliteLocalStore({ fmHome });
  assert.equal((await readReceipt(store, { eventId: d.event_id })).state, 'applied', 'the receipt is applied but not acked');
  const obBefore = await rows(store, 'SELECT delivered_at, acked_at FROM outbox WHERE outbox_id=$1', [d.outbox_id]);
  assert.ok(obBefore[0].delivered_at !== null && obBefore[0].acked_at === null);

  const consumer = new FirstMateConsumer(store, { ownerToken: token, sink: new FileLedgerSink({ dir: sinkDir }) });
  const out = await consumer.drainOne();
  assert.equal(out.recovered, 'applied_without_ack', 'recovery only needs the ack; no second sink call');
  assert.equal(ledgerCount(sinkDir, 'disposition'), 1, 'the effect is never re-applied');
  assert.equal((await readCursor(store)).last_acked_outbox_id, d.outbox_id);
});

test('t_two_consumers_contend_one_lease', async () => {
  const { store } = await freshStore();
  const a = await claim(store, { bootId: 'A', pid: 1, commandId: 'ca' });
  const before = await counters(store);
  const anomBefore = await anomalyCount(store, 'consumer_lease_conflict');

  await assert.rejects(
    () => claim(store, { bootId: 'B', pid: 2, commandId: 'cb' }),
    (e) => e.code === 'consumer_lease_conflict',
    'a different owner cannot take a live lease'
  );

  const afterC = await counters(store);
  assert.equal(afterC.commit - before.commit, 1, 'the audited conflict is one committed write');
  assert.equal(afterC.domain - before.domain, 1, 'and bumps domain_revision');
  assert.equal(await anomalyCount(store, 'consumer_lease_conflict') - anomBefore, 1, 'a consumer_lease_conflict anomaly is recorded');

  const lease = await rows(store, 'SELECT owner_token, owner_boot_id FROM consumer_leases WHERE consumer_id=$1', ['firstmate']);
  assert.equal(lease[0].owner_token, a.owner_token, 'exactly one wins: the original owner still holds the lease');
  assert.equal(lease[0].owner_boot_id, 'A');
});

test('t_stale_token_rejected_on_mutating_and_read', async () => {
  const { store } = await freshStore();
  const d = await deliverable(store, 't1');
  const t0 = '2026-07-21T00:00:00.000Z';
  const a = await claim(store, { bootId: 'A', pid: 1, ttlMs: 1000, commandId: 'ca', now: t0 }); // expires t0 + 1s
  const tLater = '2026-07-21T00:00:05.000Z'; // A has expired
  const b = await claim(store, { bootId: 'B', pid: 2, ttlMs: 90000, commandId: 'cb', now: tLater }); // takeover; B now live

  // READ with the fenced token A -> LeaseConflictError, and NO anomaly (a read has no
  // transaction that may write one).
  const anomBefore = await anomalyCount(store, 'consumer_lease_conflict');
  await assert.rejects(() => next(store, { ownerToken: a.owner_token }, { now: tLater }), (e) => e.code === 'consumer_lease_conflict');
  assert.equal(await anomalyCount(store, 'consumer_lease_conflict'), anomBefore, 'the read raised no anomaly');

  // MUTATING with the fenced token A -> audited consumer_lease_conflict.
  const before = await counters(store);
  await assert.rejects(
    () => claimDelivery(store, { outboxId: d.outbox_id, ownerToken: a.owner_token, sinkKind: 'disposition', commandId: 'cdA' }, { now: tLater }),
    (e) => e.code === 'consumer_lease_conflict'
  );
  const afterC = await counters(store);
  assert.equal(afterC.domain - before.domain, 1, 'the fenced mutating verb audits +1 domain');
  assert.equal(await anomalyCount(store, 'consumer_lease_conflict') - anomBefore, 1, 'and records the anomaly');

  // The true holder (B) still works.
  const ok = await claimDelivery(store, { outboxId: d.outbox_id, ownerToken: b.owner_token, sinkKind: 'disposition', commandId: 'cdB' }, { now: tLater });
  assert.equal(ok.state, 'claimed');
});

test('t_cursor_never_goes_backward', async () => {
  const { store } = await freshStore();
  const d1 = await deliverable(store, 't1');
  const d2 = await deliverable(store, 't2');
  const c = await claim(store, { commandId: 'cc' });

  await applyAndAck(store, c.owner_token, (await next(store, { ownerToken: c.owner_token })).row, 'a');
  assert.equal((await readCursor(store)).last_acked_outbox_id, d1.outbox_id);
  await applyAndAck(store, c.owner_token, (await next(store, { ownerToken: c.owner_token })).row, 'b');
  assert.equal((await readCursor(store)).last_acked_outbox_id, d2.outbox_id);

  // A replayed ack of the earlier row (same command-id) never regresses the cursor.
  await ack(store, { outboxId: d1.outbox_id, ownerToken: c.owner_token, commandId: 'a-ak' });
  assert.equal((await readCursor(store)).last_acked_outbox_id, d2.outbox_id, 'a replayed ack does not move the cursor backward');

  // A fresh-command ack of an already-acked row is a gap (nothing unacked) and rejected.
  await assert.rejects(() => ack(store, { outboxId: d1.outbox_id, ownerToken: c.owner_token, commandId: 'fresh-ak' }), (e) => e.code === 'state_transition');
  assert.equal((await readCursor(store)).last_acked_outbox_id, d2.outbox_id, 'and the cursor is unchanged');
});

test('t_receipt_dedup_duplicate_delivery', async () => {
  const { store } = await freshStore();
  const d = await deliverable(store, 't1');
  const c = await claim(store, { commandId: 'cc' });

  await claimDelivery(store, { outboxId: d.outbox_id, ownerToken: c.owner_token, sinkKind: 'disposition', commandId: 'cd1' });
  const r2 = await claimDelivery(store, { outboxId: d.outbox_id, ownerToken: c.owner_token, sinkKind: 'disposition', commandId: 'cd2' });
  assert.equal(r2.delivery_attempts, 2, 'two delivery attempts are recorded');
  const rc = await rows(store, 'SELECT count(*)::int AS n FROM consumer_receipts WHERE event_id=$1', [d.event_id]);
  assert.equal(rc[0].n, 1, 'but exactly one receipt row (deduped by (consumer_id,event_id))');

  const sinkDir = mkTempDir('cp-s4-sink-');
  const sink = new FileLedgerSink({ dir: sinkDir });
  const a1 = await sink.apply('disposition', d.event_id, { event_id: d.event_id });
  const a2 = await sink.apply('disposition', d.event_id, { event_id: d.event_id });
  assert.equal(a1.alreadyApplied, false);
  assert.equal(a2.alreadyApplied, true, 'the second sink call for the same event_id is deduped');
  assert.deepEqual(a2.result, a1.result, 'and returns the previous result');
  assert.equal(ledgerCount(sinkDir, 'disposition'), 1, 'exactly one durable effect for the event_id');

  await markApplied(store, { eventId: d.event_id, ownerToken: c.owner_token, sinkResult: a1.result, commandId: 'ma1' });
  await ack(store, { outboxId: d.outbox_id, ownerToken: c.owner_token, commandId: 'ak1' });
  const rc2 = await rows(store, 'SELECT count(*)::int AS n FROM consumer_receipts WHERE event_id=$1', [d.event_id]);
  assert.equal(rc2[0].n, 1, 'still one receipt after apply+ack');
});

test('t_ack_already_acked_is_idempotent_via_command_id', async () => {
  const { store } = await freshStore();
  const d = await deliverable(store, 't1');
  const c = await claim(store, { commandId: 'cc' });
  await claimDelivery(store, { outboxId: d.outbox_id, ownerToken: c.owner_token, sinkKind: 'disposition', commandId: 'cd1' });
  await markApplied(store, { eventId: d.event_id, ownerToken: c.owner_token, sinkResult: { ok: true }, commandId: 'ma1' });
  const first = await ack(store, { outboxId: d.outbox_id, ownerToken: c.owner_token, commandId: 'ak1' });

  const before = await counters(store);
  const replay = await ack(store, { outboxId: d.outbox_id, ownerToken: c.owner_token, commandId: 'ak1' });
  assert.deepEqual(replay, first, 'the same command-id replays the stored result');
  assert.deepEqual(await counters(store), before, 'a replayed ack moves no counter');
  assert.equal((await readCursor(store)).last_acked_outbox_id, d.outbox_id, 'and the cursor is unchanged');
});

test('t_ack_gap_rejected', async () => {
  const { store } = await freshStore();
  const rev1 = await runningTask(store, 't1');
  const d1 = await deliver(store, 't1', rev1); // outbox_id 1 (min unacked)
  const d2 = await deliverable(store, 't2');    // outbox_id 2
  const c = await claim(store, { commandId: 'cc' });

  await assert.rejects(
    () => ack(store, { outboxId: d2.outbox_id, ownerToken: c.owner_token, commandId: 'gap1' }),
    (e) => e.code === 'state_transition' && /minimum unacked/.test(e.message),
    'acking past the minimum unacked is a gap ack'
  );
  await assert.rejects(
    () => ack(store, { outboxId: 9999, ownerToken: c.owner_token, commandId: 'gap2' }),
    (e) => e.code === 'state_transition',
    'acking a nonexistent id is likewise not the minimum'
  );
  assert.equal((await readCursor(store)).last_acked_outbox_id, 0, 'a rejected gap ack never advances the cursor');
  assert.ok(d1.outbox_id < d2.outbox_id);
});

test('t_sink_idempotency_unknown_raises_anomaly_and_stops', async () => {
  const { store } = await freshStore();
  const d = await deliverable(store, 't1');
  const timeoutSink = { apply: async () => { throw new AmbiguousSinkTimeoutError('ambiguous timeout'); } };

  const consumer = new FirstMateConsumer(store, { bootId: 'A', pid: 1, sink: timeoutSink });
  await consumer.claim();
  const before = await counters(store);
  const anomBefore = await anomalyCount(store, 'sink_idempotency_unknown');

  await assert.rejects(() => consumer.drainOne(), (e) => e.code === 'sink_idempotency_unknown', 'the drain stops and surfaces the unknown');

  assert.equal((await counters(store)).domain - before.domain, 1, 'the anomaly is one domain-affecting audit write');
  assert.equal(await anomalyCount(store, 'sink_idempotency_unknown') - anomBefore, 1, 'an active sink_idempotency_unknown anomaly is recorded');

  const receipt = await readReceipt(store, { eventId: d.event_id });
  assert.equal(receipt.state, 'claimed', 'the receipt is NEVER marked applied on an unconfirmed effect');
  const ob = await rows(store, 'SELECT acked_at, delivered_at FROM outbox WHERE outbox_id=$1', [d.outbox_id]);
  assert.equal(ob[0].acked_at, null, 'the row is not acked');
  assert.equal(ob[0].delivered_at, null, 'nor delivered');

  // The loop form also halts cleanly with a stopped summary rather than throwing.
  const looped = new FirstMateConsumer(store, { ownerToken: consumer.ownerToken, sink: timeoutSink });
  const summary = await looped.drainUntilIdle();
  assert.equal(summary.stopped, true);
  assert.equal(summary.reason, 'sink_idempotency_unknown');
});

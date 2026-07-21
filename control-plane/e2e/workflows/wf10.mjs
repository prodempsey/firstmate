import assert from 'node:assert/strict';
import { runExclusive } from '../../lib/internal-runtime.mjs';
import { createTask, beginRun, appendEvent } from '../../lib/domain-store.mjs';
import { recordSpawn, commitRunning } from '../../lib/domain-store-s3.mjs';
import { completeRun } from '../../lib/domain-store-s2.mjs';
import { claimConsumer, claimDelivery, markApplied, ack, readReceipt } from '../../lib/domain-store-s4.mjs';
import { CausalOrderingError, StateTransitionError } from '../../lib/errors-s1.mjs';
import { TerminalConflictError } from '../../lib/errors-s2.mjs';
import { captureOk, probeMatch } from '../fixtures/doubles.mjs';
import { openHostedStore } from '../fixtures/pg.mjs';

// Workflow 10 - Hosted Postgres contract (spec matrix row 869): the storage-seam contract
// suite run against the test-only MULTI-connection hosted adapter (pg.Pool, session advisory
// lock). This is a PORTABILITY gate, not a production hosted deployment (spec 875): it proves
// the same seam invariants the local PGlite store guarantees - concurrent CAS,
// advisory/serializable serialization, terminal conflict, gap ack, and sink-receipt state
// transitions - hold on hosted Postgres. GATED on CP_E2E_PG_URL; the test entry skips loudly
// when it is unset. Every object it creates is dropped afterward.
export const meta = { pgGated: true };

const ALL_TABLES = [
  'consumer_receipts', 'consumer_leases', 'consumer_cursors', 'snapshots', 'outbox',
  'task_events', 'runs', 'producer_highwater', 'command_results', 'anomalies', 'tasks',
  'coordinator_state', 'schema_meta'
];

async function dropEverything(store) {
  await runExclusive(store, async (conn) => {
    for (const t of ALL_TABLES) await conn.exec(`DROP TABLE IF EXISTS ${t} CASCADE`);
    await conn.exec('DROP FUNCTION IF EXISTS cp_tasks_origin_immutable() CASCADE');
  });
}

async function read(store, sql, params) {
  return runExclusive(store, async (conn) => (await conn.query(sql, params)).rows);
}

export async function run() {
  const store = await openHostedStore();
  try {
    await dropEverything(store); // start from a clean scratch schema
    await store.init({ homeLabel: 'wf10-hosted' });

    // Core seam portability: the exclusive contract probe increments once and is durable
    // across exclusive sections on the hosted adapter.
    const p1 = await store.contractProbe();
    assert.equal(p1.after, p1.before + 1, 'hosted contractProbe increments exactly once');
    const p2 = await store.contractProbe();
    assert.equal(p2.before, p1.after, 'the increment is durable across hosted exclusive sections');

    // A verified running task via injected identity doubles (no host process on hosted PG).
    const created = await createTask(store, { taskId: 't-h', kind: 'ship', title: 'hosted', origin: 'internal', internalReason: 'r', commandId: 'c-create' });
    const beg = await beginRun(store, { taskId: 't-h', expectedRevision: created.revision, commandId: 'c-begin' });
    const rs = await recordSpawn(store, { taskId: 't-h', generation: 1, expectedRevision: beg.revision, launchMarker: beg.launch_marker, endpoint: '@0', pane: '%0', regFile: '/reg', commandId: 'c-spawn' }, { captureIdentity: captureOk(0) });
    const cr = await commitRunning(store, { taskId: 't-h', generation: 1, expectedRevision: rs.revision, commandId: 'c-run' }, { probeIdentity: probeMatch() });

    // Concurrent CAS + advisory/serializable serialization: two writers race the SAME
    // expected revision through the pool; the session advisory lock serializes them, so
    // exactly one commits and the other loses the compare-and-set.
    const racers = await Promise.allSettled([
      appendEvent(store, { taskId: 't-h', generation: 1, eventType: 'progress', producer: 'crewmate', seq: 1, expectedRevision: cr.revision, commandId: 'c-cas-a' }),
      appendEvent(store, { taskId: 't-h', generation: 1, eventType: 'progress', producer: 'crewmate', seq: 2, expectedRevision: cr.revision, commandId: 'c-cas-b' })
    ]);
    const wins = racers.filter((r) => r.status === 'fulfilled');
    const losses = racers.filter((r) => r.status === 'rejected');
    assert.equal(wins.length, 1, 'exactly one concurrent CAS writer wins');
    assert.equal(losses.length, 1, 'exactly one concurrent CAS writer loses the compare-and-set');
    assert.ok(losses[0].reason instanceof CausalOrderingError || losses[0].reason instanceof StateTransitionError, 'the loser fails with a typed CAS/causal error');
    const winRev = wins[0].value.revision;

    // Terminal conflict portability: complete, then a conflicting terminal is rejected.
    const done = await completeRun(store, { taskId: 't-h', generation: 1, expectedRevision: winRev, outcome: 'success', producer: 'crewmate', seq: 3, evidence: {}, commandId: 'c-done' });
    await assert.rejects(
      () => completeRun(store, { taskId: 't-h', generation: 1, expectedRevision: done.revision, outcome: 'success', producer: 'crewmate', seq: 4, evidence: {}, commandId: 'c-conflict' }),
      (e) => e instanceof TerminalConflictError,
      'a conflicting terminal is rejected on hosted PG'
    );

    // A second completed task for gap-ack ordering.
    const c2 = await createTask(store, { taskId: 't-h2', kind: 'ship', title: 'hosted2', origin: 'internal', internalReason: 'r', commandId: 'c-create2' });
    const b2 = await beginRun(store, { taskId: 't-h2', expectedRevision: c2.revision, commandId: 'c-begin2' });
    const rs2 = await recordSpawn(store, { taskId: 't-h2', generation: 1, expectedRevision: b2.revision, launchMarker: b2.launch_marker, endpoint: '@1', pane: '%1', regFile: '/reg2', commandId: 'c-spawn2' }, { captureIdentity: captureOk(1) });
    const cr2 = await commitRunning(store, { taskId: 't-h2', generation: 1, expectedRevision: rs2.revision, commandId: 'c-run2' }, { probeIdentity: probeMatch() });
    await completeRun(store, { taskId: 't-h2', generation: 1, expectedRevision: cr2.revision, outcome: 'success', producer: 'crewmate', seq: 1, evidence: {}, commandId: 'c-done2' });

    const rows = await read(store, "SELECT outbox_id, event_id FROM outbox WHERE event_type = 'completed' ORDER BY outbox_id");
    const d1 = { outboxId: Number(rows[0].outbox_id), eventId: rows[0].event_id };
    const d2 = { outboxId: Number(rows[1].outbox_id), eventId: rows[1].event_id };

    const lease = await claimConsumer(store, { bootId: 'boot-h', pid: 9000, commandId: 'c-claim' });
    const tok = { ownerToken: lease.owner_token, ownerEpoch: lease.owner_epoch };

    // Sink-receipt state transitions on hosted PG: claimed -> applied via the S4 verbs.
    await claimDelivery(store, { outboxId: d2.outboxId, ...tok, sinkKind: 'disposition', commandId: 'c-cd2' });
    const rClaimed = await readReceipt(store, { eventId: d2.eventId });
    assert.equal(rClaimed.state, 'claimed', 'the receipt is claimed after claim-delivery');
    await markApplied(store, { eventId: d2.eventId, ...tok, sinkResult: { ok: true, event_id: d2.eventId }, commandId: 'c-ma2' });
    const rApplied = await readReceipt(store, { eventId: d2.eventId });
    assert.equal(rApplied.state, 'applied', 'the receipt is applied after mark-applied');

    // Gap ack: acking d2 before d1 is rejected on hosted PG.
    await assert.rejects(
      () => ack(store, { outboxId: d2.outboxId, ...tok, commandId: 'c-ak2-early' }),
      (e) => e instanceof StateTransitionError,
      'acking out of order is rejected on hosted PG'
    );

    // Contiguous order works.
    await claimDelivery(store, { outboxId: d1.outboxId, ...tok, sinkKind: 'disposition', commandId: 'c-cd1' });
    await markApplied(store, { eventId: d1.eventId, ...tok, sinkResult: { ok: true, event_id: d1.eventId }, commandId: 'c-ma1' });
    const ack1 = await ack(store, { outboxId: d1.outboxId, ...tok, commandId: 'c-ak1' });
    assert.equal(ack1.cursor, d1.outboxId, 'the cursor advances to d1');
    const ack2 = await ack(store, { outboxId: d2.outboxId, ...tok, commandId: 'c-ak2' });
    assert.equal(ack2.cursor, d2.outboxId, 'the cursor advances contiguously to d2 on hosted PG');

    return { hosted: true };
  } finally {
    await dropEverything(store); // leave the scratch database clean
    await store.close();
  }
}

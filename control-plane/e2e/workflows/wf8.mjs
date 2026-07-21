import assert from 'node:assert/strict';
import { completeRun } from '../../lib/domain-store-s2.mjs';
import { claimConsumer, next, claimDelivery, markApplied, ack, readCursor } from '../../lib/domain-store-s4.mjs';
import { LeaseConflictError } from '../../lib/errors-s4.mjs';
import { StateTransitionError } from '../../lib/errors-s1.mjs';
import { doubleRunning } from '../fixtures/lifecycle.mjs';

// Workflow 8 - Concurrent consumers and gap ack (spec matrix row 867): two consumers
// contend for the single consumer lease; only the CURRENT (owner_token, owner_epoch) works
// and a stale token is rejected; and an out-of-order ack (N+1 before N) is rejected. The
// cursor only advances contiguously. No real pane needed.
export const meta = { tmuxRequired: false };

export async function run(h) {
  const store = h.store;

  // Two completed tasks -> two terminal deliveries d1 < d2.
  const t1 = await doubleRunning(store, 't-consumer-a', { seed: 1 });
  await completeRun(store, { taskId: 't-consumer-a', generation: 1, expectedRevision: t1.revision, outcome: 'success', producer: 'crewmate', seq: 1, evidence: {}, commandId: 'c-done-a' });
  const t2 = await doubleRunning(store, 't-consumer-b', { seed: 2 });
  await completeRun(store, { taskId: 't-consumer-b', generation: 1, expectedRevision: t2.revision, outcome: 'success', producer: 'crewmate', seq: 1, evidence: {}, commandId: 'c-done-b' });

  const outbox = await h.read("SELECT outbox_id, event_id FROM outbox WHERE event_type = 'completed' ORDER BY outbox_id");
  assert.equal(outbox.length, 2, 'two terminal deliveries');
  const d1 = { outboxId: Number(outbox[0].outbox_id), eventId: outbox[0].event_id };
  const d2 = { outboxId: Number(outbox[1].outbox_id), eventId: outbox[1].event_id };

  // Consumer A holds the lease.
  const a = await claimConsumer(store, { bootId: 'boot-a', pid: 1000, commandId: 'cc-a1' });

  // Consumer B (a DIFFERENT owner) cannot take over the still-live lease: contention is
  // rejected loudly, not silently granted.
  await assert.rejects(
    () => claimConsumer(store, { bootId: 'boot-b', pid: 2000, commandId: 'cc-b1' }),
    (e) => e instanceof LeaseConflictError,
    'a second owner cannot take over a live lease'
  );

  // A renews (same owner) - the token/epoch ROTATE, so A's own previous token is now stale.
  const a2 = await claimConsumer(store, { bootId: 'boot-a', pid: 1000, commandId: 'cc-a2' });
  assert.equal(a2.owner_epoch, a.owner_epoch + 1, 'epoch increments on renew');
  assert.notEqual(a2.owner_token, a.owner_token, 'the owner token rotates on renew');

  // The stale (rotated-past) token no longer works; only the current one does.
  await assert.rejects(
    () => next(store, { ownerToken: a.owner_token, ownerEpoch: a.owner_epoch }),
    (e) => e instanceof LeaseConflictError,
    'the stale token is rejected'
  );
  const head = await next(store, { ownerToken: a2.owner_token, ownerEpoch: a2.owner_epoch });
  assert.equal(head.row.outbox_id, d1.outboxId, 'next returns only the minimum unacked row');

  // Gap ack: claim+apply d2 out of order, then try to ack it before d1 - rejected because
  // d1 (a smaller id) is still unacked.
  const tok = { ownerToken: a2.owner_token, ownerEpoch: a2.owner_epoch };
  await claimDelivery(store, { outboxId: d2.outboxId, ...tok, sinkKind: 'disposition', commandId: 'cd-d2' });
  await markApplied(store, { eventId: d2.eventId, ...tok, sinkResult: { ok: true, event_id: d2.eventId }, commandId: 'ma-d2' });
  await assert.rejects(
    () => ack(store, { outboxId: d2.outboxId, ...tok, commandId: 'ak-d2-early' }),
    (e) => e instanceof StateTransitionError,
    'acking N+1 before N is rejected'
  );

  // Proper contiguous order: ack d1, then d2 (already applied). The cursor advances exactly
  // to the highest contiguously-acked id.
  await claimDelivery(store, { outboxId: d1.outboxId, ...tok, sinkKind: 'disposition', commandId: 'cd-d1' });
  await markApplied(store, { eventId: d1.eventId, ...tok, sinkResult: { ok: true, event_id: d1.eventId }, commandId: 'ma-d1' });
  const ack1 = await ack(store, { outboxId: d1.outboxId, ...tok, commandId: 'ak-d1' });
  assert.equal(ack1.cursor, d1.outboxId, 'the cursor advances to d1');
  const ack2 = await ack(store, { outboxId: d2.outboxId, ...tok, commandId: 'ak-d2' });
  assert.equal(ack2.cursor, d2.outboxId, 'the cursor advances contiguously to d2');

  const cursor = await readCursor(store, {});
  assert.equal(cursor.last_acked_outbox_id, d2.outboxId, 'the durable cursor is at d2');

  // The rejected takeover deliberately recorded a consumer_lease_conflict audit anomaly. It
  // is an S4-owned audit row (not an S5-remediable one) documenting the contention, so it is
  // explained residue - allowlisted for the finals rather than resolved.
  const leaseConflicts = await h.read("SELECT fingerprint FROM anomalies WHERE anomaly_class = 'consumer_lease_conflict' AND status = 'active'");
  assert.ok(leaseConflicts.length >= 1, 'the contention recorded a consumer_lease_conflict audit anomaly');
  return { expectedActiveAnomalies: leaseConflicts.map((a) => a.fingerprint) };
}

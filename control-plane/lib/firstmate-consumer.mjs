import crypto from 'node:crypto';
import {
  claimConsumer, next, claimDelivery, markApplied, ack,
  readReceipt, recordSinkIdempotencyUnknown, CONSUMER_ID
} from './domain-store-s4.mjs';
import { AmbiguousSinkTimeoutError, defaultResolveSinkKind } from './sinks.mjs';
import { SinkIdempotencyUnknownError } from './errors-s4.mjs';

// The FirstMate consumer drain loop (spec section 8, S4 row). A REAL adapter, not E2E
// scaffolding: it acquires the single consumer lease, then repeatedly takes the minimum
// unacked outbox row and drives it through claim-delivery -> idempotent sink ->
// mark-applied -> ack, renewing the lease at no more than one third of TTL.
//
// The at-least-once + idempotent-apply contract lives in the RECOVERY BRANCHING here,
// applied verbatim from spec section 8.2:
//
//   - No receipt: claim and call the sink.
//   - `claimed` receipt, no applied_at: call or query the sink by event_id; then
//     mark-applied.
//   - Effect completed but process crashed before mark-applied: the repeated sink call
//     returns the same applied result by event_id, then mark-applied.
//   - `applied` receipt but no ack: ack.
//   - Ack attempted out of order: reject.
//
// NO recovery step infers "effect applied" from a `claimed` receipt (spec section 8.2).
// A claimed-but-not-applied row is always re-driven through the sink, which dedups by
// event_id, before it is marked applied.

const DEFAULT_TTL_MS = 90000;

export class FirstMateConsumer {
  constructor(store, {
    consumerId = CONSUMER_ID, ownerToken = null, ownerEpoch = null, leaseExpiresAt = null,
    bootId = null, pid = null, ttlMs = DEFAULT_TTL_MS,
    sink, resolveSinkKind = defaultResolveSinkKind, genCommandId = () => crypto.randomUUID()
  } = {}) {
    if (!sink) throw new Error('FirstMateConsumer requires a sink adapter');
    this.store = store;
    this.consumerId = consumerId;
    this.ownerToken = ownerToken;
    this.ownerEpoch = ownerEpoch;
    this.leaseExpiresAt = leaseExpiresAt;
    this.bootId = bootId;
    this.pid = pid;
    this.ttlMs = ttlMs;
    this.sink = sink;
    this.resolveSinkKind = resolveSinkKind;
    this.genCommandId = genCommandId;
  }

  // Acquire (or renew) the single consumer lease. Records the rotated token/epoch and
  // the new expiry so subsequent verbs fence correctly and renewal can time itself.
  async claim({ now } = {}) {
    if (this.bootId === null || this.pid === null) {
      throw new Error('FirstMateConsumer.claim requires bootId and pid');
    }
    const res = await claimConsumer(this.store, {
      consumerId: this.consumerId, bootId: this.bootId, pid: this.pid,
      ttlMs: this.ttlMs, commandId: this.genCommandId()
    }, now === undefined ? {} : { now });
    this.ownerToken = res.owner_token;
    this.ownerEpoch = res.owner_epoch;
    this.leaseExpiresAt = res.lease_expires_at;
    return res;
  }

  // Renew when within one third of TTL of expiry (spec section 8.1). No-op otherwise.
  async renewIfNeeded({ now = new Date().toISOString() } = {}) {
    if (!this.leaseExpiresAt || this.bootId === null || this.pid === null) return null;
    const nowMs = new Date(now).getTime();
    const expiresMs = new Date(this.leaseExpiresAt).getTime();
    if (expiresMs - nowMs > this.ttlMs / 3) return null;
    return this.claim({ now });
  }

  // Process the single current minimum-unacked outbox row through the recovery-aware
  // sequence. Returns { idle:true } when nothing is unacked, or a summary of the row
  // handled. Throws SinkIdempotencyUnknownError (after recording the anomaly) if the
  // sink cannot confirm by event_id; delivery must stop there rather than lie.
  async drainOne({ now } = {}) {
    const nowOpts = now === undefined ? {} : { now };
    const head = await next(this.store, { consumerId: this.consumerId, ownerToken: this.ownerToken }, nowOpts);
    if (head.row === null) return { idle: true };
    const row = head.row;
    const { outbox_id: outboxId, event_id: eventId } = row;

    const receipt = await readReceipt(this.store, { consumerId: this.consumerId, eventId });

    // Recovery: an `applied` receipt with no ack only needs the ack.
    if (receipt && receipt.state === 'applied') {
      await ack(this.store, {
        consumerId: this.consumerId, outboxId, ownerToken: this.ownerToken, commandId: this.genCommandId()
      }, nowOpts);
      return { outbox_id: outboxId, event_id: eventId, recovered: 'applied_without_ack', acked: true };
    }

    // Recovery: no receipt -> claim then call the sink; a `claimed` receipt with no
    // applied_at -> re-claim (renew, idempotent) then re-drive the sink by event_id.
    const sinkKind = receipt ? receipt.sink_kind : this.resolveSinkKind(row);
    await claimDelivery(this.store, {
      consumerId: this.consumerId, outboxId, ownerToken: this.ownerToken, sinkKind, commandId: this.genCommandId()
    }, nowOpts);

    // Call the sink with event_id as the idempotency key. The sink durably applies, or
    // returns the already-applied result for that same event_id (dedup across a crash).
    let sinkResult;
    try {
      sinkResult = await this.sink.apply(sinkKind, eventId, {
        task_id: row.task_id, event_type: row.event_type, payload_hash: row.payload_hash
      });
    } catch (err) {
      if (err instanceof AmbiguousSinkTimeoutError) {
        // The sink could not confirm by event_id. Record the anomaly through the audit
        // path and STOP - never mark applied on an unconfirmed effect (spec section 8.3).
        // recordSinkIdempotencyUnknown throws SinkIdempotencyUnknownError, which
        // propagates out of the loop.
        await recordSinkIdempotencyUnknown(this.store, {
          consumerId: this.consumerId, eventId, taskId: row.task_id, sinkKind, commandId: this.genCommandId()
        }, nowOpts);
      }
      throw err;
    }

    await markApplied(this.store, {
      consumerId: this.consumerId, eventId, ownerToken: this.ownerToken,
      sinkResult: sinkResult.result, commandId: this.genCommandId()
    }, nowOpts);
    await ack(this.store, {
      consumerId: this.consumerId, outboxId, ownerToken: this.ownerToken, commandId: this.genCommandId()
    }, nowOpts);
    return {
      outbox_id: outboxId, event_id: eventId, applied: true, acked: true,
      already_applied: sinkResult.alreadyApplied === true
    };
  }

  // Drain until the outbox has no unacked rows, or until a bounded maximum. Renews the
  // lease before each row. A sink-idempotency-unknown stop is caught and returned as a
  // stopped summary rather than thrown, so a caller can drive the loop to a clean halt.
  async drainUntilIdle({ now, maxRows = 10000 } = {}) {
    const handled = [];
    for (let i = 0; i < maxRows; i += 1) {
      await this.renewIfNeeded(now === undefined ? {} : { now });
      let outcome;
      try {
        outcome = await this.drainOne(now === undefined ? {} : { now });
      } catch (err) {
        if (err instanceof SinkIdempotencyUnknownError) {
          return { handled, stopped: true, reason: 'sink_idempotency_unknown', detail: err.detail };
        }
        throw err;
      }
      if (outcome.idle) return { handled, idle: true };
      handled.push(outcome);
    }
    return { handled, exhaustedMax: true };
  }
}

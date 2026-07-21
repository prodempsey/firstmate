import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { runExclusive } from './internal-runtime.mjs';
import { ValidationError } from './errors.mjs';
import { StateTransitionError } from './errors-s1.mjs';
import { LeaseConflictError, SinkIdempotencyUnknownError } from './errors-s4.mjs';
import {
  executeCommand, ConflictSignal, ensureInitialized,
  canonicalJson, sha256hex
} from './domain-store.mjs';

// S4 domain layer: the FirstMate consumer side (spec-amend-s4 section 8, S4 row 889).
// Owns three tables - consumer_leases, consumer_cursors, consumer_receipts - and the
// five verbs claim-consumer / next / claim-delivery / mark-applied / ack, plus the
// audit-only sink_idempotency_unknown recorder the drain loop uses.
//
// It adds NO new access path to the database. The four MUTATING verbs reuse S1's
// command envelope (executeCommand) exactly as S2/S3 do, inheriting - never
// reimplementing - the required command-id, idempotent replay by
// command_id + request_hash, the SAVEPOINT-guarded conflict audit, the audit-counter
// contract, and the atomic bundle of domain write + counter bumps + command_results in
// ONE transaction. `next` is a bare locked read (runExclusive + ensureInitialized), the
// same shape as taskHead/verify-running: no command-id, no revision, no counter bump.
//
// S4 emits NO events and needs ZERO edits to domain-store.mjs. It reads the S2 `outbox`
// (produced by prior complete/fail/cancel) and drives its delivery columns
// (delivery_attempts/delivered_at/acked_at); it never edits any S0-S3 module.
//
// DELIVERY IS AT-LEAST-ONCE WITH IDEMPOTENT APPLY (spec section 8.2). The receipt in
// this store and the effect in the sink are two separate stores; a crash may leave the
// effect done but the receipt still `claimed`, or the receipt `applied` but not
// `ack`ed. The recovery rules never infer `applied` from a `claimed` receipt: they
// re-drive the sink by event_id (which the sink dedups) and only then mark-applied.
// A committed receipt no longer means the effect happened.

const SQL_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'sql');
const DOMAIN_SCHEMA_S4 = fs.readFileSync(path.join(SQL_DIR, 'domain-schema-s4.sql'), 'utf8');

const DOMAIN_SCHEMA_S4_KEY = 'domain_schema_s4';
const DOMAIN_SCHEMA_S4_VERSION = 's4';

// The single logical consumer (spec section 8: one FirstMate consumer per DB). The
// consumer_id column is a PK so the table could physically hold more, but the
// operational contract is exactly one; contention is between two OWNERS of that one
// lease (distinct boot_id/pid), never between two consumer ids.
export const CONSUMER_ID = 'firstmate';

// Lease TTL 90s; sink effects are idempotent by event_id, which is what makes a TTL
// this generous safe (spec section 8.1). The claim window for an in-flight receipt
// uses the same bound.
const DEFAULT_LEASE_TTL_MS = 90000;
const DEFAULT_CLAIM_TTL_MS = 90000;

// S4's conflict classes. `lease` is the audited consumer_lease_conflict raised on a
// FENCING failure (a live lease held by a different owner); `sink_unknown` is the
// audited sink_idempotency_unknown the drain loop records when a sink cannot answer by
// event_id. Idempotency/causal are inherited from the envelope defaults unchanged.
const S4_CONFLICT_ERRORS = {
  lease: (detail) =>
    new LeaseConflictError('consumer lease fencing check failed', detail),
  sink_unknown: (detail) =>
    new SinkIdempotencyUnknownError('sink could not confirm idempotency by event_id after an ambiguous timeout', detail)
};

function nowIso() {
  return new Date().toISOString();
}

function requireStr(verb, value, flag) {
  if (typeof value !== 'string' || value.length === 0) {
    throw new ValidationError(`${verb} requires --${flag}`, { verb, flag });
  }
  return value;
}

function requireInt(verb, value, flag, { min } = {}) {
  if (!Number.isInteger(value)) {
    throw new ValidationError(`${verb} requires an integer --${flag}`, { verb, flag });
  }
  if (min !== undefined && value < min) {
    throw new ValidationError(`${verb} --${flag} must be >= ${min}`, { verb, flag, value });
  }
  return value;
}

// The consumer id is fixed to the single logical FirstMate consumer. Supplying a
// different one is a routing error, not a second consumer.
function requireConsumer(verb, consumerId) {
  if (consumerId !== CONSUMER_ID) {
    throw new ValidationError(
      `${verb} operates on the single logical consumer '${CONSUMER_ID}'`,
      { verb, consumer_id: consumerId }
    );
  }
  return consumerId;
}

// Apply the S4 schema idempotently at the start of an S4 domain mutation (the
// applyS2Schema pattern). Every object is IF NOT EXISTS, so this is a no-op after the
// first consumer command. The three tables have no cross-slice FK, so no ordering
// hazard and no defensive cross-schema import.
async function applyS4Schema(conn) {
  await conn.exec(DOMAIN_SCHEMA_S4);
  await conn.query(
    `INSERT INTO schema_meta (key, value) VALUES ($1, $2)
       ON CONFLICT (key) DO NOTHING`,
    [DOMAIN_SCHEMA_S4_KEY, DOMAIN_SCHEMA_S4_VERSION]
  );
}

async function consumerTablePresent(conn, table) {
  const r = await conn.query(
    "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = $1",
    [table]
  );
  return r.rows.length > 0;
}

async function readLease(conn, consumerId) {
  if (!(await consumerTablePresent(conn, 'consumer_leases'))) return null;
  const r = await conn.query(
    'SELECT owner_token, owner_epoch, owner_boot_id, owner_pid, lease_expires_at FROM consumer_leases WHERE consumer_id = $1',
    [consumerId]
  );
  return r.rows[0] || null;
}

// Classify a presented (owner_token, owner_epoch) FENCING TUPLE against the current
// lease (spec section 8.1: "every consumer command carries both"):
//   'holder' - a live lease whose owner_token AND owner_epoch both match;
//   'fenced' - a live lease whose fencing tuple does NOT match (a different owner, OR
//              the same token presented with a stale epoch - either way the caller is
//              acting on superseded lease knowledge and must be fenced);
//   'lapsed' - no lease, or the lease has expired (the caller's own lease lapsed).
// The token and epoch rotate together on every grant/renew/takeover, so a valid token
// always pairs with exactly one epoch; validating both closes the gap where a stale
// epoch rode through on a still-recognized token (qa-s4-q67 finding 1). The distinction
// decides audited (fenced) vs un-audited (lapsed) rejection.
function classifyLease(lease, ownerToken, ownerEpoch, nowMs) {
  if (!lease) return 'lapsed';
  const live = new Date(lease.lease_expires_at).getTime() > nowMs;
  if (!live) return 'lapsed';
  const matches = lease.owner_token === ownerToken && Number(lease.owner_epoch) === ownerEpoch;
  return matches ? 'holder' : 'fenced';
}

// Fencing check for a MUTATING verb. Returns the live lease when the caller holds it.
// A fenced tuple (wrong token OR stale epoch) raises the AUDITED consumer_lease_conflict
// through the sanctioned audit path (ConflictSignal -> savepoint rollback -> anomaly
// persisted). A lapsed lease raises LeaseConflictError DIRECTLY (un-audited): the
// caller's own lease simply expired and it must re-acquire; there is no competing owner
// to record a contention against.
async function requireLeaseHolderForMutation(conn, consumerId, ownerToken, ownerEpoch, nowMs, verb, commandId) {
  const lease = await readLease(conn, consumerId);
  const cls = classifyLease(lease, ownerToken, ownerEpoch, nowMs);
  if (cls === 'holder') return lease;
  if (cls === 'fenced') {
    throw new ConflictSignal('lease', {
      anomalyClass: 'consumer_lease_conflict', taskId: null,
      terminalFingerprint: `${consumerId}:fenced:${ownerToken}:${ownerEpoch}`,
      detail: {
        command_id: commandId, verb, reason: 'fenced_by_live_lease',
        consumer_id: consumerId,
        holder_epoch: Number(lease.owner_epoch), presented_epoch: ownerEpoch,
        holder_boot_id: lease.owner_boot_id, holder_pid: Number(lease.owner_pid)
      }
    });
  }
  throw new LeaseConflictError(
    'consumer lease expired or absent; re-acquire with claim-consumer',
    { consumer_id: consumerId, reason: 'lapsed', verb }
  );
}

async function readReceiptRow(conn, consumerId, eventId) {
  const r = await conn.query(
    `SELECT consumer_id, event_id, state, owner_token, owner_epoch, claimed_at, claim_expires_at,
            sink_kind, sink_idempotency_key, applied_at, sink_result_hash, applied_disposition
       FROM consumer_receipts WHERE consumer_id = $1 AND event_id = $2`,
    [consumerId, eventId]
  );
  return r.rows[0] || null;
}

async function requireOutboxRow(conn, outboxId) {
  if (!(await consumerTablePresent(conn, 'outbox'))) {
    throw new ValidationError(
      'outbox table is absent; no deliverable events have ever been produced (S2 precondition unmet)',
      { outbox_id: outboxId }
    );
  }
  const r = await conn.query(
    'SELECT outbox_id, event_id, task_id, delivery_attempts, acked_at FROM outbox WHERE outbox_id = $1',
    [outboxId]
  );
  if (r.rows.length === 0) {
    throw new StateTransitionError(`no such outbox row: ${outboxId}`, { outbox_id: outboxId });
  }
  return r.rows[0];
}

// claim-consumer: acquire or renew the single consumer lease. Grants when absent,
// takes over an EXPIRED lease (any owner), renews a LIVE lease held by the SAME owner
// (boot_id/pid), and rejects a takeover of a LIVE lease held by a DIFFERENT owner as
// the audited consumer_lease_conflict - "exactly one wins" (ruling RISK#3). Every
// grant/renew/takeover rotates owner_token and increments owner_epoch. commit-sequence
// only (domainChanged:false, ruling RISK#5); the reject audits +1 domain via the
// conflict path.
export async function claimConsumer(store, params, { now = nowIso(), fault } = {}) {
  const consumerId = params.consumerId ?? CONSUMER_ID;
  requireConsumer('claim-consumer', consumerId);
  const bootId = requireStr('claim-consumer', params.bootId, 'boot-id');
  requireInt('claim-consumer', params.pid, 'pid', { min: 0 });
  const ttlMs = params.ttlMs ?? DEFAULT_LEASE_TTL_MS;
  if (!Number.isInteger(ttlMs) || ttlMs <= 0) {
    throw new ValidationError('claim-consumer requires a positive --ttl (seconds)', { ttl_ms: ttlMs });
  }
  const requestHash = sha256hex(canonicalJson({
    verb: 'claim-consumer', consumer_id: consumerId, boot_id: bootId, pid: params.pid, ttl_ms: ttlMs
  }));
  return executeCommand(store, {
    verb: 'claim-consumer', commandId: params.commandId, requestHash, taskId: null, now, fault,
    conflictErrors: S4_CONFLICT_ERRORS,
    mutate: async (conn, ctx) => {
      await applyS4Schema(conn);
      const nowMs = new Date(ctx.now).getTime();
      const lease = await readLease(conn, consumerId);
      const live = lease && new Date(lease.lease_expires_at).getTime() > nowMs;
      const sameOwner = lease && lease.owner_boot_id === bootId && Number(lease.owner_pid) === params.pid;
      if (live && !sameOwner) {
        throw new ConflictSignal('lease', {
          anomalyClass: 'consumer_lease_conflict', taskId: null,
          terminalFingerprint: `${consumerId}:${bootId}:${params.pid}`,
          detail: {
            command_id: ctx.commandId, verb: 'claim-consumer', reason: 'live_lease_held_by_other_owner',
            consumer_id: consumerId, incoming_boot_id: bootId, incoming_pid: params.pid,
            holder_boot_id: lease.owner_boot_id, holder_pid: Number(lease.owner_pid)
          }
        });
      }
      const newEpoch = lease ? Number(lease.owner_epoch) + 1 : 1;
      const newToken = crypto.randomBytes(24).toString('hex');
      const expiresAt = new Date(nowMs + ttlMs).toISOString();
      await conn.query(
        `INSERT INTO consumer_leases
           (consumer_id, owner_token, owner_epoch, owner_boot_id, owner_pid, lease_expires_at, updated_at)
           VALUES ($1,$2,$3,$4,$5,$6,$7)
           ON CONFLICT (consumer_id) DO UPDATE SET
             owner_token = EXCLUDED.owner_token,
             owner_epoch = EXCLUDED.owner_epoch,
             owner_boot_id = EXCLUDED.owner_boot_id,
             owner_pid = EXCLUDED.owner_pid,
             lease_expires_at = EXCLUDED.lease_expires_at,
             updated_at = EXCLUDED.updated_at`,
        [consumerId, newToken, newEpoch, bootId, params.pid, expiresAt, ctx.now]
      );
      return {
        result: {
          consumer_id: consumerId, owner_token: newToken, owner_epoch: newEpoch,
          lease_expires_at: expiresAt, granted: !lease, renewed: !!lease
        },
        committedRevision: null, domainChanged: false
      };
    }
  });
}

// next: locked read of the single minimum-unacked outbox row (spec section 8.2). No
// command-id, no revision, no counter bump. Returns MIN(outbox_id WHERE acked_at IS
// NULL) - never cursor+1 (S2 burns ids on rolled-back terminals; ruling RISK#2) - or
// {row:null} on an empty-but-present outbox. A stale/expired/fenced owner_token raises
// LeaseConflictError with NO anomaly (a read has no transaction that may write one).
export async function next(store, params, { now = nowIso() } = {}) {
  const consumerId = params.consumerId ?? CONSUMER_ID;
  requireConsumer('next', consumerId);
  const ownerToken = requireStr('next', params.ownerToken, 'owner-token');
  const ownerEpoch = requireInt('next', params.ownerEpoch, 'owner-epoch', { min: 1 });
  return runExclusive(store, async (conn) => {
    await ensureInitialized(conn);
    const nowMs = new Date(now).getTime();
    const lease = await readLease(conn, consumerId);
    if (classifyLease(lease, ownerToken, ownerEpoch, nowMs) !== 'holder') {
      throw new LeaseConflictError(
        'owner_token/owner_epoch does not hold the live consumer lease; re-acquire with claim-consumer',
        { consumer_id: consumerId }
      );
    }
    if (!(await consumerTablePresent(conn, 'outbox'))) {
      throw new ValidationError(
        'outbox table is absent; no deliverable events have ever been produced (S2 precondition unmet)',
        { consumer_id: consumerId }
      );
    }
    const r = await conn.query(
      `SELECT outbox_id, event_id, task_id, run_generation, generation_key, task_seq,
              event_type, payload_hash, created_at, delivery_attempts
         FROM outbox WHERE acked_at IS NULL ORDER BY outbox_id ASC LIMIT 1`
    );
    if (r.rows.length === 0) return { consumer_id: consumerId, row: null };
    const row = r.rows[0];
    return {
      consumer_id: consumerId,
      row: {
        outbox_id: Number(row.outbox_id), event_id: row.event_id, task_id: row.task_id,
        run_generation: row.run_generation === null ? null : Number(row.run_generation),
        generation_key: Number(row.generation_key), task_seq: Number(row.task_seq),
        event_type: row.event_type, payload_hash: row.payload_hash,
        created_at: row.created_at, delivery_attempts: Number(row.delivery_attempts)
      }
    };
  });
}

// claim-delivery: create or renew the consumer_receipts row for the outbox row's
// event_id in 'claimed' state; bump the outbox row's delivery_attempts. NO external
// effect happens here (spec section 8.2 step 2). An already-'applied' receipt is a
// recovery no-op: it is NEVER downgraded to 'claimed' (no recovery step un-applies an
// effect). commit-sequence only (domainChanged:false, ruling RISK#5).
export async function claimDelivery(store, params, { now = nowIso(), fault } = {}) {
  const consumerId = params.consumerId ?? CONSUMER_ID;
  requireConsumer('claim-delivery', consumerId);
  requireInt('claim-delivery', params.outboxId, 'outbox-id', { min: 1 });
  const ownerToken = requireStr('claim-delivery', params.ownerToken, 'owner-token');
  const ownerEpoch = requireInt('claim-delivery', params.ownerEpoch, 'owner-epoch', { min: 1 });
  const sinkKind = requireStr('claim-delivery', params.sinkKind, 'sink-kind');
  const claimTtlMs = params.claimTtlMs ?? DEFAULT_CLAIM_TTL_MS;
  const requestHash = sha256hex(canonicalJson({
    verb: 'claim-delivery', consumer_id: consumerId, outbox_id: params.outboxId,
    owner_token: ownerToken, owner_epoch: ownerEpoch, sink_kind: sinkKind
  }));
  return executeCommand(store, {
    verb: 'claim-delivery', commandId: params.commandId, requestHash, taskId: null, now, fault,
    conflictErrors: S4_CONFLICT_ERRORS,
    mutate: async (conn, ctx) => {
      await applyS4Schema(conn);
      const nowMs = new Date(ctx.now).getTime();
      const lease = await requireLeaseHolderForMutation(conn, consumerId, ownerToken, ownerEpoch, nowMs, 'claim-delivery', ctx.commandId);
      const ob = await requireOutboxRow(conn, params.outboxId);
      if (ob.acked_at !== null) {
        throw new StateTransitionError('claim-delivery rejected: outbox row is already acked', {
          consumer_id: consumerId, outbox_id: params.outboxId
        });
      }
      const eventId = ob.event_id;
      const existing = await readReceiptRow(conn, consumerId, eventId);
      if (existing && existing.state === 'applied') {
        return {
          result: {
            consumer_id: consumerId, outbox_id: params.outboxId, event_id: eventId,
            state: 'applied', already_applied: true, delivery_attempts: Number(ob.delivery_attempts)
          },
          committedRevision: null, domainChanged: false
        };
      }
      const claimExpiresAt = new Date(nowMs + claimTtlMs).toISOString();
      // sink_idempotency_key IS the event_id (spec section 8.1): the same key the sink
      // dedups by, so a re-drive of the same outbox row hits the same idempotent effect.
      await conn.query(
        `INSERT INTO consumer_receipts
           (consumer_id, event_id, state, owner_token, owner_epoch, claimed_at, claim_expires_at, sink_kind, sink_idempotency_key)
           VALUES ($1,$2,'claimed',$3,$4,$5,$6,$7,$2)
           ON CONFLICT (consumer_id, event_id) DO UPDATE SET
             owner_token = EXCLUDED.owner_token,
             owner_epoch = EXCLUDED.owner_epoch,
             claimed_at = EXCLUDED.claimed_at,
             claim_expires_at = EXCLUDED.claim_expires_at,
             sink_kind = EXCLUDED.sink_kind`,
        [consumerId, eventId, ownerToken, Number(lease.owner_epoch), ctx.now, claimExpiresAt, sinkKind]
      );
      const upd = await conn.query(
        'UPDATE outbox SET delivery_attempts = delivery_attempts + 1 WHERE outbox_id = $1 RETURNING delivery_attempts',
        [params.outboxId]
      );
      return {
        result: {
          consumer_id: consumerId, outbox_id: params.outboxId, event_id: eventId,
          state: 'claimed', sink_kind: sinkKind, sink_idempotency_key: eventId,
          claim_expires_at: claimExpiresAt, delivery_attempts: Number(upd.rows[0].delivery_attempts)
        },
        committedRevision: null, domainChanged: false
      };
    }
  });
}

// mark-applied: transition the receipt from 'claimed' to 'applied' AFTER the
// idempotent sink has confirmed (spec section 8.2 step 5). Records sink_result_hash +
// applied_disposition and stamps the outbox row's delivered_at. An already-'applied'
// receipt is an idempotent no-op (recovery via a fresh command-id). commit-sequence
// only (domainChanged:false, ruling RISK#5).
export async function markApplied(store, params, { now = nowIso(), fault } = {}) {
  const consumerId = params.consumerId ?? CONSUMER_ID;
  requireConsumer('mark-applied', consumerId);
  const eventId = requireStr('mark-applied', params.eventId, 'event-id');
  const ownerToken = requireStr('mark-applied', params.ownerToken, 'owner-token');
  const ownerEpoch = requireInt('mark-applied', params.ownerEpoch, 'owner-epoch', { min: 1 });
  if (params.sinkResult === undefined) {
    throw new ValidationError('mark-applied requires --sink-result-file', { verb: 'mark-applied' });
  }
  const sinkResultHash = sha256hex(canonicalJson(params.sinkResult));
  const requestHash = sha256hex(canonicalJson({
    verb: 'mark-applied', consumer_id: consumerId, event_id: eventId,
    owner_token: ownerToken, owner_epoch: ownerEpoch, sink_result_hash: sinkResultHash
  }));
  return executeCommand(store, {
    verb: 'mark-applied', commandId: params.commandId, requestHash, taskId: null, now, fault,
    conflictErrors: S4_CONFLICT_ERRORS,
    mutate: async (conn, ctx) => {
      await applyS4Schema(conn);
      const nowMs = new Date(ctx.now).getTime();
      await requireLeaseHolderForMutation(conn, consumerId, ownerToken, ownerEpoch, nowMs, 'mark-applied', ctx.commandId);
      const receipt = await readReceiptRow(conn, consumerId, eventId);
      if (!receipt) {
        throw new StateTransitionError(
          'mark-applied requires an existing claimed receipt; none found (claim-delivery first)',
          { consumer_id: consumerId, event_id: eventId }
        );
      }
      if (receipt.state === 'applied') {
        return {
          result: { consumer_id: consumerId, event_id: eventId, state: 'applied', already_applied: true },
          committedRevision: null, domainChanged: false
        };
      }
      await conn.query(
        `UPDATE consumer_receipts
           SET state = 'applied', applied_at = $1, sink_result_hash = $2, applied_disposition = $3::jsonb
           WHERE consumer_id = $4 AND event_id = $5`,
        [ctx.now, sinkResultHash, JSON.stringify(params.sinkResult), consumerId, eventId]
      );
      const upd = await conn.query(
        'UPDATE outbox SET delivered_at = $1 WHERE event_id = $2 RETURNING outbox_id',
        [ctx.now, eventId]
      );
      if (upd.rows.length === 0) {
        throw new StateTransitionError('mark-applied found no outbox row for this event_id', {
          consumer_id: consumerId, event_id: eventId
        });
      }
      return {
        result: {
          consumer_id: consumerId, event_id: eventId, outbox_id: Number(upd.rows[0].outbox_id),
          state: 'applied', sink_result_hash: sinkResultHash
        },
        committedRevision: null, domainChanged: false
      };
    }
  });
}

// ack: advance the contiguous consumption cursor (spec section 8.2 step 6). Rejects
// unless --outbox-id is the CURRENT minimum unacked row (gap/out-of-order ack -> a
// non-audited StateTransitionError, ruling MINOR), and unless that row's delivery is
// already 'applied' (no recovery step infers applied from a claim). Marks the outbox
// row acked and advances consumer_cursors.last_acked_outbox_id monotonically. This is
// the ONE consumer verb that bumps domain_revision (it mutates operational truth -
// ruling RISK#5). Replay of the same command-id is an idempotent no-op via the
// envelope; a distinct command-id re-acking a now-acked row falls out as a gap ack.
export async function ack(store, params, { now = nowIso(), fault } = {}) {
  const consumerId = params.consumerId ?? CONSUMER_ID;
  requireConsumer('ack', consumerId);
  requireInt('ack', params.outboxId, 'outbox-id', { min: 1 });
  const ownerToken = requireStr('ack', params.ownerToken, 'owner-token');
  const ownerEpoch = requireInt('ack', params.ownerEpoch, 'owner-epoch', { min: 1 });
  const requestHash = sha256hex(canonicalJson({
    verb: 'ack', consumer_id: consumerId, outbox_id: params.outboxId,
    owner_token: ownerToken, owner_epoch: ownerEpoch
  }));
  return executeCommand(store, {
    verb: 'ack', commandId: params.commandId, requestHash, taskId: null, now, fault,
    conflictErrors: S4_CONFLICT_ERRORS,
    mutate: async (conn, ctx) => {
      await applyS4Schema(conn);
      const nowMs = new Date(ctx.now).getTime();
      await requireLeaseHolderForMutation(conn, consumerId, ownerToken, ownerEpoch, nowMs, 'ack', ctx.commandId);
      if (!(await consumerTablePresent(conn, 'outbox'))) {
        throw new ValidationError(
          'outbox table is absent; no deliverable events have ever been produced (S2 precondition unmet)',
          { consumer_id: consumerId }
        );
      }
      const minR = await conn.query(
        'SELECT outbox_id, event_id FROM outbox WHERE acked_at IS NULL ORDER BY outbox_id ASC LIMIT 1'
      );
      if (minR.rows.length === 0) {
        throw new StateTransitionError('ack rejected: no unacked outbox rows remain', {
          consumer_id: consumerId, outbox_id: params.outboxId
        });
      }
      const minId = Number(minR.rows[0].outbox_id);
      if (minId !== params.outboxId) {
        throw new StateTransitionError('ack rejected: not the current minimum unacked outbox row', {
          consumer_id: consumerId, outbox_id: params.outboxId, min_unacked: minId
        });
      }
      const eventId = minR.rows[0].event_id;
      const receipt = await readReceiptRow(conn, consumerId, eventId);
      if (!receipt || receipt.state !== 'applied') {
        throw new StateTransitionError('ack rejected: the delivery is not yet applied (mark-applied first)', {
          consumer_id: consumerId, outbox_id: params.outboxId, event_id: eventId,
          receipt_state: receipt ? receipt.state : null
        });
      }
      await conn.query('UPDATE outbox SET acked_at = $1 WHERE outbox_id = $2', [ctx.now, params.outboxId]);
      // GREATEST keeps the cursor monotonic even under an out-of-window replay path
      // (t_cursor_never_goes_backward); in-order acking already advances it strictly.
      await conn.query(
        `INSERT INTO consumer_cursors (consumer_id, last_acked_outbox_id, last_acked_at, updated_at)
           VALUES ($1,$2,$3,$3)
           ON CONFLICT (consumer_id) DO UPDATE SET
             last_acked_outbox_id = GREATEST(consumer_cursors.last_acked_outbox_id, EXCLUDED.last_acked_outbox_id),
             last_acked_at = EXCLUDED.last_acked_at,
             updated_at = EXCLUDED.updated_at`,
        [consumerId, params.outboxId, ctx.now]
      );
      return {
        result: {
          consumer_id: consumerId, outbox_id: params.outboxId, event_id: eventId,
          acked: true, cursor: params.outboxId
        },
        committedRevision: null, domainChanged: true
      };
    }
  });
}

// recordSinkIdempotencyUnknown: the audit-only recorder the drain loop calls when a
// sink cannot confirm idempotency by event_id after an ambiguous timeout (spec section
// 8.3). It performs NO domain mutation - like S3's cleanup-mismatch, it persists the
// anomaly through the sanctioned audit path (ConflictSignal -> savepoint rollback ->
// `sink_idempotency_unknown` anomaly persisted -> +1 domain/commit) and then throws
// SinkIdempotencyUnknownError so the drain loop STOPS rather than lying about apply.
export async function recordSinkIdempotencyUnknown(store, params, { now = nowIso(), fault } = {}) {
  const consumerId = params.consumerId ?? CONSUMER_ID;
  requireConsumer('sink-idempotency-unknown', consumerId);
  const eventId = requireStr('sink-idempotency-unknown', params.eventId, 'event-id');
  const requestHash = sha256hex(canonicalJson({
    verb: 'sink-idempotency-unknown', consumer_id: consumerId, event_id: eventId
  }));
  return executeCommand(store, {
    verb: 'sink-idempotency-unknown', commandId: params.commandId, requestHash,
    taskId: params.taskId ?? null, now, fault,
    conflictErrors: S4_CONFLICT_ERRORS,
    mutate: async (conn) => {
      await applyS4Schema(conn);
      throw new ConflictSignal('sink_unknown', {
        anomalyClass: 'sink_idempotency_unknown', taskId: params.taskId ?? null,
        terminalFingerprint: `${consumerId}:${eventId}`,
        detail: {
          command_id: params.commandId, verb: 'mark-applied', reason: 'sink_ambiguous_timeout',
          consumer_id: consumerId, event_id: eventId, sink_kind: params.sinkKind ?? null
        }
      });
    }
  });
}

// readReceipt: a bare locked read used by the drain loop's recovery branching to
// decide whether a min-unacked row needs claim+sink+mark-applied or only an ack. No
// command-id, no counter bump.
export async function readReceipt(store, params) {
  const consumerId = params.consumerId ?? CONSUMER_ID;
  requireConsumer('read-receipt', consumerId);
  const eventId = requireStr('read-receipt', params.eventId, 'event-id');
  return runExclusive(store, async (conn) => {
    await ensureInitialized(conn);
    if (!(await consumerTablePresent(conn, 'consumer_receipts'))) return null;
    return readReceiptRow(conn, consumerId, eventId);
  });
}

// readCursor: a bare locked read of the contiguous cursor (tests and diagnostics).
export async function readCursor(store, params = {}) {
  const consumerId = params.consumerId ?? CONSUMER_ID;
  requireConsumer('read-cursor', consumerId);
  return runExclusive(store, async (conn) => {
    await ensureInitialized(conn);
    if (!(await consumerTablePresent(conn, 'consumer_cursors'))) {
      return { consumer_id: consumerId, last_acked_outbox_id: 0, last_acked_at: null };
    }
    const r = await conn.query(
      'SELECT last_acked_outbox_id, last_acked_at FROM consumer_cursors WHERE consumer_id = $1',
      [consumerId]
    );
    if (r.rows.length === 0) return { consumer_id: consumerId, last_acked_outbox_id: 0, last_acked_at: null };
    return {
      consumer_id: consumerId,
      last_acked_outbox_id: Number(r.rows[0].last_acked_outbox_id),
      last_acked_at: r.rows[0].last_acked_at
    };
  });
}

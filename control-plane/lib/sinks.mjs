import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { ValidationError } from './errors.mjs';
import { canonicalJson, sha256hex } from './domain-store.mjs';

// S4 sink adapters (spec section 8.3). The FirstMate consumer applies each delivered
// outbox row through exactly one of three sink methods, chosen by sink_kind:
//
//   card        -> upsertCardDisposition(event_id, payload)
//   wake        -> appendWakeIfAbsent(event_id, payload)
//   disposition -> recordFirstMateDisposition(event_id, payload)
//
// EVERY sink operation MUST be durably idempotent by event_id at the sink itself
// (spec section 8.3): it records event_id in its own durable store before or with its
// effect, and a repeat of the same event_id returns the PREVIOUS result without
// duplicating the card, wake, or disposition. That property - not token fencing - is
// what makes at-least-once delivery safe across a crash between the sink effect and
// mark-applied.
//
// The default implementation is an ISOLATED, DURABLE, event_id-keyed file ledger that
// is SEPARATE from the coordinator's PGlite store (ruling RISK#4): a per-home directory
// with one file per (sink_kind, event_id). Keeping the effect in a different store from
// the receipt is what genuinely exercises two-store crash consistency. It is NOT a real
// Bridge/wake-queue/disposition store - S4 ships no production sink paths and no
// cutover. Tests inject their own deterministic idempotent/failing/timeout doubles
// against the same SinkAdapter shape.

export const SINK_KINDS = Object.freeze(['card', 'wake', 'disposition']);

const SINK_KIND_TO_METHOD = Object.freeze({
  card: 'upsertCardDisposition',
  wake: 'appendWakeIfAbsent',
  disposition: 'recordFirstMateDisposition'
});

// Default routing of an outbox row's event_type to a sink_kind. S4 owns no production
// routing policy, so this is a defensible, overridable default (pass a resolver to the
// consumer). Terminal/disposition-bearing outcomes record a FirstMate disposition;
// cancellation surfaces as a card; the nonterminal progress family appends a wake.
const DEFAULT_SINK_KIND_BY_EVENT_TYPE = Object.freeze({
  completed: 'disposition',
  failed: 'disposition',
  cancelled: 'card',
  progress: 'wake',
  blocked: 'wake',
  unblocked: 'wake',
  waiting_firstmate: 'wake',
  needs_human: 'wake',
  rework: 'wake'
});

export function defaultResolveSinkKind(row) {
  const kind = DEFAULT_SINK_KIND_BY_EVENT_TYPE[row.event_type];
  if (!kind) {
    throw new ValidationError(
      `no default sink_kind for event_type '${row.event_type}'; supply an explicit resolver`,
      { event_type: row.event_type }
    );
  }
  return kind;
}

// Thrown by a sink method when it cannot confirm idempotency by event_id after an
// ambiguous timeout (spec section 8.3). The consumer catches it, records the
// `sink_idempotency_unknown` anomaly through the audit path, and STOPS delivery - it
// must never mark the receipt applied on an effect it cannot confirm.
export class AmbiguousSinkTimeoutError extends Error {
  constructor(message, detail) {
    super(message || 'sink could not confirm idempotency by event_id after an ambiguous timeout');
    this.name = 'AmbiguousSinkTimeoutError';
    this.detail = detail || null;
  }
}

// The isolated, durable, event_id-keyed file-ledger sink. One file per
// (sink_kind, event_id) under `dir`; the write is atomic (temp -> fsync -> rename) so a
// crash mid-write leaves either the full committed entry or nothing - never a
// half-applied effect. Re-invoking with the same event_id returns the previously
// committed result.
export class FileLedgerSink {
  constructor({ dir } = {}) {
    if (typeof dir !== 'string' || dir.length === 0) {
      throw new ValidationError('FileLedgerSink requires a { dir } path');
    }
    this.dir = dir;
  }

  _pathFor(sinkKind, eventId) {
    // event_id is a UUID (no path separators), but encode defensively so a hostile id
    // can never escape the ledger directory.
    return path.join(this.dir, sinkKind, `${encodeURIComponent(eventId)}.json`);
  }

  // Durably idempotent apply, keyed by event_id. `faultBeforeCommit`, when supplied, is
  // a TEST-ONLY hook fired AFTER the durable temp write + fsync but BEFORE the atomic
  // rename - the exact "crash during the effect" cut. It mirrors the domain layer's
  // `fault` convention and is never passed by any production caller.
  _applyIdempotent(sinkKind, eventId, payload, { faultBeforeCommit } = {}) {
    const file = this._pathFor(sinkKind, eventId);
    if (fs.existsSync(file)) {
      const stored = JSON.parse(fs.readFileSync(file, 'utf8'));
      return { result: stored.result, alreadyApplied: true };
    }
    const result = {
      sink_kind: sinkKind,
      event_id: eventId,
      disposition: `${sinkKind}:recorded`,
      payload_digest: sha256hex(canonicalJson(payload ?? {}))
    };
    const record = { event_id: eventId, sink_kind: sinkKind, payload: payload ?? {}, result };
    fs.mkdirSync(path.dirname(file), { recursive: true });
    const tmp = `${file}.tmp-${process.pid}-${crypto.randomBytes(6).toString('hex')}`;
    const fd = fs.openSync(tmp, 'w');
    try {
      fs.writeSync(fd, JSON.stringify(record));
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    if (typeof faultBeforeCommit === 'function') faultBeforeCommit();
    fs.renameSync(tmp, file);
    return { result, alreadyApplied: false };
  }

  async upsertCardDisposition(eventId, payload, opts) {
    return this._applyIdempotent('card', eventId, payload, opts);
  }

  async appendWakeIfAbsent(eventId, payload, opts) {
    return this._applyIdempotent('wake', eventId, payload, opts);
  }

  async recordFirstMateDisposition(eventId, payload, opts) {
    return this._applyIdempotent('disposition', eventId, payload, opts);
  }

  // Route to the sink method for a sink_kind. Returns { result, alreadyApplied }.
  async apply(sinkKind, eventId, payload, opts) {
    const method = SINK_KIND_TO_METHOD[sinkKind];
    if (!method) {
      throw new ValidationError(`unknown sink_kind '${sinkKind}' (expected one of ${SINK_KINDS.join(', ')})`, { sink_kind: sinkKind });
    }
    return this[method](eventId, payload, opts);
  }
}

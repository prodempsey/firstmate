import fs from 'node:fs';
import { PgliteLocalStore } from './pglite-local-store.mjs';
import { parseArgs } from './coordinator.mjs';
import { ValidationError } from './errors.mjs';
import { claimConsumer, next, claimDelivery, markApplied, ack } from './domain-store-s4.mjs';

// S4 coordinator dispatcher (spec section 6). Owns the FirstMate consumer verbs; the
// S0 coordinator delegates to it via a single registration branch, exactly as it does
// for S1/S2/S3. Runs the same storage lifecycle (flock + open + one BEGIN/COMMIT +
// close-before-unlock); the domain layer reaches the exclusive transaction only through
// the sanctioned in-package seam. The card/wake/disposition sink adapters and the drain
// loop are library modules (lib/sinks.mjs, lib/firstmate-consumer.mjs) that FirstMate
// drives directly; they are not CLI verbs.

export const S4_VERBS = new Set(['claim-consumer', 'next', 'claim-delivery', 'mark-applied', 'ack']);

export async function runS4Verb(verb, rest, { env = process.env } = {}) {
  const { flags, positionals } = parseArgs(rest);
  const store = PgliteLocalStore.create({ dataDir: flags['data-dir'], env });
  try {
    const result = await dispatch(verb, flags, positionals, store);
    return { ok: true, result };
  } finally {
    await store.close();
  }
}

// Delivery policy is store-owned; a caller may not suppress or force it (spec section
// 3.1/6.1). The consumer verbs neither produce nor deliver events, so a --deliver
// switch on any of them is doubly wrong and is rejected loudly rather than ignored
// (t_no_caller_deliver_switch_s4).
function rejectDeliverSwitch(verb, flags) {
  if ('deliver' in flags || 'no-deliver' in flags) {
    throw new ValidationError(
      `'${verb}' has no --deliver/--no-deliver switch; delivery policy is store-owned (spec section 6.1)`,
      { verb }
    );
  }
}

// No consumer verb takes a task causal token: leases/cursors/receipts are keyed by
// consumer_id/event_id/outbox_id, never by tasks.revision (ruling RISK#6;
// t_no_expected_revision_on_consumer_verbs). Accepting-and-ignoring --expected-revision
// would silently imply a CAS the consumer surface does not have.
function rejectExpectedRevision(verb, flags) {
  if ('expected-revision' in flags) {
    throw new ValidationError(
      `'${verb}' takes no --expected-revision; consumer verbs are not task-causal (spec section 8)`,
      { verb }
    );
  }
}

async function dispatch(verb, flags, positionals, store) {
  if (positionals.length > 0) {
    throw new ValidationError(`'${verb}' takes no positional arguments; use the named --flags (spec section 8)`, { verb });
  }
  rejectDeliverSwitch(verb, flags);
  rejectExpectedRevision(verb, flags);
  const consumerId = flags.consumer === undefined || flags.consumer === true ? 'firstmate' : flags.consumer;
  switch (verb) {
    case 'claim-consumer': {
      const ttlSeconds = parseOptionalIntFlag(verb, flags, 'ttl', { min: 1 });
      return claimConsumer(store, {
        consumerId,
        bootId: requireStringFlag(verb, flags, 'boot-id'),
        pid: parseIntFlag(flags, 'pid'),
        ttlMs: ttlSeconds === undefined ? undefined : ttlSeconds * 1000,
        commandId: flags['command-id']
      });
    }
    case 'next':
      // Locked read: no command-id, no revision, no bump (spec section 6/8).
      return next(store, {
        consumerId,
        ownerToken: requireStringFlag(verb, flags, 'owner-token')
      });
    case 'claim-delivery':
      return claimDelivery(store, {
        consumerId,
        outboxId: parseIntFlag(flags, 'outbox-id'),
        ownerToken: requireStringFlag(verb, flags, 'owner-token'),
        sinkKind: requireStringFlag(verb, flags, 'sink-kind'),
        commandId: flags['command-id']
      });
    case 'mark-applied':
      return markApplied(store, {
        consumerId,
        eventId: requireStringFlag(verb, flags, 'event-id'),
        ownerToken: requireStringFlag(verb, flags, 'owner-token'),
        sinkResult: readJsonFileFlag(verb, flags, 'sink-result-file', { required: true }),
        commandId: flags['command-id']
      });
    case 'ack':
      return ack(store, {
        consumerId,
        outboxId: parseIntFlag(flags, 'outbox-id'),
        ownerToken: requireStringFlag(verb, flags, 'owner-token'),
        commandId: flags['command-id']
      });
    default:
      throw new ValidationError(`unhandled S4 verb: ${verb}`);
  }
}

function parseIntFlag(flags, name) {
  const v = flags[name];
  if (v === undefined || v === true) {
    throw new ValidationError(`--${name} is required and must be an integer`);
  }
  const n = Number(v);
  if (!Number.isInteger(n)) {
    throw new ValidationError(`--${name} must be an integer`, { value: v });
  }
  return n;
}

function parseOptionalIntFlag(verb, flags, name, { min } = {}) {
  const v = flags[name];
  if (v === undefined) return undefined;
  if (v === true) throw new ValidationError(`--${name} requires an integer value`, { verb, flag: name });
  const n = Number(v);
  if (!Number.isInteger(n)) throw new ValidationError(`--${name} must be an integer`, { verb, flag: name, value: v });
  if (min !== undefined && n < min) throw new ValidationError(`--${name} must be >= ${min}`, { verb, flag: name, value: v });
  return n;
}

function requireStringFlag(verb, flags, name) {
  const v = flags[name];
  if (typeof v !== 'string' || v.length === 0) {
    throw new ValidationError(`'${verb}' requires --${name}`, { verb, flag: name });
  }
  return v;
}

// Read a JSON file named by a flag, holding a required input to the same loud standard
// S2/S3 use: a missing, unreadable, or malformed file rejects BEFORE any store work
// rather than silently dropping the sink result the receipt must carry.
function readJsonFileFlag(verb, flags, name, { required }) {
  const p = flags[name];
  if (p === undefined) {
    if (required) throw new ValidationError(`'${verb}' requires --${name}`, { verb, flag: name });
    return undefined;
  }
  if (p === true) {
    throw new ValidationError(`--${name} requires a file path`, { verb, flag: name });
  }
  let text;
  try {
    text = fs.readFileSync(p, 'utf8');
  } catch (err) {
    throw new ValidationError(`--${name} could not be read`, { verb, flag: name, path: p, cause: err.message });
  }
  try {
    return JSON.parse(text);
  } catch {
    throw new ValidationError(`--${name} is not valid JSON`, { verb, flag: name, path: p });
  }
}

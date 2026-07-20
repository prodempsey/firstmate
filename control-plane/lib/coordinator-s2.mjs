import fs from 'node:fs';
import { PgliteLocalStore } from './pglite-local-store.mjs';
import { parseArgs } from './coordinator.mjs';
import { ValidationError } from './errors.mjs';
import { completeRun, failRun, cancelTask } from './domain-store-s2.mjs';

// S2 coordinator dispatcher (spec section 6). Owns the S2 verbs; the S0 coordinator
// delegates to it via a single registration branch, exactly as it does for S1. Runs
// the same storage lifecycle (flock + open + one BEGIN/COMMIT + close-before-unlock);
// the domain layer reaches the exclusive transaction only through the sanctioned
// in-package seam.

export const S2_VERBS = new Set(['complete', 'fail', 'cancel']);

export async function runS2Verb(verb, rest, { env = process.env } = {}) {
  const { flags, positionals } = parseArgs(rest);
  const store = PgliteLocalStore.create({ dataDir: flags['data-dir'], env });
  try {
    const result = await dispatch(verb, flags, positionals, store);
    return { ok: true, result };
  } finally {
    await store.close();
  }
}

// Delivery policy is store-owned; a caller may not suppress or force it (spec
// section 3.1/6.1). Terminal and cancellation deliveries are exactly the ones an
// operator would most want to silence by hand, so the switch is rejected loudly
// rather than ignored.
function rejectDeliverSwitch(verb, flags) {
  if ('deliver' in flags || 'no-deliver' in flags) {
    throw new ValidationError(
      `'${verb}' has no --deliver/--no-deliver switch; delivery policy is store-owned (spec section 6.1)`,
      { verb }
    );
  }
}

// The terminal verbs take exactly the spec's named inputs (--evidence-file,
// --artifacts-file, --reason); a generic --payload-file is not part of their
// surface, and accepting-but-ignoring it would be the same silent-discard defect
// finding 2 repaired, so it is rejected loudly.
function rejectPayloadFile(verb, flags) {
  if ('payload-file' in flags) {
    throw new ValidationError(
      `'${verb}' has no --payload-file; its payload is built from the spec's named inputs (spec section 6)`,
      { verb }
    );
  }
}

async function dispatch(verb, flags, positionals, store) {
  rejectDeliverSwitch(verb, flags);
  rejectPayloadFile(verb, flags);
  switch (verb) {
    case 'complete':
      return completeRun(store, {
        taskId: positionals[0],
        generation: parseIntFlag(flags, 'generation'),
        expectedRevision: parseIntFlag(flags, 'expected-revision'),
        outcome: requireStringFlag(verb, flags, 'outcome'),
        producer: requireStringFlag(verb, flags, 'producer'),
        seq: parseIntFlag(flags, 'seq'),
        evidence: readJsonFileFlag(verb, flags, 'evidence-file', { required: true }),
        commandId: flags['command-id']
      });
    case 'fail':
      return failRun(store, {
        taskId: positionals[0],
        generation: parseIntFlag(flags, 'generation'),
        expectedRevision: parseIntFlag(flags, 'expected-revision'),
        outcome: typeof flags.outcome === 'string' ? flags.outcome : undefined,
        reason: requireStringFlag(verb, flags, 'reason'),
        producer: requireStringFlag(verb, flags, 'producer'),
        seq: parseIntFlag(flags, 'seq'),
        artifacts: readJsonFileFlag(verb, flags, 'artifacts-file', { required: false }),
        commandId: flags['command-id']
      });
    case 'cancel':
      return cancelTask(store, {
        taskId: positionals[0],
        expectedRevision: parseIntFlag(flags, 'expected-revision'),
        reason: requireStringFlag(verb, flags, 'reason'),
        commandId: flags['command-id']
      });
    default:
      throw new ValidationError(`unhandled S2 verb: ${verb}`);
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

function requireStringFlag(verb, flags, name) {
  const v = flags[name];
  if (typeof v !== 'string' || v.length === 0) {
    throw new ValidationError(`'${verb}' requires --${name}`, { verb, flag: name });
  }
  return v;
}

// Read a JSON file named by a flag. A REQUIRED input that is missing, unreadable
// (including a nonexistent path), or malformed rejects loudly BEFORE any store work:
// evidence and artifacts must be durably captured, never silently dropped
// (qa-s2-q54 finding 2). An optional input that was not supplied returns undefined;
// once supplied it is held to the same standard.
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

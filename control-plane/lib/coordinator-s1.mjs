import fs from 'node:fs';
import { PgliteLocalStore } from './pglite-local-store.mjs';
import { parseArgs } from './coordinator.mjs';
import { ValidationError } from './errors.mjs';
import { createTask, beginRun, appendEvent, taskHead } from './domain-store.mjs';

// S1 coordinator dispatcher (spec section 6). Owns the S1 verbs; the S0
// coordinator delegates to it via a single registration branch. Runs the same
// storage lifecycle as S0 by going through the store (flock + open + one
// BEGIN/COMMIT + close-before-unlock); the domain layer reaches the exclusive
// transaction only through the sanctioned in-package seam.

export const S1_VERBS = new Set(['create-task', 'begin-run', 'event', 'task-head']);

export async function runS1Verb(verb, rest, { env = process.env } = {}) {
  const { flags, positionals } = parseArgs(rest);
  const store = PgliteLocalStore.create({ dataDir: flags['data-dir'], env });
  try {
    const result = await dispatch(verb, flags, positionals, store);
    return { ok: true, result };
  } finally {
    await store.close();
  }
}

async function dispatch(verb, flags, positionals, store) {
  switch (verb) {
    case 'create-task':
      return createTask(store, {
        taskId: positionals[0],
        kind: flags.kind,
        title: flags.title,
        repo: flags.repo,
        origin: flags.origin,
        orderRef: flags['order-ref'],
        internalReason: flags['internal-reason'],
        commandId: flags['command-id']
      });
    case 'begin-run':
      return beginRun(store, {
        taskId: positionals[0],
        expectedRevision: parseIntFlag(flags, 'expected-revision'),
        backend: typeof flags.backend === 'string' ? flags.backend : undefined,
        launchDir: typeof flags['launch-dir'] === 'string' ? flags['launch-dir'] : undefined,
        registrationPath: typeof flags['reg-file'] === 'string' ? flags['reg-file'] : undefined,
        commandId: flags['command-id']
      });
    case 'event': {
      // Delivery policy is store-owned; a caller may not suppress or force it
      // (spec section 3.1/6.1). There is deliberately no --deliver switch.
      if ('deliver' in flags || 'no-deliver' in flags) {
        throw new ValidationError(
          "generic 'event' has no --deliver switch; delivery policy is store-owned (spec section 6.1)"
        );
      }
      return appendEvent(store, {
        taskId: positionals[0],
        generation: parseIntFlag(flags, 'generation'),
        eventType: flags.type,
        producer: flags.producer,
        seq: parseIntFlag(flags, 'seq'),
        expectedRevision: parseIntFlag(flags, 'expected-revision'),
        payload: readPayloadFlag(flags),
        commandId: flags['command-id']
      });
    }
    case 'task-head':
      return taskHead(store, { taskId: positionals[0] });
    default:
      throw new ValidationError(`unhandled S1 verb: ${verb}`);
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

function readPayloadFlag(flags) {
  const p = flags['payload-file'];
  if (!p || p === true) return {};
  let text;
  try {
    text = fs.readFileSync(p, 'utf8');
  } catch (err) {
    throw new ValidationError('--payload-file could not be read', { path: p, cause: err.message });
  }
  try {
    return JSON.parse(text);
  } catch {
    throw new ValidationError('--payload-file is not valid JSON', { path: p });
  }
}

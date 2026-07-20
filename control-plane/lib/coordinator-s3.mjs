import fs from 'node:fs';
import { PgliteLocalStore } from './pglite-local-store.mjs';
import { parseArgs } from './coordinator.mjs';
import { ValidationError } from './errors.mjs';
import {
  recordSpawn, commitRunning, verifyRunning, cleanupIntent, cleanupFinish
} from './domain-store-s3.mjs';

// S3 coordinator dispatcher (spec section 6). Owns the S3 lifecycle verbs; the S0
// coordinator delegates to it via a single registration branch, exactly as it does for
// S1 and S2. Runs the same storage lifecycle (flock + open + one BEGIN/COMMIT +
// close-before-unlock); the domain layer reaches the exclusive transaction only through
// the sanctioned in-package seam, and it uses the REAL tmux/proc probes by default -
// tests drive the domain functions directly with injected deterministic doubles.

export const S3_VERBS = new Set(['record-spawn', 'commit-running', 'verify-running', 'cleanup-intent', 'cleanup-finish']);

export async function runS3Verb(verb, rest, { env = process.env } = {}) {
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
// 3.1/6.1). Every S3 lifecycle event is audit-only, so a caller attaching a delivery
// switch to an S3 verb is doubly wrong and is rejected loudly rather than ignored.
function rejectDeliverSwitch(verb, flags) {
  if ('deliver' in flags || 'no-deliver' in flags) {
    throw new ValidationError(
      `'${verb}' has no --deliver/--no-deliver switch; delivery policy is store-owned and every S3 event is audit-only (spec section 6.1)`,
      { verb }
    );
  }
}

async function dispatch(verb, flags, positionals, store) {
  rejectDeliverSwitch(verb, flags);
  switch (verb) {
    case 'record-spawn':
      return recordSpawn(store, {
        taskId: positionals[0],
        generation: parseIntFlag(flags, 'generation'),
        expectedRevision: parseIntFlag(flags, 'expected-revision'),
        launchMarker: requireStringFlag(verb, flags, 'launch-marker'),
        endpoint: requireStringFlag(verb, flags, 'endpoint'),
        pane: requireStringFlag(verb, flags, 'pane'),
        regFile: requireStringFlag(verb, flags, 'reg-file'),
        commandId: flags['command-id']
      });
    case 'commit-running':
      return commitRunning(store, {
        taskId: positionals[0],
        generation: parseIntFlag(flags, 'generation'),
        expectedRevision: parseIntFlag(flags, 'expected-revision'),
        commandId: flags['command-id']
      });
    case 'verify-running':
      // Locked read: no command-id, no expected-revision, no bump (spec section 6).
      return verifyRunning(store, {
        taskId: positionals[0],
        generation: parseIntFlag(flags, 'generation')
      });
    case 'cleanup-intent':
      return cleanupIntent(store, {
        taskId: positionals[0],
        generation: parseIntFlag(flags, 'generation'),
        expectedRevision: parseIntFlag(flags, 'expected-revision'),
        commandId: flags['command-id']
      });
    case 'cleanup-finish':
      return cleanupFinish(store, {
        taskId: positionals[0],
        generation: parseIntFlag(flags, 'generation'),
        expectedRevision: parseIntFlag(flags, 'expected-revision'),
        effectResult: readJsonFileFlag(verb, flags, 'effect-result-file', { required: true }),
        commandId: flags['command-id']
      });
    default:
      throw new ValidationError(`unhandled S3 verb: ${verb}`);
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

// Read a JSON file named by a flag, holding a required input to the same loud standard
// S2's terminal inputs use: a missing, unreadable, or malformed file rejects BEFORE any
// store work rather than silently dropping the adapter's cleanup effect result.
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

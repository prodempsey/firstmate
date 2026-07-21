import crypto from 'node:crypto';
import { PgliteLocalStore } from './pglite-local-store.mjs';
import { parseArgs } from './coordinator.mjs';
import { ValidationError } from './errors.mjs';
import { reconcilePass } from './reconciler.mjs';
import { listAnomalies, resolveAnomaly } from './domain-store-s5.mjs';

// S5 coordinator dispatcher (spec section 6). Owns the reconciler-facing verbs; the S0
// coordinator delegates to it via a single registration branch, exactly as it does for
// S1/S2/S3. Runs the same storage lifecycle (flock + open + close-before-unlock) - a
// `reconcile` pass drives MANY small exclusive transactions rather than one, since each
// reconciled change is its own atomic envelope mutation, but every one goes through the
// same sanctioned seam. There is NO daemon and NO timer here: `cp reconcile` runs ONE
// bounded pass and returns; the production 30s cadence is FirstMate-owned wiring at
// cutover (spec 791).

export const S5_VERBS = new Set(['reconcile', 'anomalies', 'resolve-anomaly']);

export async function runS5Verb(verb, rest, { env = process.env } = {}) {
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
  rejectDeliverSwitch(verb, flags);
  switch (verb) {
    case 'reconcile': {
      // A real production pass gets a fresh random nonce as its deterministic-within-the-
      // -pass command-id root; tests call reconcilePass directly with an injected nonce.
      const taskId = typeof flags.task === 'string' ? flags.task : null;
      return reconcilePass(store, { taskId, nonce: crypto.randomUUID() });
    }
    case 'anomalies':
      // Locked read (spec 596). `--active` narrows to still-open anomalies.
      return listAnomalies(store, { activeOnly: 'active' in flags });
    case 'resolve-anomaly':
      return resolveAnomaly(store, {
        fingerprint: positionals[0],
        reason: requireStringFlag(verb, flags, 'reason'),
        resolutionKind: requireStringFlag(verb, flags, 'resolution-kind'),
        commandId: flags['command-id']
      });
    default:
      throw new ValidationError(`unhandled S5 verb: ${verb}`);
  }
}

// The reconciler authors only audit-only anomaly rows and drives terminal outcomes
// through the store-owned S2 fail path; no S5 verb has a caller delivery switch, so one
// attached is rejected loudly rather than ignored (spec section 6.1).
function rejectDeliverSwitch(verb, flags) {
  if ('deliver' in flags || 'no-deliver' in flags) {
    throw new ValidationError(
      `'${verb}' has no --deliver/--no-deliver switch; delivery policy is store-owned (spec section 6.1)`,
      { verb }
    );
  }
}

function requireStringFlag(verb, flags, name) {
  const v = flags[name];
  if (typeof v !== 'string' || v.length === 0) {
    throw new ValidationError(`'${verb}' requires --${name}`, { verb, flag: name });
  }
  return v;
}

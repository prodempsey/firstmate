import { PgliteLocalStore } from './pglite-local-store.mjs';
import { parseArgs } from './coordinator.mjs';
import { ValidationError } from './errors.mjs';
import { createSnapshot, getSnapshot, resolveOrderSourcePath } from './domain-store-s6.mjs';
import { projectBridge, projectHelm, exportSnapshot } from './projections.mjs';

// S6 coordinator dispatcher (spec section 6, verbs 593-598). Owns snapshot / project /
// export-snapshot; the S0 coordinator delegates to it via a single registration branch,
// exactly as it does for S1/S2/S3/S4/S5. Runs the same storage lifecycle (flock + open +
// close-before-unlock): `snapshot` drives ONE exclusive transaction that reads a
// consistent domain view and inserts-or-dedups the row, while `project` and
// `export-snapshot` are bare locked reads of the snapshots table (no command-id, no
// counter bump). There is NO daemon, NO 30s cadence, and NO cutover wiring here (spec
// 787/923): these are one-shot verbs that return.

export const S6_VERBS = new Set(['snapshot', 'project', 'export-snapshot']);

export async function runS6Verb(verb, rest, { env = process.env } = {}) {
  const { flags, positionals } = parseArgs(rest);
  const store = PgliteLocalStore.create({ dataDir: flags['data-dir'], env });
  try {
    const result = await dispatch(verb, flags, positionals, store, env);
    return { ok: true, result };
  } finally {
    await store.close();
  }
}

// Projections and export are pure reads and snapshot produces no deliverable events, so
// a --deliver switch on any S6 verb is meaningless and rejected loudly (spec 6.1), the
// same guard S4/S5 apply.
function rejectDeliverSwitch(verb, flags) {
  if ('deliver' in flags || 'no-deliver' in flags) {
    throw new ValidationError(
      `'${verb}' has no --deliver/--no-deliver switch; delivery policy is store-owned (spec section 6.1)`,
      { verb }
    );
  }
}

// `--revision` is optional; when present it must be a non-negative integer naming a
// projection revision. Absent -> null (the latest snapshot). A REQUESTED revision that
// does not exist becomes SnapshotNotFoundError downstream, never a silent latest (Q6).
function parseRevisionFlag(verb, flags) {
  if (!('revision' in flags)) return null;
  const v = flags.revision;
  if (v === true) throw new ValidationError(`--revision requires an integer value`, { verb });
  const n = Number(v);
  if (!Number.isInteger(n) || n < 0) {
    throw new ValidationError(`--revision must be a non-negative integer`, { verb, value: v });
  }
  return n;
}

async function dispatch(verb, flags, positionals, store, env) {
  rejectDeliverSwitch(verb, flags);
  switch (verb) {
    case 'snapshot': {
      if (positionals.length > 0) {
        throw new ValidationError(`'snapshot' takes no positional arguments`, { verb });
      }
      // Resolve the canonical order inbox WITHOUT ever guessing the real one: an explicit
      // --order-source or CP_ORDER_SOURCE_PATH, else config/orders-path, else a loud error.
      const explicit = typeof flags['order-source'] === 'string' ? flags['order-source'] : undefined;
      const orderSourcePath = resolveOrderSourcePath({ explicit, env });
      return createSnapshot(store, {
        orderSourcePath,
        commandId: typeof flags['command-id'] === 'string' ? flags['command-id'] : undefined
      });
    }
    case 'project': {
      const surface = positionals[0];
      if (surface !== 'bridge' && surface !== 'helm') {
        throw new ValidationError(`'project' requires a surface: bridge|helm`, { surface: surface ?? null });
      }
      const revision = parseRevisionFlag(verb, flags);
      const snapshot = await getSnapshot(store, { revision });
      return surface === 'bridge' ? projectBridge(snapshot) : projectHelm(snapshot);
    }
    case 'export-snapshot': {
      if (positionals.length > 0) {
        throw new ValidationError(`'export-snapshot' takes no positional arguments; use --out <path>`, { verb });
      }
      const outPath = flags.out;
      if (typeof outPath !== 'string' || outPath.length === 0) {
        throw new ValidationError(`'export-snapshot' requires --out <path>`, { verb });
      }
      const revision = parseRevisionFlag(verb, flags);
      return exportSnapshot(store, { revision, outPath });
    }
    default:
      throw new ValidationError(`unhandled S6 verb: ${verb}`);
  }
}

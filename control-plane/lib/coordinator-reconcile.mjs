import { parseArgs } from './coordinator.mjs';
import { ValidationError } from './errors.mjs';
import { runShadowReconcile } from './shadow-reconcile.mjs';

// CW2+ shadow-window RECONCILE coordinator dispatcher. Owns `shadow-reconcile`; the S0
// coordinator delegates to it via a single registration branch, exactly as it does for
// S1-S6/archive, S8, CW1, and CW2. This is a NEW slice: the landed S0-S8 + CW1 + CW2 modules
// stay byte-identical; the ONLY change to an existing module is the one sanctioned
// registration in coordinator.mjs.
//
// Like migrate-apply/migrate-backfill, `shadow-reconcile` DOES write - through the landed
// domain command envelope only - and opens the target store itself, so this dispatcher just
// validates the command surface and hands off; runShadowReconcile owns the store lifecycle,
// the captain-approval / ledger / shadow-window gates, idempotency, and the receipt file.

export const RECONCILE_VERBS = new Set(['shadow-reconcile']);

export async function runReconcileVerb(verb, rest, { env = process.env } = {}) {
  const { flags, positionals } = parseArgs(rest);
  if (verb !== 'shadow-reconcile') {
    throw new ValidationError(`unhandled reconcile verb: ${verb}`);
  }
  if (positionals.length > 0) {
    throw new ValidationError(
      `'shadow-reconcile' takes no positional arguments; use --ledger <path> --data-dir <path> --out <path> --captain-approved [--task <id>]`,
      { verb }
    );
  }
  // Delivery policy is store-owned; shadow-reconcile produces no deliverable events, so a
  // --deliver switch is meaningless and rejected loudly (same guard every write slice applies).
  if ('deliver' in flags || 'no-deliver' in flags) {
    throw new ValidationError(`'shadow-reconcile' has no --deliver/--no-deliver switch`, { verb });
  }
  const ledgerPath = typeof flags.ledger === 'string' ? flags.ledger : undefined;
  if (!ledgerPath) {
    throw new ValidationError(`'shadow-reconcile' requires --ledger <reconcile-ledger-path>`, { verb });
  }
  const dataDir = typeof flags['data-dir'] === 'string' ? flags['data-dir'] : undefined;
  if (!dataDir) {
    throw new ValidationError(`'shadow-reconcile' requires --data-dir <control-plane store path>`, { verb });
  }
  const outPath = typeof flags.out === 'string' ? flags.out : undefined;
  if (!outPath) {
    throw new ValidationError(`'shadow-reconcile' requires --out <receipt-path>`, { verb });
  }
  // The captain-approval consent is an EXPLICIT bare flag: `--captain-approved` with no value.
  // Anything else (absent, or given a value) fails closed in runShadowReconcile.
  const captainApproved = flags['captain-approved'] === true;
  const taskFilter = typeof flags.task === 'string' ? flags.task : undefined;

  const result = await runShadowReconcile({ ledgerPath, dataDir, outPath, captainApproved, taskFilter, env });
  return { ok: true, result };
}

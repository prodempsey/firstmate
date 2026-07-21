import { parseArgs } from './coordinator.mjs';
import { ValidationError } from './errors.mjs';
import { runMigrateReport } from './migrate-report.mjs';

// S8 coordinator dispatcher (spec section 12 S8 row; section 13). Owns `migrate-report`;
// the S0 coordinator delegates to it via a single registration branch, exactly as it does
// for S1-S6/archive.
//
// UNLIKE every other slice, migrate-report opens NO control-plane store: it is a strictly
// read-only shadow read of the LEGACY stores that emits a proposal and applies nothing
// (spec section 13). So there is no flock, no PGlite open, no transaction here - the verb
// touches the control plane not at all, and the legacy stores read-only only.

export const S8_VERBS = new Set(['migrate-report']);

export async function runS8Verb(verb, rest, { env = process.env } = {}) {
  const { flags, positionals } = parseArgs(rest);
  if (verb !== 'migrate-report') {
    throw new ValidationError(`unhandled S8 verb: ${verb}`);
  }
  if (positionals.length > 0) {
    throw new ValidationError(`'migrate-report' takes no positional arguments; use --out <path> [--home <path>]`, { verb });
  }
  // Delivery policy is store-owned; migrate-report produces no deliverable events, so a
  // --deliver switch is meaningless and rejected loudly (same guard S4/S5/S6 apply).
  if ('deliver' in flags || 'no-deliver' in flags) {
    throw new ValidationError(`'migrate-report' has no --deliver/--no-deliver switch`, { verb });
  }
  const outPath = flags.out;
  if (typeof outPath !== 'string' || outPath.length === 0) {
    throw new ValidationError(`'migrate-report' requires --out <path>`, { verb });
  }
  const home = typeof flags.home === 'string' ? flags.home : undefined;
  const { receipt } = runMigrateReport({ home, outPath, env });
  return { ok: true, result: receipt };
}

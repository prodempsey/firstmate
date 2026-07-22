import { parseArgs } from './coordinator.mjs';
import { ValidationError } from './errors.mjs';
import { runMigrateApply } from './migrate-apply.mjs';

// CW1 (cutover stage 1) coordinator dispatcher. Owns `migrate-apply`; the S0 coordinator
// delegates to it via a single registration branch, exactly as it does for S1-S6/archive
// and S8. This is a NEW slice, not an edit of S8 - the landed S0-S8 modules stay
// byte-identical; the only change to an existing module is the one sanctioned
// registration in coordinator.mjs.
//
// Unlike migrate-report (which opened NO store), migrate-apply DOES write - through the
// landed domain command envelope only. It opens the target store itself (many create-task
// calls plus a verification snapshot), so this dispatcher just validates the surface and
// hands off; runMigrateApply owns the store lifecycle.

export const CW1_VERBS = new Set(['migrate-apply']);

export async function runCw1Verb(verb, rest, { env = process.env } = {}) {
  const { flags, positionals } = parseArgs(rest);
  if (verb !== 'migrate-apply') {
    throw new ValidationError(`unhandled CW1 verb: ${verb}`);
  }
  if (positionals.length > 0) {
    throw new ValidationError(
      `'migrate-apply' takes no positional arguments; use --report <path> --data-dir <path> --out <path> [--resume] [--order-source <path>]`,
      { verb }
    );
  }
  // Delivery policy is store-owned; migrate-apply produces no deliverable events, so a
  // --deliver switch is meaningless and rejected loudly (same guard every write slice
  // applies).
  if ('deliver' in flags || 'no-deliver' in flags) {
    throw new ValidationError(`'migrate-apply' has no --deliver/--no-deliver switch`, { verb });
  }
  const reportPath = typeof flags.report === 'string' ? flags.report : undefined;
  if (!reportPath) {
    throw new ValidationError(`'migrate-apply' requires --report <s8-report-path>`, { verb });
  }
  const dataDir = typeof flags['data-dir'] === 'string' ? flags['data-dir'] : undefined;
  if (!dataDir) {
    throw new ValidationError(`'migrate-apply' requires --data-dir <control-plane store path>`, { verb });
  }
  const outPath = typeof flags.out === 'string' ? flags.out : undefined;
  if (!outPath) {
    throw new ValidationError(`'migrate-apply' requires --out <residual-report-path>`, { verb });
  }
  const resume = flags.resume === true;
  const orderSourcePath = typeof flags['order-source'] === 'string' ? flags['order-source'] : undefined;

  const result = await runMigrateApply({ reportPath, dataDir, outPath, resume, orderSourcePath, env });
  return { ok: true, result };
}

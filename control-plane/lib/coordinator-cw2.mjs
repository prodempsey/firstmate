import { parseArgs } from './coordinator.mjs';
import { ValidationError } from './errors.mjs';
import { runShadowDiff } from './shadow-diff.mjs';
import { runMigrateBackfill } from './migrate-backfill.mjs';

// CW2 (cutover stage 2) coordinator dispatcher. Owns the two READ-model/back-fill verbs of
// the shadow-run stage: `shadow-diff` (read-only divergence monitor) and `migrate-backfill`
// (archived-history audit import). The S0 coordinator delegates here via a single
// registration branch, exactly as it does for S1-S6/archive, S8, and CW1. This is a NEW
// slice: the landed S0-S8 + CW1 modules stay byte-identical; the only change to an existing
// module is the one sanctioned registration in coordinator.mjs.
//
// The Part A SHADOW WRITER is intentionally NOT a `cp` verb: it is a fire-and-forget mirror
// a lifecycle chokepoint invokes out-of-band via bin/cp-shadow.mjs (and bin/fm-cp-shadow.sh),
// so it never rides the same synchronous `cp <verb>` surface a legacy op would block on.

export const CW2_VERBS = new Set(['shadow-diff', 'migrate-backfill']);

export async function runCw2Verb(verb, rest, { env = process.env } = {}) {
  const { flags, positionals } = parseArgs(rest);

  if (verb === 'shadow-diff') {
    if (positionals.length > 0) {
      throw new ValidationError(
        `'shadow-diff' takes no positional arguments; use --out <path> --data-dir <path> [--home <legacy>]`,
        { verb }
      );
    }
    if ('deliver' in flags || 'no-deliver' in flags) {
      throw new ValidationError(`'shadow-diff' has no --deliver/--no-deliver switch`, { verb });
    }
    const dataDir = typeof flags['data-dir'] === 'string' ? flags['data-dir'] : undefined;
    if (!dataDir) throw new ValidationError(`'shadow-diff' requires --data-dir <control-plane store path>`, { verb });
    const outPath = typeof flags.out === 'string' ? flags.out : undefined;
    if (!outPath) throw new ValidationError(`'shadow-diff' requires --out <divergence-report-path>`, { verb });
    const home = typeof flags.home === 'string' ? flags.home : undefined;
    const ordersPath = typeof flags['orders-path'] === 'string' ? flags['orders-path'] : undefined;
    const bridgeHistoryPath = typeof flags['bridge-history'] === 'string' ? flags['bridge-history'] : undefined;
    const result = await runShadowDiff({ home, dataDir, outPath, ordersPath, bridgeHistoryPath, env });
    return { ok: true, result };
  }

  if (verb === 'migrate-backfill') {
    if (positionals.length > 0) {
      throw new ValidationError(
        `'migrate-backfill' takes no positional arguments; use --residual <path> --data-dir <path> --out <path> [--resume]`,
        { verb }
      );
    }
    if ('deliver' in flags || 'no-deliver' in flags) {
      throw new ValidationError(`'migrate-backfill' has no --deliver/--no-deliver switch`, { verb });
    }
    const residualPath = typeof flags.residual === 'string' ? flags.residual : undefined;
    if (!residualPath) throw new ValidationError(`'migrate-backfill' requires --residual <cw1-residual-path>`, { verb });
    const dataDir = typeof flags['data-dir'] === 'string' ? flags['data-dir'] : undefined;
    if (!dataDir) throw new ValidationError(`'migrate-backfill' requires --data-dir <control-plane store path>`, { verb });
    const outPath = typeof flags.out === 'string' ? flags.out : undefined;
    if (!outPath) throw new ValidationError(`'migrate-backfill' requires --out <backfill-residual-path>`, { verb });
    const resume = flags.resume === true;
    const result = await runMigrateBackfill({ residualPath, dataDir, outPath, resume, env });
    return { ok: true, result };
  }

  throw new ValidationError(`unhandled CW2 verb: ${verb}`);
}

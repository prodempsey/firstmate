// Crash/concurrency-probe worker for the S6 snapshot adversarial tests.
//
// Two roles, selected by CP_MODE:
//   * 'plain' (default) - run ONE `cp snapshot` against the isolated fixture inbox and
//     print the result JSON. Two of these launched concurrently are the racers in
//     t_concurrent_snapshot_single_increment: the whole-transaction flock serializes
//     them, so exactly one inserts a new row and the other dedups to it - one increment,
//     one new snapshot, both reporting the SAME projection_revision.
//   * 'crash-after-commit' - run ONE snapshot but HARD-EXIT via faultAfterCommit AFTER
//     the transaction has durably committed and BEFORE the result is reported, modelling
//     a crash "between insert and return" (t_snapshot_crash_between_insert_and_return_
//     recovers_idempotently). The parent then reruns snapshot and must observe the SAME
//     single row (idempotent recovery), never a second increment.
//
// Uses ONLY the isolated fixture inbox at CP_ORDER_SOURCE; it never reads the real inbox.
import { PgliteLocalStore } from '../../lib/pglite-local-store.mjs';
import { createSnapshot } from '../../lib/domain-store-s6.mjs';

const store = new PgliteLocalStore({ fmHome: process.env.CP_FM_HOME });
const orderSourcePath = process.env.CP_ORDER_SOURCE;
const mode = process.env.CP_MODE || 'plain';

const opts = { orderSourcePath };
if (mode === 'crash-after-commit') {
  // The row is already durably committed (close-before-unlock ran inside the seam); die
  // before we can report it, so recovery is a plain rerun that must dedup, not re-insert.
  opts.faultAfterCommit = () => process.exit(47);
}

const res = await createSnapshot(store, opts);
await store.close();
process.stdout.write(JSON.stringify(res));
process.exit(0);

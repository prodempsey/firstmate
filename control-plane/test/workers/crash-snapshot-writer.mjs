// Crash / concurrency / ordering probe worker for the S6 snapshot adversarial tests.
//
// Roles selected by CP_MODE:
//   * 'plain' (default) - run ONE `cp snapshot` against the isolated fixture inbox and
//     print the result JSON. Two of these launched concurrently are the racers in
//     t_concurrent_snapshot_single_increment: the whole-transaction flock serializes them,
//     so exactly one inserts a new row and the other dedups to it. If CP_DONE_FILE is set,
//     touch it AFTER the snapshot commits and before printing (a commit signal a parent can
//     poll without blocking on the child's exit).
//   * 'crash-after-commit' - run ONE snapshot but HARD-EXIT via faultAfterCommit AFTER the
//     transaction durably commits and BEFORE the result is reported (a crash "between
//     insert and return"; t_snapshot_crash_between_insert_and_return_recovers_idempotently).
//   * 'pause-after-read' - run ONE snapshot but PAUSE inside the order-prefix afterReadHook
//     on its first firing: touch CP_PAUSE_FILE (signalling "I have read my prefix"), then
//     block (bounded) until the parent creates CP_RELEASE_FILE, then proceed to commit.
//     This is caller A in t_snapshot_prefix_capture_serialized_no_revision_regression: with
//     the finding-1 fix the read happens INSIDE the exclusive transaction, so A holds the
//     per-home flock across this pause and a concurrent caller B cannot commit ahead of it.
//
// Uses ONLY the isolated fixture inbox at CP_ORDER_SOURCE; it never reads the real inbox.
import fs from 'node:fs';
import { PgliteLocalStore } from '../../lib/pglite-local-store.mjs';
import { createSnapshot } from '../../lib/domain-store-s6.mjs';

// Synchronous sleep so a pause can block inside the (synchronous) afterReadHook.
function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

const store = new PgliteLocalStore({ fmHome: process.env.CP_FM_HOME });
const orderSourcePath = process.env.CP_ORDER_SOURCE;
const mode = process.env.CP_MODE || 'plain';

const opts = { orderSourcePath };

if (mode === 'crash-after-commit') {
  // The row is already durably committed (close-before-unlock ran inside the seam); die
  // before we can report it, so recovery is a plain rerun that must dedup, not re-insert.
  opts.faultAfterCommit = () => process.exit(47);
} else if (mode === 'pause-after-read') {
  let paused = false;
  opts.orderPrefixOptions = {
    afterReadHook: () => {
      if (paused) return;
      paused = true;
      fs.writeFileSync(process.env.CP_PAUSE_FILE, 'read');
      // Bounded wait for release so a stuck test still exits.
      for (let i = 0; i < 800 && !fs.existsSync(process.env.CP_RELEASE_FILE); i += 1) sleepSync(25);
    }
  };
}

const res = await createSnapshot(store, opts);
await store.close();
if (process.env.CP_DONE_FILE) fs.writeFileSync(process.env.CP_DONE_FILE, 'committed');
process.stdout.write(JSON.stringify(res));
process.exit(0);

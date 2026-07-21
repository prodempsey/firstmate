// Crash-probe worker for t_reconcile_crash_mid_pass_recovers.
//
// The parent has set up TWO verifiable spawning generations (t1, t2), both promotable.
// This worker runs ONE reconcile pass whose test-only faultAfterCommit hook performs a
// HARD process exit right AFTER the FIRST per-item commit lands (index 0) and BEFORE the
// second. Each reconciled change is its own atomic envelope transaction, so the first
// promotion is already durably committed when the process dies; the OS releases the
// flock. The parent must then observe t1 promoted and t2 still spawning, and a rerun with
// the SAME nonce must finish t2 without re-promoting or duplicating t1 - the pass is
// resumable, never a half-applied sweep.
import { PgliteLocalStore } from '../../lib/pglite-local-store.mjs';
import { reconcilePass } from '../../lib/reconciler.mjs';

const store = new PgliteLocalStore({ fmHome: process.env.CP_FM_HOME });
await reconcilePass(store, {
  nonce: process.env.CP_NONCE,
  probeIdentity: () => ({ matches: true, failingClause: null, anomalyClass: null }),
  faultAfterCommit: (i) => { if (i === 0) process.exit(46); }
});

// Unreachable: the fault must exit the process after the first commit.
process.exit(0);

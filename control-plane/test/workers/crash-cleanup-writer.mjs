// Crash-probe worker for t_cleanup_crash_cuts_recover.
//
// The parent has driven a generation to terminal (binding cleanup_pending) and
// committed the cleanup intent (cleanup_state intent_committed). This worker opens the
// same store and issues ONE cleanup-finish whose test-only fault hook performs a HARD
// process exit AFTER the domain writes (run -> cleaned/closed, cleaned event) but BEFORE
// the counter bump and command_results insert - i.e. mid-transaction, before COMMIT.
//
// This is a real writer-exit, not a caught in-process throw: the process is gone, the
// flock is released by the OS, and the parent must observe that PGlite crash recovery
// left the cleanup STILL intent_committed. A retry with the SAME command-id then commits
// cleaned exactly once (the cleanup saga's crash-cut recovery, spec section 7).
import { PgliteLocalStore } from '../../lib/pglite-local-store.mjs';
import { cleanupFinish } from '../../lib/domain-store-s3.mjs';

const store = new PgliteLocalStore({ fmHome: process.env.CP_FM_HOME });
await cleanupFinish(
  store,
  {
    taskId: process.env.CP_TASK_ID,
    generation: Number(process.env.CP_GENERATION),
    expectedRevision: Number(process.env.CP_EXPECTED_REVISION),
    effectResult: { killed: true, confirmed_absent: true },
    commandId: process.env.CP_COMMAND_ID
  },
  { fault: () => process.exit(47) }
);

// Unreachable: the fault must exit the process before this line.
process.exit(0);

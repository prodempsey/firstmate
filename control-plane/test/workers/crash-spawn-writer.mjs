// Crash-probe worker for t_crash_between_record_spawn_and_commit_running.
//
// The parent has created the task, begun generation 1, and recorded the spawn (so the
// endpoint is stored and the run is spawning). This worker opens the same store and
// issues ONE commit-running whose test-only fault hook performs a HARD process exit
// AFTER the domain promotion writes (run -> open/bound_verified, running_verified event)
// but BEFORE the counter bump and command_results insert - i.e. mid-transaction, before
// COMMIT. It injects a PASSING identity probe so the crash cut is reached.
//
// This is a real writer-exit at that cut, not a caught in-process throw: the process is
// gone, the flock is released by the OS, and the parent must observe that PGlite crash
// recovery left the run STILL spawning - never a half-promoted ghost running card. The
// anti-ghost guarantee holds across a crash: no run is promoted unless the whole
// commit-running transaction commits.
import { PgliteLocalStore } from '../../lib/pglite-local-store.mjs';
import { commitRunning } from '../../lib/domain-store-s3.mjs';

const store = new PgliteLocalStore({ fmHome: process.env.CP_FM_HOME });
await commitRunning(
  store,
  {
    taskId: process.env.CP_TASK_ID,
    generation: Number(process.env.CP_GENERATION),
    expectedRevision: Number(process.env.CP_EXPECTED_REVISION),
    commandId: process.env.CP_COMMAND_ID
  },
  {
    probeIdentity: () => ({ matches: true, failingClause: null, anomalyClass: null }),
    fault: () => process.exit(43)
  }
);

// Unreachable: the fault must exit the process before this line.
process.exit(0);

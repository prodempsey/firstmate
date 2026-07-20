// Crash-probe worker for t_recovers_when_terminal_writer_exits_before_outbox.
//
// The parent has already created the task, begun generation 1, and promoted it to
// running. This worker opens the same store and issues ONE `complete` whose test-only
// crash hook performs a HARD process exit at the sharpest cut in S2: AFTER the
// terminal task_events row is written and the run is closed, but BEFORE the outbox
// row is inserted - i.e. mid-transaction, before COMMIT.
//
// This is a real writer-exit at that cut, not a caught in-process throw: the process
// is gone, the flock is released by the OS, and the parent must observe that PGlite
// crash recovery left NO part of the terminal bundle behind. If run closure could
// survive a missing delivery, a completed run would never reach FirstMate.
import { PgliteLocalStore } from '../../lib/pglite-local-store.mjs';
import { completeRun } from '../../lib/domain-store-s2.mjs';

const store = new PgliteLocalStore({ fmHome: process.env.CP_FM_HOME });
await completeRun(
  store,
  {
    taskId: process.env.CP_TASK_ID,
    generation: Number(process.env.CP_GENERATION),
    expectedRevision: Number(process.env.CP_EXPECTED_REVISION),
    outcome: 'success', producer: 'crewmate', seq: 1, evidence: {},
    commandId: process.env.CP_COMMAND_ID
  },
  { faultBeforeDelivery: () => process.exit(41) }
);

// Unreachable: the fault must exit the process before this line.
process.exit(0);

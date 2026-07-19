// Crash-probe worker for t_recovers_when_writer_exits_before_revision_bump.
//
// Opens the (already-initialized) store named by CP_FM_HOME and issues one
// create-task whose test-only fault hook performs a HARD process exit AFTER the
// domain write but BEFORE the commit bookkeeping - i.e. mid-transaction, before
// COMMIT. This is a real writer-exit at the named crash cut, not a caught
// in-process throw: the process is gone, the flock is released by the OS, and the
// parent must observe that PGlite crash recovery left no partial commit on reopen.
import { PgliteLocalStore } from '../../lib/pglite-local-store.mjs';
import { createTask } from '../../lib/domain-store.mjs';

const store = new PgliteLocalStore({ fmHome: process.env.CP_FM_HOME });
await createTask(
  store,
  {
    taskId: process.env.CP_TASK_ID,
    kind: 'ship',
    title: 'crash',
    origin: 'internal',
    internalReason: 'r',
    commandId: process.env.CP_COMMAND_ID
  },
  { fault: () => process.exit(37) }
);

// Unreachable: the fault must exit the process before this line.
process.exit(0);

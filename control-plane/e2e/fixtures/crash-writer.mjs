import { PgliteLocalStore } from '../../lib/pglite-local-store.mjs';
import { createTask } from '../../lib/domain-store.mjs';

// Child-process crash worker for wf9 durability (spec matrix row 868: "kill mid-transaction
// and reopen; no partial commit"). It opens the real store and begins a createTask
// transaction, then HARD-exits at the domain layer's `fault` seam - after the domain write
// inside the BEGIN, but BEFORE the transaction commits. The parent then reopens the store on
// the same dataDir and proves PGlite recovery left NO partial commit: the task does not
// exist and no counter moved. Mirrors the landed test/workers/crash-writer.mjs pattern.
//
// env: CP_FM_HOME, CP_TASK_ID, CP_COMMAND_ID. Exits 37 at the cutpoint.

const store = new PgliteLocalStore({ fmHome: process.env.CP_FM_HOME });
await createTask(store, {
  taskId: process.env.CP_TASK_ID, kind: 'ship', title: 'crash', origin: 'internal', internalReason: 'r',
  commandId: process.env.CP_COMMAND_ID
}, { fault: () => process.exit(37) });

// Unreachable: the fault seam exits the process before the transaction commits.
process.exit(0);

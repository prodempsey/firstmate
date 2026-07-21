import fs from 'node:fs';
import { PgliteLocalStore } from '../../lib/pglite-local-store.mjs';
import { createTask, beginRun } from '../../lib/domain-store.mjs';
import { recordSpawn, cleanupIntent } from '../../lib/domain-store-s3.mjs';
import { completeRun } from '../../lib/domain-store-s2.mjs';
import { launchAgentPane } from './agent.mjs';
import { doubleRunning } from './lifecycle.mjs';

// The real coordinator/adapter driver for wf7's spawn-saga crash cutpoints. It runs the saga
// up to the requested cutpoint against the real store (and, for B/C, launches a real
// marker-bearing pane on the dedicated socket), writes a readiness record, and then HANGS -
// so the parent can SIGKILL this exact process AT the cutpoint. That is a genuine
// coordinator/adapter crash mid-saga, not an in-process omission of the next call. The pane
// (a separate tmux process) survives this child's death exactly as a real orphaned/adopted
// endpoint would.
//
// env: CP_FM_HOME, CP_TMUX_SOCKET, CP_TASK_ID, CP_CUTPOINT (A|B|C|D|E), CP_READY_FILE, CP_SEED.
// The readiness record is JSON: { pid, pane: null | { endpointId, paneId, agentPid, launchMarker } }.

const store = new PgliteLocalStore({ fmHome: process.env.CP_FM_HOME });
const taskId = process.env.CP_TASK_ID;
const cut = process.env.CP_CUTPOINT;
const socket = process.env.CP_TMUX_SOCKET;
const seed = Number(process.env.CP_SEED || '0');
let pane = null;

if (cut === 'A') {
  const created = await createTask(store, { taskId, kind: 'ship', title: 'saga A', origin: 'internal', internalReason: 'r', commandId: `c-create-${taskId}` });
  await beginRun(store, { taskId, expectedRevision: created.revision, commandId: `c-begin-${taskId}` });
} else if (cut === 'B' || cut === 'C') {
  const created = await createTask(store, { taskId, kind: 'ship', title: `saga ${cut}`, origin: 'internal', internalReason: 'r', commandId: `c-create-${taskId}` });
  const beg = await beginRun(store, { taskId, expectedRevision: created.revision, commandId: `c-begin-${taskId}` });
  const p = launchAgentPane({ socket, fmHome: process.env.CP_FM_HOME, taskId, launchMarker: beg.launch_marker, bindNonce: beg.bind_nonce });
  pane = { endpointId: p.endpointId, paneId: p.paneId, agentPid: p.agentPid, launchMarker: beg.launch_marker };
  if (cut === 'C') {
    // record-spawn commits the endpoint (real /proc capture); commit-running never runs.
    await recordSpawn(store, { taskId, generation: 1, expectedRevision: beg.revision, launchMarker: beg.launch_marker, endpoint: p.endpointId, pane: p.paneId, regFile: p.regFile, commandId: `c-spawn-${taskId}` });
  }
} else if (cut === 'D') {
  const started = await doubleRunning(store, taskId, { seed });
  await completeRun(store, { taskId, generation: 1, expectedRevision: started.revision, outcome: 'success', producer: 'crewmate', seq: 1, evidence: {}, commandId: `c-done-${taskId}` });
} else if (cut === 'E') {
  const started = await doubleRunning(store, taskId, { seed });
  const done = await completeRun(store, { taskId, generation: 1, expectedRevision: started.revision, outcome: 'success', producer: 'crewmate', seq: 1, evidence: {}, commandId: `c-done-${taskId}` });
  await cleanupIntent(store, { taskId, generation: 1, expectedRevision: done.revision, commandId: `c-intent-${taskId}` });
} else {
  process.stderr.write(`crash-saga: unknown cutpoint ${cut}\n`);
  process.exit(2);
}

fs.writeFileSync(process.env.CP_READY_FILE, JSON.stringify({ pid: process.pid, pane }));
await new Promise(() => {}); // hang at the cutpoint until the parent SIGKILLs this process

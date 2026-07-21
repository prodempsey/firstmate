import fs from 'node:fs';
import readline from 'node:readline';
import { PgliteLocalStore } from '../../lib/pglite-local-store.mjs';
import { runExclusive } from '../../lib/internal-runtime.mjs';
import { createTask, beginRun, appendEvent } from '../../lib/domain-store.mjs';
import { completeRun } from '../../lib/domain-store-s2.mjs';
import { recordSpawn, commitRunning, cleanupIntent, cleanupFinish } from '../../lib/domain-store-s3.mjs';
import { archiveTask } from '../../lib/domain-store-archive.mjs';
import { FirstMateConsumer } from '../../lib/firstmate-consumer.mjs';
import { FileLedgerSink } from '../../lib/sinks.mjs';
import { launchAgentPane, killAgentExactPane } from './agent.mjs';

// The wf1 LIFECYCLE + STORE/CONSUMER OWNER, run as a real child process (spec matrix row
// 860; qa-s7r2-q76). This process owns the task lifecycle mutations AND the FirstMate
// consumer lease; the parent drives it over a line protocol (one command per stdin line, one
// JSON result per stdout line) and RESTARTS it by SIGKILLing this process and launching a
// fresh one against the same durable fixture data/sink. Because the killed process owns the
// consumer lease and the lifecycle, a genuine store+consumer reopen is forced: the fresh
// process must RE-CLAIM the lease (a strictly higher owner_epoch, reported at startup) and
// perform the remaining lifecycle steps. There is no in-parent shortcut - if the parent
// stopped relaunching, the remaining steps would simply never run.
//
// env: CP_FM_HOME, CP_SINK_DIR, CP_TMUX_SOCKET, CP_TASK_ID, CP_OWNER_BOOT, CP_OWNER_PID,
//      CP_INSTANCE (distinct per relaunch, so each lease re-claim is a real renew).
// startup line: { ready:true, epoch:<owner_epoch>, pid:<process.pid> }
// per-command line: { ok:true, step, ... } or { ok:false, step, error }

const store = new PgliteLocalStore({ fmHome: process.env.CP_FM_HOME });
const taskId = process.env.CP_TASK_ID;
const socket = process.env.CP_TMUX_SOCKET;
const instance = process.env.CP_INSTANCE || '0';

// Own the consumer: a fixed logical owner identity across restarts, so a fresh process's
// claim is a RENEW that rotates the epoch (the observable proof a distinct process took over).
const sink = new FileLedgerSink({ dir: process.env.CP_SINK_DIR });
const consumer = new FirstMateConsumer(store, {
  sink, bootId: process.env.CP_OWNER_BOOT, pid: Number(process.env.CP_OWNER_PID)
});
const lease = await consumer.claim({});

async function readRevision() {
  const rows = await runExclusive(store, async (conn) => (await conn.query('SELECT revision FROM tasks WHERE task_id = $1', [taskId])).rows);
  return Number(rows[0].revision);
}

async function step(cmd) {
  switch (cmd) {
    case 'spawn': {
      const created = await createTask(store, { taskId, kind: 'ship', title: 'e2e success', origin: 'captain_order', orderRef: 'ORD-1', commandId: 'c-create' });
      const beg = await beginRun(store, { taskId, expectedRevision: created.revision, commandId: 'c-begin' });
      const pane = launchAgentPane({ socket, fmHome: process.env.CP_FM_HOME, taskId, launchMarker: beg.launch_marker, bindNonce: beg.bind_nonce });
      const rs = await recordSpawn(store, { taskId, generation: 1, expectedRevision: beg.revision, launchMarker: beg.launch_marker, endpoint: pane.endpointId, pane: pane.paneId, regFile: pane.regFile, commandId: 'c-spawn' });
      const cr = await commitRunning(store, { taskId, generation: 1, expectedRevision: rs.revision, commandId: 'c-run' });
      return { step: 'spawn', binding_state: cr.binding_state, pane: { endpointId: pane.endpointId, paneId: pane.paneId, agentPid: pane.agentPid, launchMarker: beg.launch_marker } };
    }
    case 'progress': {
      const rev = await readRevision();
      await appendEvent(store, { taskId, generation: 1, eventType: 'progress', producer: 'crewmate', seq: 1, expectedRevision: rev, commandId: 'c-prog' });
      return { step: 'progress' };
    }
    case 'complete': {
      const rev = await readRevision();
      const done = await completeRun(store, { taskId, generation: 1, expectedRevision: rev, outcome: 'success', producer: 'crewmate', seq: 2, evidence: { ok: true }, commandId: 'c-done' });
      return { step: 'complete', status: done.status, delivered: done.delivered };
    }
    case 'drain': {
      const result = await consumer.drainUntilIdle({});
      return { step: 'drain', idle: result.idle === true, epoch: consumer.ownerEpoch };
    }
    case 'cleanup': {
      const rev = await readRevision();
      const intent = await cleanupIntent(store, { taskId, generation: 1, expectedRevision: rev, commandId: 'c-intent' });
      const effect = killAgentExactPane({ socket, endpointId: intent.target.endpoint_id, paneId: intent.target.pane_id, run: intent.target });
      const fin = await cleanupFinish(store, { taskId, generation: 1, expectedRevision: intent.revision, effectResult: effect, commandId: 'c-finish' });
      return { step: 'cleanup', binding_state: fin.binding_state, killed: effect.killed };
    }
    case 'archive': {
      const rev = await readRevision();
      const arch = await archiveTask(store, { taskId, expectedRevision: rev, commandId: 'c-arch' });
      return { step: 'archive', status: arch.status };
    }
    default:
      throw new Error(`unknown driver command: ${cmd}`);
  }
}

process.stdout.write(JSON.stringify({ ready: true, epoch: Number(lease.owner_epoch), pid: process.pid, instance }) + '\n');

const rl = readline.createInterface({ input: process.stdin });
for await (const line of rl) {
  const cmd = line.trim();
  if (!cmd) continue;
  try {
    const result = await step(cmd);
    process.stdout.write(JSON.stringify({ ok: true, ...result }) + '\n');
  } catch (err) {
    process.stdout.write(JSON.stringify({ ok: false, step: cmd, error: err?.message || String(err) }) + '\n');
  }
}

import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createTask, beginRun, appendEvent, taskHead } from '../../lib/domain-store.mjs';
import { completeRun } from '../../lib/domain-store-s2.mjs';
import {
  recordSpawn, commitRunning, cleanupIntent, cleanupFinish
} from '../../lib/domain-store-s3.mjs';
import { archiveTask } from '../../lib/domain-store-archive.mjs';
import { readCursor } from '../../lib/domain-store-s4.mjs';
import { projectBridge, projectHelm } from '../../lib/projections.mjs';
import { launchAgentPane, killAgentExactPane } from '../fixtures/agent.mjs';
import { makeSink, drainToIdle, sinkEffectCount } from '../fixtures/consumer.mjs';
import { waitFor, waitForFile } from '../fixtures/proc.mjs';
import { tmuxListPane } from '../../lib/tmux-adapter.mjs';

// Workflow 1 - Success (spec matrix row 860): the full happy path against a REAL
// marker-bearing pane on the dedicated socket, with TWO REAL PROCESS restarts MID-lifecycle.
// Each restart spawns a driver child that opens the store and hangs INSIDE the exclusive
// section holding the flock with an uncommitted sentinel write, then SIGKILLs that exact
// process; the parent reopens from the durable dataDir and proves no resurrection - the
// uncommitted write rolled back, task/run state is byte-identical, and there are no duplicate
// cards or sink effects. This is an abrupt process death mid-lifecycle, not an in-process
// close after the work is already done.
export const meta = { tmuxRequired: true };

const FLOCK_HOLDER = fileURLToPath(new URL('../fixtures/flock-holder.mjs', import.meta.url));

// A real store-driver process restart at the current lifecycle point: it holds the store
// flock mid-transaction (uncommitted sentinel), is SIGKILLed abruptly, and the parent reopens
// from durable storage. Asserts the uncommitted write left no ghost.
async function realRestart(h, label) {
  const readyFile = path.join(h.fmHome, `restart-ready-${label}`);
  const sentinel = `e2e-sentinel-${label}`;
  const child = h.spawnDriver(FLOCK_HOLDER, { CP_MODE: 'kill', CP_READY_FILE: readyFile, CP_SENTINEL: sentinel });
  h.recordChild(child.pid, `restart-${label}`);
  assert.equal(waitForFile(readyFile), true, `${label}: the store driver reached its mid-transaction hold`);
  const dead = await h.crashRecordedChild(child.pid, child);
  assert.equal(dead.signalCode, 'SIGKILL', `${label}: the store driver was SIGKILLed mid-transaction`);
  await h.reopenStore();
  const ghost = await h.read('SELECT count(*)::int AS n FROM command_results WHERE command_id = $1', [sentinel]);
  assert.equal(Number(ghost[0].n), 0, `${label}: the mid-transaction write rolled back after the abrupt death (no resurrection)`);
}

async function runState(h, taskId) {
  const t = (await h.read('SELECT status, revision, current_generation FROM tasks WHERE task_id = $1', [taskId]))[0];
  const r = (await h.read('SELECT run_generation, status, binding_state, cleanup_state, closed_at FROM runs WHERE task_id = $1', [taskId]))[0];
  return { t, r };
}

export async function run(h) {
  const store = h.store;
  const taskId = 't-success';

  // create + read
  const created = await createTask(store, {
    taskId, kind: 'ship', title: 'e2e success', origin: 'captain_order', orderRef: 'ORD-1', commandId: 'c-create'
  });
  assert.equal(created.status, 'queued');
  const head = await taskHead(store, { taskId });
  assert.equal(head.status, 'queued');
  assert.equal(head.revision, created.revision);

  // begin run + real marker-bound spawn
  const beg = await beginRun(store, { taskId, expectedRevision: created.revision, commandId: 'c-begin' });
  const pane = launchAgentPane({ socket: h.socket, fmHome: h.fmHome, taskId, launchMarker: beg.launch_marker, bindNonce: beg.bind_nonce });
  h.recordAgent({ pid: pane.agentPid, marker: beg.launch_marker, endpointId: pane.endpointId, paneId: pane.paneId });

  // record-spawn (real /proc+tmux capture) then commit-running (real anti-ghost probe)
  const rs = await recordSpawn(store, {
    taskId, generation: 1, expectedRevision: beg.revision, launchMarker: beg.launch_marker,
    endpoint: pane.endpointId, pane: pane.paneId, regFile: pane.regFile, commandId: 'c-spawn'
  });
  const cr = await commitRunning(store, { taskId, generation: 1, expectedRevision: rs.revision, commandId: 'c-run' });
  assert.equal(cr.binding_state, 'bound_verified');

  // one Bridge card and one Helm live pane
  const snap1 = await h.snapshot();
  assert.equal(projectBridge(snap1).cards.filter((c) => c.task_id === taskId).length, 1, 'exactly one Bridge card for the task');
  assert.deepEqual(projectHelm(snap1).live.map((p) => p.task_id), [taskId], 'exactly one live Helm pane for the task');

  // ---- RESTART 1 (mid-lifecycle, at running): abrupt store-driver death, no resurrection ----
  const runningBaseline = await runState(h, taskId);
  await realRestart(h, 'running');
  assert.deepEqual(await runState(h, taskId), runningBaseline, 'restart@running: task/run state is byte-identical after the abrupt restart');
  const snapAfter1 = await h.snapshot();
  assert.equal(projectBridge(snapAfter1).cards.filter((c) => c.task_id === taskId).length, 1, 'restart@running: still exactly one card, not duplicated');
  assert.deepEqual(projectHelm(snapAfter1).live.map((p) => p.task_id), [taskId], 'restart@running: the live pane survived (it is its own tmux process)');

  // progress then completed
  const prog = await appendEvent(store, {
    taskId, generation: 1, eventType: 'progress', producer: 'crewmate', seq: 1, expectedRevision: cr.revision, commandId: 'c-prog'
  });
  const done = await completeRun(store, {
    taskId, generation: 1, expectedRevision: prog.revision, outcome: 'success', producer: 'crewmate', seq: 2, evidence: { ok: true }, commandId: 'c-done'
  });
  assert.equal(done.status, 'completed');
  assert.equal(done.delivered, true, 'the terminal completion produced an outbox delivery');

  // sink effect by event_id; mark-applied; ack (the real consumer adapter drains to idle)
  const drain = await drainToIdle(store, { sink: makeSink(h.sinkDir) });
  assert.equal(drain.result.idle, true, 'the consumer drained the terminal delivery to idle');
  const terminalOutbox = (await h.read("SELECT outbox_id FROM outbox WHERE task_id = $1 AND event_type = 'completed'", [taskId]))[0];
  assert.ok((await h.read('SELECT acked_at FROM outbox WHERE outbox_id = $1', [Number(terminalOutbox.outbox_id)]))[0].acked_at, 'the terminal delivery is acked');
  assert.equal(sinkEffectCount(h.sinkDir), 1, 'exactly one durable sink effect, keyed by event_id');

  // ---- RESTART 2 (mid-lifecycle, at completed+acked): consumer state survives, no dup ----
  const completedBaseline = await runState(h, taskId);
  const cursorBefore = (await readCursor(store, {})).last_acked_outbox_id;
  await realRestart(h, 'completed');
  assert.deepEqual(await runState(h, taskId), completedBaseline, 'restart@completed: task/run state is byte-identical after the abrupt restart');
  assert.equal((await readCursor(h.store, {})).last_acked_outbox_id, cursorBefore, 'restart@completed: the consumer cursor survived the abrupt death');
  assert.equal(sinkEffectCount(h.sinkDir), 1, 'restart@completed: no duplicate sink effect');
  const reDrain = await drainToIdle(h.store, { sink: makeSink(h.sinkDir) });
  assert.equal(reDrain.result.idle, true, 'restart@completed: nothing is redelivered - the acked terminal is not resurrected');
  assert.equal(sinkEffectCount(h.sinkDir), 1, 'restart@completed: recovery drain added no effect');

  // cleanup: exact-pane kill through the production cleanup effect, then finish
  const intent = await cleanupIntent(store, { taskId, generation: 1, expectedRevision: done.revision, commandId: 'c-intent' });
  const effect = killAgentExactPane({ socket: h.socket, endpointId: intent.target.endpoint_id, paneId: intent.target.pane_id, run: intent.target });
  assert.equal(effect.killed, true, 'the cleanup effect killed the exact recorded pane');
  h.markAgentDead(pane.agentPid);
  assert.equal(waitFor(() => !tmuxListPane(h.socket, pane.endpointId, pane.paneId).listed), true, 'the exact pane is gone');
  const fin = await cleanupFinish(store, { taskId, generation: 1, expectedRevision: intent.revision, effectResult: effect, commandId: 'c-finish' });
  assert.equal(fin.binding_state, 'closed');

  // archive (terminal + acked + cleaned)
  const arch = await archiveTask(store, { taskId, expectedRevision: fin.revision, commandId: 'c-arch' });
  assert.equal(arch.status, 'archived');
  await h.snapshot();

  return { expectedActiveAnomalies: [] };
}

import assert from 'node:assert/strict';
import { createTask, beginRun, appendEvent, taskHead } from '../../lib/domain-store.mjs';
import { completeRun } from '../../lib/domain-store-s2.mjs';
import {
  recordSpawn, commitRunning, cleanupIntent, cleanupFinish
} from '../../lib/domain-store-s3.mjs';
import { archiveTask } from '../../lib/domain-store-archive.mjs';
import { getSnapshot } from '../../lib/domain-store-s6.mjs';
import { projectBridge, projectHelm } from '../../lib/projections.mjs';
import { launchAgentPane, killAgentExactPane } from '../fixtures/agent.mjs';
import { makeSink, drainToIdle, sinkEffectCount } from '../fixtures/consumer.mjs';
import { waitFor } from '../fixtures/proc.mjs';
import { tmuxListPane } from '../../lib/tmux-adapter.mjs';

// Workflow 1 - Success (spec matrix row 860): the full happy path against a REAL
// marker-bearing pane on the dedicated socket. create/read task; begin run; marker-bound
// spawn; record-spawn (real capture); commit-running (real probe); one Bridge card and one
// Helm live pane; progress then completed; sink effect by event_id; mark-applied; ack;
// cleanup (exact-pane kill); archive; then TWO store+consumer restarts proving no
// resurrection - task/run state identical and no duplicate cards or sink effects.
export const meta = { tmuxRequired: true };

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
  const bridge1 = projectBridge(snap1);
  const helm1 = projectHelm(snap1);
  assert.equal(bridge1.cards.filter((c) => c.task_id === taskId).length, 1, 'exactly one Bridge card for the task');
  assert.deepEqual(helm1.live.map((p) => p.task_id), [taskId], 'exactly one live Helm pane for the task');

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
  const sink = makeSink(h.sinkDir);
  const drain = await drainToIdle(store, { sink });
  assert.equal(drain.result.idle, true, 'the consumer drained the terminal delivery to idle');
  const terminalOutbox = (await h.read("SELECT outbox_id, event_id FROM outbox WHERE task_id = $1 AND event_type = 'completed'", [taskId]))[0];
  const acked = (await h.read('SELECT acked_at FROM outbox WHERE outbox_id = $1', [Number(terminalOutbox.outbox_id)]))[0];
  assert.ok(acked.acked_at, 'the terminal delivery is acked');
  assert.equal(sinkEffectCount(h.sinkDir), 1, 'exactly one durable sink effect, keyed by event_id');

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
  // A fresh snapshot now reflects the archived, cleaned-up end state (no live pane, closed
  // binding); the restart assertions read this captured state back.
  await h.snapshot();

  // TWO restarts: close+reopen the store and re-claim the consumer, proving no resurrection.
  const baseline = await runState(h, taskId);
  const effectsBefore = sinkEffectCount(h.sinkDir);
  for (let i = 0; i < 2; i += 1) {
    await h.reopenStore();
    const reSink = makeSink(h.sinkDir);
    const reDrain = await drainToIdle(h.store, { sink: reSink });
    assert.equal(reDrain.result.idle, true, `restart ${i + 1}: nothing left to drain`);
    assert.deepEqual(await runState(h, taskId), baseline, `restart ${i + 1}: task/run state is identical (no resurrection)`);
    assert.equal(sinkEffectCount(h.sinkDir), effectsBefore, `restart ${i + 1}: no duplicate sink effect`);
    const reSnap = await getSnapshot(h.store, {});
    assert.equal(projectBridge(reSnap).cards.filter((c) => c.task_id === taskId).length, 1, `restart ${i + 1}: still exactly one card, not duplicated`);
    assert.equal(projectHelm(reSnap).live.length, 0, `restart ${i + 1}: no live pane resurrected for the archived task`);
  }

  return { expectedActiveAnomalies: [] };
}

// The identity-defining state of a task and its run, used to prove restarts change nothing.
async function runState(h, taskId) {
  const t = (await h.read('SELECT status, revision, current_generation FROM tasks WHERE task_id = $1', [taskId]))[0];
  const r = (await h.read('SELECT run_generation, status, binding_state, cleanup_state, closed_at FROM runs WHERE task_id = $1', [taskId]))[0];
  return { t, r };
}

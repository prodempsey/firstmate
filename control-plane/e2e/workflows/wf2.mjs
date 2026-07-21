import assert from 'node:assert/strict';
import { createTask, beginRun } from '../../lib/domain-store.mjs';
import { failRun } from '../../lib/domain-store-s2.mjs';
import { recordSpawn, commitRunning, cleanupIntent, cleanupFinish } from '../../lib/domain-store-s3.mjs';
import { archiveTask } from '../../lib/domain-store-archive.mjs';
import { projectHelm } from '../../lib/projections.mjs';
import { launchAgentPane, killAgentExactPane } from '../fixtures/agent.mjs';
import { makeSink, drainToIdle, sinkEffectCount } from '../fixtures/consumer.mjs';
import { waitFor } from '../fixtures/proc.mjs';
import { tmuxListPane } from '../../lib/tmux-adapter.mjs';

// Workflow 2 - Failure (spec matrix row 861): a verified run that then FAILS. Exactly one
// failed terminal event and one failed outbox delivery, and NO success event; ack; cleanup;
// archive; no live Helm pane at the end.
export const meta = { tmuxRequired: true };

export async function run(h) {
  const store = h.store;
  const taskId = 't-failure';

  const created = await createTask(store, { taskId, kind: 'ship', title: 'e2e failure', origin: 'internal', internalReason: 'r', commandId: 'c-create' });
  const beg = await beginRun(store, { taskId, expectedRevision: created.revision, commandId: 'c-begin' });
  const pane = launchAgentPane({ socket: h.socket, fmHome: h.fmHome, taskId, launchMarker: beg.launch_marker, bindNonce: beg.bind_nonce });
  h.recordAgent({ pid: pane.agentPid, marker: beg.launch_marker, endpointId: pane.endpointId, paneId: pane.paneId });
  const rs = await recordSpawn(store, {
    taskId, generation: 1, expectedRevision: beg.revision, launchMarker: beg.launch_marker,
    endpoint: pane.endpointId, pane: pane.paneId, regFile: pane.regFile, commandId: 'c-spawn'
  });
  const cr = await commitRunning(store, { taskId, generation: 1, expectedRevision: rs.revision, commandId: 'c-run' });
  assert.equal(cr.binding_state, 'bound_verified', 'the run is verified before it fails');

  // Fail the verified run.
  const failed = await failRun(store, {
    taskId, generation: 1, expectedRevision: cr.revision, reason: 'e2e induced failure', producer: 'crewmate', seq: 1, commandId: 'c-fail'
  });
  assert.equal(failed.status, 'failed');
  assert.equal(failed.delivered, true, 'the failure produced an outbox delivery');

  // Exactly one failed terminal event and one failed outbox row; no success event.
  const terminalEvents = await h.read("SELECT event_type FROM task_events WHERE task_id = $1 AND is_terminal", [taskId]);
  assert.deepEqual(terminalEvents.map((e) => e.event_type), ['failed'], 'exactly one terminal event and it is failed');
  const completedCount = await h.read("SELECT count(*)::int AS n FROM task_events WHERE task_id = $1 AND event_type = 'completed'", [taskId]);
  assert.equal(Number(completedCount[0].n), 0, 'there is no success event');
  const failedOutbox = await h.read("SELECT count(*)::int AS n FROM outbox WHERE task_id = $1 AND event_type = 'failed'", [taskId]);
  assert.equal(Number(failedOutbox[0].n), 1, 'exactly one failed outbox delivery');

  // ack via the real consumer, then exact-pane cleanup, then archive.
  const sink = makeSink(h.sinkDir);
  const drain = await drainToIdle(store, { sink });
  assert.equal(drain.result.idle, true, 'the failed delivery is acked');
  assert.equal(sinkEffectCount(h.sinkDir), 1, 'exactly one durable disposition effect for the failure');

  const intent = await cleanupIntent(store, { taskId, generation: 1, expectedRevision: failed.revision, commandId: 'c-intent' });
  const effect = killAgentExactPane({ socket: h.socket, endpointId: intent.target.endpoint_id, paneId: intent.target.pane_id, run: intent.target });
  assert.equal(effect.killed, true, 'the exact pane was killed');
  h.markAgentDead(pane.agentPid);
  assert.equal(waitFor(() => !tmuxListPane(h.socket, pane.endpointId, pane.paneId).listed), true, 'the pane is gone');
  const fin = await cleanupFinish(store, { taskId, generation: 1, expectedRevision: intent.revision, effectResult: effect, commandId: 'c-finish' });

  const arch = await archiveTask(store, { taskId, expectedRevision: fin.revision, commandId: 'c-arch' });
  assert.equal(arch.status, 'archived');

  // No live Helm pane at the end.
  const snap = await h.snapshot();
  assert.equal(projectHelm(snap).live.length, 0, 'no live Helm pane for the failed, cleaned, archived task');

  return { expectedActiveAnomalies: [] };
}

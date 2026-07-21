import assert from 'node:assert/strict';
import { createTask, beginRun, appendEvent } from '../../lib/domain-store.mjs';
import { completeRun } from '../../lib/domain-store-s2.mjs';
import { recordSpawn, commitRunning, cleanupIntent, cleanupFinish } from '../../lib/domain-store-s3.mjs';
import { archiveTask } from '../../lib/domain-store-archive.mjs';
import { projectBridge, projectHelm } from '../../lib/projections.mjs';
import { launchAgentPane, killAgentExactPane } from '../fixtures/agent.mjs';
import { makeSink, drainToIdle } from '../fixtures/consumer.mjs';
import { waitFor } from '../fixtures/proc.mjs';
import { tmuxListPane } from '../../lib/tmux-adapter.mjs';

// Workflow 3 - Blocked and rework (spec matrix row 862): a blocked event shows a blocked
// card and a RETAINED-LIVE pane (the process is still verified, so it stays in the live
// set); rework returns the SAME generation to running (no new run, no new claim); then
// complete and archive without any duplicate card, run, or claim.
export const meta = { tmuxRequired: true };

export async function run(h) {
  const store = h.store;
  const taskId = 't-blocked';

  const created = await createTask(store, { taskId, kind: 'ship', title: 'e2e blocked/rework', origin: 'internal', internalReason: 'r', commandId: 'c-create' });
  const beg = await beginRun(store, { taskId, expectedRevision: created.revision, commandId: 'c-begin' });
  const pane = launchAgentPane({ socket: h.socket, fmHome: h.fmHome, taskId, launchMarker: beg.launch_marker, bindNonce: beg.bind_nonce });
  h.recordAgent({ pid: pane.agentPid, marker: beg.launch_marker, endpointId: pane.endpointId, paneId: pane.paneId });
  const rs = await recordSpawn(store, {
    taskId, generation: 1, expectedRevision: beg.revision, launchMarker: beg.launch_marker,
    endpoint: pane.endpointId, pane: pane.paneId, regFile: pane.regFile, commandId: 'c-spawn'
  });
  let rev = (await commitRunning(store, { taskId, generation: 1, expectedRevision: rs.revision, commandId: 'c-run' })).revision;

  // running -> blocked. The card shows blocked; the verified process is retained-live.
  rev = (await appendEvent(store, { taskId, generation: 1, eventType: 'blocked', producer: 'crewmate', seq: 1, expectedRevision: rev, commandId: 'c-block' })).revision;
  {
    const snap = await h.snapshot();
    const card = projectBridge(snap).cards.find((c) => c.task_id === taskId);
    assert.equal(card.status, 'blocked', 'the Bridge card shows blocked');
    const livePane = projectHelm(snap).live.find((p) => p.task_id === taskId);
    assert.ok(livePane, 'the still-verified pane is retained-live (in the live set) while blocked');
    assert.equal(livePane.task_status, 'blocked');
    assert.equal(livePane.binding_state, 'bound_verified');
  }

  // blocked -> running (unblocked) -> waiting_firstmate -> running (rework). rework is the
  // only event whose legal source is waiting_firstmate; it returns the SAME generation to
  // running - no begin-run, no new generation.
  rev = (await appendEvent(store, { taskId, generation: 1, eventType: 'unblocked', producer: 'firstmate', seq: 2, expectedRevision: rev, commandId: 'c-unblock' })).revision;
  rev = (await appendEvent(store, { taskId, generation: 1, eventType: 'waiting_firstmate', producer: 'crewmate', seq: 3, expectedRevision: rev, commandId: 'c-wait' })).revision;
  const reworked = await appendEvent(store, { taskId, generation: 1, eventType: 'rework', producer: 'firstmate', seq: 4, expectedRevision: rev, commandId: 'c-rework' });
  assert.equal(reworked.status, 'running', 'rework returns the task to running');
  assert.equal(reworked.generation, 1, 'rework stays on the same generation');
  rev = reworked.revision;

  // Still exactly one run row and one generation - no duplicate run.
  const runCount = await h.read('SELECT count(*)::int AS n, max(run_generation)::int AS g FROM runs WHERE task_id = $1', [taskId]);
  assert.equal(Number(runCount[0].n), 1, 'exactly one run row through the whole blocked/rework cycle');
  assert.equal(Number(runCount[0].g), 1, 'still generation 1');

  // complete -> drain(one claim) -> cleanup -> archive.
  const done = await completeRun(store, { taskId, generation: 1, expectedRevision: rev, outcome: 'success', producer: 'crewmate', seq: 5, evidence: {}, commandId: 'c-done' });
  const sink = makeSink(h.sinkDir);
  await drainToIdle(store, { sink });
  // Exactly one consumer receipt for the single terminal delivery - no duplicate claim.
  const terminalReceipts = await h.read(
    "SELECT count(*)::int AS n FROM consumer_receipts cr JOIN outbox o ON o.event_id = cr.event_id WHERE o.task_id = $1 AND o.event_type = 'completed'", [taskId]
  );
  assert.equal(Number(terminalReceipts[0].n), 1, 'exactly one terminal claim/receipt (no duplicate claim)');

  const intent = await cleanupIntent(store, { taskId, generation: 1, expectedRevision: done.revision, commandId: 'c-intent' });
  const effect = killAgentExactPane({ socket: h.socket, endpointId: intent.target.endpoint_id, paneId: intent.target.pane_id, run: intent.target });
  h.markAgentDead(pane.agentPid);
  assert.equal(waitFor(() => !tmuxListPane(h.socket, pane.endpointId, pane.paneId).listed), true, 'the pane is gone');
  const fin = await cleanupFinish(store, { taskId, generation: 1, expectedRevision: intent.revision, effectResult: effect, commandId: 'c-finish' });
  const arch = await archiveTask(store, { taskId, expectedRevision: fin.revision, commandId: 'c-arch' });
  assert.equal(arch.status, 'archived');

  // Still exactly one Bridge card for the task - never duplicated across the cycle.
  const finalSnap = await h.snapshot();
  assert.equal(projectBridge(finalSnap).cards.filter((c) => c.task_id === taskId).length, 1, 'still exactly one card - no duplicate');

  return { expectedActiveAnomalies: [] };
}

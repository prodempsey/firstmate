import assert from 'node:assert/strict';
import { createTask, beginRun, appendEvent } from '../../lib/domain-store.mjs';
import { recordSpawn, commitRunning } from '../../lib/domain-store-s3.mjs';
import { resolveAnomaly } from '../../lib/domain-store-s5.mjs';
import { projectHelm } from '../../lib/projections.mjs';
import { probeIdentityTransientAware } from '../../lib/backend-scan-s5.mjs';
import { launchAgentPane, launchMarkerlessPane } from '../fixtures/agent.mjs';
import { makeSink, drainToIdle } from '../fixtures/consumer.mjs';
import { waitFor } from '../fixtures/proc.mjs';
import { tmuxListPane } from '../../lib/tmux-adapter.mjs';

// Workflow 4 - Unexpected death (spec matrix row 863): kill the EXACT recorded agent PID
// while the run is running, blocked, and waiting_firstmate (three separate cases); the
// reconciler fails the generation from a real probe that now sees the pane gone. A
// shell-only markerless pane lands in the orphan inspector (and is never killed by this
// slice). PID reuse cannot match: a live pane probed with reused start-ticks is a
// definitive pid_reuse_suspected, never a spurious match.
export const meta = { tmuxRequired: true };

async function toRunning(h, taskId, seed) {
  const created = await createTask(h.store, { taskId, kind: 'ship', title: `death ${taskId}`, origin: 'internal', internalReason: 'r', commandId: `c-create-${taskId}` });
  const beg = await beginRun(h.store, { taskId, expectedRevision: created.revision, commandId: `c-begin-${taskId}` });
  const pane = launchAgentPane({ socket: h.socket, fmHome: h.fmHome, taskId, launchMarker: beg.launch_marker, bindNonce: beg.bind_nonce });
  h.recordAgent({ pid: pane.agentPid, marker: beg.launch_marker, endpointId: pane.endpointId, paneId: pane.paneId });
  const rs = await recordSpawn(h.store, {
    taskId, generation: 1, expectedRevision: beg.revision, launchMarker: beg.launch_marker,
    endpoint: pane.endpointId, pane: pane.paneId, regFile: pane.regFile, commandId: `c-spawn-${taskId}`
  });
  const cr = await commitRunning(h.store, { taskId, generation: 1, expectedRevision: rs.revision, commandId: `c-run-${taskId}` });
  return { pane, rev: cr.revision };
}

// Kill the exact agent, wait for the pane to vanish, run the task-scoped reconcile pass,
// assert the generation is failed+lost, then resolve the (explained) death anomalies with
// agent authority so only genuinely-unremediable residue remains.
async function killAndReconcile(h, taskId, agentPid, endpointId, paneId) {
  // Fail-CLOSED at the kill boundary (Q3): killRecordedAgent asserts this PID is
  // fixture-recorded in the harness registry IMMEDIATELY before it signals, then kills and
  // marks it dead. An unrecorded PID would throw here rather than being signalled.
  h.killRecordedAgent(agentPid);
  assert.equal(waitFor(() => !tmuxListPane(h.socket, endpointId, paneId).listed), true, `${taskId}: the exact pane is gone after the kill`);

  const out = h.cp(['reconcile', '--task', taskId]);
  assert.equal(out.status, 0, `${taskId}: reconcile pass ran`);
  const run = (await h.read('SELECT status, binding_state FROM runs WHERE task_id = $1 AND run_generation = 1', [taskId]))[0];
  assert.equal(run.status, 'failed', `${taskId}: the reconciler failed the generation`);
  // The terminal fail routes the lost binding to cleanup_pending (the endpoint metadata
  // remains for a later cleanup saga); 'lost' is a transient within-pass state.
  assert.ok(['lost', 'cleanup_pending', 'closed'].includes(run.binding_state), `${taskId}: the failed generation's binding is no longer active (got ${run.binding_state})`);
  const task = (await h.read('SELECT status FROM tasks WHERE task_id = $1', [taskId]))[0];
  assert.equal(task.status, 'failed', `${taskId}: the task is failed`);

  const anomalies = await h.read("SELECT fingerprint FROM anomalies WHERE task_id = $1 AND status = 'active'", [taskId]);
  assert.ok(anomalies.length >= 1, `${taskId}: the death produced at least one anomaly`);
  for (const a of anomalies) {
    await resolveAnomaly(h.store, { fingerprint: a.fingerprint, reason: 'e2e: provably-dead run reconciled to terminal', resolutionKind: 'agent_verified', commandId: `c-res-${a.fingerprint}` });
  }
}

export async function run(h) {
  // Launch the shell-only markerless pane FIRST. It does double duty: it keeps the isolated
  // tmux server reachable after each agent pane is killed (so a killed agent probes as a
  // DEFINITIVE missing_pane on a reachable server, not a transient unreachable-server), and
  // it is itself the orphan-inspector subject. It is never killed by this slice.
  const shell = launchMarkerlessPane({ socket: h.socket });
  h.recordKeepalive(shell.pid, 'shell-only-orphan'); // stays alive to finals (never killed this slice); reclaimed at teardown

  // Case running: PID reuse cannot match (probe the live pane with reused start-ticks),
  // then kill while running.
  const a = await toRunning(h, 't-death-running', 1);
  const runRow = (await h.read('SELECT * FROM runs WHERE task_id = $1 AND run_generation = 1', ['t-death-running']))[0];
  const reused = probeIdentityTransientAware({ run: { ...runRow, agent_start_ticks: Number(runRow.agent_start_ticks) + 999999 }, socket: h.socket });
  assert.equal(reused.matches, false, 'a reused start-ticks does not match');
  assert.equal(reused.transient, false, 'the mismatch is definitive, not transient');
  assert.equal(reused.anomalyClass, 'pid_reuse_suspected', 'PID reuse is surfaced as pid_reuse_suspected, never a spurious match');
  await killAndReconcile(h, 't-death-running', a.pane.agentPid, a.pane.endpointId, a.pane.paneId);

  // Case blocked.
  const b = await toRunning(h, 't-death-blocked', 2);
  await appendEvent(h.store, { taskId: 't-death-blocked', generation: 1, eventType: 'blocked', producer: 'crewmate', seq: 1, expectedRevision: b.rev, commandId: 'c-block-b' });
  await killAndReconcile(h, 't-death-blocked', b.pane.agentPid, b.pane.endpointId, b.pane.paneId);

  // Case waiting_firstmate.
  const c = await toRunning(h, 't-death-waiting', 3);
  await appendEvent(h.store, { taskId: 't-death-waiting', generation: 1, eventType: 'waiting_firstmate', producer: 'crewmate', seq: 1, expectedRevision: c.rev, commandId: 'c-wait-c' });
  await killAndReconcile(h, 't-death-waiting', c.pane.agentPid, c.pane.endpointId, c.pane.paneId);

  // A full, unfiltered reconcile pass runs the marker scan and reports the still-live
  // markerless pane as a shell-only orphan in the inspector.
  const full = h.cp(['reconcile']);
  assert.equal(full.status, 0, 'the full reconcile pass ran');
  const orphan = (await h.read("SELECT fingerprint, detail_json FROM anomalies WHERE anomaly_class = 'orphan_pane' AND status = 'active'"));
  assert.ok(orphan.length >= 1, 'the markerless pane produced an active orphan_pane anomaly');
  const snap = await h.snapshot();
  const inspector = projectHelm(snap).orphan_inspector;
  assert.ok(inspector.some((o) => o.reason === 'shell_only_or_markerless'), 'the shell-only pane lands in the orphan inspector');

  // Ack the three failed-terminal deliveries through the real consumer so the outbox is
  // clean at finals.
  const sink = makeSink(h.sinkDir);
  await drainToIdle(h.store, { sink });

  // The full pass also observes that the three killed runs' launch markers are now absent
  // (launch_marker_missing) - an explained, agent-verifiable consequence of the deaths.
  // Resolve every active anomaly EXCEPT the markerless orphan_pane, which is resolvable only
  // by later human disposition (spec 833-834) and is the ONE allowlisted active residue.
  const active = await h.read("SELECT fingerprint, anomaly_class FROM anomalies WHERE status = 'active'");
  const orphanFingerprints = [];
  for (const anom of active) {
    if (anom.anomaly_class === 'orphan_pane') { orphanFingerprints.push(anom.fingerprint); continue; }
    await resolveAnomaly(h.store, { fingerprint: anom.fingerprint, reason: 'e2e: explained by reconciled death', resolutionKind: 'agent_verified', commandId: `c-res-full-${anom.fingerprint}` });
  }
  return { expectedActiveAnomalies: orphanFingerprints };
}

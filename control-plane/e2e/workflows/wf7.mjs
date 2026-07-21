import assert from 'node:assert/strict';
import { createTask, beginRun } from '../../lib/domain-store.mjs';
import { recordSpawn, cleanupIntent, cleanupFinish } from '../../lib/domain-store-s3.mjs';
import { completeRun } from '../../lib/domain-store-s2.mjs';
import { reconcilePass } from '../../lib/reconciler.mjs';
import { resolveAnomaly } from '../../lib/domain-store-s5.mjs';
import { archiveTask } from '../../lib/domain-store-archive.mjs';
import { projectHelm } from '../../lib/projections.mjs';
import { probeIdentityTransientAware } from '../../lib/backend-scan-s5.mjs';
import { launchAgentPane } from '../fixtures/agent.mjs';
import { doubleRunning } from '../fixtures/lifecycle.mjs';
import { makeSink, drainToIdle } from '../fixtures/consumer.mjs';
import { killExactPid, waitFor } from '../fixtures/proc.mjs';
import { tmuxListPane, killExactPane } from '../../lib/tmux-adapter.mjs';

// Workflow 7 - Spawn saga crash cutpoints (spec matrix row 866, resolves R3-2): the
// coordinator/adapter is "crashed" (the saga simply stops) at each of the five cutpoints and
// a bounded reconcile pass reconciles/adopts/fails/cleans by marker and EXACT identity:
//   A after begin-run before any endpoint    -> fail the never-recorded-spawn generation
//   B after a marker pane before record-spawn -> the unknown-marker pane is an orphan (never
//                                                adopted, never killed) and the run fails
//   C after record-spawn before commit-running -> the verified live case is PROMOTED to running
//   D after terminal commit before cleanup-intent -> terminal-without-cleanup, then cleaned
//   E after cleanup effect before cleanup-finish  -> cleanup-finish resumes idempotently
// No unrecorded marker-bearing pane survives to the finals.
export const meta = { tmuxRequired: true };

const FAR_FUTURE = '2999-01-01T00:00:00.000Z';
const noPresence = () => ({ present: false });

export async function run(h) {
  const store = h.store;
  const realProbe = ({ run }) => probeIdentityTransientAware({ run, socket: h.socket });
  const sink = makeSink(h.sinkDir);
  const allowlist = [];

  // ---- Cutpoint A: after begin-run, before any endpoint -> fail never-recorded-spawn ----
  {
    const t = 't7-a';
    const created = await createTask(store, { taskId: t, kind: 'ship', title: 'saga A', origin: 'internal', internalReason: 'r', commandId: `c-create-${t}` });
    await beginRun(store, { taskId: t, expectedRevision: created.revision, commandId: `c-begin-${t}` }); // spawning, endpoint null
    const pass = await reconcilePass(store, { taskId: t, nonce: 'saga-a', deadlineNow: FAR_FUTURE });
    assert.ok(pass.committed.some((c) => c.kind === 'fail'), 'A: the reconciler failed the never-recorded-spawn generation');
    const run = (await h.read('SELECT status FROM runs WHERE task_id = $1 AND run_generation = 1', [t]))[0];
    assert.equal(run.status, 'failed', 'A: the run is failed');
    assert.equal((await h.read('SELECT status FROM tasks WHERE task_id = $1', [t]))[0].status, 'failed', 'A: the task is failed');
  }

  // ---- Cutpoint B: marker-bearing pane exists, record-spawn never ran -> unknown-marker orphan ----
  {
    const t = 't7-b';
    const created = await createTask(store, { taskId: t, kind: 'ship', title: 'saga B', origin: 'internal', internalReason: 'r', commandId: `c-create-${t}` });
    const beg = await beginRun(store, { taskId: t, expectedRevision: created.revision, commandId: `c-begin-${t}` });
    // The adapter created the marker pane but crashed before record-spawn: endpoint stays null.
    const pane = launchAgentPane({ socket: h.socket, fmHome: h.fmHome, taskId: t, launchMarker: beg.launch_marker, bindNonce: beg.bind_nonce });
    h.recordAgent({ pid: pane.agentPid, marker: beg.launch_marker, endpointId: pane.endpointId, paneId: pane.paneId });

    // A fleet-wide pass: the marker is unknown (its run has no endpoint), so the live pane is
    // an orphan_pane (never adopted, never killed), and the spawning run is failed.
    const pass = await reconcilePass(store, { taskId: null, nonce: 'saga-b', deadlineNow: FAR_FUTURE, probeIdentity: realProbe });
    assert.ok(pass.committed.some((c) => c.kind === 'fail'), 'B: the never-recorded-spawn run is failed');
    const orphan = await h.read("SELECT fingerprint, detail_json FROM anomalies WHERE anomaly_class = 'orphan_pane' AND status = 'active'");
    assert.ok(orphan.some((o) => (o.detail_json.reason || o.detail_json?.reason) === 'unknown_marker' || JSON.stringify(o.detail_json).includes('unknown_marker')), 'B: the record-spawn-less marker pane is an unknown_marker orphan');
    // The orphan pane is never adopted or killed by the slice; this fixture reclaims it by
    // EXACT pane identity so no unrecorded marker-bearing pane survives to the finals.
    const run = (await h.read('SELECT * FROM runs WHERE task_id = $1 AND run_generation = 1', [t]))[0];
    killExactPane({ socket: h.socket, endpointId: pane.endpointId, paneId: pane.paneId, run: { ...run, endpoint_id: pane.endpointId, pane_id: pane.paneId } });
    killExactPid(pane.agentPid);
    h.markAgentDead(pane.agentPid);
    assert.equal(waitFor(() => !tmuxListPane(h.socket, pane.endpointId, pane.paneId).listed), true, 'B: the orphan pane is reclaimed by exact identity');
    // The orphan_pane audit row is explained residue pending human disposition -> allowlisted.
    allowlist.push(...orphan.map((o) => o.fingerprint));
  }

  // ---- Cutpoint C: after record-spawn, before commit-running -> PROMOTED to running ----
  {
    const t = 't7-c';
    const created = await createTask(store, { taskId: t, kind: 'ship', title: 'saga C', origin: 'internal', internalReason: 'r', commandId: `c-create-${t}` });
    const beg = await beginRun(store, { taskId: t, expectedRevision: created.revision, commandId: `c-begin-${t}` });
    const pane = launchAgentPane({ socket: h.socket, fmHome: h.fmHome, taskId: t, launchMarker: beg.launch_marker, bindNonce: beg.bind_nonce });
    h.recordAgent({ pid: pane.agentPid, marker: beg.launch_marker, endpointId: pane.endpointId, paneId: pane.paneId });
    // record-spawn commits the endpoint (real capture); commit-running never runs (the crash).
    await recordSpawn(store, { taskId: t, generation: 1, expectedRevision: beg.revision, launchMarker: beg.launch_marker, endpoint: pane.endpointId, pane: pane.paneId, regFile: pane.regFile, commandId: `c-spawn-${t}` });

    const pass = await reconcilePass(store, { taskId: t, nonce: 'saga-c', probeIdentity: realProbe });
    assert.ok(pass.committed.some((c) => c.kind === 'promote'), 'C: the reconciler promoted the verified spawning generation');
    const run = (await h.read('SELECT status, binding_state FROM runs WHERE task_id = $1 AND run_generation = 1', [t]))[0];
    assert.equal(run.status, 'open', 'C: the run is open');
    assert.equal(run.binding_state, 'bound_verified', 'C: the binding is verified (post-record-spawn live case promoted to running)');
    assert.equal((await h.read('SELECT status FROM tasks WHERE task_id = $1', [t]))[0].status, 'running', 'C: the task is running');

    // Carry the promoted run to a clean terminal: complete, exact-pane cleanup.
    const rev = Number((await h.read('SELECT revision FROM tasks WHERE task_id = $1', [t]))[0].revision);
    const done = await completeRun(store, { taskId: t, generation: 1, expectedRevision: rev, outcome: 'success', producer: 'crewmate', seq: 1, evidence: {}, commandId: `c-done-${t}` });
    const intent = await cleanupIntent(store, { taskId: t, generation: 1, expectedRevision: done.revision, commandId: `c-intent-${t}` });
    const effect = killExactPane({ socket: h.socket, endpointId: intent.target.endpoint_id, paneId: intent.target.pane_id, run: intent.target });
    killExactPid(pane.agentPid);
    h.markAgentDead(pane.agentPid);
    assert.equal(waitFor(() => !tmuxListPane(h.socket, pane.endpointId, pane.paneId).listed), true, 'C: the pane is gone after cleanup');
    await cleanupFinish(store, { taskId: t, generation: 1, expectedRevision: intent.revision, effectResult: effect, commandId: `c-finish-${t}` });
  }

  // ---- Cutpoint D: after terminal commit, before cleanup-intent -> terminal_without_cleanup ----
  {
    const t = 't7-d';
    const started = await doubleRunning(store, t, { seed: 70 });
    const done = await completeRun(store, { taskId: t, generation: 1, expectedRevision: started.revision, outcome: 'success', producer: 'crewmate', seq: 1, evidence: {}, commandId: `c-done-${t}` });
    // Reconcile sees a terminal run whose cleanup never started (grace forced past via FAR_FUTURE).
    await reconcilePass(store, { taskId: t, nonce: 'saga-d', deadlineNow: FAR_FUTURE, cleanupProbe: noPresence });
    const tw = await h.read("SELECT fingerprint FROM anomalies WHERE anomaly_class = 'terminal_without_cleanup' AND status = 'active' AND task_id = $1", [t]);
    assert.equal(tw.length, 1, 'D: the reconciler flagged terminal_without_cleanup');
    // Firstmate cleans up; the anomaly resolves once cleanup is cleaned.
    const intent = await cleanupIntent(store, { taskId: t, generation: 1, expectedRevision: done.revision, commandId: `c-intent-${t}` });
    await cleanupFinish(store, { taskId: t, generation: 1, expectedRevision: intent.revision, effectResult: { killed: true, confirmed_absent: true }, commandId: `c-finish-${t}` });
    await resolveAnomaly(store, { fingerprint: tw[0].fingerprint, reason: 'e2e: cleanup completed', resolutionKind: 'agent_verified', commandId: `c-res-${t}` });
  }

  // ---- Cutpoint E: after cleanup effect, before cleanup-finish -> cleanup-finish resumes ----
  {
    const t = 't7-e';
    const started = await doubleRunning(store, t, { seed: 71 });
    const done = await completeRun(store, { taskId: t, generation: 1, expectedRevision: started.revision, outcome: 'success', producer: 'crewmate', seq: 1, evidence: {}, commandId: `c-done-${t}` });
    const intent = await cleanupIntent(store, { taskId: t, generation: 1, expectedRevision: done.revision, commandId: `c-intent-${t}` });
    // The cleanup EFFECT ran (target confirmed absent) but cleanup-finish never committed.
    // Reconcile leaves intent_committed untouched (it never finishes cleanup itself).
    await reconcilePass(store, { taskId: t, nonce: 'saga-e', cleanupProbe: noPresence });
    const mid = (await h.read('SELECT cleanup_state FROM runs WHERE task_id = $1 AND run_generation = 1', [t]))[0];
    assert.equal(mid.cleanup_state, 'intent_committed', 'E: the reconciler left cleanup at intent_committed');
    // Recovery: cleanup-finish resumes idempotently to cleaned/closed.
    const fin = await cleanupFinish(store, { taskId: t, generation: 1, expectedRevision: intent.revision, effectResult: { killed: true, confirmed_absent: true }, commandId: `c-finish-${t}` });
    assert.equal(fin.cleanup_state, 'cleaned', 'E: cleanup-finish resumed to cleaned');
    assert.equal(fin.binding_state, 'closed', 'E: the binding is closed');
  }

  // Drain every terminal delivery produced across the cutpoints so the outbox is clean.
  await drainToIdle(store, { sink });

  // No unrecorded marker-bearing pane survives on the socket.
  const snap = await h.snapshot();
  assert.ok(projectHelm(snap).orphan_inspector.every((o) => o.source === 'anomaly'), 'the orphan inspector is derived only from present-pane anomalies');

  return { expectedActiveAnomalies: allowlist };
}

import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { cleanupIntent, cleanupFinish } from '../../lib/domain-store-s3.mjs';
import { completeRun } from '../../lib/domain-store-s2.mjs';
import { reconcilePass } from '../../lib/reconciler.mjs';
import { resolveAnomaly } from '../../lib/domain-store-s5.mjs';
import { projectHelm } from '../../lib/projections.mjs';
import { probeIdentityTransientAware } from '../../lib/backend-scan-s5.mjs';
import { makeSink, drainToIdle } from '../fixtures/consumer.mjs';
import { waitForFile, waitFor } from '../fixtures/proc.mjs';
import { tmuxListPane, killExactPane } from '../../lib/tmux-adapter.mjs';

// Workflow 7 - Spawn saga crash cutpoints (spec matrix row 866, resolves R3-2). At EACH of
// the five cutpoints a real coordinator/adapter DRIVER child process (fixtures/crash-saga.mjs)
// runs the saga up to that point and hangs; the parent then SIGKILLs that exact recorded child
// PID - a genuine crash mid-saga - and a bounded reconcile pass reconciles/adopts/fails/cleans
// by marker and EXACT identity:
//   A after begin-run before any endpoint    -> fail the never-recorded-spawn generation
//   B after a marker pane before record-spawn -> unknown-marker orphan (never adopted/killed), run failed
//   C after record-spawn before commit-running -> the verified live case is PROMOTED to running
//   D after terminal commit before cleanup-intent -> terminal-without-cleanup, then cleaned
//   E after cleanup effect before cleanup-finish  -> cleanup-finish resumes idempotently
// No unrecorded marker-bearing pane survives to the finals.
export const meta = { tmuxRequired: true };

const CRASH_SAGA = fileURLToPath(new URL('../fixtures/crash-saga.mjs', import.meta.url));
const FAR_FUTURE = '2999-01-01T00:00:00.000Z';
const noPresence = () => ({ present: false });

// Spawn the saga driver, let it reach `cut`, then CRASH it by killing its exact recorded PID.
// Returns the driver's readiness record ({ pid, pane }). For B/C the live pane it launched is
// recorded as a fixture agent (it survives the driver's death, like a real orphaned endpoint).
async function crashAt(h, cut, taskId, seed = 0) {
  const readyFile = path.join(h.fmHome, `saga-ready-${cut}`);
  const child = h.spawnDriver(CRASH_SAGA, { CP_TASK_ID: taskId, CP_CUTPOINT: cut, CP_READY_FILE: readyFile, CP_SEED: String(seed) });
  h.recordChild(child.pid, `saga-${cut}`);
  assert.equal(waitForFile(readyFile), true, `${cut}: the saga driver reached the cutpoint`);
  const ready = JSON.parse(fs.readFileSync(readyFile, 'utf8'));
  if (ready.pane) {
    h.recordAgent({ pid: ready.pane.agentPid, marker: ready.pane.launchMarker, endpointId: ready.pane.endpointId, paneId: ready.pane.paneId });
  }
  // The crash: kill the exact recorded coordinator/adapter PID at the cutpoint and reap it.
  const dead = await h.crashRecordedChild(child.pid, child);
  assert.equal(dead.signalCode, 'SIGKILL', `${cut}: the coordinator/adapter process was SIGKILLed at the cutpoint`);
  return ready;
}

export async function run(h) {
  const store = h.store;
  const realProbe = ({ run }) => probeIdentityTransientAware({ run, socket: h.socket });
  const allowlist = [];

  // A: crash after begin-run, before any endpoint -> fail never-recorded-spawn.
  {
    const t = 't7-a';
    await crashAt(h, 'A', t);
    const pass = await reconcilePass(store, { taskId: t, nonce: 'saga-a', deadlineNow: FAR_FUTURE });
    assert.ok(pass.committed.some((c) => c.kind === 'fail'), 'A: the reconciler failed the never-recorded-spawn generation');
    assert.equal((await h.read('SELECT status FROM runs WHERE task_id = $1 AND run_generation = 1', [t]))[0].status, 'failed', 'A: the run is failed');
    assert.equal((await h.read('SELECT status FROM tasks WHERE task_id = $1', [t]))[0].status, 'failed', 'A: the task is failed');
  }

  // B: crash after a marker pane exists but before record-spawn -> unknown-marker orphan + fail.
  {
    const t = 't7-b';
    const ready = await crashAt(h, 'B', t);
    const pass = await reconcilePass(store, { taskId: null, nonce: 'saga-b', deadlineNow: FAR_FUTURE, probeIdentity: realProbe });
    assert.ok(pass.committed.some((c) => c.kind === 'fail'), 'B: the never-recorded-spawn run is failed');
    const orphan = await h.read("SELECT fingerprint, detail_json FROM anomalies WHERE anomaly_class = 'orphan_pane' AND status = 'active'");
    assert.ok(orphan.some((o) => JSON.stringify(o.detail_json).includes('unknown_marker')), 'B: the record-spawn-less marker pane is an unknown_marker orphan (never adopted)');
    // The slice never kills the orphan; this fixture reclaims it by exact identity so no
    // unrecorded marker-bearing pane survives to the finals.
    killExactPane({ socket: h.socket, endpointId: ready.pane.endpointId, paneId: ready.pane.paneId, run: { endpoint_id: ready.pane.endpointId, pane_id: ready.pane.paneId } });
    h.killRecordedAgent(ready.pane.agentPid);
    assert.equal(waitFor(() => !tmuxListPane(h.socket, ready.pane.endpointId, ready.pane.paneId).listed), true, 'B: the orphan pane is reclaimed by exact identity');
    allowlist.push(...orphan.map((o) => o.fingerprint));
  }

  // C: crash after record-spawn, before commit-running -> PROMOTED to running.
  {
    const t = 't7-c';
    const ready = await crashAt(h, 'C', t);
    const pass = await reconcilePass(store, { taskId: t, nonce: 'saga-c', probeIdentity: realProbe });
    assert.ok(pass.committed.some((c) => c.kind === 'promote'), 'C: the reconciler promoted the verified spawning generation');
    const run = (await h.read('SELECT status, binding_state FROM runs WHERE task_id = $1 AND run_generation = 1', [t]))[0];
    assert.equal(run.status, 'open', 'C: the run is open');
    assert.equal(run.binding_state, 'bound_verified', 'C: the binding is verified (post-record-spawn live case promoted to running)');
    assert.equal((await h.read('SELECT status FROM tasks WHERE task_id = $1', [t]))[0].status, 'running', 'C: the task is running');
    // Carry the promoted run to a clean terminal via the exact-pane cleanup.
    const rev = Number((await h.read('SELECT revision FROM tasks WHERE task_id = $1', [t]))[0].revision);
    const done = await completeRun(store, { taskId: t, generation: 1, expectedRevision: rev, outcome: 'success', producer: 'crewmate', seq: 1, evidence: {}, commandId: `c-done-${t}` });
    const intent = await cleanupIntent(store, { taskId: t, generation: 1, expectedRevision: done.revision, commandId: `c-intent-${t}` });
    const effect = killExactPane({ socket: h.socket, endpointId: intent.target.endpoint_id, paneId: intent.target.pane_id, run: intent.target });
    h.killRecordedAgent(ready.pane.agentPid);
    assert.equal(waitFor(() => !tmuxListPane(h.socket, ready.pane.endpointId, ready.pane.paneId).listed), true, 'C: the pane is gone after cleanup');
    await cleanupFinish(store, { taskId: t, generation: 1, expectedRevision: intent.revision, effectResult: effect, commandId: `c-finish-${t}` });
  }

  // D: crash after terminal commit, before cleanup-intent -> terminal_without_cleanup, then cleaned.
  {
    const t = 't7-d';
    await crashAt(h, 'D', t, 70);
    await reconcilePass(store, { taskId: t, nonce: 'saga-d', deadlineNow: FAR_FUTURE, cleanupProbe: noPresence });
    const tw = await h.read("SELECT fingerprint FROM anomalies WHERE anomaly_class = 'terminal_without_cleanup' AND status = 'active' AND task_id = $1", [t]);
    assert.equal(tw.length, 1, 'D: the reconciler flagged terminal_without_cleanup');
    const rev = Number((await h.read('SELECT revision FROM tasks WHERE task_id = $1', [t]))[0].revision);
    const intent = await cleanupIntent(store, { taskId: t, generation: 1, expectedRevision: rev, commandId: `c-intent-${t}` });
    await cleanupFinish(store, { taskId: t, generation: 1, expectedRevision: intent.revision, effectResult: { killed: true, confirmed_absent: true }, commandId: `c-finish-${t}` });
    await resolveAnomaly(store, { fingerprint: tw[0].fingerprint, reason: 'e2e: cleanup completed', resolutionKind: 'agent_verified', commandId: `c-res-${t}` });
  }

  // E: crash after cleanup effect, before cleanup-finish -> cleanup-finish resumes idempotently.
  {
    const t = 't7-e';
    await crashAt(h, 'E', t, 71);
    await reconcilePass(store, { taskId: t, nonce: 'saga-e', cleanupProbe: noPresence });
    const mid = (await h.read('SELECT cleanup_state FROM runs WHERE task_id = $1 AND run_generation = 1', [t]))[0];
    assert.equal(mid.cleanup_state, 'intent_committed', 'E: the reconciler left cleanup at intent_committed');
    const rev = Number((await h.read('SELECT revision FROM tasks WHERE task_id = $1', [t]))[0].revision);
    const fin = await cleanupFinish(store, { taskId: t, generation: 1, expectedRevision: rev, effectResult: { killed: true, confirmed_absent: true }, commandId: `c-finish-${t}` });
    assert.equal(fin.cleanup_state, 'cleaned', 'E: cleanup-finish resumed to cleaned');
    assert.equal(fin.binding_state, 'closed', 'E: the binding is closed');
  }

  // Drain every terminal delivery produced across the cutpoints so the outbox is clean.
  await drainToIdle(store, { sink: makeSink(h.sinkDir) });

  const snap = await h.snapshot();
  assert.ok(projectHelm(snap).orphan_inspector.every((o) => o.source === 'anomaly'), 'the orphan inspector is derived only from present-pane anomalies');

  return { expectedActiveAnomalies: allowlist };
}

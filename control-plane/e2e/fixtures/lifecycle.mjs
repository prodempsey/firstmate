import { createTask, beginRun } from '../../lib/domain-store.mjs';
import { recordSpawn, commitRunning, cleanupIntent, cleanupFinish } from '../../lib/domain-store-s3.mjs';
import { captureOk, probeMatch } from './doubles.mjs';

// Shared lifecycle builders for the NO-TMUX workflows (spec matrix: wf5/6/8/9 do not
// require a real pane). These drive a task to a verified running binding through the SAME
// injected identity doubles the landed archive/S6/S4 contract suites use, so the domain
// state is genuine (a real record-spawn/commit-running transition, a real bound_verified
// run) without a host process. Workflows that DO need a live process use fixtures/agent.mjs.

// createTask -> begin-run -> record-spawn (captured double) -> commit-running (matching
// probe double). Returns { revision, generation, launchMarker }.
export async function doubleRunning(store, taskId, { seed = 0, origin = 'internal' } = {}) {
  const createParams = origin === 'captain_order'
    ? { taskId, kind: 'ship', title: `T ${taskId}`, origin: 'captain_order', orderRef: 'ORD-1', commandId: `c-create-${taskId}` }
    : { taskId, kind: 'ship', title: `T ${taskId}`, origin: 'internal', internalReason: 'r', commandId: `c-create-${taskId}` };
  const created = await createTask(store, createParams);
  const beg = await beginRun(store, { taskId, expectedRevision: created.revision, commandId: `c-begin-${taskId}` });
  const rs = await recordSpawn(store, {
    taskId, generation: 1, expectedRevision: beg.revision, launchMarker: beg.launch_marker,
    endpoint: `@${seed}`, pane: `%${seed}`, regFile: `/reg-${taskId}`, commandId: `c-spawn-${taskId}`
  }, { captureIdentity: captureOk(seed) });
  const cr = await commitRunning(store, { taskId, generation: 1, expectedRevision: rs.revision, commandId: `c-run-${taskId}` }, { probeIdentity: probeMatch() });
  return { revision: cr.revision, generation: 1, launchMarker: beg.launch_marker };
}

// Finish the cleanup saga in double mode (no real pane to kill): commit intent, then finish
// with a synthetic effect result asserting the target is confirmed absent.
export async function doubleCleanup(store, taskId, expectedRevision) {
  const intent = await cleanupIntent(store, { taskId, generation: 1, expectedRevision, commandId: `c-intent-${taskId}` });
  const fin = await cleanupFinish(store, {
    taskId, generation: 1, expectedRevision: intent.revision,
    effectResult: { killed: true, confirmed_absent: true }, commandId: `c-finish-${taskId}`
  });
  return fin.revision;
}

import assert from 'node:assert/strict';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';
import { readCursor } from '../../lib/domain-store-s4.mjs';
import { projectBridge, projectHelm } from '../../lib/projections.mjs';
import { sinkEffectCount } from '../fixtures/consumer.mjs';

// Workflow 1 - Success (spec matrix row 860; qa-s7r2-q76). The full happy path against a REAL
// marker-bearing pane, driven by a real DRIVER child process that OWNS the task lifecycle AND
// the FirstMate consumer lease (fixtures/driver.mjs). Twice, mid-lifecycle, the parent
// SIGKILLs the owning driver and launches a FRESH driver process against the same durable
// fixture data/sink to resume the remaining steps. Because the killed process owns the
// consumer lease and the lifecycle, each relaunch forces a genuine store+consumer reopen: the
// fresh process re-claims the lease (a strictly higher owner_epoch) and performs the remaining
// work. If a relaunch were removed, those remaining steps (progress/complete/drain, then
// cleanup/archive) would never run and the workflow would not reach an acked, cleaned,
// archived end state - so the restart is load-bearing, not decorative.
export const meta = { tmuxRequired: true };

const DRIVER = fileURLToPath(new URL('../fixtures/driver.mjs', import.meta.url));

// A line-protocol handle over a driver child: read newline-delimited JSON results, send
// newline commands. ready() reads the driver's startup record; send(cmd) awaits its result.
function driverHandle(child) {
  const rl = readline.createInterface({ input: child.stdout });
  const q = []; const waiters = [];
  rl.on('line', (line) => {
    const obj = JSON.parse(line);
    if (waiters.length) waiters.shift().resolve(obj); else q.push(obj);
  });
  // Bounded wait for the next driver line: a dead/absent driver (e.g. a relaunch that was
  // skipped) rejects promptly instead of hanging forever, so the restart is mutation-sensitive
  // - removing a relaunch makes the workflow FAIL rather than deadlock.
  const next = (what) => new Promise((resolve, reject) => {
    if (q.length) { resolve(q.shift()); return; }
    const timer = setTimeout(() => reject(new Error(`driver did not respond to ${what} within 20s (is a fresh driver running?)`)), 20000);
    waiters.push({ resolve: (obj) => { clearTimeout(timer); resolve(obj); } });
  });
  return {
    ready: () => next('startup'),
    send: (cmd) => { child.stdin.write(cmd + '\n'); return next(cmd); }
  };
}

export async function run(h) {
  const taskId = 't-success';
  // A fixed logical consumer owner across restarts, so each fresh driver's claim is a renew
  // that ROTATES the epoch - the observable proof a distinct process took over the consumer.
  const owner = { CP_TASK_ID: taskId, CP_OWNER_BOOT: 'boot-wf1', CP_OWNER_PID: '424242' };
  let instance = 0;
  let pane = null;

  // Launch a fresh driver process (a real store+consumer owner) and return its handle + the
  // epoch it re-claimed. Each instance number is distinct so the lease re-claim is a real renew.
  const launchDriver = async () => {
    instance += 1;
    const child = h.spawnDriver(DRIVER, { ...owner, CP_INSTANCE: String(instance) });
    h.recordChild(child.pid, `driver-${instance}`);
    const handle = driverHandle(child);
    const ready = await handle.ready();
    assert.equal(ready.ready, true, `driver instance ${instance} came up and owns the consumer`);
    return { child, handle, epoch: ready.epoch };
  };

  // Driver instance 1 owns the lifecycle up to a verified running binding.
  let d = await launchDriver();
  const epoch1 = d.epoch;
  const spawned = await d.handle.send('spawn');
  assert.equal(spawned.ok, true, 'the driver spawned the run to a verified binding');
  assert.equal(spawned.binding_state, 'bound_verified');
  pane = spawned.pane;
  h.recordAgent({ pid: pane.agentPid, marker: pane.launchMarker, endpointId: pane.endpointId, paneId: pane.paneId });

  // one Bridge card and one Helm live pane (observed by the parent - a read, not lifecycle).
  const snap1 = await h.snapshot();
  assert.equal(projectBridge(snap1).cards.filter((c) => c.task_id === taskId).length, 1, 'exactly one Bridge card for the task');
  assert.deepEqual(projectHelm(snap1).live.map((p) => p.task_id), [taskId], 'exactly one live Helm pane for the task');
  const runningBaseline = await runState(h, taskId);

  // ---- RESTART 1 (mid-lifecycle @ running): kill the OWNING driver, relaunch a fresh one ----
  const dead1 = await h.crashRecordedChild(d.child.pid, d.child);
  assert.equal(dead1.signalCode, 'SIGKILL', 'restart@running: the lifecycle/consumer owner was SIGKILLed');
  d = await launchDriver();
  const epoch2 = d.epoch;
  assert.ok(epoch2 > epoch1, `restart@running: the fresh process re-claimed the consumer lease (epoch ${epoch1} -> ${epoch2})`);
  assert.deepEqual(await runState(h, taskId), runningBaseline, 'restart@running: task/run state is byte-identical after the abrupt owner restart');
  assert.deepEqual(projectHelm(await h.snapshot()).live.map((p) => p.task_id), [taskId], 'restart@running: the live pane survived (its own tmux process)');

  // The FRESH driver performs the remaining running-phase lifecycle: progress, complete, drain.
  assert.equal((await d.handle.send('progress')).ok, true, 'the fresh driver appended progress');
  const completed = await d.handle.send('complete');
  assert.equal(completed.status, 'completed', 'the fresh driver completed the run');
  assert.equal(completed.delivered, true, 'the completion produced an outbox delivery');
  const drained = await d.handle.send('drain');
  assert.equal(drained.idle, true, 'the fresh driver drained the terminal delivery to idle');
  assert.equal(drained.epoch, epoch2, 'the drain used the fresh owner epoch');

  const terminalOutbox = (await h.read("SELECT outbox_id FROM outbox WHERE task_id = $1 AND event_type = 'completed'", [taskId]))[0];
  assert.ok((await h.read('SELECT acked_at FROM outbox WHERE outbox_id = $1', [Number(terminalOutbox.outbox_id)]))[0].acked_at, 'the terminal delivery is acked');
  assert.equal(sinkEffectCount(h.sinkDir), 1, 'exactly one durable sink effect, keyed by event_id');
  const completedBaseline = await runState(h, taskId);
  const cursorBefore = (await readCursor(h.store, {})).last_acked_outbox_id;

  // ---- RESTART 2 (mid-lifecycle @ completed+acked): kill the OWNING driver, relaunch ----
  const dead2 = await h.crashRecordedChild(d.child.pid, d.child);
  assert.equal(dead2.signalCode, 'SIGKILL', 'restart@completed: the lifecycle/consumer owner was SIGKILLed');
  d = await launchDriver();
  const epoch3 = d.epoch;
  assert.ok(epoch3 > epoch2, `restart@completed: the fresh process re-claimed the consumer lease (epoch ${epoch2} -> ${epoch3})`);
  assert.deepEqual(await runState(h, taskId), completedBaseline, 'restart@completed: task/run state is byte-identical after the abrupt owner restart');
  assert.equal((await readCursor(h.store, {})).last_acked_outbox_id, cursorBefore, 'restart@completed: the consumer cursor survived the abrupt death');
  assert.equal(sinkEffectCount(h.sinkDir), 1, 'restart@completed: no duplicate sink effect');

  // The FRESH driver performs the remaining lifecycle: exact-pane cleanup, then archive.
  const cleaned = await d.handle.send('cleanup');
  assert.equal(cleaned.ok, true, 'the fresh driver cleaned up the exact pane');
  assert.equal(cleaned.binding_state, 'closed');
  assert.equal(cleaned.killed, true, 'the cleanup effect killed the exact recorded pane');
  h.markAgentDead(pane.agentPid);
  const archived = await d.handle.send('archive');
  assert.equal(archived.status, 'archived', 'the fresh driver archived the task');

  // The acked terminal is never resurrected across the restarts - still one effect.
  assert.equal(sinkEffectCount(h.sinkDir), 1, 'exactly one durable sink effect across both restarts (no resurrection)');
  await h.snapshot();

  // Cleanly shut down the final driver (EOF on stdin ends its command loop) and reap it, so it
  // is not a lingering fixture process at the finals.
  d.child.stdin.end();
  await new Promise((res) => { if (d.child.exitCode !== null || d.child.signalCode !== null) res(); else d.child.once('exit', res); });

  return { expectedActiveAnomalies: [] };
}

async function runState(h, taskId) {
  const t = (await h.read('SELECT status, revision, current_generation FROM tasks WHERE task_id = $1', [taskId]))[0];
  const r = (await h.read('SELECT run_generation, status, binding_state, cleanup_state, closed_at FROM runs WHERE task_id = $1', [taskId]))[0];
  return { t, r };
}

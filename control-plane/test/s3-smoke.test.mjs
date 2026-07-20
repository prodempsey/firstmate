import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { createTask, beginRun } from '../lib/domain-store.mjs';
import { completeRun } from '../lib/domain-store-s2.mjs';
import { recordSpawn, commitRunning, verifyRunning, cleanupIntent, cleanupFinish } from '../lib/domain-store-s3.mjs';
import { killExactPane, tmuxListPane } from '../lib/tmux-adapter.mjs';
import { mkFixtureHome, cleanupAll } from './helpers.mjs';

// ONE real-adapter smoke test (ruling RISK#2 NARROW / Q7). It drives the REAL tmux +
// /proc probes and the exact-pane cleanup against a genuine marker-bearing pane on an
// ISOLATED `tmux -L <cp-socket>` namespace - no production socket, no production home,
// killing only the exact recorded pane and the dedicated socket. The mutation-sensitive
// domain coverage (s3-contract/s3-adversarial) passes with NO tmux via injected doubles;
// this test SKIPS when tmux is absent, exactly as S0's hosted-Postgres contract does.
after(cleanupAll);

const hasTmux = (() => {
  try {
    return spawnSync('tmux', ['-V'], { encoding: 'utf8' }).status === 0;
  } catch {
    return false;
  }
})();

// A unique isolated socket for this run (Date.now/Math.random are avoided per the repo's
// determinism rules; the pid + a monotonic counter are enough to isolate).
let socketCounter = 0;
function isolatedSocket() {
  socketCounter += 1;
  return `cp-s3-smoke-${process.pid}-${socketCounter}`;
}

function tmux(socket, args) {
  return spawnSync('tmux', ['-L', socket, ...args], { encoding: 'utf8' });
}

// Poll (bounded, synchronous) for a predicate the pane's own side effect satisfies.
function waitFor(predicate, { tries = 100, stepMs = 50 } = {}) {
  for (let i = 0; i < tries; i += 1) {
    if (predicate()) return true;
    // Busy-ish sleep via a blocking child; keeps the test synchronous and simple.
    spawnSync('sleep', [String(stepMs / 1000)]);
  }
  return predicate();
}

test('t_real_tmux_marker_launch_smoke', { skip: hasTmux ? false : 'tmux not available' }, async () => {
  const { fmHome } = mkFixtureHome();
  const socket = isolatedSocket();
  const store = new PgliteLocalStore({ fmHome });
  await store.init({ homeLabel: 'smoke' });
  process.env.CP_TMUX_SOCKET = socket;

  const launchWrapper = fileURLToPath(new URL('../bin/cp-launch.mjs', import.meta.url));
  const regFile = path.join(fmHome, 'gen1.reg');

  try {
    // 1. begin-run precommits the launch intent (marker, nonce, deadline).
    await createTask(store, { taskId: 't1', kind: 'ship', title: 'smoke', origin: 'internal', internalReason: 'r', commandId: 'c-create' });
    const beg = await beginRun(store, { taskId: 't1', expectedRevision: 1, commandId: 'c-begin', registrationPath: regFile });
    assert.equal(typeof beg.launch_marker, 'string');

    // 2. Create ONE marker-bearing window whose initial command is cp-launch, execing so
    // the node wrapper (whose pid the registration records) is the pane leader. The
    // harness is a plain sleep - a stand-in for the real harness, kept alive for probing.
    const env = [
      `CP_LAUNCH_MARKER=${beg.launch_marker}`,
      'CP_TASK_ID=t1',
      'CP_RUN_GENERATION=1',
      `CP_BIND_NONCE=${beg.bind_nonce}`,
      `CP_REG_FILE=${regFile}`,
      "CP_HARNESS_CMD='[\"sleep\",\"300\"]'"
    ].join(' ');
    const winName = `cp-${beg.launch_marker.slice(0, 8)}`;
    // new-session both starts the isolated server and creates the first (marker-bearing)
    // window; new-window would fail on an empty socket with no running server.
    const created = tmux(socket, ['new-session', '-d', '-P', '-F', '#{window_id} #{pane_id}', '-s', 'cp', '-n', winName, `${env} exec node ${launchWrapper}`]);
    assert.equal(created.status, 0, `tmux new-session failed: ${created.stderr}`);
    const [endpointId, paneId] = created.stdout.trim().split(/\s+/);

    // 3. The wrapper's first action is the registration write; wait for it, then confirm
    // tmux really lists the marker-bound endpoint/pane (the self-identifying instant).
    assert.equal(waitFor(() => fs.existsSync(regFile)), true, 'cp-launch wrote the registration record');
    assert.equal(waitFor(() => tmuxListPane(socket, endpointId, paneId).listed), true, 'tmux lists the marker-bearing pane');

    // 4. record-spawn through the REAL captureIdentity (HMAC + /proc + tmux).
    const rs = await recordSpawn(store, {
      taskId: 't1', generation: 1, expectedRevision: beg.revision, launchMarker: beg.launch_marker,
      endpoint: endpointId, pane: paneId, regFile, commandId: 'c-spawn'
    });
    assert.equal(rs.endpoint_id, endpointId, 'the real capture recorded the live endpoint');

    // 5. commit-running through the REAL probe verifies the live identity and promotes.
    const cr = await commitRunning(store, { taskId: 't1', generation: 1, expectedRevision: rs.revision, commandId: 'c-run' });
    assert.equal(cr.status, 'running');
    const vr = await verifyRunning(store, { taskId: 't1', generation: 1 });
    assert.equal(vr.running_verified, true, 'the real predicate confirms the running binding');

    // 6. Terminal, then the exact-pane cleanup saga against the real socket.
    const done = await completeRun(store, { taskId: 't1', generation: 1, expectedRevision: cr.revision, outcome: 'success', producer: 'crewmate', seq: 1, evidence: {}, commandId: 'c-done' });
    const intent = await cleanupIntent(store, { taskId: 't1', generation: 1, expectedRevision: done.revision, commandId: 'c-intent' });
    const effect = killExactPane({ socket, endpointId: intent.target.endpoint_id, paneId: intent.target.pane_id, run: { boot_id: intent.target.boot_id, endpoint_id: intent.target.endpoint_id, pane_id: intent.target.pane_id, pane_leader_pid: intent.target.pane_leader_pid } });
    assert.equal(effect.killed, true, 'the cleanup effect killed the exact recorded pane');
    assert.equal(waitFor(() => !tmuxListPane(socket, endpointId, paneId).listed), true, 'the exact pane is gone after cleanup');

    const fin = await cleanupFinish(store, { taskId: 't1', generation: 1, expectedRevision: intent.revision, effectResult: effect, commandId: 'c-finish' });
    assert.equal(fin.binding_state, 'closed', 'the binding closed after the real cleanup');
  } finally {
    // Tear down ONLY the dedicated isolated socket - never a shared server - and unlink
    // its stale socket inode so no orphan fixture artifact is left behind.
    tmux(socket, ['kill-server']);
    try {
      const sockDir = process.env.TMUX_TMPDIR || `/tmp/tmux-${process.getuid()}`;
      fs.unlinkSync(path.join(sockDir, socket));
    } catch {
      // best effort: kill-server usually removes it already
    }
    delete process.env.CP_TMUX_SOCKET;
    await store.close();
  }
});

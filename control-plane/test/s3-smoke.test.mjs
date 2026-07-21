import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { runExclusive } from '../lib/internal-runtime.mjs';
import { createTask, beginRun } from '../lib/domain-store.mjs';
import { completeRun } from '../lib/domain-store-s2.mjs';
import { recordSpawn, commitRunning, verifyRunning, cleanupIntent, cleanupFinish } from '../lib/domain-store-s3.mjs';
import {
  killExactPane, cleanupTargetMatches, tmuxListPane, probeIdentity, captureIdentity, registrationHmac
} from '../lib/tmux-adapter.mjs';
import { mkFixtureHome, cleanupAll } from './helpers.mjs';

// Real-adapter smoke + regression against a genuine marker-bearing pane on an ISOLATED
// `tmux -L <cp-socket>` namespace - no production socket, no production home, killing
// only the exact recorded pane and the dedicated socket. The mutation-sensitive domain
// coverage (s3-contract/s3-adversarial) passes with NO tmux via injected doubles; these
// tests SKIP when tmux is absent, exactly as S0's hosted-Postgres contract does.
//
// These tests exercise the PRODUCTION probes end to end so a weakened predicate is
// caught here: the false-positive-identity regression (finding 1) corrupts each stored
// clause and requires the real probe to fail; the agent-identity regression (finding 2)
// proves the recorded agent is the harness, not the wrapper; the mismatched-cleanup
// regression (finding 3) proves a materially wrong target is never killed.
after(cleanupAll);

const hasTmux = (() => {
  try {
    return spawnSync('tmux', ['-V'], { encoding: 'utf8' }).status === 0;
  } catch {
    return false;
  }
})();

let socketCounter = 0;
function isolatedSocket() {
  socketCounter += 1;
  return `cp-s3-smoke-${process.pid}-${socketCounter}`;
}

function tmux(socket, args) {
  return spawnSync('tmux', ['-L', socket, ...args], { encoding: 'utf8' });
}

function killSocket(socket) {
  tmux(socket, ['kill-server']);
  try {
    const sockDir = process.env.TMUX_TMPDIR || `/tmp/tmux-${process.getuid()}`;
    fs.unlinkSync(path.join(sockDir, socket));
  } catch {
    // best effort: kill-server usually removes it already
  }
}

function waitFor(predicate, { tries = 200, stepMs = 25 } = {}) {
  for (let i = 0; i < tries; i += 1) {
    if (predicate()) return true;
    spawnSync('sleep', [String(stepMs / 1000)]);
  }
  return predicate();
}

async function runRow(store, taskId, generation = 1) {
  return runExclusive(store, async (conn) => (await conn.query(
    `SELECT status, binding_state, cleanup_state, closed_at, endpoint_id, pane_id, pane_leader_pid, pane_start_ticks,
            boot_id, agent_pid, agent_start_ticks, agent_exe, agent_argv_hash, agent_ppid, agent_pty,
            bind_nonce, launch_marker, registration_path, run_generation
       FROM runs WHERE task_id = $1 AND run_generation = $2`, [taskId, generation]
  )).rows[0]);
}

const launchWrapper = fileURLToPath(new URL('../bin/cp-launch.mjs', import.meta.url));

// Launch a real marker-bearing pane running cp-launch with a `sleep` harness on the
// isolated socket, wait for its registration, and drive the domain lifecycle through
// record-spawn (real capture) and commit-running (real probe) to a running binding.
// Returns the live handles the tests need.
async function launchToRunning(store, socket, fmHome, taskId = 't1') {
  await createTask(store, { taskId, kind: 'ship', title: 'smoke', origin: 'internal', internalReason: 'r', commandId: `c-create-${taskId}` });
  const regFile = path.join(fmHome, `${taskId}.reg`);
  const beg = await beginRun(store, { taskId, expectedRevision: 1, commandId: `c-begin-${taskId}`, registrationPath: regFile });

  const env = [
    `CP_LAUNCH_MARKER=${beg.launch_marker}`,
    `CP_TASK_ID=${taskId}`,
    'CP_RUN_GENERATION=1',
    `CP_BIND_NONCE=${beg.bind_nonce}`,
    `CP_REG_FILE=${regFile}`,
    "CP_HARNESS_CMD='[\"sleep\",\"300\"]'"
  ].join(' ');
  const winName = `cp-${beg.launch_marker.slice(0, 8)}`;
  // new-session both starts the isolated server and creates the first (marker-bearing)
  // window; execing node makes the wrapper the pane leader.
  const created = tmux(socket, ['new-session', '-d', '-P', '-F', '#{window_id} #{pane_id}', '-s', `cp-${taskId}`, '-n', winName, `${env} exec node ${launchWrapper}`]);
  assert.equal(created.status, 0, `tmux new-session failed: ${created.stderr}`);
  const [endpointId, paneId] = created.stdout.trim().split(/\s+/);

  assert.equal(waitFor(() => fs.existsSync(regFile)), true, 'cp-launch wrote the registration record');
  assert.equal(waitFor(() => tmuxListPane(socket, endpointId, paneId).listed), true, 'tmux lists the marker-bearing pane');

  const rs = await recordSpawn(store, {
    taskId, generation: 1, expectedRevision: beg.revision, launchMarker: beg.launch_marker,
    endpoint: endpointId, pane: paneId, regFile, commandId: `c-spawn-${taskId}`
  });
  const cr = await commitRunning(store, { taskId, generation: 1, expectedRevision: rs.revision, commandId: `c-run-${taskId}` });
  return { endpointId, paneId, regFile, launchMarker: beg.launch_marker, bindNonce: beg.bind_nonce, revision: cr.revision };
}

test('t_real_tmux_marker_launch_smoke', { skip: hasTmux ? false : 'tmux not available' }, async () => {
  const { fmHome } = mkFixtureHome();
  const socket = isolatedSocket();
  const store = new PgliteLocalStore({ fmHome });
  await store.init({ homeLabel: 'smoke' });
  process.env.CP_TMUX_SOCKET = socket;
  try {
    const h = await launchToRunning(store, socket, fmHome, 't1');

    // The real predicate confirms the running binding.
    const vr = await verifyRunning(store, { taskId: 't1', generation: 1 });
    assert.equal(vr.running_verified, true, 'the real predicate confirms the running binding');

    // FINDING 2: the RECORDED agent identity is the HARNESS, not the wrapper. The reg
    // record and the stored run both name a distinct agent pid whose exe is the harness,
    // and the pane leader is the (different) wrapper node process.
    const reg = JSON.parse(fs.readFileSync(h.regFile, 'utf8'));
    const run = await runRow(store, 't1');
    const paneLeaderPid = tmuxListPane(socket, h.endpointId, h.paneId).paneLeaderPid;
    const nodeReal = fs.realpathSync(process.execPath);
    assert.notEqual(reg.agentPid, paneLeaderPid, 'the recorded agent is NOT the pane-leader wrapper');
    assert.notEqual(reg.agentExe, nodeReal, 'the recorded agent exe is the harness, not the node wrapper');
    assert.equal(Number(run.agent_pid), reg.agentPid, 'record-spawn stored the harness agent pid');
    assert.equal(run.agent_exe, reg.agentExe, 'record-spawn stored the harness agent exe');
    assert.equal(Number(run.pane_leader_pid), paneLeaderPid, 'the pane leader is the wrapper process');
    assert.equal(Number(run.agent_ppid), paneLeaderPid, 'the agent parent chain is the pane-leader wrapper');

    // Terminal, then the exact-pane cleanup saga against the real socket.
    const done = await completeRun(store, { taskId: 't1', generation: 1, expectedRevision: h.revision, outcome: 'success', producer: 'crewmate', seq: 1, evidence: {}, commandId: 'c-done' });
    const intent = await cleanupIntent(store, { taskId: 't1', generation: 1, expectedRevision: done.revision, commandId: 'c-intent' });
    const effect = killExactPane({ socket, endpointId: intent.target.endpoint_id, paneId: intent.target.pane_id, run: intent.target });
    assert.equal(effect.killed, true, 'the cleanup effect killed the exact recorded pane');
    assert.equal(effect.confirmed_absent, true, 'the cleanup effect confirmed the pane is gone');
    assert.equal(waitFor(() => !tmuxListPane(socket, h.endpointId, h.paneId).listed), true, 'the exact pane is gone after cleanup');

    const fin = await cleanupFinish(store, { taskId: 't1', generation: 1, expectedRevision: intent.revision, effectResult: effect, commandId: 'c-finish' });
    assert.equal(fin.binding_state, 'closed', 'the binding closed after the real cleanup');
  } finally {
    killSocket(socket);
    delete process.env.CP_TMUX_SOCKET;
    await store.close();
  }
});

test('t_real_tmux_identity_predicate_fails_closed', { skip: hasTmux ? false : 'tmux not available' }, async () => {
  const { fmHome } = mkFixtureHome();
  const socket = isolatedSocket();
  const store = new PgliteLocalStore({ fmHome });
  await store.init({ homeLabel: 'smoke' });
  process.env.CP_TMUX_SOCKET = socket;
  try {
    await launchToRunning(store, socket, fmHome, 't1');
    const run = await runRow(store, 't1');
    // Normalize the run object the way commit/verify pass it to the probe.
    const base = { ...run, task_id: 't1', run_generation: 1 };

    // FINDING 1: with the TRUE stored identity, the real predicate matches.
    assert.equal(probeIdentity({ run: base, socket }).matches, true, 'the real predicate matches the true live identity');

    // ...and corrupting ANY single required clause makes it fail closed. Each row is a
    // wrong value for exactly one stored field plus the failing clause the real predicate
    // must report. A regression that drops any clause fails here.
    const corruptions = [
      ['boot_id', 'not-the-real-boot-id', 'boot_id'],
      ['pane_leader_pid', 999999, 'pane_leader_pid'],
      ['pane_start_ticks', 999999999, 'pane_start_ticks'],
      ['agent_pid', 999999, 'agent_pid'],
      ['agent_start_ticks', 999999999, 'agent_start_ticks'],
      ['agent_exe', '/definitely/wrong', 'agent_exe'],
      ['agent_argv_hash', 'wrong-hash', 'agent_argv_hash'],
      ['agent_ppid', 999999, 'agent_ppid'],
      ['agent_pty', '/definitely/wrong', 'agent_pty']
    ];
    for (const [field, wrong, clause] of corruptions) {
      const probed = probeIdentity({ run: { ...base, [field]: wrong }, socket });
      assert.equal(probed.matches, false, `a wrong ${field} must NOT match`);
      assert.equal(probed.failingClause, clause, `the failing clause for a wrong ${field} is ${clause}`);
    }
    // A NULL stored clause is a weak binding and also fails closed (never a skipped clause).
    for (const field of ['pane_start_ticks', 'agent_ppid', 'agent_pty']) {
      const probed = probeIdentity({ run: { ...base, [field]: null }, socket });
      assert.equal(probed.matches, false, `a null stored ${field} must fail closed`);
      assert.match(probed.failingClause, /incomplete_binding/, 'a missing clause is an incomplete binding, not a skip');
    }

    // FINDING 1 (record time): a registration with a VALID HMAC over deliberately wrong
    // immutable values must be rejected by capture - the signed identity must equal the
    // live process, closing the PID-reuse / stale-registration gap.
    const badReg = path.join(fmHome, 'stale.reg');
    const signed = {
      marker: run.launch_marker, taskId: 't1', generation: 1,
      agentPid: Number(run.agent_pid), agentStartTicks: 999999999, agentExe: '/definitely/wrong',
      agentArgvHash: 'wrong-hash', agentPpid: 999999, agentPty: '/definitely/wrong'
    };
    fs.writeFileSync(badReg, JSON.stringify({ ...signed, bootId: run.boot_id, hmac: registrationHmac(run.bind_nonce, signed) }));
    const cap = captureIdentity({
      run: { bind_nonce: run.bind_nonce, launch_marker: run.launch_marker, task_id: 't1', run_generation: 1 },
      params: { endpoint: run.endpoint_id, pane: run.pane_id, regFile: badReg, taskId: 't1', generation: 1 },
      socket
    });
    assert.equal(cap.ok, false, 'capture rejects a validly-signed-but-not-live registration');
    assert.equal(cap.reason, 'signed_identity_not_live', 'the signed identity did not equal the live process');
  } finally {
    killSocket(socket);
    delete process.env.CP_TMUX_SOCKET;
    await store.close();
  }
});

test('t_real_tmux_cleanup_refuses_mismatched_target', { skip: hasTmux ? false : 'tmux not available' }, async () => {
  const { fmHome } = mkFixtureHome();
  const socket = isolatedSocket();
  const store = new PgliteLocalStore({ fmHome });
  await store.init({ homeLabel: 'smoke' });
  process.env.CP_TMUX_SOCKET = socket;
  try {
    const h = await launchToRunning(store, socket, fmHome, 't1');
    const run = await runRow(store, 't1');

    // FINDING 3: the real cleanup predicate matches the TRUE target (pane present).
    assert.equal(cleanupTargetMatches({ run, socket }).matches, true, 'the true target is an exact match');

    // ...but a target with the correct coarse ids (endpoint/pane/leader present) yet a
    // materially wrong identity is REFUSED, and killExactPane does NOT kill it: this is
    // the kill-wrong-pane hazard the exact-cleanup guarantee exists to prevent.
    const mismatches = [
      ['pane_start_ticks', 999999999, 'pane_start_mismatch'],
      ['agent_start_ticks', 999999999, 'agent_mismatch'],
      ['agent_exe', '/definitely/wrong', 'agent_mismatch'],
      ['agent_pty', '/definitely/wrong', 'agent_mismatch']
    ];
    for (const [field, wrong, reason] of mismatches) {
      const target = { ...run, [field]: wrong };
      const m = cleanupTargetMatches({ run: target, socket });
      assert.equal(m.present, true, `the pane is present for a wrong ${field}`);
      assert.equal(m.matches, false, `a wrong ${field} is NOT an exact cleanup match`);
      assert.equal(m.reason, reason, `the mismatch reason for a wrong ${field} is ${reason}`);

      const effect = killExactPane({ socket, endpointId: run.endpoint_id, paneId: run.pane_id, run: target });
      assert.equal(effect.killed, false, `killExactPane refuses to kill on a wrong ${field}`);
      assert.equal(effect.confirmed_absent, false, 'a refused kill never claims the endpoint is absent');
      assert.equal(tmuxListPane(socket, h.endpointId, h.paneId).listed, true, `the real pane is untouched after a refused kill on a wrong ${field}`);
    }
  } finally {
    killSocket(socket);
    delete process.env.CP_TMUX_SOCKET;
    await store.close();
  }
});

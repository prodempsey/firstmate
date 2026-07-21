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
import {
  recordSpawn, commitRunning, verifyRunning, cleanupIntent, cleanupFinish, recordCleanupMismatch
} from '../lib/domain-store-s3.mjs';
import {
  killExactPane, cleanupTargetMatches, tmuxListPane, probeIdentity, captureIdentity, registrationHmac, readProcIdentity
} from '../lib/tmux-adapter.mjs';
import { IdentityMismatchError } from '../lib/errors-s3.mjs';
import { mkFixtureHome, cleanupAll } from './helpers.mjs';

// Real-adapter smoke + regression against a genuine marker-bearing pane on an ISOLATED
// `tmux -L <cp-socket>` namespace - no production socket, no production home, killing
// only the exact recorded pane and the dedicated socket. The mutation-sensitive domain
// coverage (s3-contract/s3-adversarial) passes with NO tmux via injected doubles; these
// tests SKIP when tmux is absent, exactly as S0's hosted-Postgres contract does.
//
// These tests exercise the PRODUCTION launcher and probes end to end so a weakened
// contract is caught here: the register-first/PID-preserving launch regression
// (finding 2) proves the registered PID IS the live harness process (no separate child);
// the false-positive-identity regression (finding 1) corrupts each stored clause and
// requires the real probe to fail; the mismatched-cleanup regression (finding 3) proves
// a materially wrong target is never killed AND that the mismatch persists an anomaly.
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

async function rows(store, sql, params) {
  return runExclusive(store, async (conn) => (await conn.query(sql, params)).rows);
}

async function runRow(store, taskId, generation = 1) {
  return runExclusive(store, async (conn) => (await conn.query(
    `SELECT status, binding_state, cleanup_state, closed_at, endpoint_id, pane_id, pane_leader_pid, pane_start_ticks,
            boot_id, agent_pid, agent_start_ticks, agent_exe, agent_argv_hash, agent_ppid, agent_pty,
            bind_nonce, launch_marker, registration_path, run_generation
       FROM runs WHERE task_id = $1 AND run_generation = $2`, [taskId, generation]
  )).rows[0]);
}

const cpLaunchSh = fileURLToPath(new URL('../bin/cp-launch.sh', import.meta.url));

// The live /proc cmdline of a pid as a plain string (NUL-delimited args joined by space).
function readCmdlineStr(pid) {
  try {
    return fs.readFileSync(`/proc/${pid}/cmdline`).toString('latin1').replace(/\0/g, ' ').trim();
  } catch {
    return null;
  }
}

// Launch a real marker-bearing pane whose initial command is `exec sh cp-launch.sh
// <harness...>`, so cp-launch.sh writes the registration and then EXECs the harness in
// place - the pane's single PID-preserved process becomes the harness. Wait for
// registration and for the exec to actually complete (the registered PID's argv is no
// longer cp-launch's - reliable across native binaries AND shebang interpreters), then
// drive the domain lifecycle through record-spawn (real capture) and commit-running (real
// probe) to a running binding. Returns the live handles.
async function launchToRunning(store, socket, fmHome, taskId = 't1', harnessArgv = ['sleep', '300']) {
  await createTask(store, { taskId, kind: 'ship', title: 'smoke', origin: 'internal', internalReason: 'r', commandId: `c-create-${taskId}` });
  const regFile = path.join(fmHome, `${taskId}.reg`);
  const beg = await beginRun(store, { taskId, expectedRevision: 1, commandId: `c-begin-${taskId}`, registrationPath: regFile });

  const env = [
    `CP_LAUNCH_MARKER=${beg.launch_marker}`,
    `CP_TASK_ID=${taskId}`,
    'CP_RUN_GENERATION=1',
    `CP_BIND_NONCE=${beg.bind_nonce}`,
    `CP_REG_FILE=${regFile}`
  ].join(' ');
  const winName = `cp-${beg.launch_marker.slice(0, 8)}`;
  // new-session both starts the isolated server and creates the first (marker-bearing)
  // window; `exec sh cp-launch.sh` makes the launcher the pane process, and its own
  // `exec "$@"` then replaces it in place with the harness (PID preserved).
  const paneCmd = `${env} exec sh ${cpLaunchSh} ${harnessArgv.join(' ')}`;
  const created = tmux(socket, ['new-session', '-d', '-P', '-F', '#{window_id} #{pane_id}', '-s', `cp-${taskId}`, '-n', winName, paneCmd]);
  assert.equal(created.status, 0, `tmux new-session failed: ${created.stderr}`);
  const [endpointId, paneId] = created.stdout.trim().split(/\s+/);

  assert.equal(waitFor(() => fs.existsSync(regFile)), true, 'cp-launch wrote the registration record');
  const reg = JSON.parse(fs.readFileSync(regFile, 'utf8'));
  // Wait for the exec to COMPLETE: the registered PID's live argv must no longer be the
  // cp-launch wrapper's. This is reliable even when exec does not change the executable
  // realpath (a `#!/bin/sh` harness stays /usr/bin/dash), because exec always rewrites argv.
  assert.equal(
    waitFor(() => {
      const cl = readCmdlineStr(reg.agentPid);
      return cl !== null && !cl.includes('cp-launch');
    }),
    true, 'the registered PID exec\'d into the harness (argv no longer the wrapper\'s)'
  );
  assert.equal(waitFor(() => tmuxListPane(socket, endpointId, paneId).listed), true, 'tmux lists the marker-bearing pane');

  const rs = await recordSpawn(store, {
    taskId, generation: 1, expectedRevision: beg.revision, launchMarker: beg.launch_marker,
    endpoint: endpointId, pane: paneId, regFile, commandId: `c-spawn-${taskId}`
  });
  const cr = await commitRunning(store, { taskId, generation: 1, expectedRevision: rs.revision, commandId: `c-run-${taskId}` });
  return { endpointId, paneId, regFile, reg, revision: cr.revision };
}

test('t_real_tmux_marker_launch_smoke', { skip: hasTmux ? false : 'tmux not available' }, async () => {
  const { fmHome } = mkFixtureHome();
  const socket = isolatedSocket();
  const store = new PgliteLocalStore({ fmHome });
  await store.init({ homeLabel: 'smoke' });
  process.env.CP_TMUX_SOCKET = socket;
  try {
    const h = await launchToRunning(store, socket, fmHome, 't1');

    const vr = await verifyRunning(store, { taskId: 't1', generation: 1 });
    assert.equal(vr.running_verified, true, 'the real predicate confirms the running binding');

    // FINDING 2: register-first, THEN exec with the PID PRESERVED. The registered agent
    // PID equals the LIVE pane process, and record-spawn stored the OBSERVED live /proc
    // executable/argv as the authoritative identity (not a pre-exec prediction). The agent
    // IS the pane leader - a single PID-preserved process, no lingering wrapper.
    const run = await runRow(store, 't1');
    const paneLeaderPid = tmuxListPane(socket, h.endpointId, h.paneId).paneLeaderPid;
    const live = readProcIdentity(h.reg.agentPid);
    const nodeReal = fs.realpathSync(process.execPath);
    assert.equal(h.reg.agentPid, paneLeaderPid, 'the registered PID IS the live pane process (PID preserved by exec)');
    assert.equal(run.agent_exe, live.exe, 'record-spawn stored the OBSERVED live executable, not a prediction');
    assert.equal(run.agent_argv_hash, live.argvHash, 'record-spawn stored the OBSERVED live argv hash');
    assert.notEqual(run.agent_exe, nodeReal, 'the recorded agent is the harness, not the node registration helper');
    assert.equal(Number(run.agent_pid), h.reg.agentPid, 'record-spawn stored the PID-preserved agent');
    assert.equal(Number(run.pane_leader_pid), paneLeaderPid, 'the pane leader is that same PID-preserved process');
    assert.equal(Number(run.agent_pid), Number(run.pane_leader_pid), 'the agent and the pane leader are one PID-preserved process');

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

test('t_real_tmux_shebang_harness_registers', { skip: hasTmux ? false : 'tmux not available' }, async () => {
  // A DIRECTLY-INVOKED shebang script harness (the shape `codex` has: #!/usr/bin/env
  // node). The kernel execs the INTERPRETER and rewrites argv, so a pre-exec prediction
  // of the harness executable/argv would be wrong and would make record-spawn reject a
  // conforming launch (qa-s3r3-q61 finding 1). Because S3 now OBSERVES the live post-exec
  // identity instead of predicting it, this legitimate agent registers, commits running,
  // and verifies - and the stored identity is the real interpreter, robust to the chain.
  const { fmHome } = mkFixtureHome();
  const socket = isolatedSocket();
  const store = new PgliteLocalStore({ fmHome });
  await store.init({ homeLabel: 'smoke' });
  process.env.CP_TMUX_SOCKET = socket;

  // An executable `#!/bin/sh` harness: when exec'd directly the kernel runs /usr/bin/dash,
  // so /proc/<pid>/exe is the INTERPRETER, NOT this script path. It runs `sleep` as a
  // child (no `exec`), so the interpreter stays the live pane process to be probed.
  const harnessPath = path.join(fmHome, 'shebang-harness.sh');
  fs.writeFileSync(harnessPath, '#!/bin/sh\nsleep 300\n', { mode: 0o755 });

  try {
    const h = await launchToRunning(store, socket, fmHome, 't1', [harnessPath]);

    // The launch registered and committed running - the whole point: a real live shebang
    // agent is no longer rejected.
    const vr = await verifyRunning(store, { taskId: 't1', generation: 1 });
    assert.equal(vr.running_verified, true, 'a shebang-harness launch verifies running');

    // The STORED identity is the OBSERVED live /proc identity of the exec'd process - the
    // interpreter, never the script path a prediction would have signed.
    const run = await runRow(store, 't1');
    const live = readProcIdentity(h.reg.agentPid);
    assert.equal(h.reg.agentPid, tmuxListPane(socket, h.endpointId, h.paneId).paneLeaderPid, 'PID preserved through the shebang exec');
    assert.equal(run.agent_exe, live.exe, 'the stored agent exe is the OBSERVED interpreter');
    assert.notEqual(run.agent_exe, harnessPath, 'the stored agent exe is the interpreter, not the (mispredicted) script path');
    assert.equal(run.agent_argv_hash, live.argvHash, 'the stored argv hash is the OBSERVED kernel-rewritten argv');

    // And the registration itself never contained an executable/argv prediction to be
    // wrong about: it signs only the exec-preserved facts.
    assert.equal(h.reg.agentExe, undefined, 'registration does not predict the executable');
    assert.equal(h.reg.agentArgvHash, undefined, 'registration does not predict the argv hash');
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
    const base = { ...run, task_id: 't1', run_generation: 1 };

    // FINDING 1: with the TRUE stored identity, the real predicate matches.
    assert.equal(probeIdentity({ run: base, socket }).matches, true, 'the real predicate matches the true live identity');

    // ...and corrupting ANY single required clause makes it fail closed.
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
    // A NULL stored clause is a weak binding and also fails closed.
    for (const field of ['pane_start_ticks', 'agent_ppid', 'agent_pty']) {
      const probed = probeIdentity({ run: { ...base, [field]: null }, socket });
      assert.equal(probed.matches, false, `a null stored ${field} must fail closed`);
      assert.match(probed.failingClause, /incomplete_binding/, 'a missing clause is an incomplete binding, not a skip');
    }

    // FINDING 1 (record time): a registration with a VALID HMAC over deliberately wrong
    // exec-preserved values (start ticks / parent / PTY) must be rejected by capture -
    // the signed identity must equal the live process, closing the stale/PID-reuse gap.
    const badReg = path.join(fmHome, 'stale.reg');
    const signed = {
      marker: run.launch_marker, taskId: 't1', generation: 1,
      agentPid: Number(run.agent_pid), agentStartTicks: 999999999,
      agentPpid: 999999, agentPty: '/definitely/wrong'
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

test('t_real_tmux_cleanup_refuses_and_records_mismatch', { skip: hasTmux ? false : 'tmux not available' }, async () => {
  const { fmHome } = mkFixtureHome();
  const socket = isolatedSocket();
  const store = new PgliteLocalStore({ fmHome });
  await store.init({ homeLabel: 'smoke' });
  process.env.CP_TMUX_SOCKET = socket;
  try {
    const h = await launchToRunning(store, socket, fmHome, 't1');
    const run = await runRow(store, 't1');

    // FINDING 3: the real cleanup predicate matches the TRUE target...
    assert.equal(cleanupTargetMatches({ run, socket }).matches, true, 'the true target is an exact match');

    // ...but a target with correct coarse ids yet a materially wrong identity is REFUSED,
    // and killExactPane does NOT kill it (the kill-wrong-pane hazard).
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
      assert.equal(tmuxListPane(socket, h.endpointId, h.paneId).listed, true, `the real pane is untouched after a refused kill on a wrong ${field}`);
    }

    // FINDING 3 (anomaly half): drive to terminal + intent, corrupt the STORED pane start
    // ticks so the REAL cleanup probe sees a live mismatch, and record it. The mismatch
    // must persist a durable identity_mismatch anomaly (visible to the S5 reconciler)
    // while the real pane survives.
    const done = await completeRun(store, { taskId: 't1', generation: 1, expectedRevision: h.revision, outcome: 'success', producer: 'crewmate', seq: 1, evidence: {}, commandId: 'c-done' });
    const intent = await cleanupIntent(store, { taskId: 't1', generation: 1, expectedRevision: done.revision, commandId: 'c-intent' });
    await runExclusive(store, (conn) => conn.query(
      "UPDATE runs SET pane_start_ticks = 999999999 WHERE task_id = 't1' AND run_generation = 1"
    ));
    await assert.rejects(
      () => recordCleanupMismatch(store, { taskId: 't1', generation: 1, expectedRevision: intent.revision, commandId: 'c-mismatch' }),
      (e) => e instanceof IdentityMismatchError,
      'the real cleanup mismatch surfaces as IdentityMismatchError'
    );
    const anom = await rows(store, "SELECT task_id, run_generation, status FROM anomalies WHERE anomaly_class = 'identity_mismatch'");
    assert.equal(anom.length, 1, 'the cleanup mismatch persisted exactly one identity_mismatch anomaly');
    assert.equal(anom[0].task_id, 't1');
    assert.equal(tmuxListPane(socket, h.endpointId, h.paneId).listed, true, 'the real pane survived the recorded mismatch (no kill)');
  } finally {
    killSocket(socket);
    delete process.env.CP_TMUX_SOCKET;
    await store.close();
  }
});

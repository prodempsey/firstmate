import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { tmuxListPane, killExactPane } from '../../lib/tmux-adapter.mjs';
import { scanIsolatedSocket } from '../../lib/backend-scan-s5.mjs';
import { readCmdlineStr, waitFor, isAlive } from './proc.mjs';

// Real marker-bearing agent panes on the run's DEDICATED tmux socket (spec section 11 /
// matrix wf1-4,7). This is the production launch path: `exec sh cp-launch.sh <harness>`
// registers the HMAC-signed identity and then execs the harness in place, so the pane's
// single PID-preserved process IS the agent - exactly what the S3 smoke proves. The
// fixture's only job is to stand up that live process and hand back its exact recorded PID
// so the runner can (a) drive the real record-spawn/commit-running probes against it and
// (b) tear it down by exact PID, never a pattern.

const CP_LAUNCH_SH = fileURLToPath(new URL('../../bin/cp-launch.sh', import.meta.url));

export function hasTmux() {
  try {
    return spawnSync('tmux', ['-V'], { encoding: 'utf8' }).status === 0;
  } catch {
    return false;
  }
}

// Every tmux call is scoped to the dedicated `-L <socket>` namespace; TMUX_TMPDIR is set
// by the runner to a dir inside the fixture root, so even the socket FILE is contained.
export function tmux(socket, args, env = process.env) {
  return spawnSync('tmux', ['-L', socket, ...args], { encoding: 'utf8', env });
}

// Launch a live marker-bearing agent pane. Waits for the registration write AND for the
// exec to actually complete (the registered PID's argv is no longer the wrapper's), then
// for tmux to list the pane. Returns the handles plus the exact agent PID to record.
export function launchAgentPane({ socket, fmHome, taskId, launchMarker, bindNonce, harnessArgv = ['sleep', '600'] }) {
  const regFile = path.join(fmHome, `${taskId}.reg`);
  const env = [
    `CP_LAUNCH_MARKER=${launchMarker}`,
    `CP_TASK_ID=${taskId}`,
    'CP_RUN_GENERATION=1',
    `CP_BIND_NONCE=${bindNonce}`,
    `CP_REG_FILE=${regFile}`
  ].join(' ');
  const winName = `cp-${launchMarker.slice(0, 8)}`;
  const paneCmd = `${env} exec sh ${CP_LAUNCH_SH} ${harnessArgv.join(' ')}`;
  const created = tmux(socket, ['new-session', '-d', '-P', '-F', '#{window_id} #{pane_id}', '-s', `cp-${taskId}`, '-n', winName, paneCmd]);
  if (created.status !== 0) throw new Error(`tmux new-session failed: ${created.stderr}`);
  const [endpointId, paneId] = created.stdout.trim().split(/\s+/);

  if (!waitFor(() => fs.existsSync(regFile))) throw new Error('cp-launch never wrote the registration record');
  const reg = JSON.parse(fs.readFileSync(regFile, 'utf8'));
  if (!waitFor(() => { const cl = readCmdlineStr(reg.agentPid); return cl !== null && !cl.includes('cp-launch'); })) {
    throw new Error('the registered PID never exec\'d into the harness');
  }
  if (!waitFor(() => tmuxListPane(socket, endpointId, paneId).listed)) throw new Error('tmux never listed the marker-bearing pane');

  return { endpointId, paneId, regFile, reg, agentPid: reg.agentPid, sessionName: `cp-${taskId}` };
}

// A DECOY marker-bearing pane the fixture deliberately does NOT record in the runner's PID
// registry. It exists to prove teardown kills ONLY recorded PIDs (the decoy survives) and
// that the "zero unrecorded marker-bearing panes" final assertion flags it. Its marker is
// a syntactically valid launch marker for a run that does not exist in this store.
export function launchDecoyPane({ socket, marker = 'e2e-decoy-marker-0000', harnessArgv = ['sleep', '600'] }) {
  const paneCmd = `CP_LAUNCH_MARKER=${marker} exec ${harnessArgv.join(' ')}`;
  const created = tmux(socket, ['new-session', '-d', '-P', '-F', '#{window_id} #{pane_id} #{pane_pid}', '-s', 'cp-decoy', '-n', 'decoy', paneCmd]);
  if (created.status !== 0) throw new Error(`decoy new-session failed: ${created.stderr}`);
  const [endpointId, paneId, panePid] = created.stdout.trim().split(/\s+/);
  const pid = Number(panePid);
  if (!waitFor(() => isAlive(pid))) throw new Error('decoy pane process never came alive');
  return { endpointId, paneId, pid, marker };
}

// A truly MARKERLESS pane (no CP_LAUNCH_MARKER in its environ) - the shell-only orphan the
// reconciler's marker scan reports as an `orphan_pane` with reason 'markerless' (spec: this
// slice never kills it; it stays in the orphan inspector for later human disposition). Its
// PID is returned so the fixture can record it and teardown can reclaim it by exact PID.
export function launchMarkerlessPane({ socket, harnessArgv = ['sleep', '600'] }) {
  const paneCmd = `exec ${harnessArgv.join(' ')}`;
  const created = tmux(socket, ['new-session', '-d', '-P', '-F', '#{window_id} #{pane_id} #{pane_pid}', '-s', 'cp-shell', '-n', 'shell', paneCmd]);
  if (created.status !== 0) throw new Error(`markerless new-session failed: ${created.stderr}`);
  const [endpointId, paneId, panePid] = created.stdout.trim().split(/\s+/);
  const pid = Number(panePid);
  if (!waitFor(() => isAlive(pid))) throw new Error('markerless pane process never came alive');
  return { endpointId, paneId, pid };
}

// Kill the exact recorded pane through the production exact-identity cleanup effect, using
// the stored run identity as the match target. Returns the effect result.
export function killAgentExactPane({ socket, endpointId, paneId, run }) {
  return killExactPane({ socket, endpointId, paneId, run });
}

// Every marker-bearing pane the isolated socket currently lists, with its leader PID and
// live marker. Used by the finals to detect unrecorded marker panes and by wf7 to prove no
// unrecorded marker pane survives a spawn-saga crash.
export function scanPanes(socket) {
  const scan = scanIsolatedSocket(socket);
  return scan === null ? [] : scan;
}

// Kill the whole dedicated server and remove its socket file (best effort). Only ever
// called at teardown on the run's OWN dedicated socket - never a shared or default one.
export function killSocket(socket, env = process.env) {
  tmux(socket, ['kill-server'], env);
  try {
    const sockDir = env.TMUX_TMPDIR || `/tmp/tmux-${process.getuid()}`;
    fs.unlinkSync(path.join(sockDir, socket));
  } catch {
    // kill-server usually removes it already
  }
}

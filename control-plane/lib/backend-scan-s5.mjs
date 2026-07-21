import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
import { readProcIdentity, readBootId } from './tmux-adapter.mjs';

// S5 production backend seam: the REAL isolated-socket marker scan (spec 795) and a
// transient-aware wrapper over the S3 identity probe (spec 455 "transient probe failed
// but not yet proven dead"). Both are read-only and touch ONLY the isolated
// control-plane tmux socket and /proc; neither kills, adopts, or writes anything. The
// reconciler injects these as its production defaults, and tests inject deterministic
// doubles in their place.
//
// This module does NOT edit the S3 adapter (tmux-adapter.mjs stays byte-identical); it
// composes the landed read-only probe with two things S3 does not provide: (a) an actual
// enumeration of marker-bearing endpoints on the socket, and (b) the transient/definitive
// distinction the reconciler state machine needs but the S3 probe collapses to
// "definitive absence". The distinction rests on backend REACHABILITY: if the isolated
// tmux server cannot be reached at all, the scan/probe did not run, so nothing may be
// declared dead (transient); if the server responds and the specific pane is simply
// absent, that is a definitive loss the S3 predicate reports.

function tmux(socket, args) {
  try {
    return spawnSync('tmux', ['-L', socket, ...args], { encoding: 'utf8' });
  } catch (err) {
    // A missing tmux binary or spawn failure is an unreachable backend, never a proof of
    // absence.
    return { status: 127, stdout: '', stderr: err.message, error: err };
  }
}

// Reachable iff the isolated tmux server responds to a list. A non-zero status ("no
// server running on <socket>", a missing binary, a spawn error) means the backend could
// not be reached and nothing it would have reported can be trusted.
export function backendReachable(socket) {
  const r = tmux(socket, ['list-panes', '-a', '-F', '#{pane_id}']);
  return r.status === 0;
}

// Read a single environment variable from a live process's /proc environ. Returns null if
// the process is gone/unreadable or the variable is absent. /proc/<pid>/environ is a
// NUL-separated list of KEY=VALUE entries.
function readProcEnv(pid, key) {
  let raw;
  try {
    raw = fs.readFileSync(`/proc/${pid}/environ`, 'utf8');
  } catch {
    return null;
  }
  const prefix = `${key}=`;
  for (const entry of raw.split('\0')) {
    if (entry.startsWith(prefix)) return entry.slice(prefix.length);
  }
  return null;
}

// Scan ONLY the isolated control-plane tmux socket for marker-bearing launch endpoints
// (spec 795). Returns one entry per live pane { endpointId, paneId, marker }, where
// `marker` is the pane leader's CP_LAUNCH_MARKER read live from /proc environ (null for a
// markerless pane - e.g. a stray interactive shell). The launch wrapper carries
// CP_LAUNCH_MARKER in the pane leader's environment and `exec`s the harness in place, so
// the marker survives into the running agent's environ and is observable here without any
// write to the pane.
//
// Returns NULL (not an empty array) when the backend is unreachable: a scan that could not
// run must never be mistaken for "scanned, found zero panes", which would spuriously flag
// every known run's marker as missing. An empty array means the server responded with no
// panes.
export function scanIsolatedSocket(socket) {
  const r = tmux(socket, ['list-panes', '-a', '-F', '#{window_id} #{pane_id} #{pane_pid}']);
  if (r.status !== 0 || typeof r.stdout !== 'string') return null;
  const panes = [];
  for (const line of r.stdout.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const [endpointId, paneId, pidStr] = trimmed.split(/\s+/);
    if (!endpointId || !paneId) continue;
    const pid = Number(pidStr);
    const marker = Number.isInteger(pid) ? readProcEnv(pid, 'CP_LAUNCH_MARKER') : null;
    panes.push({ endpointId, paneId, marker: marker ?? null });
  }
  return panes;
}

// List every pane on the isolated socket in ONE call, carrying reachability with it. A
// non-zero status (no server, missing binary, spawn failure) means UNREACHABLE - the list
// did not run - which is distinct from a reachable server that listed zero matching panes.
function listPanesRaw(socket) {
  const r = tmux(socket, ['list-panes', '-a', '-F', '#{window_id} #{pane_id} #{pane_pid}']);
  if (r.status !== 0 || typeof r.stdout !== 'string') return { reachable: false, entries: [] };
  const entries = [];
  for (const line of r.stdout.split('\n')) {
    const t = line.trim();
    if (!t) continue;
    const [endpointId, paneId, pidStr] = t.split(/\s+/);
    if (!endpointId || !paneId) continue;
    entries.push({ endpointId, paneId, pid: Number(pidStr) });
  }
  return { reachable: true, entries };
}

const TRANSIENT_ANOMALY = 'running_without_verification';
function transient(failingClause) {
  return { matches: false, transient: true, failingClause, anomalyClass: TRANSIENT_ANOMALY };
}
function definitive(anomalyClass, failingClause) {
  return { matches: false, transient: false, failingClause, anomalyClass };
}

// Transient-aware identity probe (qa-s5r2-q65 finding 4; spec 455/491). Reuses the S3
// read helpers (readBootId, readProcIdentity) for the actual /proc identity reads and adds
// the disposition S3's collapsed predicate cannot: TRANSIENT is the FAIL-SAFE DEFAULT
// whenever the probe cannot PROVE absence, and a result is DEFINITIVE only when a
// SUCCESSFUL operation affirmatively shows the identity gone or replaced.
//
// The reachability listing is ONE atomic call carrying presence with it, so there is no
// preflight/probe gap: a socket that dies mid-probe surfaces as unreachable -> transient,
// never as a spurious pane-absent. Every read failure - an unreachable server, an
// unreadable boot id, an unreadable pane leader or agent /proc - is transient, because a
// failed read never proves a process is gone (readProcIdentity returns the SAME null for
// gone OR unreadable, tmux-adapter.mjs). The ONLY definitive losses are: a reachable
// server that does not list the pane (affirmative absence), a readable but changed boot id
// (affirmative reboot), a pane led by a different pid, or a readable process whose start
// ticks / exe / argv / parent / pty affirmatively differ (a real identity replacement).
export function probeIdentityTransientAware({ run, socket }) {
  const list = listPanesRaw(socket);
  if (!list.reachable) return transient('backend_unreachable');

  // An incomplete stored binding cannot be verified either way -> transient, never proof.
  const required = ['boot_id', 'pane_leader_pid', 'pane_start_ticks', 'agent_pid',
    'agent_start_ticks', 'agent_exe', 'agent_argv_hash', 'agent_ppid', 'agent_pty', 'endpoint_id', 'pane_id'];
  for (const f of required) {
    if (run[f] === null || run[f] === undefined) return transient(`incomplete_binding:${f}`);
  }

  const bootId = readBootId();
  if (bootId === null) return transient('boot_id_unreadable');        // can't read -> can't prove
  if (bootId !== run.boot_id) return definitive('missing_pane', 'boot_changed'); // reboot: affirmative absence

  const pane = list.entries.find((e) => e.endpointId === run.endpoint_id && e.paneId === run.pane_id);
  if (!pane) return definitive('missing_pane', 'pane_absent'); // reachable server proves the pane gone

  if (pane.pid !== Number(run.pane_leader_pid)) return definitive('identity_mismatch', 'pane_leader_pid'); // different pid leads the pane
  const paneLeader = readProcIdentity(pane.pid);
  if (!paneLeader) return transient('pane_leader_unreadable');         // read failed -> can't prove
  if (paneLeader.startTicks !== Number(run.pane_start_ticks)) return definitive('pid_reuse_suspected', 'pane_start_ticks');

  const agent = readProcIdentity(Number(run.agent_pid));
  if (!agent) return transient('agent_unreadable');                    // read failed -> can't prove
  if (agent.startTicks !== Number(run.agent_start_ticks)) return definitive('pid_reuse_suspected', 'agent_start_ticks');
  if (agent.exe !== run.agent_exe) return definitive('identity_mismatch', 'agent_exe');
  if (agent.argvHash !== run.agent_argv_hash) return definitive('identity_mismatch', 'agent_argv_hash');
  if (agent.ppid !== Number(run.agent_ppid)) return definitive('identity_mismatch', 'agent_ppid');
  if (agent.pty !== run.agent_pty) return definitive('identity_mismatch', 'agent_pty');

  return { matches: true, failingClause: null, anomalyClass: null };
}

import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
import { probeIdentity as realProbeIdentity } from './tmux-adapter.mjs';

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

// Transient-aware identity probe (spec 455/491). Reachability first: if the isolated tmux
// server cannot be reached, the probe did not run - report a TRANSIENT failure so the
// reconciler demotes to bound_unverified rather than declaring a live binding lost. When
// the server IS reachable, delegate to the S3 definitive `identity_matches` predicate: a
// pane the reachable server does not list is a genuine, provable absence.
export function probeIdentityTransientAware({ run, socket, now }) {
  if (!backendReachable(socket)) {
    return {
      matches: false, transient: true,
      failingClause: 'backend_unreachable', anomalyClass: 'running_without_verification'
    };
  }
  return realProbeIdentity({ run, socket, now });
}

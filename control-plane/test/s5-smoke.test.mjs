import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { scanIsolatedSocket, backendReachable, probeIdentityTransientAware } from '../lib/backend-scan-s5.mjs';
import { cleanupAll } from './helpers.mjs';

// Real-adapter smoke for the S5 production backend seam (qa-s5-q64 finding 1): the marker
// scan actually reads marker-bearing endpoints off a genuine ISOLATED `tmux -L <cp-socket>`
// namespace, reading each pane leader's CP_LAUNCH_MARKER live from /proc environ - exactly
// how the launch wrapper (bin/cp-launch.sh) tags a launched pane. It NEVER kills or adopts:
// it only reads. The mutation-sensitive domain coverage (s5-contract/s5-adversarial) runs
// with injected scan fixtures and needs no tmux; this test SKIPs when tmux is absent, the
// same way S0's hosted-Postgres contract and the S3 smoke do.
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
  return `cp-s5-smoke-${process.pid}-${socketCounter}`;
}
function tmux(socket, args, env) {
  return spawnSync('tmux', ['-L', socket, ...args], { encoding: 'utf8', env: env || process.env });
}
function killSocket(socket) {
  tmux(socket, ['kill-server']);
  try {
    const sockDir = process.env.TMUX_TMPDIR || `/tmp/tmux-${process.getuid()}`;
    fs.unlinkSync(path.join(sockDir, socket));
  } catch {
    // best effort; kill-server usually removes it
  }
}
function waitFor(predicate, { tries = 200, stepMs = 25 } = {}) {
  for (let i = 0; i < tries; i += 1) {
    if (predicate()) return true;
    spawnSync('sleep', [String(stepMs / 1000)]);
  }
  return predicate();
}

test('t_real_marker_scan_reads_markers_and_flags_orphans', { skip: !hasTmux ? 'tmux not available' : false }, async () => {
  const socket = isolatedSocket();
  try {
    // A MARKER-BEARING pane: its command inherits CP_LAUNCH_MARKER via tmux -e, exactly as
    // the launch wrapper's env carries it. And a MARKERLESS pane: a plain command with no
    // marker, i.e. a stray endpoint.
    // Separate sessions so the markerless pane does NOT inherit the marker session's env
    // (tmux propagates a session `-e` var to that session's later panes).
    const mk = tmux(socket, ['new-session', '-d', '-s', 'known', '-x', '80', '-y', '24', '-e', 'CP_LAUNCH_MARKER=marker-known-1', 'sleep 300']);
    assert.equal(mk.status, 0, `new-session (marker) failed: ${mk.stderr}`);
    const orph = tmux(socket, ['new-session', '-d', '-s', 'orphan', '-x', '80', '-y', '24', 'sleep 300']);
    assert.equal(orph.status, 0, `new-session (markerless) failed: ${orph.stderr}`);

    assert.equal(backendReachable(socket), true, 'the isolated tmux server is reachable');

    // Wait until the scan actually observes both the marker and the markerless pane. The
    // pane command execs (sh -c 'sleep 300' -> sleep) and the environ is stable only once
    // the harness image is in place, so poll the real condition under test rather than mere
    // pane presence.
    const ready = waitFor(() => {
      const s = scanIsolatedSocket(socket);
      return Array.isArray(s) && s.some((p) => p.marker === 'marker-known-1') && s.some((p) => p.marker === null);
    });
    const scanned = scanIsolatedSocket(socket);
    assert.equal(ready, true, `scan observed both a marker-bearing and a markerless pane (got ${JSON.stringify(scanned)})`);
    assert.ok(Array.isArray(scanned) && scanned.length >= 2, 'a reachable socket yields an array scan of the live panes');

    const markers = scanned.map((p) => p.marker);
    assert.equal(markers.includes('marker-known-1'), true, 'the marker-bearing pane is read from /proc environ');
    assert.equal(markers.includes(null), true, 'the markerless pane is surfaced as a null marker (an orphan)');

    // The scan is READ-ONLY: it never killed or altered a pane. Both panes still live.
    assert.equal(tmux(socket, ['list-panes', '-a', '-F', '#{pane_id}']).stdout.trim().split('\n').filter(Boolean).length >= 2, true, 'the read-only scan disturbed nothing');

    // The transient-aware probe against a run whose pane the reachable server does NOT list
    // is a DEFINITIVE absence (missing_pane), not a transient failure - the server answered.
    const probe = probeIdentityTransientAware({
      run: { endpoint_id: '@999', pane_id: '%999', boot_id: 'b', pane_leader_pid: 1, pane_start_ticks: 1, agent_pid: 1, agent_start_ticks: 1, agent_exe: '/x', agent_argv_hash: 'h', agent_ppid: 1, agent_pty: 'p' },
      socket
    });
    assert.equal(probe.matches, false);
    assert.notEqual(probe.transient, true, 'a reachable server proving a pane absent is definitive, not transient');
  } finally {
    killSocket(socket);
  }
});

test('t_real_marker_scan_transient_on_dead_socket', { skip: !hasTmux ? 'tmux not available' : false }, async () => {
  // A socket whose server was never started (or was killed) is UNREACHABLE: the scan is
  // null (not an empty array) and the probe is transient - nothing may be declared dead.
  const socket = isolatedSocket();
  killSocket(socket); // ensure no server
  assert.equal(backendReachable(socket), false, 'no server on this socket');
  assert.equal(scanIsolatedSocket(socket), null, 'an unreachable socket yields a null scan');
  const probe = probeIdentityTransientAware({ run: { endpoint_id: '@0', pane_id: '%0' }, socket });
  assert.equal(probe.transient, true, 'an unreachable backend is transient, never proof of death');
});

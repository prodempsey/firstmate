import fs from 'node:fs';

// A synchronous sleep with no child process and no busy-wait: block this thread on a
// private SharedArrayBuffer that is never notified, so Atomics.wait returns only on
// timeout. Keeps the harness's bounded polling cheap and dependency-free.
const SLEEP_BUF = new Int32Array(new SharedArrayBuffer(4));
function sleepMs(ms) {
  Atomics.wait(SLEEP_BUF, 0, 0, Math.max(0, ms));
}

// Process-liveness primitives for the disposable E2E harness (spec section 11). Exact-PID
// teardown and the "zero orphan fixture processes" / "zero unrecorded marker-bearing
// panes" final assertions all rest on being able to ask, precisely, whether ONE recorded
// PID is still alive - never a pattern kill, never a name match. Everything here operates
// on an exact integer PID the fixture itself recorded.

// True iff the exact pid is a live process this user can signal. `kill(pid, 0)` sends no
// signal; it only probes existence/permission. EPERM means the pid exists but is not ours
// (still "alive" for orphan-detection purposes); ESRCH means it is gone.
export function isAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    if (err.code === 'EPERM') return true;
    return false;
  }
}

// The live /proc cmdline of a pid as a plain string (NUL-delimited argv joined by space),
// or null when the pid is gone/unreadable. Used to confirm an exec completed (the argv is
// no longer the launcher wrapper's) exactly as the S3 smoke does.
export function readCmdlineStr(pid) {
  try {
    return fs.readFileSync(`/proc/${pid}/cmdline`).toString('latin1').replace(/\0/g, ' ').trim();
  } catch {
    return null;
  }
}

// Poll a predicate up to `tries` times with a fixed step, returning its final value. The
// harness never sleeps a fixed duration and hopes; it waits for an OBSERVED condition
// (registration written, exec completed, pane gone, process dead) with a bounded budget.
export function waitFor(predicate, { tries = 400, stepMs = 25 } = {}) {
  for (let i = 0; i < tries; i += 1) {
    if (predicate()) return true;
    sleepMs(stepMs);
  }
  return predicate();
}

// Send SIGKILL to an exact pid and wait until it is confirmed gone. Returns true when the
// pid is dead (or already was). NEVER used with a pattern - the caller passes one exact,
// fixture-recorded integer pid.
export function killExactPid(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return true;
  try {
    process.kill(pid, 'SIGKILL');
  } catch (err) {
    if (err.code === 'ESRCH') return true; // already gone
    if (err.code !== 'EPERM') throw err;
  }
  return waitFor(() => !isAlive(pid));
}

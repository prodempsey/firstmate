import { spawn } from 'node:child_process';
import { LockTimeoutError, LockUnavailableError } from './errors.mjs';

// Real POSIX flock(2), cross-process.
//
// The spec (spec-amend-s4 sections 2.1-2.2, 3, 10) mandates flock per invocation,
// covering every PGlite open including reads. Node's stdlib has no flock(2), so we
// hold the advisory lock in a `flock(1)` (util-linux) holder subprocess:
//
//   flock <-x|-s> <lockfile> -c 'printf R; exec cat'
//
// `flock(1)` blocks until it acquires the lock on the file, then runs the shell
// command. That command prints a single "R" (ready => lock is held) and then
// `exec cat` blocks reading stdin. The lock is held for exactly as long as the
// holder lives. We release by closing the holder's stdin: `cat` sees EOF, exits,
// and the kernel drops the flock when the fd closes. This is close-before-unlock
// safe: the caller finishes its PGlite work (and closes PGlite) before release()
// is invoked.
//
// Advisory-lock note: flock(2) is advisory, so this serializes cooperating `cp`
// processes that all go through this module. Direct PGlite opens that bypass the
// lock are separately blocked by the runtime owner guard (pglite-engine.mjs).

const READY_BYTE = 'R';

// Brand identifying handles minted by this module. Kept private so a caller
// cannot forge a "lock held" capability; the only way to obtain a live handle is
// to actually acquire the lock here.
const FLOCK_BRAND = Symbol('control-plane.flock.handle');
const liveHandles = new WeakSet();

// True iff `handle` was minted by acquireFlock and has not been released. The
// PGlite engine factory uses this as the runtime owner guard: you cannot open
// PGlite without presenting a currently-held exclusive lock handle.
export function isFlockHandleLive(handle) {
  return Boolean(handle) && handle.brand === FLOCK_BRAND && liveHandles.has(handle);
}

// Acquire a flock on lockPath. Returns a handle { release, exclusive } where
// release() resolves once the lock has been dropped. `exclusive:false` takes a
// shared (read) lock.
export function acquireFlock(lockPath, { exclusive = true, timeoutMs = 15000 } = {}) {
  return new Promise((resolve, reject) => {
    const flag = exclusive ? '-x' : '-s';
    // flock's own -w bound (seconds), plus a hard JS-side timer as a backstop.
    const waitSecs = Math.max(1, Math.ceil(timeoutMs / 1000));
    let child;
    try {
      child = spawn(
        'flock',
        ['-w', String(waitSecs), flag, lockPath, '-c', `printf ${READY_BYTE}; exec cat`],
        { stdio: ['pipe', 'pipe', 'ignore'] }
      );
    } catch (error) {
      reject(new LockUnavailableError(`failed to spawn flock: ${error.message}`, { lockPath }));
      return;
    }

    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      child.kill('SIGKILL');
      reject(new LockTimeoutError(`timed out acquiring flock on ${lockPath}`, { lockPath, timeoutMs }));
    }, timeoutMs + 1500);

    child.on('error', (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      // ENOENT here means the flock binary is missing.
      reject(new LockUnavailableError(`flock helper error: ${error.message}`, { lockPath }));
    });

    child.stdout.on('data', (buf) => {
      if (settled) return;
      if (buf.toString().includes(READY_BYTE)) {
        settled = true;
        clearTimeout(timer);
        const handle = {
          brand: FLOCK_BRAND,
          exclusive,
          release() {
            liveHandles.delete(handle);
            return new Promise((res) => {
              // If the holder already exited, the kernel dropped the lock already.
              if (child.exitCode !== null || child.signalCode !== null) {
                res();
                return;
              }
              child.once('close', () => res());
              try {
                child.stdin.end();
              } catch {
                // If stdin is already gone, killing the holder still drops the lock.
                child.kill('SIGKILL');
              }
            });
          }
        };
        liveHandles.add(handle);
        resolve(handle);
      }
    });

    // If the holder exits before we ever saw READY, the lock was not acquired
    // (contention past -w, or a failed helper).
    child.on('exit', (code, signal) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(
        new LockTimeoutError(
          `flock did not acquire ${lockPath} (exit ${code}, signal ${signal})`,
          { lockPath, code, signal }
        )
      );
    });
  });
}

// Run `fn` while holding an exclusive (or shared) flock on lockPath, releasing
// the lock afterwards even if `fn` throws.
export async function withFlock(lockPath, fn, options = {}) {
  const handle = await acquireFlock(lockPath, options);
  try {
    return await fn();
  } finally {
    await handle.release();
  }
}

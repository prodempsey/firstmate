import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { acquireFlock } from '../lib/flock.mjs';
import { LockTimeoutError } from '../lib/errors.mjs';
import { mkFixtureHome, cleanupAll } from './helpers.mjs';

after(cleanupAll);

const PROBE_WORKER = fileURLToPath(new URL('./workers/probe-worker.mjs', import.meta.url));

function runWorker(fmHome) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [PROBE_WORKER], {
      env: { ...process.env, FM_HOME: fmHome },
      stdio: ['ignore', 'pipe', 'pipe']
    });
    let out = '';
    let err = '';
    child.stdout.on('data', (b) => (out += b));
    child.stderr.on('data', (b) => (err += b));
    child.on('close', (code) => resolve({ code, out, err }));
  });
}

test('concurrent cp processes serialize: no lost commit_sequence updates', async () => {
  const { fmHome } = mkFixtureHome();
  await new PgliteLocalStore({ fmHome }).init();

  // N separate OS processes racing to bump commit_sequence on the same pgdata. If
  // the exclusive flock did not serialize every open, PGlite opens would collide
  // or the read-modify-write would lose updates.
  const N = 6;
  const results = await Promise.all(Array.from({ length: N }, () => runWorker(fmHome)));
  for (const r of results) {
    assert.equal(r.code, 0, `worker failed: ${r.err}`);
  }

  const state = await new PgliteLocalStore({ fmHome }).coordinatorState();
  assert.equal(state.commitSequence, N, 'every commit advanced commit_sequence exactly once');
});

test('reads also acquire the exclusive lock (blocked while held)', async () => {
  const { fmHome } = mkFixtureHome();
  await new PgliteLocalStore({ fmHome }).init();

  // Derive the canonical sibling lock path and hold it externally.
  const parent = fs.realpathSync(path.join(fmHome, 'state', 'control-plane'));
  const lockPath = path.join(parent, 'pgdata.lock');
  const holder = await acquireFlock(lockPath, { exclusive: true, timeoutMs: 5000 });

  try {
    // A pure read (coordinatorState) must fail to acquire the lock while it is held.
    const store = new PgliteLocalStore({ fmHome, env: { CP_LOCK_TIMEOUT_MS: '600' } });
    await assert.rejects(() => store.coordinatorState(), LockTimeoutError);
  } finally {
    await holder.release();
  }

  // Once released, the same read proceeds.
  const store = new PgliteLocalStore({ fmHome });
  const state = await store.coordinatorState();
  assert.equal(state.commitSequence, 0);
});

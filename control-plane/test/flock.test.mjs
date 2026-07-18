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

const CP_BIN = fileURLToPath(new URL('../bin/cp.mjs', import.meta.url));

function runCp(args, env) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [CP_BIN, ...args], {
      env: { ...process.env, ...env },
      stdio: ['ignore', 'pipe', 'pipe']
    });
    let out = '';
    let err = '';
    child.stdout.on('data', (b) => (out += b));
    child.stderr.on('data', (b) => (err += b));
    child.on('close', (code) => resolve({ code, out, err }));
  });
}

test('concurrent cp processes serialize: no lost domain-revision updates', async () => {
  const { fmHome } = mkFixtureHome();
  await new PgliteLocalStore({ fmHome }).init();

  // Five separate OS processes racing to create tasks on the same pgdata. If the
  // exclusive flock did not serialize every open, PGlite opens would collide or
  // the read-modify-write of domain_revision would lose updates.
  const N = 5;
  const runs = [];
  for (let i = 0; i < N; i += 1) {
    runs.push(
      runCp(
        ['create-task', `race-${i}`, '--kind', 'ship', '--title', `t${i}`,
          '--origin', 'captain_order', '--order-ref', 'ORD-228'],
        { FM_HOME: fmHome }
      )
    );
  }
  const results = await Promise.all(runs);
  for (const r of results) {
    assert.equal(r.code, 0, `child failed: ${r.err}`);
  }

  const state = await new PgliteLocalStore({ fmHome }).runExclusive(async (conn) => {
    const cs = await conn.query('SELECT domain_revision FROM coordinator_state WHERE id=1');
    const tc = await conn.query('SELECT count(*)::int n FROM tasks');
    return { domainRevision: Number(cs.rows[0].domain_revision), tasks: Number(tc.rows[0].n) };
  });
  assert.equal(state.tasks, N, 'every task committed');
  assert.equal(state.domainRevision, N, 'every commit advanced domain_revision exactly once');
});

test('reads also acquire the exclusive lock (blocked while held)', async () => {
  const { fmHome } = mkFixtureHome();
  await new PgliteLocalStore({ fmHome }).init();

  // Derive the canonical sibling lock path and hold it externally.
  const parent = fs.realpathSync(path.join(fmHome, 'state', 'control-plane'));
  const lockPath = path.join(parent, 'pgdata.lock');
  const holder = await acquireFlock(lockPath, { exclusive: true, timeoutMs: 5000 });

  try {
    // A pure read (task-head) must fail to acquire the lock while it is held.
    const store = new PgliteLocalStore({ fmHome, env: { CP_LOCK_TIMEOUT_MS: '600' } });
    await assert.rejects(() => store.taskHead('anything'), LockTimeoutError);
  } finally {
    await holder.release();
  }

  // Once released, the same read proceeds.
  const store = new PgliteLocalStore({ fmHome });
  assert.equal(await store.taskHead('anything'), null);
});
